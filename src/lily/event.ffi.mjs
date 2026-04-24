/**
 * This mjs file attaches event listeners to DOM elements. Events are attached
 * once and persist for the lifetime of the page. Handlers call back into Gleam
 * code which sends messages to the store.
 *
 * The *WithOptions variants accept debounce_ms, throttle_ms, once, and
 * stop_propagation parameters (debounce_ms and throttle_ms are -1 when
 * disabled). applyOptions wraps a raw DOM event listener with these behaviours.
 */

import { NonEmpty, Empty } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
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

/** Like setupClickEvent but with debounce/throttle/once/stopPropagation */
export function setupClickEventWithOptions(
  selector,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
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
  target.addEventListener("click", listener);
}

/** Attaches a coordinate event (mouse/touch/pointer) with x,y position */
export function setupCoordinateEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.clientX, event.clientY);
  });
}

/** Like setupCoordinateEvent but with debounce/throttle/once/stopPropagation */
export function setupCoordinateEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.clientX, event.clientY);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  target.addEventListener(eventName, listener);
}

/**
 * Attaches an input handler to a form element, passing current FormData as a
 * Gleam list of name/value tuples. Fires on any field change (input bubbles up
 * to the form). No preventDefault, no reset.
 */
export function setupFormChangeEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("input", (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const form = event.target.closest("form") ?? event.target;
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

/** Attaches a keyboard event with key value */
export function setupKeyEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.key);
  });
}

/** Like setupKeyEvent but with debounce/throttle/once/stopPropagation */
export function setupKeyEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.key);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  target.addEventListener(eventName, listener);
}

/** Attaches a simple event with no event data */
export function setupSimpleEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler();
  });
}

/** Like setupSimpleEvent but with debounce/throttle/once/stopPropagation */
export function setupSimpleEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler();
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
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

/**
 * Attaches a submit handler that extracts FormData entries as a Gleam list of
 * name/value tuples, calls the handler, then resets the form. preventDefault
 * is called so the browser does not navigate away. File uploads are skipped.
 */
export function setupSubmitFormEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("submit", (event) => {
    event.preventDefault();
    if (event.target.closest("[data-lily-disabled]")) return;
    const form = event.target;
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

/** Attaches an input/change event with input value */
export function setupValueEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.target.value || "");
  });
}

/** Like setupValueEvent but with debounce/throttle/once/stopPropagation */
export function setupValueEventWithOptions(
  selector,
  eventName,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.target.value || "");
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  target.addEventListener(eventName, listener);
}

/** Attaches a wheel event with deltaX and deltaY values */
export function setupWheelEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("wheel", (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.deltaX, event.deltaY);
  });
}

/** Like setupWheelEvent but with debounce/throttle/once/stopPropagation */
export function setupWheelEventWithOptions(
  selector,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  handler,
) {
  const target = resolveTarget(selector);
  if (!target) return;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.deltaX, event.deltaY);
  };
  listener = applyOptions(listener, debounceMs, throttleMs, once, stopPropagation);
  target.addEventListener("wheel", listener);
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/** Resolves a selector to a DOM target (handles "document" and "window") */
function resolveTarget(selector) {
  if (selector === "document") return document;
  if (selector === "window") return window;
  return document.querySelector(selector);
}

/**
 * Wraps a raw DOM event listener with optional debounce, throttle, once, and
 * stopPropagation behaviours. debounceMs and throttleMs are -1 when disabled.
 * Applied in order: stopPropagation → once → throttle → debounce (outermost
 * last, so debounce gates before throttle fires).
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
