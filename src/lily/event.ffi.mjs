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
// circular with component.mjs, safe as these are only read inside functions
import {
  DecodeFailed,
  Dispatch,
  DomEvent,
  ElementResize,
  ElementVisibility,
  SkipAndPreventDefault,
} from "./component.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function createEvents(wrappers) {
  return {
    dispatch: null,
    wrappers,
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
    binding.runtime.observer?.disconnect();
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
    const element = event.target.closest?.("[data-lily-message]");
    if (!element || !root.contains(element)) return;
    const decoded = decodeMessage(element.getAttribute("data-lily-message"));
    if (decoded instanceof Ok) dispatch(decoded[0]);
  };
  root.lilyMessageClick = listener;
  root.addEventListener("click", listener);
}

export function readChecked(event) {
  return event.target?.checked === true;
}

export function readDataMessage(event) {
  const element = event.target?.closest?.("[data-lily-message]");
  return element?.getAttribute("data-lily-message") ?? "";
}

export function readFiles(event) {
  return toList(Array.from(event.target?.files ?? [], fileFields));
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
    event.key ?? "",
    event.code ?? "",
    event.ctrlKey === true,
    event.shiftKey === true,
    event.altKey === true,
    event.metaKey === true,
    event.repeat === true,
    // 229 is what older browsers send while an input method composes
    event.isComposing === true || event.keyCode === 229,
  ];
}

export function readMedia(event) {
  const media = event.target ?? {};
  const duration = Number(media.duration);
  return [
    Number(media.currentTime) || 0,
    Number.isFinite(duration) ? duration : 0,
    media.paused !== false,
    media.ended === true,
    media.muted === true,
    Number(media.volume ?? 1),
    Number(media.playbackRate ?? 1),
  ];
}

// drag events have no pointer id or type, a mouse is assumed
export function readPointer(event) {
  return [
    event.clientX ?? 0,
    event.clientY ?? 0,
    event.button ?? 0,
    event.pointerId ?? 1,
    event.pointerType || "mouse",
    event.ctrlKey === true,
    event.shiftKey === true,
    event.altKey === true,
    event.metaKey === true,
  ];
}

export function readScroll(event) {
  const target = event.lilyMatched ?? event.target;
  const element = target.documentElement ?? target;
  return [Math.round(element.scrollTop), Math.round(element.scrollLeft)];
}

export function readSize(event) {
  return event.lilySize ?? [0, 0];
}

export function readTransfer(event) {
  const transfer = event.clipboardData ?? event.dataTransfer;
  return [
    transfer?.getData("text/plain") ?? "",
    transfer?.getData("text/html") ?? "",
    toList(Array.from(transfer?.files ?? [], fileFields)),
  ];
}

export function readValue(event) {
  return String(event.target?.value ?? "");
}

export function readVisible(event) {
  return event.lilyVisible === true;
}

export function readWheel(event) {
  const scale =
    event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1;
  return [
    (event.deltaX ?? 0) * scale,
    (event.deltaY ?? 0) * scale,
    event.ctrlKey === true,
    event.shiftKey === true,
    event.altKey === true,
    event.metaKey === true,
  ];
}

// the owner's element was replaced
export function reobserveOwner(state, ownerId) {
  for (const binding of state.byOwner.get(ownerId) ?? []) {
    const watch = binding.runtime.watch;
    if (!watch) continue;
    binding.runtime.observer?.disconnect();
    binding.runtime.observer = null;
    observeOwner(state, binding, watch.kind, watch.toEvent);
  }
}

export function registerListener(state, ownerId, listener) {
  const trigger = listener.trigger;
  const binding = {
    name: trigger instanceof DomEvent ? trigger.name : null,
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
  if (trigger instanceof ElementResize) {
    observeOwner(state, binding, "ResizeObserver", (entry) => {
      const box = entry.contentRect;
      return { lilySize: [box.width, box.height] };
    });
    return;
  }
  if (trigger instanceof ElementVisibility) {
    observeOwner(state, binding, "IntersectionObserver", (entry) => ({
      lilyVisible: entry.isIntersecting,
    }));
    return;
  }
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

// Firefox starts no drag without data
export function startDrag(event, result) {
  if (event.dataTransfer?.types?.length === 0) {
    event.dataTransfer.setData("text/plain", "");
  }
  return result;
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
    const owners = element.getAttribute("data-lily-component");
    if (!owners) continue;
    const bindings = owners
      .split(" ")
      .flatMap((owner) => state.byOwner.get(owner) ?? []);
    for (const binding of bindings) {
      if (binding.name !== name || binding.selector !== null) continue;
      // non-bubbling, only the component's own element or a wrapper's child
      if (
        nonBubbling &&
        element !== target &&
        !(state.wrappers.has(element) && element === target.parentElement)
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

function fileFields(file) {
  return [file.name, file.size, file.type, file];
}

function handleEvent(state, name, event, onWindow) {
  if (!state.dispatch) return;
  for (const { binding, matched } of collect(state, name, event, onWindow)) {
    if (runBinding(state, binding, event, matched)) return;
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
  // browsers make page-level wheel and touch listeners passive otherwise
  target.addEventListener(binding.name, listener, { capture, passive: false });
}

// once rendered, a `display: contents` wrapper is watched through its child
function observeOwner(state, binding, kind, toEvent) {
  const Observer = globalThis[kind];
  if (typeof Observer !== "function") return;
  binding.runtime.watch = { kind, toEvent };
  queueMicrotask(() => {
    if (!state.byOwner.get(binding.owner)?.includes(binding)) return;
    const owner = document.querySelector(
      `[data-lily-component~="${binding.owner}"]`,
    );
    const contents =
      state.wrappers.has(owner) && owner.style.display === "contents";
    const element = contents ? owner.firstElementChild : owner;
    if (!element) return;
    const observer = new Observer((entries) => {
      const event = toEvent(entries[entries.length - 1]);
      if (state.dispatch) runBinding(state, binding, event, element);
    });
    observer.observe(element);
    binding.runtime.observer = observer;
  });
}

function optionValue(option) {
  return option instanceof Some ? option[0] : null;
}

/** True when it stops propagation. */
function runBinding(state, binding, event, matched) {
  event.lilyMatched = matched;

  // a spent `once` still handles it, a form must not submit
  if (binding.once && binding.runtime.fired) {
    if (binding.prevent) event.preventDefault?.();
    return false;
  }
  // payload read now, only the dispatch is debounced
  const outcome = binding.run(event);
  if (outcome instanceof Dispatch) {
    if (binding.prevent) event.preventDefault?.();
    binding.runtime.fired = true;
    const message = outcome[0];
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
  } else if (outcome instanceof SkipAndPreventDefault) {
    if (binding.prevent) event.preventDefault?.();
  } else if (outcome instanceof DecodeFailed && !binding.runtime.reported) {
    binding.runtime.reported = true;
    log(
      "warn",
      `lily: a "${binding.name}" binding skipped an event it could not ` +
        `decode (${binding.selector ?? "its component"}): ${outcome.reason}`,
    );
  }

  if (binding.stop) {
    event.stopPropagation?.();
    return true;
  }
  return false;
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
  // media
  "abort",
  "canplay",
  "canplaythrough",
  "durationchange",
  "emptied",
  "ended",
  "loadeddata",
  "loadedmetadata",
  "loadstart",
  "pause",
  "play",
  "playing",
  "progress",
  "ratechange",
  "seeked",
  "seeking",
  "stalled",
  "suspend",
  "timeupdate",
  "volumechange",
  "waiting",
]);
