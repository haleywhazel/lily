/**
 * WEBSOCKET TRANSPORT
 *
 * Bidirectional WebSocket communication with automatic reconnection using
 * exponential backoff and offline queueing with localStorage persistence.
 *
 * Connection status is tracked via WebSocket.onopen and WebSocket.onclose
 * events. The reconnect strategy doubles the delay after each failed attempt
 * up to a configured maximum.
 */

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
      if (typeof event.data === "string") {
        handler.on_receive(event.data);
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
    for (const text of pending) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(text);
        sent.push(text);
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
      localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(remaining));
      pending = remaining;
    }
  }

  /** Retrieve pending messages from localStorage */
  function getPending() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY_PENDING);
      if (raw) return JSON.parse(raw);
    } catch (_error) {
      // Corrupted data, reset to empty queue
    }
    return [];
  }

  /** Add message to pending queue and persist to localStorage */
  function queuePending(text) {
    const wasEmpty = pending.length === 0;
    pending.push(text);
    if (wasEmpty) {
      // Write immediately for the first queued message so the data is visible
      // to synchronous readers (e.g. tests) without waiting for a microtask.
      try {
        localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending));
      } catch (_error) {
        // Quota exceeded — message remains in-memory, sent on reconnect
      }
    } else if (!persistScheduled) {
      // Subsequent messages are coalesced — avoids O(n²) writes in rapid batches.
      persistScheduled = true;
      queueMicrotask(function () {
        persistScheduled = false;
        try {
          localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending));
        } catch (_error) {
          // Quota exceeded — messages remain in-memory, sent on reconnect
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
    /** Send message via WebSocket (queues if offline) */
    send(text) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(text);
      } else {
        queuePending(text);
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

/** Send text via transport handle */
export function send(handle, text) {
  handle.send(text);
}

/** Close transport connection */
export function close(handle) {
  handle.close();
}

/** Derive WebSocket URL from current browser location */
export function urlFromCurrentLocation(path) {
  const protocol = globalThis.location.protocol === "https:" ? "wss:" : "ws:";
  return protocol + "//" + globalThis.location.host + path;
}
