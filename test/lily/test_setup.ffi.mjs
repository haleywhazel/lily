/**
 * TEST SETUP
 *
 * Patches globalThis with a jsdom environment and mock browser APIs.
 * Module-level side effects run once on first import, patching globals before
 * any test code runs. Each test should call resetDom() to get a clean slate.
 */

import { JSDOM } from "jsdom";
import { NonEmpty, Empty } from "../gleam.mjs";

// =============================================================================
// JSDOM ENVIRONMENT
// =============================================================================

const dom = new JSDOM(
  '<!DOCTYPE html><html><body><div id="app"></div></body></html>',
  { url: "http://localhost:8080", pretendToBeVisual: true },
);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.localStorage = dom.window.localStorage;
// Use a synchronous requestAnimationFrame stub so notifications flush immediately
// in tests. jsdom's RAF uses setTimeout internally which causes recursion when
// globalThis.setTimeout is replaced.
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
// EXPORTS
// =============================================================================

export function setup() {
  // Globals already patched at import time — this is a no-op kept for
  // explicitness when test files call setup() at the top of each test.
}

export function resetDom() {
  dom.window.document.body.innerHTML = '<div id="app"></div>';
  dom.window.localStorage.clear();
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

// WebSocket test helpers — trigger lifecycle events on a mock instance
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
  // Convert JS array to Gleam list; decode ArrayBuffers to UTF-8 strings so
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
