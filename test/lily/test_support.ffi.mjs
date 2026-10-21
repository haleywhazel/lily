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

/** The stubbed finite animation's rate, 0 when there is none. */
export function animationPlaybackRate(selector) {
  const element = document.querySelector(selector);
  const [animation] = element?.getAnimations?.({ subtree: true }) ?? [];
  return animation?.playbackRate ?? 0;
}

/** A page about to close, returns whether a guard asked to stay. */
export function beforeUnloadPrevented() {
  const event = new Event("beforeunload", { cancelable: true });
  dom.window.dispatchEvent(event);
  return event.defaultPrevented;
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

/** A keydown with a physical code, repeat and composing flags. */
export function dispatchKeyDetail(selector, key, code, repeat, composing) {
  document.querySelector(selector)?.dispatchEvent(
    new KeyboardEvent("keydown", {
      key,
      code,
      repeat,
      isComposing: composing,
      bubbles: true,
    }),
  );
}

/** Bubbling, at the first match. */
export function dispatchKeyEvent(selector, eventName, key) {
  const element = document.querySelector(selector);
  if (element) {
    element.dispatchEvent(new KeyboardEvent(eventName, { key, bubbles: true }));
  }
}

/** A media event at `currentTime`, which jsdom doesn't play. */
export function dispatchMedia(selector, eventName, currentTime) {
  const media = document.querySelector(selector);
  if (!media) return;
  Object.defineProperty(media, "currentTime", {
    value: currentTime,
    configurable: true,
  });
  media.dispatchEvent(new Event(eventName));
}

/** jsdom has no PointerEvent, its fields go on a MouseEvent. */
export function dispatchPointerDetail(selector, eventName, button, type) {
  const event = new MouseEvent(eventName, {
    clientX: 5,
    clientY: 6,
    button,
    bubbles: !eventName.endsWith("enter"),
    cancelable: true,
  });
  Object.defineProperty(event, "pointerId", { value: 7 });
  Object.defineProperty(event, "pointerType", { value: type });
  document.querySelector(selector)?.dispatchEvent(event);
  return event.defaultPrevented;
}

/** Whether a handler prevented the default. */
export function dispatchSubmit(selector) {
  const element = document.querySelector(selector);
  if (!element) return false;
  const event = new Event("submit", { bubbles: true, cancelable: true });
  element.dispatchEvent(event);
  return event.defaultPrevented;
}

/** A clipboard or drag event carrying `text`, true if prevented. */
export function dispatchTransfer(selector, eventName, text) {
  const event = new Event(eventName, { bubbles: true, cancelable: true });
  const transfer = {
    getData: (type) => (type === "text/plain" ? text : ""),
    setData(type) {
      this.types.push(type);
    },
    files: [],
    types: [],
  };
  const field = ["copy", "cut", "paste"].includes(eventName)
    ? "clipboardData"
    : "dataTransfer";
  Object.defineProperty(event, field, { value: transfer });
  document.querySelector(selector)?.dispatchEvent(event);
  return event.defaultPrevented;
}

export function dispatchWheel(selector, deltaY, deltaMode) {
  const event = new WheelEvent("wheel", {
    deltaY,
    deltaMode,
    bubbles: true,
    cancelable: true,
  });
  document.querySelector(selector)?.dispatchEvent(event);
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

/** Cancelable, with modifiers, returns whether a handler prevented it. */
export function keyEventPrevented(selector, eventName, key, ctrl, meta) {
  const element = document.querySelector(selector);
  if (!element) return false;
  const event = new KeyboardEvent(eventName, {
    key,
    ctrlKey: ctrl,
    metaKey: meta,
    bubbles: true,
    cancelable: true,
  });
  element.dispatchEvent(event);
  return event.defaultPrevented;
}

/** Reloads and assigns jsdom was asked for. */
export function navigationCount() {
  return navigations;
}

export function newRef(value) {
  return { value };
}

/** Tags of the connected elements a stubbed `kind` observer watches. */
export function observedTags(kind) {
  return toList(
    observers
      .filter((entry) => entry.kind === kind && entry.element.isConnected)
      .map((entry) => entry.element.tagName.toLowerCase()),
  );
}

/** Window and document listeners for `name` added and not removed. */
export function pageListenerCount(name) {
  return pageListeners.get(name) ?? 0;
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

export function resizeWindow(width, height) {
  Object.defineProperty(dom.window, "innerWidth", {
    value: width,
    configurable: true,
  });
  Object.defineProperty(dom.window, "innerHeight", {
    value: height,
    configurable: true,
  });
  dom.window.dispatchEvent(new Event("resize"));
}

/** jsdom doesn't scroll, the offsets are set then `scroll` fired. */
export function scrollTo(selector, top, left) {
  const element = document.querySelector(selector);
  if (!element) return;
  Object.defineProperty(element, "scrollTop", {
    value: top,
    configurable: true,
  });
  Object.defineProperty(element, "scrollLeft", {
    value: left,
    configurable: true,
  });
  element.dispatchEvent(new Event("scroll"));
}

/** jsdom can't pick files, a fake list then a change. */
export function setFiles(selector, names) {
  const input = document.querySelector(selector);
  if (!input) return;
  const files = names
    .toArray()
    .map((name) => ({ name, size: name.length, type: "text/plain" }));
  Object.defineProperty(input, "files", { value: files, configurable: true });
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

export function setInnerHtml(selector, html) {
  const element = document.querySelector(selector);
  if (element) element.innerHTML = html;
}

export function setOnline(online) {
  Object.defineProperty(globalThis.navigator, "onLine", {
    value: online,
    configurable: true,
  });
  dom.window.dispatchEvent(new Event(online ? "online" : "offline"));
}

export function setRef(ref, value) {
  ref.value = value;
  return undefined;
}

export function setVisibility(visible) {
  Object.defineProperty(document, "visibilityState", {
    value: visible ? "visible" : "hidden",
    configurable: true,
  });
  document.dispatchEvent(new Event("visibilitychange"));
}

/**
 * jsdom has no `getAnimations`. A finite fake runs on any element holding
 * `.className`, an infinite one everywhere, `unstubAnimations` undoes it.
 */
export function stubAnimations(className, milliseconds) {
  const fakes = new WeakMap();
  dom.window.Element.prototype.getAnimations = function (options) {
    const target = this.classList.contains(className)
      ? this
      : options?.subtree
        ? this.querySelector(`.${className}`)
        : null;
    if (!target) return [infinite];
    if (!fakes.has(target)) fakes.set(target, fakeAnimation(milliseconds));
    return [fakes.get(target), infinite];
  };
}

/** Records observers, `triggerResize` and `triggerVisible` report to them. */
export function stubObservers() {
  for (const kind of ["ResizeObserver", "IntersectionObserver"]) {
    dom.window[kind] = globalThis[kind] = class {
      constructor(callback) {
        this.callback = callback;
      }
      observe(element) {
        observers.push({ kind, observer: this, element });
      }
      disconnect() {
        observers = observers.filter((entry) => entry.observer !== this);
      }
    };
  }
}

/** As a dropped stream does. */
export function triggerEventSourceError(source) {
  source.readyState = 0;
  if (source.onerror) source.onerror(new globalThis.Event("error"));
}

export function triggerEventSourceOpen(source) {
  source.readyState = 1;
  if (source.onopen) source.onopen();
}

export function triggerResize(width, height) {
  for (const { kind, observer } of observers) {
    if (kind === "ResizeObserver") {
      observer.callback([{ contentRect: { width, height } }]);
    }
  }
}

export function triggerVisible(visible) {
  for (const { kind, observer } of observers) {
    if (kind === "IntersectionObserver") {
      observer.callback([{ isIntersecting: visible }]);
    }
  }
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

export function unstubAnimations() {
  delete dom.window.Element.prototype.getAnimations;
}

export function unstubObservers() {
  for (const kind of ["ResizeObserver", "IntersectionObserver"]) {
    delete dom.window[kind];
    delete globalThis[kind];
  }
  observers = [];
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
// FUNCTIONS
// =============================================================================

/** Plays at rate 1 or -1, `reverse` turns it round from where it is. */
function fakeAnimation(milliseconds) {
  let state = "running";
  let rate = 1;
  let played = 0;
  let since = Date.now();
  let timer = null;
  let resolve;
  const finished = new Promise((done) => (resolve = done));
  const position = () =>
    Math.min(milliseconds, Math.max(0, played + (Date.now() - since) * rate));
  const schedule = () => {
    clearTimeout(timer);
    const left = rate > 0 ? milliseconds - position() : position();
    timer = setTimeout(() => {
      state = "finished";
      resolve();
    }, left);
  };
  schedule();
  return {
    get playState() {
      return state;
    },
    get playbackRate() {
      return rate;
    },
    get currentTime() {
      return position();
    },
    effect: { getComputedTiming: () => ({ endTime: milliseconds }) },
    get finished() {
      return finished;
    },
    reverse() {
      played = position();
      since = Date.now();
      rate = -rate;
      schedule();
    },
  };
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const infinite = {
  playState: "running",
  currentTime: 0,
  effect: { getComputedTiming: () => ({ endTime: Infinity }) },
  finished: new Promise(() => {}),
};

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

// counted per event name, a stacking listener shows up here
const pageListeners = new Map();
for (const target of [dom.window, dom.window.document]) {
  const add = target.addEventListener.bind(target);
  const remove = target.removeEventListener.bind(target);
  // type to the listeners added on this target
  const listening = new Map();
  target.addEventListener = (type, listener, options) => {
    if (!listening.has(type)) listening.set(type, new Set());
    if (!listening.get(type).has(listener)) {
      listening.get(type).add(listener);
      pageListeners.set(type, (pageListeners.get(type) ?? 0) + 1);
    }
    add(type, listener, options);
  };
  target.removeEventListener = (type, listener, options) => {
    if (listening.get(type)?.delete(listener)) {
      pageListeners.set(type, pageListeners.get(type) - 1);
    }
    remove(type, listener, options);
  };
}

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

let observers = [];
