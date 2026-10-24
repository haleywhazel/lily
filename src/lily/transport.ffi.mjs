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
import { log } from "./internal/actor.ffi.mjs";

// re-exported for user FFIs, the registry lives in codec
export { registerModule } from "./internal/codec.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/**
 * `makeConnectorHandler` and `makeChannel` are passed-in Gleam constructors.
 * The first frame sent after an open goes ahead of the queue, which flushes
 * right behind it. The runtime sends its `Resync` there, and never queues it,
 * the next open sends a fresh one. Frames queued under another queue
 * version, stored as `protocol`, are dropped, they'd be read as something
 * else.
 */
export function offlineConnect(
  connect,
  storageKey,
  protocol,
  handler,
  makeConnectorHandler,
  makeChannel,
) {
  const queue = createOfflineQueue(storageKey, protocol);
  let channel = null;
  let leading = false;
  // between an open and its close, when a queued frame may go out early
  let open = false;

  function flush() {
    if (!channel || queue.size === 0) return;
    let sent = 0;
    for (const frame of queue.all()) {
      if (sendSafely(channel, new BitArray(frame)) instanceof GleamError) break;
      sent++;
    }
    queue.drainSent(sent);
  }

  function sendOrQueue(bytes) {
    const result = sendSafely(channel, bytes);
    if (result instanceof GleamError) queue.queuePending(bytes.rawBuffer);
    return result;
  }

  channel = connect(
    makeConnectorHandler(
      handler.received,
      () => {
        leading = true;
        open = true;
        handler.opened();
        // nothing was sent while opening, flush anyway
        if (leading && channel) {
          leading = false;
          flush();
        }
      },
      () => {
        leading = false;
        open = false;
        handler.closed();
      },
    ),
  );

  return makeChannel(
    (bytes) => {
      if (leading) {
        leading = false;
        const result = channel ? sendSafely(channel, bytes) : new GleamError();
        flush();
        return result;
      }
      // a send that failed once while open shouldn't stall the rest, the
      // queue gets another go first, and a frame behind it keeps the order
      if (open && queue.size > 0) flush();
      if (queue.size > 0) {
        queue.queuePending(bytes.rawBuffer);
        return new GleamError(undefined);
      }
      return channel ? sendOrQueue(bytes) : queueOnly(queue, bytes);
    },
    () => channel.close(),
  );
}

export function offlinePending(storageKey, protocol) {
  return toList(
    readQueue(storageKey, protocol).map((frame) => new BitArray(frame)),
  );
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
  // a hot loop or a timer past what setTimeout holds would both misbehave
  reconnectBase = Math.max(reconnectBase, 50);
  reconnectMax = Math.min(Math.max(reconnectMax, reconnectBase), 2 ** 31 - 1);
  jitterRatio = Math.min(Math.max(jitterRatio, 0), 1);
  multiplier = Math.max(multiplier, 1);
  const address = resolveSocketUrl(url);
  if (address === null) {
    log(
      "error",
      `lily: ${JSON.stringify(url)} isn't a WebSocket URL, not connecting`,
    );
    return makeChannel(
      () => new GleamError(undefined),
      () => undefined,
    );
  }
  let socket = null;
  let reconnectDelay = reconnectBase;
  let reconnectTimer = null;
  let stopped = false;

  function openConnection() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    try {
      socket = new WebSocket(address);
      socket.binaryType = "arraybuffer";
    } catch (_error) {
      scheduleReconnect();
      return;
    }

    socket.onopen = function () {
      handler.opened();
    };

    // a server that closes every socket straight away still backs off, the
    // delay only resets once one has heard from it
    socket.onmessage = function (event) {
      reconnectDelay = reconnectBase;
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
      if (!stopped) scheduleReconnect();
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
    // for good, the close event doesn't reconnect
    () => {
      stopped = true;
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

// seeded from storage, letting early frames join an earlier page's queue
function createOfflineQueue(storageKey, protocol) {
  let pending = readQueue(storageKey, protocol);
  let persistScheduled = false;

  function persist() {
    try {
      sessionStorage.setItem(
        storageKey,
        JSON.stringify({ protocol, frames: pending.map(frameToBase64) }),
      );
    } catch (_error) {
      // quota exceeded, frames stay in memory and a stale copy mustn't be
      // sent again after a reload
      try {
        sessionStorage.removeItem(storageKey);
      } catch (_ignored) {
        // storage unavailable
      }
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

// held while there's no channel yet, sent once it opens
function queueOnly(queue, bytes) {
  queue.queuePending(bytes.rawBuffer);
  return new GleamError(undefined);
}

// a bare array is a version 1 queue
function readQueue(storageKey, protocol) {
  try {
    const raw = sessionStorage.getItem(storageKey);
    if (!raw) return [];
    const stored = JSON.parse(raw);
    const frames = Array.isArray(stored)
      ? protocol === 1
        ? stored
        : []
      : stored?.protocol === protocol && Array.isArray(stored.frames)
        ? stored.frames
        : [];
    if (frames.length === 0) sessionStorage.removeItem(storageKey);
    return frames.map(base64ToFrame);
  } catch (_error) {
    return [];
  }
}

// ws or wss for the page's scheme, `null` for a URL that can't be either
function resolveSocketUrl(url) {
  const trimmed = url.trim();
  if (!globalThis.location) return /^wss?:/i.test(trimmed) ? trimmed : null;
  try {
    const resolved = new URL(trimmed, globalThis.location.href);
    const scheme = SOCKET_SCHEMES[resolved.protocol];
    if (!scheme) return null;
    resolved.protocol = scheme;
    return resolved.href;
  } catch (_error) {
    return null;
  }
}

// a custom channel's send can throw, that's a frame that didn't go out
function sendSafely(channel, bytes) {
  try {
    return channel.send(bytes);
  } catch (_error) {
    return new GleamError(undefined);
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// bytes per fromCharCode call
const BASE64_CHUNK = 0x8000;

const SOCKET_SCHEMES = {
  "http:": "ws:",
  "https:": "wss:",
  "ws:": "ws:",
  "wss:": "wss:",
};

const TEXT_ENCODER = new TextEncoder();
