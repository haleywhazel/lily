/**
 * COMPONENT TREE RENDERING
 *
 * This mjs file handles traversing the Component tree and rendering it to the
 * DOM. Components create their own selective handlers that track slice changes.
 *
 * When renderTree is called on root mount, the HTML skeleton is generated, and
 * and the render function for each component is called – this is when the
 * handlers get created. Each handler is then triggered at the end of the
 * `renderTree` function, beginning live component updates.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { applyPatchesToElement, referenceEqual } from "./client.ffi.mjs";
import { isEqual } from "../gleam.mjs";
import { StructuralEqual } from "./component.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/**
 * Get the model from the runtime
 */
export function getModel(runtime) {
  return runtime.handle.getModel();
}

/**
 * Identity function, used as `to_dynamic` in the Gleam file. Workaround to
 * ensure that the public API still allows the slice listened to by each
 * component to remain Dynamic.
 */
export function identity(value) {
  return value;
}

export function renderTree(
  runtime,
  rootSelector,
  component,
  model,
  toHtml,
  toSlot,
  store,
  depth,
) {
  const handle = runtime.handle;

  // Reset state on root render
  if (depth === 0) {
    handle.resetComponentCounter();
    handle.clearRegistry();
  }

  const html = renderComponent(
    handle,
    component,
    model,
    toHtml,
    toSlot,
    store,
    rootSelector,
    depth,
  );

  // Only set innerHTML and trigger handlers at the root
  if (depth === 0) {
    handle.setInnerHtml(rootSelector, html);

    // Trigger all component handlers to populate dynamic content
    for (const handler of handle.getComponentRegistry().values()) {
      handler(model);
    }
  }

  return null;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/**
 * Renders a child component, capturing any new component IDs that get
 * registered as a side effect. Returns the HTML string and the array of new
 * IDs so the caller can run their handlers immediately and track them for
 * cleanup when the parent item is removed or re-rendered.
 */
function renderChildAndCaptureIds(
  runtime,
  child,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const registry = runtime.getComponentRegistry();
  const beforeKeys = new Set(registry.keys());
  const html = renderComponent(
    runtime,
    child,
    model,
    toHtml,
    toSlot,
    store,
    parentSelector,
    depth + 1,
  );
  const newIds = [];
  for (const k of registry.keys()) {
    if (!beforeKeys.has(k)) newIds.push(k);
  }
  return { html, newIds };
}

/** Runs each handler in `ids` once with the current model to populate. */
function runChildHandlers(runtime, ids, model) {
  const registry = runtime.getComponentRegistry();
  for (const id of ids) {
    const handler = registry.get(id);
    if (handler) handler(model);
  }
}

/** Unregisters every id in `ids` from the runtime registry. */
function unregisterChildHandlers(runtime, ids) {
  for (const id of ids) {
    runtime.unregisterComponent(id);
  }
}

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
 * Regex matching a single `<lily-slot></lily-slot>` placeholder (with optional
 * whitespace). Used by substituteSlots; replace one at a time (first match).
 */
const SLOT_RE = /<lily-slot[^>]*>\s*<\/lily-slot>/;

/**
 * After calling the user's content function and serialising to HTML, replace
 * each `<lily-slot>` marker in order with the rendered HTML of the
 * corresponding collected child component. Returns the substituted HTML string
 * and a flat list of all child component IDs registered during this call.
 */
function substituteSlots(
  parentHtml,
  collected,
  runtime,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const allIds = [];
  let html = parentHtml;
  for (const component of collected) {
    const { html: childHtml, newIds } = renderChildAndCaptureIds(
      runtime,
      component,
      model,
      toHtml,
      toSlot,
      store,
      parentSelector,
      depth,
    );
    allIds.push(...newIds);
    if (!SLOT_RE.test(html)) {
      console.error(
        "lily: <lily-slot> placeholder missing from rendered HTML — child component dropped. " +
          "Make sure slot() return values are placed in the template.",
      );
      unregisterChildHandlers(runtime, newIds);
      continue;
    }
    html = html.replace(SLOT_RE, childHtml); // replaces first match only
  }
  return { html, ids: allIds };
}

/** Create handler for `component.each` (returns the handler function) */
function createEachHandler(
  runtime,
  selector,
  slice,
  getKey,
  render,
  toHtml,
  toSlot,
  store,
  depth,
  compare,
) {
  const children = new Map();
  const previousItemByKey = new Map();
  const childIdsByKey = new Map();
  let cachedContainer = null;

  return function (model) {
    // Re-query only if detached (handles re-mounts, not run normally)
    if (!cachedContainer || !cachedContainer.isConnected) {
      cachedContainer = document.querySelector(selector);
    }

    const container = cachedContainer;
    if (!container) return;

    const items = slice(model).toArray();
    const currentKeySet = new Set(items.map((item) => getKey(item)));

    // Drop children whose keys are no longer in the list and release their
    // child component handlers from the runtime registry.
    for (const [keyStr, child] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(child);
        children.delete(keyStr);
        previousItemByKey.delete(keyStr);
        const oldIds = childIdsByKey.get(keyStr);
        if (oldIds) unregisterChildHandlers(runtime, oldIds);
        childIdsByKey.delete(keyStr);
      }
    }

    // Sync children (create, update, and reorder in one pass)
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const keyStr = getKey(item);

      // Look up or create the element for this key
      let element = children.get(keyStr);
      if (!element) {
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        children.set(keyStr, element);
      }

      // Compare the slice item (not the rendered Component) — Components may
      // contain function fields (e.g. nested each_live) that never compare
      // structurally. The slice item is the user's source of truth.
      // Re-rendering replaces innerHTML, so any previously-registered child
      // component handlers for this key are now pointing at detached nodes —
      // release them and register the new ones.
      const previousItem = previousItemByKey.get(keyStr);
      if (previousItem === undefined || !compare(previousItem, item)) {
        previousItemByKey.set(keyStr, item);
        const oldIds = childIdsByKey.get(keyStr);
        if (oldIds) unregisterChildHandlers(runtime, oldIds);

        const childSelector = `[data-lily-key="${keyStr}"]`;
        const { html, newIds } = renderChildAndCaptureIds(
          runtime,
          render(item),
          model,
          toHtml,
          toSlot,
          store,
          childSelector,
          depth,
        );
        element.innerHTML = html;
        childIdsByKey.set(keyStr, newIds);
        // Slot into position before running child handlers so their queries
        // find the freshly-inserted DOM.
        const currentAtIndex = container.children[i];
        if (currentAtIndex !== element) {
          container.insertBefore(element, currentAtIndex || null);
        }
        runChildHandlers(runtime, newIds, model);
      } else {
        // Slot into the right position if it's drifted
        const currentAtIndex = container.children[i];
        if (currentAtIndex !== element) {
          container.insertBefore(element, currentAtIndex || null);
        }
      }
    }
  };
}

/** Create handler for `component.each_live` (returns the handler function) */
function createEachLiveHandler(
  runtime,
  selector,
  slice,
  getKey,
  initial,
  patch,
  toHtml,
  toSlot,
  store,
  depth,
  compare,
) {
  const children = new Map();
  let previousPatchesByKey = new Map();
  const childIdsByKey = new Map();
  let cachedContainer = null;

  return function (model) {
    // Re-query only if detached (handles re-mounts, not run normally)
    if (!cachedContainer || !cachedContainer.isConnected) {
      cachedContainer = document.querySelector(selector);
    }
    const container = cachedContainer;
    if (!container) return;

    const items = slice(model).toArray();
    const currentKeySet = new Set(items.map((item) => getKey(item)));

    // Drop children whose keys are no longer in the list and release their
    // child component handlers.
    for (const [keyStr, element] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(element);
        children.delete(keyStr);
        previousPatchesByKey.delete(keyStr);
        const oldIds = childIdsByKey.get(keyStr);
        if (oldIds) unregisterChildHandlers(runtime, oldIds);
        childIdsByKey.delete(keyStr);
      }
    }

    // Track new IDs to kick after positioning, so that querying inside child
    // handlers finds the inserted DOM.
    const newlyCreated = [];

    // Sync children (create, update, and reorder in one pass)
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const keyStr = getKey(item);

      // Look up or create the element for this key
      let element = children.get(keyStr);
      if (!element) {
        // Only call initial() for this specific new item — not the whole list
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        const childSelector = `[data-lily-key="${keyStr}"]`;
        const { html, newIds } = renderChildAndCaptureIds(
          runtime,
          initial(item),
          model,
          toHtml,
          toSlot,
          store,
          childSelector,
          depth,
        );
        element.innerHTML = html;
        childIdsByKey.set(keyStr, newIds);
        children.set(keyStr, element);
        newlyCreated.push(newIds);
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
      const currentAtIndex = container.children[i];
      if (currentAtIndex !== element) {
        container.insertBefore(element, currentAtIndex || null);
      }
    }

    // Kick handlers for newly-created items after all positioning is done
    for (const newIds of newlyCreated) {
      runChildHandlers(runtime, newIds, model);
    }
  };
}

/** Renders a general `Component` (irrespective of specific variant) */
function renderComponent(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const typeName = component.constructor.name;

  // Constructors are opaque in the public API, so instanceof doesn't work —
  // string matching on the constructor name is the next best thing. Maybe this
  // should be changed but it works for now, we're prioritising the cleanliness
  // of the public API.
  switch (typeName) {
    case "Static":
      return renderStatic(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    case "Simple":
      return renderSimple(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    case "Live":
      return renderLive(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    case "Each":
      return renderEach(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    case "EachLive":
      return renderEachLive(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    case "Fragment":
      return renderFragment(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    case "RequireConnection":
      return renderRequireConnection(
        runtime,
        component,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth,
      );
    default:
      console.error("Unknown component variant:", typeName, component);
      return "";
  }
}

/** Renders an Each component */
function renderEach(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const componentId = runtime.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, key, render, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  const handler = createEachHandler(
    runtime,
    selector,
    slice,
    key,
    render,
    toHtml,
    toSlot,
    store,
    depth,
    compareStrategy,
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Render empty container — handler will populate it
  return `<div data-lily-component="${componentId}"></div>`;
}

/** Renders an EachLive component */
function renderEachLive(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const componentId = runtime.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, key, initial, patch, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  const handler = createEachLiveHandler(
    runtime,
    selector,
    slice,
    key,
    initial,
    patch,
    toHtml,
    toSlot,
    store,
    depth,
    compareStrategy,
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Render empty container — handler will populate it
  return `<div data-lily-component="${componentId}"></div>`;
}

/** Renders a Fragment component */
function renderFragment(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  return component.children
    .toArray()
    .map((child) =>
      renderComponent(
        runtime,
        child,
        model,
        toHtml,
        toSlot,
        store,
        parentSelector,
        depth + 1,
      ),
    )
    .join("");
}

/** Renders a Live component */
function renderLive(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const componentId = runtime.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, initial, apply, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  // Build the initial HTML with slot substitution. Children registered here
  // persist for the lifetime of this live component — they are never
  // unregistered between patch updates.
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(initial(slot));
  const { html: initialHtml, ids: childIds } = substituteSlots(
    rawHtml,
    collected,
    runtime,
    model,
    toHtml,
    toSlot,
    store,
    selector,
    depth + 1,
  );

  let cachedElement = null;

  const handler = runtime.createSelective(
    selector,
    slice,
    compareStrategy,
    (data) => {
      const patches = apply(data).toArray();

      // Re-query only if detached (handles re-mounts, not run normally)
      if (!cachedElement || !cachedElement.isConnected) {
        cachedElement = document.querySelector(selector);
      }
      if (cachedElement) {
        applyPatchesToElement(cachedElement, patches);
      }
    },
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Run child handlers after registering this component's own handler so
  // the registry order is parent-first.
  if (childIds.length > 0) {
    runChildHandlers(runtime, childIds, model);
  }

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a component wrapped in RequireConnection */
function renderRequireConnection(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const componentId = runtime.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { inner, connected } = component;

  const innerHtml = renderComponent(
    runtime,
    inner,
    model,
    toHtml,
    toSlot,
    store,
    selector,
    depth + 1,
  );

  let cachedElement = null;

  const handler = runtime.createSelective(
    selector,
    connected,
    runtime.referenceEqual,
    (isConnected) => {
      // Re-query only if detached (handles re-mounts, not run normally)
      if (!cachedElement || !cachedElement.isConnected) {
        cachedElement = document.querySelector(selector);
      }
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

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  return `<div data-lily-component="${componentId}">${innerHtml}</div>`;
}

/** Renders a Simple component */
function renderSimple(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const componentId = runtime.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, render, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  let cachedElement = null;
  let previousChildIds = [];

  const handler = runtime.createSelective(
    selector,
    slice,
    compareStrategy,
    (data) => {
      // Unregister previous child handlers before re-rendering
      unregisterChildHandlers(runtime, previousChildIds);

      const { slot, collected } = makeSlotter(toSlot);
      const rawHtml = toHtml(render(data, slot));
      const { html, ids: newChildIds } = substituteSlots(
        rawHtml,
        collected,
        runtime,
        model,
        toHtml,
        toSlot,
        store,
        selector,
        depth + 1,
      );
      previousChildIds = newChildIds;

      // Re-query only if detached (handles re-mounts, not run normally)
      if (!cachedElement || !cachedElement.isConnected) {
        cachedElement = document.querySelector(selector);
      }
      if (cachedElement) {
        cachedElement.innerHTML = html;
        // Run child handlers after innerHTML is set so their selectors find DOM
        runChildHandlers(runtime, newChildIds, model);
      }
    },
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Initial render
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(render(slice(model), slot));
  const { html: initialHtml, ids: childIds } = substituteSlots(
    rawHtml,
    collected,
    runtime,
    model,
    toHtml,
    toSlot,
    store,
    selector,
    depth + 1,
  );
  previousChildIds = childIds;

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Static component */
function renderStatic(
  runtime,
  component,
  model,
  toHtml,
  toSlot,
  store,
  parentSelector,
  depth,
) {
  const { slot, collected } = makeSlotter(toSlot);
  const rawHtml = toHtml(component.content(slot));
  if (collected.length === 0) return rawHtml;

  const { html } = substituteSlots(
    rawHtml,
    collected,
    runtime,
    model,
    toHtml,
    toSlot,
    store,
    parentSelector,
    depth + 1,
  );
  return html;
}
