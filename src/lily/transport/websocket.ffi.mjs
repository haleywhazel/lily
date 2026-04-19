/**
 * WEBSOCKET TRANSPORT
 *
 * Bidirectional WebSocket communication with automatic reconnection using
 * exponential backoff and offline queueing with localStorage persistence.
 *
 * Connection status is tracked via WebSocket.onopen and WebSocket.onclose
 * events. The reconnect strategy doubles the delay after each failed attempt
 * up to a configured maximum.
 *
 * Binary frames (ArrayBuffer) are used exclusively. The offline queue
 * base64-encodes frames for localStorage persistence.
 */

import { BitArray } from "../../gleam.mjs";

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const STORAGE_KEY_PENDING = "lily_ws_pending";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Establish WebSocket connection with reconnection and offline queueing */
export function connect(url, reconnectBaseMs, reconnectMaxMs, handler) {
  // Closure-scoped state (not module-level, allows multiple instances)
  let ws = null;
  let reconnectDelay = null;
  let reconnectTimer = null;
  let pending = [];
  let persistScheduled = false;

  // -------------------------------------------------------------------------
  // Connection management
  // -------------------------------------------------------------------------

  /** Open WebSocket connection and set up lifecycle handlers */
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

  /** Schedule reconnection attempt with exponential backoff */
  function scheduleReconnect() {
    if (reconnectTimer) return;

    if (reconnectDelay === null) {
      reconnectDelay = reconnectBaseMs;
    }

    // ±25% jitter spreads reconnects after a mass disconnect (thundering herd)
    const jitteredDelay = reconnectDelay * (0.75 + Math.random() * 0.5);
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      openConnection();
    }, jitteredDelay);

    // Advance the progression regardless of jitter so the ceiling is reached
    // in a predictable number of attempts
    reconnectDelay = Math.min(reconnectDelay * 2, reconnectMaxMs);
  }

  // -------------------------------------------------------------------------
  // Offline queue helpers
  // -------------------------------------------------------------------------

  /** Send all pending messages when connection is available */
  function flushPending() {
    // Use in-memory queue; load from storage only on first flush after page load
    if (pending.length === 0) {
      pending = getPending();
    }
    if (pending.length === 0) return;

    const sent = [];
    for (const frame of pending) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(frame);
        sent.push(frame);
      } else {
        break;
      }
    }

    if (sent.length === pending.length) {
      // Everything went out — wipe the queue
      localStorage.removeItem(STORAGE_KEY_PENDING);
      pending = [];
    } else if (sent.length > 0) {
      // Partial flush — keep whatever didn't make it
      const remaining = pending.slice(sent.length);
      localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(remaining.map(frameToBase64)));
      pending = remaining;
    }
  }

  /** Retrieve pending frames from localStorage (base64 → Uint8Array) */
  function getPending() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY_PENDING);
      if (raw) return JSON.parse(raw).map(base64ToFrame);
    } catch (_error) {
      // Corrupted data, reset to empty queue
    }
    return [];
  }

  /** Add frame to pending queue and persist to localStorage */
  function queuePending(frame) {
    const wasEmpty = pending.length === 0;
    pending.push(frame);
    if (wasEmpty) {
      // Write immediately for the first queued frame
      try {
        localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending.map(frameToBase64)));
      } catch (_error) {
        // Quota exceeded — frame remains in-memory, sent on reconnect
      }
    } else if (!persistScheduled) {
      // Subsequent frames are coalesced — avoids O(n²) writes in rapid batches.
      persistScheduled = true;
      queueMicrotask(function () {
        persistScheduled = false;
        try {
          localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending.map(frameToBase64)));
        } catch (_error) {
          // Quota exceeded — frames remain in-memory, sent on reconnect
        }
      });
    }
  }

  // -------------------------------------------------------------------------
  // Initialise connection
  // -------------------------------------------------------------------------

  openConnection();

  // -------------------------------------------------------------------------
  // Return transport handle
  // -------------------------------------------------------------------------

  return {
    /** Send bytes via WebSocket (queues if offline) */
    send(bytes) {
      const frame = bytes.rawBuffer;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(frame);
      } else {
        queuePending(frame);
      }
    },

    /** Close WebSocket connection and cancel reconnection attempts */
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

// =============================================================================
// WRAPPER EXPORTS
// =============================================================================

/** Close transport connection */
export function close(handle) {
  handle.close();
}

/** Send bytes via transport handle */
export function send(handle, bytes) {
  handle.send(bytes);
}

/** Derive WebSocket URL from current browser location */
export function urlFromCurrentLocation(path) {
  const protocol = globalThis.location.protocol === "https:" ? "wss:" : "ws:";
  return protocol + "//" + globalThis.location.host + path;
}

// =============================================================================
// PRIVATE HELPERS
// =============================================================================

/** Decode a base64 string back to a Uint8Array */
function base64ToFrame(b64) {
  const binary = globalThis.atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** Encode a Uint8Array to a base64 string for localStorage persistence */
function frameToBase64(frame) {
  let binary = "";
  for (let i = 0; i < frame.byteLength; i++) {
    binary += String.fromCharCode(frame[i]);
  }
  return globalThis.btoa(binary);
}
