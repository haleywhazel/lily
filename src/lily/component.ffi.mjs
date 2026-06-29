/**
 * COMPONENT TREE RENDERING
 *
 * This mjs file handles traversing the Component tree and rendering it to the
 * DOM. Components create their own selective handlers that track slice changes.
 *
 * When renderTree is called on root mount, the HTML skeleton is generated, and
 * and the render function for each component is called, this is when the
 * handlers get created. Each handler is then triggered at the end of the
 * `renderTree` function, beginning live component updates.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import {
  applyPatchesToElement,
  createSelective,
  referenceEqual,
} from "./client.ffi.mjs";
import { isEqual } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Get the model from the runtime */
export function getModel(runtime) {
  return runtime.handle.getModel();
}

/**
 * Identity function, used as `to_dynamic` and `list_dynamic` in the Gleam
 * file. Workaround so the public API can keep slice values opaque while the
 * runtime treats them as plain JS values.
 */
export function identity(value) {
  return value;
}

export function renderTree(runtime, rootSelector, component, model, toHtml, toSlot) {
  const handle = runtime.handle;

  // The binding closures take a Runtime, not just a handle, so stash
  // it on the handle for renderDecorated to grab. Idempotent across
  // mounts since the same runtime drives every mount.
  handle.setRuntime(runtime);

  // Start a mount segment keyed by selector. This tears down the prior
  // segment for the same selector (so re-mounts replace) while leaving
  // other mount points alone, which is what makes overlay-style portals
  // work without a separate variant. Component IDs continue counting
  // across mounts; only the segment is selector-scoped.
  handle.startMountSegment(rootSelector);

  const html = renderComponent(handle, component, model, toHtml, toSlot);

  handle.setInnerHtml(rootSelector, html);

  // Trigger only this mount's handlers, not the global registry.
  // Otherwise a second mount would re-fire every previously-mounted
  // tree's handlers; harmless (they're idempotent) but wasteful.
  // Handlers fire before bindings drain because the first handler call
  // for a `simple` / `switch` wraps innerHTML on its component root,
  // which would wipe any element-scoped listener that was attached to
  // the prior subtree. Letting handlers stabilise the DOM first means
  // bindings attach to the final tree.
  const segmentIds = handle.endMountSegment();
  const registry = handle.getComponentRegistry();
  for (const id of segmentIds) {
    const handler = registry.get(id);
    if (handler) handler(model);
  }

  // Bindings get queued during renderComponent (every Decorated with
  // bindings in the tree, including ones reached via slot children). Fire
  // them now that
  // the DOM has stabilised so element-scoped listeners attach to the
  // post-handler subtree.
  handle.drainBindings();

  return null;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

// --- DOM HELPERS ---

/**
 * Returns `cached` if it's still in the document, otherwise re-queries
 * `selector`. Handlers cache their root element to skip a querySelector on
 * every model update; the re-query path is for re-mounts after detachment.
 */
function ensureCached(cached, selector) {
  return cached && cached.isConnected
    ? cached
    : document.querySelector(selector);
}

// --- SLOT HELPERS ---

/**
 * Builds a slotter: a function the user calls inline in their content function
 * to place a child component. Each call records the component and returns a
 * placeholder html value (via toSlot). Children are collected in call order,
 * which always equals DOM position order in strict Gleam evaluation.
 */
function makeSlotter(toSlot) {
  const collected = []; // [Component, ...]
  const slot = (component) => {
    collected.push(component);
    return toSlot();
  };
  return { slot, collected };
}

/**
 * Renders a child component, capturing any new component IDs that get
 * registered as a side effect. Returns the HTML string and the array of new
 * IDs so the caller can run their handlers immediately and track them for
 * cleanup when the parent item is removed or re-rendered.
 */
function renderChildAndCaptureIds(handle, child, model, toHtml, toSlot) {
  const registry = handle.getComponentRegistry();
  const beforeKeys = new Set(registry.keys());
  const html = renderComponent(handle, child, model, toHtml, toSlot);
  const newIds = [];
  for (const k of registry.keys()) {
    if (!beforeKeys.has(k)) newIds.push(k);
  }
  return { html, newIds };
}

/** Runs each handler in `ids` once with the current model to populate. */
function runChildHandlers(handle, ids, model) {
  const registry = handle.getComponentRegistry();
  for (const id of ids) {
    const handler = registry.get(id);
    if (handler) handler(model);
  }
}

/**
 * After calling the user's content function and serialising to HTML, replace
 * each `<lily-slot>` marker in order with the rendered HTML of the
 * corresponding collected child component. Returns the substituted HTML string
 * and a flat list of all child component IDs registered during this call.
 *
 * Splits on every placeholder in one pass, then interleaves segments with
 * rendered children. If there are more children than placeholders (the user
 * dropped a slot return value), logs an error and unregisters the orphan
 * children so their handlers don't dangle.
 */
function substituteSlots(parentHtml, collected, handle, model, toHtml, toSlot) {
  if (collected.length === 0) {
    return { html: parentHtml, ids: [] };
  }

  const segments = parentHtml.split(SLOT_RE);
  const slotsAvailable = segments.length - 1;
  const allIds = [];
  let html = segments[0];

  for (let i = 0; i < collected.length; i++) {
    const { html: childHtml, newIds } = renderChildAndCaptureIds(
      handle,
      collected[i],
      model,
      toHtml,
      toSlot,
    );
    if (i >= slotsAvailable) {
      console.error(
        "lily: <lily-slot> placeholder missing from rendered HTML, child component dropped. " +
          "Make sure slot() return values are placed in the template.",
      );
      unregisterChildHandlers(handle, newIds);
      continue;
    }
    html += childHtml + segments[i + 1];
    allIds.push(...newIds);
  }

  // Append any trailing segments past the matched-children count. Only
  // reachable if the template contains more placeholders than the user
  // passed children, in which case those extra slots are dropped from output.
  for (let i = collected.length + 1; i < segments.length; i++) {
    html += segments[i];
  }

  return { html, ids: allIds };
}

/** Unregisters every id in `ids` from the runtime registry. */
function unregisterChildHandlers(handle, ids) {
  for (const id of ids) {
    handle.unregisterComponent(id);
  }
}

// --- LIST HANDLERS ---

/** Create handler for `component.each` (returns the handler function) */
function createEachHandler(
  handle,
  selector,
  slice,
  getKey,
  render,
  toHtml,
  toSlot,
  compare,
) {
  const previousItemByKey = new Map();
  const childIdsByKey = new Map();

  return createKeyedListHandler({
    handle,
    selector,
    slice,
    getKey,
    onDrop(keyStr) {
      previousItemByKey.delete(keyStr);
      const oldIds = childIdsByKey.get(keyStr);
      if (oldIds) unregisterChildHandlers(handle, oldIds);
      childIdsByKey.delete(keyStr);
    },
    onItem({ container, liveChildren, item, keyStr, element, index, model }) {
      // Compare the slice item (not the rendered Component), Components may
      // contain function fields (e.g. nested each_live) that never compare
      // structurally. The slice item is the user's source of truth.
      // Re-rendering replaces innerHTML, so any previously-registered child
      // component handlers for this key are now pointing at detached nodes,
      // release them and register the new ones.
      const previousItem = previousItemByKey.get(keyStr);
      const itemChanged =
        previousItem === undefined || !compare(previousItem, item);

      if (itemChanged) {
        previousItemByKey.set(keyStr, item);
        const oldIds = childIdsByKey.get(keyStr);
        if (oldIds) unregisterChildHandlers(handle, oldIds);

        // Bindings declared inside the item body are ignored, matching
        // the documented placement rule. Attach per-list events on the
        // each component itself or an ancestor instead.
        const was = handle.suppressBindings();
        const { html, newIds } = renderChildAndCaptureIds(
          handle,
          render(item),
          model,
          toHtml,
          toSlot,
        );
        handle.restoreBindings(was);
        element.innerHTML = html;
        childIdsByKey.set(keyStr, newIds);
      }

      // Slot into position before running child handlers so their queries
      // find the freshly-inserted DOM.
      const currentAtIndex = liveChildren[index];
      if (currentAtIndex !== element) {
        container.insertBefore(element, currentAtIndex || null);
      }

      if (itemChanged) {
        runChildHandlers(handle, childIdsByKey.get(keyStr), model);
      }
    },
  });
}

/** Create handler for `component.each_live` (returns the handler function) */
function createEachLiveHandler(
  handle,
  selector,
  slice,
  getKey,
  initial,
  patch,
  toHtml,
  toSlot,
  compare,
) {
  const previousPatchesByKey = new Map();
  const childIdsByKey = new Map();

  return createKeyedListHandler({
    handle,
    selector,
    slice,
    getKey,
    onDrop(keyStr) {
      previousPatchesByKey.delete(keyStr);
      const oldIds = childIdsByKey.get(keyStr);
      if (oldIds) unregisterChildHandlers(handle, oldIds);
      childIdsByKey.delete(keyStr);
    },
    onItem({
      container,
      liveChildren,
      deferred,
      item,
      keyStr,
      element,
      isNew,
      index,
      model,
    }) {
      if (isNew) {
        // Suppress binding collection inside the item body, matching the
        // each_live placement rule (events go on the wrapper or above).
        const was = handle.suppressBindings();
        const { html, newIds } = renderChildAndCaptureIds(
          handle,
          initial(item),
          model,
          toHtml,
          toSlot,
        );
        handle.restoreBindings(was);
        element.innerHTML = html;
        childIdsByKey.set(keyStr, newIds);
        // Defer until all items are positioned so child handlers' queries
        // find the inserted DOM.
        deferred.push(() => runChildHandlers(handle, newIds, model));
      }

      // Only patch if the patch list has changed (respects compare strategy)
      const patchList = patch(item);
      const previousPatches = previousPatchesByKey.get(keyStr);
      if (
        patchList !== undefined &&
        (previousPatches === undefined || !compare(previousPatches, patchList))
      ) {
        previousPatchesByKey.set(keyStr, patchList);
        applyPatchesToElement(element, patchList.toArray());
      }

      // Slot into the right position if it's drifted
      const currentAtIndex = liveChildren[index];
      if (currentAtIndex !== element) {
        container.insertBefore(element, currentAtIndex || null);
      }
    },
  });
}

/**
 * Shared shell for keyed-list handlers (`component.each` and
 * `component.each_live`). Owns the children Map, the slice-reference
 * short-circuit, the dropped-keys diff, and the per-item positioning loop.
 *
 * Callers supply two callbacks. `onDrop(keyStr)` runs after a child element
 * has been removed from the DOM, used to release per-key state. `onItem`
 * runs once per item; the caller decides whether to render, patch, or do
 * nothing. Anything that must run after all items are positioned can be
 * pushed onto `deferred` from `onItem`.
 */
function createKeyedListHandler({ handle, selector, slice, getKey, onDrop, onItem }) {
  const children = new Map();
  let cachedContainer = null;
  let previousList = null;

  return function (model) {
    // Short-circuit when the user's list slice returns the same reference,
    // nothing in the list could have changed.
    const list = slice(model);
    if (list === previousList) return;
    previousList = list;

    cachedContainer = ensureCached(cachedContainer, selector);
    const container = cachedContainer;
    if (!container) return;

    // Build items array and key set in a single pass.
    const items = list.toArray();
    const currentKeySet = new Set();
    for (let i = 0; i < items.length; i++) {
      currentKeySet.add(getKey(items[i]));
    }

    // Drop children whose keys are no longer in the list. If a child
    // carries transition data attributes, removeWithTransition defers
    // the actual removal until the exit animation completes (or aborts
    // when the same key reappears mid-exit).
    for (const [keyStr, element] of children) {
      if (!currentKeySet.has(keyStr)) {
        // Skip if already mid-exit, the in-flight removeWithTransition
        // will tear it down. Without this guard, a second render before
        // the duration elapses would start a duplicate timer.
        if (handle.getPendingExit(element)) continue;
        removeWithTransition(handle, container, element, () => {
          children.delete(keyStr);
          onDrop(keyStr);
        });
      }
    }

    // Cache the live HTMLCollection reference once, index reads avoid the
    // per-iteration property lookup on `container`. The collection updates
    // automatically as we `insertBefore`, so the live semantics are intact.
    const liveChildren = container.children;
    const deferred = [];

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const keyStr = getKey(item);

      let element = children.get(keyStr);
      const isNew = !element;
      if (isNew) {
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        children.set(keyStr, element);
      } else if (handle.getPendingExit(element)) {
        // Re-add mid-exit: cancel the pending removal and strip the
        // exit class synchronously. The abort branch inside
        // removeWithTransition would strip it too, but that runs as a
        // microtask after the current dispatch returns; doing it here
        // means subsequent synchronous DOM reads see the cleaned-up
        // element immediately.
        handle.cancelPendingExit(element);
        const transitionElement = findTransitionElement(element);
        if (transitionElement) {
          const exitClass = transitionElement.dataset.lilyTransitionExit;
          if (exitClass) transitionElement.classList.remove(exitClass);
        }
      }

      onItem({
        handle,
        container,
        liveChildren,
        deferred,
        item,
        keyStr,
        element,
        isNew,
        index: i,
        model,
      });
    }

    // Run anything queued during the items loop (e.g. per-new-child handler
    // kicks deferred until all positioning is done).
    for (let i = 0; i < deferred.length; i++) {
      deferred[i]();
    }
  };
}

// --- RENDERERS ---

/**
 * Renders a `Component`: dispatch on its `component_type` to produce the
 * inner HTML, then layer its `decorations` (transition wrapper, connection
 * gate, event listeners) on top.
 */
function renderComponent(handle, component, model, toHtml, toSlot) {
  const componentType = component.component_type;
  const typeName = componentType.constructor.name;
  const render = RENDERERS[typeName];
  if (!render) {
    console.error("Unknown component type:", typeName, componentType);
    return "";
  }
  const html = render(handle, componentType, model, toHtml, toSlot);
  return applyDecorations(handle, component.decorations, html, model);
}

/**
 * Applies a component's decoration list to its rendered HTML. Decorations
 * are folded innermost-first in list order, so the last one wraps outermost
 * (matching how the constructors append them):
 *
 *  - `Listener`: queues the binding to fire after renderTree's innerHTML
 *    pass; no element of its own (suppressed inside each / each_live /
 *    switch item bodies via handle.queueBinding).
 *  - `Transition`: wraps in a marker div carrying the enter class (scheduled
 *    for removal) plus the exit class and duration as data attributes for
 *    removeWithTransition; no reactive handler of its own.
 *  - `Connection`: wraps in a div whose disabled / aria-disabled /
 *    lily-disconnected state tracks the connection predicate.
 */
function applyDecorations(handle, decorations, html, model) {
  const runtime = handle.getRuntime();
  for (const decoration of decorations.toArray()) {
    switch (decoration.constructor.name) {
      case "Listener":
        handle.queueBinding(() => decoration.handler(runtime));
        break;

      case "Transition": {
        const { enter, exit, duration_milliseconds: durationMs } = decoration;
        const componentId = handle.nextComponentId();
        scheduleEnterClassRemoval(
          `[data-lily-component="${componentId}"]`,
          enter,
          durationMs,
        );
        html =
          `<div data-lily-component="${componentId}" ` +
          `data-lily-transition-exit="${exit}" ` +
          `data-lily-transition-duration="${durationMs}" ` +
          `class="${enter}">${html}</div>`;
        break;
      }

      case "Connection": {
        const connectedFn = decoration.connected;
        const componentId = handle.nextComponentId();
        const selector = `[data-lily-component="${componentId}"]`;
        let cachedElement = null;
        const handler = createSelective(
          connectedFn,
          referenceEqual,
          (isConnected) => {
            cachedElement = ensureCached(cachedElement, selector);
            if (!cachedElement) return;

            if (isConnected) {
              cachedElement.removeAttribute("data-lily-disabled");
              cachedElement.removeAttribute("aria-disabled");
              cachedElement.classList.remove("lily-disconnected");
            } else {
              cachedElement.setAttribute("data-lily-disabled", "true");
              cachedElement.setAttribute("aria-disabled", "true");
              cachedElement.classList.add("lily-disconnected");
            }
          },
        );
        handle.registerComponent(componentId, handler);
        html = `<div data-lily-component="${componentId}">${html}</div>`;
        break;
      }
    }
  }
  return html;
}

/** Renders an Each component */
function renderEach(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, key, render, compare_structural } = component;

  const compareStrategy = compare_structural ? isEqual : referenceEqual;

  const handler = createEachHandler(
    handle,
    selector,
    slice,
    key,
    render,
    toHtml,
    toSlot,
    compareStrategy,
  );

  // Register handler to be called on model updates
  handle.registerComponent(componentId, handler);

  // Render empty container, handler will populate it
  return `<div data-lily-component="${componentId}"></div>`;
}

/** Renders an EachLive component */
function renderEachLive(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, key, initial, patch, compare_structural } = component;

  const compareStrategy = compare_structural ? isEqual : referenceEqual;

  const handler = createEachLiveHandler(
    handle,
    selector,
    slice,
    key,
    initial,
    patch,
    toHtml,
    toSlot,
    compareStrategy,
  );

  // Register handler to be called on model updates
  handle.registerComponent(componentId, handler);

  // Render empty container, handler will populate it
  return `<div data-lily-component="${componentId}"></div>`;
}

/** Renders a Fragment component */
function renderFragment(handle, component, model, toHtml, toSlot) {
  return component.children
    .toArray()
    .map((child) => renderComponent(handle, child, model, toHtml, toSlot))
    .join("");
}

/** Renders a Live component */
function renderLive(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, initial, apply, compare_structural } = component;

  const compareStrategy = compare_structural ? isEqual : referenceEqual;

  // Build the initial HTML with slot substitution. Children registered here
  // persist for the lifetime of this live component, they are never
  // unregistered between patch updates.
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(initial(slot));
  const { html: initialHtml, ids: childIds } = substituteSlots(
    rawHtml,
    collected,
    handle,
    model,
    toHtml,
    toSlot,
  );

  let cachedElement = null;

  const handler = createSelective(slice, compareStrategy, (data) => {
    const patches = apply(data).toArray();

    cachedElement = ensureCached(cachedElement, selector);
    if (cachedElement) {
      applyPatchesToElement(cachedElement, patches);
    }
  });

  // Register handler to be called on model updates
  handle.registerComponent(componentId, handler);

  // Run child handlers after registering this component's own handler so
  // the registry order is parent-first.
  if (childIds.length > 0) {
    runChildHandlers(handle, childIds, model);
  }

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Simple component */
function renderSimple(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, render, compare_structural } = component;

  const compareStrategy = compare_structural ? isEqual : referenceEqual;

  let cachedElement = null;
  let previousChildIds = [];

  const handler = createSelective(slice, compareStrategy, (data) => {
    // Unregister previous child handlers before re-rendering
    unregisterChildHandlers(handle, previousChildIds);

    const { slot, collected } = makeSlotter(toSlot);
    const rawHtml = toHtml(render(data, slot));
    const { html, ids: newChildIds } = substituteSlots(
      rawHtml,
      collected,
      handle,
      model,
      toHtml,
      toSlot,
    );
    previousChildIds = newChildIds;

    cachedElement = ensureCached(cachedElement, selector);
    if (cachedElement) {
      cachedElement.innerHTML = html;
      // Run child handlers after innerHTML is set so their selectors find DOM
      runChildHandlers(handle, newChildIds, model);
    }
  });

  // Register handler to be called on model updates
  handle.registerComponent(componentId, handler);

  // Initial render
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(render(slice(model), slot));
  const { html: initialHtml, ids: childIds } = substituteSlots(
    rawHtml,
    collected,
    handle,
    model,
    toHtml,
    toSlot,
  );
  previousChildIds = childIds;

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Static component */
function renderStatic(handle, component, model, toHtml, toSlot) {
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(component.content(slot));
  if (collected.length === 0) return rawHtml;

  const { html } = substituteSlots(
    rawHtml,
    collected,
    handle,
    model,
    toHtml,
    toSlot,
  );
  return html;
}

/** Renders a Switch component */
function renderSwitch(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, build, compare_structural } = component;
  const compareStrategy = compare_structural ? isEqual : referenceEqual;

  let cachedElement = null;
  let previousChildIds = [];

  const handler = createSelective(slice, compareStrategy, (data) => {
    // Old child first, so its handlers stop firing before we render the
    // replacement. Otherwise a quick re-dispatch could hit a handler
    // whose root no longer exists in the DOM.
    unregisterChildHandlers(handle, previousChildIds);

    // Suppress binding collection while rendering the case body: events
    // declared inside `build`'s returned Component are ignored by
    // design (consistent with each / each_live item bodies). Without
    // this, every switch swap would register fresh listeners on top of
    // the old ones.
    const was = handle.suppressBindings();
    const child = build(data);
    const { html, newIds } = renderChildAndCaptureIds(
      handle,
      child,
      model,
      toHtml,
      toSlot,
    );
    handle.restoreBindings(was);
    previousChildIds = newIds;

    cachedElement = ensureCached(cachedElement, selector);
    if (cachedElement) {
      cachedElement.innerHTML = html;
      runChildHandlers(handle, newIds, model);
    }
  });

  handle.registerComponent(componentId, handler);

  // Initial render. The child's handlers are registered as a side effect
  // of renderChildAndCaptureIds; the outer registry trigger in
  // renderTree runs them with the model.
  const wasInitial = handle.suppressBindings();
  const initialChild = build(slice(model));
  const { html: initialHtml, newIds: initialIds } = renderChildAndCaptureIds(
    handle,
    initialChild,
    model,
    toHtml,
    toSlot,
  );
  handle.restoreBindings(wasInitial);
  previousChildIds = initialIds;

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

// --- TRANSITION HELPERS ---

/**
 * Schedules removal of the enter class on the next animation frame.
 * Using requestAnimationFrame (two-frame dance) so the class outlives
 * the initial paint, otherwise the animation can be skipped on some
 * browsers when the class is removed mid-frame. Falls back to the
 * duration timer so the class is gone even when the element is
 * offscreen and rAF is throttled.
 */
function scheduleEnterClassRemoval(selector, enterClass, durationMs) {
  const remove = () => {
    const element = document.querySelector(selector);
    if (element) element.classList.remove(enterClass);
  };
  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(() => requestAnimationFrame(remove));
  }
  setTimeout(remove, durationMs);
}

/**
 * Finds the Transition wrapper inside or at `element`. When a
 * Transition is placed as the top-level component of an each_live /
 * each item, the framework's key wrapper (`<div data-lily-key>`) sits
 * one level above it; for `switch`, the switch wrapper sits above it.
 * Returns null when the subtree doesn't include a Transition (so the
 * removal proceeds synchronously).
 */
function findTransitionElement(element) {
  if (element.dataset?.lilyTransitionExit) return element;
  const child = element.firstElementChild;
  if (child?.dataset?.lilyTransitionExit) return child;
  return null;
}

/**
 * Performs a transition-aware removal of `element` from `parent`.
 * If the subtree includes a Transition wrapper (own dataset attrs or
 * first child's), applies the exit class to that wrapper, races
 * animationend vs the duration timer, then removes `element` from
 * `parent` and calls `onComplete`. If not, removes immediately. Async
 * because the await is genuine; callers don't have to await unless
 * ordering matters.
 *
 * The pendingExits map on the handle is keyed by the outer `element`
 * (the one the caller wants to remove) so the each_live reconciler
 * can find a pending exit by the same handle it has, even when the
 * Transition attrs live one level down.
 */
async function removeWithTransition(handle, parent, element, onComplete) {
  const transitionElement = findTransitionElement(element);

  if (!transitionElement) {
    if (element.parentNode === parent) parent.removeChild(element);
    onComplete();
    return;
  }

  const exitClass = transitionElement.dataset.lilyTransitionExit;
  const durationMs =
    parseInt(transitionElement.dataset.lilyTransitionDuration ?? "0", 10) || 0;
  const controller = new AbortController();
  handle.registerPendingExit(element, controller);

  transitionElement.classList.add(exitClass);

  // Race animationend (the user's CSS finishing) vs the duration timer
  // (fallback for headless test environments and CSS that doesn't
  // animate). Abort short-circuits both.
  await new Promise((resolve) => {
    const cleanup = () => {
      transitionElement.removeEventListener("animationend", onAnimationEnd);
      controller.signal.removeEventListener("abort", onAbort);
      clearTimeout(timer);
    };
    const onAnimationEnd = () => {
      cleanup();
      resolve();
    };
    const onAbort = () => {
      cleanup();
      resolve();
    };
    const timer = setTimeout(() => {
      cleanup();
      resolve();
    }, durationMs);
    transitionElement.addEventListener("animationend", onAnimationEnd, {
      once: true,
    });
    controller.signal.addEventListener("abort", onAbort, { once: true });
  });

  if (controller.signal.aborted) {
    // Re-add mid-exit cancelled us. Strip the exit class so the
    // element looks normal again.
    transitionElement.classList.remove(exitClass);
    return;
  }

  handle.clearPendingExit(element);
  if (element.parentNode === parent) parent.removeChild(element);
  onComplete();
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// Constructors are opaque in the public API, so instanceof doesn't work,
// dispatching on the constructor name is the next best thing. The type
// definition in component.gleam is the source of truth for these names.
const RENDERERS = {
  Each: renderEach,
  EachLive: renderEachLive,
  Fragment: renderFragment,
  Live: renderLive,
  Simple: renderSimple,
  Static: renderStatic,
  Switch: renderSwitch,
};

// Regex matching a single `<lily-slot></lily-slot>` placeholder (with
// optional whitespace). Used by substituteSlots; passed to String.split,
// which always splits globally regardless of the `g` flag.
const SLOT_RE = /<lily-slot[^>]*>\s*<\/lily-slot>/;
