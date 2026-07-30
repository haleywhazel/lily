/**
 * TEST SUPPORT FFI
 *
 * Consolidated JavaScript helpers for the lily test suite: jsdom setup and
 * mock browser APIs, DOM inspection and event dispatch, a mutable reference
 * cell, and storage helpers. Module-level side effects run once on first
 * import, patching globals before any test code runs. Each test should call
 * resetDom() to get a clean slate.
 */

import { JSDOM } from "jsdom";
import { NonEmpty, Empty } from "../gleam.mjs";

// =============================================================================
// JSDOM ENVIRONMENT
// =============================================================================

const dom = new JSDOM(
  '<!DOCTYPE html><html><body><div id="app"></div><div id="overlays"></div></body></html>',
  { url: "http://localhost:8080", pretendToBeVisual: true },
);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.localStorage = dom.window.localStorage;
globalThis.sessionStorage = dom.window.sessionStorage;
// Use a synchronous requestAnimationFrame stub so notifications flush
// immediately in tests. jsdom's RAF uses setTimeout internally which causes
// recursion when globalThis.setTimeout is replaced.
globalThis.requestAnimationFrame = (cb) => { cb(0); };
globalThis.location = dom.window.location;
globalThis.Event = dom.window.Event;
globalThis.FormData = dom.window.FormData;
globalThis.HTMLFormElement = dom.window.HTMLFormElement;
globalThis.KeyboardEvent = dom.window.KeyboardEvent;
globalThis.MouseEvent = dom.window.MouseEvent;
globalThis.WheelEvent = dom.window.WheelEvent;

// =============================================================================
// MOCK WEBSOCKET
// =============================================================================

class MockWebSocket {
  static OPEN = 1;
  static CLOSED = 3;

  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this._sent = [];
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
    lastWs = this;
  }

  send(data) {
    this._sent.push(data);
  }

  close() {
    this.readyState = MockWebSocket.CLOSED;
    if (this.onclose) this.onclose();
  }
}

globalThis.WebSocket = MockWebSocket;

// =============================================================================
// MOCK EVENTSOURCE
// =============================================================================

class MockEventSource {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    lastEs = this;
  }

  close() {
    this.readyState = 2;
  }
}

globalThis.EventSource = MockEventSource;

// =============================================================================
// MOCK FETCH (Node 18+ has fetch, but ensure consistent behaviour)
// =============================================================================

globalThis.fetch = async (_url, _opts) => ({ ok: true, status: 200 });

// =============================================================================
// LAST-CREATED MOCK TRACKING
// =============================================================================

let lastWs = null;
let lastEs = null;

// =============================================================================
// SETUP / RESET EXPORTS
// =============================================================================

export function setup() {
  // Globals already patched at import time, this is a no-op kept for
  // explicitness when test files call setup() at the top of each test.
}

export function resetDom() {
  dom.window.document.body.innerHTML =
    '<div id="app"></div><div id="overlays"></div>';
  dom.window.localStorage.clear();
  dom.window.sessionStorage.clear();
}

export function resetHotReloadInstalled() {
  delete dom.window.__lilyHotReloadInstalled;
}

export function historyLength() {
  return dom.window.history.length;
}

export function resetUrl() {
  // jsdom keeps history across tests, reset to "/" so URL-sensitive tests
  // start from a known state.
  dom.window.history.replaceState({}, "", "/");
}

export function injectSnapshotScript(json) {
  // Mimic what transport.encode_initial_snapshot produces server-side, so
  // client.hydrate tests can read it via document.getElementById.
  const script = dom.window.document.createElement("script");
  script.type = "application/json";
  script.id = "lily-snapshot";
  script.textContent = json;
  dom.window.document.body.appendChild(script);
}

export function resetMocks() {
  lastWs = null;
  lastEs = null;
}

export function getLastWebSocket() {
  return lastWs;
}

export function getLastEventSource() {
  return lastEs;
}

// WebSocket test helpers, trigger lifecycle events on a mock instance
export function triggerWebSocketOpen(ws) {
  ws.readyState = MockWebSocket.OPEN;
  if (ws.onopen) ws.onopen();
}

export function triggerWebSocketMessage(ws, data) {
  if (ws.onmessage) ws.onmessage({ data });
}

export function triggerWebSocketClose(ws) {
  ws.readyState = MockWebSocket.CLOSED;
  if (ws.onclose) ws.onclose();
}

export function getWebSocketSent(ws) {
  // Convert JS array to Gleam list, decode ArrayBuffers to UTF-8 strings so
  // tests can use string.contains() on the sent frames.
  let result = new Empty();
  for (let i = ws._sent.length - 1; i >= 0; i--) {
    let item = ws._sent[i];
    if (item instanceof ArrayBuffer || item instanceof Uint8Array) {
      item = new TextDecoder().decode(item);
    }
    result = new NonEmpty(item, result);
  }
  return result;
}

// EventSource test helpers
export function triggerEventSourceOpen(es) {
  if (es.onopen) es.onopen();
}

export function triggerEventSourceMessage(es, data) {
  if (es.onmessage) es.onmessage({ data });
}

export function triggerEventSourceError(es) {
  if (es.onerror) es.onerror(new globalThis.Event("error"));
}

// =============================================================================
// DOM INSPECTION AND EVENT DISPATCH
// =============================================================================

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

/**
 * Dispatch a cancelable key event and report whether a handler consumed it
 * (called preventDefault). Lets a test observe a keydown handler's effect
 * directly, without depending on document-delegated listeners that persist
 * and interfere across tests.
 */
export function dispatchKeyEventDefaultPrevented(selector, eventName, key) {
  const el = document.querySelector(selector);
  if (!el) return false;
  const event = new KeyboardEvent(eventName, {
    key,
    bubbles: true,
    cancelable: true,
  });
  el.dispatchEvent(event);
  return event.defaultPrevented;
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
  // blur/focus don't bubble, dispatch their bubbling equivalents so document-
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

export function focus(selector) {
  const el = document.querySelector(selector);
  if (el && typeof el.focus === "function") el.focus();
}

export function activeElementId() {
  return document.activeElement ? document.activeElement.id ?? "" : "";
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

// =============================================================================
// STORAGE HELPERS
// =============================================================================

export function writeLocalStorage(key, value) {
  localStorage.setItem(key, value);
}

export function readLocalStorage(key) {
  return localStorage.getItem(key) ?? "";
}

export function writeSessionStorage(key, value) {
  sessionStorage.setItem(key, value);
}

export function readSessionStorage(key) {
  return sessionStorage.getItem(key) ?? "";
}

// =============================================================================
// REFERENCE CELL
// =============================================================================

export function newRef(value) {
  return { value };
}

export function getRef(ref) {
  return ref.value;
}

export function setRef(ref, value) {
  ref.value = value;
  return undefined;
}
