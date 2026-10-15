/**
 * EVENT DISPATCH
 *
 * One document or window listener per event name, bindings run deepest first.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, toList } from "../gleam.mjs";
import { Some } from "../../gleam_stdlib/gleam/option.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function createEvents() {
  return {
    dispatch: null,
    roots: new Set(),
    byOwner: new Map(),
    bySelector: new Map(),
    sequence: 0,
  };
}

export function dropListeners(state, ownerId) {
  const owned = state.byOwner.get(ownerId);
  if (!owned) return;
  state.byOwner.delete(ownerId);
  for (const binding of owned) {
    clearTimeout(binding.runtime.timer);
    if (binding.selector !== null) {
      const list = state.bySelector.get(binding.name);
      if (list) {
        const index = list.indexOf(binding);
        if (index !== -1) list.splice(index, 1);
      }
    }
  }
}

/** Replaces any earlier listener, a remount doesn't stack. */
export function installMessageClicks(root, decodeMessage, dispatch) {
  if (root.lilyMessageClick) {
    root.removeEventListener("click", root.lilyMessageClick);
  }
  const listener = (event) => {
    const element = event.target.closest?.("[data-message]");
    if (!element || !root.contains(element)) return;
    const decoded = decodeMessage(element.getAttribute("data-message"));
    if (decoded instanceof Ok) dispatch(decoded[0]);
  };
  root.lilyMessageClick = listener;
  root.addEventListener("click", listener);
}

export function readChecked(event) {
  return event.target?.checked === true;
}

export function readDataMessage(event) {
  const element = event.target?.closest?.("[data-message]");
  return element?.getAttribute("data-message") ?? "";
}

export function readFormFields(event) {
  const target = event?.lilyMatched ?? event?.target;
  const form =
    target?.tagName === "FORM" ? target : (target?.closest?.("form") ?? null);
  const fields = [];
  if (form) {
    for (const [name, value] of new FormData(form)) {
      if (typeof value === "string") fields.push([name, value]);
    }
  }
  return toList(fields);
}

export function readKey(event) {
  return [
    event.key,
    event.ctrlKey === true,
    event.shiftKey === true,
    event.altKey === true,
    event.metaKey === true,
  ];
}

export function readPointer(event) {
  return [event.clientX, event.clientY];
}

export function readScroll(event) {
  const target = event.lilyMatched ?? event.target;
  const element = target.documentElement ?? target;
  return [Math.round(element.scrollTop), Math.round(element.scrollLeft)];
}

export function readValue(event) {
  return String(event.target?.value ?? "");
}

export function registerListener(state, ownerId, listener) {
  const binding = {
    name: listener.event,
    run: listener.run,
    selector: optionValue(listener.selector),
    debounce: optionValue(listener.debounce_milliseconds),
    throttle: optionValue(listener.throttle_milliseconds),
    once: listener.once,
    prevent: listener.prevent_default,
    stop: listener.stop_propagation,
    reset: listener.reset_form,
    owner: ownerId,
    sequence: state.sequence++,
    runtime: { timer: null, last: 0, fired: false, reported: false },
  };
  if (!state.byOwner.has(ownerId)) state.byOwner.set(ownerId, []);
  state.byOwner.get(ownerId).push(binding);
  if (binding.selector !== null) {
    if (!state.bySelector.has(binding.name)) {
      state.bySelector.set(binding.name, []);
    }
    state.bySelector.get(binding.name).push(binding);
  }
  installRoot(state, binding);
}

export function setDispatch(state, dispatch) {
  state.dispatch = dispatch;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/** Bindings whose wrapper or selector contains the target, deepest first. */
function collect(state, name, event, onWindow) {
  const found = [];
  const target = event.target;
  const nonBubbling = CAPTURE_EVENTS.has(name);

  // ancestors deepest first, depth counts from the chain top not the document
  const chain = [];
  if (!onWindow) {
    for (let element = target; element; element = element.parentElement) {
      if (element.nodeType === 1) chain.push(element);
    }
  }
  const depthOf = (element) => chain.length - chain.indexOf(element);

  for (let index = 0; index < chain.length; index++) {
    const element = chain[index];
    const owner = element.getAttribute("data-lily-component");
    if (!owner) continue;
    for (const binding of state.byOwner.get(owner) ?? []) {
      if (binding.name !== name || binding.selector !== null) continue;
      // non-bubbling, only the component's own element
      if (
        nonBubbling &&
        element !== target &&
        element !== target.parentElement
      ) {
        continue;
      }
      found.push({ binding, matched: target, depth: chain.length - index });
    }
  }

  for (const binding of state.bySelector.get(name) ?? []) {
    if (onWindow !== (binding.selector === "window")) continue;
    if (binding.selector === "document" || binding.selector === "window") {
      found.push({ binding, matched: target, depth: 0 });
      continue;
    }
    if (!target?.closest) continue;
    const matched = nonBubbling
      ? target.matches(binding.selector)
        ? target
        : null
      : target.closest(binding.selector);
    if (matched) found.push({ binding, matched, depth: depthOf(matched) });
  }

  found.sort(
    (first, second) =>
      second.depth - first.depth ||
      first.binding.sequence - second.binding.sequence,
  );
  return found;
}

function deliver(state, binding, message, matched) {
  state.dispatch(message);
  if (binding.reset) matched?.closest?.("form")?.reset();
}

function handleEvent(state, name, event, onWindow) {
  if (!state.dispatch) return;
  for (const { binding, matched } of collect(state, name, event, onWindow)) {
    event.lilyMatched = matched;
    if (binding.prevent) event.preventDefault();

    if (binding.once && binding.runtime.fired) continue;
    // payload read now, only the dispatch is debounced
    const result = binding.run(event);
    if (result instanceof Ok) {
      binding.runtime.fired = true;
      const message = result[0];
      let wait = false;
      if (binding.throttle !== null) {
        const now = Date.now();
        if (now - binding.runtime.last < binding.throttle) wait = true;
        else binding.runtime.last = now;
      }
      if (!wait && binding.debounce !== null) {
        clearTimeout(binding.runtime.timer);
        binding.runtime.timer = setTimeout(
          () => deliver(state, binding, message, matched),
          binding.debounce,
        );
      } else if (!wait) {
        deliver(state, binding, message, matched);
      }
    } else if (result[0] !== "" && !binding.runtime.reported) {
      binding.runtime.reported = true;
      log(
        "warn",
        `lily: a "${binding.name}" binding skipped an event it could not ` +
          `decode (${binding.selector ?? "its component"}): ${result[0]}`,
      );
    }

    if (binding.stop) {
      event.stopPropagation();
      return;
    }
  }
}

function installRoot(state, binding) {
  const onWindow = binding.selector === "window";
  const capture = CAPTURE_EVENTS.has(binding.name);
  const key = (onWindow ? "window:" : "document:") + binding.name;
  if (state.roots.has(key)) return;
  state.roots.add(key);
  const target = onWindow ? window : document;
  const listener = (event) => handleEvent(state, binding.name, event, onWindow);
  target.addEventListener(binding.name, listener, capture);
}

function optionValue(option) {
  return option instanceof Some ? option[0] : null;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// non-bubbling, heard in capture so a binding fires only for its own element
const CAPTURE_EVENTS = new Set([
  "focus",
  "blur",
  "scroll",
  "mouseenter",
  "mouseleave",
  "pointerenter",
  "pointerleave",
  "toggle",
  "load",
  "error",
]);
