//// The [`Server`](#Server) is, well, the server of a Lily app. Clients can
//// apply their own changes optimistically, although the server has the final
//// say and streams the corrected state back, keeping the two in sync (see
//// [transport](./transport.html) for the frames that carry it). This means
//// that ultimately, the server is usually authoritative when it comes to
//// decisions but this can be managed by you in more detail.
////
//// Every message a client sends to the server lands in one of two places,
//// either that client's own per-connection session model, or a topic model
//// shared between clients. (The client can also keep a message to itself.)
//// See [store](./store.html) for how topics are declared.
////
//// The server starts a topic the first time anyone subscribes to it, and
//// starts it again from the same declaration if it crashes. A topic that
//// stopped, or was given up on after crashing too often, keeps its holders,
//// who are subscribed again when it next starts. Each topic's
//// [`Access`](./store.html#Access) rule is checked on every subscribe, on a
//// resync and whenever the client's session changes, and a topic the rule
//// now refuses is left with a `Rejected` frame. A subscribe to an id no
//// declaration covers is rejected too.
////
//// While the server compiles for both targets, not using the Erlang one means
//// that you aren't leveraging BEAM's model and a full-stack JS model might be
//// better suited.
////
//// To build an Erlang server from the same synced store your client gets,
//// plus an [`Origins`](#Origins) policy saying which browser origins may open
//// a connection, you can do this:
////
//// ```gleam
//// import lily/server
////
//// pub fn main() {
////   let assert Ok(#(_supervisor, app)) =
////     server.new(shared.store(), origins: server.AllowedOrigins([
////       "http://localhost:8080",
////     ]))
////     |> server.observe(log_events)
////     |> server.start_supervised
//// }
//// ```
////
//// Using [`start_supervised`](#start_supervised) rather than [`start`](#start)
//// ensures that the server and the topics are placed in an OTP supervision
//// tree so the crash can be isolated and restarted rather than taking the node
//// down with it.
////
//// The server doesn't import `mist` or `wisp` or `ewe`, it's completely
//// transport-agnostic (the same way Lustre leaves the transport to you),
//// leaving you to wire it into whatever WebSocket or HTTP handler you're
//// running. Open a [`Connection`](#Connection) with [`connect`](#connect),
//// feed every inbound frame to [`incoming`](#incoming), and call
//// [`disconnect`](#disconnect) when the socket closes:
////
//// ```gleam
//// let assert Ok(connection) =
////   server.connect(
////     app,
////     origin: request.get_header(req, "origin") |> option.from_result,
////     send: process.send(outgoing_subject, _),
////   )
////
//// // for every frame the socket receives
//// case server.incoming(connection, bytes:) {
////   server.Closed -> close_socket()
////   _ -> Nil
//// }
////
//// // when it closes
//// server.disconnect(connection)
//// ```
////
//// With `connect` watching the process that calls it, the server runs the
//// same cleanup `disconnect` does if that process dies. A transport that
//// connects from a short-lived process, such as an HTTP request, uses
//// [`connect_as`](#connect_as) with `Unwatched`.
////
//// A client id that is already connected is taken over by the newer
//// connection, see [`connect_as`](#connect_as).
////
//// Most apps then just need [`observe`](#observe). An observer sees every
//// [`ServerEvent`](#ServerEvent), a client coming and going, a session message
//// applied, a client joining, leaving or being refused a topic, together with
//// the server it happened on. This is the place to notice events and do
//// quick work rather than slower work (e.g. database writes, process
//// sleeps, side effects) to prevent stalling the observer.
////
//// When the server itself needs to change state, rather than react to
//// something a client sent, use [`dispatch_to`](#dispatch_to) for a single
//// client's session or [`dispatch_topic`](#dispatch_topic) for a shared topic.
//// Both are safe to call from any process (an observer included) where they
//// apply once the current event is done. Thus an observer can answer a client
//// joining straight away, and something slow can be spawned and dispatch when
//// it's ready.
////
//// A topic whose state lives somewhere else, like a database, can load it
//// with [`topic_init`](#topic_init), or a whole family of them with
//// [`topics_init`](#topics_init). Running inside the topic itself when it
//// starts and every time it restarts, a slow loader only holds up that topic.
////
//// The server treats every client as possibly hostile. A frame is decoded in
//// the process that calls [`incoming`](#incoming), refused past
//// [`max_frame_bytes`](#max_frame_bytes), and each client is held to a
//// [`rate_limit`](#rate_limit), where a frame past it waits its turn rather
//// than being refused. One client may hold
//// [`max_subscriptions`](#max_subscriptions) topics, 100 by default, with ids
//// up to [`max_topic_id_bytes`](#max_topic_id_bytes), and the server as a
//// whole caps [`max_clients`](#max_clients) and [`max_topics`](#max_topics).
//// On Erlang a socket from [`attach`](#attach) that reads too slowly is cut
//// off past [`max_outbound_queue`](#max_outbound_queue), and frames are shed
//// past [`max_inbound_queue`](#max_inbound_queue), a shed message still
//// answered with a `Dropped`.
//// [`stop_idle_topics`](#stop_idle_topics) stops the topics nobody holds.
////
//// Shut a server down with [`stop`](#stop), which asks every topic to stop
//// first, settling each subscriber's pending messages with a final
//// `Acknowledge`, before the underlying actor terminates.
////
//// Sample server combining everything together (using mist):
////
//// ```gleam
//// import gleam/bytes_tree
//// import gleam/erlang/process
//// import gleam/http/request
//// import gleam/http/response
//// import gleam/option
////
//// import lily/server
//// import mist
////
//// import shared
////
//// pub fn main() {
////   let assert Ok(#(_supervisor, app)) =
////     server.new(
////       shared.store(),
////       origins: server.AllowedOrigins(["http://localhost:8080"]),
////     )
////     |> server.start_supervised
////
////   let assert Ok(_) =
////     mist.new(fn(http_request) {
////       let origin =
////         request.get_header(http_request, "origin") |> option.from_result
////       case server.open(app, origin:) {
////         Error(_) ->
////           response.new(403)
////           |> response.set_body(mist.Bytes(bytes_tree.new()))
////         Ok(opened) ->
////           mist.websocket(
////             request: http_request,
////             on_init: fn(_socket) {
////               let #(connection, frames) = server.attach(opened)
////               #(connection, option.Some(frames))
////             },
////             on_close: server.disconnect,
////             handler: fn(connection, message, socket) {
////               case message {
////                 mist.Binary(bytes) ->
////                   case server.incoming(connection, bytes:) {
////                     server.Closed -> mist.stop()
////                     _ -> mist.continue(connection)
////                   }
////                 mist.Custom(Ok(bytes)) -> {
////                   let _ = mist.send_binary_frame(socket, bytes)
////                   mist.continue(connection)
////                 }
////                 mist.Text(_) -> mist.continue(connection)
////                 mist.Custom(Error(Nil)) | mist.Closed | mist.Shutdown ->
////                   mist.stop()
////               }
////             },
////           )
////       }
////     })
////     |> mist.port(8080)
////     |> mist.start
////
////   process.sleep_forever()
//// }
//// ```

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option}
@target(erlang)
import gleam/otp/actor as otp_actor
@target(erlang)
import gleam/otp/static_supervisor
@target(erlang)
import gleam/otp/supervision
import gleam/pair
import gleam/result
import gleam/set.{type Set}
import gleam/string

import lily/internal/actor.{type Cell, Continue, Halt, Reply}
import lily/store.{type Store, type Synced}
import lily/transport.{
  type Format, type RejectionReason, type Serialiser, AccessDenied, NotFound,
  OverLimit,
}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Description of the server before starting, construct from [`new`](#new).
pub opaque type Builder(model, message) {
  Builder(
    store: Store(model, message, Synced),
    origins: Origins,
    observers: List(Observer(model, message)),
    topic_inits: List(#(store.TopicMatch, fn(String) -> model)),
    max_clients: Int,
    max_frame_bytes: Int,
    max_held_bytes: HeldBytes,
    max_inbound_queue: Int,
    max_outbound_bytes: Int,
    max_outbound_queue: Int,
    max_subscriptions: Int,
    max_topic_id_bytes: Int,
    max_topics: Int,
    rate_limit: RateLimit,
    eviction: Eviction,
    diagnostic_budget: RateLimit,
    topic_restarts: RestartLimit,
    restart_tolerance: Tolerance,
    clock: fn() -> Int,
    idle_after: Option(Int),
  )
}

/// Why a connection was refused before it was registered.
pub type ConnectError {
  /// The `Origin` header did not match the allowlist.
  OriginNotAllowed(origin: String)
  /// Request had no `Origin` header and the policy wants one.
  OriginMissing
  /// The server already holds [`max_clients`](#max_clients) connections.
  TooManyClients
}

/// One client's registration with a server, from [`connect`](#connect).
///
/// Give it each inbound frame and close it when the transport closes.
pub opaque type Connection(model, message) {
  Connection(
    server: Server(model, message),
    client_id: String,
    link: Link,
    // the server incarnation it registered with, a restart closes it
    incarnation: Int,
  )
}

/// Which process the server should watch for a connection, its death
/// disconnecting the client.
pub type ConnectionWatch {
  /// The process calling `connect_as` (what [`connect`](#connect) does)
  WatchCaller
  /// Some other process, such as the one owning the socket
  WatchProcess(Pid)
  /// Nothing, for a transport whose requests are short-lived
  Unwatched
}

/// Why the server cut a client off, in a
/// [`ClientEvicted`](#ServerEvent) event.
pub type EvictionReason {
  /// It kept sending past its [`rate_limit`](#rate_limit)
  RateLimited
  /// It read its frames too slowly and its queue passed
  /// [`max_outbound_queue`](#max_outbound_queue)
  SlowReader
  /// Another connection registered with its id and took its place
  Superseded
}

@target(erlang)
/// A request whose origin [`open`](#open) has accepted, waiting for its socket
/// to [`attach`](#attach).
///
/// Erlang only.
pub opaque type Opened(model, message) {
  Opened(server: Server(model, message), client_id: String, seed: List(message))
}

/// Which browser origins may open a connection to this server.
///
/// Passed to [`new`](#new) and evaluated by [`connect`](#connect) and
/// [`check_origin`](#check_origin).
///
/// ```gleam
/// server.AllowedOrigins(["https://example.com", "http://localhost:8080"])
/// ```
pub type Origins {
  AllowedOrigins(List(String))
  AnyOrigin
}

/// What [`incoming`](#incoming) did with a frame. A WebSocket transport only
/// needs `Closed`, an HTTP one can answer the others with a status.
pub type Received {
  /// Handed to the server, where it may wait its turn under the client's
  /// [`rate_limit`](#rate_limit)
  Accepted
  /// Over [`max_frame_bytes`](#max_frame_bytes), refused unread, a 413
  TooLarge
  /// The server's mailbox is past [`max_inbound_queue`](#max_inbound_queue)
  /// and the frame was shed, a 503. A message still gets its `Dropped`, so
  /// the client's edit rolls back
  Overloaded
  /// The server cut this connection off, another took its id, or it belongs
  /// to a server that has since restarted or stopped, so close the socket
  Closed
}

/// A running Lily server.
///
/// Use [`start`](#start) to start one.
pub opaque type Server(model, message) {
  Server(
    handle: ServerHandle(model, message),
    origins: Origins,
    gate: Gate(model, message),
  )
}

/// Something that happened on the server, given to every observer.
pub type ServerEvent(model, message) {
  /// A client was registered
  ClientConnected(client_id: String)
  /// A client left, or its connection process died
  ClientDisconnected(client_id: String)
  /// The server cut a client off, a `ClientDisconnected` follows
  ClientEvicted(client_id: String, reason: EvictionReason)
  /// A client went past its rate limit, reported once per window, whether its
  /// frames waited or were refused
  ClientThrottled(client_id: String)
  /// A session message was applied (`model` is the client's model after it)
  SessionMessageApplied(client_id: String, message: message, model: model)
  /// A client sent a message to a topic it joined, before the topic applies it
  TopicMessageReceived(client_id: String, topic_id: String, message: message)
  /// A topic admitted a client
  Subscribed(client_id: String, topic_id: String)
  /// A subscribe was refused with a `Rejected` frame
  SubscriptionRejected(
    client_id: String,
    topic_id: String,
    reason: RejectionReason,
  )
  /// A client left a topic it had joined
  Unsubscribed(client_id: String, topic_id: String)
  /// Lily dropped something (`Warning`) or gave up on something (`Failure`)
  Diagnostic(level: transport.DiagnosticLevel, message: String)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(erlang)
/// Registers a WebSocket with the server from inside its socket process, once
/// [`open`](#open) or [`open_as`](#open_as) has accepted the request. Erlang
/// only.
///
/// Give it the `Opened` value. You get back the connection and a selector that
/// yields `Ok(bytes)` for each frame to send, and `Error(Nil)` when the socket
/// should close, because the server restarted or cut this client off, or was
/// already full when it attached.
///
/// ```gleam
/// on_init: fn(_socket) {
///   let #(connection, frames) = server.attach(opened)
///   #(connection, option.Some(frames))
/// },
/// ```
pub fn attach(
  opened: Opened(model, message),
) -> #(Connection(model, message), process.Selector(Result(BitArray, Nil))) {
  let server = opened.server
  // monitor before joining, a restart in between still closes the socket
  // instead of leaving it registered on a dead process
  let gone = monitor(server)
  let outgoing = process.new_subject()
  let socket = process.self()
  let client_id = opened.client_id
  let token = unique_integer()
  let mirror = ClientMirror(closed: new_gauge(), overflowed: new_gauge())
  let limit = server.gate.max_outbound_queue
  let byte_limit = server.gate.max_outbound_bytes
  // what the socket has yet to read, a frame on its own always fits so one
  // big snapshot can't cut a client off for good
  let queued = new_gauge()
  // runs in the server and its topics, a close queued behind the backlog
  // would only be read once it had drained, so a slow reader is killed
  let send = fn(bytes) {
    let size = bit_array.byte_size(bytes)
    let backlog = gauge_value(queued)
    case
      message_queue_length(socket) < limit
      && { backlog == 0 || backlog + size <= byte_limit }
    {
      True -> {
        let _ = gauge_add(queued, size)
        process.send(outgoing, Frame(bytes))
      }
      False -> {
        // flagged first, the socket's death can reach the server before this
        gauge_set(mirror.overflowed, 1)
        cast(server, Overflowed(client_id:, token:))
        process.kill(socket)
      }
    }
  }
  // `open` only checked the cap, two handshakes at once could both pass it
  let connection = case reserve_client(server.gate) {
    True ->
      register(
        server,
        token:,
        mirror:,
        send:,
        close: option.Some(fn() { process.send(outgoing, Shut) }),
        client_id:,
        session: opened.seed,
        watch: WatchCaller,
      )
    False -> {
      // never registered, the socket closes on its first look at the selector
      process.send(outgoing, Shut)
      actor.log_limited(
        "attach",
        transport.Warning,
        "lily: refused a socket, the server holds max_clients already",
      )
      Connection(
        server:,
        client_id:,
        link: Refused,
        incarnation: gauge_value(server.gate.incarnation),
      )
    }
  }
  let selector =
    process.new_selector()
    |> process.select_map(outgoing, fn(outbound) {
      case outbound {
        Frame(bytes) -> {
          let _ = gauge_add(queued, -bit_array.byte_size(bytes))
          Ok(bytes)
        }
        Shut -> Error(Nil)
      }
    })
    |> process.select_specific_monitor(gone, fn(_) { Error(Nil) })
  #(connection, selector)
}

/// Checks a request's `Origin` header against the server's
/// [`Origins`](#Origins), for refusing a request before you connect it.
///
/// ```gleam
/// case server.check_origin(app, origin:) {
///   Ok(Nil) -> upgrade(request)
///   Error(_) -> forbidden()
/// }
/// ```
pub fn check_origin(
  server: Server(model, message),
  origin origin: Option(String),
) -> Result(Nil, ConnectError) {
  validate_origin(server.origins, origin)
}

/// The id of a connection.
pub fn client_id(connection: Connection(model, message)) -> String {
  connection.client_id
}

/// Registers a client with the server, from the process that owns its socket.
///
/// Give it the request's `Origin` header and a `send` function that delivers a
/// frame to this client. `send` runs inside the server and its topics, so it
/// must not block and should bound what it queues itself. The client is
/// disconnected if the calling process dies. With mist or ewe, [`open`](#open)
/// and [`attach`](#attach) are simpler and bound the queue for you.
///
/// ```gleam
/// let assert Ok(connection) =
///   server.connect(app, origin:, send: process.send(outgoing, _))
/// ```
pub fn connect(
  server: Server(model, message),
  origin origin: Option(String),
  send send: fn(BitArray) -> Nil,
) -> Result(Connection(model, message), ConnectError) {
  connect_as(
    server,
    origin:,
    send:,
    client_id: generate_client_id(),
    seed: [],
    watch: WatchCaller,
  )
}

/// Registers a client like [`connect`](#connect), letting you choose its id,
/// seed its session and pick which process to watch.
///
/// `seed` is a list of messages applied to the new connection's session
/// before anything it sends, such as who signed in. Use `watch: Unwatched`
/// for short-lived HTTP requests.
///
/// An id that's already connected is taken over. The old connection is
/// unsubscribed from everything and reported as
/// [`ClientEvicted`](#ServerEvent) with `Superseded`, and its later frames and
/// disconnect are ignored. Ids from [`generate_client_id`](#generate_client_id)
/// are random, so only reuse one you've authenticated.
///
/// `send` runs inside the server and its topics. It must not block, and should
/// bound what it queues for a slow socket itself.
///
/// ```gleam
/// server.connect_as(
///   app,
///   origin:,
///   send:,
///   client_id: server.generate_client_id(),
///   seed: [SignedInAs(user)],
///   watch: server.WatchCaller,
/// )
/// ```
pub fn connect_as(
  server: Server(model, message),
  origin origin: Option(String),
  send send: fn(BitArray) -> Nil,
  client_id client_id: String,
  seed seed: List(message),
  watch watch: ConnectionWatch,
) -> Result(Connection(model, message), ConnectError) {
  // validated so that a refused origin doesn't reach the actor
  use _ <- result.try(validate_origin(server.origins, origin))
  use <- bool.guard(
    when: !reserve_client(server.gate),
    return: Error(TooManyClients),
  )
  Ok(register(
    server,
    token: unique_integer(),
    mirror: ClientMirror(closed: new_gauge(), overflowed: new_gauge()),
    send:,
    close: option.None,
    client_id:,
    session: seed,
    watch:,
  ))
}

/// The connection for a client id you kept, for transports that store the id
/// rather than the connection.
///
/// It reaches whichever connection holds the id now, a newer one included.
/// It can't tell the transport the client was cut off, so `incoming` only
/// says `Closed` after a restart.
///
/// ```gleam
/// case server.connection(app, client_id:) |> server.incoming(bytes:) {
///   server.Closed -> close_stream()
///   _ -> Nil
/// }
/// ```
pub fn connection(
  server: Server(model, message),
  client_id client_id: String,
) -> Connection(model, message) {
  Connection(
    server:,
    client_id:,
    link: ById,
    incarnation: gauge_value(server.gate.incarnation),
  )
}

/// Caps the diagnostics every client's frames can set off together,
/// `per_second` on average and up to `burst` at once, 10 and 100 by default.
/// Each client is also held to one per 10 seconds on its own. Both values are
/// clamped to between 1 and 1,000,000,000.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.diagnostic_budget(per_second: 1, burst: 20)
/// ```
pub fn diagnostic_budget(
  builder: Builder(model, message),
  per_second per_second: Int,
  burst burst: Int,
) -> Builder(model, message) {
  let per_second = int.clamp(per_second, min: 1, max: 1_000_000_000)
  let burst = int.clamp(burst, min: 1, max: 1_000_000_000)
  Builder(..builder, diagnostic_budget: RateLimit(per_second:, burst:))
}

/// Unregisters a client, usually when its socket closes.
pub fn disconnect(connection: Connection(model, message)) -> Nil {
  let client_id = connection.client_id
  case connection.link {
    Registered(token:, ..) -> {
      let left = ClientLeft(client_id:, token: Token(token))
      actor.rescue_or("unwatch", Nil, fn() {
        actor.unwatch(connection.server.handle, down: left)
      })
      cast(connection.server, left)
    }
    ById -> cast(connection.server, ClientLeft(client_id:, token: AnyToken))
    // never registered, nothing to leave
    Refused -> Nil
  }
}

/// Applies a message to one client's session and sends it the update, for
/// changes the server makes on its own, like the result of async work.
///
/// Does nothing if the client isn't connected. Safe to call from any process.
///
/// ```gleam
/// server.dispatch_to(app, client_id:, message: Welcome)
/// ```
pub fn dispatch_to(
  server: Server(model, message),
  client_id client_id: String,
  message message: message,
) -> Nil {
  cast(server, DispatchToClient(client_id:, message:))
}

/// Applies a message to every connected client's session and sends each the
/// update.
///
/// ```gleam
/// server.dispatch_to_all(app, message: BannerChanged(banner))
/// ```
pub fn dispatch_to_all(
  server: Server(model, message),
  message message: message,
) -> Nil {
  cast(server, DispatchToAllClients(message:))
}

/// Applies a message to a topic and sends the update to its subscribers,
/// starting the topic if it isn't running. Safe to call from any process.
///
/// A dispatch to an id no declaration covers, or to a new topic once
/// [`max_topics`](#max_topics) are running and every one is held, is dropped
/// with a `Diagnostic`.
///
/// ```gleam
/// server.dispatch_topic(app, topic_id: "chat", message: Chat(Notice(text)))
/// ```
pub fn dispatch_topic(
  server: Server(model, message),
  topic_id topic_id: String,
  message message: message,
) -> Nil {
  cast(server, DispatchTopic(topic_id:, message:))
}

/// Cuts a client off once more than `refusals` of its frames are refused
/// within `within` milliseconds, reported as [`ClientEvicted`](#ServerEvent)
/// with `RateLimited`. By default that's the [`rate_limit`](#rate_limit)'s
/// `burst` within 10 seconds, the same window `ClientThrottled` is reported
/// once in. Both values are clamped to at least 1.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.evict_after(refusals: 2000, within: 30_000)
/// ```
pub fn evict_after(
  builder: Builder(model, message),
  refusals refusals: Int,
  within milliseconds: Int,
) -> Builder(model, message) {
  let eviction =
    Eviction(
      refusals: option.Some(int.max(refusals, 1)),
      within: int.max(milliseconds, 1),
    )
  Builder(..builder, eviction:)
}

/// Generates a new random client id, for [`connect_as`](#connect_as).
pub fn generate_client_id() -> String {
  random_hex(byte_count: 16)
}

/// Passes a frame the client sent to the server. Call it for every binary frame
/// the socket receives, and close the socket when it says `Closed`.
///
/// ```gleam
/// case server.incoming(connection, bytes:) {
///   server.Closed -> close_socket()
///   _ -> Nil
/// }
/// ```
pub fn incoming(
  connection: Connection(model, message),
  bytes bytes: BitArray,
) -> Received {
  case live_token(connection) {
    Error(Nil) -> Closed
    Ok(token) -> {
      let gate = connection.server.gate
      let size = bit_array.byte_size(bytes)
      // decoded here so a hostile frame costs its own process
      let #(inbound, received) = case size > gate.max_frame_bytes {
        True -> #(Oversized(target: transport.peek_target(bytes)), TooLarge)
        False ->
          case
            transport.decode_inbound(
              bytes,
              serialiser: gate.serialiser,
              conform: gate.conform,
              from_client: True,
            )
          {
            Ok(#(frame, format)) -> #(Decoded(frame:, format:), Accepted)
            Error(failure) -> #(Undecodable(failure:), Accepted)
          }
      }
      let client_id = connection.client_id
      case overloaded(connection.server) {
        False -> {
          cast(connection.server, Incoming(client_id:, token:, inbound:, size:))
          received
        }
        True -> shed(connection, token, inbound, size, received)
      }
    }
  }
}

/// Caps how many clients may be connected at once, 10,000 by default. Past
/// it [`connect`](#connect), [`connect_as`](#connect_as), [`open`](#open) and
/// [`open_as`](#open_as) refuse with `TooManyClients`.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_clients(count: 2000)
/// ```
pub fn max_clients(
  builder: Builder(model, message),
  count count: Int,
) -> Builder(model, message) {
  Builder(..builder, max_clients: count)
}

/// Caps the size of a frame a client may send, 1 MiB by default. A bigger one
/// is dropped before it's decoded and charged against the client's
/// [`rate_limit`](#rate_limit), a message gets a `Dropped`.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_frame_bytes(bytes: 64 * 1024)
/// ```
pub fn max_frame_bytes(
  builder: Builder(model, message),
  bytes bytes: Int,
) -> Builder(model, message) {
  Builder(..builder, max_frame_bytes: bytes)
}

/// Caps what frames waiting under the [`rate_limit`](#rate_limit) may take,
/// `per_client` bytes for one client and `total` across every client, 256 KiB
/// and 64 MiB by default. A message that doesn't fit gets a `Dropped`. Raise
/// `per_client` for an app whose offline replays carry big edits, and `total`
/// alongside [`max_clients`](#max_clients). Both are clamped to at least 0.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_held_bytes(per_client: 1_048_576, total: 268_435_456)
/// ```
pub fn max_held_bytes(
  builder: Builder(model, message),
  per_client per_client: Int,
  total total: Int,
) -> Builder(model, message) {
  let max_held_bytes =
    HeldBytes(per_client: int.max(per_client, 0), total: int.max(total, 0))
  Builder(..builder, max_held_bytes:)
}

/// Caps how many frames may wait in the server's mailbox, 10,000 by default.
/// Erlang only, a JavaScript server handles each frame as it arrives.
///
/// Past it [`incoming`](#incoming) sheds the frame instead of queueing work
/// for it. A connection from [`attach`](#attach) is closed, the client
/// reconnects with backoff and resyncs. Otherwise a message frame is answered
/// with a `Dropped`, in order behind the client's earlier answers, rolling
/// its edit back, and a resync, subscribe or unsubscribe is let through so
/// the client isn't left waiting. Shed frames count towards the client's
/// [`rate_limit`](#rate_limit) refusals.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_inbound_queue(frames: 50_000)
/// ```
pub fn max_inbound_queue(
  builder: Builder(model, message),
  frames frames: Int,
) -> Builder(model, message) {
  Builder(..builder, max_inbound_queue: frames)
}

/// Caps the bytes that may wait for a socket from [`attach`](#attach) to send
/// them, 16 MiB by default. Erlang only. Like
/// [`max_outbound_queue`](#max_outbound_queue), a client reading slower is cut
/// off as [`ClientEvicted`](#ServerEvent) with `SlowReader`. A frame on its
/// own always fits, so a snapshot bigger than this still reaches the client.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_outbound_bytes(bytes: 4_194_304)
/// ```
pub fn max_outbound_bytes(
  builder: Builder(model, message),
  bytes bytes: Int,
) -> Builder(model, message) {
  Builder(..builder, max_outbound_bytes: int.max(bytes, 1))
}

/// Caps how many frames may wait for a socket from [`attach`](#attach) to
/// send them, 1000 by default. Erlang only.
///
/// A client reading slower than the server writes is cut off past it,
/// reported as [`ClientEvicted`](#ServerEvent) with `SlowReader`. A `send` of
/// your own passed to [`connect`](#connect) needs a bound of its own.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_outbound_queue(frames: 200)
/// ```
pub fn max_outbound_queue(
  builder: Builder(model, message),
  frames frames: Int,
) -> Builder(model, message) {
  Builder(..builder, max_outbound_queue: frames)
}

/// Caps how many topics one client may join at once, 100 by default. It also
/// bounds the work one `Resync` or one session change costs.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_subscriptions(per_client: 50)
/// ```
pub fn max_subscriptions(
  builder: Builder(model, message),
  per_client per_client: Int,
) -> Builder(model, message) {
  Builder(..builder, max_subscriptions: per_client)
}

/// Caps the length of a topic id a client may subscribe to, 256 bytes by
/// default.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_topic_id_bytes(bytes: 64)
/// ```
pub fn max_topic_id_bytes(
  builder: Builder(model, message),
  bytes bytes: Int,
) -> Builder(model, message) {
  Builder(..builder, max_topic_id_bytes: bytes)
}

/// Caps how many topics run at once, 100,000 by default. Topic ids come from
/// clients, so past it the topic nobody has held for longest is stopped to
/// make room. If every topic is held, a subscribe is rejected with
/// `OverLimit` and a dispatch to a new topic is dropped.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.max_topics(count: 10_000)
/// ```
pub fn max_topics(
  builder: Builder(model, message),
  count count: Int,
) -> Builder(model, message) {
  Builder(..builder, max_topics: count)
}

@target(erlang)
/// Monitors the server process, letting a socket close when the server
/// restarts. Erlang only. [`attach`](#attach) already does this for you.
///
/// ```gleam
/// process.new_selector()
/// |> process.select_specific_monitor(server.monitor(app), fn(_) { Gone })
/// ```
pub fn monitor(server: Server(model, message)) -> process.Monitor {
  process.monitor(actor.watched_pid(actor.watched(server.handle)))
}

/// Starts building a server from the synced store your client also uses, and
/// the origins allowed to connect. Pipe it into [`start`](#start) or
/// [`start_supervised`](#start_supervised).
///
/// ```gleam
/// server.new(shared.store(), origins: server.AllowedOrigins([
///   "https://example.com",
/// ]))
/// |> server.start_supervised
/// ```
pub fn new(
  store: Store(model, message, Synced),
  origins origins: Origins,
) -> Builder(model, message) {
  Builder(
    store:,
    origins:,
    observers: [],
    topic_inits: [],
    max_clients: 10_000,
    max_frame_bytes: 1_048_576,
    max_held_bytes: HeldBytes(per_client: 262_144, total: 67_108_864),
    max_inbound_queue: 10_000,
    max_outbound_bytes: 16_777_216,
    max_outbound_queue: 1000,
    max_subscriptions: 100,
    max_topic_id_bytes: 256,
    max_topics: 100_000,
    rate_limit: RateLimit(per_second: 50, burst: 500),
    eviction: Eviction(refusals: option.None, within: 10_000),
    diagnostic_budget: RateLimit(per_second: 10, burst: 100),
    topic_restarts: RestartLimit(max: 5, within: 60_000),
    // the 2 in 5 default is tight for a client-influenced process
    restart_tolerance: Tolerance(intensity: 3, period: 10),
    clock: monotonic_milliseconds,
    idle_after: option.None,
  )
}

/// Adds a function that's called with every [`ServerEvent`](#ServerEvent) and
/// the server it happened on. Pipe it from [`new`](#new).
///
/// Keep it quick, every other client waits while it runs. Spawn anything slow.
///
/// ```gleam
/// server.observe(builder, fn(event, app) {
///   case event {
///     server.ClientConnected(client_id:) ->
///       server.dispatch_to(app, client_id:, message: Welcome)
///     _ -> Nil
///   }
/// })
/// ```
pub fn observe(
  builder: Builder(model, message),
  observer: fn(ServerEvent(model, message), Server(model, message)) -> Nil,
) -> Builder(model, message) {
  Builder(..builder, observers: list.append(builder.observers, [observer]))
}

@target(erlang)
/// Checks a WebSocket request's origin before upgrading it, returning an
/// error for a refused one that you answer with a 403, and refuses with
/// `TooManyClients` once the server holds [`max_clients`](#max_clients).
/// Erlang only. Pass the result to [`attach`](#attach) once the socket is up.
///
/// ```gleam
/// case server.open(app, origin:) {
///   Ok(opened) -> upgrade(request, opened)
///   Error(_) -> forbidden()
/// }
/// ```
pub fn open(
  server: Server(model, message),
  origin origin: Option(String),
) -> Result(Opened(model, message), ConnectError) {
  open_as(server, origin:, client_id: generate_client_id(), seed: [])
}

@target(erlang)
/// Like [`open`](#open), choosing the client's id and seeding its session,
/// for a socket you've authenticated. Erlang only. Pass the result to
/// [`attach`](#attach).
///
/// `seed` is applied before anything the client sends, the place for who
/// signed in. A connected id is taken over, as with
/// [`connect_as`](#connect_as).
///
/// ```gleam
/// case server.open_as(app, origin:, client_id:, seed: [SignedInAs(user)]) {
///   Ok(opened) -> upgrade(request, opened)
///   Error(_) -> forbidden()
/// }
/// ```
pub fn open_as(
  server: Server(model, message),
  origin origin: Option(String),
  client_id client_id: String,
  seed seed: List(message),
) -> Result(Opened(model, message), ConnectError) {
  use Nil <- result.try(validate_origin(server.origins, origin))
  // only a check, `attach` reserves the place once the socket is up
  case client_count(server.gate) >= server.gate.max_clients {
    True -> Error(TooManyClients)
    False -> Ok(Opened(server:, client_id:, seed:))
  }
}

/// Caps how fast one client may send, `per_second` frames on average and up to
/// `burst` at once, 50 and 500 by default. That's a few times a fast typist,
/// with room for a reconnect's resync and an offline replay.
///
/// A frame past it waits its turn. Frames are held in arrival order, up to
/// `burst` messages within [`max_held_bytes`](#max_held_bytes), and run as
/// the allowance refills. A message that can't wait, because the held queue
/// is full, gets a `Dropped`, so the client's edit rolls back. A client
/// refused more than [`evict_after`](#evict_after) allows, `burst` frames
/// within 10 seconds by default, is cut off,
/// reported as [`ClientEvicted`](#ServerEvent) with `RateLimited`.
///
/// Both values are clamped to between 1 and 1,000,000,000.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.rate_limit(per_second: 20, burst: 200)
/// ```
pub fn rate_limit(
  builder: Builder(model, message),
  per_second per_second: Int,
  burst burst: Int,
) -> Builder(model, message) {
  // a rate of 0 would never refill
  let per_second = int.clamp(per_second, min: 1, max: 1_000_000_000)
  let burst = int.clamp(burst, min: 1, max: 1_000_000_000)
  Builder(..builder, rate_limit: RateLimit(per_second:, burst:))
}

/// Checks every topic a client joined against its access rule again, for
/// rules that read state outside the session, like a database.
///
/// A topic the rule now refuses is left with a `Rejected` frame. Session
/// changes are re-checked on their own.
///
/// ```gleam
/// server.recheck_access(app, client_id:)
/// ```
pub fn recheck_access(
  server: Server(model, message),
  client_id client_id: String,
) -> Nil {
  cast(server, RecheckAccess(client_id:))
}

@target(erlang)
/// Sets how many times [`start_supervised`](#start_supervised)'s supervisor
/// restarts the server within `period` seconds before it gives up and exits
/// itself, 3 in 10 by default. Erlang only. A server in a tree of your own,
/// from [`supervised`](#supervised), follows your supervisor's tolerance
/// instead.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.restart_tolerance(intensity: 5, period: 30)
/// |> server.start_supervised
/// ```
pub fn restart_tolerance(
  builder: Builder(model, message),
  intensity intensity: Int,
  period period: Int,
) -> Builder(model, message) {
  let restart_tolerance =
    Tolerance(intensity: int.max(intensity, 0), period: int.max(period, 1))
  Builder(..builder, restart_tolerance:)
}

/// Starts the server. Pipe it from [`new`](#new). On Erlang,
/// [`start_supervised`](#start_supervised) is usually the better choice.
///
/// ```gleam
/// let assert Ok(app) =
///   server.new(shared.store(), origins: server.AnyOrigin)
///   |> server.start
/// ```
pub fn start(
  builder: Builder(model, message),
) -> Result(Server(model, message), Nil) {
  warn_about_setup(builder)
  let gate = gate_of(builder)
  actor.start_seeded(new_state(builder, gate, _), reduce:)
  |> result.map(Server(handle: _, origins: builder.origins, gate:))
}

@target(erlang)
/// Starts the server under its own supervisor, letting a crash restart it
/// instead of taking your app down. Erlang only. Call it once when your program
/// starts.
///
/// ```gleam
/// let assert Ok(#(_supervisor, app)) =
///   server.new(shared.store(), origins: server.AnyOrigin)
///   |> server.start_supervised
/// ```
pub fn start_supervised(
  builder: Builder(model, message),
) -> Result(#(static_supervisor.Supervisor, Server(model, message)), Nil) {
  // start runs in the supervisor, meaning replies go via a caller-owned channel
  let ready = process.new_subject()
  // only the first start is waited for, a restart's would pile up unread
  let starts = new_gauge()
  let child =
    supervised_as(builder, actor.new_name("lily_server"), fn(server) {
      case gauge_add(starts, 1) {
        1 -> process.send(ready, server)
        _ -> Nil
      }
    })
  let tree =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.restart_tolerance(
      intensity: builder.restart_tolerance.intensity,
      period: builder.restart_tolerance.period,
    )
    |> static_supervisor.add(child)
    |> static_supervisor.start
  case tree {
    Error(_) -> Error(Nil)
    Ok(tree) ->
      case process.receive(ready, within: 5000) {
        // a tree left running would hold the server's name
        Error(_) -> {
          process.unlink(tree.pid)
          process.kill(tree.pid)
          Error(Nil)
        }
        Ok(server) -> Ok(#(tree.data, server))
      }
  }
}

/// Stops the server and all of its topics.
pub fn stop(server: Server(model, message)) -> Nil {
  cast(server, Stop)
}

/// Stops a topic once it has gone `after` milliseconds with no subscribers and
/// no dispatches, dropping its state until [`topic_init`](#topic_init) loads
/// it again.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.stop_idle_topics(after: 60_000)
/// ```
pub fn stop_idle_topics(
  builder: Builder(model, message),
  after milliseconds: Int,
) -> Builder(model, message) {
  Builder(..builder, idle_after: option.Some(int.max(milliseconds, 0)))
}

/// Stops one topic. Its subscribers get a final `Acknowledge` and then a
/// `Rejected` with `NotFound`, keeping their last state. The next subscribe or
/// dispatch starts it again from the beginning, and the clients that held it
/// are subscribed again then, those its access rule still allows, each sent a
/// fresh snapshot.
///
/// ```gleam
/// server.stop_topic(app, topic_id: "room:1")
/// ```
pub fn stop_topic(
  server: Server(model, message),
  topic_id topic_id: String,
) -> Nil {
  cast(server, StopTopic(topic_id:))
}

@target(erlang)
/// A child specification for adding the server to your own supervision tree.
/// Erlang only. Call it once when your program starts.
///
/// ```gleam
/// static_supervisor.new(static_supervisor.OneForOne)
/// |> static_supervisor.add(
///   server.new(shared.store(), origins: server.AnyOrigin)
///   |> server.supervised,
/// )
/// |> static_supervisor.start
/// ```
pub fn supervised(
  builder: Builder(model, message),
) -> supervision.ChildSpecification(Server(model, message)) {
  supervised_as(builder, actor.new_name("lily_server"), fn(_) { Nil })
}

/// Loads the starting model of the topic with this exact `id`, for state kept
/// somewhere else like a database. Pipe it from [`new`](#new), matching a
/// [`store.topic`](./store.html#topic) declaration.
///
/// `init` runs again if the topic restarts. If it crashes, the topic starts
/// from the store's initial model instead.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.topic_init(id: "lobby", init: fn() {
///   Model(..shared.initial_model(), lobby: database.load_lobby())
/// })
/// |> server.start
/// ```
pub fn topic_init(
  builder: Builder(model, message),
  id id: String,
  init init: fn() -> model,
) -> Builder(model, message) {
  add_topic_init(builder, store.ExactId(id), fn(_) { init() })
}

/// Sets how often a crashing topic is restarted before the server gives up on
/// it, `max` crashes each within `within` milliseconds of the last, 5 within
/// 60,000 by default. A topic given up on rejects its holders with `NotFound`
/// and rejoins them when it next starts. Clamped to at least 0 and 1.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.topic_restarts(max: 10, within: 30_000)
/// ```
pub fn topic_restarts(
  builder: Builder(model, message),
  max max: Int,
  within milliseconds: Int,
) -> Builder(model, message) {
  let topic_restarts =
    RestartLimit(max: int.max(max, 0), within: int.max(milliseconds, 1))
  Builder(..builder, topic_restarts:)
}

/// Loads the starting model of every topic whose id starts with `prefix`,
/// matching a [`store.topics`](./store.html#topics) family. Mirrors
/// [`topic_init`](#topic_init).
///
/// `init` gets the rest of the id after the prefix. An exact `topic_init` id
/// beats any prefix, then the longest prefix wins.
///
/// ```gleam
/// server.new(shared.store(), origins: server.AnyOrigin)
/// |> server.topics_init(prefix: "room:", init: fn(room) {
///   Model(..shared.initial_model(), room: database.load_room(room))
/// })
/// |> server.start
/// ```
pub fn topics_init(
  builder: Builder(model, message),
  prefix prefix: String,
  init init: fn(String) -> model,
) -> Builder(model, message) {
  add_topic_init(builder, store.IdPrefix(prefix), init)
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@internal
pub type Inspection {
  Inspection(
    boot_id: String,
    client_count: Int,
    topics: Dict(String, TopicInspection),
    supervisor: actor.Supervisor,
    watched: actor.Watched,
  )
}

/// `subscriber_count` raises on Erlang once the topic has died.
@internal
pub type TopicInspection {
  TopicInspection(subscriber_count: fn() -> Int, watched: actor.Watched)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Replaces the clock the server's timing reads, in milliseconds.
@internal
pub fn clock(
  builder: Builder(model, message),
  now now: fn() -> Int,
) -> Builder(model, message) {
  Builder(..builder, clock: now)
}

/// Don't call it from an observer, which runs inside the server and would
/// wait on itself.
@internal
pub fn inspect(server: Server(model, message)) -> Result(Inspection, Nil) {
  // guarded like `cast`, calling a stopped cell raises on Erlang
  actor.rescue_or("inspect", option.None, fn() {
    actor.call(server.handle, Inspect, default: option.None)
  })
  |> option.to_result(Nil)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

// whether a snapshot is paid for by the client it goes to
type Charge {
  // it asked for it
  Charged
  // a restart or a rejoin sent it unasked
  Free
}

type Client(model, message) {
  Client(
    // which registration holds the id, a stale one's events are ignored
    token: Int,
    limiter: Limiter(model, message),
    // what the connection's `incoming` reads
    mirror: ClientMirror,
    send: fn(BitArray) -> Nil,
    // closes the socket, only a transport that can say so has one
    close: Option(fn() -> Nil),
    model: model,
    sequence: Int,
    topics: Dict(String, SubscriptionState),
    format: Option(Format),
  )
}

// the server's word on one registration, readable outside it
type ClientMirror {
  ClientMirror(
    // 1 once the registration is gone, its transport should close
    closed: Gauge,
    // 1 once `attach` killed a socket for reading too slowly, a gauge as the
    // kill's down and its `Overflowed` come from different processes
    overflowed: Gauge,
  )
}

// `AnyToken` reaches whoever holds the id now, for `connection`
type ConnectionToken {
  Token(Int)
  AnyToken
}

// when a client refused too often is cut off, `None` refusals means `burst`
type Eviction {
  Eviction(refusals: Option(Int), within: Int)
}

// what every connection needs before a frame reaches the server
type Gate(model, message) {
  Gate(
    serialiser: Serialiser(model, message),
    conform: transport.Conformer,
    max_frame_bytes: Int,
    max_inbound_queue: Int,
    max_outbound_bytes: Int,
    max_outbound_queue: Int,
    max_clients: Int,
    rate_limit: RateLimit,
    clock: fn() -> Int,
    // clients the server holds, set by the server
    registered: Gauge,
    // places taken by a connect still on its way to the server
    reserved: Gauge,
    // the running incarnation, 0 once stopped
    incarnation: Gauge,
  )
}

// a shared counter, atomics on Erlang
type Gauge

// a frame waiting for its client's allowance, answered in arrival order
type Held(model, message) {
  HeldFrame(inbound: Inbound(model, message), size: Int)
  // a frame that couldn't wait, its `Dropped` waits behind those that did
  HeldRefusal(target: transport.SyncTarget)
}

// what held frames may take, one client's and every client's together
type HeldBytes {
  HeldBytes(per_client: Int, total: Int)
}

// a frame as `incoming` hands it to the server
type Inbound(model, message) {
  Decoded(frame: transport.Protocol(model, message), format: Option(Format))
  // over `max_frame_bytes`, with the target read from its head
  Oversized(target: Option(transport.SyncTarget))
  Undecodable(failure: transport.DecodeFailure)
}

type InternalEvent(model, message) {
  ClientJoined(
    client_id: String,
    token: Int,
    send: fn(BitArray) -> Nil,
    close: Option(fn() -> Nil),
    mirror: ClientMirror,
    session: List(message),
  )
  ClientLeft(client_id: String, token: ConnectionToken)
  DispatchToAllClients(message: message)
  DispatchToClient(client_id: String, message: message)
  DispatchTopic(topic_id: String, message: message)
  IdleTopic(topic_id: String, generation: Int)
  Incoming(
    client_id: String,
    token: ConnectionToken,
    inbound: Inbound(model, message),
    size: Int,
  )
  Inspect
  // its socket's queue passed `max_outbound_queue`
  Overflowed(client_id: String, token: Int)
  RecheckAccess(client_id: String)
  // runs what the rate limit held back, in order
  RetryHeld(client_id: String, token: Int)
  // a message `incoming` shed past `max_inbound_queue`, refused in order
  Shed(client_id: String, token: ConnectionToken, target: transport.SyncTarget)
  Stop
  StopTopic(topic_id: String)
  TopicDown(id: String)
  TopicReported(topic_id: String, report: TopicReport)
}

// how a topic subscriber came to be sent to it
type Joining {
  // the client asked, admission is reported and the snapshot charged
  Asked
  // a lapsed holder brought back when its topic started, reported, not charged
  Rejoined
  // a joined holder put back after a restart, neither
  Restored
}

// a client's rate limit and diagnostics, times in milliseconds
type Limiter(model, message) {
  Limiter(
    // in thousandths of a frame, a frame gets in while it's positive and is
    // paid for after, letting a frame's real cost be charged
    allowance: Int,
    refilled_at: Int,
    // frames refused this window, and whether that was reported
    window_started_at: Int,
    refused: Int,
    reported: Bool,
    // frames over the limit in arrival order
    held: Queue(Held(model, message)),
    // resyncs, subscribes and unsubscribes among them, capped on their own
    held_controls: Int,
    held_bytes: Int,
    retry_scheduled: Bool,
    // this client's last diagnostic, and how many were held back since
    diagnosed_at: Option(Int),
    suppressed: Int,
  )
}

// how a connection reaches its registration
type Link {
  // `close` when the transport can be told to
  Registered(token: Int, mirror: ClientMirror, close: Option(fn() -> Nil))
  // rebuilt from an id by `connection`, it reaches whoever holds the id
  ById
  // an `attach` past `max_clients`, never registered
  Refused
}

type MessageSource {
  // a client, answered with an `Acknowledge` or a `Dropped`
  FromClient
  // the server, answered with a `SessionUpdate` carrying the message
  FromServer
}

type Observer(model, message) =
  fn(ServerEvent(model, message), Server(model, message)) -> Nil

// what `attach` hands its socket process
@target(erlang)
type Outbound {
  Frame(BitArray)
  Shut
}

// what a frame past the rate limit did
type Overrun {
  Waited
  // refused, these add up to an eviction
  Bounced
}

// first in first out, a front list and a reversed back, the front only empty
// when both are
type Queue(item) {
  Queue(front: List(item), back: List(item), size: Int)
}

type RateLimit {
  RateLimit(per_second: Int, burst: Int)
}

// how many crashes are tolerated, each `within` milliseconds of the last
type RestartLimit {
  RestartLimit(max: Int, within: Int)
}

// the state a client says it holds, `epoch` a topic actor's incarnation or a
// session's registration token, both offset by `epoch_base`
type Seen {
  Seen(epoch: Int, sequence: Int)
}

type ServerHandle(model, message) =
  Cell(
    ServerState(model, message),
    InternalEvent(model, message),
    Option(Inspection),
  )

type ServerState(model, message) {
  ServerState(
    // the running server itself, handed to observers
    server: Server(model, message),
    supervisor: actor.Supervisor,
    // what a client is written in until it has spoken
    format: Format,
    store: Store(model, message, Synced),
    observers: List(Observer(model, message)),
    topic_inits: List(#(store.TopicMatch, fn(String) -> model)),
    max_subscriptions: Int,
    max_topic_id_bytes: Int,
    max_topics: Int,
    max_held_bytes: HeldBytes,
    eviction: Eviction,
    diagnostic_budget: RateLimit,
    topic_restarts: RestartLimit,
    // the budget every client's diagnostics share, like a client's allowance
    diagnostic_allowance: Int,
    diagnostic_refilled_at: Int,
    // topics nobody holds, oldest first, stopped to make room at `max_topics`,
    // an entry goes stale rather than being removed and `unheld_since` says
    // which is current
    unheld: Queue(#(Int, String)),
    unheld_count: Int,
    unheld_sequence: Int,
    // what every client's held frames take, bounded together
    held_bytes_total: Int,
    idle_after: Option(Int),
    clients: Dict(String, Client(model, message)),
    topics: Dict(String, TopicEntry(model, message)),
    // clients holding a stopped topic, by topic id, rejoined when it starts
    lapsed: Dict(String, Set(String)),
    boot_id: String,
    // random per incarnation and added to every epoch, a counter that starts
    // over with the VM can't repeat one a client still holds
    epoch_base: Int,
    // a seed routed to `Session` is warned about once per incarnation
    warned_session_seed: Bool,
    // clients whose send raised this reduction, swept at the end so dead
    // connections needn't be threaded through every writer
    failed_sends: Set(String),
  )
}

type Subscriber {
  // `token` names the registration, for reports back to the server
  Subscriber(send: fn(BitArray) -> Nil, format: Format, token: Int)
}

type SubscriptionState {
  // asked for, not yet admitted by the topic
  Pending
  Joined
  // held when the topic stopped, rejoined when it starts again
  Lapsed
}

// who tells a stopped topic's holders it's gone
type Teller {
  // the topic, behind its final answers to them
  TopicTells
  ServerTells
}

// what `start_supervised`'s supervisor takes, in seconds
type Tolerance {
  Tolerance(intensity: Int, period: Int)
}

type TopicActor(model, message) =
  Cell(TopicState(model, message), TopicEvent(message), Int)

// why a topic stops
type TopicEnd {
  // on its own, its subscribers get a `Rejected`
  Removed
  // with the whole server
  ShutDown
}

// restart count lives here so a stopped topic restarts with a full budget
type TopicEntry(model, message) {
  TopicEntry(
    actor: TopicActor(model, message),
    // which actor this is, an admission from an earlier one is stale, and the
    // epoch of its snapshots
    incarnation: Int,
    restarts: Int,
    // the clients with it in `Client.topics`, pending included
    holders: Set(String),
    // bumped per idle timer, an older timer is stale
    generation: Int,
    // the live idle timer, cancelled before another is set
    idle_timer: Option(actor.Timer),
    // when it last crashed, `restarts` starts over once `topic_restarts` has
    // passed quietly
    crashed_at: Int,
    // when nobody came to hold it, its place in `unheld`
    unheld_since: Option(Int),
  )
}

type TopicEvent(message) {
  // `from` is the sending client and how to reach it, `None` for the server
  TopicDispatch(from: Option(#(String, Subscriber)), message: message)
  TopicLoad
  // a `Dropped` for a message the server refused, sent behind the topic's own
  // answers to that client
  TopicRefuse(to: #(String, Subscriber))
  TopicSendSnapshot(
    client_id: String,
    token: Int,
    subscriber: Subscriber,
    seen: Option(Seen),
  )
  TopicStop(end: TopicEnd)
  TopicSubscribe(
    client_id: String,
    token: Int,
    subscriber: Subscriber,
    joining: Joining,
    // what the client holds, its snapshot spared when that's current
    seen: Option(Seen),
  )
  TopicSubscriberCount
  TopicUnsubscribe(client_id: String)
}

// whether `find_or_start_topic` had to start it
type TopicFound {
  Running
  Started
}

type TopicReport {
  // the topic actor `incarnation` admitted this registration of the client
  Admitted(client_id: String, token: Int, incarnation: Int)
  // the topic's own loader crashed, leaving it on the initial model
  LoadFailed(reason: String)
  // `update` crashed on a message, from this client or `None` for the server
  MessageCrashed(from: Option(String), reason: String)
  // a snapshot this big went to this registration, charged to it
  SnapshotSent(client_id: String, token: Int, bytes: Int)
  // a send to this registration raised, its connection is gone
  SendFailed(client_id: String, token: Int)
}

type TopicState(model, message) {
  TopicState(
    id: String,
    incarnation: Int,
    serialiser: Serialiser(model, message),
    update: fn(model, message) -> model,
    load: Option(fn() -> model),
    report: fn(TopicReport) -> Nil,
    subscribers: Dict(String, Subscriber),
    current: model,
    sequence: Int,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

// a frame's cost goes up by one for each this many bytes, on the wire or in
// a snapshot it causes
const bytes_per_cost = 16_384

fn add_holder(
  state: ServerState(model, message),
  topic_id: String,
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Error(_) -> state
    Ok(entry) ->
      put_topic(
        state,
        topic_id,
        TopicEntry(..entry, holders: set.insert(entry.holders, client_id)),
      )
      |> mark_held(topic_id)
  }
}

fn add_lapsed(
  state: ServerState(model, message),
  topic_id: String,
  client_id: String,
) -> ServerState(model, message) {
  let holders =
    dict.get(state.lapsed, topic_id)
    |> result.unwrap(set.new())
    |> set.insert(client_id)
  ServerState(..state, lapsed: dict.insert(state.lapsed, topic_id, holders))
}

fn add_topic_init(
  builder: Builder(model, message),
  match: store.TopicMatch,
  init: fn(String) -> model,
) -> Builder(model, message) {
  let others = list.filter(builder.topic_inits, fn(other) { other.0 != match })
  Builder(..builder, topic_inits: [#(match, init), ..others])
}

// handles the frame and charges for it
fn admit(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  inbound: Inbound(model, message),
  size: Int,
) -> ServerState(model, message) {
  // a resync's cursors are bounded once, for its cost and its work
  let inbound = case inbound {
    Decoded(frame: transport.Resync(cursors:), format:) ->
      Decoded(
        frame: transport.Resync(distinct_cursors(state, cursors)),
        format:,
      )
    Decoded(..) | Oversized(..) | Undecodable(..) -> inbound
  }
  handle_inbound(state, client_id, client, inbound)
  |> charge(client_id, client, cost(inbound, size))
}

fn apply_to_session(
  state: ServerState(model, message),
  client_id: String,
  message: message,
  source: MessageSource,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let update = store.update_function(state.store)
      case actor.rescue(fn() { update(client.model, message) }) {
        // crash means a hostile frame or bad dispatch, drop to keep the actor
        Error(reason) ->
          case source {
            FromClient ->
              diagnose_client(
                state,
                client_id,
                transport.Warning,
                "dropped malformed session message from "
                  <> shown(client_id)
                  <> ": "
                  <> reason,
              )
              |> push_dropped(client_id, transport.Session)
            FromServer -> {
              diagnose(
                state,
                transport.Warning,
                "dropped crashing dispatch to "
                  <> shown(client_id)
                  <> ": "
                  <> reason,
              )
              state
            }
          }
        Ok(model) -> {
          let sequence = client.sequence + 1
          let state =
            put_client(state, client_id, Client(..client, model:, sequence:))
          let state = case source {
            FromClient -> {
              let state =
                push(
                  state,
                  client_id,
                  client,
                  transport.Acknowledge(target: transport.Session, sequence:),
                )
              notify(state, SessionMessageApplied(client_id:, message:, model:))
              state
            }
            FromServer ->
              push(
                state,
                client_id,
                client,
                transport.SessionUpdate(sequence:, payload: message),
              )
          }
          // an unchanged session can't change what access allows
          case model == client.model {
            True -> state
            False -> recheck_client(state, client_id)
          }
        }
      }
    }
  }
}

fn cast(
  server: Server(model, message),
  event: InternalEvent(model, message),
) -> Nil {
  let _ = delivered(server, event)
  Nil
}

// what a frame cost once handled, a session change that re-checked access
// paying for the `Allow` topics the client held when it came in
fn charge(
  state: ServerState(model, message),
  client_id: String,
  before: Client(model, message),
  cost: Int,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let rechecked = case client.model == before.model {
        True -> 0
        False -> guarded_topics(state, before)
      }
      spend(state, client_id, client, cost + rechecked)
    }
  }
}

// a big snapshot costs what its bytes would as frames
fn charge_bytes(
  state: ServerState(model, message),
  client_id: String,
  token: Int,
  bytes: Int,
) -> ServerState(model, message) {
  case current_client(state, client_id, Token(token)), bytes / bytes_per_cost {
    _, 0 | Error(_), _ -> state
    Ok(client), cost -> spend(state, client_id, client, cost)
  }
}

// fails closed, a crashing access rule refuses
fn check_access(
  state: ServerState(model, message),
  access: store.Access(model),
  client_id: String,
  topic_id: String,
  session: model,
) -> #(ServerState(model, message), Bool) {
  case access {
    store.Open -> #(state, True)
    store.Allow(predicate) ->
      case actor.rescue(fn() { predicate(client_id, topic_id, session) }) {
        Ok(allowed) -> #(state, allowed)
        Error(reason) -> #(
          diagnose_client(
            state,
            client_id,
            transport.Failure,
            "access to "
              <> shown(topic_id)
              <> " crashed for "
              <> shown(client_id)
              <> ", refused: "
              <> reason,
          ),
          False,
        )
      }
  }
}

// held plus reserved places, what `open` checks against `max_clients`
@target(erlang)
fn client_count(gate: Gate(model, message)) -> Int {
  gauge_value(gate.registered) + gauge_value(gate.reserved)
}

// closes the client's socket when its transport can be told to
fn close_client(state: ServerState(model, message), client_id: String) -> Nil {
  case dict.get(state.clients, client_id) {
    Ok(Client(close: option.Some(close), ..)) ->
      actor.rescue_or("close", Nil, close)
    Ok(Client(close: option.None, ..)) | Error(_) -> Nil
  }
}

fn compact_unheld(
  state: ServerState(model, message),
) -> ServerState(model, message) {
  let live =
    queue_to_list(state.unheld)
    |> list.filter(fn(queued) {
      case dict.get(state.topics, queued.1) {
        Ok(TopicEntry(unheld_since: option.Some(since), ..)) ->
          since == queued.0
        Ok(TopicEntry(unheld_since: option.None, ..)) | Error(_) -> False
      }
    })
  ServerState(..state, unheld: queue_from_list(live))
}

// a resync pays per distinct cursor, every frame for its size on the wire,
// and a topic it starts is charged on top
fn cost(inbound: Inbound(model, message), size: Int) -> Int {
  let base = case inbound {
    Oversized(..) -> 10
    Decoded(frame: transport.Resync(cursors:), ..) ->
      int.max(list.length(cursors), 1)
    Decoded(..) | Undecodable(..) -> 1
  }
  base + size / bytes_per_cost
}

// `AnyToken` matches whoever holds the id now
fn current_client(
  state: ServerState(model, message),
  client_id: String,
  token: ConnectionToken,
) -> Result(Client(model, message), Nil) {
  case dict.get(state.clients, client_id), token {
    Ok(client), AnyToken -> Ok(client)
    Ok(client), Token(held) if held == client.token -> Ok(client)
    Ok(_), Token(_) | Error(_), _ -> Error(Nil)
  }
}

// rescued, a restarting server's name is briefly unregistered
fn delivered(
  server: Server(model, message),
  event: InternalEvent(model, message),
) -> Bool {
  case actor.rescue(fn() { actor.send(server.handle, event) }) {
    Ok(Nil) -> True
    Error(reason) -> {
      actor.log_limited(
        "cast",
        transport.Failure,
        "lily: cast crashed: " <> reason,
      )
      False
    }
  }
}

fn diagnose(
  state: ServerState(model, message),
  level: transport.DiagnosticLevel,
  description: String,
) -> Nil {
  actor.log(level, "lily: " <> description)
  notify(state, Diagnostic(level:, message: description))
}

// at most one per client per window, and only while the shared budget lasts,
// so a hostile client can't fill the log
fn diagnose_client(
  state: ServerState(model, message),
  client_id: String,
  level: transport.DiagnosticLevel,
  description: String,
) -> ServerState(model, message) {
  let now = state.server.gate.clock()
  case dict.get(state.clients, client_id) {
    Error(_) -> {
      let #(state, allowed) = take_diagnostic(state, now)
      case allowed {
        True -> diagnose(state, level, description)
        False -> Nil
      }
      state
    }
    Ok(client) -> {
      let limiter = client.limiter
      let quiet = case limiter.diagnosed_at {
        // one per client every ten seconds
        option.Some(at) -> now - at < 10_000
        option.None -> False
      }
      let #(state, allowed) = case quiet {
        True -> #(state, False)
        False -> take_diagnostic(state, now)
      }
      let limiter = case allowed {
        False -> Limiter(..limiter, suppressed: limiter.suppressed + 1)
        True -> {
          let since = case limiter.suppressed {
            0 -> ""
            count -> " (" <> int.to_string(count) <> " similar since)"
          }
          diagnose(state, level, description <> since)
          Limiter(..limiter, diagnosed_at: option.Some(now), suppressed: 0)
        }
      }
      put_client(state, client_id, Client(..client, limiter:))
    }
  }
}

// one per `key` every ten seconds, for what a client can set off from any
// number of connections
fn diagnose_limited(
  state: ServerState(model, message),
  key: String,
  level: transport.DiagnosticLevel,
  description: String,
) -> Nil {
  actor.log_limited_with(key, description, diagnose(state, level, _))
}

// bounded, and a repeated target would cost another snapshot
fn distinct_cursors(
  state: ServerState(model, message),
  cursors: List(transport.Cursor),
) -> List(transport.Cursor) {
  list.take(cursors, state.max_subscriptions + 1)
  |> list.unique
  |> list.fold([], fn(kept, cursor) {
    let target = cursor.target
    case
      list.any(kept, fn(other: transport.Cursor) { other.target == target })
    {
      True -> kept
      False -> [cursor, ..kept]
    }
  })
  |> list.reverse
}

// runs what was waiting, in order, while the client can pay
fn drain(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) ->
      case client.limiter.held.front, client.limiter.allowance > 0 {
        [HeldRefusal(target:), ..], _ ->
          pop_held(state, client_id, client)
          |> push_dropped(client_id, target)
          |> drain(client_id)
        [HeldFrame(inbound:, size:), ..], True -> {
          let state = pop_held(state, client_id, client)
          case dict.get(state.clients, client_id) {
            Ok(client) -> admit(state, client_id, client, inbound, size)
            Error(_) -> state
          }
          |> drain(client_id)
        }
        [], _ | [HeldFrame(..), ..], False -> schedule_retry(state, client_id)
      }
  }
}

fn drop_failed_sends(
  state: ServerState(model, message),
) -> ServerState(model, message) {
  use <- bool.guard(when: set.is_empty(state.failed_sends), return: state)
  let failed = state.failed_sends
  set.fold(failed, ServerState(..state, failed_sends: set.new()), fn(state, id) {
    handle_disconnect(state, id, AnyToken)
  })
}

// `why` follows the client id, a crashing route says so
fn drop_misrouted(
  state: ServerState(model, message),
  client_id: String,
  target: transport.SyncTarget,
  what: String,
  why: String,
) -> ServerState(model, message) {
  diagnose_client(
    state,
    client_id,
    transport.Warning,
    "dropped " <> what <> " from " <> shown(client_id) <> why,
  )
  |> push_dropped(client_id, target)
}

// its holders lapse, rejoining when it starts again, and are told it's gone
fn drop_topic(
  state: ServerState(model, message),
  topic_id: String,
  teller: Teller,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Error(_) -> state
    Ok(entry) -> {
      option.map(entry.idle_timer, actor.cancel_timer)
      let state = mark_held(state, topic_id)
      let state =
        ServerState(..state, topics: dict.delete(state.topics, topic_id))
      set.fold(entry.holders, state, fn(state, client_id) {
        lapse(state, client_id, topic_id, teller)
      })
    }
  }
}

// encodes and sends one frame, the size it sent and whether the send held, a
// frame that won't encode is dropped and the connection kept
fn encode_and_send(
  frame: transport.Protocol(model, message),
  serialiser: Serialiser(model, message),
  format: Format,
  label: String,
  send: fn(BitArray) -> Nil,
) -> #(Int, Bool) {
  case rescue_encode(frame, serialiser, format) {
    option.None -> #(0, True)
    option.Some(bytes) -> #(
      bit_array.byte_size(bytes),
      actor.rescue_send(label, send, bytes),
    )
  }
}

// pending included, an admission racing the revocation is undone on report
fn evict(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  subscription: SubscriptionState,
) -> ServerState(model, message) {
  leave_topic(state, client_id, topic_id, subscription)
  |> remove_subscription(client_id, topic_id)
  |> reject(client_id, topic_id, AccessDenied)
}

// reported, removed, then its socket closed
fn evict_client(
  state: ServerState(model, message),
  client_id: String,
  reason: EvictionReason,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      notify(state, ClientEvicted(client_id:, reason:))
      let state = remove_client(state, client_id, client)
      case client.close {
        option.Some(close) -> actor.rescue_or("close", Nil, close)
        option.None -> Nil
      }
      state
    }
  }
}

// one that isn't running is started, making room at `max_topics`, and
// whoever held it when it stopped rejoins, the caller checks it's declared
fn find_or_start_topic(
  state: ServerState(model, message),
  topic_id: String,
) -> Result(
  #(ServerState(model, message), TopicActor(model, message), TopicFound),
  RejectionReason,
) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) -> Ok(#(state, entry.actor, Running))
    Error(_) -> {
      // full, the topic left unheld longest makes room, a held one never does
      use state <- result.try(case dict.size(state.topics) >= state.max_topics {
        False -> Ok(state)
        True -> make_room(state) |> result.replace_error(OverLimit)
      })
      case start_topic(state, topic_id) {
        Error(Nil) -> {
          // a client picks the id, so it can make this happen at will
          diagnose_limited(
            state,
            "start",
            transport.Failure,
            "could not start topic " <> shown(topic_id),
          )
          Error(NotFound)
        }
        Ok(#(topic, incarnation)) -> {
          let entry =
            TopicEntry(
              actor: topic,
              incarnation:,
              restarts: 0,
              holders: set.new(),
              generation: 0,
              idle_timer: option.None,
              crashed_at: 0,
              unheld_since: option.None,
            )
          let state =
            put_topic(state, topic_id, entry)
            |> mark_unheld(topic_id)
            |> schedule_idle(topic_id)
            |> rejoin(topic_id, topic)
          Ok(#(state, topic, Started))
        }
      }
    }
  }
}

fn forget_topic(
  state: ServerState(model, message),
  id: String,
  why: String,
) -> ServerState(model, message) {
  diagnose_limited(
    state,
    "forget",
    transport.Failure,
    "gave up on topic " <> shown(id) <> ", " <> why,
  )
  drop_topic(state, id, ServerTells)
}

fn gate_of(builder: Builder(model, message)) -> Gate(model, message) {
  Gate(
    serialiser: store.serialiser_of(builder.store),
    conform: transport.message_conformer(store.schema_of(builder.store)),
    max_frame_bytes: builder.max_frame_bytes,
    max_inbound_queue: builder.max_inbound_queue,
    max_outbound_bytes: builder.max_outbound_bytes,
    max_outbound_queue: builder.max_outbound_queue,
    max_clients: builder.max_clients,
    rate_limit: builder.rate_limit,
    clock: builder.clock,
    registered: new_gauge(),
    reserved: new_gauge(),
    incarnation: new_gauge(),
  )
}

// the topics a client holds whose access rule has to run again
fn guarded_topics(
  state: ServerState(model, message),
  client: Client(model, message),
) -> Int {
  dict.fold(client.topics, 0, fn(count, topic_id, subscription) {
    case subscription, store.access_for(state.store, topic_id) {
      Pending, Ok(store.Allow(_)) | Joined, Ok(store.Allow(_)) -> count + 1
      Lapsed, _ | Pending, _ | Joined, _ -> count
    }
  })
}

// an admission from an actor that has since stopped or restarted is stale,
// undoing it could unsubscribe the client from a successor
fn handle_admitted(
  state: ServerState(model, message),
  client_id: String,
  token: Int,
  incarnation: Int,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id), dict.get(state.topics, topic_id) {
    Ok(client), Ok(entry)
      if client.token == token && entry.incarnation == incarnation
    ->
      case dict.get(client.topics, topic_id) {
        Ok(Pending) -> {
          let state = set_subscription(state, client_id, topic_id, Joined)
          notify(state, Subscribed(client_id:, topic_id:))
          state
        }
        Ok(Joined) | Ok(Lapsed) -> state
        Error(_) -> {
          actor.send(entry.actor, TopicUnsubscribe(client_id:))
          state
        }
      }
    _, _ -> state
  }
}

fn handle_connect(
  state: ServerState(model, message),
  client_id: String,
  token: Int,
  send: fn(BitArray) -> Nil,
  close: Option(fn() -> Nil),
  mirror: ClientMirror,
  session: List(message),
) -> ServerState(model, message) {
  let now = state.server.gate.clock()
  let fresh =
    Limiter(
      allowance: state.server.gate.rate_limit.burst * 1000,
      refilled_at: now,
      window_started_at: now,
      refused: 0,
      reported: False,
      held: queue_from_list([]),
      held_controls: 0,
      held_bytes: 0,
      retry_scheduled: False,
      diagnosed_at: option.None,
      suppressed: 0,
    )
  // a reused id replaces the old connection, only its budget carries over, so
  // reconnecting under one id can't buy a fresh burst
  let limiter = case dict.get(state.clients, client_id) {
    Ok(old) ->
      Limiter(
        ..fresh,
        allowance: old.limiter.allowance,
        refilled_at: old.limiter.refilled_at,
        window_started_at: old.limiter.window_started_at,
        refused: old.limiter.refused,
        reported: old.limiter.reported,
        diagnosed_at: old.limiter.diagnosed_at,
        suppressed: old.limiter.suppressed,
      )
    Error(Nil) -> fresh
  }
  let state = evict_client(state, client_id, Superseded)
  let model = store.get_model(state.store)
  let client =
    Client(
      token:,
      limiter:,
      mirror:,
      send:,
      close:,
      model:,
      sequence: 0,
      topics: dict.new(),
      format: option.None,
    )
  let state = put_client(state, client_id, client)
  // counted as registered before the reservation goes, the cap never dips
  gauge_set(state.server.gate.registered, dict.size(state.clients))
  gauge_release(state.server.gate.reserved)
  let state =
    state
    |> push(
      client_id,
      client,
      transport.Version(
        hash: state.boot_id,
        protocol: transport.protocol_version,
      ),
    )
    |> push(client_id, client, transport.Connected(client_id:))
  // seeds applied in the actor land before this client's first frame
  let state =
    list.fold(session, state, fn(state, message) {
      warn_about_seed(state, message)
      |> apply_to_session(client_id, message, FromServer)
    })
  notify(state, ClientConnected(client_id:))
  state
}

fn handle_disconnect(
  state: ServerState(model, message),
  client_id: String,
  token: ConnectionToken,
) -> ServerState(model, message) {
  // close callback and dead process can both land, report only once, and a
  // socket `attach` killed is reported as the slow reader it was
  case current_client(state, client_id, token) {
    Error(_) -> state
    Ok(client) ->
      case gauge_value(client.mirror.overflowed) {
        0 -> remove_client(state, client_id, client)
        _ -> evict_client(state, client_id, SlowReader)
      }
  }
}

fn handle_dispatch_topic(
  state: ServerState(model, message),
  topic_id: String,
  message: message,
) -> ServerState(model, message) {
  let found = case store.access_for(state.store, topic_id) {
    Error(Nil) -> Error(", no topic is declared for it")
    Ok(_) ->
      find_or_start_topic(state, topic_id)
      |> result.map_error(fn(reason) {
        case reason {
          OverLimit -> ", the topic limit is reached and every topic is held"
          AccessDenied | NotFound -> ", the topic would not start"
        }
      })
  }
  case found {
    Ok(#(state, topic, _)) -> {
      actor.send(topic, TopicDispatch(from: option.None, message:))
      // in use, so it moves to the back of the line to be stopped for room
      case dict.get(state.topics, topic_id) {
        Ok(entry) ->
          case set.is_empty(entry.holders) {
            True ->
              mark_held(state, topic_id)
              |> mark_unheld(topic_id)
              |> schedule_idle(topic_id)
            False -> state
          }
        Error(_) -> state
      }
    }
    Error(why) -> {
      diagnose(
        state,
        transport.Warning,
        "dropped a dispatch to " <> shown(topic_id) <> why,
      )
      state
    }
  }
}

fn handle_frame(
  state: ServerState(model, message),
  client_id: String,
  frame: transport.Protocol(model, message),
) -> ServerState(model, message) {
  case frame {
    transport.SessionMessage(payload:) ->
      case route_of(state, payload) {
        Ok(store.Session) ->
          apply_to_session(state, client_id, payload, FromClient)
        Ok(store.Topic(_)) | Ok(store.Local) ->
          drop_misrouted(
            state,
            client_id,
            transport.Session,
            "a session message",
            " that the store routes elsewhere",
          )
        Error(reason) ->
          drop_misrouted(
            state,
            client_id,
            transport.Session,
            "a session message",
            ", the store's route crashed on it: " <> reason,
          )
      }

    transport.TopicMessage(topic_id:, payload:) ->
      handle_topic_message(state, client_id, topic_id, payload)

    transport.Subscribe(topic_id:) ->
      handle_subscribe(state, client_id, topic_id, option.None)

    transport.Unsubscribe(topic_id:) ->
      handle_unsubscribe(state, client_id, topic_id)

    transport.Resync(cursors:) ->
      list.fold(cursors, state, fn(state, cursor) {
        handle_resync(state, client_id, cursor)
      })

    // server-to-client variants, never legitimately arrive here
    transport.Acknowledge(_, _)
    | transport.Connected(_)
    | transport.Dropped(_)
    | transport.Rejected(_, _)
    | transport.SessionUpdate(_, _)
    | transport.Snapshot(..)
    | transport.TopicUpdate(_, _, _)
    | transport.Unchanged(_)
    | transport.Version(..) -> state
  }
}

fn handle_idle_topic(
  state: ServerState(model, message),
  topic_id: String,
  generation: Int,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) if entry.generation == generation ->
      case set.is_empty(entry.holders) {
        True -> handle_stop_topic(state, topic_id)
        False -> state
      }
    _ -> state
  }
}

fn handle_inbound(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  inbound: Inbound(model, message),
) -> ServerState(model, message) {
  case inbound {
    Oversized(target:) -> {
      let state =
        diagnose_client(
          state,
          client_id,
          transport.Warning,
          "dropped an oversized frame from " <> shown(client_id),
        )
      case target {
        option.Some(target) -> push_dropped(state, client_id, target)
        option.None -> state
      }
    }

    Undecodable(failure: transport.Nonconforming(target:)) -> {
      let why = case option.is_some(store.schema_of(state.store)) {
        True -> " that fails the schema"
        False -> " whose payload failed to decode"
      }
      diagnose_client(
        state,
        client_id,
        transport.Warning,
        "dropped a message from " <> shown(client_id) <> why,
      )
      |> push_dropped(client_id, target)
    }

    Undecodable(failure: transport.Malformed) ->
      diagnose_client(
        state,
        client_id,
        transport.Warning,
        "dropped a frame from " <> shown(client_id) <> " that failed to decode",
      )

    Decoded(frame:, format:) ->
      learn_format(state, client_id, client, format)
      |> handle_frame(client_id, frame)
  }
}

// rate limited, a frame gets in while the client has allowance and nothing
// is waiting ahead of it, and is paid for once handled
fn handle_incoming(
  state: ServerState(model, message),
  client_id: String,
  token: ConnectionToken,
  inbound: Inbound(model, message),
  size: Int,
) -> ServerState(model, message) {
  case current_client(state, client_id, token) {
    // gone, never here, or an older registration of the id
    Error(_) -> state
    Ok(client) -> {
      let now = state.server.gate.clock()
      let limiter = refill_limiter(client.limiter, state, now)
      let client = Client(..client, limiter:)
      let state = put_client(state, client_id, client)
      // only a client with frames waiting has any to run first
      let #(state, client) = case limiter.held.size {
        0 -> #(state, Ok(client))
        _ -> {
          let state = drain(state, client_id)
          #(state, dict.get(state.clients, client_id))
        }
      }
      case client {
        Error(_) -> state
        Ok(client) ->
          case client.limiter.allowance > 0 && client.limiter.held.size == 0 {
            True -> admit(state, client_id, client, inbound, size)
            False -> hold(state, client_id, client, inbound, size, now)
          }
      }
    }
  }
}

// a client back from a reconnect, a held topic is snapshotted again and a lost
// one subscribed again, either answered `Unchanged` when the cursor names the
// state it's still in
fn handle_resync(
  state: ServerState(model, message),
  client_id: String,
  cursor: transport.Cursor,
) -> ServerState(model, message) {
  let seen = case cursor {
    transport.Known(epoch:, sequence:, ..) ->
      option.Some(Seen(epoch:, sequence:))
    transport.Unknown(..) -> option.None
  }
  case dict.get(state.clients, client_id), cursor.target {
    Error(_), _ -> state
    // a session's epoch is its registration, a reconnect always starts over
    Ok(client), transport.Session -> {
      let epoch = state.epoch_base + client.token
      case seen == option.Some(Seen(epoch:, sequence: client.sequence)) {
        True ->
          push(state, client_id, client, transport.Unchanged(transport.Session))
        False -> {
          let #(state, bytes) =
            push_measured(
              state,
              client_id,
              client,
              transport.Snapshot(
                target: transport.Session,
                epoch:,
                sequence: client.sequence,
                state: client.model,
              ),
            )
          charge_bytes(state, client_id, client.token, bytes)
        }
      }
    }
    Ok(client), transport.Topic(topic_id) ->
      case dict.get(client.topics, topic_id), dict.get(state.topics, topic_id) {
        Ok(Joined), Ok(entry) ->
          case still_permitted(state, client_id, client.model, topic_id) {
            #(state, False) -> evict(state, client_id, topic_id, Joined)
            #(state, True) -> {
              actor.send(
                entry.actor,
                TopicSendSnapshot(
                  client_id:,
                  token: client.token,
                  subscriber: subscriber_of(state, client),
                  seen:,
                ),
              )
              state
            }
          }
        // its snapshot is on the way, but the rule may have changed since
        Ok(Pending), Ok(_) ->
          case still_permitted(state, client_id, client.model, topic_id) {
            #(state, False) -> evict(state, client_id, topic_id, Pending)
            #(state, True) -> state
          }
        // stopped, it rejoins when the topic starts and a resync won't start it
        Ok(Lapsed), _ -> state
        Ok(Joined), Error(_) | Ok(Pending), Error(_) | Error(_), _ ->
          handle_subscribe(state, client_id, topic_id, seen)
      }
  }
}

fn handle_retry(
  state: ServerState(model, message),
  client_id: String,
  token: Int,
) -> ServerState(model, message) {
  case current_client(state, client_id, Token(token)) {
    Error(_) -> state
    Ok(client) -> {
      let limiter =
        Limiter(
          ..refill_limiter(client.limiter, state, state.server.gate.clock()),
          retry_scheduled: False,
        )
      put_limiter(state, client_id, client, limiter)
      |> drain(client_id)
    }
  }
}

// refused like a frame past the rate limit, in line behind what's waiting
fn handle_shed(
  state: ServerState(model, message),
  client_id: String,
  token: ConnectionToken,
  target: transport.SyncTarget,
) -> ServerState(model, message) {
  case current_client(state, client_id, token) {
    Error(_) -> state
    Ok(_) ->
      refuse(state, client_id, target)
      |> note_over_limit(client_id, state.server.gate.clock(), Bounced)
  }
}

fn handle_stop_topic(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Error(_) -> state
    Ok(entry) -> {
      // ahead of the halt, a late down would restart a same-id successor
      let _ = actor.unwatch(state.server.handle, down: TopicDown(id: topic_id))
      actor.send(entry.actor, TopicStop(end: Removed))
      drop_topic(state, topic_id, TopicTells)
    }
  }
}

// a topic already held is ignored, its snapshot is already on the way, and a
// lapsed one the client asks for again starts over
fn handle_subscribe(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  seen: Option(Seen),
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) ->
      case
        dict.get(client.topics, topic_id),
        dict.has_key(state.topics, topic_id)
      {
        Ok(Pending), True | Ok(Joined), True -> state
        // lapsed, or a stale entry, subscribed again from scratch
        Ok(subscription), _ ->
          leave_topic(state, client_id, topic_id, subscription)
          |> remove_subscription(client_id, topic_id)
          |> handle_subscribe(client_id, topic_id, seen)
        Error(_), _ -> subscribe_fresh(state, client_id, client, topic_id, seen)
      }
  }
}

// gives up after `topic_restarts` crashes each within its window of the last
fn handle_topic_down(
  state: ServerState(model, message),
  id: String,
) -> ServerState(model, message) {
  let now = state.server.gate.clock()
  case dict.get(state.topics, id) {
    Error(_) -> state
    Ok(entry) -> {
      let limit = state.topic_restarts
      let restarts = case now - entry.crashed_at > limit.within {
        True -> 0
        False -> entry.restarts
      }
      case restarts >= limit.max, start_topic(state, id) {
        True, _ ->
          forget_topic(
            state,
            id,
            "it crashed " <> int.to_string(restarts + 1) <> " times",
          )
        False, Error(Nil) -> forget_topic(state, id, "it would not restart")
        False, Ok(#(topic, incarnation)) -> {
          let state =
            reinstate_topic(state, id, topic, incarnation, restarts + 1)
          case dict.get(state.topics, id) {
            Ok(entry) ->
              put_topic(state, id, TopicEntry(..entry, crashed_at: now))
            Error(Nil) -> state
          }
        }
      }
    }
  }
}

fn handle_topic_message(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  message: message,
) -> ServerState(model, message) {
  let target = transport.Topic(topic_id)
  let what = "a message for " <> shown(topic_id)
  case route_of(state, message), dict.get(state.clients, client_id) {
    Error(reason), _ ->
      drop_misrouted(
        state,
        client_id,
        target,
        what,
        ", the store's route crashed on it: " <> reason,
      )
    Ok(route), _ if route != store.Topic(topic_id) ->
      drop_misrouted(
        state,
        client_id,
        target,
        what,
        " that the store routes elsewhere",
      )
    Ok(_), Error(_) -> state
    Ok(_), Ok(client) ->
      case dict.get(client.topics, topic_id), dict.get(state.topics, topic_id) {
        Ok(Pending), Ok(entry) | Ok(Joined), Ok(entry) -> {
          notify(state, TopicMessageReceived(client_id:, topic_id:, message:))
          let from = #(client_id, subscriber_of(state, client))
          actor.send(
            entry.actor,
            TopicDispatch(from: option.Some(from), message:),
          )
          state
        }
        Ok(Lapsed), _
        | Ok(Pending), Error(_)
        | Ok(Joined), Error(_)
        | Error(_), _
        ->
          diagnose_client(
            state,
            client_id,
            transport.Warning,
            "dropped "
              <> what
              <> " from "
              <> shown(client_id)
              <> ", which hasn't joined it",
          )
          |> push_dropped(client_id, target)
      }
  }
}

fn handle_topic_report(
  state: ServerState(model, message),
  topic_id: String,
  report: TopicReport,
) -> ServerState(model, message) {
  case report {
    Admitted(client_id:, token:, incarnation:) ->
      handle_admitted(state, client_id, token, incarnation, topic_id)
    LoadFailed(reason:) -> {
      diagnose_limited(
        state,
        "load",
        transport.Failure,
        "loading topic "
          <> shown(topic_id)
          <> " crashed, it started from the initial model: "
          <> reason,
      )
      state
    }
    MessageCrashed(from: option.Some(client_id), reason:) ->
      diagnose_client(
        state,
        client_id,
        transport.Warning,
        "dropped malformed topic message on "
          <> shown(topic_id)
          <> " from "
          <> shown(client_id)
          <> ": "
          <> reason,
      )
    SnapshotSent(client_id:, token:, bytes:) ->
      charge_bytes(state, client_id, token, bytes)
    // the topic found the connection dead, the server forgets it the same way
    SendFailed(client_id:, token:) ->
      handle_disconnect(state, client_id, Token(token))
    MessageCrashed(from: option.None, reason:) -> {
      diagnose(
        state,
        transport.Warning,
        "dropped crashing dispatch to topic "
          <> shown(topic_id)
          <> ": "
          <> reason,
      )
      state
    }
  }
}

// a topic this client doesn't hold is none of its business
fn handle_unsubscribe(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  let subscription =
    dict.get(state.clients, client_id)
    |> result.try(fn(client) { dict.get(client.topics, topic_id) })
  case subscription {
    Error(_) -> state
    Ok(subscription) ->
      leave_topic(state, client_id, topic_id, subscription)
      |> remove_subscription(client_id, topic_id)
  }
}

// a frame the client can't pay for yet, or behind others waiting, waits in
// order, and one that can't wait is refused with its `Dropped` in line
fn hold(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  inbound: Inbound(model, message),
  size: Int,
  now: Int,
) -> ServerState(model, message) {
  let state = case inbound {
    Decoded(format:, ..) -> learn_format(state, client_id, client, format)
    Oversized(..) | Undecodable(..) -> state
  }
  let limiter = client.limiter
  let control = is_control(inbound)
  let fits =
    limiter.held_bytes + size <= state.max_held_bytes.per_client
    && state.held_bytes_total + size <= state.max_held_bytes.total
  let room = case control {
    True -> fits && limiter.held_controls <= state.max_subscriptions
    False ->
      fits
      && limiter.held.size - limiter.held_controls
      < state.server.gate.rate_limit.burst
  }
  let state = case inbound, message_target_of(inbound), room {
    Decoded(..), _, True | Undecodable(..), option.Some(_), True ->
      push_held(state, client_id, HeldFrame(inbound:, size:), size, control)
      |> note_over_limit(client_id, now, Waited)
    Decoded(..), option.Some(target), False
    | Undecodable(..), option.Some(target), False
    | Oversized(..), option.Some(target), _
    ->
      refuse(state, client_id, target)
      |> note_over_limit(client_id, now, Bounced)
    // a control that can't wait can't be answered, so a connection that can
    // close is closed and resyncs
    Decoded(..), option.None, False -> {
      close_client(state, client_id)
      note_over_limit(state, client_id, now, Bounced)
    }
    Undecodable(..), option.None, _ | Oversized(..), option.None, _ ->
      note_over_limit(state, client_id, now, Bounced)
  }
  schedule_retry(state, client_id)
}

// a resync, subscribe or unsubscribe, small and capped on their own
fn is_control(inbound: Inbound(model, message)) -> Bool {
  case inbound {
    Decoded(frame: transport.Resync(..), ..)
    | Decoded(frame: transport.Subscribe(..), ..)
    | Decoded(frame: transport.Unsubscribe(..), ..) -> True
    Decoded(..) | Oversized(..) | Undecodable(..) -> False
  }
}

// a holder of a stopped topic, kept so it counts towards its cap and rejoins
fn lapse(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  teller: Teller,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let joined = dict.get(client.topics, topic_id) == Ok(Joined)
      let topics = dict.insert(client.topics, topic_id, Lapsed)
      let state =
        put_client(state, client_id, Client(..client, topics:))
        |> add_lapsed(topic_id, client_id)
      case joined {
        True -> notify(state, Unsubscribed(client_id:, topic_id:))
        False -> Nil
      }
      case teller {
        TopicTells -> {
          notify(
            state,
            SubscriptionRejected(client_id:, topic_id:, reason: NotFound),
          )
          state
        }
        ServerTells -> reject(state, client_id, topic_id, NotFound)
      }
    }
  }
}

// the first frame a client sends says which format it reads
fn learn_format(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  format: Option(Format),
) -> ServerState(model, message) {
  case client.format, format {
    option.None, option.Some(_) ->
      put_client(state, client_id, Client(..client, format:))
    option.Some(_), _ | option.None, option.None -> state
  }
}

// the client lets go of a topic, its entry in `Client.topics` is the
// caller's to remove
fn leave_topic(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  subscription: SubscriptionState,
) -> ServerState(model, message) {
  case subscription {
    Lapsed -> remove_lapsed(state, topic_id, client_id)
    Joined -> {
      with_topic(state, topic_id, actor.send(_, TopicUnsubscribe(client_id:)))
      notify(state, Unsubscribed(client_id:, topic_id:))
      remove_holder(state, topic_id, client_id)
    }
    Pending -> {
      with_topic(state, topic_id, actor.send(_, TopicUnsubscribe(client_id:)))
      remove_holder(state, topic_id, client_id)
    }
  }
}

// the token a frame goes with, `Error` once the connection was cut off or its
// server incarnation has gone
fn live_token(
  connection: Connection(model, message),
) -> Result(ConnectionToken, Nil) {
  let current =
    gauge_value(connection.server.gate.incarnation) == connection.incarnation
  case connection.link, current {
    _, False | Refused, True -> Error(Nil)
    ById, True -> Ok(AnyToken)
    Registered(token:, mirror:, ..), True ->
      case gauge_value(mirror.closed) {
        0 -> Ok(Token(token))
        _ -> Error(Nil)
      }
  }
}

// the topic left unheld longest, stopped, if any is
fn make_room(
  state: ServerState(model, message),
) -> Result(ServerState(model, message), Nil) {
  case queue_pop(state.unheld) {
    Error(Nil) -> Error(Nil)
    Ok(#(#(since, topic_id), unheld)) -> {
      let state = ServerState(..state, unheld:)
      case dict.get(state.topics, topic_id) {
        Ok(TopicEntry(unheld_since: option.Some(current), ..))
          if current == since
        -> Ok(handle_stop_topic(state, topic_id))
        // stale, the topic was held again or is gone
        _ -> make_room(state)
      }
    }
  }
}

fn mark_held(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Ok(TopicEntry(unheld_since: option.Some(_), ..) as entry) ->
      ServerState(
        ..put_topic(
          state,
          topic_id,
          TopicEntry(..entry, unheld_since: option.None),
        ),
        unheld_count: state.unheld_count - 1,
      )
    Ok(TopicEntry(unheld_since: option.None, ..)) | Error(_) -> state
  }
}

// queued with a sequence, an entry whose topic has moved on is stale and the
// queue is rebuilt once stale entries outnumber live ones
fn mark_unheld(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Ok(TopicEntry(unheld_since: option.None, ..) as entry) -> {
      let since = state.unheld_sequence + 1
      let state =
        ServerState(
          ..put_topic(
            state,
            topic_id,
            TopicEntry(..entry, unheld_since: option.Some(since)),
          ),
          unheld: queue_push(state.unheld, #(since, topic_id)),
          unheld_count: state.unheld_count + 1,
          unheld_sequence: since,
        )
      case state.unheld.size > 2 * state.unheld_count + 1024 {
        True -> compact_unheld(state)
        False -> state
      }
    }
    Ok(TopicEntry(unheld_since: option.Some(_), ..)) | Error(_) -> state
  }
}

// a message's target, the `Dropped` a refusal owes
fn message_target_of(
  inbound: Inbound(model, message),
) -> Option(transport.SyncTarget) {
  case inbound {
    Decoded(frame: transport.SessionMessage(..), ..) ->
      option.Some(transport.Session)
    Decoded(frame: transport.TopicMessage(topic_id:, ..), ..) ->
      option.Some(transport.Topic(topic_id))
    Undecodable(failure: transport.Nonconforming(target:)) ->
      option.Some(target)
    Oversized(target:) -> target
    Decoded(..) | Undecodable(failure: transport.Malformed) -> option.None
  }
}

fn new_state(
  builder: Builder(model, message),
  gate: Gate(model, message),
  toolkit: actor.Toolkit(
    ServerState(model, message),
    InternalEvent(model, message),
    Option(Inspection),
  ),
) -> ServerState(model, message) {
  // a fresh incarnation holds no clients, the old one's are gone with it, and
  // a connect in flight lands here without its reservation being missed much
  gauge_set(gate.registered, 0)
  gauge_set(gate.reserved, 0)
  gauge_set(gate.incarnation, unique_integer())
  ServerState(
    server: Server(handle: toolkit.cell, origins: builder.origins, gate:),
    supervisor: toolkit.supervisor,
    format: transport.server_format(gate.serialiser),
    store: builder.store,
    observers: builder.observers,
    topic_inits: builder.topic_inits,
    max_subscriptions: builder.max_subscriptions,
    max_topic_id_bytes: builder.max_topic_id_bytes,
    max_topics: builder.max_topics,
    max_held_bytes: builder.max_held_bytes,
    eviction: builder.eviction,
    diagnostic_budget: builder.diagnostic_budget,
    topic_restarts: builder.topic_restarts,
    diagnostic_allowance: builder.diagnostic_budget.burst * 1000,
    diagnostic_refilled_at: gate.clock(),
    unheld: queue_from_list([]),
    unheld_count: 0,
    unheld_sequence: 0,
    held_bytes_total: 0,
    idle_after: builder.idle_after,
    clients: dict.new(),
    topics: dict.new(),
    lapsed: dict.new(),
    // fresh per incarnation, lets a client tell a restart from a reconnect
    boot_id: random_hex(8),
    epoch_base: random_hex(5) |> int.base_parse(16) |> result.unwrap(0),
    warned_session_seed: False,
    failed_sends: set.new(),
  )
}

// lowercased, one trailing '/' dropped, 'null' only matches if listed
fn normalise_origin(origin: String) -> String {
  let lowered = string.lowercase(origin)
  case string.ends_with(lowered, "/") {
    True -> string.drop_end(lowered, 1)
    False -> lowered
  }
}

// reported once per window, cut off past the eviction's refusals in one
fn note_over_limit(
  state: ServerState(model, message),
  client_id: String,
  now: Int,
  overrun: Overrun,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let limiter = case now - client.limiter.window_started_at {
        elapsed if elapsed >= state.eviction.within ->
          Limiter(
            ..client.limiter,
            window_started_at: now,
            refused: 0,
            reported: False,
          )
        _ -> client.limiter
      }
      let count = case overrun {
        Bounced -> limiter.refused + 1
        Waited -> limiter.refused
      }
      let state =
        put_limiter(
          state,
          client_id,
          client,
          Limiter(..limiter, refused: count, reported: True),
        )
      let state = case limiter.reported {
        True -> state
        False -> {
          notify(state, ClientThrottled(client_id:))
          diagnose_client(
            state,
            client_id,
            transport.Warning,
            "throttled " <> shown(client_id) <> ", it went past its rate limit",
          )
        }
      }
      let refusals =
        option.unwrap(
          state.eviction.refusals,
          state.server.gate.rate_limit.burst,
        )
      case count > refusals {
        True -> evict_client(state, client_id, RateLimited)
        False -> state
      }
    }
  }
}

fn notify(
  state: ServerState(model, message),
  event: ServerEvent(model, message),
) -> Nil {
  list.each(state.observers, fn(observer) {
    actor.rescue_or("observer", Nil, fn() { observer(event, state.server) })
  })
}

// the server's mailbox is past `max_inbound_queue`, always False on JavaScript
fn overloaded(server: Server(model, message)) -> Bool {
  server_queue_length(server) > server.gate.max_inbound_queue
}

// takes the head of the held queue off
fn pop_held(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
) -> ServerState(model, message) {
  let limiter = client.limiter
  case queue_pop(limiter.held) {
    Error(Nil) -> state
    Ok(#(popped, held)) -> {
      let #(size, controls) = case popped {
        HeldFrame(inbound:, size:) ->
          case is_control(inbound) {
            True -> #(size, limiter.held_controls - 1)
            False -> #(size, limiter.held_controls)
          }
        HeldRefusal(..) -> #(0, limiter.held_controls)
      }
      let limiter =
        Limiter(
          ..limiter,
          held:,
          held_controls: controls,
          held_bytes: limiter.held_bytes - size,
        )
      ServerState(..state, held_bytes_total: state.held_bytes_total - size)
      |> put_limiter(client_id, client, limiter)
    }
  }
}

// a serialiser crash drops the frame, keeps the connection
fn push(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  frame: transport.Protocol(model, message),
) -> ServerState(model, message) {
  push_measured(state, client_id, client, frame).0
}

// in place of the `Acknowledge` so the client rolls its edit back, a topic's
// goes through the topic behind its answers to that client's earlier messages
fn push_dropped(
  state: ServerState(model, message),
  client_id: String,
  target: transport.SyncTarget,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id), target {
    Error(_), _ -> state
    Ok(client), transport.Topic(id) ->
      case dict.get(state.topics, id) {
        Ok(entry) -> {
          actor.send(
            entry.actor,
            TopicRefuse(to: #(client_id, subscriber_of(state, client))),
          )
          state
        }
        // a target's id is the client's own, cut like a rejected one
        Error(_) ->
          push(
            state,
            client_id,
            client,
            transport.Dropped(
              target: transport.Topic(truncate_bytes(
                id,
                state.max_topic_id_bytes,
              )),
            ),
          )
      }
    Ok(client), transport.Session ->
      push(
        state,
        client_id,
        client,
        transport.Dropped(target: transport.Session),
      )
  }
}

// queued behind what's already waiting
fn push_held(
  state: ServerState(model, message),
  client_id: String,
  held: Held(model, message),
  size: Int,
  control: Bool,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let limiter = client.limiter
      let controls = case control {
        True -> limiter.held_controls + 1
        False -> limiter.held_controls
      }
      let limiter =
        Limiter(
          ..limiter,
          held: queue_push(limiter.held, held),
          held_controls: controls,
          held_bytes: limiter.held_bytes + size,
        )
      ServerState(..state, held_bytes_total: state.held_bytes_total + size)
      |> put_limiter(client_id, client, limiter)
    }
  }
}

// also gives back the size it sent, for charging a snapshot
fn push_measured(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  frame: transport.Protocol(model, message),
) -> #(ServerState(model, message), Int) {
  let format = option.unwrap(client.format, state.format)
  let serialiser = state.server.gate.serialiser
  case encode_and_send(frame, serialiser, format, "client", client.send) {
    #(size, True) -> #(state, size)
    #(size, False) -> #(
      ServerState(
        ..state,
        failed_sends: set.insert(state.failed_sends, client_id),
      ),
      size,
    )
  }
}

fn put_client(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
) -> ServerState(model, message) {
  ServerState(..state, clients: dict.insert(state.clients, client_id, client))
}

fn put_limiter(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  limiter: Limiter(model, message),
) -> ServerState(model, message) {
  put_client(state, client_id, Client(..client, limiter:))
}

fn put_topic(
  state: ServerState(model, message),
  topic_id: String,
  entry: TopicEntry(model, message),
) -> ServerState(model, message) {
  ServerState(..state, topics: dict.insert(state.topics, topic_id, entry))
}

fn queue_from_list(items: List(item)) -> Queue(item) {
  Queue(front: items, back: [], size: list.length(items))
}

fn queue_pop(queue: Queue(item)) -> Result(#(item, Queue(item)), Nil) {
  case queue.front {
    [] -> Error(Nil)
    [first] -> Ok(#(first, Queue(list.reverse(queue.back), [], queue.size - 1)))
    [first, ..front] ->
      Ok(#(first, Queue(..queue, front:, size: queue.size - 1)))
  }
}

fn queue_push(queue: Queue(item), item: item) -> Queue(item) {
  case queue.front {
    [] -> Queue(front: [item], back: [], size: 1)
    _ -> Queue(..queue, back: [item, ..queue.back], size: queue.size + 1)
  }
}

fn queue_to_list(queue: Queue(item)) -> List(item) {
  list.append(queue.front, list.reverse(queue.back))
}

fn recheck_client(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) ->
      dict.fold(client.topics, state, fn(state, topic_id, subscription) {
        case subscription {
          // already told it's gone, checked again when it rejoins
          Lapsed -> state
          Pending | Joined ->
            case still_permitted(state, client_id, client.model, topic_id) {
              #(state, True) -> state
              #(state, False) -> evict(state, client_id, topic_id, subscription)
            }
        }
      })
  }
}

fn reduce(
  event: InternalEvent(model, message),
  state: ServerState(model, message),
) -> actor.CellOutcome(ServerState(model, message), Option(Inspection)) {
  case event {
    ClientJoined(client_id:, token:, send:, close:, mirror:, session:) ->
      Continue(handle_connect(
        state,
        client_id,
        token,
        send,
        close,
        mirror,
        session,
      ))

    ClientLeft(client_id:, token:) ->
      Continue(handle_disconnect(state, client_id, token))

    DispatchToAllClients(message:) ->
      dict.fold(state.clients, state, fn(state, client_id, _client) {
        apply_to_session(state, client_id, message, FromServer)
      })
      |> Continue

    DispatchToClient(client_id:, message:) ->
      Continue(apply_to_session(state, client_id, message, FromServer))

    DispatchTopic(topic_id:, message:) ->
      Continue(handle_dispatch_topic(state, topic_id, message))

    IdleTopic(topic_id:, generation:) ->
      Continue(handle_idle_topic(state, topic_id, generation))

    Incoming(client_id:, token:, inbound:, size:) ->
      Continue(handle_incoming(state, client_id, token, inbound, size))

    Inspect ->
      Reply(
        state,
        option.Some(Inspection(
          boot_id: state.boot_id,
          client_count: dict.size(state.clients),
          topics: dict.map_values(state.topics, fn(_id, entry) {
            TopicInspection(
              subscriber_count: fn() {
                // the topic may be gone by the time this runs
                actor.rescue_or("subscriber_count", -1, fn() {
                  actor.call(entry.actor, TopicSubscriberCount, default: -1)
                })
              },
              watched: actor.watched(entry.actor),
            )
          }),
          supervisor: state.supervisor,
          watched: actor.watched(state.server.handle),
        )),
      )

    Overflowed(client_id:, token:) ->
      case current_client(state, client_id, Token(token)) {
        Ok(_) -> Continue(evict_client(state, client_id, SlowReader))
        Error(Nil) -> Continue(state)
      }

    RecheckAccess(client_id:) -> Continue(recheck_client(state, client_id))

    RetryHeld(client_id:, token:) ->
      Continue(handle_retry(state, client_id, token))

    Shed(client_id:, token:, target:) ->
      Continue(handle_shed(state, client_id, token, target))

    // topics stop first, each sends a final `Acknowledge(Topic(id), sequence)`,
    // and every connection now reads as closed
    Stop -> {
      dict.each(state.topics, fn(_id, entry) {
        actor.send(entry.actor, TopicStop(end: ShutDown))
      })
      gauge_set(state.server.gate.incarnation, 0)
      Halt(state)
    }

    StopTopic(topic_id:) -> Continue(handle_stop_topic(state, topic_id))

    TopicDown(id:) -> Continue(handle_topic_down(state, id))

    TopicReported(topic_id:, report:) ->
      Continue(handle_topic_report(state, topic_id, report))
  }
  |> sweep_failed_sends
}

// an allowance in thousandths, refilled at `rate` since `since`, up to its
// burst, for a client's frames and the server's diagnostics alike
fn refill(allowance: Int, since: Int, now: Int, rate: RateLimit) -> Int {
  let elapsed = int.max(now - since, 0)
  int.min(allowance + elapsed * rate.per_second, rate.burst * 1000)
}

fn refill_limiter(
  limiter: Limiter(model, message),
  state: ServerState(model, message),
  now: Int,
) -> Limiter(model, message) {
  let rate = state.server.gate.rate_limit
  let allowance = refill(limiter.allowance, limiter.refilled_at, now, rate)
  Limiter(..limiter, allowance:, refilled_at: now)
}

// a refused edit rolls back, in line behind any frames still waiting
fn refuse(
  state: ServerState(model, message),
  client_id: String,
  target: transport.SyncTarget,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Ok(client) if client.limiter.held.size > 0 ->
      push_held(state, client_id, HeldRefusal(target:), 0, False)
    Ok(_) | Error(_) -> push_dropped(state, client_id, target)
  }
}

fn register(
  server: Server(model, message),
  token token: Int,
  mirror mirror: ClientMirror,
  send send: fn(BitArray) -> Nil,
  close close: Option(fn() -> Nil),
  client_id client_id: String,
  session session: List(message),
  watch watch: ConnectionWatch,
) -> Connection(model, message) {
  let incarnation = gauge_value(server.gate.incarnation)
  let joined =
    ClientJoined(client_id:, token:, send:, close:, mirror:, session:)
  // reserved by the caller, given back when it never reaches the server, and
  // the connection then reads as closed
  case delivered(server, joined) {
    True -> Nil
    False -> {
      gauge_release(server.gate.reserved)
      gauge_set(mirror.closed, 1)
    }
  }
  let left = ClientLeft(client_id:, token: Token(token))
  // rescued like a cast, inert on JavaScript
  actor.rescue_or("watch", Nil, fn() {
    case watch {
      WatchCaller ->
        actor.watch(server.handle, watched: actor.watched_here(), down: left)
      WatchProcess(pid) ->
        actor.watch(server.handle, watched: actor.watched_from(pid), down: left)
      Unwatched -> Nil
    }
  })
  Connection(
    server:,
    client_id:,
    link: Registered(token:, mirror:, close:),
    incarnation:,
  )
}

fn reinstate_topic(
  state: ServerState(model, message),
  id: String,
  topic: TopicActor(model, message),
  incarnation: Int,
  restarts: Int,
) -> ServerState(model, message) {
  actor.log_limited(
    "restart",
    transport.Failure,
    "lily: topic actor died, restarted: " <> shown(id),
  )
  case dict.get(state.topics, id) {
    Error(_) -> state
    Ok(entry) -> {
      set.each(entry.holders, fn(client_id) {
        let held =
          dict.get(state.clients, client_id)
          |> result.try(fn(client) {
            dict.get(client.topics, id) |> result.map(pair.new(client, _))
          })
        let joining = case held {
          Ok(#(client, Joined)) -> Ok(#(client, Restored))
          Ok(#(client, Pending)) -> Ok(#(client, Asked))
          Ok(#(_, Lapsed)) | Error(Nil) -> Error(Nil)
        }
        case joining {
          Ok(#(client, joining)) ->
            actor.send(
              topic,
              TopicSubscribe(
                client_id:,
                token: client.token,
                subscriber: subscriber_of(state, client),
                joining:,
                seen: option.None,
              ),
            )
          Error(Nil) -> Nil
        }
      })
      put_topic(
        state,
        id,
        TopicEntry(..entry, actor: topic, incarnation:, restarts:),
      )
    }
  }
}

fn reject(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  reason: RejectionReason,
) -> ServerState(model, message) {
  // an id over the cap isn't echoed back whole
  let topic_id = case reason {
    OverLimit -> truncate_bytes(topic_id, state.max_topic_id_bytes)
    AccessDenied | NotFound -> topic_id
  }
  let state = case dict.get(state.clients, client_id) {
    Ok(client) ->
      push(state, client_id, client, transport.Rejected(topic_id:, reason:))
    Error(_) -> state
  }
  notify(state, SubscriptionRejected(client_id:, topic_id:, reason:))
  state
}

// a stopped topic's lapsed holders come back when it starts, those the access
// rule still allows, the rest were told already
fn rejoin(
  state: ServerState(model, message),
  topic_id: String,
  topic: TopicActor(model, message),
) -> ServerState(model, message) {
  case dict.get(state.lapsed, topic_id) {
    Error(Nil) -> state
    Ok(holders) -> {
      let access = store.access_for(state.store, topic_id)
      let state =
        ServerState(..state, lapsed: dict.delete(state.lapsed, topic_id))
      set.fold(holders, state, fn(state, client_id) {
        case dict.get(state.clients, client_id), access {
          Ok(client), Ok(access) -> {
            let allowed =
              check_access(state, access, client_id, topic_id, client.model)
            case dict.get(client.topics, topic_id), allowed {
              Ok(Lapsed), #(state, True) -> {
                actor.send(
                  topic,
                  TopicSubscribe(
                    client_id:,
                    token: client.token,
                    subscriber: subscriber_of(state, client),
                    joining: Rejoined,
                    seen: option.None,
                  ),
                )
                set_subscription(state, client_id, topic_id, Pending)
              }
              Ok(Lapsed), #(state, False) ->
                remove_subscription(state, client_id, topic_id)
              Ok(Pending), #(state, _)
              | Ok(Joined), #(state, _)
              | Error(_), #(state, _)
              -> state
            }
          }
          Ok(_), Error(Nil) -> remove_subscription(state, client_id, topic_id)
          Error(_), _ -> state
        }
      })
    }
  }
}

fn remove_client(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
) -> ServerState(model, message) {
  // an evicted client's watch would otherwise outlive it
  let _ =
    actor.unwatch(
      state.server.handle,
      down: ClientLeft(client_id:, token: Token(client.token)),
    )
  let state =
    dict.fold(client.topics, state, fn(state, topic_id, subscription) {
      leave_topic(state, client_id, topic_id, subscription)
    })
  gauge_set(client.mirror.closed, 1)
  let state =
    ServerState(
      ..state,
      clients: dict.delete(state.clients, client_id),
      held_bytes_total: state.held_bytes_total - client.limiter.held_bytes,
    )
  gauge_set(state.server.gate.registered, dict.size(state.clients))
  notify(state, ClientDisconnected(client_id:))
  state
}

fn remove_holder(
  state: ServerState(model, message),
  topic_id: String,
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Error(_) -> state
    Ok(entry) ->
      case set.contains(entry.holders, client_id) {
        False -> state
        True -> {
          let holders = set.delete(entry.holders, client_id)
          let state = put_topic(state, topic_id, TopicEntry(..entry, holders:))
          case set.is_empty(holders) {
            True -> mark_unheld(state, topic_id) |> schedule_idle(topic_id)
            False -> state
          }
        }
      }
  }
}

fn remove_lapsed(
  state: ServerState(model, message),
  topic_id: String,
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.lapsed, topic_id) {
    Error(Nil) -> state
    Ok(holders) -> {
      let holders = set.delete(holders, client_id)
      let lapsed = case set.is_empty(holders) {
        True -> dict.delete(state.lapsed, topic_id)
        False -> dict.insert(state.lapsed, topic_id, holders)
      }
      ServerState(..state, lapsed:)
    }
  }
}

// forgets the client's entry, `leave_topic` lets go of the topic itself
fn remove_subscription(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let topics = dict.delete(client.topics, topic_id)
      put_client(state, client_id, Client(..client, topics:))
    }
  }
}

fn rescue_encode(
  frame: transport.Protocol(model, message),
  serialiser: Serialiser(model, message),
  format: Format,
) -> Option(BitArray) {
  actor.rescue_or("encode", option.None, fn() {
    option.Some(transport.encode_as(frame, serialiser:, format:))
  })
}

// takes a place up front, `False` when that passes the cap
fn reserve_client(gate: Gate(model, message)) -> Bool {
  let reserved = gauge_add(gate.reserved, 1)
  case reserved + gauge_value(gate.registered) > gate.max_clients {
    False -> True
    True -> {
      gauge_release(gate.reserved)
      False
    }
  }
}

// a decoded payload may be any constructor, `route` can crash on it
fn route_of(
  state: ServerState(model, message),
  message: message,
) -> Result(store.Route, String) {
  actor.rescue(fn() { store.route(state.store, message) })
}

fn schedule_idle(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case state.idle_after, dict.get(state.topics, topic_id) {
    option.Some(milliseconds), Ok(entry) -> {
      // one timer per topic, a subscribe and leave loop would pile them up
      option.map(entry.idle_timer, actor.cancel_timer)
      // unique, a timer from an earlier topic of the same id is never current
      let generation = unique_integer()
      let timer =
        actor.send_after(
          state.server.handle,
          milliseconds,
          IdleTopic(topic_id:, generation:),
        )
      put_topic(
        state,
        topic_id,
        TopicEntry(..entry, generation:, idle_timer: option.Some(timer)),
      )
    }
    option.None, _ | option.Some(_), Error(_) -> state
  }
}

// one timer per client, set for when it can pay for the next frame
fn schedule_retry(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let limiter = client.limiter
      case limiter.retry_scheduled || limiter.held.size == 0 {
        True -> state
        False -> {
          let owed = 1000 - limiter.allowance
          let milliseconds =
            int.min(
              owed / state.server.gate.rate_limit.per_second + 1,
              // a held frame waits at most a minute for the timer
              60_000,
            )
          let _ =
            actor.send_after(
              state.server.handle,
              milliseconds,
              RetryHeld(client_id:, token: client.token),
            )
          put_limiter(
            state,
            client_id,
            client,
            Limiter(..limiter, retry_scheduled: True),
          )
        }
      }
    }
  }
}

@target(erlang)
fn server_queue_length(server: Server(model, message)) -> Int {
  message_queue_length(actor.watched_pid(actor.watched(server.handle)))
}

@target(javascript)
fn server_queue_length(_server: Server(model, message)) -> Int {
  0
}

fn set_subscription(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  subscription: SubscriptionState,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let topics = dict.insert(client.topics, topic_id, subscription)
      put_client(state, client_id, Client(..client, topics:))
      |> add_holder(topic_id, client_id)
    }
  }
}

// a connection that can close is closed and resyncs, a message is refused in
// order behind the client's earlier answers, which the server does cheaply,
// and a control is let through so the client isn't left waiting
fn shed(
  connection: Connection(model, message),
  token: ConnectionToken,
  inbound: Inbound(model, message),
  size: Int,
  received: Received,
) -> Received {
  let server = connection.server
  let client_id = connection.client_id
  let close = case connection.link {
    Registered(close:, ..) -> close
    ById | Refused -> option.None
  }
  case close, message_target_of(inbound), is_control(inbound) {
    option.Some(close), _, _ -> {
      actor.rescue_or("close", Nil, close)
      Overloaded
    }
    option.None, option.Some(target), _ -> {
      cast(server, Shed(client_id:, token:, target:))
      Overloaded
    }
    option.None, option.None, True -> {
      cast(server, Incoming(client_id:, token:, inbound:, size:))
      received
    }
    option.None, option.None, False -> Overloaded
  }
}

// truncated and escaped, ids come from clients
fn shown(id: String) -> String {
  string.inspect(truncate_bytes(id, 64))
}

// takes `cost` frames off a client's allowance
fn spend(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  cost: Int,
) -> ServerState(model, message) {
  let allowance = client.limiter.allowance - cost * 1000
  put_limiter(state, client_id, client, Limiter(..client.limiter, allowance:))
}

// with the incarnation that tells its reports from an earlier actor's
fn start_topic(
  state: ServerState(model, message),
  id: String,
) -> Result(#(TopicActor(model, message), Int), Nil) {
  let cell = state.server.handle
  let incarnation = state.epoch_base + unique_integer()
  let load =
    store.match_topic(state.topic_inits, id, pair.first)
    |> result.map(fn(found) {
      let #(#(_, init), rest) = found
      fn() { init(rest) }
    })
    |> option.from_result
  let topic_state =
    TopicState(
      id:,
      incarnation:,
      serialiser: state.server.gate.serialiser,
      update: store.update_function(state.store),
      load:,
      report: fn(report) {
        actor.send(cell, TopicReported(topic_id: id, report:))
      },
      subscribers: dict.new(),
      current: store.get_model(state.store),
      sequence: 0,
    )
  actor.start_in_supervisor(
    state.supervisor,
    fn(toolkit) {
      case load {
        option.Some(_) -> actor.send(toolkit.cell, TopicLoad)
        option.None -> Nil
      }
      topic_state
    },
    reduce: topic_reduce,
  )
  |> result.map(fn(topic) {
    // inert on JavaScript, hence the discard
    let _ =
      actor.watch(cell, watched: actor.watched(topic), down: TopicDown(id:))
    #(topic, incarnation)
  })
}

fn still_permitted(
  state: ServerState(model, message),
  client_id: String,
  session: model,
  topic_id: String,
) -> #(ServerState(model, message), Bool) {
  case store.access_for(state.store, topic_id) {
    Ok(access) -> check_access(state, access, client_id, topic_id, session)
    Error(_) -> #(state, False)
  }
}

fn subscribe_fresh(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model, message),
  topic_id: String,
  seen: Option(Seen),
) -> ServerState(model, message) {
  let admitted = case
    within_limits(state, client, topic_id),
    store.access_for(state.store, topic_id)
  {
    Error(reason), _ -> #(state, Error(reason))
    Ok(Nil), Error(Nil) -> #(state, Error(NotFound))
    Ok(Nil), Ok(access) ->
      case check_access(state, access, client_id, topic_id, client.model) {
        #(state, False) -> #(state, Error(AccessDenied))
        #(state, True) ->
          case find_or_start_topic(state, topic_id) {
            Ok(#(state, topic, found)) -> #(state, Ok(#(topic, found)))
            Error(reason) -> #(state, Error(reason))
          }
      }
  }
  case admitted {
    #(state, Error(reason)) -> reject(state, client_id, topic_id, reason)
    #(state, Ok(#(topic, found))) -> {
      actor.send(
        topic,
        TopicSubscribe(
          client_id:,
          token: client.token,
          subscriber: subscriber_of(state, client),
          joining: Asked,
          seen:,
        ),
      )
      let state = set_subscription(state, client_id, topic_id, Pending)
      // a topic it started is paid for on top of the frame
      case found, dict.get(state.clients, client_id) {
        Started, Ok(client) -> spend(state, client_id, client, 1)
        Started, Error(_) | Running, _ -> state
      }
    }
  }
}

fn subscriber_of(
  state: ServerState(model, message),
  client: Client(model, message),
) -> Subscriber {
  Subscriber(
    send: client.send,
    format: option.unwrap(client.format, state.format),
    token: client.token,
  )
}

@target(erlang)
fn supervised_as(
  builder: Builder(model, message),
  name: actor.CellName(InternalEvent(model, message), Option(Inspection)),
  started: fn(Server(model, message)) -> Nil,
) -> supervision.ChildSpecification(Server(model, message)) {
  // outside `run`, every incarnation shares it and restarts don't warn again
  warn_about_setup(builder)
  let gate = gate_of(builder)
  // transient, `stop` ends it for good while a crash still restarts it
  supervision.worker(run: fn() {
    let cell =
      actor.start_with_supervisor(new_state(builder, gate, _), reduce:, name:)
    case cell {
      Error(_) -> Error(otp_actor.InitFailed("lily: server failed to start"))
      Ok(handle) -> {
        let server = Server(handle:, origins: builder.origins, gate:)
        started(server)
        let pid = actor.watched_pid(actor.watched(handle))
        Ok(otp_actor.Started(pid:, data: server))
      }
    }
  })
  |> supervision.restart(supervision.Transient)
}

// once per reduction, not mid-handler
fn sweep_failed_sends(
  outcome: actor.CellOutcome(ServerState(model, message), Option(Inspection)),
) -> actor.CellOutcome(ServerState(model, message), Option(Inspection)) {
  case outcome {
    Continue(state) -> Continue(drop_failed_sends(state))
    Reply(state, reply) -> Reply(drop_failed_sends(state), reply)
    Halt(state) -> Halt(state)
  }
}

fn take_diagnostic(
  state: ServerState(model, message),
  now: Int,
) -> #(ServerState(model, message), Bool) {
  let allowance =
    refill(
      state.diagnostic_allowance,
      state.diagnostic_refilled_at,
      now,
      state.diagnostic_budget,
    )
  let allowed = allowance >= 1000
  let allowance = case allowed {
    True -> allowance - 1000
    False -> allowance
  }
  #(
    ServerState(
      ..state,
      diagnostic_allowance: allowance,
      diagnostic_refilled_at: now,
    ),
    allowed,
  )
}

fn topic_encode_each(
  state: TopicState(model, message),
  frame: transport.Protocol(model, message),
  subscribers: Dict(String, Subscriber),
) -> List(#(Format, Option(BitArray))) {
  dict.fold(subscribers, [], fn(formats, _id, subscriber) {
    case list.contains(formats, subscriber.format) {
      True -> formats
      False -> [subscriber.format, ..formats]
    }
  })
  |> list.map(fn(format) {
    #(format, rescue_encode(frame, state.serialiser, format))
  })
}

fn topic_frame_in(
  frames: List(#(Format, Option(BitArray))),
  format: Format,
) -> Option(BitArray) {
  case list.key_find(frames, format) {
    Ok(frame) -> frame
    Error(Nil) -> option.None
  }
}

// sender gets the ack, everyone else the update
fn topic_handle_dispatch(
  state: TopicState(model, message),
  from: Option(#(String, Subscriber)),
  message: message,
) -> TopicState(model, message) {
  let sender = option.map(from, pair.first)
  // clients write only to subscribed topics, server dispatches are trusted
  let authorised = case sender {
    option.Some(client_id) -> dict.has_key(state.subscribers, client_id)
    option.None -> True
  }
  use <- bool.lazy_guard(when: !authorised, return: fn() {
    topic_send_dropped(state, from)
    state
  })
  // an unmatched payload crashes, drop the frame not the actor
  case actor.rescue(fn() { state.update(state.current, message) }) {
    Error(reason) -> {
      topic_report(state, MessageCrashed(from: sender, reason:))
      topic_send_dropped(state, from)
      state
    }
    Ok(current) -> {
      let sequence = state.sequence + 1
      let #(originator, others) = case sender {
        option.Some(id) -> #(
          dict.take(state.subscribers, [id]),
          dict.delete(state.subscribers, id),
        )
        option.None -> #(dict.new(), state.subscribers)
      }
      let update =
        transport.TopicUpdate(topic_id: state.id, sequence:, payload: message)
      let acknowledge =
        transport.Acknowledge(target: transport.Topic(state.id), sequence:)
      // encode only in the recipients' formats, at most two
      let update_frames = topic_encode_each(state, update, others)
      let acknowledge_frames = topic_encode_each(state, acknowledge, originator)
      let subscribers =
        topic_send_to_subscribers(state, fn(id, format) {
          case sender == option.Some(id) {
            True -> topic_frame_in(acknowledge_frames, format)
            False -> topic_frame_in(update_frames, format)
          }
        })
      TopicState(..state, current:, sequence:, subscribers:)
    }
  }
}

fn topic_handle_load(
  state: TopicState(model, message),
) -> TopicState(model, message) {
  case state.load {
    option.None -> state
    option.Some(load) ->
      case actor.rescue(load) {
        Ok(current) -> TopicState(..state, current:)
        Error(reason) -> {
          topic_report(state, LoadFailed(reason:))
          state
        }
      }
  }
}

fn topic_handle_send_snapshot(
  state: TopicState(model, message),
  client_id: String,
  token: Int,
  subscriber: Subscriber,
  seen: Option(Seen),
) -> TopicState(model, message) {
  case dict.has_key(state.subscribers, client_id) {
    True ->
      topic_send_snapshot(state, client_id, token, subscriber, Charged, seen)
    False -> Nil
  }
  state
}

// every subscriber gets its last `Acknowledge`, then a `Rejected` when the
// topic was removed on its own
fn topic_handle_stop(state: TopicState(model, message), end: TopicEnd) -> Nil {
  let acknowledge_frames =
    topic_encode_each(
      state,
      transport.Acknowledge(
        target: transport.Topic(state.id),
        sequence: state.sequence,
      ),
      state.subscribers,
    )
  let _ =
    topic_send_to_subscribers(state, fn(_, format) {
      topic_frame_in(acknowledge_frames, format)
    })
  case end {
    ShutDown -> Nil
    Removed -> {
      let rejected_frames =
        topic_encode_each(
          state,
          transport.Rejected(topic_id: state.id, reason: NotFound),
          state.subscribers,
        )
      let _ =
        topic_send_to_subscribers(state, fn(_, format) {
          topic_frame_in(rejected_frames, format)
        })
      Nil
    }
  }
}

// only the first admission is reported to the server, and a snapshot the
// client didn't ask for isn't charged
fn topic_handle_subscribe(
  state: TopicState(model, message),
  client_id: String,
  token: Int,
  subscriber: Subscriber,
  joining: Joining,
  seen: Option(Seen),
) -> TopicState(model, message) {
  // asked twice before the first admission settled, already reported
  let already_in = dict.has_key(state.subscribers, client_id)
  let state =
    TopicState(
      ..state,
      subscribers: dict.insert(state.subscribers, client_id, subscriber),
    )
  let charge = case joining {
    Asked -> Charged
    Rejoined | Restored -> Free
  }
  topic_send_snapshot(state, client_id, token, subscriber, charge, seen)
  case joining, already_in {
    Asked, False | Rejoined, False ->
      topic_report(
        state,
        Admitted(client_id:, token:, incarnation: state.incarnation),
      )
    Asked, True | Rejoined, True | Restored, _ -> Nil
  }
  state
}

fn topic_reduce(
  event: TopicEvent(message),
  state: TopicState(model, message),
) -> actor.CellOutcome(TopicState(model, message), Int) {
  case event {
    TopicDispatch(from:, message:) ->
      Continue(topic_handle_dispatch(state, from, message))

    TopicLoad -> Continue(topic_handle_load(state))

    TopicRefuse(to:) -> {
      topic_send_dropped(state, option.Some(to))
      Continue(state)
    }

    TopicSendSnapshot(client_id:, token:, subscriber:, seen:) ->
      Continue(topic_handle_send_snapshot(
        state,
        client_id,
        token,
        subscriber,
        seen,
      ))

    TopicStop(end:) -> {
      topic_handle_stop(state, end)
      Halt(state)
    }

    TopicSubscribe(client_id:, token:, subscriber:, joining:, seen:) ->
      Continue(topic_handle_subscribe(
        state,
        client_id,
        token,
        subscriber,
        joining,
        seen,
      ))

    TopicSubscriberCount -> Reply(state, dict.size(state.subscribers))

    TopicUnsubscribe(client_id:) ->
      Continue(
        TopicState(
          ..state,
          subscribers: dict.delete(state.subscribers, client_id),
        ),
      )
  }
}

fn topic_report(state: TopicState(model, message), report: TopicReport) -> Nil {
  actor.rescue_or("report", Nil, fn() { state.report(report) })
}

// the size it sent, a send that raised is reported as the dead connection it is
fn topic_send(
  state: TopicState(model, message),
  client_id: String,
  subscriber: Subscriber,
  frame: transport.Protocol(model, message),
) -> Int {
  let #(size, sent) =
    encode_and_send(
      frame,
      state.serialiser,
      subscriber.format,
      "subscriber",
      subscriber.send,
    )
  case sent {
    True -> Nil
    False ->
      topic_report(state, SendFailed(client_id:, token: subscriber.token))
  }
  size
}

// reaches a sender the topic has already let go of too
fn topic_send_dropped(
  state: TopicState(model, message),
  to: Option(#(String, Subscriber)),
) -> Nil {
  case to {
    option.Some(#(client_id, subscriber)) -> {
      let _ =
        topic_send(
          state,
          client_id,
          subscriber,
          transport.Dropped(target: transport.Topic(state.id)),
        )
      Nil
    }
    option.None -> Nil
  }
}

// a big one is reported, the server charges it to the client, and one the
// client already holds is answered `Unchanged` for nothing
fn topic_send_snapshot(
  state: TopicState(model, message),
  client_id: String,
  token: Int,
  subscriber: Subscriber,
  charge: Charge,
  seen: Option(Seen),
) -> Nil {
  let target = transport.Topic(state.id)
  let current = Seen(epoch: state.incarnation, sequence: state.sequence)
  case seen == option.Some(current) {
    True -> {
      let _ =
        topic_send(state, client_id, subscriber, transport.Unchanged(target))
      Nil
    }
    False -> {
      let bytes =
        topic_send(
          state,
          client_id,
          subscriber,
          transport.Snapshot(
            target:,
            epoch: state.incarnation,
            sequence: state.sequence,
            state: state.current,
          ),
        )
      case charge, bytes >= bytes_per_cost {
        Charged, True ->
          topic_report(state, SnapshotSent(client_id:, token:, bytes:))
        Charged, False | Free, _ -> Nil
      }
    }
  }
}

fn topic_send_to_subscribers(
  state: TopicState(model, message),
  frame_for: fn(String, Format) -> Option(BitArray),
) -> Dict(String, Subscriber) {
  let subscribers = state.subscribers
  let report = topic_report(state, _)
  use <- bool.guard(when: dict.is_empty(subscribers), return: subscribers)
  dict.fold(subscribers, subscribers, fn(kept, id, subscriber) {
    case frame_for(id, subscriber.format) {
      option.None -> kept
      option.Some(bytes) ->
        case actor.rescue_send("subscriber", subscriber.send, bytes) {
          True -> kept
          // a raising send is a dead connection, drop only that subscriber and
          // tell the server, which still counts it as joined
          False -> {
            report(SendFailed(client_id: id, token: subscriber.token))
            dict.delete(kept, id)
          }
        }
    }
  })
}

// backs off to a character boundary, a cut mid-character isn't a string
fn truncate_bytes(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  case bit_array.byte_size(bytes) <= limit {
    True -> text
    False -> truncate_bytes_at(bytes, int.max(limit, 0))
  }
}

fn truncate_bytes_at(bytes: BitArray, size: Int) -> String {
  case bit_array.slice(bytes, 0, size) |> result.try(bit_array.to_string) {
    Ok(text) -> text
    Error(Nil) if size > 0 -> truncate_bytes_at(bytes, size - 1)
    Error(Nil) -> ""
  }
}

// missing header, `AnyOrigin` accepts, an allowlist refuses
fn validate_origin(
  origins: Origins,
  origin: Option(String),
) -> Result(Nil, ConnectError) {
  case origins, origin {
    AnyOrigin, _ -> Ok(Nil)
    AllowedOrigins(_), option.None -> Error(OriginMissing)
    AllowedOrigins(allowed), option.Some(value) -> {
      let candidate = normalise_origin(value)
      case list.any(allowed, fn(one) { normalise_origin(one) == candidate }) {
        True -> Ok(Nil)
        False -> Error(OriginNotAllowed(origin: value))
      }
    }
  }
}

// a browser's Origin is scheme, host and port, an entry that can't be one
// never matches
fn warn_about_origins(origins: Origins) -> Nil {
  case origins {
    AnyOrigin -> Nil
    AllowedOrigins([]) ->
      actor.log(
        transport.Warning,
        "lily: AllowedOrigins([]) lets no browser connect, every origin is refused",
      )
    AllowedOrigins(allowed) ->
      list.each(allowed, fn(entry) {
        let origin = normalise_origin(entry)
        let why = case string.split_once(origin, "://") {
          _ if origin == "null" -> Error(Nil)
          Ok(#(_, rest)) ->
            case string.contains(rest, "/"), string.contains(rest, "*") {
              True, _ -> Ok("has a path, a browser never sends one")
              _, True -> Ok("has a wildcard, origins are matched exactly")
              False, False -> Error(Nil)
            }
          Error(Nil) -> Ok("has no scheme, write it as https://host")
        }
        case why {
          Ok(why) ->
            actor.log(
              transport.Warning,
              "lily: the allowed origin "
                <> string.inspect(entry)
                <> " "
                <> why
                <> ", so it matches nothing",
            )
          Error(Nil) -> Nil
        }
      })
  }
}

// what a seed says is trusted, a client must not be able to say it too
fn warn_about_seed(
  state: ServerState(model, message),
  message: message,
) -> ServerState(model, message) {
  case state.warned_session_seed, route_of(state, message) {
    False, Ok(store.Session) -> {
      actor.log(
        transport.Warning,
        "lily: a seed message is routed to store.Session, so a client can send "
          <> "it too, route server-written messages store.Local",
      )
      ServerState(..state, warned_session_seed: True)
    }
    True, _
    | False, Ok(store.Topic(_))
    | False, Ok(store.Local)
    | False, Error(_)
    -> state
  }
}

fn warn_about_setup(builder: Builder(model, message)) -> Nil {
  warn_about_origins(builder.origins)
  let serialiser = store.serialiser_of(builder.store)
  case
    transport.is_automatic(serialiser),
    option.is_some(store.schema_of(builder.store))
  {
    True, False ->
      actor.log(
        transport.Warning,
        "lily: the server decodes with the automatic serialiser and no schema, "
          <> "so a client can put any type in any field, generate one with "
          <> "`gleam run -m lily/dev schema` and pipe it into store.schema",
      )
    False, True ->
      actor.log(
        transport.Warning,
        "lily: store.schema only checks the automatic serialiser, it's ignored "
          <> "with a serialiser of your own",
      )
    True, True | False, False -> Nil
  }
}

fn with_topic(
  state: ServerState(model, message),
  topic_id: String,
  apply: fn(TopicActor(model, message)) -> Nil,
) -> Nil {
  case dict.get(state.topics, topic_id) {
    Ok(entry) -> apply(entry.actor)
    Error(_) -> Nil
  }
}

fn within_limits(
  state: ServerState(model, message),
  client: Client(model, message),
  topic_id: String,
) -> Result(Nil, RejectionReason) {
  let joining = !dict.has_key(client.topics, topic_id)
  case
    string.byte_size(topic_id) > state.max_topic_id_bytes,
    joining && dict.size(client.topics) >= state.max_subscriptions
  {
    False, False -> Ok(Nil)
    _, _ -> Error(OverLimit)
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

// the count after adding `delta`
@external(erlang, "lily_server_ffi", "gauge_add")
@external(javascript, "./server.ffi.mjs", "gaugeAdd")
fn gauge_add(gauge: Gauge, delta: Int) -> Int

// takes one off unless it's already zero
@external(erlang, "lily_server_ffi", "gauge_release")
@external(javascript, "./server.ffi.mjs", "gaugeRelease")
fn gauge_release(gauge: Gauge) -> Nil

@external(erlang, "lily_server_ffi", "gauge_set")
@external(javascript, "./server.ffi.mjs", "gaugeSet")
fn gauge_set(gauge: Gauge, value: Int) -> Nil

@external(erlang, "lily_server_ffi", "gauge_value")
@external(javascript, "./server.ffi.mjs", "gaugeValue")
fn gauge_value(gauge: Gauge) -> Int

// zero for a dead process
@target(erlang)
@external(erlang, "lily_server_ffi", "message_queue_length")
fn message_queue_length(pid: Pid) -> Int

@external(erlang, "lily_server_ffi", "monotonic_milliseconds")
@external(javascript, "./server.ffi.mjs", "monotonicMilliseconds")
fn monotonic_milliseconds() -> Int

@external(erlang, "lily_server_ffi", "new_gauge")
@external(javascript, "./server.ffi.mjs", "newGauge")
fn new_gauge() -> Gauge

@external(erlang, "lily_server_ffi", "random_hex")
@external(javascript, "./server.ffi.mjs", "randomHex")
fn random_hex(byte_count byte_count: Int) -> String

@external(erlang, "lily_server_ffi", "unique_integer")
@external(javascript, "./server.ffi.mjs", "uniqueInteger")
fn unique_integer() -> Int
