//// This is the transport layer between the client/browser and the server,
//// ensuring that the centralised model within [`Store`](./store.html#Store)
//// on both sides remain in sync by exchanging serialised
//// [`Protocol`](#Protocol) messages over this module.
////
//// It works on both Erlang and JS targets since both ends need it, although
//// the WebSocket and HTTP/SSE connectors are JavaScript-only.
////
//// The module provides:
////
//// - Wire format: [`Protocol`](#Protocol) envelope types for messages
////   exchanged between client and server.
//// - Serialisation: [`Serialiser`](#Serialiser) with automatic
////   ([`automatic`](#automatic)) and custom ([`custom_json`](#custom_json),
////   [`custom_binary`](#custom_binary)) variants.
//// - WebSocket transport: [`websocket`](#websocket) config builder and
////   [`websocket_connect`](#websocket_connect) connector, with automatic
////   reconnection and offline queueing.
//// - HTTP/SSE transport: [`http`](#http) config builder and
////   [`http_connect`](#http_connect) connector using EventSource + POST.
////
//// For most apps, use [`transport.automatic`](#automatic) for
//// zero-configuration serialisation, then pick a transport. WebSockets
//// suit most cases, although switch to HTTP if corporate firewalls block them.
////
//// ```gleam
//// import lily/client
//// import lily/transport
////
//// pub fn main() {
////   let runtime = client.start(
////     app_store,
////     wiring: shared.wiring(),
////     serialiser: transport.automatic(),
////   )
////
////   client.connect(runtime,
////     with: transport.websocket(url: "ws://localhost:8080/ws")
////       |> transport.reconnect_base_milliseconds(1000)
////       |> transport.websocket_connect,
////   )
//// }
//// ```
////
//// Switch to HTTP/SSE when WebSocket connections are blocked:
////
//// ```gleam
//// client.connect(runtime,
////   with: transport.http(
////     post_url: "/api/messages",
////     events_url: "/api/events",
////   ) |> transport.http_connect,
//// )
//// ```
////
//// `automatic()` defaults to JSON so frames are more easily debuggable within
//// DevTools. You can (and probably should) use MessagePack for production
//// for smaller transport packages with
//// [`transport.use_message_pack`](#use_message_pack).
////
//// ```gleam
//// transport.automatic() |> transport.use_message_pack()
//// ```
////
//// The automatic serialiser uses positional encoding:
//// `{"_":"ConstructorName","0":field0,"1":field1,...}`. On JavaScript,
//// constructors must be registered so the decoder can reconstruct them.
////
//// To register constructors, your shared types module exposes a tiny FFI
//// shim that calls `registerModule` from `transport.ffi.mjs`, this part is key
//// do not forget:
////
//// ```javascript
//// // my_shared.ffi.mjs
//// import * as self from "./my_shared.mjs";
//// import { registerModule } from "../lily/lily/transport.ffi.mjs";
////
//// export function registerTypes() { registerModule(self); }
//// ```
////
//// ```gleam
//// // my_shared.gleam
//// pub fn serialiser() -> transport.Serialiser(Model, Message) {
////   let _ = register_types()
////   transport.automatic()
//// }
////
//// @target(javascript)
//// @external(javascript, "./my_shared.ffi.mjs", "registerTypes")
//// fn register_types() -> Nil { Nil }
////
//// @target(erlang)
//// fn register_types() -> Nil { Nil }
//// ```
////
//// For shared types split across multiple modules, call `registerModule`
//// once per file in the FFI shim:
////
//// ```javascript
//// import * as messages from "./messages.mjs";
//// import * as model from "./model.mjs";
//// import { registerModule } from "../lily/lily/transport.ffi.mjs";
////
//// export function registerTypes() {
////   registerModule(messages);
////   registerModule(model);
//// }
//// ```
////
//// For cases where automatic serialisation isn't suitable, you can use
//// [`transport.custom_json`](#custom_json) or
//// [`transport.custom_binary`](#custom_binary) for explicit encode/decode.
////

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import lily/internal/auto_codec
import lily/internal/message_pack.{
  type Value, ValueArray, ValueBytes, ValueInteger, ValueMap, ValueString,
}
import lily/internal/reflection

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Opaque transport connector. Built by
/// [`websocket_connect`](#websocket_connect) and
/// [`http_connect`](#http_connect), passed to
/// [`client.connect`](./client.html#connect).
pub opaque type Connector {
  Connector(connect: fn(Handler) -> Transport)
}

/// Callbacks the runtime provides to the transport. `on_receive` fires on a
/// message from the server, `on_reconnect` when the connection is established
/// or restored, `on_disconnect` when it is lost.
@internal
pub type Handler {
  Handler(
    on_receive: fn(BitArray) -> Nil,
    on_reconnect: fn() -> Nil,
    on_disconnect: fn() -> Nil,
  )
}

@target(javascript)
/// HTTP/SSE connection config. A POST URL for client-to-server messages and an
/// SSE events URL for server-to-client.
pub opaque type HttpConfig {
  HttpConfig(post_url: String, events_url: String, flush_batch_size: Int)
}

/// Wire-format envelope between client and server. Sequence numbers are
/// server-assigned and tracked separately per [`Target`](#Target), so each
/// store stays in sync independently.
///
/// Sequences are ordering metadata, not a security control. The client records
/// whatever sequence a frame carries with no monotonicity check, so they give
/// no replay or reorder protection alone. The server is the trust anchor (it
/// assigns ids and sequences and ignores server-to-client frames from a
/// client), and confidentiality and integrity rest on the transport. Run over
/// secure connections in production. Built-in connectors select `wss`
/// automatically on an HTTPS page.
@internal
pub type Protocol(model, message) {
  /// Server, after applying a `SessionMessage` or `TopicMessage` and assigning
  /// it a sequence for the target. Also sent to a topic's subscribers when the
  /// topic is stopped.
  Acknowledge(target: Target, sequence: Int)

  /// Server, right after a client connects, carrying the server-assigned
  /// `client_id`. Use [`client.client_id`](./client.html#client_id) to inject
  /// it into your model so every session carries its identity.
  Connected(client_id: String)

  /// Server, directly to a topic's subscribers. No sequence, never replayed on
  /// resync. Ephemeral by design.
  Push(topic_id: String, payload: message)

  /// Server, when a `Subscribe` is denied: missing topic or kind, invalid
  /// topic id, or `can_subscribe` returned `False`.
  Rejected(topic_id: String, reason: String)

  /// Client, requesting the current state of every known target after a full
  /// reconnect. The server responds with a `Snapshot` per target regardless of
  /// how far behind, so the wire form is just the target list.
  Resync(cursors: List(Target))

  /// Client update to apply to the originating connection's session store.
  SessionMessage(payload: message)

  /// Server, an applied session-store update to a single targeted client, sent
  /// by [`server.dispatch_to`](./server.html#dispatch_to) or
  /// [`server.dispatch_to_all`](./server.html#dispatch_to_all). Sequence is
  /// the client's session sequence after applying.
  SessionUpdate(sequence: Int, payload: message)

  /// Server, in response to `Resync` (per target) and `Subscribe` (the
  /// subscribed topic).
  Snapshot(target: Target, sequence: Int, state: model)

  /// Client, to join a topic. Server replies `Snapshot(Topic(id), ...)` on
  /// success or `Rejected(id, reason)` on failure.
  Subscribe(topic_id: String)

  /// Client update to apply to a shared topic store. Server fans the result
  /// out as `TopicUpdate` to every other subscriber and `Acknowledge` to the
  /// originator.
  TopicMessage(topic_id: String, payload: message)

  /// Server, an applied topic-store update to every subscriber but the
  /// originator. Sequence is the topic's sequence after applying.
  TopicUpdate(topic_id: String, sequence: Int, payload: message)

  /// Client, to leave a topic. Fire-and-forget, no confirmation frame back.
  Unsubscribe(topic_id: String)

  /// Server, on connect and reconnect, carrying a build identifier. The client
  /// remembers the first and compares later ones, so a change (a deploy
  /// landed) can be surfaced to the user. See
  /// [`client.on_version_mismatch`](./client.html#on_version_mismatch).
  Version(hash: String)
}

/// Serialises `Protocol` values to and from bytes. `Auto` uses positional
/// encoding, works for any Gleam custom type without config, its `format`
/// field selecting JSON or MessagePack at runtime. `CustomJson` and
/// `CustomBinary` carry user-supplied codecs at a fixed format.
///
/// Construct via [`automatic`](#automatic), [`custom_json`](#custom_json), or
/// [`custom_binary`](#custom_binary). Toggle the auto format via
/// [`use_json`](#use_json) and [`use_message_pack`](#use_message_pack), no-ops
/// on custom serialisers.
pub opaque type Serialiser(model, message) {
  Auto(format: AutoFormat, codec: BinaryCodec(model, message))
  CustomJson(
    encode_message: fn(message) -> Json,
    decode_message: decode.Decoder(message),
    encode_model: fn(model) -> Json,
    decode_model: decode.Decoder(model),
  )
  CustomBinary(codec: BinaryCodec(model, message))
}

/// Which store a frame applies to, the per-connection session store or a named
/// shared topic store.
@internal
pub type Target {
  Session
  Topic(id: String)
}

/// Transport handle returned by a [`Connector`](#Connector). Carries `send`
/// and `close`. Constructed by [`websocket_connect`](#websocket_connect) and
/// [`http_connect`](#http_connect), not user-facing.
@internal
pub opaque type Transport {
  Transport(send: fn(BitArray) -> Nil, close: fn() -> Nil)
}

@target(javascript)
/// WebSocket connection config. Use the builder functions to customise
/// reconnection.
pub opaque type WebSocketConfig {
  WebSocketConfig(
    url: String,
    reconnect_base_milliseconds: Int,
    reconnect_max_milliseconds: Int,
    reconnect_jitter_ratio: Float,
    reconnect_multiplier: Float,
  )
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

/// Format selector for the [`Auto`](#Serialiser) variant. Toggled by
/// [`use_json`](#use_json) and [`use_message_pack`](#use_message_pack).
type AutoFormat {
  AutoJson
  AutoMessagePack
}

type BinaryCodec(model, message) {
  BinaryCodec(
    encode_message: fn(message) -> BitArray,
    decode_message: fn(BitArray) -> Result(message, Nil),
    encode_model: fn(model) -> BitArray,
    decode_model: fn(BitArray) -> Result(model, Nil),
    max_decode_depth: Int,
  )
}

/// One field of a `Protocol` envelope, the source of truth both the JSON and
/// MessagePack encoders map over.
type Field(model, message) {
  FieldInt(name: String, value: Int)
  FieldMessage(name: String, value: message)
  FieldState(name: String, value: model)
  FieldString(name: String, value: String)
  FieldTarget(name: String, value: Target)
  FieldTargetList(name: String, value: List(Target))
}

@target(javascript)
type HttpHandle

@target(javascript)
type WsHandle

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create an automatic serialiser. Uses JSON by default.
///
/// Switch to MessagePack for production (smaller, faster binary frames)
/// with [`transport.use_message_pack`](#use_message_pack):
///
/// ```gleam
/// // dev (JSON)
/// transport.automatic()
///
/// // prod (MessagePack)
/// transport.automatic() |> transport.use_message_pack()
/// ```
///
/// On JavaScript, register constructors before connecting, else the decoder
/// can't reconstruct types that only arrive from the server or other clients.
/// Use an FFI shim in your shared types module calling `registerModule` from
/// `transport.ffi.mjs`, once per file. See the module docs for the full
/// pattern.
///
/// ## Supported value shapes
///
/// Every Gleam value the model and message types are likely to hold:
///
/// - Primitives, `Int`, `Float`, `String`, `Bool`, `Nil`.
/// - Custom types, records and variants, a tagged map whose `_` field carries
///   the PascalCase constructor name.
/// - Lists, as arrays.
/// - Tuples, `#(a, b)` as tag-less maps with positional keys
///   (`{"0":a,"1":b}`), told from custom types by the absent `_`.
/// - `gleam/dict.Dict`, as `{"_":"$dict","0":[[k,v],...]}`.
/// - `gleam/set.Set`, as `{"_":"$set","0":[v,...]}`.
///
/// ## Not supported: `BitArray`
///
/// `BitArray` fields in synced types are not auto-encoded. Erlang represents
/// both `String` and `BitArray` as native binaries, so reflection can't tell
/// them apart, a byte sequence like `<<104,101,108,108,111>>` is both a valid
/// `String` and a valid `BitArray`. Encoding the wrong one corrupts data.
///
/// For raw bytes, wrap them in a marker CustomType and encode yourself with
/// [`custom_binary`](#custom_binary) or [`custom_json`](#custom_json):
///
/// ```gleam
/// pub type Bytes {
///   Bytes(data: BitArray)
/// }
/// ```
///
/// Then provide custom encode/decode functions that base64-encode the inner
/// field.
pub fn automatic() -> Serialiser(model, message) {
  Auto(
    format: AutoJson,
    codec: auto_binary_codec(message_pack.default_max_depth),
  )
}

/// Close the transport connection. Cleans up resources and stops reconnecting.
@internal
pub fn close(transport: Transport) -> Nil {
  transport.close()
}

/// Create a serialiser from explicit binary encode/decode functions, for a
/// custom binary codec (MessagePack, CBOR, any binary format). Format fixed to
/// binary, the [`use_json`](#use_json) and
/// [`use_message_pack`](#use_message_pack) toggles are no-ops here.
pub fn custom_binary(
  encode_message encode_message: fn(message) -> BitArray,
  decode_message decode_message: fn(BitArray) -> Result(message, Nil),
  encode_model encode_model: fn(model) -> BitArray,
  decode_model decode_model: fn(BitArray) -> Result(model, Nil),
) -> Serialiser(model, message) {
  CustomBinary(BinaryCodec(
    encode_message:,
    decode_message:,
    encode_model:,
    decode_model:,
    max_decode_depth: message_pack.default_max_depth,
  ))
}

/// Create a serialiser from explicit JSON encode/decode functions, when the
/// auto format is not suitable (third-party APIs, human-readable JSON,
/// backwards compatibility). Format fixed to JSON, the [`use_json`](#use_json)
/// and [`use_message_pack`](#use_message_pack) toggles are no-ops here.
pub fn custom_json(
  encode_message encode_message: fn(message) -> Json,
  decode_message decode_message: decode.Decoder(message),
  encode_model encode_model: fn(model) -> Json,
  decode_model decode_model: decode.Decoder(model),
) -> Serialiser(model, message) {
  CustomJson(encode_message:, decode_message:, encode_model:, decode_model:)
}

/// Decode `BitArray` bytes into a [`Protocol`](#Protocol) result.
pub fn decode(
  bytes: BitArray,
  serialiser serialiser: Serialiser(model, message),
) -> Result(Protocol(model, message), Nil) {
  case serialiser {
    Auto(format: AutoJson, ..) ->
      decode_json(
        bytes,
        decode.new_primitive_decoder("Auto", ffi_auto_decode),
        decode.new_primitive_decoder("Auto", ffi_auto_decode),
      )
    Auto(format: AutoMessagePack, codec:) ->
      decode_message_pack_protocol(bytes, codec)
    CustomJson(decode_message:, decode_model:, ..) ->
      decode_json(bytes, decode_message, decode_model)
    CustomBinary(codec:) -> decode_message_pack_protocol(bytes, codec)
  }
}

/// Encode a `Protocol` into bytes. MessagePack for a binary serialiser
/// (`custom_binary`, or [`automatic`](#automatic) after
/// [`use_message_pack`](#use_message_pack)), JSON otherwise.
/// [`automatic`](#automatic) defaults to JSON.
pub fn encode(
  protocol: Protocol(model, message),
  serialiser serialiser: Serialiser(model, message),
) -> BitArray {
  case serialiser {
    Auto(format: AutoJson, ..) ->
      encode_json(protocol, ffi_auto_encode, ffi_auto_encode)
    Auto(format: AutoMessagePack, codec:) ->
      encode_message_pack_protocol(protocol, codec)
    CustomJson(encode_message:, encode_model:, ..) ->
      encode_json(protocol, encode_message, encode_model)
    CustomBinary(codec:) -> encode_message_pack_protocol(protocol, codec)
  }
}

/// Encode a model as an inline hydration payload for pre-rendered HTML.
/// Returns `<script type="application/json" id="lily-snapshot">...</script>`
/// wrapping a JSON `Snapshot(Session, 0, model)` frame.
/// [`client.hydrate`](./client.html#hydrate) reads it on mount as the initial
/// state, saving a round-trip on first paint. A fixed initial state baked into
/// the page, not per-request data.
///
/// Always JSON regardless of the format toggle, since binary MessagePack isn't
/// safe to inline in HTML. A `CustomBinary` serialiser produces a
/// base16-encoded payload, so prefer `automatic` or `custom_json` here.
///
/// ```gleam
/// let body = "<!DOCTYPE html><html><body>"
///   <> "<div id=\"app\">" <> rendered_html <> "</div>"
///   <> transport.encode_initial_snapshot(
///     serialiser: shared.serialiser(),
///     model: initial_model,
///   )
///   <> "</body></html>"
/// ```
///
/// Not proper SSR, only the initial snapshot.
pub fn encode_initial_snapshot(
  serialiser serialiser: Serialiser(model, message),
  model model: model,
) -> String {
  let frame = Snapshot(target: Session, sequence: 0, state: model)
  // Force JSON for the inline payload
  let json_serialiser = case serialiser {
    Auto(_, codec) -> Auto(AutoJson, codec)
    CustomJson(_, _, _, _) -> serialiser
    CustomBinary(_) -> serialiser
  }
  let bytes = encode(frame, serialiser: json_serialiser)
  let json_text = bit_array.to_string(bytes) |> result.unwrap("")
  "<script type=\"application/json\" id=\"lily-snapshot\">"
  <> json_text
  <> "</script>"
}

@target(javascript)
/// Max queued messages POSTed in parallel on HTTP/SSE reconnect. Lower limits
/// concurrent POSTs during a reconnect burst, higher flushes faster. Default
/// 10.
pub fn flush_batch_size(config: HttpConfig, size: Int) -> HttpConfig {
  HttpConfig(..config, flush_batch_size: size)
}

@target(javascript)
/// Create an HTTP/SSE transport configuration. `post_url` sends messages to
/// the server, `events_url` receives Server-Sent Events.
///
/// ```gleam
/// transport.http(
///   post_url: "/api/messages",
///   events_url: "/api/events",
/// )
/// ```
pub fn http(
  post_url post_url: String,
  events_url events_url: String,
) -> HttpConfig {
  HttpConfig(post_url: post_url, events_url: events_url, flush_batch_size: 10)
}

@target(javascript)
/// Returns a connector establishing an HTTP/SSE connection. Pass to
/// `client.connect`.
///
/// ```gleam
/// client.connect(runtime,
///   with: transport.http(
///     post_url: "/api/messages",
///     events_url: "/api/events",
///   ) |> transport.http_connect,
///   serialiser: transport.automatic(),
/// )
/// ```
pub fn http_connect(config: HttpConfig) -> Connector {
  Connector(connect: fn(handler: Handler) {
    let handle =
      ffi_http_connect(
        config.post_url,
        config.events_url,
        config.flush_batch_size,
        handler,
      )
    new(send: fn(bytes) { ffi_http_send(handle, bytes) }, close: fn() {
      ffi_http_close(handle)
    })
  })
}

/// Wrap a `connect` function as a [`Connector`](#Connector). Used by
/// [`websocket_connect`](#websocket_connect), [`http_connect`](#http_connect),
/// and transport fakes in tests.
@internal
pub fn make_connector(connect: fn(Handler) -> Transport) -> Connector {
  Connector(connect:)
}

/// Max nesting depth the MessagePack decoder will parse, bounding stack use on
/// hostile deeply-nested frames. Default is generous, raise it only if your
/// model legitimately nests beyond it. No-op on `custom_json`.
///
/// ```gleam
/// transport.automatic()
/// |> transport.use_message_pack()
/// |> transport.max_decode_depth(256)
/// ```
pub fn max_decode_depth(
  serialiser: Serialiser(model, message),
  depth: Int,
) -> Serialiser(model, message) {
  case serialiser {
    Auto(format:, ..) -> Auto(format:, codec: auto_binary_codec(depth))
    CustomBinary(codec:) ->
      CustomBinary(codec: BinaryCodec(..codec, max_decode_depth: depth))
    CustomJson(..) -> serialiser
  }
}

/// Create a [`Transport`](#Transport) from send and close functions. Used by
/// transport implementations (WebSocket, HTTP) to build the handle they return
/// from their connector.
@internal
pub fn new(
  send send: fn(BitArray) -> Nil,
  close close: fn() -> Nil,
) -> Transport {
  Transport(send:, close:)
}

@target(javascript)
/// Base delay in milliseconds for WebSocket reconnection. Doubles on each
/// failed attempt up to the maximum.
pub fn reconnect_base_milliseconds(
  config: WebSocketConfig,
  milliseconds: Int,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_base_milliseconds: milliseconds)
}

@target(javascript)
/// Jitter ratio applied to each WebSocket reconnection delay. `0.25` gives
/// plus or minus 25% randomisation, spreading reconnects after a mass
/// disconnect so the server isn't stampeded. Between 0.0 (none) and 1.0
/// (full). Default 0.25.
pub fn reconnect_jitter_ratio(
  config: WebSocketConfig,
  ratio: Float,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_jitter_ratio: ratio)
}

@target(javascript)
/// Max delay in milliseconds between WebSocket reconnection attempts.
pub fn reconnect_max_milliseconds(
  config: WebSocketConfig,
  milliseconds: Int,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_max_milliseconds: milliseconds)
}

@target(javascript)
/// Backoff multiplier for WebSocket reconnection. Delay after each failed
/// attempt is multiplied by this, up to
/// [`reconnect_max_milliseconds`](#reconnect_max_milliseconds). Default 2.0
/// (standard exponential backoff).
pub fn reconnect_multiplier(
  config: WebSocketConfig,
  multiplier: Float,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_multiplier: multiplier)
}

/// Run a connector with the runtime's handler. Used by
/// [`client.connect`](./client.html#connect).
@internal
pub fn run_connector(connector: Connector, handler: Handler) -> Transport {
  connector.connect(handler)
}

/// Send bytes through the transport, a serialised
/// [`Protocol`](#Protocol) message.
@internal
pub fn send(transport: Transport, bytes: BitArray) -> Nil {
  transport.send(bytes)
}

/// Parse a sequence-cursor storage key back into a [`Target`](#Target).
@internal
pub fn target_from_key(key: String) -> Result(Target, Nil) {
  case key {
    "session" -> Ok(Session)
    _ ->
      case string.starts_with(key, "topic:") {
        True -> Ok(Topic(string.drop_start(key, 6)))
        False -> Error(Nil)
      }
  }
}

/// Encode a [`Target`](#Target) as the stable string key the client uses to
/// track per-target sequence cursors in session storage.
@internal
pub fn target_key(target: Target) -> String {
  case target {
    Session -> "session"
    Topic(id) -> "topic:" <> id
  }
}

@target(javascript)
/// Derive a WebSocket URL from the browser's current location, using `wss:`
/// for HTTPS pages and `ws:` for HTTP. `path` is the endpoint path.
///
/// ```gleam
/// // On https://example.com:3000/app
/// transport.url_from_current_location(path: "/ws")
/// // Returns "wss://example.com:3000/ws"
/// ```
pub fn url_from_current_location(path path: String) -> String {
  ffi_ws_url_from_current_location(path)
}

/// Switch the serialiser to JSON encoding. Only meaningful on
/// [`automatic`](#automatic), no-op on `custom_json` or `custom_binary`.
pub fn use_json(
  serialiser: Serialiser(model, message),
) -> Serialiser(model, message) {
  case serialiser {
    Auto(format: AutoMessagePack, codec:) -> Auto(format: AutoJson, codec:)
    Auto(..) | CustomJson(..) | CustomBinary(..) -> serialiser
  }
}

/// Switch the serialiser back to MessagePack after [`use_json`](#use_json).
/// Only meaningful on [`automatic`](#automatic), no-op on `custom_json` or
/// `custom_binary`.
pub fn use_message_pack(
  serialiser: Serialiser(model, message),
) -> Serialiser(model, message) {
  case serialiser {
    Auto(format: AutoJson, codec:) -> Auto(format: AutoMessagePack, codec:)
    Auto(..) | CustomJson(..) | CustomBinary(..) -> serialiser
  }
}

@target(javascript)
/// Create a WebSocket configuration for the given URL. Defaults 1000ms base
/// delay, 30000ms maximum (exponential backoff).
pub fn websocket(url url: String) -> WebSocketConfig {
  WebSocketConfig(
    url: url,
    reconnect_base_milliseconds: 1000,
    reconnect_max_milliseconds: 30_000,
    reconnect_jitter_ratio: 0.25,
    reconnect_multiplier: 2.0,
  )
}

@target(javascript)
/// Returns a connector establishing a WebSocket connection. Pass to
/// `client.connect`.
///
/// ```gleam
/// client.connect(runtime,
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.reconnect_base_milliseconds(2000)
///     |> transport.websocket_connect,
///   serialiser: transport.automatic(),
/// )
/// ```
pub fn websocket_connect(config: WebSocketConfig) -> Connector {
  Connector(connect: fn(handler: Handler) {
    let handle =
      ffi_ws_connect(
        config.url,
        config.reconnect_base_milliseconds,
        config.reconnect_max_milliseconds,
        config.reconnect_jitter_ratio,
        config.reconnect_multiplier,
        handler,
      )
    new(send: fn(bytes) { ffi_ws_send(handle, bytes) }, close: fn() {
      ffi_ws_close(handle)
    })
  })
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn acknowledge_decoder() -> decode.Decoder(Protocol(model, message)) {
  use target <- decode.field("target", target_decoder())
  use sequence <- decode.field("sequence", decode.int)
  decode.success(Acknowledge(target:, sequence:))
}

// Capture `max_decode_depth` so envelope and payload parse both honour the
// cap.
fn auto_binary_codec(max_decode_depth: Int) -> BinaryCodec(model, message) {
  BinaryCodec(
    encode_message: ffi_auto_encode_message_pack,
    decode_message: fn(bytes) {
      ffi_auto_decode_message_pack(bytes, max_decode_depth)
    },
    encode_model: ffi_auto_encode_message_pack,
    decode_model: fn(bytes) {
      ffi_auto_decode_message_pack(bytes, max_decode_depth)
    },
    max_decode_depth:,
  )
}

fn connected_decoder() -> decode.Decoder(Protocol(model, message)) {
  use client_id <- decode.field("client_id", decode.string)
  decode.success(Connected(client_id:))
}

fn decode_json(
  bytes: BitArray,
  decode_message: decode.Decoder(message),
  decode_model: decode.Decoder(model),
) -> Result(Protocol(model, message), Nil) {
  let decoder = protocol_decoder(decode_message, decode_model)
  bit_array.to_string(bytes)
  |> result.try(fn(text) {
    json.parse(from: text, using: decoder)
    |> result.replace_error(Nil)
  })
}

fn decode_message_pack_envelope(
  entries: List(#(Value, Value)),
  codec: BinaryCodec(model, message),
) -> Result(Protocol(model, message), Nil) {
  use type_value <- result.try(message_pack.lookup_string_key(entries, "type"))
  use type_name <- result.try(value_string(type_value))
  case type_name {
    "acknowledge" -> {
      use target_value <- result.try(message_pack.lookup_string_key(
        entries,
        "target",
      ))
      use target <- result.try(decode_target_message_pack(target_value))
      use sequence_value <- result.try(message_pack.lookup_string_key(
        entries,
        "sequence",
      ))
      use sequence <- result.try(value_int(sequence_value))
      Ok(Acknowledge(target:, sequence:))
    }

    "connected" -> {
      use client_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "client_id",
      ))
      use client_id <- result.try(value_string(client_id_value))
      Ok(Connected(client_id:))
    }

    "push" -> {
      use topic_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "topic_id",
      ))
      use topic_id <- result.try(value_string(topic_id_value))
      use payload_value <- result.try(message_pack.lookup_string_key(
        entries,
        "payload",
      ))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(Push(topic_id:, payload:))
    }

    "rejected" -> {
      use topic_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "topic_id",
      ))
      use topic_id <- result.try(value_string(topic_id_value))
      use reason_value <- result.try(message_pack.lookup_string_key(
        entries,
        "reason",
      ))
      use reason <- result.try(value_string(reason_value))
      Ok(Rejected(topic_id:, reason:))
    }

    "resync" -> {
      use cursors_value <- result.try(message_pack.lookup_string_key(
        entries,
        "cursors",
      ))
      use cursors <- result.try(value_array(cursors_value))
      use targets <- result.try(list.try_map(
        cursors,
        decode_target_message_pack,
      ))
      Ok(Resync(cursors: targets))
    }

    "session_message" -> {
      use payload_value <- result.try(message_pack.lookup_string_key(
        entries,
        "payload",
      ))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(SessionMessage(payload:))
    }

    "session_update" -> {
      use sequence_value <- result.try(message_pack.lookup_string_key(
        entries,
        "sequence",
      ))
      use sequence <- result.try(value_int(sequence_value))
      use payload_value <- result.try(message_pack.lookup_string_key(
        entries,
        "payload",
      ))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(SessionUpdate(sequence:, payload:))
    }

    "snapshot" -> {
      use target_value <- result.try(message_pack.lookup_string_key(
        entries,
        "target",
      ))
      use target <- result.try(decode_target_message_pack(target_value))
      use sequence_value <- result.try(message_pack.lookup_string_key(
        entries,
        "sequence",
      ))
      use sequence <- result.try(value_int(sequence_value))
      use state_value <- result.try(message_pack.lookup_string_key(
        entries,
        "state",
      ))
      use state_bytes <- result.try(value_bytes(state_value))
      use state <- result.try(codec.decode_model(state_bytes))
      Ok(Snapshot(target:, sequence:, state:))
    }

    "subscribe" -> {
      use topic_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "topic_id",
      ))
      use topic_id <- result.try(value_string(topic_id_value))
      Ok(Subscribe(topic_id:))
    }

    "topic_message" -> {
      use topic_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "topic_id",
      ))
      use topic_id <- result.try(value_string(topic_id_value))
      use payload_value <- result.try(message_pack.lookup_string_key(
        entries,
        "payload",
      ))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(TopicMessage(topic_id:, payload:))
    }

    "topic_update" -> {
      use topic_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "topic_id",
      ))
      use topic_id <- result.try(value_string(topic_id_value))
      use sequence_value <- result.try(message_pack.lookup_string_key(
        entries,
        "sequence",
      ))
      use sequence <- result.try(value_int(sequence_value))
      use payload_value <- result.try(message_pack.lookup_string_key(
        entries,
        "payload",
      ))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(TopicUpdate(topic_id:, sequence:, payload:))
    }

    "unsubscribe" -> {
      use topic_id_value <- result.try(message_pack.lookup_string_key(
        entries,
        "topic_id",
      ))
      use topic_id <- result.try(value_string(topic_id_value))
      Ok(Unsubscribe(topic_id:))
    }

    "version" -> {
      use hash_value <- result.try(message_pack.lookup_string_key(
        entries,
        "hash",
      ))
      use hash <- result.try(value_string(hash_value))
      Ok(Version(hash:))
    }

    _ -> Error(Nil)
  }
}

/// Decode MessagePack bytes to a Protocol, the codec handling payload/state
/// values.
fn decode_message_pack_protocol(
  bytes: BitArray,
  codec: BinaryCodec(model, message),
) -> Result(Protocol(model, message), Nil) {
  use #(top_value, _) <- result.try(message_pack.decode_bounded(
    bytes,
    codec.max_decode_depth,
  ))
  case top_value {
    ValueMap(entries) -> decode_message_pack_envelope(entries, codec)
    _ -> Error(Nil)
  }
}

fn decode_target_message_pack(value: Value) -> Result(Target, Nil) {
  case value {
    ValueMap(entries) -> {
      use kind_value <- result.try(message_pack.lookup_string_key(
        entries,
        "kind",
      ))
      use kind <- result.try(value_string(kind_value))
      case kind {
        "session" -> Ok(Session)
        "topic" -> {
          use id_value <- result.try(message_pack.lookup_string_key(
            entries,
            "id",
          ))
          use id <- result.try(value_string(id_value))
          Ok(Topic(id:))
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn encode_json(
  protocol: Protocol(model, message),
  encode_message: fn(message) -> Json,
  encode_model: fn(model) -> Json,
) -> BitArray {
  let #(tag, fields) = protocol_fields(protocol)
  let entries =
    list.map(fields, fn(field) {
      case field {
        FieldInt(name:, value:) -> #(name, json.int(value))
        FieldString(name:, value:) -> #(name, json.string(value))
        FieldMessage(name:, value:) -> #(name, encode_message(value))
        FieldState(name:, value:) -> #(name, encode_model(value))
        FieldTarget(name:, value:) -> #(name, encode_target_json(value))
        FieldTargetList(name:, value:) -> #(
          name,
          json.array(value, encode_target_json),
        )
      }
    })
  json.object([#("type", json.string(tag)), ..entries])
  |> json.to_string
  |> bit_array.from_string
}

/// Encode a Protocol to MessagePack bytes. Pure Gleam, source of truth for
/// both targets. Payload/state slots embed bytes from the configured codec
/// (auto or user-supplied).
fn encode_message_pack_protocol(
  protocol: Protocol(model, message),
  codec: BinaryCodec(model, message),
) -> BitArray {
  let str = message_pack.encode_string
  let bin = message_pack.encode_bin
  let #(tag, fields) = protocol_fields(protocol)
  let entries =
    list.map(fields, fn(field) {
      case field {
        FieldInt(name:, value:) -> #(str(name), message_pack.encode_int(value))
        FieldString(name:, value:) -> #(str(name), str(value))
        FieldMessage(name:, value:) -> #(
          str(name),
          bin(codec.encode_message(value)),
        )
        FieldState(name:, value:) -> #(
          str(name),
          bin(codec.encode_model(value)),
        )
        FieldTarget(name:, value:) -> #(
          str(name),
          encode_target_message_pack(value),
        )
        FieldTargetList(name:, value:) -> #(
          str(name),
          message_pack.encode_array(list.map(value, encode_target_message_pack)),
        )
      }
    })
  message_pack.encode_map([#(str("type"), str(tag)), ..entries])
}

fn encode_target_json(target: Target) -> Json {
  case target {
    Session -> json.object([#("kind", json.string("session"))])
    Topic(id:) ->
      json.object([
        #("kind", json.string("topic")),
        #("id", json.string(id)),
      ])
  }
}

fn encode_target_message_pack(target: Target) -> BitArray {
  let str = message_pack.encode_string
  case target {
    Session -> message_pack.encode_map([#(str("kind"), str("session"))])
    Topic(id:) ->
      message_pack.encode_map([
        #(str("kind"), str("topic")),
        #(str("id"), str(id)),
      ])
  }
}

fn ffi_auto_decode(value: Dynamic) -> Result(a, a) {
  case auto_codec.decode_json(value) {
    Ok(decoded) -> Ok(reflection.passthrough(decoded))
    Error(_) -> Error(reflection.passthrough(value))
  }
}

fn ffi_auto_decode_message_pack(
  bytes: BitArray,
  max_depth: Int,
) -> Result(a, Nil) {
  case auto_codec.decode_message_pack_bounded(bytes, max_depth) {
    Ok(value) -> Ok(reflection.passthrough(value))
    Error(_) -> Error(Nil)
  }
}

fn ffi_auto_encode(value: a) -> Json {
  auto_codec.encode_json(value)
}

fn ffi_auto_encode_message_pack(value: a) -> BitArray {
  auto_codec.encode_message_pack(value)
}

fn protocol_decoder(
  decode_message: decode.Decoder(message),
  decode_model: decode.Decoder(model),
) -> decode.Decoder(Protocol(model, message)) {
  use protocol_type <- decode.then(decode.at(["type"], decode.string))
  case protocol_type {
    "acknowledge" -> acknowledge_decoder()
    "connected" -> connected_decoder()
    "push" -> push_decoder(decode_message)
    "rejected" -> rejected_decoder()
    "resync" -> resync_decoder()
    "session_message" -> session_message_decoder(decode_message)
    "session_update" -> session_update_decoder(decode_message)
    "snapshot" -> snapshot_decoder(decode_model)
    "subscribe" -> subscribe_decoder()
    "topic_message" -> topic_message_decoder(decode_message)
    "topic_update" -> topic_update_decoder(decode_message)
    "unsubscribe" -> unsubscribe_decoder()
    "version" -> version_decoder()
    _ -> decode.failure(Acknowledge(Session, 0), "Protocol")
  }
}

/// Wire tag and ordered fields for each `Protocol` variant. Field order must
/// match the historical encoders exactly to keep the wire format unchanged.
fn protocol_fields(
  protocol: Protocol(model, message),
) -> #(String, List(Field(model, message))) {
  case protocol {
    Acknowledge(target:, sequence:) -> #("acknowledge", [
      FieldTarget("target", target),
      FieldInt("sequence", sequence),
    ])
    Connected(client_id:) -> #("connected", [
      FieldString("client_id", client_id),
    ])
    Push(topic_id:, payload:) -> #("push", [
      FieldString("topic_id", topic_id),
      FieldMessage("payload", payload),
    ])
    Rejected(topic_id:, reason:) -> #("rejected", [
      FieldString("topic_id", topic_id),
      FieldString("reason", reason),
    ])
    Resync(cursors:) -> #("resync", [FieldTargetList("cursors", cursors)])
    SessionMessage(payload:) -> #("session_message", [
      FieldMessage("payload", payload),
    ])
    SessionUpdate(sequence:, payload:) -> #("session_update", [
      FieldInt("sequence", sequence),
      FieldMessage("payload", payload),
    ])
    Snapshot(target:, sequence:, state:) -> #("snapshot", [
      FieldTarget("target", target),
      FieldInt("sequence", sequence),
      FieldState("state", state),
    ])
    Subscribe(topic_id:) -> #("subscribe", [FieldString("topic_id", topic_id)])
    TopicMessage(topic_id:, payload:) -> #("topic_message", [
      FieldString("topic_id", topic_id),
      FieldMessage("payload", payload),
    ])
    TopicUpdate(topic_id:, sequence:, payload:) -> #("topic_update", [
      FieldString("topic_id", topic_id),
      FieldInt("sequence", sequence),
      FieldMessage("payload", payload),
    ])
    Unsubscribe(topic_id:) -> #("unsubscribe", [
      FieldString("topic_id", topic_id),
    ])
    Version(hash:) -> #("version", [FieldString("hash", hash)])
  }
}

fn push_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use payload <- decode.field("payload", decode_message)
  decode.success(Push(topic_id:, payload:))
}

fn rejected_decoder() -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(Rejected(topic_id:, reason:))
}

fn resync_decoder() -> decode.Decoder(Protocol(model, message)) {
  use cursors <- decode.field("cursors", decode.list(target_decoder()))
  decode.success(Resync(cursors:))
}

fn session_message_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use payload <- decode.field("payload", decode_message)
  decode.success(SessionMessage(payload:))
}

fn session_update_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", decode_message)
  decode.success(SessionUpdate(sequence:, payload:))
}

fn snapshot_decoder(
  decode_model: decode.Decoder(model),
) -> decode.Decoder(Protocol(model, message)) {
  use target <- decode.field("target", target_decoder())
  use sequence <- decode.field("sequence", decode.int)
  use state <- decode.field("state", decode_model)
  decode.success(Snapshot(target:, sequence:, state:))
}

fn subscribe_decoder() -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  decode.success(Subscribe(topic_id:))
}

fn target_decoder() -> decode.Decoder(Target) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "session" -> decode.success(Session)
    "topic" -> {
      use id <- decode.field("id", decode.string)
      decode.success(Topic(id:))
    }
    _ -> decode.failure(Session, "Target")
  }
}

fn topic_message_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use payload <- decode.field("payload", decode_message)
  decode.success(TopicMessage(topic_id:, payload:))
}

fn topic_update_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", decode_message)
  decode.success(TopicUpdate(topic_id:, sequence:, payload:))
}

fn unsubscribe_decoder() -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  decode.success(Unsubscribe(topic_id:))
}

fn value_array(value: Value) -> Result(List(Value), Nil) {
  case value {
    ValueArray(items) -> Ok(items)
    _ -> Error(Nil)
  }
}

fn value_bytes(value: Value) -> Result(BitArray, Nil) {
  case value {
    ValueBytes(b) -> Ok(b)
    _ -> Error(Nil)
  }
}

fn value_int(value: Value) -> Result(Int, Nil) {
  case value {
    ValueInteger(n) -> Ok(n)
    _ -> Error(Nil)
  }
}

fn value_string(value: Value) -> Result(String, Nil) {
  case value {
    ValueString(s) -> Ok(s)
    _ -> Error(Nil)
  }
}

fn version_decoder() -> decode.Decoder(Protocol(model, message)) {
  use hash <- decode.field("hash", decode.string)
  decode.success(Version(hash:))
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "transportClose")
fn ffi_http_close(_handle: HttpHandle) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "httpConnect")
fn ffi_http_connect(
  _post_url: String,
  _events_url: String,
  _flush_batch_size: Int,
  _handler: Handler,
) -> HttpHandle {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "transportSend")
fn ffi_http_send(_handle: HttpHandle, _bytes: BitArray) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "transportClose")
fn ffi_ws_close(_handle: WsHandle) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "wsConnect")
fn ffi_ws_connect(
  _url: String,
  _reconnect_base_ms: Int,
  _reconnect_max_ms: Int,
  _reconnect_jitter_ratio: Float,
  _reconnect_multiplier: Float,
  _handler: Handler,
) -> WsHandle {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "transportSend")
fn ffi_ws_send(_handle: WsHandle, _bytes: BitArray) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "wsUrlFromCurrentLocation")
fn ffi_ws_url_from_current_location(_path: String) -> String {
  panic as "JavaScript only"
}
