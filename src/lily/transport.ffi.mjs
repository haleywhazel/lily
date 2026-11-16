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
import { None, Some } from "../../gleam_stdlib/gleam/option.mjs";
import { log } from "./internal/actor.ffi.mjs";

// re-exported for user FFIs, the registry lives in codec
export { registerModule } from "./internal/codec.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Empties every queue on the page and keeps them out of storage from here. */
export function discardOfflineQueues() {
  for (const queue of liveQueues) queue.discard();
}

/**
 * `queue` is from `offlineQueue`, and `makeConnectorHandler` and `makeChannel`
 * are passed-in Gleam constructors. The first frame sent after an open goes
 * ahead of the queue, which flushes right behind it. The runtime sends its
 * `Resync` there once the server has greeted it, and never queues it, the
 * next open sends a fresh one.
 */
export function offlineConnect(
  connect,
  queue,
  handler,
  makeConnectorHandler,
  makeChannel,
) {
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

/** The `delivered` an earlier page stored with its requeued frames, else 0. */
export function offlineDelivered(storageKey, protocol) {
  return readStored(storageKey, protocol).delivered;
}

export function offlineKeepOwner(queue, owner) {
  queue.keepOwner(owner);
}

/** The owner this tab last kept, `None` before its first `Connected`. */
export function offlineOwner(queue) {
  const owner = queue.owner;
  return owner === null ? new None() : new Some(owner);
}

export function offlinePending(storageKey, protocol) {
  return toList(
    readQueue(storageKey, protocol).map((frame) => new BitArray(frame)),
  );
}

/**
 * Seeded from `sessionStorage`. Frames queued under another queue version,
 * stored as `protocol`, are dropped, they'd be read as something else.
 */
export function offlineQueue(storageKey, protocol) {
  const queue = createOfflineQueue(storageKey, protocol);
  liveQueues.add(queue);
  return queue;
}

/**
 * Replaces everything held with `frames`, a Gleam list, in order, noting the
 * highest message id already put on the wire among them.
 */
export function offlineRequeue(queue, frames, delivered) {
  queue.replace(
    frames.toArray().map((frame) => frame.rawBuffer),
    delivered,
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
  let { frames: pending, delivered } = readStored(storageKey, protocol);
  let owner = readOwner(storageKey);
  let persistScheduled = false;
  // after `discard`, a close on the way out mustn't write the queue back
  let discarded = false;

  function persist() {
    if (discarded) return;
    try {
      sessionStorage.setItem(
        storageKey,
        JSON.stringify({
          protocol,
          frames: pending.map(frameToBase64),
          delivered,
        }),
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
    get owner() {
      return owner;
    },
    get size() {
      return pending.length;
    },
    discard() {
      pending = [];
      delivered = 0;
      owner = null;
      discarded = true;
      try {
        sessionStorage.removeItem(storageKey);
        sessionStorage.removeItem(storageKey + OWNER_SUFFIX);
      } catch (_error) {
        // storage unavailable, nothing was kept
      }
    },
    // kept apart from the frames, an empty queue still has an owner
    keepOwner(next) {
      if (next === owner) return;
      owner = next;
      if (discarded) return;
      try {
        sessionStorage.setItem(storageKey + OWNER_SUFFIX, next);
      } catch (_error) {
        // storage unavailable, the owner stays in memory
      }
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
    replace(frames, sent) {
      pending = frames;
      delivered = sent;
      if (pending.length === 0) {
        try {
          sessionStorage.removeItem(storageKey);
        } catch (_error) {
          // storage unavailable, memory queue already empty
        }
      } else {
        persist();
      }
    },
    drainSent(count) {
      if (count === pending.length) {
        pending = [];
        delivered = 0;
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

function readOwner(storageKey) {
  try {
    return sessionStorage.getItem(storageKey + OWNER_SUFFIX);
  } catch (_error) {
    return null;
  }
}

function readQueue(storageKey, protocol) {
  return readStored(storageKey, protocol).frames;
}

// a bare array is a version 1 queue
function readStored(storageKey, protocol) {
  try {
    const raw = sessionStorage.getItem(storageKey);
    if (!raw) return { frames: [], delivered: 0 };
    const stored = JSON.parse(raw);
    const current = !Array.isArray(stored) && stored?.protocol === protocol;
    const frames = Array.isArray(stored)
      ? protocol === 1
        ? stored
        : []
      : current && Array.isArray(stored.frames)
        ? stored.frames
        : [];
    if (frames.length === 0) sessionStorage.removeItem(storageKey);
    const delivered =
      current && Number.isSafeInteger(stored.delivered) ? stored.delivered : 0;
    return { frames: frames.map(base64ToFrame), delivered };
  } catch (_error) {
    return { frames: [], delivered: 0 };
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

// every queue made on this page, for `discardOfflineQueues`
const liveQueues = new Set();

const OWNER_SUFFIX = "_owner";

const SOCKET_SCHEMES = {
  "http:": "ws:",
  "https:": "wss:",
  "ws:": "ws:",
  "wss:": "wss:",
};

const TEXT_ENCODER = new TextEncoder();
