import { set_inner_html } from "./client.ffi.mjs";

// EACH HANDLER

function gleamListToArray(list) {
  const result = [];
  let current = list;
  while (current.head !== undefined) {
    result.push(current.head);
    current = current.tail;
  }
  return result;
}

export function create_each_handler(
  containerSelector,
  itemsFn,
  createFn,
  compare,
) {
  const children = new Map();
  let previousKeys = [];

  return function (model) {
    const container = document.querySelector(containerSelector);
    if (!container) return;

    const keys = gleamListToArray(itemsFn(model));

    const currentKeySet = new Set(keys.map(String));

    for (const [keyStr, child] of children) {
      if (!currentKeySet.has(keyStr)) {
        container.removeChild(child.element);
        children.delete(keyStr);
      }
    }

    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const keyStr = String(key);

      if (!children.has(keyStr)) {
        const result = createFn(key);
        const select = result[0];
        const render = result[1];

        const element = document.createElement("div");
        element.setAttribute("data-lily-key", keyStr);

        children.set(keyStr, {
          element: element,
          select: select,
          render: render,
          previousSlice: undefined,
          hasPrevious: false,
        });

        container.appendChild(element);
      }

      const child = children.get(keyStr);
      const nextSlice = child.select(model);

      if (!child.hasPrevious || !compare(child.previousSlice, nextSlice)) {
        child.previousSlice = nextSlice;
        child.hasPrevious = true;
        child.element.innerHTML = child.render(nextSlice);
      }
    }

    for (let i = 0; i < keys.length; i++) {
      const keyStr = String(keys[i]);
      const child = children.get(keyStr);
      const currentAtIndex = container.children[i];

      if (currentAtIndex !== child.element) {
        container.insertBefore(child.element, currentAtIndex);
      }
    }

    previousKeys = keys;
  };
}

// EVENT HANDLERS

function resolveTarget(selector) {
  if (selector === "document") return document;
  if (selector === "window") return window;
  return document.querySelector(selector);
}

export function setup_simple_event(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, () => handler());
}

export function setup_coordinate_event(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    handler(event.clientX, event.clientY);
  });
}

export function setup_key_event(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    handler(event.key);
  });
}

export function setup_value_event(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    handler(event.target.value || "");
  });
}

export function setup_wheel_event(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("wheel", (event) => {
    handler(event.deltaX, event.deltaY);
  });
}

export function setup_click_event(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("click", (event) => {
    const matched = event.target.closest("[data-msg]");
    if (!matched) return;
    handler(matched.getAttribute("data-msg"));
  });
}
