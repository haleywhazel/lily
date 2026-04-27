/**
 * This mjs file attaches event listeners to DOM elements. Events are attached
 * once and persist for the lifetime of the page. Handlers call back into Gleam
 * code which sends messages to the store.
 *
 * The *WithOptions variants accept debounce_ms, throttle_ms, once,
 * stop_propagation, and prevent_default parameters (debounce_ms and
 * throttle_ms are -1 when disabled). applyOptions wraps a raw DOM event
 * listener with these behaviours. preventDefaultFirst wraps the listener so
 * that preventDefault fires on every event even when debounce/throttle would
 * skip the inner handler.
 *
 * setupElementEvent / setupCoordinateElementEvent use event delegation and
 * attach to document rather than a single queried element, so they work
 * correctly with dynamically-rendered lists (e.g. each/each_live). Non-
 * bubbling events (mouseenter/mouseleave, focus/blur) are mapped to their
 * bubbling equivalents (mouseover/mouseout, focusin/focusout) with a
 * relatedTarget guard to preserve enter/leave semantics.
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
  const attrs = Array.from(element.attributes);
  for (let i = attrs.length - 1; i >= 0; i--) {
    const attr = attrs[i];
    if (attr.name.startsWith("data-")) {
      list = new NonEmpty([attr.name.slice(5), attr.value], list);
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

// =============================================================================
// EXPORT FUNCTIONS — CLICK
// =============================================================================

/** Attaches a click event handler with data-msg attribute delegation */
export function setupClickEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("click", (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest("[data-msg]");
    if (!matched) return;
    handler(matched.getAttribute("data-msg"));
  });
}

/** Like setupClickEvent but with debounce/throttle/once/stopPropagation/preventDefault */
export function setupClickEventWithOptions(
  selector,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  handler,
) {
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

// =============================================================================
// EXPORT FUNCTIONS — COORDINATE (coords only, no element data)
// =============================================================================

/** Attaches a coordinate event (mouse/touch/pointer) with x,y position */
export function setupCoordinateEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.clientX, event.clientY);
  });
}

/** Like setupCoordinateEvent but with debounce/throttle/once/stopPropagation/preventDefault */
export function setupCoordinateEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  handler,
) {
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

// =============================================================================
// EXPORT FUNCTIONS — COORDINATE + ELEMENT DATA
// =============================================================================

/**
 * Attaches a coordinate event with x,y position and the matched element's
 * data-* attributes. Uses event delegation via document so it works on
 * dynamically-rendered lists.
 */
export function setupCoordinateElementEvent(
  selector,
  eventName,
  makeElementData,
  handler,
) {
  document.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    handler(event.clientX, event.clientY, makeElementData(datasetToList(matched)));
  });
}

/**
 * Like setupCoordinateElementEvent but with options. preventDefault is hoisted
 * outside debounce/throttle so drop targets stay receptive even when the
 * inner handler is suppressed.
 */
export function setupCoordinateElementEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  makeElementData,
  handler,
) {
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

// =============================================================================
// EXPORT FUNCTIONS — ELEMENT DATA (no coords)
// =============================================================================

/**
 * Attaches an element-delegated event that provides the matched element's
 * data-* attributes to the handler. Non-bubbling events (mouseenter,
 * mouseleave, focus, blur) are mapped to their bubbling equivalents with a
 * relatedTarget guard to preserve semantics.
 */
export function setupElementEvent(selector, eventName, makeElementData, handler) {
  const domEvent = delegatedEventName(eventName);
  document.addEventListener(domEvent, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    if (shouldSkipDelegatedEvent(eventName, matched, event.relatedTarget)) return;
    handler(makeElementData(datasetToList(matched)));
  });
}

/** Like setupElementEvent but with options. */
export function setupElementEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  makeElementData,
  handler,
) {
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

// =============================================================================
// EXPORT FUNCTIONS — FORM
// =============================================================================

/**
 * Attaches an input handler to a form element, passing current FormData as a
 * Gleam list of name/value tuples. Fires on any field change (input bubbles up
 * to the form). No preventDefault, no reset. Uses delegation at document so
 * forms re-rendered by innerHTML updates keep firing.
 */
export function setupFormChangeEvent(selector, handler) {
  document.addEventListener("input", (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    const form =
      matched instanceof HTMLFormElement ? matched : matched.closest("form");
    if (!(form instanceof HTMLFormElement)) return;
    const entries = Array.from(new FormData(form).entries()).filter(
      ([, value]) => typeof value === "string",
    );
    let list = new Empty();
    for (let i = entries.length - 1; i >= 0; i--) {
      list = new NonEmpty(entries[i], list);
    }
    handler(list);
  });
}

// =============================================================================
// EXPORT FUNCTIONS — KEY (with modifiers)
// =============================================================================

/**
 * Attaches a keyboard event that passes key name and modifier flags (ctrl,
 * shift, alt, meta) to the handler via the makeKeyEvent constructor.
 */
export function setupKeyFullEvent(selector, eventName, makeKeyEvent, handler) {
  document.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    handler(makeKeyEvent(event.key, event.ctrlKey, event.shiftKey, event.altKey, event.metaKey));
  });
}

/** Like setupKeyFullEvent but with options. */
export function setupKeyFullEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  makeKeyEvent,
  handler,
) {
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

// =============================================================================
// EXPORT FUNCTIONS — SCROLL POSITION
// =============================================================================

/**
 * Attaches a scroll event that passes the element's scrollTop and scrollLeft
 * values (not delta — absolute position).
 */
export function setupScrollPositionEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("scroll", (event) => {
    if (event.target.closest?.("[data-lily-disabled]")) return;
    const el = event.target;
    handler(el.scrollTop ?? 0, el.scrollLeft ?? 0);
  });
}

/** Like setupScrollPositionEvent but with options. */
export function setupScrollPositionEventWithOptions(
  selector,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest?.("[data-lily-disabled]")) return;
    const el = event.target;
    handler(el.scrollTop ?? 0, el.scrollLeft ?? 0);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  if (preventDefault) listener = preventDefaultFirst(listener);
  target.addEventListener("scroll", listener);
}

// =============================================================================
// EXPORT FUNCTIONS — SIMPLE (no data)
// =============================================================================

/** Attaches a simple event with no event data */
export function setupSimpleEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler();
  });
}

/** Like setupSimpleEvent but with debounce/throttle/once/stopPropagation/preventDefault */
export function setupSimpleEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  handler,
) {
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

/** Attaches a simple event with preventDefault called */
export function setupSimpleEventWithPreventDefault(
  selector,
  eventName,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    event.preventDefault();
    if (event.target.closest("[data-lily-disabled]")) return;
    handler();
  });
}

// =============================================================================
// EXPORT FUNCTIONS — SUBMIT
// =============================================================================

/**
 * Attaches a submit handler that extracts FormData entries as a Gleam list of
 * name/value tuples, calls the handler, then resets the form. preventDefault
 * is called so the browser does not navigate away. File uploads are skipped.
 * Uses delegation at document so every form matching the selector is handled,
 * including forms rendered after setup.
 */
export function setupSubmitFormEvent(selector, handler) {
  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (!form.matches(selector)) return;
    event.preventDefault();
    if (form.closest("[data-lily-disabled]")) return;
    const entries = Array.from(new FormData(form).entries()).filter(
      ([, value]) => typeof value === "string",
    );
    let list = new Empty();
    for (let i = entries.length - 1; i >= 0; i--) {
      list = new NonEmpty(entries[i], list);
    }
    handler(list);
    form.reset();
  });
}

// =============================================================================
// EXPORT FUNCTIONS — VALUE
// =============================================================================

/** Attaches an input/change event with input value */
export function setupValueEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.target.value || "");
  });
}

/** Like setupValueEvent but with debounce/throttle/once/stopPropagation/preventDefault */
export function setupValueEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  handler,
) {
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

// =============================================================================
// EXPORT FUNCTIONS — WHEEL
// =============================================================================

/** Attaches a wheel event with deltaX and deltaY values */
export function setupWheelEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("wheel", (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.deltaX, event.deltaY);
  });
}

/** Like setupWheelEvent but with debounce/throttle/once/stopPropagation/preventDefault */
export function setupWheelEventWithOptions(
  selector,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  preventDefault,
  handler,
) {
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
