// APP INITIALISATION & RUNTIME

let currentStore = null;
let applyMsg = null;
let notifyHandlers = null;

export function initialise(store, applyFn, notifyFn) {
  currentStore = store;
  applyMsg = applyFn;
  notifyHandlers = notifyFn;
}

export function set_store_ref(store) {
  currentStore = store;
}

// MESSAGE DISPATCH

let onMsgHook = null;

export function set_on_msg_hook(hook) {
  onMsgHook = hook;
}

export function send_msg(msg) {
  currentStore = applyMsg(currentStore, msg);
  if (onMsgHook) onMsgHook(msg);
  scheduleNotify(flushNotify);
}

export function apply_remote_msg(msg) {
  currentStore = applyMsg(currentStore, msg);
  scheduleNotify(flushNotify);
}

export function dispatch_model(model) {
  currentStore = { ...currentStore, model };
  scheduleNotify(flushNotify);
}

function flushNotify() {
  notifyHandlers(currentStore);
}

// DOM

export function set_inner_html(selector, html) {
  const element = document.querySelector(selector);
  if (element) {
    element.innerHTML = html;
  }
}

export function apply_patches(rootSelector, patches) {
  const root = document.querySelector(rootSelector);
  if (!root) return;

  let current = patches;
  while (current.head !== undefined) {
    const patch = current.head;
    const type = patch[0];
    const selector = patch[1];
    const name = patch[2];
    const value = patch[3];

    const element = root.querySelector(selector);
    if (element) {
      switch (type) {
        case "text":
          element.textContent = value;
          break;
        case "attribute":
          element.setAttribute(name, value);
          break;
        case "style":
          element.style.setProperty(name, value);
          break;
        case "remove_attribute":
          element.removeAttribute(name);
          break;
      }
    }

    current = current.tail;
  }
}

// COMPARISON

export function reference_equal(a, b) {
  return a === b;
}

// BATCHED RENDERING

let frameScheduled = false;
let dirty = false;

export function scheduleNotify(flush) {
  dirty = true;
  if (!frameScheduled) {
    frameScheduled = true;
    dirty = false;
    flush();
    requestAnimationFrame(() => {
      frameScheduled = false;
      if (dirty) {
        dirty = false;
        flush();
      }
    });
  }
}

// COMPARE STRATEGIES

const compareStrategies = new Map();

export function set_compare_strategy(selector, compare) {
  compareStrategies.set(selector, compare);
}

// SELECTIVE HANDLER

export function create_selective(selector, select, defaultCompare, handler) {
  let previous = undefined;
  let hasPrevious = false;
  return function (model) {
    const compare = compareStrategies.get(selector) || defaultCompare;
    const next = select(model);
    if (hasPrevious && compare(previous, next)) return;
    previous = next;
    hasPrevious = true;
    handler(next);
  };
}

// WEBSOCKET SYNC

const STORAGE_KEY_PENDING = "lily_pending";
const STORAGE_KEY_SEQUENCE = "lily_last_sequence";

let reconnectBaseMs = 1000;
let reconnectMaxMs = 30000;

let ws = null;
let onMessageCallback = null;
let onReconnectCallback = null;
let reconnectDelay = null;
let reconnectTimer = null;

// CONFIGURATION

export function set_reconnect_base_milliseconds(milliseconds) {
  reconnectBaseMs = milliseconds;
}

export function set_reconnect_max_milliseconds(milliseconds) {
  reconnectMaxMs = milliseconds;
}

// CONNECTION

export function connect(url, onMessage, onReconnect) {
  onMessageCallback = onMessage;
  onReconnectCallback = onReconnect;
  openConnection(url);
}

function openConnection(url) {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  try {
    ws = new WebSocket(url);
  } catch (_error) {
    scheduleReconnect(url);
    return;
  }

  ws.onopen = function () {
    reconnectDelay = reconnectBaseMs;
    // Flush offline messages first, then request resync to process pending messages first.
    flushPending();
    if (onReconnectCallback) onReconnectCallback();
  };

  ws.onmessage = function (event) {
    if (onMessageCallback && typeof event.data === "string") {
      onMessageCallback(event.data);
    }
  };

  ws.onclose = function () {
    ws = null;
    scheduleReconnect(url);
  };

  ws.onerror = function () {
    // onclose will fire after onerror, triggering reconnect
  };
}

function scheduleReconnect(url) {
  if (reconnectTimer) return;

  // Initialise delay if this is the first reconnect attempt
  if (reconnectDelay === null) {
    reconnectDelay = reconnectBaseMs;
  }

  reconnectTimer = setTimeout(function () {
    reconnectTimer = null;
    openConnection(url);
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, reconnectMaxMs);
}

// SENDING

export function send_text(text) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(text);
  } else {
    queuePending(text);
  }
}

// PENDING QUEUE (localStorage-backed)

function queuePending(text) {
  const pending = getPending();
  pending.push(text);
  localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending));
}

function getPending() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY_PENDING);
    if (raw) return JSON.parse(raw);
  } catch (_error) {
    // Corrupted data, reset
  }
  return [];
}

function flushPending() {
  const pending = getPending();
  if (pending.length === 0) return;

  const sent = [];
  for (const text of pending) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(text);
      sent.push(text);
    } else {
      // Connection dropped mid-flush, stop sending
      break;
    }
  }

  // Only remove messages that were successfully sent
  if (sent.length === pending.length) {
    // All messages sent, clear the queue
    localStorage.removeItem(STORAGE_KEY_PENDING);
  } else if (sent.length > 0) {
    // Partial send, remove only the sent messages
    const remaining = pending.slice(sent.length);
    localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(remaining));
  }
  // If sent.length === 0, leave queue unchanged
}

// SEQUENCE TRACKING

export function get_last_sequence() {
  const raw = localStorage.getItem(STORAGE_KEY_SEQUENCE);
  return raw ? parseInt(raw, 10) || 0 : 0;
}

export function set_last_sequence(sequence) {
  localStorage.setItem(STORAGE_KEY_SEQUENCE, String(sequence));
}
