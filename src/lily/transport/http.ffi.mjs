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
 *
 * Client→server: binary POST with Content-Type application/octet-stream.
 * Server→client: SSE text frames encoded as UTF-8 bytes (JSON mode) or
 * base64-encoded MessagePack (binary mode, server must base64-encode).
 * Offline queue persists frames as base64 in localStorage.
 */

import { BitArray } from "../../gleam.mjs";

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const STORAGE_KEY_PENDING = "lily_http_pending";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Establish HTTP/SSE transport connection with offline queueing */
export function connect(postUrl, eventsUrl, flushBatchSize, handler) {
  // Closure-scoped state (not module-level, allows multiple instances)
  let eventSource = null;
  let pending = [];
  let isConnected = false;
  let persistScheduled = false;
  let isFlushing = false;

  // -------------------------------------------------------------------------
  // Offline queue helpers
  // -------------------------------------------------------------------------

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

  /** Send all pending frames via POST when connection is available */
  async function flushPending() {
    // Guard against a second concurrent flush if onopen fires again mid-flush
    if (isFlushing) return;
    // Use in-memory queue; load from storage only on first flush after page load
    if (pending.length === 0) {
      pending = getPending();
    }
    if (pending.length === 0) return;

    isFlushing = true;
    let totalSent = 0;

    for (let i = 0; i < pending.length; i += flushBatchSize) {
      if (!isConnected) break;
      const batch = pending.slice(i, i + flushBatchSize);
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

    if (totalSent === pending.length) {
      localStorage.removeItem(STORAGE_KEY_PENDING);
      pending = [];
    } else if (totalSent > 0) {
      pending = pending.slice(totalSent);
      localStorage.setItem(STORAGE_KEY_PENDING, JSON.stringify(pending.map(frameToBase64)));
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
      // SSE is text-only; convert to bytes so the handler always gets BitArray
      handler.on_receive(new BitArray(new TextEncoder().encode(event.data)));
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
    /** Send bytes to server via POST (queues if offline) */
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
            queuePending(frame);
          });
      } else {
        queuePending(frame);
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

/** Close transport connection */
export function close(handle) {
  handle.close();
}

/** Send bytes via transport handle */
export function send(handle, bytes) {
  handle.send(bytes);
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
