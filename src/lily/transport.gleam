//// This is how Lily deals with the communication between client/browser and
//// the server, ensuring that the centralised model within
//// [`Store`](./store.html#Store) on both sides remains in sync by exchanging
//// serialised [`Protocol`](#Protocol) messages. For most use cases, this
//// module won't be needed but the details below will be helpful, especially
//// if you want to supply your own transport layer.
////
//// It works on both Erlang and JS targets since both ends need it, although
//// the WebSocket connector is JavaScript-only.
////
//// The wire format is the [`Protocol`](#Protocol) exchanged. A
//// [`Serialiser`](#Serialiser) is built with [`automatic`](#automatic) for
//// any Gleam type, or with [`serialiser`](#serialiser) from your own encoders
//// and decoders. The connectors are [`websocket`](#websocket) (with automatic
//// reconnection and offline queueing), [`connector`](#connector) (to wrap a
//// transport of your own), and [`with_offline_queue`](#with_offline_queue)
//// (to give it the same queueing and replay).
////
//// When a connection opens, the server sends `Connected` and `Version`, and
//// the client answers with a `Resync` with the session name and every topic it
//// wants to subscribe to. The server replies with a `Snapshot` per target,
//// then each message travels as a `SessionMessage` or `TopicMessage` and
//// comes back to the other subscribers as an update.
////
//// For most apps, use [`transport.automatic`](#automatic) for
//// serialisation and [`transport.websocket`](#websocket) to connect.
////
//// ```gleam
//// import lily/client
//// import lily/transport
////
//// pub fn main() {
////   let runtime = client.start(shared.store())
////
////   client.connect(runtime, with: transport.websocket("/ws"))
//// }
//// ```
////
//// With the default functions Lily gives you, the communication is done
//// through JSON when a page is served from `localhost` or `127.0.0.1` and
//// MessagePack otherwise. This is mainly to make dev environments have more
//// debuggable frames and smaller transport frames for prod.
////
//// To use one format consistently (everywhere), build the serialiser yourself
//// and pass it to [`store.sync_with`](./store.html#sync_with):
////
//// ```gleam
//// transport.automatic(
////   format: transport.MessagePack,
////   max_decode_depth: 128,
////   modules: [transport.module("my_shared")],
//// )
//// ```
////
//// The automatic serialiser uses positional encoding. Each custom type is a
//// map like `{"_":"ConstructorName","0":field0,"1":field1}`. On JavaScript,
//// constructors must be registered so the decoder can reconstruct them.
//// To register constructors, name the compiled modules that define the
//// types you're sending via the wire when you build the store.
////
//// ```gleam
//// store.new(init: initial_model(), update: update)
//// |> store.sync(
////   route: route,
////   modules: [
////     transport.module("my_shared"),
////     transport.module_in(package: "other_package", path: "other/types"),
////   ],
//// )
//// ```
////
//// This also means that constructor names that cross the wire must be unique
//// (per arity) across the modules as the browser matches on name and arity
//// alone. Lily should warn you in the browser when this happens. For
//// unavoidable clashes (e.g. you have two deps that share constructors),
//// it might be worth it to create your own types and conversion functions.

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
import lily/internal/codec.{
  type Value, ValueArray, ValueBytes, ValueInteger, ValueMap, ValueString,
}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// What a transport gives the client, a function to send a frame and one to
/// close the connection.
///
/// `send` returns `Error` when the frame didn't go out, letting
/// [`with_offline_queue`](#with_offline_queue) hold it and send it later.
pub type Channel {
  Channel(send: fn(BitArray) -> Result(Nil, Nil), close: fn() -> Nil)
}

/// A way for the client to reach the server. Build one with
/// [`websocket`](#websocket) or [`connector`](#connector) and pass it to
/// [`client.connect`](./client.html#connect).
pub opaque type Connector {
  Connector(connect: fn(Handler) -> Channel, pending: fn() -> List(BitArray))
}

/// Wire format the [`automatic`](#automatic) serialiser encodes frames in.
///
/// ```gleam
/// transport.automatic(
///   format: transport.Json,
///   max_decode_depth: 128,
///   modules: [],
/// )
/// ```
pub type Format {
  Json
  MessagePack
  /// JSON when served from `localhost` or `127.0.0.1` or MessagePack otherwise.
  ByHost
}

/// The callbacks a transport calls. `received` for each frame from the
/// server, `opened` every time the connection opens (the first time included),
/// and `closed` when it is lost.
pub type Handler {
  Handler(
    received: fn(BitArray) -> Nil,
    opened: fn() -> Nil,
    closed: fn() -> Nil,
  )
}

/// Severity of a `Diagnostic` from Lily.
pub type Level {
  /// Something was dropped or refused, continues as usual
  Warning
  /// Lily gave up on something, a topic that kept crashing for example
  Failure
}

/// A module whose custom types are sent over the wire. Build one with
/// [`module`](#module) or [`module_in`](#module_in) and list it in
/// [`automatic`](#automatic).
pub opaque type Module {
  Module(package: String, path: String)
}

/// The frames a client and server exchange. You only handle them yourself
/// when you write a [`serialiser`](#serialiser) of your own.
///
/// Sequence numbers count separately for each [`Target`](#Target).
pub type Protocol(model, message) {
  /// Server, confirming a `SessionMessage` or `TopicMessage` was applied.
  Acknowledge(target: Target, sequence: Int)

  /// Server, right after a client connects, with its id. A client observer
  /// sees it as `ClientIdAssigned`.
  Connected(client_id: String)

  /// Server, when a `Subscribe` is refused, with the reason `"not found"` or
  /// `"denied"`.
  Rejected(topic_id: String, reason: String)

  /// Client, after it connects, listing every target it wants a `Snapshot` of.
  Resync(cursors: List(Target))

  /// Client, a message for its own session store.
  SessionMessage(payload: message)

  /// Server, a session update sent by
  /// [`server.dispatch_to`](./server.html#dispatch_to) or
  /// [`server.dispatch_to_all`](./server.html#dispatch_to_all).
  SessionUpdate(sequence: Int, payload: message)

  /// Server, the whole state of a target, in reply to `Resync` or `Subscribe`.
  Snapshot(target: Target, sequence: Int, state: model)

  /// Client, to join a topic. The server replies with `Snapshot` or
  /// `Rejected`.
  Subscribe(topic_id: String)

  /// Client, a message for a shared topic store.
  TopicMessage(topic_id: String, payload: message)

  /// Server, a topic message from another subscriber.
  TopicUpdate(topic_id: String, sequence: Int, payload: message)

  /// Client, to leave a topic. Nothing is sent back.
  Unsubscribe(topic_id: String)

  /// Server, on every connect, with a build identifier. See
  /// [`browser.reload_on_new_version`](./browser.html#reload_on_new_version).
  Version(hash: String)
}

/// How the WebSocket connector waits between reconnection attempts.
///
/// ```gleam
/// transport.websocket_with(
///   url: "ws://localhost:8080/ws",
///   reconnect: transport.DefaultBackoff,
/// )
/// ```
pub type Reconnect {
  /// Exponential backoff with the built-in settings, the same as
  /// `Backoff(1000, 30_000, 0.25, 2.0)`.
  DefaultBackoff

  /// Tuned exponential backoff. `base_milliseconds` is the first delay,
  /// multiplied by `multiplier` after each failed attempt and capped at
  /// `max_milliseconds`.
  ///
  /// `jitter_ratio` randomises each delay by plus or minus that fraction,
  /// keeping clients dropped together from all reconnecting at once.
  ///
  /// ```gleam
  /// transport.websocket_with(
  ///   url: "ws://localhost:8080/ws",
  ///   reconnect: transport.Backoff(
  ///     base_milliseconds: 2000,
  ///     max_milliseconds: 60_000,
  ///     jitter_ratio: 0.25,
  ///     multiplier: 2.0,
  ///   ),
  /// )
  /// ```
  Backoff(
    base_milliseconds: Int,
    max_milliseconds: Int,
    jitter_ratio: Float,
    multiplier: Float,
  )
}

/// Turns [`Protocol`](#Protocol) frames into bytes and back. Build one with
/// [`automatic`](#automatic) or [`serialiser`](#serialiser).
pub opaque type Serialiser(model, message) {
  Auto(format: Format, max_decode_depth: Int)
  Open(
    encode: fn(Protocol(model, message)) -> BitArray,
    decode: fn(BitArray) -> Result(Protocol(model, message), Nil),
  )
}

/// Which store a frame applies to, the per-connection session store or a named
/// shared topic store.
pub type Target {
  Session
  Topic(id: String)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Creates a serialiser that encodes any Gleam value, with no codecs to write.
/// Pass it to [`store.sync_with`](./store.html#sync_with).
///
/// `format` picks what this end writes, and it reads either format whatever
/// you pick. `max_decode_depth` caps how deeply a MessagePack frame may nest.
///
/// `modules` lists the modules that define the types you send. Constructor
/// names that cross the wire must be unique per arity across them.
///
/// ```gleam
/// transport.automatic(
///   format: transport.MessagePack,
///   max_decode_depth: 128,
///   modules: [transport.module("shared")],
/// )
/// ```
///
/// ## Supported shapes
///
/// - Primitives, `Int`, `Float`, `String`, `Bool`, `Nil`.
/// - Custom types, records and variants, a tagged map whose `_` field carries
///   the PascalCase constructor name.
/// - Lists, as arrays.
/// - Tuples, `#(a, b)` as tag-less maps with positional keys
///   (`{"0":a,"1":b}`).
/// - `gleam/dict.Dict`, as `{"_":"$dict","0":[[k,v],...]}`.
/// - `gleam/set.Set`, as `{"_":"$set","0":[v,...]}`.
///
/// ## Not supported
///
/// `BitArray` fields are not encoded, since on Erlang they can't be told
/// apart from a `String`. Wrap raw bytes in a type of your own and write a
/// [`serialiser`](#serialiser) that base64-encodes them:
///
/// ```gleam
/// pub type Bytes {
///   Bytes(data: BitArray)
/// }
/// ```
pub fn automatic(
  format format: Format,
  max_decode_depth max_decode_depth: Int,
  modules modules: List(Module),
) -> Serialiser(model, message) {
  list.each(modules, fn(entry) {
    codec.request_module(entry.package, entry.path)
  })
  Auto(format:, max_decode_depth:)
}

/// Wraps a `connect` function as a [`Connector`](#Connector), for a transport
/// of your own.
///
/// `connect` gets the [`Handler`](#Handler) to call and returns the
/// [`Channel`](#Channel) to send frames through. Wrap the result in
/// [`with_offline_queue`](#with_offline_queue) to queue frames sent while it
/// is down.
pub fn connector(connect connect: fn(Handler) -> Channel) -> Connector {
  Connector(connect:, pending: fn() { [] })
}

/// Decodes bytes into a [`Protocol`](#Protocol) frame.
pub fn decode(
  bytes: BitArray,
  serialiser serialiser: Serialiser(model, message),
) -> Result(Protocol(model, message), Nil) {
  case serialiser {
    Auto(max_decode_depth:, ..) ->
      case detect_format(bytes) {
        Ok(Json) -> decode_json(bytes)
        Ok(MessagePack) -> decode_message_pack(bytes, max_decode_depth)
        Ok(ByHost) | Error(Nil) -> Error(Nil)
      }
    Open(decode:, ..) -> decode(bytes)
  }
}

/// Encodes a [`Protocol`](#Protocol) frame into bytes, in the serialiser's
/// format.
///
/// `ByHost` writes MessagePack where there is no page, such as on the server.
pub fn encode(
  protocol: Protocol(model, message),
  serialiser serialiser: Serialiser(model, message),
) -> BitArray {
  case serialiser {
    Auto(format:, ..) -> encode_in(protocol, format)
    Open(encode:, ..) -> encode(protocol)
  }
}

/// Names a module whose types are sent over the wire, by its path.
///
/// The first segment is taken as the package, meaning `module("shared")` is
/// module `shared` in package `shared`, and `module("shared/views/note")` is
/// that package's `views/note`. Use [`module_in`](#module_in) when the package
/// has another name.
pub fn module(path: String) -> Module {
  let package = case string.split(path, "/") {
    [first, ..] -> first
    [] -> path
  }
  Module(package:, path:)
}

/// Names a module in `package`, for when the package isn't the first segment
/// of the path, as with a dependency.
///
/// ```gleam
/// transport.module_in(package: "some_dep", path: "some/dep/module")
/// ```
pub fn module_in(package package: String, path path: String) -> Module {
  Module(package:, path:)
}

/// Creates a serialiser from your own functions that encode and decode a
/// whole [`Protocol`](#Protocol) frame, for when [`automatic`](#automatic)
/// doesn't fit.
pub fn serialiser(
  encode encode: fn(Protocol(model, message)) -> BitArray,
  decode decode: fn(BitArray) -> Result(Protocol(model, message), Nil),
) -> Serialiser(model, message) {
  Open(encode:, decode:)
}

@target(javascript)
/// Connects to the server over a WebSocket at `url`, reconnecting with the
/// default backoff. Pass it to [`client.connect`](./client.html#connect).
///
/// `url` may be relative, `/ws` becomes `wss://host/ws` on an https page.
/// Frames sent while disconnected are queued and sent when it reconnects.
///
/// ```gleam
/// client.connect(runtime, with: transport.websocket("/ws"))
/// ```
pub fn websocket(url: String) -> Connector {
  websocket_with(url:, reconnect: DefaultBackoff)
}

@target(javascript)
/// Like [`websocket`](#websocket), with a [`Reconnect`](#Reconnect) policy of
/// your own.
///
/// ```gleam
/// transport.websocket_with(
///   url: "/ws",
///   reconnect: transport.Backoff(
///     base_milliseconds: 2000,
///     max_milliseconds: 60_000,
///     jitter_ratio: 0.25,
///     multiplier: 2.0,
///   ),
/// )
/// ```
pub fn websocket_with(
  url url: String,
  reconnect reconnect: Reconnect,
) -> Connector {
  let #(base_milliseconds, max_milliseconds, jitter_ratio, multiplier) = case
    reconnect
  {
    DefaultBackoff -> #(1000, 30_000, 0.25, 2.0)
    Backoff(base_milliseconds:, max_milliseconds:, jitter_ratio:, multiplier:) -> #(
      base_milliseconds,
      max_milliseconds,
      jitter_ratio,
      multiplier,
    )
  }
  connector(fn(handler: Handler) {
    ffi_websocket_connect(
      url,
      base_milliseconds,
      max_milliseconds,
      jitter_ratio,
      multiplier,
      handler,
      Channel,
    )
  })
  |> with_offline_queue(storage_key: "lily_ws_pending")
}

@target(javascript)
/// Holds frames a connector couldn't send and sends them, in order, when it
/// next opens.
///
/// The queue is kept in `sessionStorage` under `storage_key`, letting it
/// survive a reload without being shared between tabs. Your
/// [`Channel`](#Channel)'s `send` must return `Error` for a frame that didn't
/// go out.
pub fn with_offline_queue(
  inner: Connector,
  storage_key storage_key: String,
) -> Connector {
  Connector(
    connect: fn(handler: Handler) {
      ffi_offline_connect(inner.connect, storage_key, handler, Handler, Channel)
    },
    pending: fn() { ffi_offline_pending(storage_key) },
  )
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// A serialiser of your own ignores `format`.
@internal
pub fn encode_as(
  protocol: Protocol(model, message),
  serialiser serialiser: Serialiser(model, message),
  format format: Format,
) -> BitArray {
  case serialiser {
    Auto(..) -> encode_in(protocol, format)
    Open(encode:, ..) -> encode(protocol)
  }
}

@internal
pub fn format_for_host(format: Format, hostname: String) -> Format {
  case format {
    Json -> Json
    MessagePack -> MessagePack
    ByHost ->
      case is_local_host(hostname) {
        True -> Json
        False -> MessagePack
      }
  }
}

@internal
pub fn frame_format(
  bytes: BitArray,
  serialiser serialiser: Serialiser(model, message),
) -> Result(Format, Nil) {
  case serialiser {
    Auto(..) -> detect_format(bytes)
    Open(..) -> Error(Nil)
  }
}

@internal
pub fn is_local_host(hostname: String) -> Bool {
  hostname == "localhost" || hostname == "127.0.0.1"
}

@internal
pub fn is_local_page() -> Bool {
  is_local_host(page_hostname())
}

/// Includes frames left over from before a reload.
@internal
pub fn pending(connector: Connector) -> List(BitArray) {
  connector.pending()
}

@internal
pub fn resolve_for_page(
  serialiser: Serialiser(model, message),
) -> Serialiser(model, message) {
  case serialiser {
    Auto(format:, max_decode_depth:) ->
      Auto(format: format_for_host(format, page_hostname()), max_decode_depth:)
    Open(..) -> serialiser
  }
}

@internal
pub fn run_connector(connector: Connector, handler: Handler) -> Channel {
  connector.connect(handler)
}

/// What a server writes before a client has said which format it speaks.
@internal
pub fn server_format(serialiser: Serialiser(model, message)) -> Format {
  case serialiser {
    Auto(format:, ..) -> format_for_host(format, "")
    Open(..) -> MessagePack
  }
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

type Reader(model, message) {
  Reader(
    int: fn(String) -> Result(Int, Nil),
    message: fn(String) -> Result(message, Nil),
    model: fn(String) -> Result(model, Nil),
    string: fn(String) -> Result(String, Nil),
    target: fn(String) -> Result(Target, Nil),
    targets: fn(String) -> Result(List(Target), Nil),
  )
}

type Writer(model, message, field) {
  Writer(
    int: fn(Int) -> field,
    message: fn(message) -> field,
    model: fn(model) -> field,
    string: fn(String) -> field,
    target: fn(Target) -> field,
    targets: fn(List(Target)) -> field,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

// failure value never read, only needs the decoder's type
fn auto_decoder() -> decode.Decoder(value) {
  decode.new_primitive_decoder("Auto", fn(value) {
    case codec.decode_json(value) {
      Ok(decoded) -> Ok(codec.passthrough(decoded))
      Error(_) -> Error(codec.passthrough(value))
    }
  })
}

// shared by both formats so they agree on a frame's fields
fn build(
  reader: Reader(model, message),
) -> Result(Protocol(model, message), Nil) {
  use tag <- result.try(reader.string("type"))
  case tag {
    "acknowledge" -> {
      use target <- result.try(reader.target("target"))
      use sequence <- result.try(reader.int("sequence"))
      Ok(Acknowledge(target:, sequence:))
    }
    "connected" -> {
      use client_id <- result.try(reader.string("client_id"))
      Ok(Connected(client_id:))
    }
    "rejected" -> {
      use topic_id <- result.try(reader.string("topic_id"))
      use reason <- result.try(reader.string("reason"))
      Ok(Rejected(topic_id:, reason:))
    }
    "resync" -> {
      use cursors <- result.try(reader.targets("cursors"))
      Ok(Resync(cursors:))
    }
    "session_message" -> {
      use payload <- result.try(reader.message("payload"))
      Ok(SessionMessage(payload:))
    }
    "session_update" -> {
      use sequence <- result.try(reader.int("sequence"))
      use payload <- result.try(reader.message("payload"))
      Ok(SessionUpdate(sequence:, payload:))
    }
    "snapshot" -> {
      use target <- result.try(reader.target("target"))
      use sequence <- result.try(reader.int("sequence"))
      use state <- result.try(reader.model("state"))
      Ok(Snapshot(target:, sequence:, state:))
    }
    "subscribe" -> {
      use topic_id <- result.try(reader.string("topic_id"))
      Ok(Subscribe(topic_id:))
    }
    "topic_message" -> {
      use topic_id <- result.try(reader.string("topic_id"))
      use payload <- result.try(reader.message("payload"))
      Ok(TopicMessage(topic_id:, payload:))
    }
    "topic_update" -> {
      use topic_id <- result.try(reader.string("topic_id"))
      use sequence <- result.try(reader.int("sequence"))
      use payload <- result.try(reader.message("payload"))
      Ok(TopicUpdate(topic_id:, sequence:, payload:))
    }
    "unsubscribe" -> {
      use topic_id <- result.try(reader.string("topic_id"))
      Ok(Unsubscribe(topic_id:))
    }
    "version" -> {
      use hash <- result.try(reader.string("hash"))
      Ok(Version(hash:))
    }
    _ -> Error(Nil)
  }
}

fn decode_json(bytes: BitArray) -> Result(Protocol(model, message), Nil) {
  use text <- result.try(bit_array.to_string(bytes))
  use value <- result.try(
    json.parse(from: text, using: decode.dynamic)
    |> result.replace_error(Nil),
  )
  build(json_reader(value))
}

fn decode_message_pack(
  bytes: BitArray,
  max_depth: Int,
) -> Result(Protocol(model, message), Nil) {
  use #(top_value, _) <- result.try(codec.decode_bounded(bytes, max_depth))
  case top_value {
    ValueMap(entries) -> build(message_pack_reader(entries, max_depth))
    _ -> Error(Nil)
  }
}

fn decode_target_message_pack(value: Value) -> Result(Target, Nil) {
  case value {
    ValueMap(entries) ->
      case
        codec.lookup_string_key(entries, "kind"),
        codec.lookup_string_key(entries, "id")
      {
        Ok(ValueString("session")), _ -> Ok(Session)
        Ok(ValueString("topic")), Ok(ValueString(id)) -> Ok(Topic(id:))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// every frame is a map (JSON object or MessagePack map), first byte decides
fn detect_format(bytes: BitArray) -> Result(Format, Nil) {
  case bytes {
    <<0xDE, _:bits>> | <<0xDF, _:bits>> -> Ok(MessagePack)
    <<marker, _:bits>> if marker >= 0x80 && marker <= 0x8F -> Ok(MessagePack)
    _ -> detect_json_format(bytes)
  }
}

// leading whitespace is never a MessagePack map marker, making it JSON
fn detect_json_format(bytes: BitArray) -> Result(Format, Nil) {
  case bytes {
    <<0x7B, _:bits>> -> Ok(Json)
    <<0x20, rest:bits>>
    | <<0x09, rest:bits>>
    | <<0x0A, rest:bits>>
    | <<0x0D, rest:bits>> -> detect_json_format(rest)
    _ -> Error(Nil)
  }
}

fn encode_in(protocol: Protocol(model, message), format: Format) -> BitArray {
  case format {
    Json -> encode_json(protocol)
    MessagePack -> encode_message_pack(protocol)
    ByHost -> encode_in(protocol, format_for_host(ByHost, page_hostname()))
  }
}

fn encode_json(protocol: Protocol(model, message)) -> BitArray {
  let writer =
    Writer(
      int: json.int,
      message: codec.encode_json,
      model: codec.encode_json,
      string: json.string,
      target: encode_target_json,
      targets: json.array(_, encode_target_json),
    )
  let #(tag, fields) = frame_fields(protocol, writer)
  json.object([#("type", json.string(tag)), ..fields])
  |> json.to_string
  |> bit_array.from_string
}

fn encode_message_pack(protocol: Protocol(model, message)) -> BitArray {
  let encode_string = codec.encode_string
  let writer =
    Writer(
      int: codec.encode_int,
      message: payload_bin,
      model: payload_bin,
      string: encode_string,
      target: encode_target_message_pack,
      targets: fn(targets) {
        codec.encode_array(list.map(targets, encode_target_message_pack))
      },
    )
  let #(tag, fields) = frame_fields(protocol, writer)
  let entries =
    list.map(fields, fn(field) { #(encode_string(field.0), field.1) })
  codec.encode_map([#(encode_string("type"), encode_string(tag)), ..entries])
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
  let encode_string = codec.encode_string
  case target {
    Session ->
      codec.encode_map([#(encode_string("kind"), encode_string("session"))])
    Topic(id:) ->
      codec.encode_map([
        #(encode_string("kind"), encode_string("topic")),
        #(encode_string("id"), encode_string(id)),
      ])
  }
}

// field order is part of the wire format
fn frame_fields(
  protocol: Protocol(model, message),
  writer: Writer(model, message, field),
) -> #(String, List(#(String, field))) {
  case protocol {
    Acknowledge(target:, sequence:) -> #("acknowledge", [
      #("target", writer.target(target)),
      #("sequence", writer.int(sequence)),
    ])
    Connected(client_id:) -> #("connected", [
      #("client_id", writer.string(client_id)),
    ])
    Rejected(topic_id:, reason:) -> #("rejected", [
      #("topic_id", writer.string(topic_id)),
      #("reason", writer.string(reason)),
    ])
    Resync(cursors:) -> #("resync", [#("cursors", writer.targets(cursors))])
    SessionMessage(payload:) -> #("session_message", [
      #("payload", writer.message(payload)),
    ])
    SessionUpdate(sequence:, payload:) -> #("session_update", [
      #("sequence", writer.int(sequence)),
      #("payload", writer.message(payload)),
    ])
    Snapshot(target:, sequence:, state:) -> #("snapshot", [
      #("target", writer.target(target)),
      #("sequence", writer.int(sequence)),
      #("state", writer.model(state)),
    ])
    Subscribe(topic_id:) -> #("subscribe", [
      #("topic_id", writer.string(topic_id)),
    ])
    TopicMessage(topic_id:, payload:) -> #("topic_message", [
      #("topic_id", writer.string(topic_id)),
      #("payload", writer.message(payload)),
    ])
    TopicUpdate(topic_id:, sequence:, payload:) -> #("topic_update", [
      #("topic_id", writer.string(topic_id)),
      #("sequence", writer.int(sequence)),
      #("payload", writer.message(payload)),
    ])
    Unsubscribe(topic_id:) -> #("unsubscribe", [
      #("topic_id", writer.string(topic_id)),
    ])
    Version(hash:) -> #("version", [#("hash", writer.string(hash))])
  }
}

fn json_field(
  value: Dynamic,
  key: String,
  decoder: decode.Decoder(field),
) -> Result(field, Nil) {
  decode.run(value, decode.at([key], decoder))
  |> result.replace_error(Nil)
}

fn json_reader(value: Dynamic) -> Reader(model, message) {
  Reader(
    int: json_field(value, _, decode.int),
    message: json_field(value, _, auto_decoder()),
    model: json_field(value, _, auto_decoder()),
    string: json_field(value, _, decode.string),
    target: json_field(value, _, target_decoder()),
    targets: json_field(value, _, decode.list(target_decoder())),
  )
}

fn message_pack_payload(
  value: Result(Value, Nil),
  max_depth: Int,
) -> Result(payload, Nil) {
  case value {
    Ok(ValueBytes(bytes)) ->
      codec.decode_message_pack(bytes, max_depth)
      |> result.map(codec.passthrough)
    _ -> Error(Nil)
  }
}

fn message_pack_reader(
  entries: List(#(Value, Value)),
  max_depth: Int,
) -> Reader(model, message) {
  let lookup = codec.lookup_string_key(entries, _)
  Reader(
    int: fn(key) {
      case lookup(key) {
        Ok(ValueInteger(value)) -> Ok(value)
        _ -> Error(Nil)
      }
    },
    message: fn(key) { message_pack_payload(lookup(key), max_depth) },
    model: fn(key) { message_pack_payload(lookup(key), max_depth) },
    string: fn(key) {
      case lookup(key) {
        Ok(ValueString(text)) -> Ok(text)
        _ -> Error(Nil)
      }
    },
    target: fn(key) { lookup(key) |> result.try(decode_target_message_pack) },
    targets: fn(key) {
      case lookup(key) {
        Ok(ValueArray(items)) -> list.try_map(items, decode_target_message_pack)
        _ -> Error(Nil)
      }
    },
  )
}

fn payload_bin(value: payload) -> BitArray {
  codec.encode_bin(codec.encode_message_pack(value))
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

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "offlineConnect")
fn ffi_offline_connect(
  _connect: fn(Handler) -> Channel,
  _storage_key: String,
  _handler: Handler,
  _make_handler: fn(fn(BitArray) -> Nil, fn() -> Nil, fn() -> Nil) -> Handler,
  _make_channel: fn(fn(BitArray) -> Result(Nil, Nil), fn() -> Nil) -> Channel,
) -> Channel {
  Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "offlinePending")
fn ffi_offline_pending(_storage_key: String) -> List(BitArray) {
  []
}

@target(javascript)
@external(javascript, "./transport.ffi.mjs", "websocketConnect")
fn ffi_websocket_connect(
  _url: String,
  _reconnect_base_milliseconds: Int,
  _reconnect_max_milliseconds: Int,
  _reconnect_jitter_ratio: Float,
  _reconnect_multiplier: Float,
  _handler: Handler,
  _make_channel: fn(fn(BitArray) -> Result(Nil, Nil), fn() -> Nil) -> Channel,
) -> Channel

@external(javascript, "./transport.ffi.mjs", "pageHostname")
fn page_hostname() -> String {
  ""
}
