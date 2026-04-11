//// The transport module handles client-server communication and
//// serialisation. It's target-agnostic and works on both Erlang and
//// JavaScript.
////
//// This module provides the wire format ([`Protocol`](#Protocol) envelope
//// types for client-server messages), serialisation
//// ([`Serialiser`](#Serialiser) encode/decode functions), automatic
//// serialisation ([`automatic`](#automatic) zero-config codec,
//// recommended), custom serialisation ([`custom`](#custom) explicit
//// encode/decode for special cases), and transport abstraction
//// ([`Connector`](#Connector) and [`Transport`](#Transport) for swapping
//// between WebSocket, HTTP, or custom transports).
////
//// For most apps, use [`transport.automatic`](#automatic) for
//// zero-configuration serialisation of any Gleam custom type:
////
//// ```gleam
//// import lily/transport
////
//// client.connect(
////   runtime,
////   with: connector,
////   serialiser: transport.automatic(),
//// )
////
//// server.start(store: app_store, serialiser: transport.automatic())
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
//// [`transport.custom`](#custom) with explicit encode/decode functions.
////

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
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
    on_receive: fn(String) -> Nil,
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

/// The protocol currently uses JSON serialisation for debugging clarity. Both
/// message and model encoders/decoders should be provided.
pub type Serialiser(model, message) {
  Serialiser(
    encode_message: fn(message) -> Json,
    decode_message: decode.Decoder(message),
    encode_model: fn(model) -> Json,
    decode_model: decode.Decoder(model),
  )
}

/// This is transport handle returned by a connector. Provides `send` to
/// transmit messages and `close` to terminate the connection.
pub opaque type Transport {
  Transport(send: fn(String) -> Nil, close: fn() -> Nil)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create an automatic serialiser. Encodes and decodes any Gleam custom type
/// using positional fields. Works across both targets.
///
/// On JavaScript, constructors are discovered automatically:
/// - Model types: walked recursively from the initial model at start time
/// - Message types: cached on first send
///
/// For message types that only arrive from the server (never sent by this
/// client), call [`transport.register`](#register) before connecting.
///
/// ## Example
///
/// ```gleam
/// // Zero configuration for most apps:
/// client.connect(runtime, with: connector, serialiser: transport.automatic())
/// server.start(store: app_store, serialiser: transport.automatic())
/// ```
pub fn automatic() -> Serialiser(model, message) {
  Serialiser(
    encode_message: ffi_auto_encode,
    decode_message: decode.new_primitive_decoder("Auto", ffi_auto_decode),
    encode_model: ffi_auto_encode,
    decode_model: decode.new_primitive_decoder("Auto", ffi_auto_decode),
  )
}

/// Close the transport connection. After calling this, the transport should
/// clean up resources and stop attempting to reconnect.
pub fn close(transport: Transport) -> Nil {
  transport.close()
}

/// Create a serialiser from explicit encode/decode functions for cases where
/// the auto format is not suitable (third-party APIs, human-readable JSON,
/// backwards compatibility).
pub fn custom(
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
  )
}

/// Decode a `String` into a [`Protocol`](#Protocol) result. Expects the
/// `String` to be in a JSON format.
pub fn decode(
  text: String,
  serialiser serialiser: Serialiser(model, message),
) -> Result(Protocol(model, message), Nil) {
  let decoder = protocol_decoder(serialiser)
  json.parse(from: text, using: decoder)
  |> result.replace_error(Nil)
}

/// Encodes a `Protocol` into a JSON `String`.
pub fn encode(
  protocol: Protocol(model, message),
  serialiser serialiser: Serialiser(model, message),
) -> String {
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
}

/// Create a new [`Transport`](#Transport) with the given send and close
/// functions. This is used by transport implementations (WebSocket, HTTP) to
/// construct the Transport handle they return from their connector.
pub fn new(send send: fn(String) -> Nil, close close: fn() -> Nil) -> Transport {
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

/// Send a message through the transport. The text should be a serialised
/// [`Protocol`](#Protocol) message (JSON string).
pub fn send(transport: Transport, text: String) -> Nil {
  transport.send(text)
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

/// Auto-decode a dynamic value
@external(javascript, "./transport.ffi.mjs", "autoDecode")
@external(erlang, "lily_transport_ffi", "auto_decode")
fn ffi_auto_decode(_value: Dynamic) -> Result(a, a) {
  // Placeholder for type checking — actual implementation in FFI
  panic as "auto_decode is implemented in FFI"
}

/// Auto-encode a value to JSON
@external(javascript, "./transport.ffi.mjs", "autoEncode")
@external(erlang, "lily_transport_ffi", "auto_encode")
fn ffi_auto_encode(_value: a) -> Json {
  // Placeholder for type checking — actual implementation in FFI
  panic as "auto_encode is implemented in FFI"
}

/// Register constructors
@external(javascript, "./transport.ffi.mjs", "register")
@external(erlang, "lily_transport_ffi", "register")
fn ffi_register(_constructors: List(a)) -> Nil {
  Nil
}
