/**
 * TRANSPORT FFI
 *
 * JavaScript FFI for the transport module:
 *
 *   - JSON auto-serialiser: positional encoding with a constructor registry
 *   - HTTP transport: SSE (server to client) + fetch POST (client to server)
 *   - WebSocket transport: binary frames with exponential-backoff reconnect
 *
 * MessagePack auto-serialisation lives in pure Gleam at
 * lily/internal/auto_codec, composed with reflection (which uses
 * lily/internal/reflection.ffi.mjs for value introspection on JS).
 *
 * Both transports persist offline queues to localStorage and flush them on
 * reconnection before sending Resync.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error, NonEmpty, Empty, BitArray } from "../gleam.mjs";
import { Local } from "./store.mjs";
import { registerModule as registerReflectionModule } from "./internal/reflection.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/**
 * Automatically decode JSON to a Gleam value using the constructor registry.
 * Returns Ok(value) on success, Error(undefined) on failure. Used by
 * decode.new_primitive_decoder in transport.gleam's JSON path.
 */
export function autoDecode(json) {
  try {
    return new Ok(autoDecodeInner(json));
  } catch (_e) {
    return new Error(undefined);
  }
}

/**
 * Automatically encode any Gleam value to JSON using positional fields.
 * Caches constructors during encoding so the same client can roundtrip
 * without an explicit registerModule call.
 */
export function autoEncode(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value;
  if (typeof value === "number") return value;

  if (
    value &&
    typeof value === "object" &&
    "head" in value &&
    "tail" in value
  ) {
    const result = [];
    let current = value;
    while (current && current.head !== undefined) {
      result.push(autoEncode(current.head));
      current = current.tail;
    }
    return result;
  }

  if (value && typeof value === "object" && value.constructor) {
    const ctor = value.constructor;
    const name = ctor.name;
    if (!constructorRegistry.has(name)) {
      constructorRegistry.set(name, ctor);
    }
    // Gleam JS classes store fields as named properties (e.g. this.text =
    // text), not numeric indices. Object.keys preserves constructor
    // assignment order.
    const encoded = { _: name };
    Object.keys(value).forEach((field, index) => {
      encoded[String(index)] = autoEncode(value[field]);
    });
    return encoded;
  }
  return value;
}

/**
 * Walk a module namespace and register every class that extends CustomType.
 * Pass the result of `import * as mod from "..."`. Forwards to the reflection
 * registry as well so the MessagePack auto-decoder can also reconstruct
 * these constructors.
 */
export function registerModule(moduleNamespace) {
  for (const key in moduleNamespace) {
    const value = moduleNamespace[key];
    if (typeof value === "function" && isCustomTypeClass(value)) {
      constructorRegistry.set(value.name, value);
    }
  }
  registerReflectionModule(moduleNamespace);
}

// =============================================================================
// HTTP TRANSPORT
// =============================================================================

/**
 * Establish HTTP/SSE transport connection with offline queueing.
 *
 * Server to client: SSE text frames (EventSource).
 * Client to server: binary POST (application/octet-stream).
 * Offline queue: base64-encoded frames persisted to localStorage.
 */
export function httpConnect(postUrl, eventsUrl, flushBatchSize, handler) {
  const queue = createOfflineQueue(STORAGE_KEY_HTTP_PENDING);
  let eventSource = null;
  let isConnected = false;
  let isFlushing = false;

  async function flushPending() {
    if (isFlushing) return;
    queue.loadIfEmpty();
    if (queue.size === 0) return;

    isFlushing = true;
    let totalSent = 0;

    for (let i = 0; i < queue.size; i += flushBatchSize) {
      if (!isConnected) break;
      const batch = queue.slice(i, i + flushBatchSize);
      const results = await Promise.allSettled(
        batch.map(function (frame) {
          return fetch(postUrl, {
            method: "POST",
            headers: { "Content-Type": "application/octet-stream" },
            body: frame,
          });
        }),
      );
      const sent = results.filter(function (result) {
        return result.status === "fulfilled";
      }).length;
      totalSent += sent;
      if (sent < batch.length) break;
    }

    queue.drainSent(totalSent);
    isFlushing = false;
  }

  try {
    eventSource = new EventSource(eventsUrl);
  } catch (error) {
    console.error("Failed to create EventSource:", error);
    return { send() {}, close() {} };
  }

  eventSource.onopen = function () {
    isConnected = true;
    flushPending();
    handler.on_reconnect();
  };

  eventSource.onmessage = function (event) {
    if (typeof event.data === "string") {
      handler.on_receive(new BitArray(new TextEncoder().encode(event.data)));
    }
  };

  eventSource.onerror = function (_error) {
    isConnected = false;
    handler.on_disconnect();
  };

  return {
    send(bytes) {
      const frame = bytes.rawBuffer;
      if (isConnected) {
        fetch(postUrl, {
          method: "POST",
          headers: { "Content-Type": "application/octet-stream" },
          body: frame,
        })
          .then(function () {})
          .catch(function (error) {
            console.error("Failed to POST message:", error);
            queue.queuePending(frame);
          });
      } else {
        queue.queuePending(frame);
      }
    },
    close() {
      isConnected = false;
      if (eventSource) {
        eventSource.close();
        eventSource = null;
      }
    },
  };
}

// =============================================================================
// WEBSOCKET TRANSPORT
// =============================================================================

/**
 * Establish WebSocket connection with exponential-backoff reconnection and
 * offline queueing. Binary frames (ArrayBuffer) are used exclusively. Offline
 * queue is base64-encoded and persisted to localStorage.
 */
export function wsConnect(
  url,
  reconnectBaseMs,
  reconnectMaxMs,
  jitterRatio,
  multiplier,
  handler,
) {
  let ws = null;
  let reconnectDelay = null;
  let reconnectTimer = null;
  const queue = createOfflineQueue(STORAGE_KEY_WS_PENDING);

  function openConnection() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    try {
      ws = new WebSocket(url);
      ws.binaryType = "arraybuffer";
    } catch (_error) {
      scheduleReconnect();
      return;
    }

    ws.onopen = function () {
      reconnectDelay = reconnectBaseMs;
      flushPending();
      handler.on_reconnect();
    };

    ws.onmessage = function (event) {
      if (event.data instanceof ArrayBuffer) {
        handler.on_receive(new BitArray(new Uint8Array(event.data)));
      } else if (typeof event.data === "string") {
        handler.on_receive(new BitArray(new TextEncoder().encode(event.data)));
      }
    };

    ws.onclose = function () {
      ws = null;
      handler.on_disconnect();
      scheduleReconnect();
    };

    ws.onerror = function () {
      // onclose fires after onerror, which triggers reconnect
    };
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    if (reconnectDelay === null) reconnectDelay = reconnectBaseMs;

    // Jitter spreads reconnects after a mass disconnect (thundering herd)
    const jitteredDelay =
      reconnectDelay * (1 - jitterRatio + Math.random() * jitterRatio * 2);
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      openConnection();
    }, jitteredDelay);

    // Advance the progression regardless of jitter so the ceiling is reached
    // in a predictable number of attempts
    reconnectDelay = Math.min(reconnectDelay * multiplier, reconnectMaxMs);
  }

  function flushPending() {
    queue.loadIfEmpty();
    if (queue.size === 0) return;

    let sent = 0;
    for (const frame of queue.all()) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(frame);
        sent++;
      } else {
        break;
      }
    }
    queue.drainSent(sent);
  }

  openConnection();

  return {
    send(bytes) {
      const frame = bytes.rawBuffer;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(frame);
      } else {
        queue.queuePending(frame);
      }
    },
    close() {
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      if (ws) {
        ws.close();
        ws = null;
      }
    },
  };
}

/**
 * Derive a WebSocket URL from the current browser location. Uses `wss:`
 * for HTTPS and `ws:` for HTTP.
 */
export function wsUrlFromCurrentLocation(path) {
  const protocol = globalThis.location.protocol === "https:" ? "wss:" : "ws:";
  return protocol + "//" + globalThis.location.host + path;
}

// =============================================================================
// WRAPPER EXPORTS
// =============================================================================

/** Close a transport handle (HTTP or WebSocket). */
export function transportClose(handle) {
  handle.close();
}

/** Send bytes through a transport handle (HTTP or WebSocket). */
export function transportSend(handle, bytes) {
  handle.send(bytes);
}

// =============================================================================
// FUNCTIONS
// =============================================================================

/**
 * Inner recursive JSON decode. Returns the raw decoded value or throws on
 * an unknown constructor name.
 */
function autoDecodeInner(json) {
  // Local is registered lazily to avoid TDZ errors from the circular import
  // cycle: transport.ffi.mjs to store.mjs to transport.mjs to transport.ffi.mjs
  if (!constructorRegistry.has("Local")) constructorRegistry.set("Local", Local);

  if (json === null) return undefined;
  if (typeof json === "boolean") return json;
  if (typeof json === "string") return json;
  if (typeof json === "number") return json;

  if (Array.isArray(json)) {
    // Build Gleam list right-to-left using NonEmpty/Empty
    let result = new Empty();
    for (let i = json.length - 1; i >= 0; i--) {
      const decodedItem = autoDecodeInner(json[i]);
      result = new NonEmpty(decodedItem, result);
    }
    return result;
  }

  if (json && typeof json === "object" && "_" in json) {
    const tag = json._;
    const ctor = constructorRegistry.get(tag);
    if (!ctor) {
      throw new globalThis.Error(
        `Unknown constructor: ${tag}. Did you forget to call register_types()?`,
      );
    }
    const fields = [];
    let fieldIndex = 0;
    while (String(fieldIndex) in json) {
      fields.push(autoDecodeInner(json[String(fieldIndex)]));
      fieldIndex++;
    }
    return new ctor(...fields);
  }

  return json;
}

/** Decode a base64 string back to a Uint8Array. */
function base64ToFrame(b64) {
  const binary = globalThis.atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * Factory that returns a closure-scoped offline queue backed by
 * localStorage.
 */
function createOfflineQueue(storageKey) {
  let pending = [];
  let persistScheduled = false;

  function persist() {
    try {
      localStorage.setItem(
        storageKey,
        JSON.stringify(pending.map(frameToBase64)),
      );
    } catch (_error) {
      // Quota exceeded; frames remain in-memory and are sent on reconnect
    }
  }

  return {
    all() {
      return [...pending];
    },
    get size() {
      return pending.length;
    },
    slice(start, end) {
      return pending.slice(start, end);
    },
    loadIfEmpty() {
      if (pending.length > 0) return;
      try {
        const raw = localStorage.getItem(storageKey);
        if (raw) pending = JSON.parse(raw).map(base64ToFrame);
      } catch (_error) {
        pending = [];
      }
    },
    queuePending(frame) {
      const wasEmpty = pending.length === 0;
      pending.push(frame);
      if (wasEmpty) {
        persist();
      } else if (!persistScheduled) {
        // Coalesce subsequent writes; avoids O(n^2) localStorage writes
        // during rapid bursts.
        persistScheduled = true;
        queueMicrotask(function () {
          persistScheduled = false;
          persist();
        });
      }
    },
    drainSent(count) {
      if (count === pending.length) {
        localStorage.removeItem(storageKey);
        pending = [];
      } else if (count > 0) {
        pending = pending.slice(count);
        persist();
      }
    },
  };
}

/** Encode a Uint8Array to a base64 string for localStorage persistence. */
function frameToBase64(frame) {
  let binary = "";
  for (let i = 0; i < frame.byteLength; i++) {
    binary += String.fromCharCode(frame[i]);
  }
  return globalThis.btoa(binary);
}

function isCustomTypeClass(fn) {
  let proto = fn.prototype;
  while (proto) {
    if (proto.constructor && proto.constructor.name === "CustomType")
      return true;
    proto = Object.getPrototypeOf(proto);
  }
  return false;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

/** Maps constructor name to constructor function for the JSON auto-decoder. */
const constructorRegistry = new Map();

const STORAGE_KEY_HTTP_PENDING = "lily_http_pending";
const STORAGE_KEY_WS_PENDING = "lily_ws_pending";
