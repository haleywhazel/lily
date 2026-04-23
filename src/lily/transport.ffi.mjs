/**
 * TRANSPORT FFI
 *
 * All JavaScript FFI for the transport module in one place:
 *
 *   - Auto-serialiser: positional JSON encoding with a constructor registry
 *   - MessagePack codec: inline binary codec (no external dependencies)
 *   - HTTP transport: SSE (server→client) + fetch POST (client→server)
 *   - WebSocket transport: binary frames with exponential-backoff reconnect
 *
 * Both transports persist offline queues to localStorage (base64-encoded frames)
 * and flush them on reconnection before sending Resync.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error, NonEmpty, Empty, BitArray } from "../gleam.mjs";
// Imported for MessagePack protocol decoding — these classes are used to
// construct proper Gleam Protocol instances (required for pattern matching).
// Circular imports are safe in ES modules when bindings are only used inside
// function bodies (not at module initialisation time).
import {
  Acknowledge,
  ClientMessage,
  Resync,
  ServerMessage,
  Snapshot,
} from "./transport.mjs";

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

/** Maps constructor name → constructor function, built during encode and model walk. */
const constructorRegistry = new Map();

const STORAGE_KEY_HTTP_PENDING = "lily_http_pending";
const STORAGE_KEY_WS_PENDING = "lily_ws_pending";

const messagePackTextDecoder = new TextDecoder();
const messagePackTextEncoder = new TextEncoder();

// =============================================================================
// AUTO-SERIALISER
// =============================================================================

/**
 * Automatically decode JSON to a Gleam value using the constructor registry.
 * Returns Ok(value) on success, Error(undefined) on failure.
 * This is the exported function used by decode.new_primitive_decoder.
 */
export function autoDecode(json) {
  try {
    return new Ok(autoDecodeInner(json));
  } catch (_e) {
    return new Error(undefined);
  }
}

/**
 * Decode a BitArray of MessagePack bytes to a Gleam value.
 * Returns Ok(value) or Error(undefined).
 */
export function autoDecodeMessagePack(bitArray) {
  try {
    const view = new DataView(bitArray.rawBuffer.buffer, bitArray.rawBuffer.byteOffset, bitArray.rawBuffer.byteLength);
    const [jsValue] = messagePackDecodeAt(view, 0);
    return new Ok(autoDecodeInner(jsValue));
  } catch (_e) {
    return new Error(undefined);
  }
}

/**
 * Automatically encode any Gleam value to JSON using positional fields.
 * Caches constructors during encoding to build the registry.
 */
export function autoEncode(value) {
  // Primitives
  if (value === null || value === undefined) return null;
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value;
  if (typeof value === "number") return value;

  // List (Gleam lists are built as nested objects with `head` and `tail`)
  if (value && typeof value === "object" && "head" in value && "tail" in value) {
    const result = [];
    let current = value;
    while (current && current.head !== undefined) {
      result.push(autoEncode(current.head));
      current = current.tail;
    }
    return result;
  }

  // Custom type (has a constructor property)
  if (value && typeof value === "object" && value.constructor) {
    const ctor = value.constructor;
    const name = ctor.name;

    // Cache constructor for decoding
    if (!constructorRegistry.has(name)) {
      constructorRegistry.set(name, ctor);
    }

    // Build JSON object with tag and positional fields.
    // Gleam JS classes store fields as named properties (e.g. this.text = text),
    // not numeric indices. Object.keys preserves constructor assignment order.
    const encoded = { _: name };
    Object.keys(value).forEach((field, index) => {
      encoded[String(index)] = autoEncode(value[field]);
    });

    return encoded;
  }

  // Fallback for plain objects (shouldn't happen in normal Gleam code)
  return value;
}

/**
 * Encode any Gleam value to a BitArray using MessagePack.
 * Uses autoEncode to convert Gleam objects to plain JS objects first.
 */
export function autoEncodeMessagePack(value) {
  const jsValue = autoEncode(value);
  const buf = [];
  messagePackEncodeValue(jsValue, buf);
  return new BitArray(new Uint8Array(buf));
}

/**
 * Walk a module namespace and register every class that extends CustomType.
 * Pass the result of `import * as mod from "..."`.
 */
export function registerModule(moduleNamespace) {
  for (const key in moduleNamespace) {
    const value = moduleNamespace[key];
    if (typeof value === "function" && isCustomTypeClass(value)) {
      constructorRegistry.set(value.name, value);
    }
  }
}

// =============================================================================
// HTTP TRANSPORT
// =============================================================================

/**
 * Establish HTTP/SSE transport connection with offline queueing.
 *
 * Server→client: SSE text frames (EventSource).
 * Client→server: binary POST (application/octet-stream).
 * Offline queue: base64-encoded frames persisted to localStorage.
 */
export function httpConnect(postUrl, eventsUrl, flushBatchSize, handler) {
  // Closure-scoped state (not module-level, allows multiple instances)
  let eventSource = null;
  let pending = [];
  let isConnected = false;
  let persistScheduled = false;
  let isFlushing = false;

  function getPending() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY_HTTP_PENDING);
      if (raw) return JSON.parse(raw).map(base64ToFrame);
    } catch (_error) {
      // Corrupted data, reset to empty queue
    }
    return [];
  }

  function queuePending(frame) {
    const wasEmpty = pending.length === 0;
    pending.push(frame);
    if (wasEmpty) {
      try {
        localStorage.setItem(STORAGE_KEY_HTTP_PENDING, JSON.stringify(pending.map(frameToBase64)));
      } catch (_error) {
        // Quota exceeded — frame remains in-memory, sent on reconnect
      }
    } else if (!persistScheduled) {
      // Subsequent frames are coalesced — avoids O(n²) writes in rapid batches.
      persistScheduled = true;
      queueMicrotask(function () {
        persistScheduled = false;
        try {
          localStorage.setItem(STORAGE_KEY_HTTP_PENDING, JSON.stringify(pending.map(frameToBase64)));
        } catch (_error) {
          // Quota exceeded — frames remain in-memory, sent on reconnect
        }
      });
    }
  }

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
      localStorage.removeItem(STORAGE_KEY_HTTP_PENDING);
      pending = [];
    } else if (totalSent > 0) {
      pending = pending.slice(totalSent);
      localStorage.setItem(STORAGE_KEY_HTTP_PENDING, JSON.stringify(pending.map(frameToBase64)));
    }

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
      // SSE is text-only; convert to bytes so the handler always gets BitArray
      handler.on_receive(new BitArray(new TextEncoder().encode(event.data)));
    }
  };

  eventSource.onerror = function (_error) {
    isConnected = false;
    handler.on_disconnect();
    // Browser automatically attempts to reconnect (SSE built-in behaviour)
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
            queuePending(frame);
          });
      } else {
        queuePending(frame);
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
// MESSAGEPACK CODEC
// =============================================================================

/**
 * Decode MessagePack bytes to a Protocol using the provided codec.
 * Returns Ok(Protocol) or Error(undefined).
 *
 * Protocol instances are constructed using the Gleam-generated classes
 * imported from ./transport.mjs so that Gleam pattern matching works.
 */
export function decodeMessagePackProtocol(bitArray, codec) {
  try {
    const view = new DataView(bitArray.rawBuffer.buffer, bitArray.rawBuffer.byteOffset, bitArray.rawBuffer.byteLength);
    const [map] = messagePackDecodeAt(view, 0);
    if (typeof map !== "object" || map === null) throw new globalThis.Error("not a map");
    const type = map["type"];

    if (type === "acknowledge") {
      const sequence = map["sequence"];
      if (typeof sequence !== "number") throw new globalThis.Error("missing sequence");
      return new Ok(new Acknowledge(sequence));
    }

    if (type === "client_message") {
      const payloadRaw = map["payload"];
      if (!(payloadRaw instanceof Uint8Array)) throw new globalThis.Error("payload not bin");
      const result = codec.decode_message(new BitArray(payloadRaw));
      if (result instanceof Error) throw new globalThis.Error("decode payload failed");
      return new Ok(new ClientMessage(result[0]));
    }

    if (type === "server_message") {
      const sequence = map["sequence"];
      const payloadRaw = map["payload"];
      if (typeof sequence !== "number") throw new globalThis.Error("missing sequence");
      if (!(payloadRaw instanceof Uint8Array)) throw new globalThis.Error("payload not bin");
      const result = codec.decode_message(new BitArray(payloadRaw));
      if (result instanceof Error) throw new globalThis.Error("decode payload failed");
      return new Ok(new ServerMessage(sequence, result[0]));
    }

    if (type === "snapshot") {
      const sequence = map["sequence"];
      const stateRaw = map["state"];
      if (typeof sequence !== "number") throw new globalThis.Error("missing sequence");
      if (!(stateRaw instanceof Uint8Array)) throw new globalThis.Error("state not bin");
      const result = codec.decode_model(new BitArray(stateRaw));
      if (result instanceof Error) throw new globalThis.Error("decode state failed");
      return new Ok(new Snapshot(sequence, result[0]));
    }

    if (type === "resync") {
      const after_sequence = map["after_sequence"];
      if (typeof after_sequence !== "number") throw new globalThis.Error("missing after_sequence");
      return new Ok(new Resync(after_sequence));
    }

    throw new globalThis.Error(`Unknown protocol type: ${type}`);
  } catch (_e) {
    return new Error(undefined);
  }
}

/**
 * Encode a Protocol envelope to MessagePack bytes using the provided codec.
 * The envelope wraps payload/state as MessagePack bin so any binary codec works.
 * Protocol is a Gleam custom type; we inspect its constructor name.
 */
export function encodeMessagePackProtocol(protocol, codec) {
  const buf = [];
  const name = protocol.constructor.name;

  if (name === "Acknowledge") {
    buf.push(0x82); // fixmap(2)
    messagePackEncodeString("type", buf); messagePackEncodeString("acknowledge", buf);
    messagePackEncodeString("sequence", buf); messagePackEncodeInt(protocol.sequence, buf);
  } else if (name === "ClientMessage") {
    const payloadBytes = codec.encode_message(protocol.payload).rawBuffer;
    buf.push(0x82); // fixmap(2)
    messagePackEncodeString("type", buf); messagePackEncodeString("client_message", buf);
    messagePackEncodeString("payload", buf); messagePackEncodeBin(payloadBytes, buf);
  } else if (name === "ServerMessage") {
    const payloadBytes = codec.encode_message(protocol.payload).rawBuffer;
    buf.push(0x83); // fixmap(3)
    messagePackEncodeString("type", buf); messagePackEncodeString("server_message", buf);
    messagePackEncodeString("sequence", buf); messagePackEncodeInt(protocol.sequence, buf);
    messagePackEncodeString("payload", buf); messagePackEncodeBin(payloadBytes, buf);
  } else if (name === "Snapshot") {
    const stateBytes = codec.encode_model(protocol.state).rawBuffer;
    buf.push(0x83); // fixmap(3)
    messagePackEncodeString("type", buf); messagePackEncodeString("snapshot", buf);
    messagePackEncodeString("sequence", buf); messagePackEncodeInt(protocol.sequence, buf);
    messagePackEncodeString("state", buf); messagePackEncodeBin(stateBytes, buf);
  } else if (name === "Resync") {
    buf.push(0x82); // fixmap(2)
    messagePackEncodeString("type", buf); messagePackEncodeString("resync", buf);
    messagePackEncodeString("after_sequence", buf); messagePackEncodeInt(protocol.after_sequence, buf);
  } else {
    // Unknown protocol type — encode as empty map
    buf.push(0x80);
  }

  return new BitArray(new Uint8Array(buf));
}

// =============================================================================
// WEBSOCKET TRANSPORT
// =============================================================================

/**
 * Establish WebSocket connection with exponential-backoff reconnection and
 * offline queueing. Binary frames (ArrayBuffer) are used exclusively.
 * Offline queue is base64-encoded and persisted to localStorage.
 */
export function wsConnect(url, reconnectBaseMs, reconnectMaxMs, jitterRatio, multiplier, handler) {
  // Closure-scoped state (not module-level, allows multiple instances)
  let ws = null;
  let reconnectDelay = null;
  let reconnectTimer = null;
  let pending = [];
  let persistScheduled = false;

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

    if (reconnectDelay === null) {
      reconnectDelay = reconnectBaseMs;
    }

    // Jitter spreads reconnects after a mass disconnect (thundering herd)
    const jitteredDelay = reconnectDelay * (1 - jitterRatio + Math.random() * jitterRatio * 2);
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      openConnection();
    }, jitteredDelay);

    // Advance the progression regardless of jitter so the ceiling is reached
    // in a predictable number of attempts
    reconnectDelay = Math.min(reconnectDelay * multiplier, reconnectMaxMs);
  }

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
      localStorage.removeItem(STORAGE_KEY_WS_PENDING);
      pending = [];
    } else if (sent.length > 0) {
      // Partial flush — keep whatever didn't make it
      const remaining = pending.slice(sent.length);
      localStorage.setItem(STORAGE_KEY_WS_PENDING, JSON.stringify(remaining.map(frameToBase64)));
      pending = remaining;
    }
  }

  function getPending() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY_WS_PENDING);
      if (raw) return JSON.parse(raw).map(base64ToFrame);
    } catch (_error) {
      // Corrupted data, reset to empty queue
    }
    return [];
  }

  function queuePending(frame) {
    const wasEmpty = pending.length === 0;
    pending.push(frame);
    if (wasEmpty) {
      try {
        localStorage.setItem(STORAGE_KEY_WS_PENDING, JSON.stringify(pending.map(frameToBase64)));
      } catch (_error) {
        // Quota exceeded — frame remains in-memory, sent on reconnect
      }
    } else if (!persistScheduled) {
      // Subsequent frames are coalesced — avoids O(n²) writes in rapid batches.
      persistScheduled = true;
      queueMicrotask(function () {
        persistScheduled = false;
        try {
          localStorage.setItem(STORAGE_KEY_WS_PENDING, JSON.stringify(pending.map(frameToBase64)));
        } catch (_error) {
          // Quota exceeded — frames remain in-memory, sent on reconnect
        }
      });
    }
  }

  openConnection();

  return {
    send(bytes) {
      const frame = bytes.rawBuffer;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(frame);
      } else {
        queuePending(frame);
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

/** Derive WebSocket URL from current browser location. Uses wss: for HTTPS, ws: for HTTP. */
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
// PRIVATE FUNCTIONS
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

/** Encode a Uint8Array to a base64 string for localStorage persistence. */
function frameToBase64(frame) {
  let binary = "";
  for (let i = 0; i < frame.byteLength; i++) {
    binary += String.fromCharCode(frame[i]);
  }
  return globalThis.btoa(binary);
}

function isCustomTypeClass(fn) {
  let proto = fn.prototype;
  while (proto) {
    if (proto.constructor && proto.constructor.name === "CustomType") return true;
    proto = Object.getPrototypeOf(proto);
  }
  return false;
}

function messagePackDecodeArray(view, pos, len) {
  const arr = [];
  for (let i = 0; i < len; i++) {
    const [item, newPos] = messagePackDecodeAt(view, pos);
    arr.push(item);
    pos = newPos;
  }
  return [arr, pos];
}

/**
 * Decode a Uint8Array at offset, returning [value, newOffset].
 * Throws on unknown format bytes.
 */
function messagePackDecodeAt(view, pos) {
  const byte = view.getUint8(pos);
  pos++;

  // positive fixint
  if (byte <= 0x7f) return [byte, pos];
  // negative fixint
  if (byte >= 0xe0) return [byte - 256, pos];
  // fixstr
  if ((byte & 0xe0) === 0xa0) {
    const len = byte & 0x1f;
    const str = messagePackTextDecoder.decode(new Uint8Array(view.buffer, view.byteOffset + pos, len));
    return [str, pos + len];
  }
  // fixarray
  if ((byte & 0xf0) === 0x90) return messagePackDecodeArray(view, pos, byte & 0x0f);
  // fixmap
  if ((byte & 0xf0) === 0x80) return messagePackDecodeMap(view, pos, byte & 0x0f);

  switch (byte) {
    case 0xc0: return [null, pos];
    case 0xc2: return [false, pos];
    case 0xc3: return [true, pos];

    case 0xcc: return [view.getUint8(pos), pos + 1];
    case 0xcd: return [view.getUint16(pos), pos + 2];
    case 0xce: return [view.getUint32(pos), pos + 4];
    case 0xcf: return [Number(view.getBigUint64(pos)), pos + 8];

    case 0xd0: return [view.getInt8(pos), pos + 1];
    case 0xd1: return [view.getInt16(pos), pos + 2];
    case 0xd2: return [view.getInt32(pos), pos + 4];
    case 0xd3: return [Number(view.getBigInt64(pos)), pos + 8];

    case 0xcb: return [view.getFloat64(pos), pos + 8];

    case 0xd9: {
      const len = view.getUint8(pos);
      const str = messagePackTextDecoder.decode(new Uint8Array(view.buffer, view.byteOffset + pos + 1, len));
      return [str, pos + 1 + len];
    }
    case 0xda: {
      const len = view.getUint16(pos);
      const str = messagePackTextDecoder.decode(new Uint8Array(view.buffer, view.byteOffset + pos + 2, len));
      return [str, pos + 2 + len];
    }
    case 0xdb: {
      const len = view.getUint32(pos);
      const str = messagePackTextDecoder.decode(new Uint8Array(view.buffer, view.byteOffset + pos + 4, len));
      return [str, pos + 4 + len];
    }

    case 0xdc: return messagePackDecodeArray(view, pos + 2, view.getUint16(pos));
    case 0xdd: return messagePackDecodeArray(view, pos + 4, view.getUint32(pos));

    case 0xde: return messagePackDecodeMap(view, pos + 2, view.getUint16(pos));
    case 0xdf: return messagePackDecodeMap(view, pos + 4, view.getUint32(pos));

    case 0xc4: {
      const len = view.getUint8(pos);
      const arr = new Uint8Array(view.buffer, view.byteOffset + pos + 1, len);
      return [arr.slice(), pos + 1 + len];
    }
    case 0xc5: {
      const len = view.getUint16(pos);
      const arr = new Uint8Array(view.buffer, view.byteOffset + pos + 2, len);
      return [arr.slice(), pos + 2 + len];
    }
    case 0xc6: {
      const len = view.getUint32(pos);
      const arr = new Uint8Array(view.buffer, view.byteOffset + pos + 4, len);
      return [arr.slice(), pos + 4 + len];
    }

    default:
      throw new globalThis.Error(`Unknown MessagePack byte: 0x${byte.toString(16)}`);
  }
}

function messagePackDecodeMap(view, pos, len) {
  const map = {};
  for (let i = 0; i < len; i++) {
    const [key, pos1] = messagePackDecodeAt(view, pos);
    const [value, pos2] = messagePackDecodeAt(view, pos1);
    map[key] = value;
    pos = pos2;
  }
  return [map, pos];
}

function messagePackEncodeBin(uint8arr, buf) {
  const len = uint8arr.length;
  if (len <= 255) {
    buf.push(0xc4, len);
  } else if (len <= 65535) {
    buf.push(0xc5, len >> 8, len & 0xff);
  } else {
    buf.push(0xc6, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
  }
  for (const b of uint8arr) buf.push(b);
}

function messagePackEncodeInt(n, buf) {
  if (n >= 0) {
    if (n <= 0x7f) {
      buf.push(n);
    } else if (n <= 0xff) {
      buf.push(0xcc, n);
    } else if (n <= 0xffff) {
      buf.push(0xcd, n >> 8, n & 0xff);
    } else if (n <= 0xffffffff) {
      buf.push(0xce, (n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
    } else {
      buf.push(0xcf);
      const dv = new DataView(new ArrayBuffer(8));
      dv.setBigUint64(0, BigInt(n));
      for (let i = 0; i < 8; i++) buf.push(dv.getUint8(i));
    }
  } else {
    if (n >= -32) {
      buf.push(n & 0xff);
    } else if (n >= -128) {
      buf.push(0xd0, n & 0xff);
    } else if (n >= -32768) {
      buf.push(0xd1, (n >> 8) & 0xff, n & 0xff);
    } else if (n >= -2147483648) {
      buf.push(0xd2, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
    } else {
      buf.push(0xd3);
      const dv = new DataView(new ArrayBuffer(8));
      dv.setBigInt64(0, BigInt(n));
      for (let i = 0; i < 8; i++) buf.push(dv.getUint8(i));
    }
  }
}

function messagePackEncodeString(str, buf) {
  const bytes = messagePackTextEncoder.encode(str);
  const len = bytes.length;
  if (len <= 31) {
    buf.push(0xa0 | len);
  } else if (len <= 255) {
    buf.push(0xd9, len);
  } else if (len <= 65535) {
    buf.push(0xda, len >> 8, len & 0xff);
  } else {
    buf.push(0xdb, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
  }
  for (const b of bytes) buf.push(b);
}

/** Encode a JS value (produced by autoEncode) to a Uint8Array using MessagePack. */
function messagePackEncodeValue(value, buf) {
  if (value === null || value === undefined) {
    buf.push(0xc0);
    return;
  }
  if (typeof value === "boolean") {
    buf.push(value ? 0xc3 : 0xc2);
    return;
  }
  if (typeof value === "number") {
    if (Number.isInteger(value)) {
      messagePackEncodeInt(value, buf);
    } else {
      // float64
      buf.push(0xcb);
      const dv = new DataView(new ArrayBuffer(8));
      dv.setFloat64(0, value);
      for (let i = 0; i < 8; i++) buf.push(dv.getUint8(i));
    }
    return;
  }
  if (typeof value === "string") {
    messagePackEncodeString(value, buf);
    return;
  }
  if (Array.isArray(value)) {
    const len = value.length;
    if (len <= 15) {
      buf.push(0x90 | len);
    } else if (len <= 65535) {
      buf.push(0xdc, len >> 8, len & 0xff);
    } else {
      buf.push(0xdd, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
    }
    for (const item of value) messagePackEncodeValue(item, buf);
    return;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value);
    const len = keys.length;
    if (len <= 15) {
      buf.push(0x80 | len);
    } else if (len <= 65535) {
      buf.push(0xde, len >> 8, len & 0xff);
    } else {
      buf.push(0xdf, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
    }
    for (const key of keys) {
      messagePackEncodeString(key, buf);
      messagePackEncodeValue(value[key], buf);
    }
  }
}

/** Inner recursive JSON decode — returns raw value or throws on unknown constructor. */
function autoDecodeInner(json) {
  // Primitives
  if (json === null) return undefined; // Gleam's Nil
  if (typeof json === "boolean") return json;
  if (typeof json === "string") return json;
  if (typeof json === "number") return json;

  // Array → Gleam List
  if (Array.isArray(json)) {
    // Build Gleam list from right to left using proper NonEmpty/Empty instances
    let result = new Empty();
    for (let i = json.length - 1; i >= 0; i--) {
      const decodedItem = autoDecodeInner(json[i]);
      result = new NonEmpty(decodedItem, result);
    }
    return result;
  }

  // Custom type (object with "_" tag)
  if (json && typeof json === "object" && "_" in json) {
    const tag = json._;
    const ctor = constructorRegistry.get(tag);

    if (!ctor) {
      throw new globalThis.Error(
        `Unknown constructor: ${tag}. Did you forget to call register_types()?`,
      );
    }

    // Collect positional fields
    const fields = [];
    let fieldIndex = 0;
    while (String(fieldIndex) in json) {
      fields.push(autoDecodeInner(json[String(fieldIndex)]));
      fieldIndex++;
    }

    return new ctor(...fields);
  }

  // Fallback
  return json;
}
