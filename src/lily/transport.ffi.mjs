/**
 * TRANSPORT FFI
 *
 * WS/HTTP transport and the register_types entry point. Auto-serialisation for
 * both JSON and MessagePack lives in lily/internal/auto_codec.gleam over the
 * reflection FFIs, this file no longer carries a codec of its own.
 *
 * Both transports persist offline queues to sessionStorage and flush them on
 * reconnection before sending Resync. sessionStorage (not localStorage) so the
 * queue is scoped per tab: localStorage is shared across every tab on the
 * origin, so two tabs would clobber each other's unsent frames on the one key
 * (overwrite on persist, and removeItem on drain wiping the other tab's frames).
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { BitArray } from "../gleam.mjs";
import { registerModule as registerReflectionModule } from "./internal/reflection.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/**
 * Register the CustomType classes in a module namespace so the auto-decoder
 * can reconstruct them. Pass the result of `import * as mod from "..."`. Kept
 * here as the stable entry point for user register_types shims, it forwards to
 * the reflection registry that both the JSON and MessagePack paths decode
 * through.
 */
export function registerModule(moduleNamespace) {
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
 * Offline queue: base64-encoded frames persisted to sessionStorage.
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
 * queue is base64-encoded and persisted to sessionStorage.
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

    // Jitter spreads reconnects after a mass disconnect
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
 * sessionStorage, per-tab, so tabs don't share (and corrupt) one key. The
 * in-memory `pending` array is the source of truth for the live tab, storage
 * only backs it so a reload of the same tab doesn't drop unsent frames.
 */
function createOfflineQueue(storageKey) {
  let pending = [];
  let persistScheduled = false;

  function persist() {
    try {
      sessionStorage.setItem(
        storageKey,
        JSON.stringify(pending.map(frameToBase64)),
      );
    } catch (_error) {
      // Quota exceeded, frames remain in-memory and are sent on reconnect
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
        const raw = sessionStorage.getItem(storageKey);
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
        // Coalesce subsequent writes to avoid O(n^2) sessionStorage writes
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
        sessionStorage.removeItem(storageKey);
        pending = [];
      } else if (count > 0) {
        pending = pending.slice(count);
        persist();
      }
    },
  };
}

/** Encode a Uint8Array to a base64 string for sessionStorage persistence. */
function frameToBase64(frame) {
  let binary = "";
  for (let i = 0; i < frame.byteLength; i++) {
    binary += String.fromCharCode(frame[i]);
  }
  return globalThis.btoa(binary);
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const STORAGE_KEY_HTTP_PENDING = "lily_http_pending";
const STORAGE_KEY_WS_PENDING = "lily_ws_pending";
