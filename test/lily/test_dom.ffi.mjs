/** DOM inspection and event dispatch helpers for JavaScript tests. */

export function getInnerHtml(selector) {
  const el = document.querySelector(selector);
  return el ? el.innerHTML : "";
}

export function setInnerHtml(selector, html) {
  const el = document.querySelector(selector);
  if (el) el.innerHTML = html;
}

export function click(selector) {
  const el = document.querySelector(selector);
  if (el)
    el.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true }),
    );
}

export function dispatchMouseEvent(selector, eventName, clientX, clientY) {
  const el = document.querySelector(selector);
  if (el)
    el.dispatchEvent(
      new MouseEvent(eventName, { clientX, clientY, bubbles: true, cancelable: true }),
    );
}

export function dispatchKeyEvent(selector, eventName, key) {
  const el = document.querySelector(selector);
  if (el) el.dispatchEvent(new KeyboardEvent(eventName, { key, bubbles: true }));
}

export function dispatchInputEvent(selector, value) {
  const el = document.querySelector(selector);
  if (!el) return;
  el.value = value;
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
}

export function dispatchWheelEvent(selector, deltaX, deltaY) {
  const el = document.querySelector(selector);
  if (el)
    el.dispatchEvent(
      new WheelEvent("wheel", { deltaX, deltaY, bubbles: true }),
    );
}

export function dispatchSimpleEvent(selector, eventName) {
  const el = document.querySelector(selector);
  if (!el) return;
  // blur/focus don't bubble; dispatch their bubbling equivalents so document-
  // delegated listeners (focusout/focusin) fire correctly in tests.
  const actualEvent =
    eventName === "blur" ? "focusout" :
    eventName === "focus" ? "focusin" :
    eventName;
  el.dispatchEvent(new Event(actualEvent, { bubbles: true }));
}

export function getAttribute(selector, name) {
  const el = document.querySelector(selector);
  return el ? el.getAttribute(name) ?? "" : "";
}

export function hasAttribute(selector, name) {
  const el = document.querySelector(selector);
  return el ? el.hasAttribute(name) : false;
}

export function getText(selector) {
  const el = document.querySelector(selector);
  return el ? el.textContent ?? "" : "";
}

export function setLocalStorageItem(key, value) {
  localStorage.setItem(key, value);
}

export function getLocalStorageItem(key) {
  return localStorage.getItem(key) ?? "";
}

export function hasLocalStorageItem(key) {
  return localStorage.getItem(key) !== null;
}
