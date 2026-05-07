/**
 * This mjs file attaches event listeners to DOM elements. Events are attached
 * once and persist for the lifetime of the page. Handlers call back into Gleam
 * code which sends messages to the store.
 *
 * The *WithOptions variants accept an options array [debounceMs, throttleMs,
 * once, stopPropagation, preventDefault] (debounceMs and throttleMs are -1
 * when disabled). applyOptions wraps a raw DOM event listener with these
 * behaviours. preventDefaultFirst wraps the listener so that preventDefault
 * fires on every event even when debounce/throttle would skip the inner
 * handler.
 *
 * setupElementEventWithOptions / setupCoordinateElementEventWithOptions use
 * event delegation and attach to document rather than a single queried
 * element, so they work correctly with dynamically-rendered lists (e.g.
 * each/each_live). Non-bubbling events (mouseenter/mouseleave, focus/blur)
 * are mapped to their bubbling equivalents (mouseover/mouseout,
 * focusin/focusout) with a relatedTarget guard to preserve enter/leave
 * semantics.
 */

import { NonEmpty, Empty } from "../gleam.mjs";

// =============================================================================
// HELPERS
// =============================================================================

/** Resolves a selector to a DOM target (handles "document" and "window") */
function resolveTarget(selector) {
  if (selector === "document") return document;
  if (selector === "window") return window;
  return document.querySelector(selector);
}

/**
 * Extracts all data-* attributes from an element as a Gleam list of
 * [name, value] tuples, preserving original kebab-case names.
 * e.g. data-card-id="3" → ["card-id", "3"]
 */
function datasetToList(element) {
  let list = new Empty();
  const attributes = element.attributes;
  for (let i = attributes.length - 1; i >= 0; i--) {
    const attribute = attributes[i];
    if (attribute.name.startsWith("data-")) {
      list = new NonEmpty([attribute.name.slice(5), attribute.value], list);
    }
  }
  return list;
}

/**
 * Maps non-bubbling event names to their bubbling equivalents for delegation.
 * All other events bubble and are returned unchanged.
 */
function delegatedEventName(eventName) {
  switch (eventName) {
    case "mouseenter": return "mouseover";
    case "mouseleave": return "mouseout";
    case "focus":      return "focusin";
    case "blur":       return "focusout";
    default:           return eventName;
  }
}

/**
 * Returns true when the relatedTarget check should suppress the event for
 * enter/leave semantics: fire enter only when arriving from outside the
 * matched element, and leave only when departing to outside.
 */
function shouldSkipDelegatedEvent(eventName, matched, relatedTarget) {
  switch (eventName) {
    case "mouseenter":
    case "mouseleave":
    case "focus":
    case "blur":
      return relatedTarget !== null && matched.contains(relatedTarget);
    default:
      return false;
  }
}

/**
 * Wraps a raw DOM event listener with optional debounce, throttle, once, and
 * stopPropagation behaviours. debounceMs and throttleMs are -1 when disabled.
 * Applied in order: stopPropagation → once → throttle → debounce (outermost
 * last, so debounce gates before throttle fires).
 *
 * Note: preventDefault is handled separately in preventDefaultFirst so it
 * fires unconditionally even when the inner handler is throttled/debounced.
 */
function applyOptions(listener, debounceMs, throttleMs, once, stopPropagation) {
  if (stopPropagation) {
    const inner = listener;
    listener = (event) => {
      event.stopPropagation();
      inner(event);
    };
  }

  if (once) {
    const inner = listener;
    let fired = false;
    listener = (event) => {
      if (fired) return;
      fired = true;
      inner(event);
    };
  }

  if (throttleMs >= 0) {
    const inner = listener;
    let lastFired = 0;
    listener = (event) => {
      const now = Date.now();
      if (now - lastFired >= throttleMs) {
        lastFired = now;
        inner(event);
      }
    };
  }

  if (debounceMs >= 0) {
    const inner = listener;
    let timer = null;
    listener = (event) => {
      clearTimeout(timer);
      timer = setTimeout(() => inner(event), debounceMs);
    };
  }

  return listener;
}

/**
 * Wraps listener so that event.preventDefault() is called on every invocation,
 * outside any debounce/throttle gate. Use this after applyOptions so
 * preventDefault fires even when the inner handler is suppressed.
 */
function preventDefaultFirst(listener) {
  return (event) => {
    event.preventDefault();
    listener(event);
  };
}

/**
 * Builds a Gleam list of [name, value] tuples from a form's FormData.
 * Skips File entries (only string values are passed through).
 */
function formDataToList(form) {
  const entries = [];
  for (const [name, value] of new FormData(form)) {
    if (typeof value === "string") entries.push([name, value]);
  }
  let list = new Empty();
  for (let i = entries.length - 1; i >= 0; i--) {
    list = new NonEmpty(entries[i], list);
  }
  return list;
}

// Standard focusable-elements selector, used by setupFocusTrap to enumerate
// Tab stops inside a container.
const FOCUSABLE_SELECTOR = [
  "a[href]",
  "area[href]",
  "button:not([disabled])",
  'input:not([disabled]):not([type="hidden"])',
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])',
  '[contenteditable]:not([contenteditable="false"])',
].join(",");

// Singleton trap state, holds the keydown listener so releaseFocusTrap can
// detach it. Only one trap is active at a time; nested-modal scenarios fall
// outside the current scope.
let activeTrap = null;

/** Attach the trap keydown listener once the container has rendered. */
function activateTrap(within, releaseOn, onExit) {
  const container = document.querySelector(within);
  if (!container) return;

  const handler = (event) => {
    // User-defined exit, runs first so it wins over Tab cycling
    if (releaseOn(event.key)) {
      event.preventDefault();
      releaseFocusTrap();
      onExit();
      return;
    }
    if (event.key !== "Tab") return;

    const focusables = Array.from(
      container.querySelectorAll(FOCUSABLE_SELECTOR),
    ).filter((element) => element.offsetParent !== null);
    if (focusables.length === 0) {
      event.preventDefault();
      return;
    }
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    const current = document.activeElement;

    if (event.shiftKey && current === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && current === last) {
      event.preventDefault();
      first.focus();
    } else if (!container.contains(current)) {
      // Focus drifted outside (e.g. window blurred and refocused), pull back
      event.preventDefault();
      first.focus();
    }
  };

  // Capture phase so the trap sees Tab before any element-level handlers
  document.addEventListener("keydown", handler, true);
  activeTrap = handler;
}

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

// click events

/**
 * Attaches a click event handler with data-msg attribute delegation and
 * options.
 */
export function setupClickEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest("[data-msg]");
    if (!matched) return;
    handler(matched.getAttribute("data-msg"));
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener("click", listener);
}

// coordinate events (coords only, no element data)

/**
 * Attaches a coordinate event (mouse/touch/pointer) with x,y position and
 * options.
 */
export function setupCoordinateEventWithOptions(selector, eventName, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.clientX, event.clientY);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener(eventName, listener);
}

// coordinate + element data events

/**
 * Attaches a coordinate event with x,y position, the matched element's
 * data-* attributes, and options. preventDefault is hoisted outside
 * debounce/throttle so drop targets stay receptive even when the inner
 * handler is suppressed. Uses event delegation via document so it works on
 * dynamically-rendered lists.
 */
export function setupCoordinateElementEventWithOptions(
  selector,
  eventName,
  options,
  makeElementData,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    handler(event.clientX, event.clientY, makeElementData(datasetToList(matched)));
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(eventName, listener);
}

// element data events (no coords)

/**
 * Attaches an element-delegated event that provides the matched element's
 * data-* attributes to the handler, with options. Non-bubbling events
 * (mouseenter, mouseleave, focus, blur) are mapped to their bubbling
 * equivalents with a relatedTarget guard to preserve semantics.
 */
export function setupElementEventWithOptions(
  selector,
  eventName,
  options,
  makeElementData,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const domEvent = delegatedEventName(eventName);
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    if (shouldSkipDelegatedEvent(eventName, matched, event.relatedTarget)) return;
    handler(makeElementData(datasetToList(matched)));
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(domEvent, listener);
}

// focus events

/** Move focus to the first match of selector after the next paint. */
export function setupFocus(selector) {
  // Two rAFs guard against the case where the dispatch that reveals the
  // target was itself batched into the next frame (Lily's render loop).
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      const element = document.querySelector(selector);
      if (element && typeof element.focus === "function") element.focus();
    });
  });
}

/** Activate Tab-cycling focus trap; releases on releaseOn(key) === true. */
export function setupFocusTrap(within, releaseOn, onExit) {
  releaseFocusTrap();

  // Defer activation by two frames so a dispatch that just rendered the
  // container has a chance to flush, mirrors the rAF strategy in setupFocus.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      activateTrap(within, releaseOn, onExit);
    });
  });
}

/** Remove the active focus trap (no on_exit dispatch). */
export function releaseFocusTrap() {
  if (activeTrap === null) return;
  document.removeEventListener("keydown", activeTrap, true);
  activeTrap = null;
}

// form events

/**
 * Attaches an input handler to a form element, passing current FormData as a
 * Gleam list of name/value tuples. Fires on any field change (input bubbles up
 * to the form). No preventDefault, no reset. Uses delegation at document so
 * forms re-rendered by innerHTML updates keep firing.
 */
export function setupFormChangeEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    const form =
      matched instanceof HTMLFormElement ? matched : matched.closest("form");
    if (!(form instanceof HTMLFormElement)) return;
    handler(formDataToList(form));
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener("input", listener);
}

// identity (used by Gleam unsafe_cast)

/**
 * Identity, used by Gleam-side unsafe_cast for phantom-typed Event
 * payloads.
 */
export function identity(value) {
  return value;
}

// key events (with modifiers)

/**
 * Attaches a keyboard event that passes key name and modifier flags, with
 * options.
 */
export function setupKeyFullEventWithOptions(
  selector,
  eventName,
  options,
  makeKeyEvent,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    handler(makeKeyEvent(event.key, event.ctrlKey, event.shiftKey, event.altKey, event.metaKey));
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(eventName, listener);
}

// scroll position events

/**
 * Attaches a scroll event that passes the element's scrollTop and scrollLeft
 * values (not delta, absolute position), with options.
 */
export function setupScrollPositionEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest?.("[data-lily-disabled]")) return;
    const element = event.target;
    handler(element.scrollTop ?? 0, element.scrollLeft ?? 0);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener("scroll", listener);
}

// simple events (no data)

/** Attaches a simple event with no event data, with options */
export function setupSimpleEventWithOptions(selector, eventName, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler();
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener(eventName, listener);
}

// submit events

/**
 * Attaches a submit handler that extracts FormData entries as a Gleam list of
 * name/value tuples, calls the handler, then resets the form. preventDefault
 * fires unconditionally so the browser does not navigate away. File uploads
 * are skipped. Uses delegation at document so every form matching the
 * selector is handled, including forms rendered after setup.
 */
export function setupSubmitFormEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation] = options;
  let listener = (event) => {
    const form = event.target.closest(selector);
    if (!(form instanceof HTMLFormElement)) return;
    if (form.closest("[data-lily-disabled]")) return;
    handler(formDataToList(form));
    form.reset();
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  // preventDefault is unconditional for submit, the browser would
  // otherwise navigate before the handler can run. Wrap before applyOptions
  // would put preventDefault behind debounce/throttle gates, so we layer
  // it on top.
  const inner = listener;
  listener = (event) => {
    event.preventDefault();
    inner(event);
  };
  document.addEventListener("submit", listener);
}

// value events

/** Attaches an input/change event with input value, with options */
export function setupValueEventWithOptions(selector, eventName, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.target.value || "");
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener(eventName, listener);
}

// wheel events

/** Attaches a wheel event with deltaX and deltaY values, with options */
export function setupWheelEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] = options;
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.deltaX, event.deltaY);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener("wheel", listener);
}
