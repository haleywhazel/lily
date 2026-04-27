//// A pubsub (written like this only in the module docs, the proper name is
//// pub_sub to reflect the PubSub type name) for server-pushed and ephemeral
//// messages that do not get stored or sequenced in the same way as messages
//// within [`store.Store`](./store.html#Store).
////
//// Very similar to [Phoenix PubSub](https://hexdocs.pm/phoenix_pubsub), this
//// one is built around a [`transport.Push`](./transport.html#Protocol)
//// frame that carries no sequence number and is never replayed on resync.
////
//// Use a pubsub when you need to broadcast information that isn't part of
//// the authoritative store, like presence events. It allows for communication
//// between separate stores (or other server-actions). That said, everything
//// that must be synchronised across clients should still goes through
//// [`lily/server`](./server.html), as pubsub is slightly less reliable since
//// it's ephemeral.
////
//// ```gleam
//// import lily/pub_sub
//// import lily/server
//// import lily/transport
////
//// pub fn main() {
////   let assert Ok(srv) = server.start(store:, serialiser: my_ser)
////   let assert Ok(bus) = pub_sub.new()
////
////   // Per-connection wiring (typically in your WebSocket handler):
////   let client_id = server.generate_client_id()
////   let send = fn(bytes) { ws.send(bytes) }
////   server.connect(srv, client_id:, send:)
////   pub_sub.register(bus, client_id:, send:)
////
////   // Subscribe from anywhere — a message hook, an HTTP handler, etc.:
////   pub_sub.subscribe(bus, client_id:, topic: "room:general")
////
////   // Broadcast from anywhere — a background job, a webhook, etc.:
////   pub_sub.broadcast(bus,
////     topic: "room:general",
////     message: NewChatMessage("hi"),
////     serialiser: my_serialiser,
////   )
//// }
//// ```
////
//// PubSub instances and servers are independent — an app can use one, the
//// other, or both. On Erlang a pubsub is backed by an OTP actor; on JS, by
//// closure-scoped state. Both targets expose the same API.
////

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/result
import gleam/set.{type Set}
import lily/transport.{type Serialiser}

@target(erlang)
import gleam/erlang/process.{type Subject}
@target(erlang)
import gleam/otp/actor

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// A handle to a running pubsub instance.
///
/// The wrap around `PubSubHandle` exists so the public API can have one
/// uniform shape across targets.
///
///
/// Compare with [`client.Runtime`](./client.html#Runtime), whose wrap is
/// load-bearing for a different reason: the JS FFI handle has no type
/// parameters, so the wrap is the only place to attach the `(model,
/// message)` phantom params. Here both targets already carry the
/// `message` parameter; the wrap is purely about a uniform, encapsulated
/// surface.
pub opaque type PubSub(message) {
  // Just as a note here, on Erlang the handle is an OTP
  // `Subject(InternalEvent(message))` and on JS an opaque eternal type.
  // Hiding both behind the handle makes it easier to maintain a single public
  // API, even if it feels a bit annoying to have a type that's basically a
  // wrapper around another time. This should make sure that the Erlang actor
  // subject handle never leaks (hopefully?).
  //
  // Similar issue to RuntimeHandle, although that one has more reasons to be
  // separate.
  PubSub(handle: PubSubHandle(message))
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Broadcast `message` to every client subscribed to `topic`. The message is
/// encoded as a [`transport.Push`](./transport.html#Protocol) frame before
/// being handed to each subscriber's `send` callback.
pub fn broadcast(
  pub_sub: PubSub(message),
  topic topic: String,
  message message: message,
  serialiser serialiser: Serialiser(model, message),
) -> Nil {
  let frame = transport.encode(transport.Push(payload: message), serialiser:)
  platform_broadcast(pub_sub.handle, topic, frame, option.None)
}

/// Broadcast `message` to every client subscribed to `topic` except the
/// given `from` client. Useful in message hooks where the originating client
/// already knows what it sent and doesn't need the echo.
pub fn broadcast_from(
  pub_sub: PubSub(message),
  from from_id: String,
  topic topic: String,
  message message: message,
  serialiser serialiser: Serialiser(model, message),
) -> Nil {
  let frame = transport.encode(transport.Push(payload: message), serialiser:)
  platform_broadcast(pub_sub.handle, topic, frame, option.Some(from_id))
}

/// Start a new pubsub instance. Returns `Error(Nil)` only when the Erlang
/// actor fails to start (rare). Always returns `Ok` on JavaScript.
pub fn new() -> Result(PubSub(message), Nil) {
  let initial_state =
    PubSubState(clients: dict.new(), subscriptions: dict.new())

  platform_start(initial_state)
  |> result.map(PubSub)
}

/// Register a client's `send` callback. Call alongside
/// [`server.connect`](./server.html#connect) when a client connects.
pub fn register(
  pub_sub: PubSub(message),
  client_id client_id: String,
  send send: fn(BitArray) -> Nil,
) -> Nil {
  platform_register(pub_sub.handle, client_id, send)
}

/// Subscribe a registered client to `topic`. Subsequent broadcasts on that
/// topic will deliver to this client.
pub fn subscribe(
  pub_sub: PubSub(message),
  client_id client_id: String,
  topic topic: String,
) -> Nil {
  platform_subscribe(pub_sub.handle, client_id, topic)
}

/// Remove a client and automatically unsubscribe it from every topic it was
/// in. Call alongside [`server.disconnect`](./server.html#disconnect) when a
/// client disconnects.
pub fn unregister(pub_sub: PubSub(message), client_id client_id: String) -> Nil {
  platform_unregister(pub_sub.handle, client_id)
}

/// Unsubscribe a client from `topic`. No-op if the client was not subscribed.
pub fn unsubscribe(
  pub_sub: PubSub(message),
  client_id client_id: String,
  topic topic: String,
) -> Nil {
  platform_unsubscribe(pub_sub.handle, client_id, topic)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(erlang)
/// Internal events for the Erlang actor mailbox
type InternalEvent(message) {
  Register(client_id: String, send: fn(BitArray) -> Nil)
  Unregister(client_id: String)
  Subscribe(client_id: String, topic: String)
  Unsubscribe(client_id: String, topic: String)
  Broadcast(topic: String, bytes: BitArray, exclude: Option(String))
}

@target(erlang)
/// Platform-specific handle (Subject on Erlang, FFI handle on JavaScript)
type PubSubHandle(message) =
  Subject(InternalEvent(message))

@target(javascript)
type PubSubHandle(message)

/// PubSub state: registered clients and their topic subscriptions. The
/// `subscriptions` dict maps topic → Set(client_id); an absent topic means no
/// subscribers (we remove empty sets to keep the dict tidy).
type PubSubState(message) {
  PubSubState(
    clients: Dict(String, fn(BitArray) -> Nil),
    subscriptions: Dict(String, Set(String)),
  )
}

// =============================================================================
// PRIVATE FUNCTIONS — SHARED LOGIC
// =============================================================================

/// Broadcast `bytes` to every subscriber of `topic` except any excluded id.
/// Leaves state unchanged — broadcasting is a pure fan-out.
fn handle_broadcast_logic(
  state: PubSubState(message),
  topic: String,
  bytes: BitArray,
  exclude: Option(String),
) -> PubSubState(message) {
  case dict.get(state.subscriptions, topic) {
    Error(Nil) -> state
    Ok(subscribers) -> {
      set.each(subscribers, fn(subscriber_id) {
        case exclude {
          option.Some(id) if id == subscriber_id -> Nil
          _ ->
            case dict.get(state.clients, subscriber_id) {
              Ok(send) -> send(bytes)
              Error(Nil) -> Nil
            }
        }
      })
      state
    }
  }
}

/// Add a client's `send` callback to the clients dict.
fn handle_register_logic(
  state: PubSubState(message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> PubSubState(message) {
  PubSubState(..state, clients: dict.insert(state.clients, client_id, send))
}

/// Subscribe a client to a topic, creating the subscriber set if needed.
fn handle_subscribe_logic(
  state: PubSubState(message),
  client_id: String,
  topic: String,
) -> PubSubState(message) {
  let subscribers = case dict.get(state.subscriptions, topic) {
    Ok(existing) -> set.insert(existing, client_id)
    Error(Nil) -> set.insert(set.new(), client_id)
  }
  PubSubState(
    ..state,
    subscriptions: dict.insert(state.subscriptions, topic, subscribers),
  )
}

/// Remove a client and all of its subscriptions.
fn handle_unregister_logic(
  state: PubSubState(message),
  client_id: String,
) -> PubSubState(message) {
  let subscriptions =
    dict.fold(state.subscriptions, dict.new(), fn(acc, topic, subscribers) {
      let updated = set.delete(subscribers, client_id)
      case set.size(updated) {
        0 -> acc
        _ -> dict.insert(acc, topic, updated)
      }
    })
  PubSubState(clients: dict.delete(state.clients, client_id), subscriptions:)
}

/// Unsubscribe a client from a single topic. Drops the topic entry if no
/// subscribers remain.
fn handle_unsubscribe_logic(
  state: PubSubState(message),
  client_id: String,
  topic: String,
) -> PubSubState(message) {
  case dict.get(state.subscriptions, topic) {
    Error(Nil) -> state
    Ok(subscribers) -> {
      let updated = set.delete(subscribers, client_id)
      let subscriptions = case set.size(updated) {
        0 -> dict.delete(state.subscriptions, topic)
        _ -> dict.insert(state.subscriptions, topic, updated)
      }
      PubSubState(..state, subscriptions:)
    }
  }
}

// =============================================================================
// PRIVATE FUNCTIONS — ERLANG
// =============================================================================

@target(erlang)
/// Actor message handler (Erlang): dispatches each event to the corresponding
/// shared logic function.
fn handle_message(
  state: PubSubState(message),
  event: InternalEvent(message),
) -> actor.Next(PubSubState(message), InternalEvent(message)) {
  case event {
    Register(client_id:, send:) ->
      handle_register_logic(state, client_id, send)
      |> actor.continue

    Unregister(client_id:) ->
      handle_unregister_logic(state, client_id)
      |> actor.continue

    Subscribe(client_id:, topic:) ->
      handle_subscribe_logic(state, client_id, topic)
      |> actor.continue

    Unsubscribe(client_id:, topic:) ->
      handle_unsubscribe_logic(state, client_id, topic)
      |> actor.continue

    Broadcast(topic:, bytes:, exclude:) ->
      handle_broadcast_logic(state, topic, bytes, exclude)
      |> actor.continue
  }
}

@target(erlang)
fn platform_broadcast(
  handle: PubSubHandle(message),
  topic: String,
  bytes: BitArray,
  exclude: Option(String),
) -> Nil {
  actor.send(handle, Broadcast(topic:, bytes:, exclude:))
}

@target(erlang)
fn platform_register(
  handle: PubSubHandle(message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  actor.send(handle, Register(client_id:, send:))
}

@target(erlang)
fn platform_start(
  initial_state: PubSubState(message),
) -> Result(PubSubHandle(message), Nil) {
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Nil)
}

@target(erlang)
fn platform_subscribe(
  handle: PubSubHandle(message),
  client_id: String,
  topic: String,
) -> Nil {
  actor.send(handle, Subscribe(client_id:, topic:))
}

@target(erlang)
fn platform_unregister(handle: PubSubHandle(message), client_id: String) -> Nil {
  actor.send(handle, Unregister(client_id:))
}

@target(erlang)
fn platform_unsubscribe(
  handle: PubSubHandle(message),
  client_id: String,
  topic: String,
) -> Nil {
  actor.send(handle, Unsubscribe(client_id:, topic:))
}

// =============================================================================
// PRIVATE FUNCTIONS — JAVASCRIPT
// =============================================================================

@target(javascript)
fn platform_broadcast(
  handle: PubSubHandle(message),
  topic: String,
  bytes: BitArray,
  exclude: Option(String),
) -> Nil {
  ffi_broadcast(handle, topic, bytes, exclude)
}

@target(javascript)
fn platform_register(
  handle: PubSubHandle(message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  ffi_register(handle, client_id, send)
}

@target(javascript)
fn platform_start(
  initial_state: PubSubState(message),
) -> Result(PubSubHandle(message), Nil) {
  Ok(ffi_create_pub_sub(
    initial_state,
    handle_register_logic,
    handle_unregister_logic,
    handle_subscribe_logic,
    handle_unsubscribe_logic,
    handle_broadcast_logic,
  ))
}

@target(javascript)
fn platform_subscribe(
  handle: PubSubHandle(message),
  client_id: String,
  topic: String,
) -> Nil {
  ffi_subscribe(handle, client_id, topic)
}

@target(javascript)
fn platform_unregister(handle: PubSubHandle(message), client_id: String) -> Nil {
  ffi_unregister(handle, client_id)
}

@target(javascript)
fn platform_unsubscribe(
  handle: PubSubHandle(message),
  client_id: String,
  topic: String,
) -> Nil {
  ffi_unsubscribe(handle, client_id, topic)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./pub_sub.ffi.mjs", "broadcast")
fn ffi_broadcast(
  _handle: PubSubHandle(message),
  _topic: String,
  _bytes: BitArray,
  _exclude: Option(String),
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./pub_sub.ffi.mjs", "createPubSub")
fn ffi_create_pub_sub(
  _initial_state: PubSubState(message),
  _handle_register: fn(PubSubState(message), String, fn(BitArray) -> Nil) ->
    PubSubState(message),
  _handle_unregister: fn(PubSubState(message), String) -> PubSubState(message),
  _handle_subscribe: fn(PubSubState(message), String, String) ->
    PubSubState(message),
  _handle_unsubscribe: fn(PubSubState(message), String, String) ->
    PubSubState(message),
  _handle_broadcast: fn(PubSubState(message), String, BitArray, Option(String)) ->
    PubSubState(message),
) -> PubSubHandle(message) {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./pub_sub.ffi.mjs", "register")
fn ffi_register(
  _handle: PubSubHandle(message),
  _client_id: String,
  _send: fn(BitArray) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./pub_sub.ffi.mjs", "subscribe")
fn ffi_subscribe(
  _handle: PubSubHandle(message),
  _client_id: String,
  _topic: String,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./pub_sub.ffi.mjs", "unregister")
fn ffi_unregister(_handle: PubSubHandle(message), _client_id: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./pub_sub.ffi.mjs", "unsubscribe")
fn ffi_unsubscribe(
  _handle: PubSubHandle(message),
  _client_id: String,
  _topic: String,
) -> Nil {
  Nil
}
