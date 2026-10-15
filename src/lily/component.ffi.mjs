/**
 * COMPONENT TREE RENDERING
 *
 * Renders the component tree and keeps dynamic components in step with the
 * store. One context and id prefix per runtime, a render's ids are a range.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { NonEmpty, isEqual } from "../gleam.mjs";
import { inspect } from "../../gleam_stdlib/gleam_stdlib.mjs";
import { Some } from "../../gleam_stdlib/gleam/option.mjs";
// circular with component.mjs, safe as these are only read inside functions
import {
  Each,
  Fragment,
  Listener,
  Live,
  RemoveAttribute,
  SetAttribute,
  SetStyle,
  SetText,
  Simple,
  Static,
} from "./component.mjs";
import {
  createEvents,
  dropListeners,
  installMessageClicks,
  registerListener,
  setDispatch,
} from "./event.ffi.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function keyToString(key) {
  if (typeof key === "string") return key;
  if (typeof key === "number") return String(key);
  return inspect(key);
}

export function renderTree(
  runtime,
  rootSelector,
  component,
  model,
  toHtml,
  toSlot,
  dispatch,
  decodeMessage,
) {
  const root = document.querySelector(rootSelector);
  if (!root) {
    log(
      "error",
      `lily: nothing matches the mount selector "${rootSelector}", so ` +
        "nothing was rendered",
    );
    return null;
  }

  const context = contextFor(runtime.handle);
  setDispatch(context.events, dispatch);

  const start = context.counter;
  const [html, owned] = collectOwners(context, () =>
    renderComponent(context, component, model, toHtml, toSlot),
  );
  const end = context.counter;

  // new ids are all newer, keeping the sweep to the earlier mount
  unregisterSubtree(context, root);
  root.innerHTML = html;
  setOwners(context, root, owned);

  // seeded components skip, leaving this to mostly populate keyed lists
  runRange(context, start, end, model);

  installMessageClicks(root, decodeMessage, dispatch);
  return null;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function applyPatches(rootElement, patches) {
  for (const patch of patches) {
    const element =
      patch.target === ""
        ? rootElement
        : rootElement.querySelector(patch.target);

    if (!element) continue;

    if (patch instanceof SetText) {
      element.textContent = patch.value;
    } else if (patch instanceof SetAttribute) {
      if (isUnsafeAttribute(patch.name, patch.value)) {
        log(
          "warn",
          `lily: refused unsafe attribute "${patch.name}" in a live patch`,
        );
      } else if (element.getAttribute(patch.name) !== patch.value) {
        setAttribute(element, patch.name, patch.value);
      }
    } else if (patch instanceof SetStyle) {
      element.style.setProperty(patch.property, patch.value);
    } else if (patch instanceof RemoveAttribute) {
      removeAttribute(element, patch.name);
    }
  }
}

/** Strips the exit class now, the abort path does it a microtask late. */
function cancelExitAndStripClass(context, node) {
  const controller = context.exits.get(node);
  if (controller) {
    controller.abort();
    context.exits.delete(node);
  }
  const transitionElement = findTransitionElement(node);
  const exitClass = transitionElement?.dataset.lilyTransitionExit;
  if (exitClass) transitionElement.classList.remove(exitClass);
}

/** Listener-only owners have no element of their own. */
function collectOwners(context, render) {
  const outer = context.collected;
  const owned = [];
  context.collected = owned;
  try {
    return [render(), owned];
  } finally {
    context.collected = outer;
  }
}

function contextFor(runtime) {
  let context = contexts.get(runtime);
  if (context) return context;
  context = {
    prefix: `r${runtimeCount++}`,
    // component ids, source of every render range
    counter: 0,
    // listener-only owner ids, never in a range
    listenerCounter: 0,
    // id to handler for model-reactive components
    registry: new Map(),
    // component or mount root to its listener-only owners
    owners: new Map(),
    collected: null,
    // pending exits by element, a returning key cancels its exit
    exits: new Map(),
    // off during each row renders, row listeners ignored by design
    collecting: true,
    events: createEvents(),
  };
  contexts.set(runtime, context);
  const registry = context.registry;
  runtime.addRenderer((model) => {
    for (const handler of registry.values()) handler(model);
  });
  return context;
}

function cssDurationMilliseconds(value) {
  let max = 0;
  for (const part of String(value).split(",")) {
    const text = part.trim();
    let milliseconds = 0;
    if (text.endsWith("ms")) milliseconds = parseFloat(text);
    else if (text.endsWith("s")) milliseconds = parseFloat(text) * 1000;
    if (Number.isFinite(milliseconds) && milliseconds > max) {
      max = milliseconds;
    }
  }
  return max;
}

/**
 * Elementless components get a `display: contents` wrapper for scoped
 * listeners, or a bare owner id when all have selectors.
 */
function decorate(context, decorations, html, id) {
  // prepended, leaving newest first
  const listeners = [];
  const transitions = [];
  for (let node = decorations; node instanceof NonEmpty; node = node.tail) {
    if (node.head instanceof Listener) listeners.unshift(node.head);
    else transitions.unshift(node.head);
  }

  if (listeners.length > 0) {
    let owner = id;
    if (owner === null) {
      if (listeners.some((listener) => !(listener.selector instanceof Some))) {
        owner = nextId(context);
        html =
          `<div data-lily-component="${owner}" style="display: contents">` +
          `${html}</div>`;
      } else {
        owner = `${context.prefix}l${context.listenerCounter++}`;
        if (context.collecting) context.collected?.push(owner);
      }
    }
    if (context.collecting) {
      for (const listener of listeners) {
        registerListener(context.events, owner, listener);
      }
    }
  }

  for (const { enter, exit, duration_milliseconds: duration } of transitions) {
    const wrapperId = nextId(context);
    scheduleEnterClassRemoval(
      `[data-lily-component="${wrapperId}"]`,
      enter,
      duration,
    );
    html =
      `<div data-lily-component="${wrapperId}" ` +
      `data-lily-transition-exit="${escapeAttribute(exit)}" ` +
      `data-lily-transition-duration="${duration}" ` +
      `class="${escapeAttribute(enter)}">${html}</div>`;
  }
  return html;
}

function eachHandler(context, element, component, toHtml, toSlot) {
  const { slice, key: getKey, render } = component;
  const patch = component.patch instanceof Some ? component.patch[0] : null;
  // key to { element, item }
  const rows = new Map();
  let previousList = null;

  return function (model) {
    // same list reference, unchanged
    const list = slice(model);
    if (list === previousList) return;
    const container = element();
    if (!container) return;
    previousList = list;

    const items = list.toArray();
    const keys = items.map(getKey);
    const currentKeys = new Set(keys);

    // drop departed keys, transition rows wait for their exit animation
    for (const [keyString, row] of rows) {
      if (currentKeys.has(keyString)) continue;
      // already exiting, avoids a duplicate timer
      if (context.exits.has(row.element)) continue;
      removeWithTransition(context, container, row.element, () => {
        rows.delete(keyString);
        unregisterSubtree(context, row.element);
      });
    }

    // cursor walk, indexing live `container.children` is quadratic
    let cursor = container.firstElementChild;

    // changed rows share one template, one parse
    const pending = [];

    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      const keyString = keys[index];

      let row = rows.get(keyString);
      const isNew = !row;
      if (isNew) {
        const rowElement = document.createElement("div");
        rowElement.setAttribute("data-lily-key", keyString);
        row = { element: rowElement, item: undefined };
        rows.set(keyString, row);
      } else if (context.exits.has(row.element)) {
        // re-added mid-exit, cancel removal and strip the exit class now
        cancelExitAndStripClass(context, row.element);
      }

      // exiting rows keep their place
      while (cursor && cursor !== row.element && context.exits.has(cursor)) {
        cursor = cursor.nextElementSibling;
      }
      // placed before child handlers run so their queries find it
      if (cursor !== row.element) container.insertBefore(row.element, cursor);
      cursor = row.element.nextElementSibling;

      if (!isNew && fastEqual(row.item, item)) continue;
      row.item = item;

      if (!isNew && patch) {
        applyPatches(row.element, patch(item).toArray());
        continue;
      }

      // row bindings ignored by design, bind on the list or an ancestor
      const collecting = context.collecting;
      context.collecting = false;
      const start = context.counter;
      const html = renderWithSlots(context, model, toHtml, toSlot, (slot) =>
        render(item, slot),
      );
      const end = context.counter;
      context.collecting = collecting;

      if (isNew) {
        row.element.innerHTML = html;
        runRange(context, start, end, model);
      } else {
        pending.push({ row, html, start, end });
      }
    }

    if (pending.length > 0) {
      const template = document.createElement("template");
      template.innerHTML = pending
        .map((entry) => `<div>${entry.html}</div>`)
        .join("");
      const hosts = Array.from(template.content.children);
      pending.forEach((entry, index) => {
        morphFrom(
          context,
          entry.row.element,
          hosts[index],
          entry.start,
          entry.end,
          model,
        );
      });
    }
  };
}

/** Transition classes can come from the model. */
function escapeAttribute(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/** isEqual with a shared-reference shortcut. */
function fastEqual(left, right) {
  if (left === right) return true;
  if (
    typeof left === "object" &&
    left !== null &&
    typeof right === "object" &&
    right !== null &&
    left.constructor === right.constructor
  ) {
    const keys = Object.keys(left);
    if (keys.length === Object.keys(right).length) {
      let same = true;
      for (const key of keys) {
        if (left[key] !== right[key]) {
          same = false;
          break;
        }
      }
      if (same) return true;
    }
  }
  return isEqual(left, right);
}

/** A row's key wrapper can sit just above the Transition wrapper. */
function findTransitionElement(element) {
  if (element.dataset?.lilyTransitionExit) return element;
  const child = element.firstElementChild;
  if (child?.dataset?.lilyTransitionExit) return child;
  return null;
}

function isComponentWrapper(node) {
  return (
    node.nodeType === 1 &&
    (node.hasAttribute("data-lily-component") ||
      node.hasAttribute("data-lily-key"))
  );
}

/**
 * Patch values may be other clients' input. Strips control chars and
 * whitespace before the scheme check, as browsers do.
 */
function isUnsafeAttribute(name, value) {
  if (name.toLowerCase().startsWith("on")) return true;
  if (URL_ATTRIBUTES.has(name.toLowerCase())) {
    const scheme = String(value)
      .replace(/[\u0000- ]+/g, "")
      .toLowerCase();
    if (UNSAFE_URL_SCHEME.test(scheme)) return true;
  }
  return false;
}

/** Consumes `next`. Runtime-owned wrappers match by position. */
function morph(context, live, next) {
  let liveNode = live.firstChild;
  let nextNode = next.firstChild;

  while (nextNode) {
    const nextAfter = nextNode.nextSibling;

    if (!liveNode) {
      live.appendChild(nextNode);
      nextNode = nextAfter;
      continue;
    }

    const liveOwned = isComponentWrapper(liveNode);
    const nextOwned = isComponentWrapper(nextNode);

    if (liveOwned && nextOwned) {
      // both runtime-owned, keep the live one, cancel any pending exit
      if (context.exits.has(liveNode)) {
        cancelExitAndStripClass(context, liveNode);
      }
      liveNode = liveNode.nextSibling;
      nextNode = nextAfter;
    } else if (nextOwned) {
      live.insertBefore(nextNode, liveNode);
      nextNode = nextAfter;
    } else if (liveOwned) {
      const gone = liveNode;
      liveNode = liveNode.nextSibling;
      removeMorphChild(context, live, gone);
    } else if (
      liveNode.nodeType === 1 &&
      nextNode.nodeType === 1 &&
      liveNode.tagName === nextNode.tagName
    ) {
      morphElement(context, liveNode, nextNode);
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
      live.replaceChild(nextNode, replaced);
      nextNode = nextAfter;
    }
  }

  while (liveNode) {
    const gone = liveNode;
    liveNode = liveNode.nextSibling;
    removeMorphChild(context, live, gone);
  }
}

/** Unchanged attributes are skipped to keep user input. */
function morphAttributes(live, next) {
  const nextAttributes = next.attributes;
  for (let index = 0; index < nextAttributes.length; index++) {
    const { name, value } = nextAttributes[index];
    if (live.getAttribute(name) !== value) setAttribute(live, name, value);
  }
  const liveAttributes = live.attributes;
  for (let index = liveAttributes.length - 1; index >= 0; index--) {
    const name = liveAttributes[index].name;
    if (!next.hasAttribute(name)) removeAttribute(live, name);
  }
}

function morphElement(context, live, next) {
  morphAttributes(live, next);
  // a dirty textarea ignores its text, meaning it is copied to value
  const textChanged =
    live.tagName === "TEXTAREA" && live.defaultValue !== next.defaultValue;
  morph(context, live, next);
  if (textChanged) live.value = live.defaultValue;
}

/** Sweeps duplicate registrations for wrappers already in the host. */
function morphFrom(context, host, source, start, end, model) {
  morph(context, host, source);
  for (let number = start; number < end; number++) {
    const id = context.prefix + "c" + number;
    if (host.querySelector(`[data-lily-component="${id}"]`)) {
      context.registry.get(id)?.(model);
    } else {
      unregister(context, id);
    }
  }
}

function nextId(context) {
  return context.prefix + "c" + context.counter++;
}

function registerWrapped(context, makeHandler) {
  const id = nextId(context);
  const selector = `[data-lily-component="${id}"]`;
  let cached = null;
  const element = () =>
    (cached = cached?.isConnected ? cached : document.querySelector(selector));
  context.registry.set(id, makeHandler(element, id));
  const wrap = (inner) => `<div data-lily-component="${id}">${inner}</div>`;
  return { id, wrap };
}

function removeAttribute(element, name) {
  element.removeAttribute(name);
  syncProperty(element, name, null);
}

function removeMorphChild(context, parent, node) {
  if (isComponentWrapper(node)) {
    if (context.exits.has(node)) return;
    if (findTransitionElement(node)) {
      removeWithTransition(context, parent, node, () =>
        unregisterSubtree(context, node),
      );
      return;
    }
    unregisterSubtree(context, node);
  }
  if (node.parentNode === parent) parent.removeChild(node);
}

/** The pending exit is keyed by the outer row `element`. */
async function removeWithTransition(context, parent, element, onComplete) {
  const transitionElement = findTransitionElement(element);

  if (!transitionElement) {
    if (element.parentNode === parent) parent.removeChild(element);
    onComplete();
    return;
  }

  const exitClass = transitionElement.dataset.lilyTransitionExit;
  const duration =
    parseInt(transitionElement.dataset.lilyTransitionDuration ?? "0", 10) || 0;
  const controller = new AbortController();
  context.exits.set(element, controller);

  transitionElement.classList.add(exitClass);
  await whenAnimationDone(transitionElement, duration, controller.signal);

  if (controller.signal.aborted) {
    // cancelled by a re-add, strip the exit class
    transitionElement.classList.remove(exitClass);
    return;
  }

  context.exits.delete(element);
  if (element.parentNode === parent) parent.removeChild(element);
  onComplete();
}

function renderComponent(context, component, model, toHtml, toSlot) {
  const type = component.component_type;
  let html;
  let id = null;

  if (type instanceof Simple) {
    ({ html, id } = renderSimple(context, type, model, toHtml, toSlot));
  } else if (type instanceof Each) {
    const wrapped = registerWrapped(context, (element) =>
      eachHandler(context, element, type, toHtml, toSlot),
    );
    ({ id } = wrapped);
    // empty, the handler populates it
    html = wrapped.wrap("");
  } else if (type instanceof Live) {
    ({ html, id } = renderLive(context, type, model, toHtml, toSlot));
  } else if (type instanceof Static) {
    html = renderWithSlots(context, model, toHtml, toSlot, type.render);
  } else if (type instanceof Fragment) {
    html = "";
    for (const child of type.children) {
      html += renderComponent(context, child, model, toHtml, toSlot);
    }
  } else {
    log("error", `lily: unknown component type ${type?.constructor?.name}`);
    return "";
  }

  if (!(component.decorations instanceof NonEmpty)) return html;
  return decorate(context, component.decorations, html, id);
}

function renderLive(context, component, model, toHtml, toSlot) {
  const { slice, render, patch } = component;
  const seed = slice(model);
  const { id, wrap } = registerWrapped(context, (element) =>
    selective(seed, slice, (data) => {
      const host = element();
      if (host) applyPatches(host, patch(data).toArray());
    }),
  );
  // children live as long as the component, patches never touch them
  const [html, owned] = collectOwners(context, () =>
    renderWithSlots(context, model, toHtml, toSlot, (slot) =>
      render(seed, slot),
    ),
  );
  setOwners(context, id, owned);
  return { html: wrap(html), id };
}

function renderSimple(context, component, model, toHtml, toSlot) {
  const { slice, render } = component;
  const seed = slice(model);
  const { id, wrap } = registerWrapped(context, (element, id) =>
    selective(seed, slice, (data, model) => {
      const host = element();
      if (!host) return;
      // re-render with slot children, then morph onto the live subtree
      const start = context.counter;
      const [html, owned] = collectOwners(context, () =>
        renderWithSlots(context, model, toHtml, toSlot, (slot) =>
          render(data, slot),
        ),
      );
      setOwners(context, id, owned);
      const template = document.createElement("template");
      template.innerHTML = html;
      morphFrom(context, host, template.content, start, context.counter, model);
    }),
  );
  // run at mount by renderTree, kept across updates by the morph
  const [html, owned] = collectOwners(context, () =>
    renderWithSlots(context, model, toHtml, toSlot, (slot) =>
      render(seed, slot),
    ),
  );
  setOwners(context, id, owned);
  return { html: wrap(html), id };
}

/** Fills placeholders in DOM order. Orphaned children are unregistered. */
function renderWithSlots(context, model, toHtml, toSlot, produce) {
  const children = [];
  const html = toHtml(
    produce((child) => {
      children.push(child);
      return toSlot();
    }),
  );
  if (children.length === 0) return html;

  const segments = html.split(SLOT_PATTERN);
  let output = segments[0];
  for (let index = 0; index < children.length; index++) {
    const start = context.counter;
    const ownedBefore = context.collected?.length ?? 0;
    const childHtml = renderComponent(
      context,
      children[index],
      model,
      toHtml,
      toSlot,
    );
    if (index + 1 < segments.length) {
      output += childHtml + segments[index + 1];
      continue;
    }
    log(
      "error",
      "lily: <lily-slot> placeholder missing from rendered HTML, child " +
        "component dropped. Make sure slot() return values are placed in the " +
        "template.",
    );
    for (let number = start; number < context.counter; number++) {
      unregister(context, context.prefix + "c" + number);
    }
    for (const owner of context.collected?.splice(ownedBefore) ?? []) {
      dropListeners(context.events, owner);
    }
  }

  // extra placeholders dropped
  for (let index = children.length + 1; index < segments.length; index++) {
    output += segments[index];
  }
  return output;
}

function runRange(context, start, end, model) {
  for (let number = start; number < end; number++) {
    context.registry.get(context.prefix + "c" + number)?.(model);
  }
}

/** The enter class stays until the animation ends. */
function scheduleEnterClassRemoval(selector, enterClass, duration) {
  const arm = () => {
    const element = document.querySelector(selector);
    if (!element) {
      setTimeout(() => {
        document.querySelector(selector)?.classList.remove(enterClass);
      }, duration);
      return;
    }
    whenAnimationDone(element, duration).then(() =>
      element.classList.remove(enterClass),
    );
  };
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(arm);
  else setTimeout(arm, 0);
}

/** Starts from `seed` so mount doesn't render twice. */
function selective(seed, select, handler) {
  let previous = seed;
  return function (model) {
    const next = select(model);
    if (fastEqual(previous, next)) return;
    previous = next;
    handler(next, model);
  };
}

function setAttribute(element, name, value) {
  element.setAttribute(name, value);
  syncProperty(element, name, value);
}

function setOwners(context, key, owned) {
  const previous = context.owners.get(key);
  if (previous) {
    for (const owner of previous) dropListeners(context.events, owner);
  }
  if (owned.length > 0) context.owners.set(key, owned);
  else context.owners.delete(key);
}

/**
 * Sets the property too, edited fields ignore `value`, `checked` and
 * `selected` attributes. `value` is null on removal.
 */
function syncProperty(element, name, value) {
  if (name === "value") {
    const next = value ?? "";
    if ("value" in element && element.type !== "file") {
      if (element.value !== next) element.value = next;
    }
  } else if (name === "checked" || name === "selected") {
    if (name in element) element[name] = value !== null;
  }
}

/** Falls back to the declared duration. */
function transitionHoldMilliseconds(element, fallback) {
  if (typeof getComputedStyle === "function") {
    const computed = cssDurationMilliseconds(
      getComputedStyle(element).animationDuration ?? "0s",
    );
    if (computed > 0) return computed + 60;
  }
  return fallback;
}

function unregister(context, id) {
  context.registry.delete(id);
  dropListeners(context.events, id);
  const owned = context.owners.get(id);
  if (owned) {
    context.owners.delete(id);
    for (const owner of owned) dropListeners(context.events, owner);
  }
}

function unregisterSubtree(context, element) {
  if (element.nodeType !== 1) return;
  const own = element.getAttribute("data-lily-component");
  if (own) unregister(context, own);
  for (const wrapper of element.querySelectorAll("[data-lily-component]")) {
    unregister(context, wrapper.getAttribute("data-lily-component"));
  }
}

/** Ignores a child's bubbling `animationend`. */
function whenAnimationDone(element, fallback, signal) {
  return new Promise((resolve) => {
    const finish = (event) => {
      if (event?.type === "animationend" && event.target !== element) return;
      element.removeEventListener("animationend", finish);
      signal?.removeEventListener("abort", finish);
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(
      finish,
      transitionHoldMilliseconds(element, fallback),
    );
    element.addEventListener("animationend", finish);
    signal?.addEventListener("abort", finish);
  });
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// renderer state per runtime, the runtime is component-agnostic
const contexts = new WeakMap();

let runtimeCount = 0;

// split is global regardless of the `g` flag
const SLOT_PATTERN = /<lily-slot[^>]*>\s*<\/lily-slot>/;

const UNSAFE_URL_SCHEME = /^(?:javascript|vbscript):/;

// data URLs allowed for inline images
const URL_ATTRIBUTES = new Set([
  "href",
  "src",
  "xlink:href",
  "formaction",
  "action",
]);
