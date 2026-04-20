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

/** Create handler for `component.each` (returns the handler function) */
function createEachHandler(selector, slice, getKey, render, toHtml, compare) {
  const children = new Map();
  let previousHtmlByKey = new Map();
  let cachedContainer = null;

  return function (model) {
    // Re-query only if detached — handles re-mounts, free in the normal case
    if (!cachedContainer || !cachedContainer.isConnected) {
      cachedContainer = document.querySelector(selector);
    }
    const container = cachedContainer;
    if (!container) return;

    const items = slice(model).toArray();
    const currentKeySet = new Set(items.map((item) => getKey(item)));

    // Drop children whose keys are no longer in the list
    for (const [keyStr, child] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(child);
        children.delete(keyStr);
        previousHtmlByKey.delete(keyStr);
      }
    }

    // Sync children — create, update, and reorder in one pass
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const keyStr = getKey(item);
      const htmlValue = render(item);

      // Look up or create the element for this key
      let element = children.get(keyStr);
      if (!element) {
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        children.set(keyStr, element);
      }

      // Only re-render if the content changed (respects compare strategy)
      const previousHtml = previousHtmlByKey.get(keyStr);
      if (previousHtml === undefined || !compare(previousHtml, htmlValue)) {
        previousHtmlByKey.set(keyStr, htmlValue);
        element.innerHTML = toHtml(htmlValue);
      }

      // Slot into the right position if it's drifted
      const currentAtIndex = container.children[i];
      if (currentAtIndex !== element) {
        container.insertBefore(element, currentAtIndex || null);
      }
    }
  };
}

/** Create handler for `component.each_live` (returns the handler function) */
function createEachLiveHandler(
  selector,
  slice,
  getKey,
  initial,
  patch,
  toHtml,
  compare,
) {
  const children = new Map();
  let previousPatchesByKey = new Map();
  let cachedContainer = null;

  return function (model) {
    // Re-query only if detached — handles re-mounts, free in the normal case
    if (!cachedContainer || !cachedContainer.isConnected) {
      cachedContainer = document.querySelector(selector);
    }
    const container = cachedContainer;
    if (!container) return;

    const items = slice(model).toArray();
    const currentKeySet = new Set(items.map((item) => getKey(item)));

    // Drop children whose keys are no longer in the list
    for (const [keyStr, element] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(element);
        children.delete(keyStr);
        previousPatchesByKey.delete(keyStr);
      }
    }

    // Sync children — create, update, and reorder in one pass
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const keyStr = getKey(item);

      // Look up or create the element for this key
      let element = children.get(keyStr);
      if (!element) {
        // Only call initial() for this specific new item — not the whole list
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        element.innerHTML = toHtml(initial(item));
        children.set(keyStr, element);
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
  };
}

/** Renders a general `Component` (irrespective of specific variant) */
function renderComponent(
  runtime,
  component,
  model,
  toHtml,
  store,
  parentSelector,
  depth,
) {
  const typeName = component.constructor.name;

  // Constructors are opaque in the public API, so instanceof doesn't work —
  // string matching on the constructor name is the next best thing.
  switch (typeName) {
    case "Static":
      return renderStatic(component, toHtml);
    case "Simple":
      return renderSimple(
        runtime,
        component,
        model,
        toHtml,
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
    selector,
    slice,
    key,
    render,
    toHtml,
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
    selector,
    slice,
    key,
    initial,
    patch,
    toHtml,
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
  store,
  parentSelector,
  depth,
) {
  const componentId = runtime.nextComponentId();
  const selector = `[data-lily-component="${componentId}"]`;

  const { slice, initial, apply, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  let cachedElement = null;

  const handler = runtime.createSelective(
    selector,
    slice,
    compareStrategy,
    (data) => {
      const patches = apply(data).toArray();

      // Re-query only if detached — handles re-mounts, free in the normal case
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

  const initialHtml = toHtml(initial);

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a component wrapped in RequireConnection */
function renderRequireConnection(
  runtime,
  component,
  model,
  toHtml,
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
      // Re-query only if detached — handles re-mounts, free in the normal case
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

  const handler = runtime.createSelective(
    selector,
    slice,
    compareStrategy,
    (data) => {
      const html = toHtml(render(data));
      // Re-query only if detached — handles re-mounts, free in the normal case
      if (!cachedElement || !cachedElement.isConnected) {
        cachedElement = document.querySelector(selector);
      }
      if (cachedElement) {
        cachedElement.innerHTML = html;
      }
    },
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  const initialHtml = toHtml(render(slice(model)));

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Static component */
function renderStatic(component, toHtml) {
  return toHtml(component.content);
}
