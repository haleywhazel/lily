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

  handle.resetComponentCounter();
  handle.clearRegistry();

  const html = renderComponent(handle, component, model, toHtml, toSlot);

  handle.setInnerHtml(rootSelector, html);

  // Trigger all component handlers to populate dynamic content
  for (const handler of handle.getComponentRegistry().values()) {
    handler(model);
  }

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

        const { html, newIds } = renderChildAndCaptureIds(
          handle,
          render(item),
          model,
          toHtml,
          toSlot,
        );
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
        // Only call initial() for this specific new item, not the whole list
        const { html, newIds } = renderChildAndCaptureIds(
          handle,
          initial(item),
          model,
          toHtml,
          toSlot,
        );
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

    // Drop children whose keys are no longer in the list.
    for (const [keyStr, element] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(element);
        children.delete(keyStr);
        onDrop(keyStr);
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

/** Renders a general `Component` (irrespective of specific variant) */
function renderComponent(handle, component, model, toHtml, toSlot) {
  const typeName = component.constructor.name;
  const render = RENDERERS[typeName];
  if (!render) {
    console.error("Unknown component variant:", typeName, component);
    return "";
  }
  return render(handle, component, model, toHtml, toSlot);
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

/** Renders a component wrapped in RequireConnection */
function renderRequireConnection(handle, component, model, toHtml, toSlot) {
  const componentId = handle.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { inner, connected } = component;

  const innerHtml = renderComponent(handle, inner, model, toHtml, toSlot);

  let cachedElement = null;

  const handler = createSelective(connected, referenceEqual, (isConnected) => {
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
  });

  // Register handler to be called on model updates
  handle.registerComponent(componentId, handler);

  return `<div data-lily-component="${componentId}">${innerHtml}</div>`;
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
  RequireConnection: renderRequireConnection,
  Simple: renderSimple,
  Static: renderStatic,
};

// Regex matching a single `<lily-slot></lily-slot>` placeholder (with
// optional whitespace). Used by substituteSlots; passed to String.split,
// which always splits globally regardless of the `g` flag.
const SLOT_RE = /<lily-slot[^>]*>\s*<\/lily-slot>/;
