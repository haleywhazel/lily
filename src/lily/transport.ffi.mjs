/**
 * TRANSPORT
 *
 * Browser side of the built-in transports, WebSocket with backoff plus a
 * sessionStorage offline queue.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { BitArray, Error as GleamError, Ok, toList } from "../gleam.mjs";

// re-exported for user FFIs, the registry lives in codec
export { registerModule } from "./internal/codec.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** `makeHandler` and `makeChannel` are passed-in Gleam constructors. */
export function offlineConnect(
  connect,
  storageKey,
  handler,
  makeHandler,
  makeChannel,
) {
  const queue = createOfflineQueue(storageKey);
  let channel = null;

  function flush() {
    if (!channel || queue.size === 0) return;
    let sent = 0;
    for (const frame of queue.all()) {
      if (channel.send(new BitArray(frame)) instanceof GleamError) break;
      sent++;
    }
    queue.drainSent(sent);
  }

  channel = connect(
    makeHandler(
      handler.received,
      () => {
        flush();
        handler.opened();
      },
      handler.closed,
    ),
  );

  return makeChannel(
    (bytes) => {
      const result = channel.send(bytes);
      if (result instanceof GleamError) queue.queuePending(bytes.rawBuffer);
      return result;
    },
    () => channel.close(),
  );
}

export function offlinePending(storageKey) {
  return toList(readQueue(storageKey).map((frame) => new BitArray(frame)));
}

export function pageHostname() {
  return globalThis.location?.hostname ?? "";
}

export function websocketConnect(
  url,
  reconnectBase,
  reconnectMax,
  jitterRatio,
  multiplier,
  handler,
  makeChannel,
) {
  let socket = null;
  let reconnectDelay = reconnectBase;
  let reconnectTimer = null;

  function openConnection() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    try {
      socket = new WebSocket(resolveSocketUrl(url));
      socket.binaryType = "arraybuffer";
    } catch (_error) {
      scheduleReconnect();
      return;
    }

    socket.onopen = function () {
      reconnectDelay = reconnectBase;
      handler.opened();
    };

    socket.onmessage = function (event) {
      if (event.data instanceof ArrayBuffer) {
        handler.received(new BitArray(new Uint8Array(event.data)));
      } else if (typeof event.data === "string") {
        handler.received(new BitArray(TEXT_ENCODER.encode(event.data)));
      }
    };

    // an error is always followed by a close
    socket.onclose = function () {
      socket = null;
      handler.closed();
      scheduleReconnect();
    };
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;

    // jitter spreads reconnects after a mass disconnect
    const jitteredDelay =
      reconnectDelay * (1 - jitterRatio + Math.random() * jitterRatio * 2);
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      openConnection();
    }, jitteredDelay);

    // backoff advances regardless of jitter
    reconnectDelay = Math.min(reconnectDelay * multiplier, reconnectMax);
  }

  openConnection();

  return makeChannel(
    (bytes) => {
      if (!socket || socket.readyState !== WebSocket.OPEN) {
        return new GleamError(undefined);
      }
      socket.send(bytes.rawBuffer);
      return new Ok(undefined);
    },
    () => {
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      if (socket) {
        socket.close();
        socket = null;
      }
    },
  );
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function base64ToFrame(text) {
  const binary = globalThis.atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

/** Seeded from storage, letting early frames join an earlier page's queue. */
function createOfflineQueue(storageKey) {
  let pending = readQueue(storageKey);
  let persistScheduled = false;

  function persist() {
    try {
      sessionStorage.setItem(
        storageKey,
        JSON.stringify(pending.map(frameToBase64)),
      );
    } catch (_error) {
      // quota exceeded, frames stay in memory
    }
  }

  return {
    all() {
      return [...pending];
    },
    get size() {
      return pending.length;
    },
    queuePending(frame) {
      const wasEmpty = pending.length === 0;
      pending.push(frame);
      if (wasEmpty) {
        persist();
      } else if (!persistScheduled) {
        // batched, avoids quadratic storage writes in bursts
        persistScheduled = true;
        queueMicrotask(function () {
          persistScheduled = false;
          persist();
        });
      }
    },
    drainSent(count) {
      if (count === pending.length) {
        pending = [];
        try {
          sessionStorage.removeItem(storageKey);
        } catch (_error) {
          // storage unavailable, memory queue already empty
        }
      } else if (count > 0) {
        pending = pending.slice(count);
        persist();
      }
    },
  };
}

function frameToBase64(frame) {
  // chunked, fromCharCode.apply has an argument limit
  const parts = [];
  for (let index = 0; index < frame.byteLength; index += BASE64_CHUNK) {
    parts.push(
      String.fromCharCode.apply(
        null,
        frame.subarray(index, index + BASE64_CHUNK),
      ),
    );
  }
  return globalThis.btoa(parts.join(""));
}

function readQueue(storageKey) {
  try {
    const raw = sessionStorage.getItem(storageKey);
    return raw ? JSON.parse(raw).map(base64ToFrame) : [];
  } catch (_error) {
    return [];
  }
}

function resolveSocketUrl(url) {
  if (/^wss?:/i.test(url) || !globalThis.location) return url;
  const resolved = new URL(url, globalThis.location.href);
  resolved.protocol = resolved.protocol === "https:" ? "wss:" : "ws:";
  return resolved.href;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// bytes per fromCharCode call
const BASE64_CHUNK = 0x8000;

const TEXT_ENCODER = new TextEncoder();
