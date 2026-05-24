//// Transport between client and server. The
//// [`Store`](./store.html#Store) on each side stays in sync by exchanging
//// serialised [`Protocol`](#Protocol) messages over this module. It works
//// on both Erlang and JS targets since both ends need it; the WebSocket
//// and HTTP/SSE connectors are JavaScript-only (a dedicated web server
//// handles the corresponding server-side I/O).
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
//// suit most cases; switch to HTTP if corporate firewalls block them:
////
//// ```gleam
//// import lily/client
//// import lily/transport
////
//// pub fn main() {
////   let runtime = client.start(app_store, shared.wiring())
////
////   client.connect(runtime,
////     with: transport.websocket(url: "ws://localhost:8080/ws")
////       |> transport.reconnect_base_milliseconds(1000)
////       |> transport.websocket_connect,
////     serialiser: transport.automatic(),
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
////   serialiser: transport.automatic(),
//// )
//// ```
////
//// `automatic()` defaults to JSON so frames are human-readable in DevTools.
//// You can use MessagePack for production (for smaller transport packages)
//// with [`transport.use_message_pack`](#use_message_pack):
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
//// shim that calls `registerModule` from `transport.ffi.mjs`:
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
import lily/internal/auto_codec
import lily/internal/message_pack.{
  type Value, ValueArray, ValueBytes, ValueInteger, ValueMap, ValueString,
}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Opaque transport connector. Built by
/// [`websocket_connect`](#websocket_connect) and
/// [`http_connect`](#http_connect); passed to
/// [`client.connect`](./client.html#connect).
pub opaque type Connector {
  Connector(connect: fn(Handler) -> Transport)
}

/// Callbacks the runtime provides to the transport. The transport calls
/// `on_receive` when a message arrives from the server, `on_reconnect` when
/// the connection is established or restored, and `on_disconnect` when the
/// connection is lost.
@internal
pub type Handler {
  Handler(
    on_receive: fn(BitArray) -> Nil,
    on_reconnect: fn() -> Nil,
    on_disconnect: fn() -> Nil,
  )
}

/// `Target` identifies which store a frame applies to: the per-connection
/// session store, or a named shared topic store.
@internal
pub type Target {
  Session
  Topic(id: String)
}

/// Wire-format envelope used between client and server. Sequence numbers
/// are assigned by the server and tracked separately per [`Target`](#Target),
/// so each store stays in sync independently.
@internal
pub type Protocol(model, message) {
  /// Sent by the server after applying a `SessionMessage` or `TopicMessage`
  /// and assigning it a sequence number for the relevant target. Also used
  /// to confirm `Unsubscribe`.
  Acknowledge(target: Target, sequence: Int)

  /// Sent by the server immediately after a client connects, carrying the
  /// server-assigned `client_id`. Use
  /// [`client.client_id`](./client.html#client_id) to inject it into your
  /// model so every session carries its authoritative identity.
  Connected(client_id: String)

  /// Sent by the server directly to subscribers of a topic. Carries no
  /// sequence number and is never replayed on resync. Ephemeral by design.
  Push(topic_id: String, payload: message)

  /// Sent by the server when a `Subscribe` is denied: missing topic or
  /// kind, invalid topic id, or `can_subscribe` returned `False`.
  Rejected(topic_id: String, reason: String)

  /// Sent by the client to request the current state of every known target
  /// after a full reconnect. The server responds with a `Snapshot` per
  /// target regardless of how far behind the client is, so the wire form
  /// is just the list of targets the client wants resynced.
  Resync(cursors: List(Target))

  /// Carries an update from the client to be applied to the session store
  /// of the originating connection.
  SessionMessage(payload: message)

  /// Carries an applied session-store update from the server to a single
  /// targeted client, sent by [`server.dispatch_to`](./server.html#dispatch_to)
  /// or [`server.dispatch_to_all`](./server.html#dispatch_to_all).
  /// Sequence is the client's session sequence after applying.
  SessionUpdate(sequence: Int, payload: message)

  /// Sent by the server in response to `Resync` (per target) and to a
  /// `Subscribe` (for the subscribed topic).
  Snapshot(target: Target, sequence: Int, state: model)

  /// Sent by the client to join a topic. The server replies with
  /// `Snapshot(Topic(id), ...)` on success or `Rejected(id, reason)` on
  /// failure.
  Subscribe(topic_id: String)

  /// Carries an update from the client to be applied to a shared topic
  /// store. The server fans out the result as `TopicUpdate` to every other
  /// subscriber and `Acknowledge` to the originator.
  TopicMessage(topic_id: String, payload: message)

  /// Carries an applied topic-store update from the server to every
  /// subscriber other than the originator. Sequence is the topic's
  /// sequence after applying.
  TopicUpdate(topic_id: String, sequence: Int, payload: message)

  /// Sent by the client to leave a topic. The server replies with
  /// `Acknowledge(Topic(id), seq)` to confirm.
  Unsubscribe(topic_id: String)
}

/// Serialises and deserialises `Protocol` values to and from bytes. The
/// `Auto` variant uses positional encoding and works for any Gleam custom
/// type without configuration; its `format` field selects JSON or MessagePack
/// at runtime. `CustomJson` and `CustomBinary` carry user-supplied codecs and
/// have a fixed format.
///
/// Construct via [`automatic`](#automatic), [`custom_json`](#custom_json), or
/// [`custom_binary`](#custom_binary). Toggle the auto format using
/// [`use_json`](#use_json) and [`use_message_pack`](#use_message_pack); these
/// are no-ops on custom serialisers.
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

/// Transport handle returned by a [`Connector`](#Connector). Carries `send`
/// to transmit bytes and `close` to terminate the connection. Constructed
/// inside the transport module by [`websocket_connect`](#websocket_connect)
/// and [`http_connect`](#http_connect); not user-facing.
@internal
pub opaque type Transport {
  Transport(send: fn(BitArray) -> Nil, close: fn() -> Nil)
}

@target(javascript)
/// Configuration for a WebSocket connection. Use the builder functions to
/// customise reconnection behaviour.
pub opaque type WebSocketConfig {
  WebSocketConfig(
    url: String,
    reconnect_base_milliseconds: Int,
    reconnect_max_milliseconds: Int,
    reconnect_jitter_ratio: Float,
    reconnect_multiplier: Float,
  )
}

@target(javascript)
/// Configuration for an HTTP/SSE connection. Requires both a POST URL for
/// client-to-server messages and an SSE events URL for server-to-client.
pub opaque type HttpConfig {
  HttpConfig(post_url: String, events_url: String, flush_batch_size: Int)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

/// Format selector for the [`Auto`](#Serialiser) variant of
/// [`Serialiser`](#Serialiser). Toggled by [`use_json`](#use_json) and
/// [`use_message_pack`](#use_message_pack).
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
  )
}

@target(javascript)
type HttpHandle

@target(javascript)
type WsHandle

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create an automatic serialiser. Uses JSON by default (human-readable in
/// DevTools). Positional encoding works for any Gleam custom type on both
/// targets without configuration.
///
/// Switch to MessagePack for production (smaller, faster binary frames)
/// with [`transport.use_message_pack`](#use_message_pack):
///
/// ```gleam
/// // Development: JSON, readable in DevTools
/// transport.automatic()
///
/// // Production: MessagePack
/// transport.automatic() |> transport.use_message_pack()
/// ```
///
/// On JavaScript, constructors must be registered before connecting so the
/// decoder can reconstruct all types, including those that only arrive from
/// the server or from other clients. The recommended pattern is a FFI shim in
/// your shared types module that calls `registerModule` from
/// `transport.ffi.mjs`. Multiple modules are supported by calling
/// `registerModule` once per file. See the module documentation for the
/// full pattern.
///
/// ## Supported value shapes
///
/// The auto-serialiser handles every Gleam value the model and message
/// types are likely to contain:
///
/// - **Primitives:** `Int`, `Float`, `String`, `Bool`, `Nil`.
/// - **Custom types:** records and variants, encoded as a tagged map
///   whose `_` field carries the PascalCase constructor name.
/// - **Lists:** encoded as arrays.
/// - **Tuples:** `#(a, b)` encoded as tag-less maps with positional
///   keys (`{"0":a,"1":b}`), distinguishable from CustomTypes by the
///   absence of `_`.
/// - **`gleam/dict.Dict`:** encoded as `{"_":"$dict","0":[[k,v],...]}`.
/// - **`gleam/set.Set`:** encoded as `{"_":"$set","0":[v,...]}`.
///
/// ## Not supported: `BitArray`
///
/// `BitArray` fields in synced types are not auto-encoded. The Erlang
/// runtime represents both `String` and `BitArray` as native binaries,
/// so the reflection layer cannot distinguish them at runtime: a byte
/// sequence like `<<104,101,108,108,111>>` is simultaneously a valid
/// `String` and a valid `BitArray`. Encoding the wrong type would
/// silently corrupt data.
///
/// If your model needs raw bytes, wrap them in a marker CustomType and
/// encode them yourself with [`custom_binary`](#custom_binary) or
/// [`custom_json`](#custom_json):
///
/// ```gleam
/// pub type Bytes {
///   Bytes(data: BitArray)
/// }
/// ```
///
/// Then provide custom encode/decode functions that base64-encode the
/// inner field.
pub fn automatic() -> Serialiser(model, message) {
  Auto(
    format: AutoJson,
    codec: BinaryCodec(
      encode_message: ffi_auto_encode_message_pack,
      decode_message: ffi_auto_decode_message_pack,
      encode_model: ffi_auto_encode_message_pack,
      decode_model: ffi_auto_decode_message_pack,
    ),
  )
}

/// Close the transport connection. After calling this, the transport should
/// clean up resources and stop attempting to reconnect.
@internal
pub fn close(transport: Transport) -> Nil {
  transport.close()
}

/// Create a serialiser from explicit binary encode/decode functions. Use
/// this to provide a custom binary codec (MessagePack, CBOR, or any binary
/// format). The format is fixed to binary; the [`use_json`](#use_json) and
/// [`use_message_pack`](#use_message_pack) toggles are no-ops on this
/// serialiser.
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
  ))
}

/// Create a serialiser from explicit JSON encode/decode functions. Useful
/// when the auto format is not suitable (third-party APIs, human-readable
/// JSON, backwards compatibility). The format is fixed to JSON; the
/// [`use_json`](#use_json) and [`use_message_pack`](#use_message_pack)
/// toggles are no-ops on this serialiser.
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

/// Encodes a `Protocol` into bytes. Uses MessagePack when a binary codec is
/// active (the default for [`automatic`](#automatic)), or JSON otherwise.
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

/// Encode a model as an inline hydration payload to embed inside
/// server-rendered HTML. Returns
/// `<script type="application/json" id="lily-snapshot">...</script>` with
/// a JSON-encoded `Snapshot(Session, 0, model)` frame inside.
/// [`client.hydrate`](./client.html#hydrate) reads this on mount and uses
/// the embedded model as the initial state, avoiding a round-trip on
/// first paint.
///
/// Always uses JSON regardless of the serialiser's `automatic` format
/// toggle, since binary MessagePack is not safe to inline inside HTML.
/// `CustomBinary` serialisers will produce a snapshot whose payload is a
/// base16-encoded representation of the binary bytes; prefer `automatic`
/// or `custom_json` for SSR.
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
pub fn encode_initial_snapshot(
  serialiser serialiser: Serialiser(model, message),
  model model: model,
) -> String {
  let frame = Snapshot(target: Session, sequence: 0, state: model)
  // Force JSON for the inline payload; MessagePack is binary and not
  // HTML-safe. `CustomJson` is already JSON, and `Auto` flips to JSON
  // regardless of its current format toggle. `CustomBinary` users keep
  // their binary codec and accept that the embedded bytes may not be
  // HTML-safe (documented in the function docstring).
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
/// Set the maximum number of queued messages POSTed in parallel when the
/// HTTP/SSE connection reconnects. Reducing this limits concurrent POST
/// requests during a reconnect burst; increasing it flushes the queue faster.
/// Default is 10.
pub fn flush_batch_size(config: HttpConfig, size: Int) -> HttpConfig {
  HttpConfig(..config, flush_batch_size: size)
}

@target(javascript)
/// Create a new HTTP/SSE transport configuration. The `post_url` is used for
/// sending messages to the server, and the `events_url` is used for receiving
/// Server-Sent Events.
///
/// ## Example
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
/// Returns a connector function that establishes an HTTP/SSE connection. Pass
/// the result to `client.connect`.
///
/// ## Example
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

/// Create a new [`Transport`](#Transport) with the given send and close
/// functions. Used by transport implementations (WebSocket, HTTP) to
/// construct the Transport handle they return from their connector.
@internal
pub fn new(
  send send: fn(BitArray) -> Nil,
  close close: fn() -> Nil,
) -> Transport {
  Transport(send:, close:)
}

/// Wrap a `connect` function as a [`Connector`](#Connector). Used by
/// [`websocket_connect`](#websocket_connect), [`http_connect`](#http_connect),
/// and tests that fake the transport.
@internal
pub fn make_connector(connect: fn(Handler) -> Transport) -> Connector {
  Connector(connect:)
}

/// Run a connector by passing it the runtime's handler. Used by
/// [`client.connect`](./client.html#connect).
@internal
pub fn run_connector(connector: Connector, handler: Handler) -> Transport {
  connector.connect(handler)
}

@target(javascript)
/// Set the base delay in milliseconds for WebSocket reconnection attempts. The
/// actual delay doubles on each failed attempt until reaching the maximum.
pub fn reconnect_base_milliseconds(
  config: WebSocketConfig,
  milliseconds: Int,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_base_milliseconds: milliseconds)
}

@target(javascript)
/// Set the jitter ratio applied to each WebSocket reconnection delay. A ratio
/// of `0.25` produces ±25% randomisation, which spreads reconnects across
/// clients after a mass disconnect so the server doesn't get stampeded. Must
/// be between 0.0 (no jitter) and 1.0 (full randomisation). Default is 0.25.
pub fn reconnect_jitter_ratio(
  config: WebSocketConfig,
  ratio: Float,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_jitter_ratio: ratio)
}

@target(javascript)
/// Set the maximum delay in milliseconds between WebSocket reconnection
/// attempts.
pub fn reconnect_max_milliseconds(
  config: WebSocketConfig,
  milliseconds: Int,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_max_milliseconds: milliseconds)
}

@target(javascript)
/// Set the backoff multiplier for WebSocket reconnection attempts. The delay
/// after each failed attempt is multiplied by this value, up to the maximum
/// set by [`reconnect_max_milliseconds`](#reconnect_max_milliseconds). Default
/// is 2.0 (standard exponential backoff).
pub fn reconnect_multiplier(
  config: WebSocketConfig,
  multiplier: Float,
) -> WebSocketConfig {
  WebSocketConfig(..config, reconnect_multiplier: multiplier)
}

/// Send bytes through the transport. The bytes should be a serialised
/// [`Protocol`](#Protocol) message.
@internal
pub fn send(transport: Transport, bytes: BitArray) -> Nil {
  transport.send(bytes)
}

/// Switch the serialiser to JSON encoding. Useful for development when you
/// want human-readable frames in DevTools. Only meaningful on
/// [`automatic`](#automatic) serialisers; no-op on `custom_json` or
/// `custom_binary`.
///
/// ```gleam
/// // Dev: readable JSON in DevTools
/// transport.automatic() |> transport.use_json()
/// ```
pub fn use_json(
  serialiser: Serialiser(model, message),
) -> Serialiser(model, message) {
  case serialiser {
    Auto(format: AutoMessagePack, codec:) -> Auto(format: AutoJson, codec:)
    Auto(..) | CustomJson(..) | CustomBinary(..) -> serialiser
  }
}

/// Switch the serialiser back to MessagePack encoding after
/// [`use_json`](#use_json) was called. Only meaningful on
/// [`automatic`](#automatic) serialisers; no-op on `custom_json` or
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
/// Derive a WebSocket URL from the browser's current location. Automatically
/// uses `wss:` for HTTPS pages and `ws:` for HTTP. The `path` argument
/// specifies the WebSocket endpoint path.
///
/// ```gleam
/// // On https://example.com:3000/app
/// transport.url_from_current_location(path: "/ws")
/// // Returns "wss://example.com:3000/ws"
/// ```
pub fn url_from_current_location(path path: String) -> String {
  ffi_ws_url_from_current_location(path)
}

@target(javascript)
/// Create a new WebSocket configuration with the given URL. Default reconnect
/// settings are 1000ms base delay and 30000ms maximum delay (exponential
/// backoff).
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
/// Returns a connector function that establishes a WebSocket connection. Pass
/// the result to `client.connect`.
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

/// Decoder for `Acknowledge`
fn acknowledge_decoder() -> decode.Decoder(Protocol(model, message)) {
  use target <- decode.field("target", target_decoder())
  use sequence <- decode.field("sequence", decode.int)
  decode.success(Acknowledge(target:, sequence:))
}

/// Decoder for `Target`
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

fn encode_json(
  protocol: Protocol(model, message),
  encode_message: fn(message) -> Json,
  encode_model: fn(model) -> Json,
) -> BitArray {
  case protocol {
    Acknowledge(target:, sequence:) ->
      json.object([
        #("type", json.string("acknowledge")),
        #("target", encode_target_json(target)),
        #("sequence", json.int(sequence)),
      ])

    Connected(client_id:) ->
      json.object([
        #("type", json.string("connected")),
        #("client_id", json.string(client_id)),
      ])

    Push(topic_id:, payload:) ->
      json.object([
        #("type", json.string("push")),
        #("topic_id", json.string(topic_id)),
        #("payload", encode_message(payload)),
      ])

    Rejected(topic_id:, reason:) ->
      json.object([
        #("type", json.string("rejected")),
        #("topic_id", json.string(topic_id)),
        #("reason", json.string(reason)),
      ])

    Resync(cursors:) ->
      json.object([
        #("type", json.string("resync")),
        #("cursors", json.array(cursors, encode_target_json)),
      ])

    SessionMessage(payload:) ->
      json.object([
        #("type", json.string("session_message")),
        #("payload", encode_message(payload)),
      ])

    SessionUpdate(sequence:, payload:) ->
      json.object([
        #("type", json.string("session_update")),
        #("sequence", json.int(sequence)),
        #("payload", encode_message(payload)),
      ])

    Snapshot(target:, sequence:, state:) ->
      json.object([
        #("type", json.string("snapshot")),
        #("target", encode_target_json(target)),
        #("sequence", json.int(sequence)),
        #("state", encode_model(state)),
      ])

    Subscribe(topic_id:) ->
      json.object([
        #("type", json.string("subscribe")),
        #("topic_id", json.string(topic_id)),
      ])

    TopicMessage(topic_id:, payload:) ->
      json.object([
        #("type", json.string("topic_message")),
        #("topic_id", json.string(topic_id)),
        #("payload", encode_message(payload)),
      ])

    TopicUpdate(topic_id:, sequence:, payload:) ->
      json.object([
        #("type", json.string("topic_update")),
        #("topic_id", json.string(topic_id)),
        #("sequence", json.int(sequence)),
        #("payload", encode_message(payload)),
      ])

    Unsubscribe(topic_id:) ->
      json.object([
        #("type", json.string("unsubscribe")),
        #("topic_id", json.string(topic_id)),
      ])
  }
  |> json.to_string
  |> bit_array.from_string
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

/// Decoder for `Protocol`
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
    _ -> decode.failure(Acknowledge(Session, 0), "Protocol")
  }
}

/// Decoder for `Connected`
fn connected_decoder() -> decode.Decoder(Protocol(model, message)) {
  use client_id <- decode.field("client_id", decode.string)
  decode.success(Connected(client_id:))
}

/// Decoder for `Push`
fn push_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use payload <- decode.field("payload", decode_message)
  decode.success(Push(topic_id:, payload:))
}

/// Decoder for `Rejected`
fn rejected_decoder() -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(Rejected(topic_id:, reason:))
}

/// Decoder for `Resync`
fn resync_decoder() -> decode.Decoder(Protocol(model, message)) {
  use cursors <- decode.field("cursors", decode.list(target_decoder()))
  decode.success(Resync(cursors:))
}

/// Decoder for `SessionMessage`
fn session_message_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use payload <- decode.field("payload", decode_message)
  decode.success(SessionMessage(payload:))
}

/// Decoder for `SessionUpdate`
fn session_update_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", decode_message)
  decode.success(SessionUpdate(sequence:, payload:))
}

/// Decoder for `Snapshot`
fn snapshot_decoder(
  decode_model: decode.Decoder(model),
) -> decode.Decoder(Protocol(model, message)) {
  use target <- decode.field("target", target_decoder())
  use sequence <- decode.field("sequence", decode.int)
  use state <- decode.field("state", decode_model)
  decode.success(Snapshot(target:, sequence:, state:))
}

/// Decoder for `Subscribe`
fn subscribe_decoder() -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  decode.success(Subscribe(topic_id:))
}

/// Decoder for `TopicMessage`
fn topic_message_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use payload <- decode.field("payload", decode_message)
  decode.success(TopicMessage(topic_id:, payload:))
}

/// Decoder for `TopicUpdate`
fn topic_update_decoder(
  decode_message: decode.Decoder(message),
) -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", decode_message)
  decode.success(TopicUpdate(topic_id:, sequence:, payload:))
}

/// Decoder for `Unsubscribe`
fn unsubscribe_decoder() -> decode.Decoder(Protocol(model, message)) {
  use topic_id <- decode.field("topic_id", decode.string)
  decode.success(Unsubscribe(topic_id:))
}

fn ffi_auto_encode_message_pack(value: a) -> BitArray {
  auto_codec.encode_message_pack(value)
}

fn ffi_auto_decode_message_pack(bytes: BitArray) -> Result(a, Nil) {
  case auto_codec.decode_message_pack(bytes) {
    Ok(value) -> Ok(unsafe_coerce_dynamic(value))
    Error(_) -> Error(Nil)
  }
}

/// Bridge `Dynamic` back into the call site's expected type. Pure FFI
/// passthrough: Erlang and JS values do not carry static types at runtime,
/// so reinterpreting `Dynamic` as `a` is sound here. The value was just
/// reconstructed by `reflection.construct` and matches the shape of `a` by
/// construction.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./internal/reflection.ffi.mjs", "passthrough")
fn unsafe_coerce_dynamic(_value: Dynamic) -> a

/// Encode a Protocol value to MessagePack bytes. Pure Gleam, single source
/// of truth for both targets. The payload/state slots embed bytes produced
/// by the configured codec (auto or user-supplied).
fn encode_message_pack_protocol(
  protocol: Protocol(model, message),
  codec: BinaryCodec(model, message),
) -> BitArray {
  let str = message_pack.encode_string
  let bin = message_pack.encode_bin
  let int_bytes = message_pack.encode_int
  case protocol {
    Acknowledge(target:, sequence:) ->
      message_pack.encode_map([
        #(str("type"), str("acknowledge")),
        #(str("target"), encode_target_message_pack(target)),
        #(str("sequence"), int_bytes(sequence)),
      ])

    Connected(client_id:) ->
      message_pack.encode_map([
        #(str("type"), str("connected")),
        #(str("client_id"), str(client_id)),
      ])

    Push(topic_id:, payload:) ->
      message_pack.encode_map([
        #(str("type"), str("push")),
        #(str("topic_id"), str(topic_id)),
        #(str("payload"), bin(codec.encode_message(payload))),
      ])

    Rejected(topic_id:, reason:) ->
      message_pack.encode_map([
        #(str("type"), str("rejected")),
        #(str("topic_id"), str(topic_id)),
        #(str("reason"), str(reason)),
      ])

    Resync(cursors:) ->
      message_pack.encode_map([
        #(str("type"), str("resync")),
        #(
          str("cursors"),
          message_pack.encode_array(list.map(
            cursors,
            encode_target_message_pack,
          )),
        ),
      ])

    SessionMessage(payload:) ->
      message_pack.encode_map([
        #(str("type"), str("session_message")),
        #(str("payload"), bin(codec.encode_message(payload))),
      ])

    SessionUpdate(sequence:, payload:) ->
      message_pack.encode_map([
        #(str("type"), str("session_update")),
        #(str("sequence"), int_bytes(sequence)),
        #(str("payload"), bin(codec.encode_message(payload))),
      ])

    Snapshot(target:, sequence:, state:) ->
      message_pack.encode_map([
        #(str("type"), str("snapshot")),
        #(str("target"), encode_target_message_pack(target)),
        #(str("sequence"), int_bytes(sequence)),
        #(str("state"), bin(codec.encode_model(state))),
      ])

    Subscribe(topic_id:) ->
      message_pack.encode_map([
        #(str("type"), str("subscribe")),
        #(str("topic_id"), str(topic_id)),
      ])

    TopicMessage(topic_id:, payload:) ->
      message_pack.encode_map([
        #(str("type"), str("topic_message")),
        #(str("topic_id"), str(topic_id)),
        #(str("payload"), bin(codec.encode_message(payload))),
      ])

    TopicUpdate(topic_id:, sequence:, payload:) ->
      message_pack.encode_map([
        #(str("type"), str("topic_update")),
        #(str("topic_id"), str(topic_id)),
        #(str("sequence"), int_bytes(sequence)),
        #(str("payload"), bin(codec.encode_message(payload))),
      ])

    Unsubscribe(topic_id:) ->
      message_pack.encode_map([
        #(str("type"), str("unsubscribe")),
        #(str("topic_id"), str(topic_id)),
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

/// Decode MessagePack-encoded bytes back to a Protocol using the provided
/// codec for payload/state values.
fn decode_message_pack_protocol(
  bytes: BitArray,
  codec: BinaryCodec(model, message),
) -> Result(Protocol(model, message), Nil) {
  use #(top_value, _) <- result.try(message_pack.decode(bytes))
  case top_value {
    ValueMap(entries) -> decode_message_pack_envelope(entries, codec)
    _ -> Error(Nil)
  }
}

fn decode_message_pack_envelope(
  entries: List(#(Value, Value)),
  codec: BinaryCodec(model, message),
) -> Result(Protocol(model, message), Nil) {
  use type_value <- result.try(envelope_get(entries, "type"))
  use type_name <- result.try(value_string(type_value))
  case type_name {
    "acknowledge" -> {
      use target_value <- result.try(envelope_get(entries, "target"))
      use target <- result.try(decode_target_message_pack(target_value))
      use sequence_value <- result.try(envelope_get(entries, "sequence"))
      use sequence <- result.try(value_int(sequence_value))
      Ok(Acknowledge(target:, sequence:))
    }

    "connected" -> {
      use client_id_value <- result.try(envelope_get(entries, "client_id"))
      use client_id <- result.try(value_string(client_id_value))
      Ok(Connected(client_id:))
    }

    "push" -> {
      use topic_id_value <- result.try(envelope_get(entries, "topic_id"))
      use topic_id <- result.try(value_string(topic_id_value))
      use payload_value <- result.try(envelope_get(entries, "payload"))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(Push(topic_id:, payload:))
    }

    "rejected" -> {
      use topic_id_value <- result.try(envelope_get(entries, "topic_id"))
      use topic_id <- result.try(value_string(topic_id_value))
      use reason_value <- result.try(envelope_get(entries, "reason"))
      use reason <- result.try(value_string(reason_value))
      Ok(Rejected(topic_id:, reason:))
    }

    "resync" -> {
      use cursors_value <- result.try(envelope_get(entries, "cursors"))
      use cursors <- result.try(value_array(cursors_value))
      use targets <- result.try(list.try_map(
        cursors,
        decode_target_message_pack,
      ))
      Ok(Resync(cursors: targets))
    }

    "session_message" -> {
      use payload_value <- result.try(envelope_get(entries, "payload"))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(SessionMessage(payload:))
    }

    "session_update" -> {
      use sequence_value <- result.try(envelope_get(entries, "sequence"))
      use sequence <- result.try(value_int(sequence_value))
      use payload_value <- result.try(envelope_get(entries, "payload"))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(SessionUpdate(sequence:, payload:))
    }

    "snapshot" -> {
      use target_value <- result.try(envelope_get(entries, "target"))
      use target <- result.try(decode_target_message_pack(target_value))
      use sequence_value <- result.try(envelope_get(entries, "sequence"))
      use sequence <- result.try(value_int(sequence_value))
      use state_value <- result.try(envelope_get(entries, "state"))
      use state_bytes <- result.try(value_bytes(state_value))
      use state <- result.try(codec.decode_model(state_bytes))
      Ok(Snapshot(target:, sequence:, state:))
    }

    "subscribe" -> {
      use topic_id_value <- result.try(envelope_get(entries, "topic_id"))
      use topic_id <- result.try(value_string(topic_id_value))
      Ok(Subscribe(topic_id:))
    }

    "topic_message" -> {
      use topic_id_value <- result.try(envelope_get(entries, "topic_id"))
      use topic_id <- result.try(value_string(topic_id_value))
      use payload_value <- result.try(envelope_get(entries, "payload"))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(TopicMessage(topic_id:, payload:))
    }

    "topic_update" -> {
      use topic_id_value <- result.try(envelope_get(entries, "topic_id"))
      use topic_id <- result.try(value_string(topic_id_value))
      use sequence_value <- result.try(envelope_get(entries, "sequence"))
      use sequence <- result.try(value_int(sequence_value))
      use payload_value <- result.try(envelope_get(entries, "payload"))
      use payload_bytes <- result.try(value_bytes(payload_value))
      use payload <- result.try(codec.decode_message(payload_bytes))
      Ok(TopicUpdate(topic_id:, sequence:, payload:))
    }

    "unsubscribe" -> {
      use topic_id_value <- result.try(envelope_get(entries, "topic_id"))
      use topic_id <- result.try(value_string(topic_id_value))
      Ok(Unsubscribe(topic_id:))
    }

    _ -> Error(Nil)
  }
}

fn decode_target_message_pack(value: Value) -> Result(Target, Nil) {
  case value {
    ValueMap(entries) -> {
      use kind_value <- result.try(envelope_get(entries, "kind"))
      use kind <- result.try(value_string(kind_value))
      case kind {
        "session" -> Ok(Session)
        "topic" -> {
          use id_value <- result.try(envelope_get(entries, "id"))
          use id <- result.try(value_string(id_value))
          Ok(Topic(id:))
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn envelope_get(
  entries: List(#(Value, Value)),
  key: String,
) -> Result(Value, Nil) {
  case entries {
    [] -> Error(Nil)
    [#(ValueString(k), v), ..] if k == key -> Ok(v)
    [_, ..rest] -> envelope_get(rest, key)
  }
}

fn value_string(value: Value) -> Result(String, Nil) {
  case value {
    ValueString(s) -> Ok(s)
    _ -> Error(Nil)
  }
}

fn value_int(value: Value) -> Result(Int, Nil) {
  case value {
    ValueInteger(n) -> Ok(n)
    _ -> Error(Nil)
  }
}

fn value_bytes(value: Value) -> Result(BitArray, Nil) {
  case value {
    ValueBytes(b) -> Ok(b)
    _ -> Error(Nil)
  }
}

fn value_array(value: Value) -> Result(List(Value), Nil) {
  case value {
    ValueArray(items) -> Ok(items)
    _ -> Error(Nil)
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

/// Auto-decode a dynamic value (JSON path)
@external(erlang, "lily_transport_ffi", "auto_decode")
@external(javascript, "./transport.ffi.mjs", "autoDecode")
fn ffi_auto_decode(_value: Dynamic) -> Result(a, a) {
  panic as "auto_decode is implemented in FFI"
}

/// Auto-encode a value to JSON (JSON path)
@external(erlang, "lily_transport_ffi", "auto_encode")
@external(javascript, "./transport.ffi.mjs", "autoEncode")
fn ffi_auto_encode(_value: a) -> Json {
  panic as "auto_encode is implemented in FFI"
}

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
