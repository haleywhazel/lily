/**
 * TEST SUPPORT
 *
 * jsdom with mock WebSocket, EventSource and fetch. Globals are patched once
 * on first import, call resetDom() for a clean slate.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { JSDOM, VirtualConsole } from "jsdom";
import { Empty, NonEmpty, toList } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Empty when nothing has focus. */
export function activeElementId() {
  return document.activeElement ? document.activeElement.id ?? "" : "";
}

/** `#(method, text)` per console line. */
export function captureLogLevels(thunk) {
  const seen = [];
  const original = {};
  for (const level of ["debug", "info", "warn", "error"]) {
    original[level] = console[level];
    console[level] = (...parts) => seen.push([level, parts.join(" ")]);
  }
  try {
    thunk();
  } finally {
    Object.assign(console, original);
  }
  return toList(seen);
}

/** Console error and warn lines. */
export function captureLogs(thunk) {
  const lines = [];
  const original = { error: console.error, warn: console.warn };
  console.error = (...parts) => lines.push(parts.join(" "));
  console.warn = (...parts) => lines.push(parts.join(" "));
  try {
    thunk();
  } finally {
    console.error = original.error;
    console.warn = original.warn;
  }
  return toList(lines);
}

/** Bubbling, cancelable, at the first match. */
export function click(selector) {
  const element = document.querySelector(selector);
  if (element)
    element.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true }),
    );
}

export function clickPrevented(selector) {
  const element = document.querySelector(selector);
  if (!element) return false;
  const event = new MouseEvent("click", { bubbles: true, cancelable: true });
  element.dispatchEvent(event);
  return event.defaultPrevented;
}

export function clickPreventedWithCtrl(selector) {
  const element = document.querySelector(selector);
  if (!element) return false;
  const event = new MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    ctrlKey: true,
  });
  element.dispatchEvent(event);
  return event.defaultPrevented;
}

/** `#(querySelector calls, insertBefore calls)` made by the thunk. */
export function countDomCalls(thunk) {
  const documentProto = dom.window.Document.prototype;
  const nodeProto = dom.window.Node.prototype;
  const originalQuery = documentProto.querySelector;
  const originalInsert = nodeProto.insertBefore;
  let queries = 0;
  let inserts = 0;
  documentProto.querySelector = function (...parts) {
    queries++;
    return originalQuery.apply(this, parts);
  };
  nodeProto.insertBefore = function (...parts) {
    inserts++;
    return originalInsert.apply(this, parts);
  };
  try {
    thunk();
  } finally {
    documentProto.querySelector = originalQuery;
    nodeProto.insertBefore = originalInsert;
  }
  return [queries, inserts];
}

/** Sets checked, then fires change. */
export function dispatchCheckEvent(selector, checked) {
  const element = document.querySelector(selector);
  if (!element) return;
  element.checked = checked;
  element.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Sets value, then fires `input` and `change`. */
export function dispatchInputEvent(selector, value) {
  const element = document.querySelector(selector);
  if (!element) return;
  element.value = value;
  element.dispatchEvent(new Event("input", { bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Bubbling, at the first match. */
export function dispatchKeyEvent(selector, eventName, key) {
  const element = document.querySelector(selector);
  if (element) {
    element.dispatchEvent(new KeyboardEvent(eventName, { key, bubbles: true }));
  }
}

/** Bubbling, at a viewport position. */
export function dispatchMouseEvent(selector, eventName, clientX, clientY) {
  const element = document.querySelector(selector);
  if (element)
    element.dispatchEvent(
      new MouseEvent(eventName, {
        clientX,
        clientY,
        bubbles: true,
        cancelable: true,
      }),
    );
}

/** Whether a handler prevented the default. */
export function dispatchSubmit(selector) {
  const element = document.querySelector(selector);
  if (!element) return false;
  const event = new Event("submit", { bubbles: true, cancelable: true });
  element.dispatchEvent(event);
  return event.defaultPrevented;
}

/** Drops listeners left by earlier tests. */
export function dropDocumentClickListeners() {
  for (const [listener, options] of documentClickListeners) {
    dom.window.document.removeEventListener("click", listener, options);
  }
  documentClickListeners.length = 0;
}

/** Bubbling, at the first match. */
export function fireAnimationEnd(selector) {
  const element = document.querySelector(selector);
  if (!element) return;
  const event = new dom.window.Event("animationend", { bubbles: true });
  element.dispatchEvent(event);
}

/** Bubbling, detail is { value }. */
export function fireCustomEvent(selector, eventName, value) {
  const element = document.querySelector(selector);
  if (element) {
    element.dispatchEvent(
      new CustomEvent(eventName, { bubbles: true, detail: { value } }),
    );
  }
}

/** Plain event at the first match. */
export function fireEvent(selector, eventName, bubbles) {
  const element = document.querySelector(selector);
  if (element) {
    element.dispatchEvent(new Event(eventName, { bubbles, cancelable: true }));
  }
}

export function focus(selector) {
  const element = document.querySelector(selector);
  if (element && typeof element.focus === "function") element.focus();
}

/** Empty when absent. */
export function getAttribute(selector, name) {
  const element = document.querySelector(selector);
  return element ? element.getAttribute(name) ?? "" : "";
}

/** False when absent. */
export function getChecked(selector) {
  return document.querySelector(selector)?.checked === true;
}

/** Empty when absent. */
export function getInnerHtml(selector) {
  const element = document.querySelector(selector);
  return element ? element.innerHTML : "";
}

/** Null after a reset. */
export function getLastEventSource() {
  return lastEventSource;
}

/** Null after a reset. */
export function getLastWebSocket() {
  return lastWebSocket;
}

export function getRef(ref) {
  return ref.value;
}

/** Empty when absent. */
export function getText(selector) {
  const element = document.querySelector(selector);
  return element ? element.textContent ?? "" : "";
}

/** Empty when absent. */
export function getValue(selector) {
  const element = document.querySelector(selector);
  return element ? (element.value ?? "") : "";
}

/** Oldest first, as text. */
export function getWebSocketSent(socket) {
  // decoded to text so tests can string.contains() them
  let result = new Empty();
  for (let index = socket._sent.length - 1; index >= 0; index--) {
    let item = socket._sent[index];
    if (item instanceof ArrayBuffer || item instanceof Uint8Array) {
      item = new TextDecoder().decode(item);
    }
    result = new NonEmpty(item, result);
  }
  return result;
}

export function historyLength() {
  return dom.window.history.length;
}

/** The script `store.initial_snapshot` would render. */
export function injectSnapshotScript(base64) {
  const script = dom.window.document.createElement("script");
  script.type = "application/octet-stream";
  script.id = "lily-snapshot";
  script.textContent = base64;
  dom.window.document.body.appendChild(script);
}

/** Reloads and assigns jsdom was asked for. */
export function navigationCount() {
  return navigations;
}

export function newRef(value) {
  return { value };
}

/** No history entry. */
export function popstateTo(path) {
  dom.window.history.replaceState({}, "", path);
  dom.window.dispatchEvent(new dom.window.PopStateEvent("popstate"));
}

/** Empty when absent. */
export function readLocalStorage(key) {
  return localStorage.getItem(key) ?? "";
}

/** Empty when absent. */
export function readSessionStorage(key) {
  return sessionStorage.getItem(key) ?? "";
}

/** Empty mount points, both storages cleared. */
export function resetDom() {
  dom.window.document.body.innerHTML =
    '<div id="app"></div><div id="overlays"></div>';
  dom.window.localStorage.clear();
  dom.window.sessionStorage.clear();
}

export function resetHotReloadInstalled() {
  delete dom.window.__lilyHotReloadInstalled;
}

export function resetMocks() {
  lastWebSocket = null;
  lastEventSource = null;
}

export function resetUrl() {
  // jsdom keeps history across tests
  dom.window.history.replaceState({}, "", "/");
}

export function setInnerHtml(selector, html) {
  const element = document.querySelector(selector);
  if (element) element.innerHTML = html;
}

export function setRef(ref, value) {
  ref.value = value;
  return undefined;
}

/** As a dropped stream does. */
export function triggerEventSourceError(source) {
  source.readyState = 0;
  if (source.onerror) source.onerror(new globalThis.Event("error"));
}

export function triggerEventSourceMessage(source, data) {
  if (source.onmessage) source.onmessage({ data });
}

export function triggerEventSourceOpen(source) {
  source.readyState = 1;
  if (source.onopen) source.onopen();
}

/** Server-side close. */
export function triggerWebSocketClose(socket) {
  socket.readyState = MockWebSocket.CLOSED;
  if (socket.onclose) socket.onclose();
}

export function triggerWebSocketMessage(socket, data) {
  if (socket.onmessage) socket.onmessage({ data });
}

export function triggerWebSocketOpen(socket) {
  socket.readyState = MockWebSocket.OPEN;
  if (socket.onopen) socket.onopen();
}

export function websocketUrl(socket) {
  return socket.url;
}

export function writeLocalStorage(key, value) {
  localStorage.setItem(key, value);
}

export function writeSessionStorage(key, value) {
  sessionStorage.setItem(key, value);
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// jsdom's not-implemented errors from reload() and assign() count page loads
let navigations = 0;
const virtualConsole = new VirtualConsole();
virtualConsole.sendTo(console, { omitJSDOMErrors: true });
virtualConsole.on("jsdomError", (error) => {
  if (String(error.message).includes("navigation")) navigations++;
  else console.error(error);
});

const dom = new JSDOM(
  "<!DOCTYPE html><html><body>" +
    '<div id="app"></div><div id="overlays"></div></body></html>',
  { url: "http://localhost:8080", pretendToBeVisual: true, virtualConsole },
);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.localStorage = dom.window.localStorage;
globalThis.sessionStorage = dom.window.sessionStorage;
// sync RAF, jsdom's recurses through a replaced setTimeout
globalThis.requestAnimationFrame = (callback) => {
  callback(0);
};
globalThis.location = dom.window.location;
globalThis.Event = dom.window.Event;
globalThis.FormData = dom.window.FormData;
globalThis.CustomEvent = dom.window.CustomEvent;
globalThis.HTMLFormElement = dom.window.HTMLFormElement;
globalThis.KeyboardEvent = dom.window.KeyboardEvent;
globalThis.MouseEvent = dom.window.MouseEvent;
globalThis.WheelEvent = dom.window.WheelEvent;

// recorded so tests can drop leftovers, runtimes never die in a shared jsdom
const documentClickListeners = [];
const addDocumentListener = dom.window.document.addEventListener.bind(
  dom.window.document,
);
dom.window.document.addEventListener = (type, listener, options) => {
  if (type === "click") documentClickListeners.push([listener, options]);
  addDocumentListener(type, listener, options);
};

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
    lastWebSocket = this;
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

class MockEventSource {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    lastEventSource = this;
  }

  close() {
    this.readyState = 2;
  }
}

globalThis.EventSource = MockEventSource;

globalThis.fetch = async (_url, _options) => ({ ok: true, status: 200 });

let lastWebSocket = null;
let lastEventSource = null;
