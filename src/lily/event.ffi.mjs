/**
 * This mjs file attaches event listeners to DOM elements. Events are attached
 * once and persist for the lifetime of the page. Handlers call back into Gleam
 * code which sends messages to the store.
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

/** Attaches a coordinate event (mouse/touch/pointer) with x,y position */
export function setupCoordinateEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.clientX, event.clientY);
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

/** Attaches a simple event with no event data */
export function setupSimpleEvent(selector, eventName, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener(eventName, (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler();
  });
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

/** Attaches a wheel event with deltaX and deltaY values */
export function setupWheelEvent(selector, handler) {
  const target = resolveTarget(selector);
  if (!target) return;
  target.addEventListener("wheel", (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.deltaX, event.deltaY);
  });
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/** Resolves a selector to a DOM target (handles "document" and "window") */
function resolveTarget(selector) {
  if (selector === "document") return document;
  if (selector === "window") return window;
  return document.querySelector(selector);
}
