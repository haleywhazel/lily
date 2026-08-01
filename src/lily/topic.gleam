//// Topics are basically ways for clients to listen to a certain broadcast
//// channel, similar to pub/sub patterns within other libraries like Phoenix.
//// This is useful for cases where your own model/store need to easily react
//// to other states shared between a few clients (e.g. chat rooms).
////
//// Lily provides two main types of topics, an ephemeral topic that simply
//// broadcasts [`Push`](./transport.html#Push) frames with no sequence and no
//// replay:
////
//// ```gleam
//// let assert Ok(typing) = topic.new(server, id: "typing")
//// // Broadcast from anywhere, server or client
//// topic.broadcast(typing, UserIsTyping(client_id))
//// ```
////
//// And also more stateful topics which have their own store. Pipe through
//// [`with_store`](#with_store) to make a topic stateful, the topic actor
//// reading its update logic from the server's `Wiring` and sends
//// [`TopicUpdate`](./transport.html#TopicUpdate) frames to
//// every subscriber:
////
//// ```gleam
//// let assert Ok(chat) = topic.new(server, id: "chat")
//// let chat =
////   chat
////   |> topic.with_store
////   |> topic.with_on_subscribe(fn(client_id) {
////     [Chat(UserJoined(client_id))]
////   })
//// ```
////
//// Making it stateful means the server owns the topic's state
//// authoritatively. It assigns a sequence number to every change, hands a
//// [`Snapshot`](./transport.html#Snapshot) to whoever subscribes so late
//// joiners catch up, and fans out a
//// [`TopicUpdate`](./transport.html#TopicUpdate) as the state changes. The
//// update logic isn't passed here, it's borrowed from the `store.topic(id:)`
//// entry in your shared `Wiring` whose id matches, so a `"chat"` topic reads
//// its update function and slice from `store.topic(id: "chat", ...)`. That one
//// entry is what links the server actor to the client's model slice, so the
//// same id shows up in the wiring, in `topic.new`, and in `client.subscribe`.
////
//// On the client you subscribe after connecting with
//// [`client.subscribe`](./client.html#subscribe), and the topic's slice is
//// hydrated from the snapshot when it arrives:
////
//// ```gleam
//// runtime
//// |> client.connect(with: connector)
//// |> client.subscribe("chat")
//// ```
////
//// After that, you don't wire up anything to consume updates. When a
//// [`TopicUpdate`](./transport.html#TopicUpdate) from a stateful topic or a
//// [`Push`](./transport.html#Push) from an ephemeral one lands, Lily runs the
//// payload through your `update` function exactly like a message you'd
//// dispatched locally, with the matching slice updates, your
//// [`client.on_message`](./client.html#on_message) hook fires, and the
//// affected components re-render.
////
//// With the `chat` topic set up on the backend (the `topic.new` plus
//// `with_store` from above), a client (frontend) sends by dispatching, which
//// the server fans out to the other subscribers as a TopicUpdate:
////
//// ```gleam
//// dispatch(Chat(NewChatMessage(body)))
//// ```
////
//// And consuming that update takes no extra code, a component slicing the
//// chat re-renders whether the change was local or a TopicUpdate from
//// elsewhere (another client/frontend):
////
//// ```gleam
//// component.simple(
////   slice: fn(model: Model) { model.chat },
////   render: fn(chat, _) { chat_view(chat) },
//// )
//// ```
////
//// For dynamic topics keyed by a parsed identifier (e.g. `"room:42"`), use
//// `topic.kind` to register a factory that creates topic actors on first
//// subscribe:
////
//// ```gleam
//// let assert Ok(_) =
////   topic.kind(
////     server,
////     prefix: "room:",
////     parse_id: int.parse,
////     configure: fn(room_id, topic) {
////       topic
////       |> topic.with_store
////       |> topic.with_can_subscribe(fn(client_id, _topic_id) {
////         auth.may_join_room(client_id, room_id) // your own helper
////       })
////     },
////   )
//// ```
////
//// On the wiring side this pairs with
//// [`store.topic_kind`](./store.html#topic_kind) rather than `store.topic`.
//// It binds the whole `"room:"` family to one keyed model slice, so a client
//// can be in several rooms at once and each outgoing message, incoming
//// update, and snapshot still lands on the right one. Back the slice with a
//// keyed collection like `Dict(String, RoomState)`, the key is the bit after
//// the prefix (`"42"` for `"room:42"`).

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bool
import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/result
import gleam/string
import lily/internal/actor_cell.{type Cell, Continue, Halt}
import lily/logging
import lily/server.{type Server, type ServerTopicEntry, ServerTopicEntry}
import lily/store
import lily/transport.{type Serialiser}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Phantom kind marker for ephemeral topics (broadcast only, no store).
pub type Ephemeral

/// Phantom kind marker for stateful topics (store + sequence + snapshot).
pub type Stateful

/// Opaque handle to a running topic. The `kind` phantom is `Ephemeral` after
/// `topic.new` and `Stateful` after `topic.with_store`, enforced at compile
/// time so `topic.dispatch` cannot be called on an ephemeral topic.
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

/// Send a `Push` frame to every subscriber. Ephemeral and stateful topics.
///
/// ```gleam
/// topic.broadcast(typing_topic, UserIsTyping(client_id))
/// ```
pub fn broadcast(topic: Topic(model, message, kind), message: message) -> Nil {
  actor_cell.send(topic.handle, Broadcast(message:, exclude: option.None))
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
  actor_cell.send(
    topic.handle,
    Broadcast(message:, exclude: option.Some(client_id)),
  )
}

/// Apply a message to the topic's store and emit
/// `TopicUpdate(id, seq, payload)` to every subscriber. Stateful topics only
/// (`with_store`), ephemeral topics fail at compile time.
///
/// ```gleam
/// topic.dispatch(chat_topic, Chat(NewChatMessage(body)))
/// ```
pub fn dispatch(topic: Topic(model, message, Stateful), message: message) -> Nil {
  actor_cell.send(topic.handle, Dispatch(from: option.None, message:))
}

/// Register a parametric topic kind. When a client subscribes to
/// `prefix <> suffix` and no fixed topic with that id exists, the server
/// parses the suffix via `parse_id` and calls `configure(parsed, topic)` on a
/// pre-started `Topic`.
///
/// Call `with_store`, `with_can_subscribe`, etc. inside `configure` and return
/// the result. Don't call `topic.new`, the actor is already started.
///
/// A stateful kind reads its store from the
/// [`store.topic_kind`](./store.html#topic_kind) wiring entry sharing this
/// `prefix`, keyed by instance, so every id in the family gets its own slot.
///
/// ```gleam
/// let assert Ok(_) =
///   topic.kind(
///     server,
///     prefix: "room:",
///     parse_id: int.parse,
///     configure: fn(room_id, topic) {
///       topic |> topic.with_store
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
        case actor_cell.start(initial_state, reduce:) {
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

/// Register a topic on the server. Returns an ephemeral (broadcast-only)
/// handle, pipe through `with_store` to make it stateful.
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
  use handle <- result.try(actor_cell.start(initial_state, reduce:))
  let entry = make_entry_from_handle(handle)
  use _ <- result.try(server.register_topic(server, id, entry))
  Ok(Topic(id:, handle:, server:))
}

/// Stop the topic actor and remove it from the server registry. Subscribers
/// stop receiving updates, last slice value left as-is. Further subscribes to
/// this id either error (fixed topic) or lazily reinstantiate (parametric
/// kind), the fresh topic then pushing a replacing snapshot on subscribe.
///
/// ```gleam
/// topic.stop(chat_topic)
/// ```
pub fn stop(topic: Topic(model, message, kind)) -> Nil {
  actor_cell.send(topic.handle, Stop)
  server.unregister_topic(topic.server, topic.id)
}

/// Add a subscriber (server-initiated). Client counterpart is
/// `client.subscribe`.
///
/// ```gleam
/// topic.subscribe(chat_topic, client_id)
/// ```
pub fn subscribe(topic: Topic(model, message, kind), client_id: String) -> Nil {
  server.do_subscribe(topic.server, client_id, topic.id)
}

/// Remove a subscriber.
///
/// ```gleam
/// topic.unsubscribe(chat_topic, client_id)
/// ```
pub fn unsubscribe(topic: Topic(model, message, kind), client_id: String) -> Nil {
  actor_cell.send(topic.handle, ClientUnsubscribe(client_id:))
}

/// Set an authorisation predicate for client-initiated subscribes.
/// Server-side `topic.subscribe` is trusted and unaffected. On `False`, the
/// server replies with `Rejected(topic_id, "denied")`.
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
  actor_cell.send(topic.handle, SetCanSubscribe(predicate:))
  topic
}

/// Set a join hook. Returned messages are broadcast (ephemeral) or dispatched
/// (stateful) right after the joiner receives its `Snapshot`, so it sees them
/// too.
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
  actor_cell.send(topic.handle, SetOnSubscribe(hook:))
  topic
}

/// Set a leave hook. Symmetric to `with_on_subscribe` and fires after the
/// subscriber is removed.
///
/// ```gleam
/// topic.with_on_unsubscribe(chat_topic, fn(_client_id) { [] })
/// ```
pub fn with_on_unsubscribe(
  topic: Topic(model, message, kind),
  hook: fn(String) -> List(message),
) -> Topic(model, message, kind) {
  actor_cell.send(topic.handle, SetOnUnsubscribe(hook:))
  topic
}

/// Upgrade an ephemeral topic to stateful by attaching a store. Update logic
/// and initial state come from the `store.topic(id: topic.id, ...)` entry in
/// the `store.Wiring` passed to `server.new`.
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
  actor_cell.send(topic.handle, UpgradeToStateful(initial:, apply_message:))
  Topic(id: topic.id, handle: topic.handle, server: topic.server)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

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

type TopicHandle(model, message) =
  Cell(TopicActorState(model, message), InternalEvent(model, message), Nil)

type TopicStore(model, message) {
  TopicStore(
    current: model,
    apply_message: fn(model, message) -> model,
    sequence: Int,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

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
          option.Some(_) | option.None -> send(push_frame)
        }
      })
    }
  }
  state
}

fn handle_dispatch_logic(
  state: TopicActorState(model, message),
  from: Option(String),
  message: message,
) -> TopicActorState(model, message) {
  // A client may only write to a topic it subscribes to (subscribing already
  // cleared `can_subscribe`). Server dispatches carry `from = None` and are
  // trusted. Unsubscribed client messages dropped silently.
  let authorised = case from {
    option.Some(client_id) -> dict.has_key(state.subscribers, client_id)
    option.None -> True
  }
  use <- bool.guard(when: !authorised, return: state)
  case state.store {
    // No store, so relay the message to other subscribers as a Push (no
    // sequence, no replay). Originator skipped, it already applied
    // optimistically. Fans out client-to-client signalling without a hook.
    option.None -> handle_broadcast_logic(state, message, from)
    option.Some(store) ->
      // A subscribed client can send a payload the update function cannot
      // match, so a crash here drops the frame, not the actor.
      case server.rescue(fn() { store.apply_message(store.current, message) }) {
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "lily: dropped malformed topic message on "
              <> state.id
              <> ": "
              <> reason,
          )
          state
        }
        Ok(new_model) -> {
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
              // Originator gets the ack, everyone else the update.
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

fn handle_upgrade_to_stateful_logic(
  state: TopicActorState(model, message),
  initial: model,
  apply_message: fn(model, message) -> model,
) -> TopicActorState(model, message) {
  let store = TopicStore(current: initial, apply_message:, sequence: 0)
  TopicActorState(..state, store: option.Some(store))
}

fn make_entry_from_handle(
  handle: TopicHandle(model, message),
) -> ServerTopicEntry(model, message) {
  ServerTopicEntry(
    handle_incoming: fn(client_id, message) {
      actor_cell.send(handle, Dispatch(from: option.Some(client_id), message:))
    },
    subscribe: fn(client_id, send) {
      actor_cell.send(handle, ClientSubscribe(client_id:, send:))
    },
    unsubscribe: fn(client_id) {
      actor_cell.send(handle, ClientUnsubscribe(client_id:))
    },
    send_snapshot: fn(send) { actor_cell.send(handle, SendSnapshot(send:)) },
    stop: fn() { actor_cell.send(handle, Stop) },
  )
}

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

fn reduce(
  event: InternalEvent(model, message),
  state: TopicActorState(model, message),
) -> actor_cell.Reduction(TopicActorState(model, message), Nil) {
  case event {
    ClientSubscribe(client_id:, send:) ->
      Continue(handle_subscribe_logic(state, client_id, send))

    ClientUnsubscribe(client_id:) ->
      Continue(handle_unsubscribe_logic(state, client_id))

    Dispatch(from:, message:) ->
      Continue(handle_dispatch_logic(state, from, message))

    Broadcast(message:, exclude:) ->
      Continue(handle_broadcast_logic(state, message, exclude))

    SendSnapshot(send:) -> Continue(handle_send_snapshot_logic(state, send))

    SetCanSubscribe(predicate:) ->
      Continue(handle_set_can_subscribe_logic(state, predicate))

    SetOnSubscribe(hook:) ->
      Continue(handle_set_on_subscribe_logic(state, hook))

    SetOnUnsubscribe(hook:) ->
      Continue(handle_set_on_unsubscribe_logic(state, hook))

    UpgradeToStateful(initial:, apply_message:) ->
      Continue(handle_upgrade_to_stateful_logic(state, initial, apply_message))

    Stop -> {
      handle_stop_logic(state)
      Halt(state)
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
