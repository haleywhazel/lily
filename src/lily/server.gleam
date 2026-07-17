//// The [`Server`](#Server) is the authoritative half of a Lily app. It holds
//// the real state and routes every message a client sends to the right store,
//// either that client's own per-connection session store, or a named
//// [topic](./topic.html) store shared between clients. Clients apply their own
//// changes optimistically, the server has the final say and streams the
//// corrected state back, so the two stay in sync (see
//// [transport](./transport.html) for the frames that carry it).
////
//// It compiles for both targets, but not using the Erlang one means that you
//// aren't leveraging BEAM's model and a full-stack JS model might be better
//// suited.
////
//// You build a server with [`new`](#new), handing it the same three values
//// your client gets, the initial model, the serialiser, and the shared
//// [`Wiring`](./store.html#Wiring), then [`start`](#start) it and register
//// your topics with [`topic.new`](./topic.html#new):
////
//// ```gleam
//// import gleam/result
////
//// import lily/server
//// import lily/topic
////
//// pub fn main() {
////   let assert Ok(server) =
////     server.new(
////       initial: shared.initial_model(),
////       serialiser: shared.serialiser(),
////       wiring: shared.wiring(),
////     )
////     |> server.start
////
////   let assert Ok(_) =
////     topic.new(server, id: "chat")
////     |> result.map(topic.with_store)
//// }
//// ```
////
//// Handing those same three values to [`client.start`](./client.html#start) is
//// what makes both ends agree on the model, the update logic, and the wire
//// encoding, so define them once in your `shared` package and pass the same
//// values to each side. See [store](./store.html) for how the `Wiring` splits
//// the model into a session slice and topic slices.
////
//// The server never imports `mist` or `wisp`, it's completely
//// transport-agnostic (the same way Lustre leaves the transport to you), so
//// you wire it into whatever WebSocket or HTTP handler you're running with
//// three calls. Create a stable id for each connection with
//// [`generate_client_id`](#generate_client_id), register it with
//// [`connect`](#connect) (handing over the `send` callback the server uses to
//// push frames back to that one client), feed every inbound frame to
//// [`incoming`](#incoming), and call [`disconnect`](#disconnect) when the
//// socket closes:
////
//// ```gleam
//// let client_id = server.generate_client_id()
//// server.connect(server, client_id:, send: process.send(outgoing_subject, _))
////
//// // for every frame the socket receives:
//// server.incoming(server, client_id:, bytes:)
////
//// // when it closes:
//// server.disconnect(server, client_id:)
//// ```
////
//// From there most apps just need the lifecycle hooks.
//// [`on_connect`](#on_connect) and [`on_disconnect`](#on_disconnect) fire with
//// the client id for presence tracking or audit logging,
//// [`on_message`](#on_message) runs after each session message is applied
//// (giving you the decoded message, the whole model after the update, and the
//// client id, the natural home for side effects like writing to a database),
//// and [`on_topic_message`](#on_topic_message) fires for each client-incoming
//// topic message:
////
//// ```gleam
//// server.on_connect(server, fn(client_id) {
////   logging.info("client connected: " <> client_id)
//// })
////
//// server.on_message(server, fn(message, _model, _client_id) {
////   case message {
////     Session(SaveDocument(doc)) -> db.write(doc)
////     _ -> Nil
////   }
//// })
//// ```
////
//// When the server itself needs to change a client's state, rather than react
//// to something the client sent, reach for [`dispatch_to`](#dispatch_to). It
//// applies a message to one client's session store and pushes the update
//// straight back to them, ideal for seeding a session right after connect or
//// for delivering the result of some async work once it lands (it's safe to
//// call from any process, so spawn the slow thing and dispatch when it's
//// ready):
////
//// ```gleam
//// server.on_connect(server, fn(client_id) {
////   server.dispatch_to(server, client_id:, message: WelcomeUser(client_id))
//// })
//// ```
////
//// [`dispatch_to_all`](#dispatch_to_all) does the same to every connected
//// client at once, for a server-wide change that also mutates session state.
//// If you only want to send something out without touching session state,
//// broadcast through a [topic](./topic.html#broadcast) instead.
////
//// Shut a server down with [`stop`](#stop), which asks every topic to stop
//// first so subscribers' slices reset cleanly before the underlying actor
//// terminates.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import lily/logging
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

/// Builder returned by [`server.new`](#new). Pipe through
/// [`server.start`](#start).
@internal
pub opaque type Builder(model, message) {
  Builder(
    initial_model: model,
    serialiser: Serialiser(model, message),
    wiring: store.Wiring(model, message),
    max_topics: Int,
  )
}

/// Handle to a running Lily server. Wraps platform-specific internals
/// (OTP actor on Erlang, [`Reference`](./internal/reference.html#Reference)
/// cell on JavaScript). Also carries `serialiser` and `initial_model` for
/// zero-copy access by `topic.new`.
pub opaque type Server(model, message) {
  Server(
    handle: ServerHandle(model, message),
    serialiser: Serialiser(model, message),
    initial_model: model,
    wiring: store.Wiring(model, message),
  )
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

/// Callbacks registered by a topic actor so the server can route frames to it.
/// Created inside `topic.gleam`. Stored in the server's topic registry.
@internal
pub type ServerTopicEntry(model, message) {
  ServerTopicEntry(
    handle_incoming: fn(String, message) -> Nil,
    subscribe: fn(String, fn(BitArray) -> Nil) -> Nil,
    unsubscribe: fn(String) -> Nil,
    send_snapshot: fn(fn(BitArray) -> Nil) -> Nil,
    stop: fn() -> Nil,
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Register a client connection. The `send` callback is how the server pushes
/// frames back to this specific client.
///
/// ```gleam
/// server.connect(server, client_id: id, send: process.send(outgoing_subject, _))
/// ```
pub fn connect(
  server: Server(model, message),
  client_id client_id: String,
  send send: fn(BitArray) -> Nil,
) -> Nil {
  platform_connect(server.handle, client_id, send)
}

/// Unregister a client connection from the server and all subscribed topics.
pub fn disconnect(
  server: Server(model, message),
  client_id client_id: String,
) -> Nil {
  platform_disconnect(server.handle, client_id)
}

/// Apply `message` to the session store of one connected client and send a
/// `SessionUpdate` frame back to that client. Use for server-initiated
/// per-client updates, e.g. pushing a fresh slice after authentication, server
/// timers that affect one user, async DB results.
///
/// No-op if no client with `client_id` is currently connected. Safe to call
/// from any process, including spawned tasks, so spawn the slow work and
/// call `dispatch_to` when the result is ready.
///
/// ```gleam
/// server.on_connect(server, fn(client_id) {
///   server.dispatch_to(server, client_id:, message: WelcomeUser(client_id))
/// })
/// ```
pub fn dispatch_to(
  server: Server(model, message),
  client_id client_id: String,
  message message: message,
) -> Nil {
  platform_dispatch_to(server.handle, client_id, message)
}

/// Apply `message` to every connected client's session store and send each
/// of them a `SessionUpdate` frame. Use for server-wide announcements that
/// also mutate session state, such as forcing a feature-flag refresh. For
/// fire-and-forget broadcasts without session mutation, use a topic
/// instead.
///
/// ```gleam
/// server.dispatch_to_all(server, message: SystemBannerUpdated(banner))
/// ```
pub fn dispatch_to_all(
  server: Server(model, message),
  message message: message,
) -> Nil {
  platform_dispatch_to_all(server.handle, message)
}

/// Generate a cryptographically random 32-character hex client identifier.
/// Pair with [`connect`](#connect) so every connection carries a stable,
/// server-issued id.
///
/// ```gleam
/// let client_id = server.generate_client_id()
/// server.connect(server, client_id:, send:)
/// ```
pub fn generate_client_id() -> String {
  ffi_generate_client_id()
}

/// Process an incoming frame from a client. Decodes the frame and routes
/// it: `SessionMessage` to the session store, `TopicMessage`,
/// `Subscribe`, and `Unsubscribe` to the topic actor, `Resync` to a
/// per-target snapshot fan-out.
pub fn incoming(
  server: Server(model, message),
  client_id client_id: String,
  bytes bytes: BitArray,
) -> Nil {
  platform_incoming(server.handle, client_id, bytes)
}

/// Set the maximum number of live topic actors the server keeps at once. This
/// bounds client-driven topic creation through parametric kinds. The default
/// is generous enough that most servers never reach it. Raise it if your app
/// legitimately needs more concurrent topics.
///
/// ```gleam
/// server.new(initial:, serialiser:, wiring:)
/// |> server.max_topics(500_000)
/// ```
pub fn max_topics(
  builder: Builder(model, message),
  maximum: Int,
) -> Builder(model, message) {
  Builder(..builder, max_topics: maximum)
}

/// Start building a server. Provide the shared initial model (used as
/// the zero-state for per-connection session stores and for topic
/// snapshot construction) and the serialiser.
///
/// ```gleam
/// server.new(
///   initial: shared.initial_model(),
///   serialiser: shared.serialiser(),
///   wiring: shared.wiring(),
/// )
/// ```
pub fn new(
  initial initial: model,
  serialiser serialiser: Serialiser(model, message),
  wiring wiring: store.Wiring(model, message),
) -> Builder(model, message) {
  Builder(
    initial_model: initial,
    serialiser:,
    wiring:,
    max_topics: default_max_topics,
  )
}

/// Register a hook that runs after a client successfully connects, receiving
/// the client id assigned by the server. Use for presence tracking, audit
/// logging, or seeding the client's session via
/// [`dispatch_to`](#dispatch_to).
///
/// ```gleam
/// server.on_connect(server, fn(client_id) {
///   logging.info("client connected: " <> client_id)
/// })
/// ```
pub fn on_connect(
  server: Server(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  platform_set_connect_hook(server.handle, hook)
}

/// Register a hook that runs after a client disconnects, receiving the client
/// id that just left. Use for presence cleanup or audit logging.
///
/// ```gleam
/// server.on_disconnect(server, fn(client_id) {
///   logging.info("client disconnected: " <> client_id)
/// })
/// ```
pub fn on_disconnect(
  server: Server(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  platform_set_disconnect_hook(server.handle, hook)
}

/// Register a hook that runs after each session message is applied. Receives
/// the decoded message, the full outer model after the message has been
/// applied to this client's session store, and the originating client id.
///
/// ```gleam
/// server.on_message(server, fn(message, model, client_id) {
///   case message {
///     Session(SaveDocument(doc)) -> db.write(doc)
///     _ -> Nil
///   }
/// })
/// ```
pub fn on_message(
  server: Server(model, message),
  hook: fn(message, model, String) -> Nil,
) -> Nil {
  platform_set_hook(server.handle, hook)
}

/// Register a hook that runs for each client-incoming topic message. Receives
/// the decoded message, the topic id, and the originating client id. Fires
/// before the topic actor processes the message, regardless of whether the
/// topic is stateful, ephemeral, or unknown. Does not fire for
/// server-initiated `topic.dispatch` / `topic.broadcast` calls.
///
/// ```gleam
/// server.on_topic_message(server, fn(message, topic_id, _client_id) {
///   logging.auto_log(logging.Info, #(topic_id, message))
/// })
/// ```
pub fn on_topic_message(
  server: Server(model, message),
  hook: fn(message, String, String) -> Nil,
) -> Nil {
  platform_set_topic_message_hook(server.handle, hook)
}

/// Start the configured server.
///
/// Topics are added then afterwards via `topic.new(server, ...)`.
///
/// ```gleam
/// let assert Ok(server) =
///   server.new(
///     initial: shared.initial_model(),
///     serialiser: shared.serialiser(),
///     wiring: shared.wiring(),
///   )
///   |> server.start
/// ```
pub fn start(
  builder: Builder(model, message),
) -> Result(Server(model, message), Nil) {
  let initial_state =
    ServerState(
      initial_model: builder.initial_model,
      serialiser: builder.serialiser,
      session_apply: store.session_apply(builder.wiring),
      clients: dict.new(),
      sessions: dict.new(),
      topics: dict.new(),
      topic_kinds: [],
      on_connect_hook: fn(_) { Nil },
      on_disconnect_hook: fn(_) { Nil },
      on_message_hook: fn(_, _, _) { Nil },
      on_topic_message_hook: fn(_, _, _) { Nil },
      max_topics: builder.max_topics,
    )

  platform_start(initial_state)
  |> result.map(fn(handle) {
    Server(
      handle:,
      serialiser: builder.serialiser,
      initial_model: builder.initial_model,
      wiring: builder.wiring,
    )
  })
}

/// Stop a running server. Every registered topic actor is asked to stop
/// first, each subscriber receives a final `Acknowledge(Topic(id), seq)`
/// so client slices reset cleanly. The underlying server actor then
/// terminates (Erlang) or its `Reference` state cell is cleared
/// (JavaScript). Connected session clients receive no extra frame.
pub fn stop(server: Server(model, message)) -> Nil {
  platform_stop(server.handle)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Subscribe a client to a topic by routing through the server (so the server
/// can look up the client's send function).
@internal
pub fn do_subscribe(
  server: Server(model, message),
  client_id: String,
  topic_id: String,
) -> Nil {
  platform_do_subscribe(server.handle, client_id, topic_id)
}

/// Return the configuration values `topic.gleam` needs to build a topic actor:
/// the initial model (used to construct full-outer-model snapshots), the
/// serialiser (used to encode topic frames), and the wiring (used to look up
/// the apply function for a topic's id).
@internal
pub fn internals(
  server: Server(model, message),
) -> #(model, Serialiser(model, message), store.Wiring(model, message)) {
  #(server.initial_model, server.serialiser, server.wiring)
}

/// Register a topic entry under `id`. Returns `Error(Nil)` if `id` already
/// exists or collides with a registered kind prefix.
@internal
pub fn register_topic(
  server: Server(model, message),
  id: String,
  entry: ServerTopicEntry(model, message),
) -> Result(Nil, Nil) {
  platform_register_topic(server.handle, id, entry)
}

/// Register a parametric topic kind. When a client subscribes to a topic
/// id that starts with `prefix` and no fixed topic with that id exists,
/// `create` is called with the full topic id and must return a
/// `ServerTopicEntry` on success or `None` to reject. The entry is
/// inserted directly into the server state by `find_or_create_topic`, no
/// server callback is needed.
@internal
pub fn register_topic_kind(
  server: Server(model, message),
  prefix: String,
  create: fn(String) -> Option(ServerTopicEntry(model, message)),
) -> Result(Nil, Nil) {
  platform_register_topic_kind(server.handle, prefix, create)
}

/// Remove a topic entry from the server registry.
@internal
pub fn unregister_topic(server: Server(model, message), id: String) -> Nil {
  platform_unregister_topic(server.handle, id)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(erlang)
type ServerHandle(model, message) =
  Subject(InternalEvent(model, message))

@target(javascript)
type ServerHandle(model, message) =
  Reference(Option(ServerState(model, message)))

@target(erlang)
type InternalEvent(model, message) {
  ClientConnected(client_id: String, send: fn(BitArray) -> Nil)
  ClientDisconnected(client_id: String)
  DispatchToClient(client_id: String, message: message)
  DispatchToAllClients(message: message)
  Incoming(client_id: String, bytes: BitArray)
  SetConnectHook(hook: fn(String) -> Nil)
  SetDisconnectHook(hook: fn(String) -> Nil)
  SetHook(hook: fn(message, model, String) -> Nil)
  SetTopicMessageHook(hook: fn(message, String, String) -> Nil)
  RegisterTopic(
    id: String,
    entry: ServerTopicEntry(model, message),
    reply: Subject(Result(Nil, Nil)),
  )
  RegisterTopicKind(
    prefix: String,
    create: fn(String) -> Option(ServerTopicEntry(model, message)),
    reply: Subject(Result(Nil, Nil)),
  )
  UnregisterTopic(id: String)
  DoSubscribe(client_id: String, topic_id: String)
  Stop
}

type ConnectionState(model, message) {
  ConnectionState(model: model, sequence: Int)
}

type TopicKindEntry(model, message) {
  TopicKindEntry(
    prefix: String,
    create: fn(String) -> Option(ServerTopicEntry(model, message)),
  )
}

type ServerState(model, message) {
  ServerState(
    initial_model: model,
    serialiser: Serialiser(model, message),
    session_apply: Option(fn(model, message) -> model),
    clients: Dict(String, fn(BitArray) -> Nil),
    sessions: Dict(String, ConnectionState(model, message)),
    topics: Dict(String, ServerTopicEntry(model, message)),
    topic_kinds: List(TopicKindEntry(model, message)),
    on_connect_hook: fn(String) -> Nil,
    on_disconnect_hook: fn(String) -> Nil,
    on_message_hook: fn(message, model, String) -> Nil,
    on_topic_message_hook: fn(message, String, String) -> Nil,
    max_topics: Int,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

// Default cap on live topic actors, overridable with `server.max_topics`.
const default_max_topics = 100_000

fn handle_connect_logic(
  state: ServerState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> ServerState(model, message) {
  let clients = dict.insert(state.clients, client_id, send)
  let connection = ConnectionState(model: state.initial_model, sequence: 0)
  let sessions = dict.insert(state.sessions, client_id, connection)
  send(transport.encode(
    transport.Connected(client_id:),
    serialiser: state.serialiser,
  ))
  state.on_connect_hook(client_id)
  ServerState(..state, clients:, sessions:)
}

fn handle_disconnect_logic(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  dict.each(state.topics, fn(_id, entry) { entry.unsubscribe(client_id) })
  let clients = dict.delete(state.clients, client_id)
  let sessions = dict.delete(state.sessions, client_id)
  state.on_disconnect_hook(client_id)
  ServerState(..state, clients:, sessions:)
}

fn handle_dispatch_to_logic(
  state: ServerState(model, message),
  client_id: String,
  message: message,
) -> ServerState(model, message) {
  case dict.get(state.sessions, client_id), dict.get(state.clients, client_id) {
    Ok(connection), Ok(send) -> {
      let new_model = case state.session_apply {
        option.None -> connection.model
        option.Some(apply) -> apply(connection.model, message)
      }
      let new_sequence = connection.sequence + 1
      let frame =
        transport.encode(
          transport.SessionUpdate(sequence: new_sequence, payload: message),
          serialiser: state.serialiser,
        )
      send(frame)
      let sessions =
        dict.insert(
          state.sessions,
          client_id,
          ConnectionState(model: new_model, sequence: new_sequence),
        )
      ServerState(..state, sessions:)
    }
    _, _ -> state
  }
}

fn handle_dispatch_to_all_logic(
  state: ServerState(model, message),
  message: message,
) -> ServerState(model, message) {
  dict.fold(state.clients, state, fn(acc, client_id, _send) {
    handle_dispatch_to_logic(acc, client_id, message)
  })
}

fn handle_incoming_logic(
  state: ServerState(model, message),
  client_id: String,
  bytes: BitArray,
) -> ServerState(model, message) {
  case transport.decode(bytes, serialiser: state.serialiser) {
    Ok(transport.SessionMessage(payload:)) ->
      handle_session_message_logic(state, client_id, payload)

    Ok(transport.TopicMessage(topic_id:, payload:)) ->
      handle_topic_message_logic(state, client_id, topic_id, payload)

    Ok(transport.Subscribe(topic_id:)) ->
      handle_subscribe_logic(state, client_id, topic_id)

    Ok(transport.Unsubscribe(topic_id:)) ->
      handle_unsubscribe_logic(state, client_id, topic_id)

    Ok(transport.Resync(cursors:)) ->
      handle_resync_logic(state, client_id, cursors)

    // Server-to-client variants, never legitimately arrive on the server.
    Ok(transport.Acknowledge(_, _))
    | Ok(transport.Connected(_))
    | Ok(transport.Push(_, _))
    | Ok(transport.Rejected(_, _))
    | Ok(transport.SessionUpdate(_, _))
    | Ok(transport.Snapshot(_, _, _))
    | Ok(transport.TopicUpdate(_, _, _)) -> state

    Error(_) -> state
  }
}

fn handle_session_message_logic(
  state: ServerState(model, message),
  client_id: String,
  message: message,
) -> ServerState(model, message) {
  case dict.get(state.sessions, client_id) {
    Error(_) -> state
    Ok(connection) -> {
      let applied = case state.session_apply {
        option.None -> Ok(connection.model)
        option.Some(apply) -> rescue(fn() { apply(connection.model, message) })
      }
      case applied {
        // A crash means the frame decoded to a value the update function
        // cannot match. Drop it without acking, keeping the actor alive.
        Error(reason) -> {
          logging.warning(
            "lily: dropped malformed session message from "
            <> client_id
            <> ": "
            <> reason,
          )
          state
        }
        Ok(new_model) -> {
          let new_seq = connection.sequence + 1
          case dict.get(state.clients, client_id) {
            Ok(send) -> {
              let ack_frame =
                transport.encode(
                  transport.Acknowledge(
                    target: transport.Session,
                    sequence: new_seq,
                  ),
                  serialiser: state.serialiser,
                )
              send(ack_frame)
            }
            Error(_) -> Nil
          }
          state.on_message_hook(message, new_model, client_id)
          let sessions =
            dict.insert(
              state.sessions,
              client_id,
              ConnectionState(model: new_model, sequence: new_seq),
            )
          ServerState(..state, sessions:)
        }
      }
    }
  }
}

fn handle_topic_message_logic(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  message: message,
) -> ServerState(model, message) {
  state.on_topic_message_hook(message, topic_id, client_id)
  case find_or_create_topic(state, topic_id) {
    #(state, option.Some(entry)) -> {
      entry.handle_incoming(client_id, message)
      state
    }
    #(state, option.None) -> state
  }
}

fn handle_subscribe_logic(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(send) ->
      case find_or_create_topic(state, topic_id) {
        #(state, option.Some(entry)) -> {
          entry.subscribe(client_id, send)
          state
        }
        #(state, option.None) -> {
          let rejected_frame =
            transport.encode(
              transport.Rejected(topic_id:, reason: "not found"),
              serialiser: state.serialiser,
            )
          send(rejected_frame)
          state
        }
      }
  }
}

fn handle_unsubscribe_logic(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) -> entry.unsubscribe(client_id)
    Error(_) -> Nil
  }
  state
}

fn handle_resync_logic(
  state: ServerState(model, message),
  client_id: String,
  cursors: List(transport.Target),
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(send) -> {
      list.each(cursors, fn(target) {
        case target {
          transport.Session ->
            case dict.get(state.sessions, client_id) {
              Ok(connection) -> {
                let snapshot_frame =
                  transport.encode(
                    transport.Snapshot(
                      target: transport.Session,
                      sequence: connection.sequence,
                      state: connection.model,
                    ),
                    serialiser: state.serialiser,
                  )
                send(snapshot_frame)
              }
              Error(_) -> Nil
            }

          transport.Topic(id) ->
            case dict.get(state.topics, id) {
              Ok(entry) -> entry.send_snapshot(send)
              Error(_) -> Nil
            }
        }
      })
      state
    }
  }
}

fn handle_do_subscribe_logic(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id), dict.get(state.topics, topic_id) {
    Ok(send), Ok(entry) -> {
      entry.subscribe(client_id, send)
      state
    }
    _, _ -> state
  }
}

fn handle_register_topic_logic(
  state: ServerState(model, message),
  id: String,
  entry: ServerTopicEntry(model, message),
) -> #(ServerState(model, message), Result(Nil, Nil)) {
  let already_exists = case dict.get(state.topics, id) {
    Ok(_) -> True
    Error(_) -> False
  }
  // Both directions matter, `id="room:1"` collides with kind prefix
  // `"room:"`, and a fixed `id="room"` would shadow that prefix's first
  // character.
  let kind_collision =
    list.any(state.topic_kinds, fn(kind) {
      string.starts_with(id, kind.prefix) || string.starts_with(kind.prefix, id)
    })
  case already_exists || kind_collision {
    True -> #(state, Error(Nil))
    False -> {
      let topics = dict.insert(state.topics, id, entry)
      #(ServerState(..state, topics:), Ok(Nil))
    }
  }
}

fn handle_register_kind_logic(
  state: ServerState(model, message),
  prefix: String,
  create: fn(String) -> Option(ServerTopicEntry(model, message)),
) -> #(ServerState(model, message), Result(Nil, Nil)) {
  let topic_collision =
    list.any(dict.keys(state.topics), string.starts_with(_, prefix))
  let kind_collision = list.any(state.topic_kinds, fn(k) { k.prefix == prefix })
  case topic_collision || kind_collision {
    True -> #(state, Error(Nil))
    False -> {
      let kind = TopicKindEntry(prefix:, create:)
      let topic_kinds = [kind, ..state.topic_kinds]
      #(ServerState(..state, topic_kinds:), Ok(Nil))
    }
  }
}

fn handle_unregister_topic_logic(
  state: ServerState(model, message),
  id: String,
) -> ServerState(model, message) {
  let topics = dict.delete(state.topics, id)
  ServerState(..state, topics:)
}

fn handle_set_connect_hook_logic(
  state: ServerState(model, message),
  hook: fn(String) -> Nil,
) -> ServerState(model, message) {
  ServerState(..state, on_connect_hook: hook)
}

fn handle_set_disconnect_hook_logic(
  state: ServerState(model, message),
  hook: fn(String) -> Nil,
) -> ServerState(model, message) {
  ServerState(..state, on_disconnect_hook: hook)
}

fn handle_set_hook_logic(
  state: ServerState(model, message),
  hook: fn(message, model, String) -> Nil,
) -> ServerState(model, message) {
  ServerState(..state, on_message_hook: hook)
}

fn handle_set_topic_message_hook_logic(
  state: ServerState(model, message),
  hook: fn(message, String, String) -> Nil,
) -> ServerState(model, message) {
  ServerState(..state, on_topic_message_hook: hook)
}

/// Stop every registered topic actor (which sends a final
/// `Acknowledge(Topic(id), seq)` to each subscriber) before the server itself
/// goes away. Called from both the Erlang `Stop` arm and the JavaScript
/// `stop()` method.
fn handle_stop_logic(state: ServerState(model, message)) -> Nil {
  dict.each(state.topics, fn(_id, entry) { entry.stop() })
}

fn find_or_create_topic(
  state: ServerState(model, message),
  topic_id: String,
) -> #(ServerState(model, message), Option(ServerTopicEntry(model, message))) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) -> #(state, option.Some(entry))
    // Parametric topic ids come from the client, so refuse creation past the
    // cap to stop one client spawning topics without bound.
    Error(_) ->
      case dict.size(state.topics) >= state.max_topics {
        True -> #(state, option.None)
        False -> {
          let kind =
            list.find(state.topic_kinds, fn(k) {
              string.starts_with(topic_id, k.prefix)
            })
          case kind {
            Error(_) -> #(state, option.None)
            Ok(k) ->
              case k.create(topic_id) {
                option.None -> #(state, option.None)
                option.Some(entry) -> {
                  let topics = dict.insert(state.topics, topic_id, entry)
                  #(ServerState(..state, topics:), option.Some(entry))
                }
              }
          }
        }
      }
  }
}

@target(erlang)
fn handle_message(
  state: ServerState(model, message),
  event: InternalEvent(model, message),
) -> actor.Next(ServerState(model, message), InternalEvent(model, message)) {
  case event {
    ClientConnected(client_id:, send:) ->
      handle_connect_logic(state, client_id, send) |> actor.continue

    ClientDisconnected(client_id:) ->
      handle_disconnect_logic(state, client_id) |> actor.continue

    DispatchToClient(client_id:, message:) ->
      handle_dispatch_to_logic(state, client_id, message) |> actor.continue

    DispatchToAllClients(message:) ->
      handle_dispatch_to_all_logic(state, message) |> actor.continue

    Incoming(client_id:, bytes:) ->
      handle_incoming_logic(state, client_id, bytes) |> actor.continue

    SetConnectHook(hook:) ->
      handle_set_connect_hook_logic(state, hook) |> actor.continue

    SetDisconnectHook(hook:) ->
      handle_set_disconnect_hook_logic(state, hook) |> actor.continue

    SetHook(hook:) -> handle_set_hook_logic(state, hook) |> actor.continue

    SetTopicMessageHook(hook:) ->
      handle_set_topic_message_hook_logic(state, hook) |> actor.continue

    RegisterTopic(id:, entry:, reply:) -> {
      let #(new_state, result) = handle_register_topic_logic(state, id, entry)
      process.send(reply, result)
      actor.continue(new_state)
    }

    RegisterTopicKind(prefix:, create:, reply:) -> {
      let #(new_state, result) =
        handle_register_kind_logic(state, prefix, create)
      process.send(reply, result)
      actor.continue(new_state)
    }

    UnregisterTopic(id:) ->
      handle_unregister_topic_logic(state, id) |> actor.continue

    DoSubscribe(client_id:, topic_id:) ->
      handle_do_subscribe_logic(state, client_id, topic_id) |> actor.continue

    Stop -> {
      handle_stop_logic(state)
      actor.stop()
    }
  }
}

@target(erlang)
fn platform_connect(
  handle: ServerHandle(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  actor.send(handle, ClientConnected(client_id:, send:))
}

@target(erlang)
fn platform_disconnect(
  handle: ServerHandle(model, message),
  client_id: String,
) -> Nil {
  actor.send(handle, ClientDisconnected(client_id:))
}

@target(erlang)
fn platform_dispatch_to(
  handle: ServerHandle(model, message),
  client_id: String,
  message: message,
) -> Nil {
  actor.send(handle, DispatchToClient(client_id:, message:))
}

@target(erlang)
fn platform_dispatch_to_all(
  handle: ServerHandle(model, message),
  message: message,
) -> Nil {
  actor.send(handle, DispatchToAllClients(message:))
}

@target(erlang)
fn platform_do_subscribe(
  handle: ServerHandle(model, message),
  client_id: String,
  topic_id: String,
) -> Nil {
  actor.send(handle, DoSubscribe(client_id:, topic_id:))
}

@target(erlang)
fn platform_incoming(
  handle: ServerHandle(model, message),
  client_id: String,
  bytes: BitArray,
) -> Nil {
  actor.send(handle, Incoming(client_id:, bytes:))
}

@target(erlang)
fn platform_register_topic(
  handle: ServerHandle(model, message),
  id: String,
  entry: ServerTopicEntry(model, message),
) -> Result(Nil, Nil) {
  process.call(handle, 5000, fn(reply) { RegisterTopic(id:, entry:, reply:) })
}

@target(erlang)
fn platform_register_topic_kind(
  handle: ServerHandle(model, message),
  prefix: String,
  create: fn(String) -> Option(ServerTopicEntry(model, message)),
) -> Result(Nil, Nil) {
  process.call(handle, 5000, fn(reply) {
    RegisterTopicKind(prefix:, create:, reply:)
  })
}

@target(erlang)
fn platform_set_connect_hook(
  handle: ServerHandle(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  actor.send(handle, SetConnectHook(hook:))
}

@target(erlang)
fn platform_set_disconnect_hook(
  handle: ServerHandle(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  actor.send(handle, SetDisconnectHook(hook:))
}

@target(erlang)
fn platform_set_hook(
  handle: ServerHandle(model, message),
  hook: fn(message, model, String) -> Nil,
) -> Nil {
  actor.send(handle, SetHook(hook:))
}

@target(erlang)
fn platform_set_topic_message_hook(
  handle: ServerHandle(model, message),
  hook: fn(message, String, String) -> Nil,
) -> Nil {
  actor.send(handle, SetTopicMessageHook(hook:))
}

@target(erlang)
fn platform_start(
  initial_state: ServerState(model, message),
) -> Result(ServerHandle(model, message), Nil) {
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Nil)
}

@target(erlang)
fn platform_stop(handle: ServerHandle(model, message)) -> Nil {
  actor.send(handle, Stop)
}

@target(erlang)
fn platform_unregister_topic(
  handle: ServerHandle(model, message),
  id: String,
) -> Nil {
  actor.send(handle, UnregisterTopic(id:))
}

@target(javascript)
fn modify(
  handle: ServerHandle(model, message),
  update: fn(ServerState(model, message)) -> ServerState(model, message),
) -> Nil {
  case reference.get(handle) {
    option.Some(state) -> reference.set(handle, option.Some(update(state)))
    option.None -> Nil
  }
}

@target(javascript)
fn modify_returning(
  handle: ServerHandle(model, message),
  update: fn(ServerState(model, message)) ->
    #(ServerState(model, message), result),
  default: result,
) -> result {
  case reference.get(handle) {
    option.Some(state) -> {
      let #(new_state, result) = update(state)
      reference.set(handle, option.Some(new_state))
      result
    }
    option.None -> default
  }
}

@target(javascript)
fn platform_connect(
  handle: ServerHandle(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  modify(handle, handle_connect_logic(_, client_id, send))
}

@target(javascript)
fn platform_disconnect(
  handle: ServerHandle(model, message),
  client_id: String,
) -> Nil {
  modify(handle, handle_disconnect_logic(_, client_id))
}

@target(javascript)
fn platform_dispatch_to(
  handle: ServerHandle(model, message),
  client_id: String,
  message: message,
) -> Nil {
  modify(handle, handle_dispatch_to_logic(_, client_id, message))
}

@target(javascript)
fn platform_dispatch_to_all(
  handle: ServerHandle(model, message),
  message: message,
) -> Nil {
  modify(handle, handle_dispatch_to_all_logic(_, message))
}

@target(javascript)
fn platform_do_subscribe(
  handle: ServerHandle(model, message),
  client_id: String,
  topic_id: String,
) -> Nil {
  modify(handle, handle_do_subscribe_logic(_, client_id, topic_id))
}

@target(javascript)
fn platform_incoming(
  handle: ServerHandle(model, message),
  client_id: String,
  bytes: BitArray,
) -> Nil {
  modify(handle, handle_incoming_logic(_, client_id, bytes))
}

@target(javascript)
fn platform_register_topic(
  handle: ServerHandle(model, message),
  id: String,
  entry: ServerTopicEntry(model, message),
) -> Result(Nil, Nil) {
  modify_returning(
    handle,
    handle_register_topic_logic(_, id, entry),
    Error(Nil),
  )
}

@target(javascript)
fn platform_register_topic_kind(
  handle: ServerHandle(model, message),
  prefix: String,
  create: fn(String) -> Option(ServerTopicEntry(model, message)),
) -> Result(Nil, Nil) {
  modify_returning(
    handle,
    handle_register_kind_logic(_, prefix, create),
    Error(Nil),
  )
}

@target(javascript)
fn platform_set_connect_hook(
  handle: ServerHandle(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  modify(handle, handle_set_connect_hook_logic(_, hook))
}

@target(javascript)
fn platform_set_disconnect_hook(
  handle: ServerHandle(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  modify(handle, handle_set_disconnect_hook_logic(_, hook))
}

@target(javascript)
fn platform_set_hook(
  handle: ServerHandle(model, message),
  hook: fn(message, model, String) -> Nil,
) -> Nil {
  modify(handle, handle_set_hook_logic(_, hook))
}

@target(javascript)
fn platform_set_topic_message_hook(
  handle: ServerHandle(model, message),
  hook: fn(message, String, String) -> Nil,
) -> Nil {
  modify(handle, handle_set_topic_message_hook_logic(_, hook))
}

@target(javascript)
fn platform_start(
  initial_state: ServerState(model, message),
) -> Result(ServerHandle(model, message), Nil) {
  Ok(reference.make(option.Some(initial_state)))
}

@target(javascript)
fn platform_stop(handle: ServerHandle(model, message)) -> Nil {
  case reference.get(handle) {
    option.Some(state) -> {
      handle_stop_logic(state)
      reference.set(handle, option.None)
    }
    option.None -> Nil
  }
}

@target(javascript)
fn platform_unregister_topic(
  handle: ServerHandle(model, message),
  id: String,
) -> Nil {
  modify(handle, handle_unregister_topic_logic(_, id))
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(erlang)
@external(erlang, "lily_server_ffi", "generate_client_id")
fn ffi_generate_client_id() -> String {
  ""
}

@target(javascript)
@external(javascript, "./server.ffi.mjs", "generateClientId")
fn ffi_generate_client_id() -> String {
  ""
}

/// Run `operation`, turning a runtime crash into `Error(description)`. Types
/// are erased on Erlang, so a hostile frame can decode to a value the update
/// function cannot match. Catching it keeps one bad frame from dropping the
/// shared actor and every connection on it.
@external(erlang, "lily_server_ffi", "rescue")
@external(javascript, "./server.ffi.mjs", "rescue")
@internal
pub fn rescue(operation: fn() -> value) -> Result(value, String)
