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

/**
 * Subscribe to runtime updates by attaching a handler to the store's
 * notification system. Registers the selective handler on the store so that
 * it is called on every notify cycle (triggered by sendMessage, etc.).
 */
export function subscribeToRuntime(runtime, selector, handler) {
  const handle = runtime.handle;
  handle.setCompareStrategy(selector, handle.referenceEqual);
  const selective = handle.createSelective(
    selector,
    (model) => model,
    handle.referenceEqual,
    handler,
  );
  // Register on the store's handler dict so notify() calls it
  handle.subscribeHandler(selector, selective);
}

// Renders the whole component tree.
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
function createEachHandler(selector, produce, toHtml, compare) {
  const children = new Map();
  let previousHtmlByKey = new Map();

  return function (model) {
    // Check to see if selector is valid
    const container = document.querySelector(selector);
    if (!container) return;

    // The produce function (check Gleam code for reference) creates an array
    // with each element being [key, render result before running toHtml].
    const pairs = produce(model).toArray();
    const currentKeySet = new Set(pairs.map((pair) => pair[0]));

    // Remove children whose keys disappeared
    for (const [keyStr, child] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(child);
        children.delete(keyStr);
        previousHtmlByKey.delete(keyStr);
      }
    }

    // Create/update/reorder children in a single pass
    for (let i = 0; i < pairs.length; i++) {
      const keyStr = pairs[i][0];
      const htmlValue = pairs[i][1];

      // Get or create element
      let element = children.get(keyStr);
      if (!element) {
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        children.set(keyStr, element);
      }

      // Update innerHTML if changed, using the relevant compare function given
      // (whether reference or structural)
      const previousHtml = previousHtmlByKey.get(keyStr);
      if (previousHtml === undefined || !compare(previousHtml, htmlValue)) {
        previousHtmlByKey.set(keyStr, htmlValue);
        element.innerHTML = toHtml(htmlValue);
      }

      // Insert/move element to correct position
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
  keys,
  initial,
  apply,
  toHtml,
  compare,
) {
  const children = new Map();
  let previousPatchesByKey = new Map();

  return function (model) {
    // Check to see if selector is valid
    const container = document.querySelector(selector);
    if (!container) return;

    const keyList = keys(model).toArray();
    const currentKeySet = new Set(keyList);

    // Remove children whose keys disappeared
    for (const [keyStr, element] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(element);
        children.delete(keyStr);
        previousPatchesByKey.delete(keyStr);
      }
    }

    // Build maps from initial for new items
    // For new items, initial will be used to generate pair[1]
    const needsInitial = keyList.some((k) => !children.has(k));
    const initialMap = new Map();
    if (needsInitial) {
      const initialPairs = initial(model).toArray();
      for (const pair of initialPairs) {
        initialMap.set(pair[0], pair[1]);
      }
    }

    // Build maps from apply results for updated items
    // For updated items, pair[1] will be a list of patches
    const applyPairs = apply(model).toArray();
    const applyMap = new Map();
    for (const pair of applyPairs) {
      applyMap.set(pair[0], pair[1]);
    }

    // Create/update/reorder children in a single pass
    for (let i = 0; i < keyList.length; i++) {
      const keyStr = keyList[i];

      // Get or create element
      let element = children.get(keyStr);
      if (!element) {
        element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);
        const html = initialMap.get(keyStr);
        if (html !== undefined) {
          element.innerHTML = toHtml(html);
        }
        children.set(keyStr, element);
      }

      // Apply patches if changed (using the provided compare function, whether
      // reference or structural)
      const patchList = applyMap.get(keyStr);
      const previousPatches = previousPatchesByKey.get(keyStr);
      if (
        patchList !== undefined &&
        (previousPatches === undefined || !compare(previousPatches, patchList))
      ) {
        previousPatchesByKey.set(keyStr, patchList);
        const patches = patchList.toArray();
        applyPatchesToElement(element, patches);
      }

      // Insert/move element to correct position
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

  // Note that as we have chosen to make the constructors opaque within the
  // Gleam public API, we cannot use `instanceof` and have to resort to string
  // matching.
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

  const { produce, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  const handler = createEachHandler(selector, produce, toHtml, compareStrategy);

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

  const { keys, initial, apply, compare } = component;

  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  // Create each live handler
  const handler = createEachLiveHandler(
    selector,
    keys,
    initial,
    apply,
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

  // Render the inner component
  const innerHtml = renderComponent(
    runtime,
    inner,
    model,
    toHtml,
    store,
    selector,
    depth + 1,
  );

  // Create selective handler to manage disabled state
  const handler = runtime.createSelective(
    selector,
    connected,
    runtime.referenceEqual,
    (isConnected) => {
      const element = document.querySelector(selector);
      if (!element) return;

      if (isConnected) {
        // Remove disabled attributes and class
        element.removeAttribute("data-lily-disabled");
        element.removeAttribute("aria-disabled");
        element.classList.remove("lily-disconnected");
      } else {
        // Add disabled attributes and class
        element.setAttribute("data-lily-disabled", "true");
        element.setAttribute("aria-disabled", "true");
        element.classList.add("lily-disconnected");
      }
    },
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Return wrapped HTML with component ID
  return `<div data-lily-component="${componentId}">${innerHtml}</div>`;
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

  // Create selective handler
  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  const handler = runtime.createSelective(
    selector,
    slice,
    compareStrategy,
    (_data, model) => {
      const patches = apply(model).toArray();

      // Get the component root element
      const rootElement = document.querySelector(selector);
      if (rootElement) {
        applyPatchesToElement(rootElement, patches);
      }
    },
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Render initial HTML
  const initialHtml = toHtml(initial);

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
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

  const { slice, view, compare } = component;

  // Create selective handler
  const compareStrategy =
    compare instanceof StructuralEqual ? isEqual : referenceEqual;

  const handler = runtime.createSelective(
    selector,
    slice,
    compareStrategy,
    (_data, model) => {
      const html = toHtml(view(model));
      runtime.setInnerHtml(selector, html);
    },
  );

  // Register handler to be called on model updates
  runtime.registerComponent(componentId, handler);

  // Render initial HTML
  const initialHtml = toHtml(view(model));

  return `<div data-lily-component="${componentId}">${initialHtml}</div>`;
}

/** Renders a Static component */
function renderStatic(component, toHtml) {
  return toHtml(component.content);
}
