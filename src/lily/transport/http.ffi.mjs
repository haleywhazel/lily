/**
 * HTTP TRANSPORT
 *
 * Bidirectional communication using Server-Sent Events (SSE) for server→client
 * messages and fetch POST for client→server messages. Provides offline queueing
 * with localStorage persistence and automatic reconnection (via SSE's built-in
 * reconnect).
 *
 * Connection status is tracked via the SSE connection state (EventSource.onopen
 * and EventSource.onerror). Failed POST requests do NOT trigger disconnection;
 * they are queued and retried when the SSE connection reopens.
 */

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const STORAGE_KEY_PENDING = "lily_http_pending";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Establish HTTP/SSE transport connection with offline queueing */
export function connect(postUrl, eventsUrl, handler) {
  // Closure-scoped state (not module-level, allows multiple instances)
  let eventSource = null;
  let pending = [];
  let isConnected = false;

  // -------------------------------------------------------------------------
  // Offline queue helpers
  // -------------------------------------------------------------------------

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
    try {
      localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending));
    } catch (error) {
      console.error("Failed to persist pending queue:", error);
      // Message remains in-memory pending array, will be sent on next flush
    }
  }

  /** Send all pending messages via POST when connection is available */
  function flushPending() {
    pending = getPending();
    if (pending.length === 0) return;

    const promises = [];
    for (const text of pending) {
      if (!isConnected) break;

      promises.push(
        fetch(postUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: text,
        }),
      );
    }

    // Remove successfully sent messages from queue
    Promise.allSettled(promises).then(function (results) {
      const successCount = results.filter(function (r) {
        return r.status === "fulfilled";
      }).length;

      if (successCount === pending.length) {
        // All messages sent successfully
        localStorage.removeItem(STORAGE_KEY_PENDING);
        pending = [];
      } else if (successCount > 0) {
        // Some messages sent, keep the rest queued
        const remaining = pending.slice(successCount);
        localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(remaining));
        pending = remaining;
      }
    });
  }

  // -------------------------------------------------------------------------
  // EventSource setup (server→client channel)
  // -------------------------------------------------------------------------

  try {
    eventSource = new EventSource(eventsUrl);
  } catch (error) {
    console.error("Failed to create EventSource:", error);
    // Return no-op handle if EventSource creation fails
    return {
      send() {},
      close() {},
    };
  }

  // -------------------------------------------------------------------------
  // EventSource lifecycle handlers
  // -------------------------------------------------------------------------

  eventSource.onopen = function () {
    isConnected = true;
    flushPending();
    handler.on_reconnect();
  };

  eventSource.onmessage = function (event) {
    if (typeof event.data === "string") {
      handler.on_receive(event.data);
    }
  };

  eventSource.onerror = function (_error) {
    isConnected = false;
    handler.on_disconnect();
    // Browser automatically attempts to reconnect (SSE built-in behaviour)
  };

  // -------------------------------------------------------------------------
  // Return transport handle
  // -------------------------------------------------------------------------

  return {
    /** Send message to server via POST (queues if offline) */
    send(text) {
      if (isConnected) {
        // Connected: attempt immediate send, queue on failure
        fetch(postUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: text,
        })
          .then(function () {
            // Success - nothing to do
          })
          .catch(function (error) {
            console.error("Failed to POST message:", error);
            queuePending(text);
          });
      } else {
        // Disconnected: queue immediately
        queuePending(text);
      }
    },

    /** Close EventSource connection and mark as disconnected */
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
