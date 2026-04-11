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

    // WebSocket lifecycle handlers
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

    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      openConnection();
    }, reconnectDelay);

    // Double delay for next attempt, capped at maximum
    reconnectDelay = Math.min(reconnectDelay * 2, reconnectMaxMs);
  }

  // -------------------------------------------------------------------------
  // Offline queue helpers
  // -------------------------------------------------------------------------

  /** Send all pending messages when connection is available */
  function flushPending() {
    pending = getPending();
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

    // Remove sent messages from queue
    if (sent.length === pending.length) {
      // All messages sent successfully
      localStorage.removeItem(STORAGE_KEY_PENDING);
      pending = [];
    } else if (sent.length > 0) {
      // Some messages sent, keep the rest queued
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
    pending.push(text);
    localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending));
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
