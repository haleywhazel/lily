//// The transport module handles client-server communication and
//// serialisation. It's target-agnostic and works on both Erlang and
//// JavaScript.
////
//// This module provides the wire format ([`Protocol`](#Protocol) envelope
//// types for client-server messages), serialisation
//// ([`Serialiser`](#Serialiser) encode/decode functions), automatic
//// serialisation ([`automatic`](#automatic) zero-config codec,
//// recommended), custom serialisation ([`custom_json`](#custom_json) and
//// [`custom_binary`](#custom_binary) for explicit encode/decode), and
//// transport abstraction ([`Connector`](#Connector) and
//// [`Transport`](#Transport) for swapping between WebSocket, HTTP, or custom
//// transports).
////
//// For most apps, use [`transport.automatic`](#automatic) for
//// zero-configuration serialisation of any Gleam custom type. The default
//// wire format is MessagePack (compact binary). Use
//// [`transport.use_json`](#use_json) for human-readable frames during
//// development:
////
//// ```gleam
//// import lily/transport
////
//// // Production: MessagePack (default)
//// client.connect(runtime, with: connector, serialiser: transport.automatic())
//// server.start(store: app_store, serialiser: transport.automatic())
////
//// // Development: JSON, readable in DevTools
//// client.connect(runtime, with: connector,
////   serialiser: transport.automatic() |> transport.use_json())
//// ```
////
//// The automatic serialiser uses positional encoding with the wire format
//// `{"_":"ConstructorName","0":field0,"1":field1,...}`. On JavaScript,
//// constructors are discovered automatically from message sends and the
//// initial model. For server-only message types that never get sent by the
//// client, use [`transport.register`](#register).
////
//// For cases where automatic serialisation isn't suitable (third-party APIs,
//// human-readable JSON, backwards compatibility), use
//// [`transport.custom_json`](#custom_json) with explicit encode/decode
//// functions, or [`transport.custom_binary`](#custom_binary) for a custom
//// binary codec.
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

/// Create a new [`Transport`](#Transport) with the given send and close
/// functions. This is used by transport implementations (WebSocket, HTTP) to
/// construct the Transport handle they return from their connector.
pub fn new(
  send send: fn(BitArray) -> Nil,
  close close: fn() -> Nil,
) -> Transport {
  Transport(send: send, close: close)
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
