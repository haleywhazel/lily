/**
 * COMPONENT TREE RENDERING
 *
 * Renders the Component tree to the DOM. Each component makes a selective
 * handler tracking its slice. renderTree builds the HTML skeleton, then fires
 * the handlers to begin live updates.
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

/**
 * Identity, backs `to_dynamic` and `list_dynamic`. Keeps slice values opaque
 * in the public API while the runtime treats them as plain JS values.
 */
export function identity(value) {
  return value;
}

export function renderTree(runtime, rootSelector, component, model, toHtml, toSlot) {
  const handle = runtime.handle;

  // Binding closures take a Runtime not just a handle, so stash it for
  // renderDecorated. Idempotent, the same runtime drives every mount.
  handle.setRuntime(runtime);

  // Mount segment keyed by selector. Tears down the prior segment for the
  // same selector (re-mounts replace) while leaving other mount points
  // alone, which is what makes overlay-style portals work. Component IDs
  // keep counting across mounts, only the segment is selector-scoped.
  handle.startMountSegment(rootSelector);

  const html = renderComponent(handle, component, model, toHtml, toSlot);

  handle.setInnerHtml(rootSelector, html);

  // Trigger only this mount's handlers, not the global registry, else a
  // second mount re-fires every prior tree's handlers (idempotent but
  // wasteful). Handlers run before bindings drain because the first
  // `simple` / `switch` handler wraps innerHTML on its root, wiping any
  // element-scoped listener on the prior subtree. Stabilising the DOM
  // first means bindings attach to the final tree.
  const segmentIds = handle.endMountSegment();
  const registry = handle.getComponentRegistry();
  for (const id of segmentIds) {
    const handler = registry.get(id);
    if (handler) handler(model);
  }

  // Bindings queued during renderComponent (every Decorated with bindings,
  // including via slot children). Fire them now the DOM has stabilised so
  // element-scoped listeners attach to the post-handler subtree.
  handle.drainBindings();

  return null;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/**
 * Layer a component's decorations onto its rendered HTML, folded
 * innermost-first so the last wraps outermost (as the constructors append).
 *
 *  - `Listener`: queues the binding to fire after renderTree's innerHTML
 *    pass, no element of its own.
 *  - `Transition`: wraps in a marker div carrying the enter class (scheduled
 *    for removal) plus the exit class and duration as data attributes for
 *    removeWithTransition.
 *  - `Connection`: wraps in a div whose disabled / aria-disabled /
 *    lily-disconnected state tracks the connection predicate.
 */
function applyDecorations(handle, decorations, html, model) {
  const runtime = handle.getRuntime();
  // Reverse to apply in attach order (add_decoration prepends)
  for (const decoration of decorations.toArray().reverse()) {
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
          `data-lily-transition-exit="${escapeAttribute(exit)}" ` +
          `data-lily-transition-duration="${durationMs}" ` +
          `class="${escapeAttribute(enter)}">${html}</div>`;
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

/**
 * Cancel a pending exit on `node` and strip its stored exit class in place.
 * Used when a mid-exit wrapper is re-added, the synchronous strip lets a
 * following DOM read see the cleaned-up element (removeWithTransition's abort
 * strips it too, but only as a later microtask).
 */
function cancelExitAndStripClass(handle, node) {
  handle.cancelPendingExit(node);
  const transitionElement = findTransitionElement(node);
  const exitClass = transitionElement?.dataset.lilyTransitionExit;
  if (exitClass) transitionElement.classList.remove(exitClass);
}

/** Handler for `component.each`. */
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
      // Compare the slice item not the rendered Component, Components may hold
      // function fields (e.g. nested each) that never compare structurally.
      // Re-rendering replaces innerHTML, so previously-registered child
      // handlers for this key now point at detached nodes, release and
      // re-register them.
      const previousItem = previousItemByKey.get(keyStr);
      const itemChanged =
        previousItem === undefined || !compare(previousItem, item);

      if (itemChanged) {
        previousItemByKey.set(keyStr, item);
        const oldIds = childIdsByKey.get(keyStr);
        if (oldIds) unregisterChildHandlers(handle, oldIds);

        // Bindings inside the item body are ignored (documented placement
        // rule). Attach per-list events on the each component or an ancestor.
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

/**
 * Shared shell for keyed-list handlers (`component.each`). Owns the children
 * Map, the slice-reference short-circuit, the dropped-keys diff, and the
 * per-item positioning loop.
 *
 * `onDrop(keyStr)` runs after a child leaves the DOM, to release per-key
 * state. `onItem` runs once per item and decides whether to render, patch, or
 * do nothing.
 */
function createKeyedListHandler({ handle, selector, slice, getKey, onDrop, onItem }) {
  const children = new Map();
  let cachedContainer = null;
  let previousList = null;

  return function (model) {
    // Same slice reference, nothing in the list could have changed.
    const list = slice(model);
    if (list === previousList) return;
    previousList = list;

    cachedContainer = ensureCached(cachedContainer, selector);
    const container = cachedContainer;
    if (!container) return;

    // Compute each key once and reuse it in the main loop below.
    const items = list.toArray();
    const keys = items.map(getKey);
    const currentKeySet = new Set(keys);

    // Drop children whose keys left the list. A child with transition attrs
    // defers removal via removeWithTransition until the exit animation
    // completes (or aborts if the same key reappears mid-exit).
    for (const [keyStr, element] of children) {
      if (!currentKeySet.has(keyStr)) {
        // Skip if already mid-exit, the in-flight removeWithTransition tears
        // it down. Without this a second render mid-duration starts a
        // duplicate timer.
        if (handle.getPendingExit(element)) continue;
        removeWithTransition(handle, container, element, () => {
          children.delete(keyStr);
          onDrop(keyStr);
        });
      }
    }

    // Cache the live HTMLCollection once to skip a per-iteration lookup on
    // `container`. It updates as we `insertBefore`, so live semantics hold.
    const liveChildren = container.children;

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const keyStr = keys[i];

      let element = children.get(keyStr);
      const isNew = !element;
      if (isNew) {
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        children.set(keyStr, element);
      } else if (handle.getPendingExit(element)) {
        // Re-added mid-exit, cancel the pending removal and strip the exit
        // class synchronously.
        cancelExitAndStripClass(handle, element);
      }

      onItem({
        handle,
        container,
        liveChildren,
        item,
        keyStr,
        element,
        isNew,
        index: i,
        model,
      });
    }
  };
}

/**
 * `cached` if still in the document, else re-query `selector`. Handlers cache
 * their root to skip a querySelector per update, the re-query path handles
 * re-mounts after detachment.
 */
function ensureCached(cached, selector) {
  return cached && cached.isConnected
    ? cached
    : document.querySelector(selector);
}

/**
 * Escape a value for a double-quoted HTML attribute. Transition classes are
 * usually static literals, but an app could derive them from the model, so
 * escape characters that could break out of the attribute or inject markup.
 */
function escapeAttribute(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/**
 * The Transition wrapper at or just inside `element`. As the top-level
 * component of an each item, a key wrapper (`<div data-lily-key>`) sits above
 * it, for `simple` the morph wrapper does. Null when there's no Transition
 * (removal then proceeds synchronously).
 */
function findTransitionElement(element) {
  if (element.dataset?.lilyTransitionExit) return element;
  const child = element.firstElementChild;
  if (child?.dataset?.lilyTransitionExit) return child;
  return null;
}

/** True for a wrapper the runtime owns (a component root or list-item key). */
function isComponentWrapper(node) {
  return (
    node.nodeType === 1 &&
    (node.hasAttribute("data-lily-component") ||
      node.hasAttribute("data-lily-key"))
  );
}

/**
 * Build a slotter, called inline in a content function to place a child
 * component. Each call records the component and returns a placeholder html
 * value (via toSlot). Call order equals DOM position order under strict Gleam
 * evaluation.
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
 * Reconcile `live`'s children in place to match `next`, preserving nodes so
 * focus, animation, typed input, and nested reactive children survive.
 * Runtime-owned wrappers (data-lily-component / data-lily-key) are opaque,
 * matched positionally and left to their own handler, a removed one has its
 * subtree handlers unregistered. Everything else morphs by tag then attributes
 * then children.
 */
function morph(handle, live, next) {
  let liveNode = live.firstChild;
  let nextNode = next.firstChild;

  while (nextNode) {
    const nextAfter = nextNode.nextSibling;

    if (!liveNode) {
      live.appendChild(nextNode.cloneNode(true));
      nextNode = nextAfter;
      continue;
    }

    const liveOwned = isComponentWrapper(liveNode);
    const nextOwned = isComponentWrapper(nextNode);

    if (liveOwned && nextOwned) {
      // Both runtime-owned, keep the live one intact (opaque). If it was
      // mid-exit (re-added before its close animation finished), cancel it.
      if (handle.getPendingExit(liveNode)) {
        cancelExitAndStripClass(handle, liveNode);
      }
      liveNode = liveNode.nextSibling;
      nextNode = nextAfter;
    } else if (nextOwned) {
      live.insertBefore(nextNode.cloneNode(true), liveNode);
      nextNode = nextAfter;
    } else if (liveOwned) {
      const gone = liveNode;
      liveNode = liveNode.nextSibling;
      removeMorphChild(handle, live, gone);
    } else if (
      liveNode.nodeType === 1 &&
      nextNode.nodeType === 1 &&
      liveNode.tagName === nextNode.tagName
    ) {
      morphAttributes(liveNode, nextNode);
      morph(handle, liveNode, nextNode);
      liveNode = liveNode.nextSibling;
      nextNode = nextAfter;
    } else if (liveNode.nodeType === 3 && nextNode.nodeType === 3) {
      if (liveNode.nodeValue !== nextNode.nodeValue) {
        liveNode.nodeValue = nextNode.nodeValue;
      }
      liveNode = liveNode.nextSibling;
      nextNode = nextAfter;
    } else {
      const replaced = liveNode;
      liveNode = liveNode.nextSibling;
      if (isComponentWrapper(replaced)) unregisterSubtree(handle, replaced);
      live.replaceChild(nextNode.cloneNode(true), replaced);
      nextNode = nextAfter;
    }
  }

  while (liveNode) {
    const gone = liveNode;
    liveNode = liveNode.nextSibling;
    removeMorphChild(handle, live, gone);
  }
}

/** Copy `next`'s attributes onto `live`, dropping any `live` no longer has. */
function morphAttributes(live, next) {
  for (const { name, value } of Array.from(next.attributes)) {
    if (live.getAttribute(name) !== value) live.setAttribute(name, value);
  }
  for (const { name } of Array.from(live.attributes)) {
    if (!next.hasAttribute(name)) live.removeAttribute(name);
  }
}

/** Largest value in ms from a CSS time list ("0.22s, 100ms"). */
function parseCssDurationMs(value) {
  let max = 0;
  for (const part of String(value).split(",")) {
    const text = part.trim();
    let ms = 0;
    if (text.endsWith("ms")) ms = parseFloat(text);
    else if (text.endsWith("s")) ms = parseFloat(text) * 1000;
    if (Number.isFinite(ms) && ms > max) max = ms;
  }
  return max;
}

/**
 * Remove a morphed-away child. A managed wrapper carrying an exit transition
 * defers removal through removeWithTransition (skipping if already exiting) so
 * its close animation runs, otherwise it goes immediately. Unregisters the
 * subtree's handlers.
 */
function removeMorphChild(handle, parent, node) {
  if (isComponentWrapper(node)) {
    if (handle.getPendingExit(node)) return;
    if (findTransitionElement(node)) {
      removeWithTransition(handle, parent, node, () =>
        unregisterSubtree(handle, node),
      );
      return;
    }
    unregisterSubtree(handle, node);
  }
  if (node.parentNode === parent) parent.removeChild(node);
}

/**
 * Transition-aware removal of `element` from `parent`. With a Transition
 * wrapper (own or first child's dataset attrs) it applies the exit class,
 * races animationend vs the duration timer, then removes and calls
 * `onComplete`. Otherwise removes immediately. Callers await only if ordering
 * matters.
 *
 * pendingExits is keyed by the outer `element` so the each reconciler can find
 * a pending exit by the handle it has, even when the Transition attrs live one
 * level down.
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

  // Race animationend (CSS finishing) vs the duration timer (fallback for
  // headless tests and non-animating CSS). Abort short-circuits both.
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
    }, transitionHoldMs(transitionElement, durationMs));
    transitionElement.addEventListener("animationend", onAnimationEnd, {
      once: true,
    });
    controller.signal.addEventListener("abort", onAbort, { once: true });
  });

  if (controller.signal.aborted) {
    // Re-add mid-exit cancelled us. Strip the exit class back off.
    transitionElement.classList.remove(exitClass);
    return;
  }

  handle.clearPendingExit(element);
  if (element.parentNode === parent) parent.removeChild(element);
  onComplete();
}

/**
 * Render a child component, capturing the component IDs registered as a side
 * effect. Returns the HTML and the new IDs so the caller can run their
 * handlers and track them for cleanup on parent removal or re-render.
 */
function renderChildAndCaptureIds(handle, child, model, toHtml, toSlot) {
  const newIds = handle.beginIdCapture();
  try {
    const html = renderComponent(handle, child, model, toHtml, toSlot);
    return { html, newIds };
  } finally {
    handle.endIdCapture();
  }
}

/**
 * Render a `Component`. Dispatch on `component_type` for the inner HTML, then
 * layer its `decorations` (transition, connection gate, listeners) on top.
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

/** Renders an Each component */
function renderEach(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, key, render } = component;

  const handler = createEachHandler(
    handle,
    selector,
    slice,
    key,
    render,
    toHtml,
    toSlot,
    isEqual,
  );

  handle.registerComponent(componentId, handler);

  // Empty container, the handler populates it
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

  const { slice, initial, apply } = component;

  // Initial HTML with slot substitution. Children registered here persist for
  // the live component's lifetime, never unregistered between patch updates.
  const { html: initialHtml, ids: childIds } = renderWithSlots(
    handle,
    model,
    toHtml,
    toSlot,
    initial,
  );

  let cachedElement = null;

  const handler = createSelective(slice, isEqual, (data) => {
    const patches = apply(data).toArray();

    cachedElement = ensureCached(cachedElement, selector);
    if (cachedElement) {
      applyPatchesToElement(cachedElement, patches);
    }
  });

  handle.registerComponent(componentId, handler);

  // Fire child handlers only if this element is already live in the DOM.
  if (childIds.length > 0 && document.querySelector(selector)) {
    runChildHandlers(handle, childIds, model);
  }

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Simple component */
function renderSimple(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, render } = component;

  let cachedElement = null;

  const handler = createSelective(slice, isEqual, (data) => {
    // Re-render own markup with slot children, then morph onto the live
    // subtree. Existing child wrappers are preserved (their own handler owns
    // them), so freshly-rendered duplicates are discarded by the morph, swept
    // from the registry below. Genuinely new slots land in the DOM, run their
    // handlers and drain bindings.
    const { html, ids: newChildIds } = renderWithSlots(
      handle,
      model,
      toHtml,
      toSlot,
      (slot) => render(data, slot),
    );

    cachedElement = ensureCached(cachedElement, selector);
    if (!cachedElement) return;

    const template = document.createElement("template");
    template.innerHTML = html;
    morph(handle, cachedElement, template.content);

    const registry = handle.getComponentRegistry();
    for (const id of newChildIds) {
      const kept = cachedElement.querySelector(
        `[data-lily-component="${id}"]`,
      );
      if (kept) {
        const childHandler = registry.get(id);
        if (childHandler) childHandler(model);
      } else {
        handle.unregisterComponent(id);
      }
    }
    handle.drainBindings();
  });

  handle.registerComponent(componentId, handler);

  // Children registered here are run at mount by renderTree and preserved
  // across updates by the morph above.
  const { html: initialHtml } = renderWithSlots(
    handle,
    model,
    toHtml,
    toSlot,
    (slot) => render(slice(model), slot),
  );

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Static component */
function renderStatic(handle, component, model, toHtml, toSlot) {
  const { html } = renderWithSlots(
    handle,
    model,
    toHtml,
    toSlot,
    component.content,
  );
  return html;
}

/**
 * Render a content function that may place child components via slot(). Builds
 * the slotter, runs `produce(slot)` through toHtml, then substitutes the
 * collected children back into their placeholders. Returns { html, ids }, the
 * ids being every child component registered during the render.
 */
function renderWithSlots(handle, model, toHtml, toSlot, produce) {
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(produce(slot));
  return substituteSlots(rawHtml, collected, handle, model, toHtml, toSlot);
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
 * Remove the enter class once the enter animation finishes, so it plays to
 * completion. Waits a frame for the element to mount and commit, then strips
 * the class on `animationend` (guarding bubbling child animations), with a
 * duration-sized timer fallback for CSS/environments where it never fires.
 * Stripping only after completion is what lets enter animations (a menu
 * sliding down) actually run.
 */
function scheduleEnterClassRemoval(selector, enterClass, durationMs) {
  const arm = () => {
    const element = document.querySelector(selector);
    if (!element) {
      setTimeout(() => {
        const later = document.querySelector(selector);
        if (later) later.classList.remove(enterClass);
      }, durationMs);
      return;
    }
    let done = false;
    const finish = (event) => {
      if (event && event.target !== element) return;
      if (done) return;
      done = true;
      element.removeEventListener("animationend", finish);
      element.classList.remove(enterClass);
    };
    element.addEventListener("animationend", finish);
    setTimeout(finish, transitionHoldMs(element, durationMs));
  };
  // Defer a frame so the element is mounted and its animation has committed
  // before we attach the listener.
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(arm);
  else setTimeout(arm, 0);
}

/**
 * Replace each `<lily-slot>` marker in order with the rendered HTML of the
 * corresponding collected child. Returns the substituted HTML and a flat list
 * of all child component IDs registered during this call.
 *
 * Splits on every placeholder in one pass, then interleaves segments with
 * children. More children than placeholders (a dropped slot return value)
 * logs an error and unregisters the orphans so their handlers don't dangle.
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

  // Append trailing segments past the matched-children count. Reachable only
  // when the template has more placeholders than children passed, those extra
  // slots are dropped from output.
  for (let i = collected.length + 1; i < segments.length; i++) {
    html += segments[i];
  }

  return { html, ids: allIds };
}

/**
 * How long to hold a transitioning element before removing it or stripping its
 * enter class. The computed animation duration plus a small buffer, so timing
 * tracks theme.motion() automatically. Falls back to the declared duration
 * when the environment can't compute one (headless tests, non-animating CSS).
 */
function transitionHoldMs(element, fallbackMs) {
  if (typeof getComputedStyle === "function") {
    const computed = parseCssDurationMs(
      getComputedStyle(element).animationDuration ?? "0s",
    );
    if (computed > 0) return computed + 60;
  }
  return fallbackMs;
}

/** Unregisters every id in `ids` from the runtime registry. */
function unregisterChildHandlers(handle, ids) {
  for (const id of ids) {
    handle.unregisterComponent(id);
  }
}

/** Unregister every component handler in `element`'s subtree and itself. */
function unregisterSubtree(handle, element) {
  if (element.nodeType !== 1) return;
  const own = element.getAttribute("data-lily-component");
  if (own) handle.unregisterComponent(own);
  for (const wrapper of element.querySelectorAll("[data-lily-component]")) {
    handle.unregisterComponent(wrapper.getAttribute("data-lily-component"));
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// Constructors are opaque in the public API, so instanceof doesn't work,
// dispatching on the constructor name is the next best thing. The type
// definition in component.gleam is the source of truth for these names.
const RENDERERS = {
  Each: renderEach,
  Fragment: renderFragment,
  Live: renderLive,
  Simple: renderSimple,
  Static: renderStatic,
};

// Regex matching a single `<lily-slot></lily-slot>` placeholder (with
// optional whitespace). Used by substituteSlots, passed to String.split,
// which always splits globally regardless of the `g` flag.
const SLOT_RE = /<lily-slot[^>]*>\s*<\/lily-slot>/;
