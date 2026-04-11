/**
 * This mjs file attaches event listeners to DOM elements. Events are attached
 * once and persist for the lifetime of the page. Handlers call back into Gleam
 * code which sends messages to the store.
 */

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
