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
  let persistScheduled = false;
  let isFlushing = false;

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

  /** Send all pending messages via POST when connection is available */
  async function flushPending() {
    // Guard against a second concurrent flush if onopen fires again mid-flush
    if (isFlushing) return;
    // Use in-memory queue; load from storage only on first flush after page load
    if (pending.length === 0) {
      pending = getPending();
    }
    if (pending.length === 0) return;

    isFlushing = true;
    const batchSize = 10;
    let totalSent = 0;

    for (let i = 0; i < pending.length; i += batchSize) {
      if (!isConnected) break;
      const batch = pending.slice(i, i + batchSize);
      const results = await Promise.allSettled(
        batch.map(function (text) {
          return fetch(postUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: text,
          });
        }),
      );
      const sent = results.filter(function (result) {
        return result.status === "fulfilled";
      }).length;
      totalSent += sent;
      if (sent < batch.length) break;
    }

    if (totalSent === pending.length) {
      localStorage.removeItem(STORAGE_KEY_PENDING);
      pending = [];
    } else if (totalSent > 0) {
      pending = pending.slice(totalSent);
      localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending));
    }

    isFlushing = false;
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
        fetch(postUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: text,
        })
          .then(function () {})
          .catch(function (error) {
            console.error("Failed to POST message:", error);
            queuePending(text);
          });
      } else {
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
