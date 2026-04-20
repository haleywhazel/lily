//// The transport module handles client-server communication, serialisation,
//// and the two built-in transport implementations. It works on both Erlang
//// and JavaScript. The WebSocket and HTTP/SSE transports are JavaScript-only
//// and use `@target(javascript)`.
////
//// This module provides:
////
//// - **Wire format** — [`Protocol`](#Protocol) envelope types for
////   client-server messages
//// - **Serialisation** — [`Serialiser`](#Serialiser) with automatic
////   ([`automatic`](#automatic)) and custom ([`custom_json`](#custom_json),
////   [`custom_binary`](#custom_binary)) options
//// - **WebSocket transport** — [`websocket`](#websocket) config builder and
////   [`websocket_connect`](#websocket_connect) connector with automatic
////   reconnection and offline queueing
//// - **HTTP/SSE transport** — [`http`](#http) config builder and
////   [`http_connect`](#http_connect) connector using EventSource + POST
////
//// For most apps, use [`transport.automatic`](#automatic) for
//// zero-configuration serialisation, then pick a transport:
////
//// ```gleam
//// import lily/client
//// import lily/transport
////
//// pub fn main() {
////   let runtime = client.start(app_store)
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
//// Use [`transport.use_json`](#use_json) for human-readable frames during
//// development:
////
//// ```gleam
//// transport.automatic() |> transport.use_json()
//// ```
////
//// The automatic serialiser uses positional encoding:
//// `{"_":"ConstructorName","0":field0,"1":field1,...}`. On JavaScript,
//// constructors are discovered from message sends and the initial model. For
//// server-only message types, use [`transport.register`](#register).
////
//// For cases where automatic serialisation isn't suitable, use
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
import gleam/option.{type Option}
import gleam/result

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// A connector is any function that, given Lily's [`Handler`](#Handler)
/// callbacks, returns a Transport. Users provide a connector to
/// [`client.connect`](./client.html#connect) to establish the server
/// connection using their chosen transport (WebSocket, HTTP, etc.).
pub type Connector =
  fn(Handler) -> Transport

/// Callbacks the runtime provides to the transport. The transport calls
/// `on_receive` when a message arrives from the server, `on_reconnect` when
/// the connection is established or restored, and `on_disconnect` when the
/// connection is lost.
pub type Handler {
  Handler(
    on_receive: fn(BitArray) -> Nil,
    on_reconnect: fn() -> Nil,
    on_disconnect: fn() -> Nil,
  )
}

/// Lily's `Protocol` takes the sequence of messages taken into account when
/// receiving updates to ensure proper syncing between stores and updating
/// their sequence numbers. Sequence numbers are assigned by the server.
pub type Protocol(model, message) {
  /// `Acknowledge` is sent by the server on the reception of a `ClientMessage`
  ///  and after it assigns a sequence number to the received message.
  Acknowledge(sequence: Int)

  /// `ClientMessage` carries any updates made by the client.
  ClientMessage(payload: message)

  /// `Resync` is used by the client to request the current model within the
  /// the server store after a full reconnect. The `after_sequence` number
  /// attached allows the server to know the last synced sequence state.
  Resync(after_sequence: Int)

  /// `ServerMessage` carries any updates from the server alongside a sequence
  /// number.
  ServerMessage(sequence: Int, payload: message)

  /// `Snapshot` is sent by the server on the reception of a `Resync` request by
  /// the client.
  Snapshot(sequence: Int, state: model)
}

/// Serialises and deserialises `Protocol` values to and from bytes. Carries
/// both a JSON path (always present, used in development or when no binary
/// codec is set) and an optional binary path (MessagePack or any custom binary
/// codec).
///
/// Construct via [`automatic`](#automatic), [`custom_json`](#custom_json), or
/// [`custom_binary`](#custom_binary). Toggle between formats using
/// [`use_json`](#use_json) and [`use_message_pack`](#use_message_pack).
pub opaque type Serialiser(model, message) {
  Serialiser(
    encode_message: fn(message) -> Json,
    decode_message: decode.Decoder(message),
    encode_model: fn(model) -> Json,
    decode_model: decode.Decoder(model),
    binary: Option(BinaryCodec(model, message)),
    auto_binary: Option(BinaryCodec(model, message)),
  )
}

/// This is transport handle returned by a connector. Provides `send` to
/// transmit messages and `close` to terminate the connection.
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

/// Create an automatic serialiser. Uses MessagePack by default (compact
/// binary). Positional encoding works for any Gleam custom type on both
/// targets without configuration.
///
/// Switch to JSON for development with [`transport.use_json`](#use_json):
///
/// ```gleam
/// // Production: MessagePack
/// transport.automatic()
///
/// // Development: JSON, readable in DevTools
/// transport.automatic() |> transport.use_json()
/// ```
///
/// On JavaScript, constructors are discovered automatically:
/// - Model types: walked recursively from the initial model at start time
/// - Message types: cached on first send
///
/// For message types that only arrive from the server (never sent by this
/// client), call [`transport.register`](#register) before connecting.
pub fn automatic() -> Serialiser(model, message) {
  let auto_binary =
    option.Some(
      BinaryCodec(
        encode_message: ffi_auto_encode_message_pack,
        decode_message: fn(bytes) {
          case ffi_auto_decode_message_pack(bytes) {
            Ok(value) -> Ok(value)
            Error(_) -> Error(Nil)
          }
        },
        encode_model: ffi_auto_encode_message_pack,
        decode_model: fn(bytes) {
          case ffi_auto_decode_message_pack(bytes) {
            Ok(value) -> Ok(value)
            Error(_) -> Error(Nil)
          }
        },
      ),
    )
  Serialiser(
    encode_message: ffi_auto_encode,
    decode_message: decode.new_primitive_decoder("Auto", ffi_auto_decode),
    encode_model: ffi_auto_encode,
    decode_model: decode.new_primitive_decoder("Auto", ffi_auto_decode),
    binary: auto_binary,
    auto_binary: auto_binary,
  )
}

/// Close the transport connection. After calling this, the transport should
/// clean up resources and stop attempting to reconnect.
pub fn close(transport: Transport) -> Nil {
  transport.close()
}

/// Create a serialiser from explicit binary encode/decode functions. Use this
/// to provide a custom binary codec (MessagePack, CBOR, or any binary
/// format). The format is fixed to binary; the [`use_json`](#use_json) and
/// [`use_message_pack`](#use_message_pack) toggles are no-ops on this serialiser.
pub fn custom_binary(
  encode_message encode_message: fn(message) -> BitArray,
  decode_message decode_message: fn(BitArray) -> Result(message, Nil),
  encode_model encode_model: fn(model) -> BitArray,
  decode_model decode_model: fn(BitArray) -> Result(model, Nil),
) -> Serialiser(model, message) {
  Serialiser(
    encode_message: ffi_auto_encode,
    decode_message: decode.new_primitive_decoder("Auto", ffi_auto_decode),
    encode_model: ffi_auto_encode,
    decode_model: decode.new_primitive_decoder("Auto", ffi_auto_decode),
    binary: option.Some(BinaryCodec(
      encode_message: encode_message,
      decode_message: decode_message,
      encode_model: encode_model,
      decode_model: decode_model,
    )),
    auto_binary: option.None,
  )
}

/// Create a serialiser from explicit JSON encode/decode functions. Useful
/// when the auto format is not suitable (third-party APIs, human-readable
/// JSON, backwards compatibility). The format is fixed to JSON; the
/// [`use_json`](#use_json) and [`use_message_pack`](#use_message_pack) toggles are
/// no-ops on this serialiser.
pub fn custom_json(
  encode_message encode_message: fn(message) -> Json,
  decode_message decode_message: decode.Decoder(message),
  encode_model encode_model: fn(model) -> Json,
  decode_model decode_model: decode.Decoder(model),
) -> Serialiser(model, message) {
  Serialiser(
    encode_message: encode_message,
    decode_message: decode_message,
    encode_model: encode_model,
    decode_model: decode_model,
    binary: option.None,
    auto_binary: option.None,
  )
}

/// Decode `BitArray` bytes into a [`Protocol`](#Protocol) result.
pub fn decode(
  bytes: BitArray,
  serialiser serialiser: Serialiser(model, message),
) -> Result(Protocol(model, message), Nil) {
  case serialiser.binary {
    option.None -> decode_json(bytes, serialiser)
    option.Some(codec) -> decode_message_pack(bytes, codec)
  }
}

/// Encodes a `Protocol` into bytes. Uses MessagePack when a binary codec is
/// set (the default for [`automatic`](#automatic)), or JSON otherwise.
pub fn encode(
  protocol: Protocol(model, message),
  serialiser serialiser: Serialiser(model, message),
) -> BitArray {
  case serialiser.binary {
    option.None -> encode_json(protocol, serialiser)
    option.Some(codec) -> encode_message_pack(protocol, codec)
  }
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
  fn(handler: Handler) {
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
  }
}

/// Create a new [`Transport`](#Transport) with the given send and close
/// functions. This is used by transport implementations (WebSocket, HTTP) to
/// construct the Transport handle they return from their connector.
pub fn new(
  send send: fn(BitArray) -> Nil,
  close close: fn() -> Nil,
) -> Transport {
  Transport(send: send, close: close)
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
/// clients after a mass disconnect (thundering-herd mitigation). Must be
/// between 0.0 (no jitter) and 1.0 (full randomisation). Default is 0.25.
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

/// Register constructors for the auto-serialiser's decoder. Only needed on
/// JavaScript for types that arrive from the server but are never sent by the
/// client and don't appear in the initial model.
///
/// Call before `client.connect`. Field values are placeholders — only the
/// constructor shape is extracted.
///
/// No-op on Erlang (constructors are self-describing).
///
/// ## Example
///
/// ```gleam
/// transport.register([AdminKick(""), ServerAnnouncement("")])
/// ```
pub fn register(constructors: List(anything)) -> Nil {
  ffi_register(constructors)
}

/// Send bytes through the transport. The bytes should be a serialised
/// [`Protocol`](#Protocol) message.
pub fn send(transport: Transport, bytes: BitArray) -> Nil {
  transport.send(bytes)
}

/// Switch the serialiser to JSON encoding. Useful for development when you
/// want human-readable frames in DevTools. Only meaningful on
/// [`automatic`](#automatic) serialisers; no-op on `custom_json` or
/// `custom_binary`.
///
/// ## Example
///
/// ```gleam
/// // Dev: readable JSON in DevTools
/// transport.automatic() |> transport.use_json()
/// ```
pub fn use_json(
  serialiser: Serialiser(model, message),
) -> Serialiser(model, message) {
  case serialiser.auto_binary {
    option.None -> serialiser
    option.Some(_) -> Serialiser(..serialiser, binary: option.None)
  }
}

/// Switch the serialiser back to MessagePack encoding after
/// [`use_json`](#use_json) was called. Only meaningful on
/// [`automatic`](#automatic) serialisers; no-op on `custom_json` or
/// `custom_binary`.
pub fn use_message_pack(
  serialiser: Serialiser(model, message),
) -> Serialiser(model, message) {
  Serialiser(..serialiser, binary: serialiser.auto_binary)
}

@target(javascript)
/// Derive a WebSocket URL from the browser's current location. Automatically
/// uses `wss:` for HTTPS pages and `ws:` for HTTP. The `path` argument
/// specifies the WebSocket endpoint path.
///
/// ## Example
///
/// ```gleam
/// // On https://example.com:3000/app
/// transport.url_from_current_location("/ws")
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
/// ## Example
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
  fn(handler: Handler) {
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
  }
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/// Decoder for `Acknowledge`
fn acknowledge_decoder() -> decode.Decoder(Protocol(model, message)) {
  use sequence <- decode.field("sequence", decode.int)
  decode.success(Acknowledge(sequence:))
}

/// Decoder for `ClientMessage`
fn client_message_decoder(
  serialiser: Serialiser(model, message),
) -> decode.Decoder(Protocol(model, message)) {
  use payload <- decode.field("payload", serialiser.decode_message)
  decode.success(ClientMessage(payload:))
}

fn decode_json(
  bytes: BitArray,
  serialiser: Serialiser(model, message),
) -> Result(Protocol(model, message), Nil) {
  let decoder = protocol_decoder(serialiser)
  bit_array.to_string(bytes)
  |> result.try(fn(text) {
    json.parse(from: text, using: decoder)
    |> result.replace_error(Nil)
  })
}

fn decode_message_pack(
  bytes: BitArray,
  codec: BinaryCodec(model, message),
) -> Result(Protocol(model, message), Nil) {
  ffi_decode_message_pack_protocol(bytes, codec)
}

fn encode_json(
  protocol: Protocol(model, message),
  serialiser: Serialiser(model, message),
) -> BitArray {
  case protocol {
    ClientMessage(payload:) ->
      json.object([
        #("type", json.string("client_message")),
        #("payload", serialiser.encode_message(payload)),
      ])

    ServerMessage(sequence:, payload:) ->
      json.object([
        #("type", json.string("server_message")),
        #("sequence", json.int(sequence)),
        #("payload", serialiser.encode_message(payload)),
      ])

    Snapshot(sequence:, state:) ->
      json.object([
        #("type", json.string("snapshot")),
        #("sequence", json.int(sequence)),
        #("state", serialiser.encode_model(state)),
      ])

    Resync(after_sequence:) ->
      json.object([
        #("type", json.string("resync")),
        #("after_sequence", json.int(after_sequence)),
      ])

    Acknowledge(sequence:) ->
      json.object([
        #("type", json.string("acknowledge")),
        #("sequence", json.int(sequence)),
      ])
  }
  |> json.to_string
  |> bit_array.from_string
}

fn encode_message_pack(
  protocol: Protocol(model, message),
  codec: BinaryCodec(model, message),
) -> BitArray {
  ffi_encode_message_pack_protocol(protocol, codec)
}

/// Decoder for `Protocol`
fn protocol_decoder(
  serialiser: Serialiser(model, message),
) -> decode.Decoder(Protocol(model, message)) {
  use protocol_type <- decode.then(decode.at(["type"], decode.string))
  case protocol_type {
    "client_message" -> client_message_decoder(serialiser)
    "server_message" -> server_message_decoder(serialiser)
    "snapshot" -> snapshot_decoder(serialiser)
    "resync" -> resync_decoder()
    "acknowledge" -> acknowledge_decoder()
    _ -> decode.failure(Acknowledge(0), "Protocol")
  }
}

/// Decoder for `Resync`
fn resync_decoder() -> decode.Decoder(Protocol(model, message)) {
  use after_sequence <- decode.field("after_sequence", decode.int)
  decode.success(Resync(after_sequence:))
}

/// Decoder for `ServerMessage`
fn server_message_decoder(
  serialiser: Serialiser(model, message),
) -> decode.Decoder(Protocol(model, message)) {
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", serialiser.decode_message)
  decode.success(ServerMessage(sequence:, payload:))
}

/// Decoder for `Snapshot`
fn snapshot_decoder(
  serialiser: Serialiser(model, message),
) -> decode.Decoder(Protocol(model, message)) {
  use sequence <- decode.field("sequence", decode.int)
  use state <- decode.field("state", serialiser.decode_model)
  decode.success(Snapshot(sequence:, state:))
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

/// Auto-decode MessagePack bytes to a Gleam value
@external(erlang, "lily_transport_ffi", "auto_decode_message_pack")
@external(javascript, "./transport.ffi.mjs", "autoDecodeMessagePack")
fn ffi_auto_decode_message_pack(_bytes: BitArray) -> Result(a, Nil) {
  panic as "auto_decode_message_pack is implemented in FFI"
}

/// Auto-encode a value to JSON (JSON path)
@external(erlang, "lily_transport_ffi", "auto_encode")
@external(javascript, "./transport.ffi.mjs", "autoEncode")
fn ffi_auto_encode(_value: a) -> Json {
  panic as "auto_encode is implemented in FFI"
}

/// Auto-encode a value to MessagePack bytes
@external(erlang, "lily_transport_ffi", "auto_encode_message_pack")
@external(javascript, "./transport.ffi.mjs", "autoEncodeMessagePack")
fn ffi_auto_encode_message_pack(_value: a) -> BitArray {
  panic as "auto_encode_message_pack is implemented in FFI"
}

/// Decode MessagePack bytes to a Protocol using the provided codec
@external(erlang, "lily_transport_ffi", "decode_message_pack_protocol")
@external(javascript, "./transport.ffi.mjs", "decodeMessagePackProtocol")
fn ffi_decode_message_pack_protocol(
  _bytes: BitArray,
  _codec: BinaryCodec(model, message),
) -> Result(Protocol(model, message), Nil) {
  panic as "decode_message_pack_protocol is implemented in FFI"
}

/// Encode a Protocol to MessagePack bytes using the provided codec
@external(erlang, "lily_transport_ffi", "encode_message_pack_protocol")
@external(javascript, "./transport.ffi.mjs", "encodeMessagePackProtocol")
fn ffi_encode_message_pack_protocol(
  _protocol: Protocol(model, message),
  _codec: BinaryCodec(model, message),
) -> BitArray {
  panic as "encode_message_pack_protocol is implemented in FFI"
}

/// Register constructors
@external(erlang, "lily_transport_ffi", "register")
@external(javascript, "./transport.ffi.mjs", "register")
fn ffi_register(_constructors: List(a)) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport/http.ffi.mjs", "close")
fn ffi_http_close(_handle: HttpHandle) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport/http.ffi.mjs", "connect")
fn ffi_http_connect(
  _post_url: String,
  _events_url: String,
  _flush_batch_size: Int,
  _handler: Handler,
) -> HttpHandle {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./transport/http.ffi.mjs", "send")
fn ffi_http_send(_handle: HttpHandle, _bytes: BitArray) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport/websocket.ffi.mjs", "close")
fn ffi_ws_close(_handle: WsHandle) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport/websocket.ffi.mjs", "connect")
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
@external(javascript, "./transport/websocket.ffi.mjs", "send")
fn ffi_ws_send(_handle: WsHandle, _bytes: BitArray) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./transport/websocket.ffi.mjs", "urlFromCurrentLocation")
fn ffi_ws_url_from_current_location(_path: String) -> String {
  panic as "JavaScript only"
}
