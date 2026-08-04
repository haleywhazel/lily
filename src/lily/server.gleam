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
////   logging.log(logging.Info, "client connected: " <> client_id)
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
import gleam/set.{type Set}
import gleam/string
import lily/internal/actor_cell.{type Cell, Continue, Halt, Reply}
import lily/internal/id
import lily/logging
import lily/store
import lily/transport.{type Serialiser}

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

/// Handle to a running Lily server, backed by an
/// [`actor_cell`](./internal/actor_cell.html) (OTP actor on Erlang, `Reference`
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

/// Callbacks a topic actor registers so the server can route frames to it.
/// Created in `topic.gleam`, stored in the server's topic registry.
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

/// Register a client connection. The `send` callback pushes frames back to
/// this specific client.
///
/// ```gleam
/// server.connect(server, client_id: id, send: process.send(outgoing_subject, _))
/// ```
pub fn connect(
  server: Server(model, message),
  client_id client_id: String,
  send send: fn(BitArray) -> Nil,
) -> Nil {
  actor_cell.send(server.handle, ClientConnected(client_id:, send:))
}

/// Unregister a client connection from the server and all subscribed topics.
pub fn disconnect(
  server: Server(model, message),
  client_id client_id: String,
) -> Nil {
  actor_cell.send(server.handle, ClientDisconnected(client_id:))
}

/// Apply `message` to one connected client's session store and send a
/// `SessionUpdate` frame back to it. Use for server-initiated per-client
/// updates, e.g. a fresh slice after auth, per-user timers, async DB results.
///
/// No-op if no client with `client_id` is connected. Safe to call from any
/// process, so spawn the slow work and call `dispatch_to` when it's ready.
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
  actor_cell.send(server.handle, DispatchToClient(client_id:, message:))
}

/// Apply `message` to every connected client's session store and send each a
/// `SessionUpdate` frame. Use for server-wide announcements that also mutate
/// session state, like a forced feature-flag refresh. For fire-and-forget
/// broadcasts without session mutation, use a topic.
///
/// ```gleam
/// server.dispatch_to_all(server, message: SystemBannerUpdated(banner))
/// ```
pub fn dispatch_to_all(
  server: Server(model, message),
  message message: message,
) -> Nil {
  actor_cell.send(server.handle, DispatchToAllClients(message:))
}

/// Generate a cryptographically random 32-character hex client id. Pair with
/// [`connect`](#connect) so every connection carries a stable, server-issued
/// id.
///
/// ```gleam
/// let client_id = server.generate_client_id()
/// server.connect(server, client_id:, send:)
/// ```
pub fn generate_client_id() -> String {
  id.random_hex(client_id_bytes)
}

/// Process an incoming frame from a client. Decodes and routes it:
/// `SessionMessage` to the session store, `TopicMessage`/`Subscribe`/
/// `Unsubscribe` to the topic actor, `Resync` to a per-target snapshot
/// fan-out.
pub fn incoming(
  server: Server(model, message),
  client_id client_id: String,
  bytes bytes: BitArray,
) -> Nil {
  actor_cell.send(server.handle, Incoming(client_id:, bytes:))
}

/// Set the maximum number of live topic actors at once, bounding client-driven
/// topic creation through parametric kinds. The default is generous, raise it
/// if your app legitimately needs more concurrent topics.
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

/// Start building a server. Provide the shared initial model (the zero-state
/// for per-connection session stores and for topic snapshots) and the
/// serialiser.
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

/// Register a hook that runs after a client connects, receiving the
/// server-assigned client id. Use for presence, audit logging, or seeding the
/// session via [`dispatch_to`](#dispatch_to).
///
/// ```gleam
/// server.on_connect(server, fn(client_id) {
///   logging.log(logging.Info, "client connected: " <> client_id)
/// })
/// ```
pub fn on_connect(
  server: Server(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  actor_cell.send(server.handle, SetConnectHook(hook:))
}

/// Register a hook that runs after a client disconnects, receiving the id that
/// just left. Use for presence cleanup or audit logging.
///
/// ```gleam
/// server.on_disconnect(server, fn(client_id) {
///   logging.log(logging.Info, "client disconnected: " <> client_id)
/// })
/// ```
pub fn on_disconnect(
  server: Server(model, message),
  hook: fn(String) -> Nil,
) -> Nil {
  actor_cell.send(server.handle, SetDisconnectHook(hook:))
}

/// Register a hook that runs after each session message is applied. Receives
/// the decoded message, the full outer model after it's applied to this
/// client's session store, and the originating client id.
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
  actor_cell.send(server.handle, SetHook(hook:))
}

/// Register a hook that runs for each client-incoming topic message. Receives
/// the decoded message, the topic id, and the originating client id. Fires
/// before the topic actor processes it, whether the topic is stateful,
/// ephemeral, or unknown. Does not fire for server-initiated
/// `topic.dispatch`/`topic.broadcast`.
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
  actor_cell.send(server.handle, SetTopicMessageHook(hook:))
}

/// Start the configured server. Add topics afterwards via
/// `topic.new(server, ...)`.
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
      client_topics: dict.new(),
      sessions: dict.new(),
      topics: dict.new(),
      topic_kinds: [],
      on_connect_hook: fn(_) { Nil },
      on_disconnect_hook: fn(_) { Nil },
      on_message_hook: fn(_, _, _) { Nil },
      on_topic_message_hook: fn(_, _, _) { Nil },
      max_topics: builder.max_topics,
    )

  actor_cell.start(initial_state, reduce:)
  |> result.map(fn(handle) {
    Server(
      handle:,
      serialiser: builder.serialiser,
      initial_model: builder.initial_model,
      wiring: builder.wiring,
    )
  })
}

/// Stop a running server. Every topic actor is asked to stop first, sending
/// each subscriber a final `Acknowledge(Topic(id), seq)` so slices reset
/// cleanly. The server actor then terminates (Erlang) or its `Reference` cell
/// is cleared (JavaScript). Session clients receive no extra frame.
pub fn stop(server: Server(model, message)) -> Nil {
  actor_cell.send(server.handle, Stop)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Subscribe a client to a topic via the server, so it can look up the
/// client's send function.
@internal
pub fn do_subscribe(
  server: Server(model, message),
  client_id: String,
  topic_id: String,
) -> Nil {
  actor_cell.send(server.handle, DoSubscribe(client_id:, topic_id:))
}

/// Config values `topic.gleam` needs to build a topic actor: the initial model
/// (for full-outer-model snapshots), the serialiser (to encode topic frames),
/// and the wiring (to look up the apply function for a topic id).
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
  actor_cell.call(
    server.handle,
    RegisterTopic(id:, entry:),
    default: Error(Nil),
  )
}

/// Register a parametric topic kind. When a client subscribes to an id
/// starting with `prefix` and no fixed topic with that id exists, `create` is
/// called with the full id and returns a `ServerTopicEntry` on success or
/// `None` to reject. `find_or_create_topic` inserts the entry directly, no
/// server callback needed.
@internal
pub fn register_topic_kind(
  server: Server(model, message),
  prefix: String,
  create: fn(String) -> Option(ServerTopicEntry(model, message)),
) -> Result(Nil, Nil) {
  actor_cell.call(
    server.handle,
    RegisterTopicKind(prefix:, create:),
    default: Error(Nil),
  )
}

/// Remove a topic entry from the server registry.
@internal
pub fn unregister_topic(server: Server(model, message), id: String) -> Nil {
  actor_cell.send(server.handle, UnregisterTopic(id:))
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

type ConnectionState(model, message) {
  ConnectionState(model: model, sequence: Int)
}

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
  RegisterTopic(id: String, entry: ServerTopicEntry(model, message))
  RegisterTopicKind(
    prefix: String,
    create: fn(String) -> Option(ServerTopicEntry(model, message)),
  )
  UnregisterTopic(id: String)
  DoSubscribe(client_id: String, topic_id: String)
  Stop
}

type ServerHandle(model, message) =
  Cell(
    ServerState(model, message),
    InternalEvent(model, message),
    Result(Nil, Nil),
  )

type ServerState(model, message) {
  ServerState(
    initial_model: model,
    serialiser: Serialiser(model, message),
    session_apply: Option(fn(model, message) -> model),
    clients: Dict(String, fn(BitArray) -> Nil),
    client_topics: Dict(String, Set(String)),
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

type TopicKindEntry(model, message) {
  TopicKindEntry(
    prefix: String,
    create: fn(String) -> Option(ServerTopicEntry(model, message)),
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

// Random bytes behind a client ID, so 32 hex characters. Wide enough that two
// connections never collide.
const client_id_bytes = 16

// Default cap on live topic actors, overridable with `server.max_topics`.
const default_max_topics = 100_000

/// Apply `message` to a connection's model under crash isolation, returning the
/// new model or the crash reason. `None` session apply leaves the model as-is.
fn apply_session(
  state: ServerState(model, message),
  connection: ConnectionState(model, message),
  message: message,
) -> Result(model, String) {
  case state.session_apply {
    option.None -> Ok(connection.model)
    option.Some(apply) -> rescue(fn() { apply(connection.model, message) })
  }
}

/// Bump a client's session sequence and store the new model against it.
fn commit_session(
  state: ServerState(model, message),
  client_id: String,
  new_model: model,
  new_sequence: Int,
) -> ServerState(model, message) {
  let sessions =
    dict.insert(
      state.sessions,
      client_id,
      ConnectionState(model: new_model, sequence: new_sequence),
    )
  ServerState(..state, sessions:)
}

fn find_or_create_topic(
  state: ServerState(model, message),
  topic_id: String,
) -> #(ServerState(model, message), Option(ServerTopicEntry(model, message))) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) -> #(state, option.Some(entry))
    // parametric ids come from the client, so refuse past the cap to stop one
    // client spawning topics without bound
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
  let subscribed =
    dict.get(state.client_topics, client_id) |> result.unwrap(set.new())
  set.each(subscribed, fn(topic_id) {
    case dict.get(state.topics, topic_id) {
      Ok(entry) -> entry.unsubscribe(client_id)
      Error(_) -> Nil
    }
  })
  let clients = dict.delete(state.clients, client_id)
  let client_topics = dict.delete(state.client_topics, client_id)
  let sessions = dict.delete(state.sessions, client_id)
  state.on_disconnect_hook(client_id)
  ServerState(..state, clients:, client_topics:, sessions:)
}

fn handle_dispatch_to_all_logic(
  state: ServerState(model, message),
  message: message,
) -> ServerState(model, message) {
  dict.fold(state.clients, state, fn(acc, client_id, _send) {
    handle_dispatch_to_logic(acc, client_id, message)
  })
}

fn handle_dispatch_to_logic(
  state: ServerState(model, message),
  client_id: String,
  message: message,
) -> ServerState(model, message) {
  case dict.get(state.sessions, client_id), dict.get(state.clients, client_id) {
    Ok(connection), Ok(send) ->
      case apply_session(state, connection, message) {
        // a crashing update must not take down the shared actor and every
        // connection on it, so drop this dispatch without sending an update
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "lily: dropped crashing dispatch to " <> client_id <> ": " <> reason,
          )
          state
        }
        Ok(new_model) -> {
          let new_sequence = connection.sequence + 1
          let frame =
            transport.encode(
              transport.SessionUpdate(sequence: new_sequence, payload: message),
              serialiser: state.serialiser,
            )
          send(frame)
          commit_session(state, client_id, new_model, new_sequence)
        }
      }
    _, _ -> state
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
      track_subscription(state, client_id, topic_id)
    }
    _, _ -> state
  }
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

    // server-to-client variants, never legitimately arrive here
    Ok(transport.Acknowledge(_, _))
    | Ok(transport.Connected(_))
    | Ok(transport.Push(_, _))
    | Ok(transport.Rejected(_, _))
    | Ok(transport.SessionUpdate(_, _))
    | Ok(transport.Snapshot(_, _, _))
    | Ok(transport.TopicUpdate(_, _, _))
    | Ok(transport.Version(_)) -> state

    Error(_) -> state
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

fn handle_register_topic_logic(
  state: ServerState(model, message),
  id: String,
  entry: ServerTopicEntry(model, message),
) -> #(ServerState(model, message), Result(Nil, Nil)) {
  let already_exists = dict.has_key(state.topics, id)
  // both directions matter, `id="room:1"` collides with kind prefix `"room:"`,
  // and a fixed `id="room"` would shadow that prefix
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

fn handle_session_message_logic(
  state: ServerState(model, message),
  client_id: String,
  message: message,
) -> ServerState(model, message) {
  case dict.get(state.sessions, client_id) {
    Error(_) -> state
    Ok(connection) ->
      case apply_session(state, connection, message) {
        // a crash means the frame decoded to a value update can't match, drop
        // it without acking to keep the actor alive
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "lily: dropped malformed session message from "
              <> client_id
              <> ": "
              <> reason,
          )
          state
        }
        Ok(new_model) -> {
          let new_sequence = connection.sequence + 1
          case dict.get(state.clients, client_id) {
            Ok(send) -> {
              let ack_frame =
                transport.encode(
                  transport.Acknowledge(
                    target: transport.Session,
                    sequence: new_sequence,
                  ),
                  serialiser: state.serialiser,
                )
              send(ack_frame)
            }
            Error(_) -> Nil
          }
          state.on_message_hook(message, new_model, client_id)
          commit_session(state, client_id, new_model, new_sequence)
        }
      }
  }
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

/// Stop every topic actor (each sends a final `Acknowledge(Topic(id), seq)` to
/// its subscribers) before the server goes away. Called from both the Erlang
/// `Stop` arm and the JavaScript `stop()` method.
fn handle_stop_logic(state: ServerState(model, message)) -> Nil {
  dict.each(state.topics, fn(_id, entry) { entry.stop() })
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
          track_subscription(state, client_id, topic_id)
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

fn handle_unregister_topic_logic(
  state: ServerState(model, message),
  id: String,
) -> ServerState(model, message) {
  let topics = dict.delete(state.topics, id)
  ServerState(..state, topics:)
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
  untrack_subscription(state, client_id, topic_id)
}

fn reduce(
  event: InternalEvent(model, message),
  state: ServerState(model, message),
) -> actor_cell.Reduction(ServerState(model, message), Result(Nil, Nil)) {
  case event {
    ClientConnected(client_id:, send:) ->
      Continue(handle_connect_logic(state, client_id, send))

    ClientDisconnected(client_id:) ->
      Continue(handle_disconnect_logic(state, client_id))

    DispatchToClient(client_id:, message:) ->
      Continue(handle_dispatch_to_logic(state, client_id, message))

    DispatchToAllClients(message:) ->
      Continue(handle_dispatch_to_all_logic(state, message))

    Incoming(client_id:, bytes:) ->
      Continue(handle_incoming_logic(state, client_id, bytes))

    SetConnectHook(hook:) ->
      Continue(handle_set_connect_hook_logic(state, hook))

    SetDisconnectHook(hook:) ->
      Continue(handle_set_disconnect_hook_logic(state, hook))

    SetHook(hook:) -> Continue(handle_set_hook_logic(state, hook))

    SetTopicMessageHook(hook:) ->
      Continue(handle_set_topic_message_hook_logic(state, hook))

    RegisterTopic(id:, entry:) -> {
      let #(new_state, result) = handle_register_topic_logic(state, id, entry)
      Reply(new_state, result)
    }

    RegisterTopicKind(prefix:, create:) -> {
      let #(new_state, result) =
        handle_register_kind_logic(state, prefix, create)
      Reply(new_state, result)
    }

    UnregisterTopic(id:) -> Continue(handle_unregister_topic_logic(state, id))

    DoSubscribe(client_id:, topic_id:) ->
      Continue(handle_do_subscribe_logic(state, client_id, topic_id))

    Stop -> {
      handle_stop_logic(state)
      Halt(state)
    }
  }
}

/// Record that `client_id` is subscribed to `topic_id`, so disconnect can
/// unsubscribe only the topics the client actually joined.
fn track_subscription(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  let topics =
    dict.get(state.client_topics, client_id)
    |> result.unwrap(set.new())
    |> set.insert(topic_id)
  let client_topics = dict.insert(state.client_topics, client_id, topics)
  ServerState(..state, client_topics:)
}

/// Drop `topic_id` from `client_id`'s subscription set on an explicit
/// unsubscribe.
fn untrack_subscription(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.client_topics, client_id) {
    Error(_) -> state
    Ok(topics) -> {
      let client_topics =
        dict.insert(
          state.client_topics,
          client_id,
          set.delete(topics, topic_id),
        )
      ServerState(..state, client_topics:)
    }
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

/// Run `operation`, turning a runtime crash into `Error(description)`. Types
/// are erased on Erlang, so a hostile frame can decode to a value update can't
/// match. Catching it keeps one bad frame from dropping the shared actor and
/// every connection on it.
@external(erlang, "lily_server_ffi", "rescue")
@external(javascript, "./server.ffi.mjs", "rescue")
@internal
pub fn rescue(operation: fn() -> value) -> Result(value, String)
