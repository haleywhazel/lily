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
////   |> topic.on_subscribe(fn(client_id) {
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
////       |> topic.can_subscribe(fn(client_id, _topic_id, session) {
////         auth.may_join_room(session, room_id) // your own helper
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
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import lily/internal/actor_cell.{type Cell, Continue, Halt, Reply}
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
///
/// `config` is the configuration the topic was given, in order, so a topic
/// that comes back from a crash comes back configured. `fixed` is `False` for
/// a topic created by a parametric [`kind`](#kind), which rebuilds itself
/// through its own factory instead.
pub opaque type Topic(model, message, kind) {
  Topic(
    id: String,
    handle: TopicHandle(model, message),
    server: Server(model, message),
    config: List(InternalEvent(model, message)),
    fixed: Bool,
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

/// Set an authorisation predicate for client-initiated subscribes. It receives
/// the client id, the topic id, and that connection's session model, which is
/// where whatever the transport seeded at connect time lives, so the decision
/// can read the signed-in user rather than the id alone. Server-side
/// `topic.subscribe` is trusted and unaffected. On `False`, the server replies
/// with `Rejected(topic_id, "denied")`.
///
/// ```gleam
/// topic.can_subscribe(chat_topic, fn(_client_id, _topic_id, session) {
///   session.user != option.None
/// })
/// ```
pub fn can_subscribe(
  topic: Topic(model, message, kind),
  predicate predicate: fn(String, String, model) -> Bool,
) -> Topic(model, message, kind) {
  let config = record(topic, SetCanSubscribe(predicate:))
  Topic(..topic, config:)
}

/// Apply a message to the topic's store and emit
/// `TopicUpdate(id, seq, payload)` to every subscriber. Stateful topics only
/// (`with_store`), ephemeral topics fail at compile time.
///
/// ```gleam
/// topic.dispatch(chat_topic, Chat(NewChatMessage(body)))
/// ```
pub fn dispatch(
  topic: Topic(model, message, Stateful),
  message: message,
) -> Nil {
  actor_cell.send(topic.handle, Dispatch(from: option.None, message:))
}

/// Register a parametric topic kind. When a client subscribes to
/// `prefix <> suffix` and no fixed topic with that id exists, the server
/// parses the suffix via `parse_id` and calls `configure(parsed, topic)` on a
/// pre-started `Topic`.
///
/// Call `with_store`, `can_subscribe`, etc. inside `configure` and return
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
  server.register_topic_kind(server, prefix, fn(topic_id) {
    create_parametric(server, prefix, parse_id, configure, topic_id)
  })
}

/// Register a topic on the server. Returns an ephemeral (broadcast-only)
/// handle, pipe through `with_store` to make it stateful.
///
/// ```gleam
/// let assert Ok(typing) = topic.new(server, id: "typing")
/// ```
///
/// Each step records itself on the returned topic so a supervised server can
/// rebuild the topic after a crash, and a step applied to a stale binding
/// records only what that binding knew.
///
/// ```gleam
/// // records with_store and can_subscribe
/// let assert Ok(chat) =
///   topic.new(server, id: "chat")
///   |> result.map(topic.with_store)
///   |> result.map(topic.can_subscribe(_, predicate))
/// ```
///
/// A topic that comes back from a crash comes back at sequence 0 with the
/// initial model, and its subscribers receive a replacing `Snapshot`. The
/// state it held is genuinely lost. Persist anything you need to survive a
/// crash yourself.
pub fn new(
  server: Server(model, message),
  id id: String,
) -> Result(Topic(model, message, Ephemeral), Nil) {
  let #(_, serialiser, _) = server.internals(server)
  let initial_state = make_initial_state(id, serialiser)
  use handle <- result.try(actor_cell.start_in_supervisor(
    server.supervisor(server),
    initial_state,
    reduce:,
  ))
  let entry = make_entry(server, id, handle, [])
  use _ <- result.try(server.register_topic(server, id, entry))
  Ok(Topic(id:, handle:, server:, config: [], fixed: True))
}

/// Set a join hook. Returned messages are broadcast (ephemeral) or dispatched
/// (stateful) right after the joiner receives its `Snapshot`, so it sees them
/// too.
///
/// ```gleam
/// topic.on_subscribe(chat_topic, fn(client_id) {
///   [Chat(UserJoined(client_id))]
/// })
/// ```
pub fn on_subscribe(
  topic: Topic(model, message, kind),
  hook: fn(String) -> List(message),
) -> Topic(model, message, kind) {
  let config = record(topic, SetOnSubscribe(hook:))
  Topic(..topic, config:)
}

/// Set a leave hook. Symmetric to `on_subscribe` and fires after the
/// subscriber is removed.
///
/// ```gleam
/// topic.on_unsubscribe(chat_topic, fn(_client_id) { [] })
/// ```
pub fn on_unsubscribe(
  topic: Topic(model, message, kind),
  hook: fn(String) -> List(message),
) -> Topic(model, message, kind) {
  let config = record(topic, SetOnUnsubscribe(hook:))
  Topic(..topic, config:)
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
/// `client.subscribe`. This path is trusted, so any `can_subscribe` predicate
/// is skipped, the server has already decided.
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
pub fn unsubscribe(
  topic: Topic(model, message, kind),
  client_id: String,
) -> Nil {
  actor_cell.send(topic.handle, ClientUnsubscribe(client_id:))
}

/// Upgrade an ephemeral topic to stateful by attaching a store. Update logic
/// and initial state come from the `store.topic(id: topic.id, ...)` entry in
/// the `store.Wiring` passed to `server.start`.
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
  let config = record(topic, UpgradeToStateful(initial:, apply_message:))
  Topic(
    id: topic.id,
    handle: topic.handle,
    server: topic.server,
    config:,
    fixed: topic.fixed,
  )
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Number of clients currently subscribed to this topic. Test-only accessor.
@internal
pub fn subscriber_count(topic: Topic(model, message, kind)) -> Int {
  actor_cell.call(topic.handle, SubscriberCount, default: -1)
}

/// The process running this topic, so it can be watched or, in tests, killed.
@internal
pub fn watched(topic: Topic(model, message, kind)) -> actor_cell.Watched {
  actor_cell.watched(topic.handle)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

type InternalEvent(model, message) {
  ClientSubscribe(client_id: String, session: model, send: fn(BitArray) -> Nil)
  ClientUnsubscribe(client_id: String)
  Dispatch(from: Option(String), message: message)
  Broadcast(message: message, exclude: Option(String))
  // re-attach after a crash, so the join hooks must not run again
  RejoinSubscriber(client_id: String, send: fn(BitArray) -> Nil)
  SendSnapshot(send: fn(BitArray) -> Nil)
  // no session field, the trusted path has nothing to authorise against
  ServerSubscribe(client_id: String, send: fn(BitArray) -> Nil)
  SetCanSubscribe(predicate: fn(String, String, model) -> Bool)
  SetOnSubscribe(hook: fn(String) -> List(message))
  SetOnUnsubscribe(hook: fn(String) -> List(message))
  SubscriberCount
  UpgradeToStateful(initial: model, apply_message: fn(model, message) -> model)
  Stop
}

type TopicActorState(model, message) {
  TopicActorState(
    id: String,
    serialiser: Serialiser(model, message),
    subscribers: Dict(String, fn(BitArray) -> Nil),
    store: Option(TopicStore(model, message)),
    can_subscribe: fn(String, String, model) -> Bool,
    on_subscribe: fn(String) -> List(message),
    on_unsubscribe: fn(String) -> List(message),
  )
}

type TopicHandle(model, message) =
  Cell(TopicActorState(model, message), InternalEvent(model, message), Int)

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

/// Add a subscriber unconditionally, send it the snapshot, then run the join
/// hook. Shared by the gated client path and the trusted server path, which
/// differ only in whether `can_subscribe` runs first.
fn admit_subscriber(
  state: TopicActorState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  let subscribers = dict.insert(state.subscribers, client_id, send)
  let state = TopicActorState(..state, subscribers:)
  maybe_send_snapshot(state, send)
  handle_hook_messages(state, state.on_subscribe(client_id), option.None)
}

/// Start and configure one instance of a parametric topic. Also the respawn
/// path, so it names itself rather than closing over a local, which is why it
/// carries every argument `kind` was given.
fn create_parametric(
  server: Server(model, message),
  prefix: String,
  parse_id: fn(String) -> Result(parsed, Nil),
  configure: fn(parsed, Topic(model, message, Ephemeral)) ->
    Topic(model, message, kind),
  topic_id: String,
) -> Option(ServerTopicEntry(model, message)) {
  let suffix = string.drop_start(topic_id, string.length(prefix))
  case parse_id(suffix) {
    Error(_) -> option.None
    Ok(parsed) -> {
      let #(_, serialiser, _) = server.internals(server)
      let initial_state = make_initial_state(topic_id, serialiser)
      case
        actor_cell.start_in_supervisor(
          server.supervisor(server),
          initial_state,
          reduce:,
        )
      {
        Error(_) -> option.None
        Ok(handle) -> {
          let pre_topic =
            Topic(id: topic_id, handle:, server:, config: [], fixed: False)
          let configured = configure(parsed, pre_topic)
          // the fixed path watches from `server.register_topic`, but a
          // parametric topic is created inside the server's own reducer, so
          // the watch is issued here instead
          let _ =
            server.watch_topic(
              server,
              topic_id,
              actor_cell.watched(configured.handle),
            )
          option.Some(
            ServerTopicEntry(
              ..make_entry(server, topic_id, configured.handle, []),
              respawn: fn() {
                create_parametric(server, prefix, parse_id, configure, topic_id)
              },
            ),
          )
        }
      }
    }
  }
}

/// Encode a protocol frame with the topic actor's serialiser.
fn encode_frame(
  state: TopicActorState(model, message),
  frame: transport.Protocol(model, message),
) -> BitArray {
  transport.encode(frame, serialiser: state.serialiser)
}

fn handle_broadcast_logic(
  state: TopicActorState(model, message),
  message: message,
  exclude: Option(String),
) -> TopicActorState(model, message) {
  let push_frame =
    encode_frame(state, transport.Push(topic_id: state.id, payload: message))
  send_to_subscribers(state.subscribers, exclude, option.None, push_frame)
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
    option.Some(topic_store) ->
      // A subscribed client can send a payload the update function cannot
      // match, so a crash here drops the frame, not the actor.
      case
        server.rescue(fn() {
          topic_store.apply_message(topic_store.current, message)
        })
      {
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
          let new_seq = topic_store.sequence + 1
          let update_frame =
            encode_frame(
              state,
              transport.TopicUpdate(
                topic_id: state.id,
                sequence: new_seq,
                payload: message,
              ),
            )
          let ack_frame =
            encode_frame(
              state,
              transport.Acknowledge(
                target: transport.Topic(state.id),
                sequence: new_seq,
              ),
            )
          // Originator gets the ack, everyone else the update.
          send_to_subscribers(
            state.subscribers,
            from,
            option.Some(ack_frame),
            update_frame,
          )
          let topic_store =
            TopicStore(..topic_store, current: new_model, sequence: new_seq)
          TopicActorState(..state, store: option.Some(topic_store))
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

/// Re-attach a subscriber the server had already authorised, after this topic
/// came back from a crash. Identical to `admit_subscriber` except that the
/// join hooks do not run, so a chat topic's `UserJoined` is not replayed for
/// every subscriber on every crash.
fn handle_rejoin_logic(
  state: TopicActorState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  let subscribers = dict.insert(state.subscribers, client_id, send)
  let state = TopicActorState(..state, subscribers:)
  maybe_send_snapshot(state, send)
  state
}

fn handle_send_snapshot_logic(
  state: TopicActorState(model, message),
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  maybe_send_snapshot(state, send)
  state
}

/// The server-initiated subscribe. Identical to the client one except that
/// `can_subscribe` never runs, since the server has already made the call.
fn handle_server_subscribe_logic(
  state: TopicActorState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  admit_subscriber(state, client_id, send)
}

fn handle_set_can_subscribe_logic(
  state: TopicActorState(model, message),
  predicate: fn(String, String, model) -> Bool,
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
    encode_frame(
      state,
      transport.Acknowledge(target: transport.Topic(state.id), sequence: seq),
    )
  dict.each(state.subscribers, fn(_id, send) { send(ack_frame) })
}

fn handle_subscribe_logic(
  state: TopicActorState(model, message),
  client_id: String,
  session: model,
  send: fn(BitArray) -> Nil,
) -> TopicActorState(model, message) {
  case state.can_subscribe(client_id, state.id, session) {
    False -> {
      let rejected_frame =
        encode_frame(
          state,
          transport.Rejected(topic_id: state.id, reason: "denied"),
        )
      send(rejected_frame)
      state
    }
    True -> admit_subscriber(state, client_id, send)
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

/// The callbacks the server routes through, plus the closure that rebuilds
/// this topic from `config` after a crash.
fn make_entry(
  server: Server(model, message),
  id: String,
  handle: TopicHandle(model, message),
  config: List(InternalEvent(model, message)),
) -> ServerTopicEntry(model, message) {
  ServerTopicEntry(
    handle_incoming: fn(client_id, message) {
      actor_cell.send(handle, Dispatch(from: option.Some(client_id), message:))
    },
    rejoin: fn(client_id, send) {
      actor_cell.send(handle, RejoinSubscriber(client_id:, send:))
    },
    respawn: fn() { respawn_fixed(server, id, config) },
    subscribe: fn(client_id, session, send) {
      actor_cell.send(handle, ClientSubscribe(client_id:, session:, send:))
    },
    subscribe_trusted: fn(client_id, _session, send) {
      actor_cell.send(handle, ServerSubscribe(client_id:, send:))
    },
    unsubscribe: fn(client_id) {
      actor_cell.send(handle, ClientUnsubscribe(client_id:))
    },
    send_snapshot: fn(send) { actor_cell.send(handle, SendSnapshot(send:)) },
    stop: fn() { actor_cell.send(handle, Stop) },
    watched: actor_cell.watched(handle),
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
    can_subscribe: fn(_, _, _) { True },
    on_subscribe: fn(_) { [] },
    on_unsubscribe: fn(_) { [] },
  )
}

/// Send a snapshot to `send` when the topic is stateful, a no-op otherwise.
fn maybe_send_snapshot(
  state: TopicActorState(model, message),
  send: fn(BitArray) -> Nil,
) -> Nil {
  case state.store {
    option.None -> Nil
    option.Some(topic_store) -> send(snapshot_frame(state, topic_store))
  }
}

/// Apply one configuration step and record it, so a supervised server can
/// replay the whole chain onto a fresh process. Parametric topics rebuild
/// through their own factory, so they record nothing.
fn record(
  topic: Topic(model, message, kind),
  event: InternalEvent(model, message),
) -> List(InternalEvent(model, message)) {
  actor_cell.send(topic.handle, event)
  let config = list.append(topic.config, [event])
  case topic.fixed {
    False -> Nil
    True ->
      server.set_topic_respawn(topic.server, topic.id, fn() {
        respawn_fixed(topic.server, topic.id, config)
      })
  }
  config
}

fn reduce(
  event: InternalEvent(model, message),
  state: TopicActorState(model, message),
) -> actor_cell.Outcome(TopicActorState(model, message), Int) {
  case event {
    ClientSubscribe(client_id:, session:, send:) ->
      Continue(handle_subscribe_logic(state, client_id, session, send))

    ClientUnsubscribe(client_id:) ->
      Continue(handle_unsubscribe_logic(state, client_id))

    Dispatch(from:, message:) ->
      Continue(handle_dispatch_logic(state, from, message))

    Broadcast(message:, exclude:) ->
      Continue(handle_broadcast_logic(state, message, exclude))

    RejoinSubscriber(client_id:, send:) ->
      Continue(handle_rejoin_logic(state, client_id, send))

    SendSnapshot(send:) -> Continue(handle_send_snapshot_logic(state, send))

    ServerSubscribe(client_id:, send:) ->
      Continue(handle_server_subscribe_logic(state, client_id, send))

    SetCanSubscribe(predicate:) ->
      Continue(handle_set_can_subscribe_logic(state, predicate))

    SetOnSubscribe(hook:) ->
      Continue(handle_set_on_subscribe_logic(state, hook))

    SetOnUnsubscribe(hook:) ->
      Continue(handle_set_on_unsubscribe_logic(state, hook))

    SubscriberCount -> Reply(state, dict.size(state.subscribers))

    UpgradeToStateful(initial:, apply_message:) ->
      Continue(handle_upgrade_to_stateful_logic(state, initial, apply_message))

    Stop -> {
      handle_stop_logic(state)
      Halt(state)
    }
  }
}

/// Rebuild a fixed topic on a fresh process, replaying its recorded
/// configuration in order and re-watching the new process. The state the old
/// one held is gone, so it starts at sequence 0 with the initial model.
fn respawn_fixed(
  server: Server(model, message),
  id: String,
  config: List(InternalEvent(model, message)),
) -> Option(ServerTopicEntry(model, message)) {
  let #(_, serialiser, _) = server.internals(server)
  let initial_state = make_initial_state(id, serialiser)
  case
    actor_cell.start_in_supervisor(
      server.supervisor(server),
      initial_state,
      reduce:,
    )
  {
    Error(_) -> option.None
    Ok(handle) -> {
      list.each(config, fn(event) { actor_cell.send(handle, event) })
      let _ = server.watch_topic(server, id, actor_cell.watched(handle))
      option.Some(make_entry(server, id, handle, config))
    }
  }
}

/// Fan a frame out to subscribers, guarding on empty. The originator, when
/// `Some`, receives `originator_frame` if that is `Some` and is skipped
/// otherwise. Everyone else receives `other_frame`.
fn send_to_subscribers(
  subscribers: Dict(String, fn(BitArray) -> Nil),
  originator: Option(String),
  originator_frame: Option(BitArray),
  other_frame: BitArray,
) -> Nil {
  use <- bool.guard(when: dict.is_empty(subscribers), return: Nil)
  dict.each(subscribers, fn(id, send) {
    case originator {
      option.Some(sender) if sender == id ->
        case originator_frame {
          option.Some(frame) -> send(frame)
          option.None -> Nil
        }
      option.Some(_) | option.None -> send(other_frame)
    }
  })
}

fn snapshot_frame(
  state: TopicActorState(model, message),
  store: TopicStore(model, message),
) -> BitArray {
  encode_frame(
    state,
    transport.Snapshot(
      target: transport.Topic(state.id),
      sequence: store.sequence,
      state: store.current,
    ),
  )
}
