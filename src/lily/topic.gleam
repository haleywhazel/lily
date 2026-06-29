//// Ephemeral and stateful topics for server-to-client fan-out, similar to
//// pub/sub patterns within other libraries.
////
//// An ephemeral topic broadcasts `Push` frames with no sequence and no replay:
////
//// ```gleam
//// let assert Ok(typing) = topic.new(server, id: "typing")
//// // Broadcast from anywhere:
//// topic.broadcast(typing, UserIsTyping(client_id))
//// ```
////
//// Pipe through `with_store` to make it stateful, the topic actor reads its
//// update logic from the server's `Wiring` and sends `TopicUpdate` frames to
//// every subscriber:
////
//// ```gleam
//// let assert Ok(chat) =
////   topic.new(server, id: "chat")
////   |> topic.with_store
////   |> topic.with_on_subscribe(fn(client_id) {
////     [Chat(UserJoined(client_id))]
////   })
//// ```
////
//// For dynamic topics keyed by a parsed identifier (e.g. `"room:42"`), use
//// `topic.kind` to register a factory that creates topic actors on first
//// subscribe:
////
//// ```gleam
//// // `auth.may_join_room` is your own helper; Lily does not ship auth.
//// let assert Ok(_) =
////   topic.kind(
////     server,
////     prefix: "room:",
////     parse_id: int.parse,
////     configure: fn(room_id, topic) {
////       topic
////       |> topic.with_store
////       |> topic.with_can_subscribe(fn(client_id, _topic_id) {
////         auth.may_join_room(client_id, room_id)
////       })
////     },
////   )
//// ```

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/result
import gleam/string
import lily/server.{type Server, type ServerTopicEntry, ServerTopicEntry}
import lily/store
import lily/transport.{type Serialiser}

@target(erlang)
import gleam/erlang/process.{type Subject}
@target(erlang)
import gleam/otp/actor

@target(javascript)
import lily/internal/reference.{type Reference}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Phantom kind marker for ephemeral topics (broadcast only, no store).
pub type Ephemeral

/// Phantom kind marker for stateful topics (store + sequence + snapshot).
pub type Stateful

/// Opaque handle to a running topic. The `kind` phantom parameter is
/// `Ephemeral` after `topic.new` and `Stateful` after `topic.with_store`;
/// this is enforced at compile time so `topic.dispatch` cannot be called
/// on an ephemeral topic.
pub opaque type Topic(model, message, kind) {
  Topic(
    id: String,
    handle: TopicHandle(model, message),
    server: Server(model, message),
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Send a `Push` frame to every subscriber of this topic. Available on both
/// ephemeral and stateful topics.
///
/// ```gleam
/// topic.broadcast(typing_topic, UserIsTyping(client_id))
/// ```
pub fn broadcast(topic: Topic(model, message, kind), message: message) -> Nil {
  platform_broadcast(topic.handle, message, option.None)
}

/// Like `broadcast` but skips the originating client.
///
/// ```gleam
/// topic.broadcast_from(
///   typing_topic,
///   except: client_id,
///   message: UserIsTyping(client_id),
/// )
/// ```
pub fn broadcast_from(
  topic: Topic(model, message, kind),
  except client_id: String,
  message message: message,
) -> Nil {
  platform_broadcast(topic.handle, message, option.Some(client_id))
}

/// Apply a message to the topic's store and emit
/// `TopicUpdate(id, seq, payload)` to every subscriber. Only callable on
/// stateful topics (created via `with_store`); ephemeral topics fail at
/// compile time.
///
/// ```gleam
/// topic.dispatch(chat_topic, Chat(NewChatMessage(body)))
/// ```
pub fn dispatch(topic: Topic(model, message, Stateful), message: message) -> Nil {
  platform_dispatch(topic.handle, option.None, message)
}

/// Register a parametric topic kind. When a client subscribes to
/// `prefix <> suffix` and no fixed topic with that id exists, the server
/// parses the suffix via `parse_id` and calls `configure(parsed, topic)` to
/// configure a pre-started `Topic` lazily.
///
/// The pre-started topic is passed to `configure`. Call `with_store`,
/// `with_can_subscribe`, etc. on it and return the result. Do not call
/// `topic.new` inside `configure`; the topic actor is already started.
///
/// ```gleam
/// let assert Ok(_) =
///   topic.kind(
///     server,
///     prefix: "room:",
///     parse_id: int.parse,
///     configure: fn(room_id, topic) {
///       topic |> topic.with_store(...)
///     },
///   )
/// ```
pub fn kind(
  server: Server(model, message),
  prefix prefix: String,
  parse_id parse_id: fn(String) -> Result(parsed, Nil),
  configure configure: fn(parsed, Topic(model, message, Ephemeral)) ->
    Topic(model, message, kind),
) -> Result(Nil, Nil) {
  let create = fn(topic_id: String) -> option.Option(
    ServerTopicEntry(model, message),
  ) {
    let suffix = string.drop_start(topic_id, string.length(prefix))
    case parse_id(suffix) {
      Error(_) -> option.None
      Ok(parsed) -> {
        let #(_, serialiser, _) = server.internals(server)
        let initial_state = make_initial_state(topic_id, serialiser)
        case platform_start(initial_state) {
          Error(_) -> option.None
          Ok(handle) -> {
            let pre_topic = Topic(id: topic_id, handle:, server:)
            let configured = configure(parsed, pre_topic)
            option.Some(make_entry_from_handle(configured.handle))
          }
        }
      }
    }
  }
  server.register_topic_kind(server, prefix, create)
}

/// Register a topic on the given server. Returns an ephemeral handle
/// (broadcast-only) by default; pipe through `with_store` to make it
/// stateful.
///
/// ```gleam
/// let assert Ok(typing) = topic.new(server, id: "typing")
/// ```
pub fn new(
  server: Server(model, message),
  id id: String,
) -> Result(Topic(model, message, Ephemeral), Nil) {
  let #(_, serialiser, _) = server.internals(server)
  let initial_state = make_initial_state(id, serialiser)
  use handle <- result.try(platform_start(initial_state))
  let entry = make_entry_from_handle(handle)
  use _ <- result.try(server.register_topic(server, id, entry))
  Ok(Topic(id:, handle:, server:))
}

/// Stop the topic actor and remove it from the server registry.
/// Subscribers stop receiving updates; their last slice value is left as-is,
/// not reset. Further subscribes to this id either error (fixed topic) or
/// trigger lazy reinstantiation (parametric kind, if registered), in which
/// case the fresh topic pushes a snapshot on subscribe that replaces it.
///
/// ```gleam
/// topic.stop(chat_topic)
/// ```
pub fn stop(topic: Topic(model, message, kind)) -> Nil {
  platform_stop_actor(topic.handle)
  server.unregister_topic(topic.server, topic.id)
}

/// Add a subscriber. Server-initiated; the client-side counterpart is
/// `client.subscribe`. Idempotent.
///
/// ```gleam
/// topic.subscribe(chat_topic, client_id)
/// ```
pub fn subscribe(topic: Topic(model, message, kind), client_id: String) -> Nil {
  server.do_subscribe(topic.server, client_id, topic.id)
}

/// Remove a subscriber. Idempotent.
///
/// ```gleam
/// topic.unsubscribe(chat_topic, client_id)
/// ```
pub fn unsubscribe(topic: Topic(model, message, kind), client_id: String) -> Nil {
  platform_unsubscribe(topic.handle, client_id)
}

/// Set an authorisation predicate for client-initiated subscribes.
/// Server-side `topic.subscribe` is unaffected (it's trusted). On `False`,
/// the server replies with `Rejected(topic_id, "denied")`.
///
/// ```gleam
/// topic.with_can_subscribe(chat_topic, fn(client_id, _topic_id) {
///   auth.is_authenticated(client_id)
/// })
/// ```
pub fn with_can_subscribe(
  topic: Topic(model, message, kind),
  predicate: fn(String, String) -> Bool,
) -> Topic(model, message, kind) {
  platform_set_can_subscribe(topic.handle, predicate)
  topic
}

/// Set a join hook. Returned messages are broadcast (ephemeral topics) or
/// dispatched (stateful topics) immediately after the new subscriber receives
/// its `Snapshot`, so the joiner sees them too.
///
/// ```gleam
/// topic.with_on_subscribe(chat_topic, fn(client_id) {
///   [Chat(UserJoined(client_id))]
/// })
/// ```
pub fn with_on_subscribe(
  topic: Topic(model, message, kind),
  hook: fn(String) -> List(message),
) -> Topic(model, message, kind) {
  platform_set_on_subscribe(topic.handle, hook)
  topic
}

/// Set a leave hook. Symmetric to `with_on_subscribe`; fires after the
/// subscriber is removed. Common pattern: check the remaining subscriber count
/// and call `topic.stop` when empty for kind-instantiated topics.
///
/// ```gleam
/// topic.with_on_unsubscribe(chat_topic, fn(_client_id) { [] })
/// ```
pub fn with_on_unsubscribe(
  topic: Topic(model, message, kind),
  hook: fn(String) -> List(message),
) -> Topic(model, message, kind) {
  platform_set_on_unsubscribe(topic.handle, hook)
  topic
}

/// Upgrade an ephemeral topic to stateful by attaching a store. The update
/// logic and initial state are read from the `store.Wiring` that was passed
/// to `server.new`, specifically the `store.topic(id: topic.id, ...)` entry.
///
/// ```gleam
/// topic.new(server, id: "chat")
/// |> topic.with_store
/// ```
pub fn with_store(
  topic: Topic(model, message, Ephemeral),
) -> Topic(model, message, Stateful) {
  let #(initial, _, wiring) = server.internals(topic.server)
  let apply_message = case store.topic_apply(wiring, topic.id) {
    option.Some(f) -> f
    option.None -> fn(m, _) { m }
  }
  platform_upgrade_to_stateful(topic.handle, initial, apply_message)
  Topic(id: topic.id, handle: topic.handle, server: topic.server)
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn make_initial_state(
  id: String,
  serialiser: Serialiser(model, message),
) -> TopicActorState(model, message) {
  TopicActorState(
    id:,
    serialiser:,
    subscribers: dict.new(),
    store: option.None,
    can_subscribe: fn(_, _) { True },
    on_subscribe: fn(_) { [] },
    on_unsubscribe: fn(_) { [] },
  )
}

fn make_entry_from_handle(
  handle: TopicHandle(model, message),
) -> ServerTopicEntry(model, message) {
  ServerTopicEntry(
    handle_incoming: fn(client_id, message) {
      platform_dispatch(handle, option.Some(client_id), message)
    },
    subscribe: fn(client_id, send) {
      platform_subscribe(handle, client_id, send)
    },
    unsubscribe: fn(client_id) { platform_unsubscribe(handle, client_id) },
    send_snapshot: fn(send) { platform_send_snapshot(handle, send) },
    stop: fn() { platform_stop_actor(handle) },
  )
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

type TopicActorState(model, message) {
  TopicActorState(
    id: String,
    serialiser: Serialiser(model, message),
    subscribers: Dict(String, fn(BitArray) -> Nil),
    store: Option(TopicStore(model, message)),
    can_subscribe: fn(String, String) -> Bool,
    on_subscribe: fn(String) -> List(message),
    on_unsubscribe: fn(String) -> List(message),
  )
}

type TopicStore(model, message) {
  TopicStore(
    current: model,
    apply_message: fn(model, message) -> model,
    sequence: Int,
  )
}

@target(erlang)
type TopicHandle(model, message) =
  Subject(InternalEvent(model, message))

@target(javascript)
type TopicHandle(model, message) =
  Reference(Option(TopicActorState(model, message)))

@target(erlang)
type InternalEvent(model, message) {
  ClientSubscribe(client_id: String, send: fn(BitArray) -> Nil)
  ClientUnsubscribe(client_id: String)
  Dispatch(from: Option(String), message: message)
  Broadcast(message: message, exclude: Option(String))
  SendSnapshot(send: fn(BitArray) -> Nil)
  SetCanSubscribe(predicate: fn(String, String) -> Bool)
  SetOnSubscribe(hook: fn(String) -> List(message))
  SetOnUnsubscribe(hook: fn(String) -> List(message))
  UpgradeToStateful(initial: model, apply_message: fn(model, message) -> model)
  Stop
}

fn handle_subscribe_logic(
  state: TopicActorState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  let authorised = state.can_subscribe(client_id, state.id)
  case authorised {
    False -> {
      let rejected_frame =
        transport.encode(
          transport.Rejected(topic_id: state.id, reason: "denied"),
          serialiser: state.serialiser,
        )
      send(rejected_frame)
      state
    }
    True -> {
      let subscribers = dict.insert(state.subscribers, client_id, send)
      let state = TopicActorState(..state, subscribers:)
      let state = case state.store {
        option.None -> state
        option.Some(store) -> {
          send(snapshot_frame(state, store))
          state
        }
      }
      handle_hook_messages(state, state.on_subscribe(client_id), option.None)
    }
  }
}

fn handle_unsubscribe_logic(
  state: TopicActorState(model, message),
  client_id: String,
) -> TopicActorState(model, message) {
  let subscribers = dict.delete(state.subscribers, client_id)
  let state = TopicActorState(..state, subscribers:)
  handle_hook_messages(state, state.on_unsubscribe(client_id), option.None)
}

fn handle_dispatch_logic(
  state: TopicActorState(model, message),
  from: Option(String),
  message: message,
) -> TopicActorState(model, message) {
  case state.store {
    option.None -> state
    option.Some(store) -> {
      let new_model = store.apply_message(store.current, message)
      let new_seq = store.sequence + 1
      case dict.is_empty(state.subscribers) {
        True -> Nil
        False -> {
          let update_frame =
            transport.encode(
              transport.TopicUpdate(
                topic_id: state.id,
                sequence: new_seq,
                payload: message,
              ),
              serialiser: state.serialiser,
            )
          let ack_frame =
            transport.encode(
              transport.Acknowledge(
                target: transport.Topic(state.id),
                sequence: new_seq,
              ),
              serialiser: state.serialiser,
            )
          // Originator gets the ack; everyone else gets the update.
          dict.each(state.subscribers, fn(id, send) {
            case from {
              option.Some(sender) if sender == id -> send(ack_frame)
              option.Some(_) | option.None -> send(update_frame)
            }
          })
        }
      }
      let store = TopicStore(..store, current: new_model, sequence: new_seq)
      TopicActorState(..state, store: option.Some(store))
    }
  }
}

fn handle_broadcast_logic(
  state: TopicActorState(model, message),
  message: message,
  exclude: Option(String),
) -> TopicActorState(model, message) {
  case dict.is_empty(state.subscribers) {
    True -> Nil
    False -> {
      let push_frame =
        transport.encode(
          transport.Push(topic_id: state.id, payload: message),
          serialiser: state.serialiser,
        )
      dict.each(state.subscribers, fn(id, send) {
        case exclude {
          option.Some(excluded) if excluded == id -> Nil
          option.Some(_) -> send(push_frame)
          option.None -> send(push_frame)
        }
      })
    }
  }
  state
}

fn handle_send_snapshot_logic(
  state: TopicActorState(model, message),
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  case state.store {
    option.None -> state
    option.Some(store) -> {
      send(snapshot_frame(state, store))
      state
    }
  }
}

fn snapshot_frame(
  state: TopicActorState(model, message),
  store: TopicStore(model, message),
) -> BitArray {
  transport.encode(
    transport.Snapshot(
      target: transport.Topic(state.id),
      sequence: store.sequence,
      state: store.current,
    ),
    serialiser: state.serialiser,
  )
}

fn handle_hook_messages(
  state: TopicActorState(model, message),
  messages: List(message),
  exclude: Option(String),
) -> TopicActorState(model, message) {
  case messages {
    [] -> state
    [message, ..rest] -> {
      let state = case state.store {
        option.Some(_) -> handle_dispatch_logic(state, exclude, message)
        option.None -> handle_broadcast_logic(state, message, exclude)
      }
      handle_hook_messages(state, rest, exclude)
    }
  }
}

fn handle_stop_logic(state: TopicActorState(model, message)) -> Nil {
  let seq = case state.store {
    option.Some(store) -> store.sequence
    option.None -> 0
  }
  let ack_frame =
    transport.encode(
      transport.Acknowledge(target: transport.Topic(state.id), sequence: seq),
      serialiser: state.serialiser,
    )
  dict.each(state.subscribers, fn(_id, send) { send(ack_frame) })
}

fn handle_set_can_subscribe_logic(
  state: TopicActorState(model, message),
  predicate: fn(String, String) -> Bool,
) -> TopicActorState(model, message) {
  TopicActorState(..state, can_subscribe: predicate)
}

fn handle_set_on_subscribe_logic(
  state: TopicActorState(model, message),
  hook: fn(String) -> List(message),
) -> TopicActorState(model, message) {
  TopicActorState(..state, on_subscribe: hook)
}

fn handle_set_on_unsubscribe_logic(
  state: TopicActorState(model, message),
  hook: fn(String) -> List(message),
) -> TopicActorState(model, message) {
  TopicActorState(..state, on_unsubscribe: hook)
}

fn handle_upgrade_to_stateful_logic(
  state: TopicActorState(model, message),
  initial: model,
  apply_message: fn(model, message) -> model,
) -> TopicActorState(model, message) {
  let store = TopicStore(current: initial, apply_message:, sequence: 0)
  TopicActorState(..state, store: option.Some(store))
}

@target(erlang)
fn handle_message(
  state: TopicActorState(model, message),
  event: InternalEvent(model, message),
) -> actor.Next(TopicActorState(model, message), InternalEvent(model, message)) {
  case event {
    ClientSubscribe(client_id:, send:) ->
      handle_subscribe_logic(state, client_id, send) |> actor.continue

    ClientUnsubscribe(client_id:) ->
      handle_unsubscribe_logic(state, client_id) |> actor.continue

    Dispatch(from:, message:) ->
      handle_dispatch_logic(state, from, message) |> actor.continue

    Broadcast(message:, exclude:) ->
      handle_broadcast_logic(state, message, exclude) |> actor.continue

    SendSnapshot(send:) ->
      handle_send_snapshot_logic(state, send) |> actor.continue

    SetCanSubscribe(predicate:) ->
      handle_set_can_subscribe_logic(state, predicate) |> actor.continue

    SetOnSubscribe(hook:) ->
      handle_set_on_subscribe_logic(state, hook) |> actor.continue

    SetOnUnsubscribe(hook:) ->
      handle_set_on_unsubscribe_logic(state, hook) |> actor.continue

    UpgradeToStateful(initial:, apply_message:) ->
      handle_upgrade_to_stateful_logic(state, initial, apply_message)
      |> actor.continue

    Stop -> {
      handle_stop_logic(state)
      actor.stop()
    }
  }
}

@target(erlang)
fn platform_broadcast(
  handle: TopicHandle(model, message),
  message: message,
  exclude: Option(String),
) -> Nil {
  actor.send(handle, Broadcast(message:, exclude:))
}

@target(erlang)
fn platform_dispatch(
  handle: TopicHandle(model, message),
  from: Option(String),
  message: message,
) -> Nil {
  actor.send(handle, Dispatch(from:, message:))
}

@target(erlang)
fn platform_send_snapshot(
  handle: TopicHandle(model, message),
  send: fn(BitArray) -> Nil,
) -> Nil {
  actor.send(handle, SendSnapshot(send:))
}

@target(erlang)
fn platform_set_can_subscribe(
  handle: TopicHandle(model, message),
  predicate: fn(String, String) -> Bool,
) -> Nil {
  actor.send(handle, SetCanSubscribe(predicate:))
}

@target(erlang)
fn platform_set_on_subscribe(
  handle: TopicHandle(model, message),
  hook: fn(String) -> List(message),
) -> Nil {
  actor.send(handle, SetOnSubscribe(hook:))
}

@target(erlang)
fn platform_set_on_unsubscribe(
  handle: TopicHandle(model, message),
  hook: fn(String) -> List(message),
) -> Nil {
  actor.send(handle, SetOnUnsubscribe(hook:))
}

@target(erlang)
fn platform_start(
  initial_state: TopicActorState(model, message),
) -> Result(TopicHandle(model, message), Nil) {
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Nil)
}

@target(erlang)
fn platform_stop_actor(handle: TopicHandle(model, message)) -> Nil {
  actor.send(handle, Stop)
}

@target(erlang)
fn platform_subscribe(
  handle: TopicHandle(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  actor.send(handle, ClientSubscribe(client_id:, send:))
}

@target(erlang)
fn platform_unsubscribe(
  handle: TopicHandle(model, message),
  client_id: String,
) -> Nil {
  actor.send(handle, ClientUnsubscribe(client_id:))
}

@target(erlang)
fn platform_upgrade_to_stateful(
  handle: TopicHandle(model, message),
  initial: model,
  apply_message: fn(model, message) -> model,
) -> Nil {
  actor.send(handle, UpgradeToStateful(initial:, apply_message:))
}

@target(javascript)
fn modify(
  handle: TopicHandle(model, message),
  update: fn(TopicActorState(model, message)) -> TopicActorState(model, message),
) -> Nil {
  case reference.get(handle) {
    option.Some(state) -> reference.set(handle, option.Some(update(state)))
    option.None -> Nil
  }
}

@target(javascript)
fn platform_broadcast(
  handle: TopicHandle(model, message),
  message: message,
  exclude: Option(String),
) -> Nil {
  modify(handle, handle_broadcast_logic(_, message, exclude))
}

@target(javascript)
fn platform_dispatch(
  handle: TopicHandle(model, message),
  from: Option(String),
  message: message,
) -> Nil {
  modify(handle, handle_dispatch_logic(_, from, message))
}

@target(javascript)
fn platform_send_snapshot(
  handle: TopicHandle(model, message),
  send: fn(BitArray) -> Nil,
) -> Nil {
  modify(handle, handle_send_snapshot_logic(_, send))
}

@target(javascript)
fn platform_set_can_subscribe(
  handle: TopicHandle(model, message),
  predicate: fn(String, String) -> Bool,
) -> Nil {
  modify(handle, handle_set_can_subscribe_logic(_, predicate))
}

@target(javascript)
fn platform_set_on_subscribe(
  handle: TopicHandle(model, message),
  hook: fn(String) -> List(message),
) -> Nil {
  modify(handle, handle_set_on_subscribe_logic(_, hook))
}

@target(javascript)
fn platform_set_on_unsubscribe(
  handle: TopicHandle(model, message),
  hook: fn(String) -> List(message),
) -> Nil {
  modify(handle, handle_set_on_unsubscribe_logic(_, hook))
}

@target(javascript)
fn platform_start(
  initial_state: TopicActorState(model, message),
) -> Result(TopicHandle(model, message), Nil) {
  Ok(reference.make(option.Some(initial_state)))
}

@target(javascript)
fn platform_stop_actor(handle: TopicHandle(model, message)) -> Nil {
  case reference.get(handle) {
    option.Some(state) -> {
      handle_stop_logic(state)
      reference.set(handle, option.None)
    }
    option.None -> Nil
  }
}

@target(javascript)
fn platform_subscribe(
  handle: TopicHandle(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  modify(handle, handle_subscribe_logic(_, client_id, send))
}

@target(javascript)
fn platform_unsubscribe(
  handle: TopicHandle(model, message),
  client_id: String,
) -> Nil {
  modify(handle, handle_unsubscribe_logic(_, client_id))
}

@target(javascript)
fn platform_upgrade_to_stateful(
  handle: TopicHandle(model, message),
  initial: model,
  apply_message: fn(model, message) -> model,
) -> Nil {
  modify(handle, handle_upgrade_to_stateful_logic(_, initial, apply_message))
}
