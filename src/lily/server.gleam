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
//// starts it again from the same declaration if it crashes. Each topic's
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
////   let assert Ok(server) =
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
////     server,
////     origin: request.get_header(req, "origin") |> option.from_result,
////     send: process.send(outgoing_subject, _),
////   )
////
//// // for every frame the socket receives
//// server.incoming(connection, bytes:)
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
//// One client may hold 1000 topics with ids up to 256 bytes, tuned with
//// [`max_subscriptions`](#max_subscriptions) and
//// [`max_topic_id_length`](#max_topic_id_length), and
//// [`stop_idle_topics`](#stop_idle_topics) stops the topics nobody holds.
////
//// Shut a server down with [`stop`](#stop), which asks every topic to stop
//// first so that subscribers' slices reset before the underlying actor
//// terminates.
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
////                 mist.Binary(bytes) -> {
////                   server.incoming(connection, bytes:)
////                   mist.continue(connection)
////                 }
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
    max_subscriptions: Int,
    max_topic_id_length: Int,
    idle_after: Option(Int),
  )
}

/// Why a connection was refused before it was registered.
pub type ConnectError {
  /// The `Origin` header did not match the allowlist.
  OriginNotAllowed(origin: String)
  /// Request had no `Origin` header and the policy wants one.
  OriginMissing
}

/// One client's registration with a server, from [`connect`](#connect).
///
/// Give it each inbound frame and close it when the transport closes.
pub opaque type Connection(model, message) {
  Connection(server: Server(model, message), client_id: String)
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

@target(erlang)
/// A request whose origin [`open`](#open) has accepted, waiting for its socket
/// to [`attach`](#attach).
///
/// Erlang only.
pub opaque type Opened(model, message) {
  Opened(server: Server(model, message), origin: Option(String))
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

/// A running Lily server.
///
/// Use [`start`](#start) to start one.
pub opaque type Server(model, message) {
  Server(handle: ServerHandle(model, message), origins: Origins)
}

/// Something that happened on the server, given to every observer.
pub type ServerEvent(model, message) {
  /// A client was registered
  ClientConnected(client_id: String)
  /// A client left, or its connection process died
  ClientDisconnected(client_id: String)
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
/// [`open`](#open) has accepted the request. Erlang only.
///
/// Give it the `Opened` value. You get back the connection and a selector that
/// yields `Ok(bytes)` for each frame to send, and `Error(Nil)` when the socket
/// should close because the server restarted.
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
  let connection =
    register(
      server,
      send: process.send(outgoing, _),
      client_id: generate_client_id(),
      session: [],
      watch: WatchCaller,
    )
  let selector =
    process.new_selector()
    |> process.select_map(outgoing, Ok)
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
/// frame to this client. The client is disconnected if the calling process
/// dies. With mist or ewe, [`open`](#open) and [`attach`](#attach) are simpler.
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
  use _ <- result.map(validate_origin(server.origins, origin))
  register(server, send:, client_id:, session: seed, watch:)
}

/// The connection for a client id you kept, for transports that store the id
/// rather than the connection.
///
/// ```gleam
/// server.connection(app, client_id:)
/// |> server.incoming(bytes:)
/// ```
pub fn connection(
  server: Server(model, message),
  client_id client_id: String,
) -> Connection(model, message) {
  Connection(server:, client_id:)
}

/// Unregisters a client, usually when its socket closes.
pub fn disconnect(connection: Connection(model, message)) -> Nil {
  let _ =
    actor.unwatch(
      connection.server.handle,
      down: ClientLeft(client_id: connection.client_id),
    )
  cast(connection.server, ClientLeft(client_id: connection.client_id))
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

/// Generates a new random client id, for [`connect_as`](#connect_as).
pub fn generate_client_id() -> String {
  random_hex(byte_count: 16)
}

/// Passes a frame the client sent to the server. Call it for every binary frame
/// the socket receives.
///
/// ```gleam
/// server.incoming(connection, bytes:)
/// ```
pub fn incoming(
  connection: Connection(model, message),
  bytes bytes: BitArray,
) -> Nil {
  cast(connection.server, Incoming(client_id: connection.client_id, bytes:))
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

/// Caps how many topics one client may join at once, 1000 by default.
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
/// |> server.max_topic_id_length(bytes: 64)
/// ```
pub fn max_topic_id_length(
  builder: Builder(model, message),
  bytes bytes: Int,
) -> Builder(model, message) {
  Builder(..builder, max_topic_id_length: bytes)
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
    max_subscriptions: 1000,
    max_topic_id_length: 256,
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
/// Checks a WebSocket request's origin before upgrading it, giving a refused
/// one a 403. Erlang only. Pass the result to [`attach`](#attach) once the
/// socket is up.
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
  validate_origin(server.origins, origin)
  |> result.replace(Opened(server:, origin:))
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
  actor.start_seeded(new_state(builder, _), reduce:)
  |> result.map(Server(handle: _, origins: builder.origins))
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
  let child =
    supervised_as(builder, actor.new_name("lily_server"), fn(server) {
      process.send(ready, server)
    })
  let tree =
    static_supervisor.new(static_supervisor.OneForAll)
    // the 2 in 5 default is tight for a client-influenced process
    |> static_supervisor.restart_tolerance(intensity: 3, period: 10)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  case tree {
    Error(_) -> Error(Nil)
    Ok(tree) ->
      case process.receive(ready, within: 5000) {
        Error(_) -> Error(Nil)
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
  Builder(..builder, idle_after: option.Some(milliseconds))
}

/// Stops one topic. Its subscribers keep their last state, and the next
/// subscribe or dispatch starts it again from the beginning.
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

type Client(model) {
  Client(
    send: fn(BitArray) -> Nil,
    model: model,
    sequence: Int,
    topics: Dict(String, SubscriptionState),
    format: Option(Format),
  )
}

type InternalEvent(message) {
  ClientJoined(
    client_id: String,
    send: fn(BitArray) -> Nil,
    session: List(message),
  )
  ClientLeft(client_id: String)
  DispatchToAllClients(message: message)
  DispatchToClient(client_id: String, message: message)
  DispatchTopic(topic_id: String, message: message)
  IdleTopic(topic_id: String, generation: Int)
  Incoming(client_id: String, bytes: BitArray)
  Inspect
  RecheckAccess(client_id: String)
  Stop
  StopTopic(topic_id: String)
  TopicDown(id: String)
  TopicReported(topic_id: String, report: TopicReport)
}

type MessageSource {
  /// A client, answered with an `Acknowledge` or a `Dropped`
  FromClient
  /// The server, answered with a `SessionUpdate` carrying the message
  FromServer
}

type Observer(model, message) =
  fn(ServerEvent(model, message), Server(model, message)) -> Nil

type ServerHandle(model, message) =
  Cell(ServerState(model, message), InternalEvent(message), Option(Inspection))

type ServerState(model, message) {
  ServerState(
    // the running server itself, handed to observers
    server: Server(model, message),
    supervisor: actor.Supervisor,
    serialiser: Serialiser(model, message),
    // what a client is written in until it has spoken
    format: Format,
    store: Store(model, message, Synced),
    observers: List(Observer(model, message)),
    topic_inits: List(#(store.TopicMatch, fn(String) -> model)),
    max_subscriptions: Int,
    max_topic_id_length: Int,
    idle_after: Option(Int),
    clients: Dict(String, Client(model)),
    topics: Dict(String, TopicEntry(model, message)),
    boot_id: String,
    // clients whose send raised this reduction, swept at the end so dead
    // connections needn't be threaded through every writer
    failed_sends: Set(String),
  )
}

type Subscriber {
  Subscriber(send: fn(BitArray) -> Nil, format: Format)
}

type SubscriptionState {
  /// Asked for, not yet admitted by the topic
  Pending
  /// Admitted
  Joined
}

type TopicActor(model, message) =
  Cell(TopicState(model, message), TopicEvent(message), Int)

// restart count lives here so a stopped topic restarts with a full budget
type TopicEntry(model, message) {
  TopicEntry(
    actor: TopicActor(model, message),
    restarts: Int,
    // keys in `Client.topics`, pending included
    subscribers: Int,
    // bumped per idle timer, an older timer is stale
    generation: Int,
  )
}

type TopicEvent(message) {
  /// `from` is the sending client and how to reach it, `None` for the server
  TopicDispatch(from: Option(#(String, Subscriber)), message: message)
  TopicLoad
  TopicSendSnapshot(client_id: String, subscriber: Subscriber)
  TopicStop
  TopicSubscribe(client_id: String, subscriber: Subscriber, report: Bool)
  TopicSubscriberCount
  TopicUnsubscribe(client_id: String)
}

type TopicReport {
  /// The topic admitted this client
  Admitted(client_id: String)
  /// The topic's own loader crashed, leaving it on the initial model
  LoadFailed(reason: String)
}

type TopicState(model, message) {
  TopicState(
    id: String,
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

// stops a topic that crashes on start restarting in a tight loop
const max_topic_restarts = 5

// topic ids come from clients, caps unbounded topic creation
const max_topics = 100_000

fn add_topic_init(
  builder: Builder(model, message),
  match: store.TopicMatch,
  init: fn(String) -> model,
) -> Builder(model, message) {
  let others = list.filter(builder.topic_inits, fn(other) { other.0 != match })
  Builder(..builder, topic_inits: [#(match, init), ..others])
}

fn admit(
  state: ServerState(model, message),
  client_id: String,
  session: model,
  topic_id: String,
) -> Result(
  #(ServerState(model, message), TopicActor(model, message)),
  RejectionReason,
) {
  use access <- result.try(
    store.access_for(state.store, topic_id) |> result.replace_error(NotFound),
  )
  use <- bool.guard(
    when: !permitted(access, client_id, topic_id, session),
    return: Error(AccessDenied),
  )
  find_or_start_topic(state, topic_id)
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
        Error(reason) -> {
          let what = case source {
            FromClient -> "dropped malformed session message from "
            FromServer -> "dropped crashing dispatch to "
          }
          diagnose(
            state,
            transport.Warning,
            what <> client_id <> ": " <> reason,
          )
          case source {
            FromClient -> push_dropped(state, client_id, transport.Session)
            FromServer -> state
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
          recheck_client(state, client_id)
        }
      }
    }
  }
}

// rescued, a restarting server's name is briefly unregistered
fn cast(server: Server(model, message), event: InternalEvent(message)) -> Nil {
  actor.rescue_or("cast", Nil, fn() { actor.send(server.handle, event) })
}

fn diagnose(
  state: ServerState(model, message),
  level: transport.DiagnosticLevel,
  description: String,
) -> Nil {
  actor.log(level, "lily: " <> description)
  notify(state, Diagnostic(level:, message: description))
}

fn drop_failed_sends(
  state: ServerState(model, message),
) -> ServerState(model, message) {
  use <- bool.guard(when: set.is_empty(state.failed_sends), return: state)
  let failed = state.failed_sends
  set.fold(
    failed,
    ServerState(..state, failed_sends: set.new()),
    handle_disconnect,
  )
}

fn drop_misrouted(
  state: ServerState(model, message),
  client_id: String,
  target: transport.SyncTarget,
  what: String,
) -> ServerState(model, message) {
  diagnose(
    state,
    transport.Warning,
    "dropped "
      <> what
      <> " from "
      <> client_id
      <> " that the store routes elsewhere",
  )
  push_dropped(state, client_id, target)
}

fn drop_topic(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  let clients =
    dict.map_values(state.clients, fn(_client_id, client) {
      Client(..client, topics: dict.delete(client.topics, topic_id))
    })
  ServerState(..state, clients:, topics: dict.delete(state.topics, topic_id))
}

// pending included, an admission racing the revocation is undone on report
fn evict(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  subscription: SubscriptionState,
) -> ServerState(model, message) {
  with_topic(state, topic_id, actor.send(_, TopicUnsubscribe(client_id:)))
  let state =
    remove_subscription(state, client_id, topic_id)
    |> reject(client_id, topic_id, AccessDenied)
  case subscription {
    Joined -> notify(state, Unsubscribed(client_id:, topic_id:))
    Pending -> Nil
  }
  state
}

fn find_or_start_topic(
  state: ServerState(model, message),
  topic_id: String,
) -> Result(
  #(ServerState(model, message), TopicActor(model, message)),
  RejectionReason,
) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) -> Ok(#(state, entry.actor))
    Error(_) -> {
      use <- bool.guard(
        when: result.is_error(store.access_for(state.store, topic_id)),
        return: Error(NotFound),
      )
      use <- bool.guard(
        when: dict.size(state.topics) >= max_topics,
        return: Error(OverLimit),
      )
      case start_topic(state, topic_id) {
        Error(Nil) -> {
          diagnose(
            state,
            transport.Failure,
            "could not start topic " <> topic_id,
          )
          Error(NotFound)
        }
        Ok(topic) -> {
          let entry =
            TopicEntry(actor: topic, restarts: 0, subscribers: 0, generation: 0)
          let topics = dict.insert(state.topics, topic_id, entry)
          Ok(#(schedule_idle(ServerState(..state, topics:), topic_id), topic))
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
  diagnose(state, transport.Failure, "gave up on topic " <> id <> ", " <> why)
  drop_topic(state, id)
}

// undoes a subscription cancelled before the topic admitted it
fn handle_admitted(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  let subscription =
    dict.get(state.clients, client_id)
    |> result.try(fn(client) { dict.get(client.topics, topic_id) })
  case subscription {
    Ok(Pending) -> {
      let state = set_subscription(state, client_id, topic_id, Joined)
      notify(state, Subscribed(client_id:, topic_id:))
      state
    }
    Ok(Joined) -> state
    Error(_) -> {
      with_topic(state, topic_id, actor.send(_, TopicUnsubscribe(client_id:)))
      state
    }
  }
}

fn handle_connect(
  state: ServerState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
  session: List(message),
) -> ServerState(model, message) {
  // keep a re-registered client's topics so leaving still unsubscribes
  let topics = case dict.get(state.clients, client_id) {
    Ok(existing) -> existing.topics
    Error(_) -> dict.new()
  }
  let model = store.get_model(state.store)
  let client = Client(send:, model:, sequence: 0, topics:, format: option.None)
  let state =
    put_client(state, client_id, client)
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
      apply_to_session(state, client_id, message, FromServer)
    })
  notify(state, ClientConnected(client_id:))
  state
}

fn handle_disconnect(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  // close callback and dead process can both land, report only once
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      let state =
        dict.fold(client.topics, state, fn(state, topic_id, subscription) {
          with_topic(state, topic_id, actor.send(
            _,
            TopicUnsubscribe(client_id:),
          ))
          case subscription {
            Joined -> notify(state, Unsubscribed(client_id:, topic_id:))
            Pending -> Nil
          }
          leave_count(state, topic_id)
        })
      let state =
        ServerState(..state, clients: dict.delete(state.clients, client_id))
      notify(state, ClientDisconnected(client_id:))
      state
    }
  }
}

fn handle_dispatch_topic(
  state: ServerState(model, message),
  topic_id: String,
  message: message,
) -> ServerState(model, message) {
  case find_or_start_topic(state, topic_id) {
    Ok(#(state, topic)) -> {
      actor.send(topic, TopicDispatch(from: option.None, message:))
      case dict.get(state.topics, topic_id) {
        Ok(TopicEntry(subscribers: 0, ..)) -> schedule_idle(state, topic_id)
        _ -> state
      }
    }
    Error(reason) -> {
      let why = case reason {
        AccessDenied | NotFound -> ", no topic is declared for it"
        OverLimit -> ", the topic limit is reached"
      }
      diagnose(
        state,
        transport.Warning,
        "dropped a dispatch to " <> topic_id <> why,
      )
      state
    }
  }
}

fn handle_idle_topic(
  state: ServerState(model, message),
  topic_id: String,
  generation: Int,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Ok(entry) if entry.generation == generation && entry.subscribers == 0 ->
      handle_stop_topic(state, topic_id)
    _ -> state
  }
}

fn handle_incoming(
  state: ServerState(model, message),
  client_id: String,
  bytes: BitArray,
) -> ServerState(model, message) {
  // user decoder on hostile bytes, a crash counts as a decode failure
  let decoded =
    actor.rescue_or("decode", Error(Nil), fn() {
      transport.decode_checked(
        bytes,
        serialiser: state.serialiser,
        schema: store.schema_of(state.store),
      )
    })
  let state = case decoded {
    Ok(_) -> learn_format(state, client_id, bytes)
    Error(_) -> state
  }
  case decoded {
    Ok(transport.SessionMessage(payload:)) ->
      case route_of(state, payload) {
        option.Some(store.Session) ->
          apply_to_session(state, client_id, payload, FromClient)
        option.Some(store.Topic(_)) | option.Some(store.Local) | option.None ->
          drop_misrouted(
            state,
            client_id,
            transport.Session,
            "a session message",
          )
      }

    Ok(transport.TopicMessage(topic_id:, payload:)) ->
      handle_topic_message(state, client_id, topic_id, payload)

    Ok(transport.Subscribe(topic_id:)) ->
      handle_subscribe(state, client_id, topic_id)

    Ok(transport.Unsubscribe(topic_id:)) ->
      handle_unsubscribe(state, client_id, topic_id)

    Ok(transport.Resync(cursors:)) ->
      list.take(cursors, state.max_subscriptions + 1)
      |> list.fold(state, fn(state, target) {
        handle_resync(state, client_id, target)
      })

    // server-to-client variants, never legitimately arrive here
    Ok(transport.Acknowledge(_, _))
    | Ok(transport.Connected(_))
    | Ok(transport.Dropped(_))
    | Ok(transport.Rejected(_, _))
    | Ok(transport.SessionUpdate(_, _))
    | Ok(transport.Snapshot(_, _, _))
    | Ok(transport.TopicUpdate(_, _, _))
    | Ok(transport.Version(..)) -> state

    Error(_) ->
      case mismatched_target(state, bytes) {
        option.Some(target) -> {
          diagnose(
            state,
            transport.Warning,
            "dropped a message from " <> client_id <> " that fails the schema",
          )
          push_dropped(state, client_id, target)
        }
        option.None -> {
          diagnose(
            state,
            transport.Warning,
            "dropped a frame from " <> client_id <> " that failed to decode",
          )
          state
        }
      }
  }
}

// reconnect has a fresh id and `send`, meaning a rejoin, not a re-snapshot
fn handle_resync(
  state: ServerState(model, message),
  client_id: String,
  target: transport.SyncTarget,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id), target {
    Error(_), _ -> state
    Ok(client), transport.Session ->
      push(
        state,
        client_id,
        client,
        transport.Snapshot(
          target: transport.Session,
          sequence: client.sequence,
          state: client.model,
        ),
      )
    Ok(client), transport.Topic(topic_id) ->
      case dict.get(client.topics, topic_id), dict.get(state.topics, topic_id) {
        Ok(Joined), Ok(entry) ->
          case still_permitted(state, client_id, client.model, topic_id) {
            False -> evict(state, client_id, topic_id, Joined)
            True -> {
              actor.send(
                entry.actor,
                TopicSendSnapshot(
                  client_id:,
                  subscriber: subscriber_of(state, client),
                ),
              )
              state
            }
          }
        Ok(Joined), Error(_) | Ok(Pending), _ | Error(_), _ ->
          handle_subscribe(state, client_id, topic_id)
      }
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
      actor.send(entry.actor, TopicStop)
      drop_topic(state, topic_id)
    }
  }
}

fn handle_subscribe(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) ->
      case
        {
          use Nil <- result.try(within_limits(state, client, topic_id))
          admit(state, client_id, client.model, topic_id)
        }
      {
        Error(reason) -> reject(state, client_id, topic_id, reason)
        Ok(#(state, topic)) -> {
          actor.send(
            topic,
            TopicSubscribe(
              client_id:,
              subscriber: subscriber_of(state, client),
              report: True,
            ),
          )
          // already admitted, the topic won't report it twice
          case dict.has_key(client.topics, topic_id) {
            True -> state
            False -> set_subscription(state, client_id, topic_id, Pending)
          }
        }
      }
  }
}

// gives up after `max_topic_restarts`
fn handle_topic_down(
  state: ServerState(model, message),
  id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, id) {
    Error(_) -> state
    Ok(entry) if entry.restarts >= max_topic_restarts ->
      forget_topic(
        state,
        id,
        "it crashed " <> int.to_string(entry.restarts + 1) <> " times",
      )
    Ok(entry) ->
      case start_topic(state, id) {
        Error(Nil) -> forget_topic(state, id, "it would not restart")
        Ok(topic) -> reinstate_topic(state, id, topic, entry.restarts + 1)
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
  case
    route_of(state, message) == option.Some(store.Topic(topic_id)),
    dict.get(state.clients, client_id)
  {
    False, _ ->
      drop_misrouted(state, client_id, target, "a message for " <> topic_id)
    True, Error(_) -> state
    True, Ok(client) ->
      case
        dict.has_key(client.topics, topic_id),
        dict.get(state.topics, topic_id)
      {
        True, Ok(entry) -> {
          notify(state, TopicMessageReceived(client_id:, topic_id:, message:))
          let from = #(client_id, subscriber_of(state, client))
          actor.send(
            entry.actor,
            TopicDispatch(from: option.Some(from), message:),
          )
          state
        }
        False, _ | True, Error(_) -> {
          diagnose(
            state,
            transport.Warning,
            "dropped a message for "
              <> topic_id
              <> " from "
              <> client_id
              <> ", which hasn't joined it",
          )
          push_dropped(state, client_id, target)
        }
      }
  }
}

fn handle_topic_report(
  state: ServerState(model, message),
  topic_id: String,
  report: TopicReport,
) -> ServerState(model, message) {
  case report {
    Admitted(client_id:) -> handle_admitted(state, client_id, topic_id)
    LoadFailed(reason:) -> {
      diagnose(
        state,
        transport.Failure,
        "loading topic "
          <> topic_id
          <> " crashed, it started from the initial model: "
          <> reason,
      )
      state
    }
  }
}

fn handle_unsubscribe(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  with_topic(state, topic_id, actor.send(_, TopicUnsubscribe(client_id:)))
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) -> {
      case dict.get(client.topics, topic_id) {
        Ok(Joined) -> notify(state, Unsubscribed(client_id:, topic_id:))
        Ok(Pending) | Error(_) -> Nil
      }
      remove_subscription(state, client_id, topic_id)
    }
  }
}

fn join_count(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Error(_) -> state
    Ok(entry) ->
      put_topic(
        state,
        topic_id,
        TopicEntry(..entry, subscribers: entry.subscribers + 1),
      )
  }
}

fn learn_format(
  state: ServerState(model, message),
  client_id: String,
  bytes: BitArray,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Ok(Client(format: option.None, ..) as client) ->
      case transport.frame_format(bytes, serialiser: state.serialiser) {
        Ok(format) ->
          put_client(
            state,
            client_id,
            Client(..client, format: option.Some(format)),
          )
        Error(Nil) -> state
      }
    Ok(Client(format: option.Some(_), ..)) | Error(_) -> state
  }
}

fn leave_count(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.topics, topic_id) {
    Error(_) -> state
    Ok(entry) -> {
      let subscribers = int.max(entry.subscribers - 1, 0)
      let state = put_topic(state, topic_id, TopicEntry(..entry, subscribers:))
      case subscribers {
        0 -> schedule_idle(state, topic_id)
        _ -> state
      }
    }
  }
}

fn mismatched_target(
  state: ServerState(model, message),
  bytes: BitArray,
) -> Option(transport.SyncTarget) {
  use <- bool.guard(
    when: option.is_none(store.schema_of(state.store)),
    return: option.None,
  )
  actor.rescue_or("decode", Error(Nil), fn() {
    transport.payload_target(bytes, serialiser: state.serialiser)
  })
  |> option.from_result
}

fn new_state(
  builder: Builder(model, message),
  toolkit: actor.Toolkit(
    ServerState(model, message),
    InternalEvent(message),
    Option(Inspection),
  ),
) -> ServerState(model, message) {
  ServerState(
    server: Server(handle: toolkit.cell, origins: builder.origins),
    supervisor: toolkit.supervisor,
    serialiser: store.serialiser_of(builder.store),
    format: transport.server_format(store.serialiser_of(builder.store)),
    store: builder.store,
    observers: builder.observers,
    topic_inits: builder.topic_inits,
    max_subscriptions: builder.max_subscriptions,
    max_topic_id_length: builder.max_topic_id_length,
    idle_after: builder.idle_after,
    clients: dict.new(),
    topics: dict.new(),
    // fresh per incarnation, lets a client tell a restart from a reconnect
    boot_id: random_hex(8),
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

fn notify(
  state: ServerState(model, message),
  event: ServerEvent(model, message),
) -> Nil {
  list.each(state.observers, fn(observer) {
    actor.rescue_or("observer", Nil, fn() { observer(event, state.server) })
  })
}

// fails closed, a crashing access rule refuses
fn permitted(
  access: store.Access(model),
  client_id: String,
  topic_id: String,
  session: model,
) -> Bool {
  case access {
    store.Open -> True
    store.Allow(predicate) ->
      actor.rescue_or("access", False, fn() {
        predicate(client_id, topic_id, session)
      })
  }
}

// a serialiser crash drops the frame, keeps the connection
fn push(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model),
  frame: transport.Protocol(model, message),
) -> ServerState(model, message) {
  let format = option.unwrap(client.format, state.format)
  case rescue_encode(frame, state.serialiser, format) {
    option.None -> state
    option.Some(bytes) ->
      case actor.rescue_send("client", client.send, bytes) {
        True -> state
        False ->
          ServerState(
            ..state,
            failed_sends: set.insert(state.failed_sends, client_id),
          )
      }
  }
}

// in place of the `Acknowledge`, the client rolls its edit back
fn push_dropped(
  state: ServerState(model, message),
  client_id: String,
  target: transport.SyncTarget,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Ok(client) -> push(state, client_id, client, transport.Dropped(target:))
    Error(_) -> state
  }
}

fn put_client(
  state: ServerState(model, message),
  client_id: String,
  client: Client(model),
) -> ServerState(model, message) {
  ServerState(..state, clients: dict.insert(state.clients, client_id, client))
}

fn put_topic(
  state: ServerState(model, message),
  topic_id: String,
  entry: TopicEntry(model, message),
) -> ServerState(model, message) {
  ServerState(..state, topics: dict.insert(state.topics, topic_id, entry))
}

fn recheck_client(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) ->
      dict.fold(client.topics, state, fn(state, topic_id, subscription) {
        case still_permitted(state, client_id, client.model, topic_id) {
          True -> state
          False -> evict(state, client_id, topic_id, subscription)
        }
      })
  }
}

fn reduce(
  event: InternalEvent(message),
  state: ServerState(model, message),
) -> actor.CellOutcome(ServerState(model, message), Option(Inspection)) {
  case event {
    ClientJoined(client_id:, send:, session:) ->
      Continue(handle_connect(state, client_id, send, session))

    ClientLeft(client_id:) -> Continue(handle_disconnect(state, client_id))

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

    Incoming(client_id:, bytes:) ->
      Continue(handle_incoming(state, client_id, bytes))

    Inspect ->
      Reply(
        state,
        option.Some(Inspection(
          boot_id: state.boot_id,
          client_count: dict.size(state.clients),
          topics: dict.map_values(state.topics, fn(_id, entry) {
            TopicInspection(
              subscriber_count: fn() {
                actor.call(entry.actor, TopicSubscriberCount, default: -1)
              },
              watched: actor.watched(entry.actor),
            )
          }),
          supervisor: state.supervisor,
          watched: actor.watched(state.server.handle),
        )),
      )

    RecheckAccess(client_id:) -> Continue(recheck_client(state, client_id))

    // topics stop first, each sends a final `Acknowledge(Topic(id), sequence)`
    Stop -> {
      dict.each(state.topics, fn(_id, entry) {
        actor.send(entry.actor, TopicStop)
      })
      Halt(state)
    }

    StopTopic(topic_id:) -> Continue(handle_stop_topic(state, topic_id))

    TopicDown(id:) -> Continue(handle_topic_down(state, id))

    TopicReported(topic_id:, report:) ->
      Continue(handle_topic_report(state, topic_id, report))
  }
  |> sweep_failed_sends
}

fn register(
  server: Server(model, message),
  send send: fn(BitArray) -> Nil,
  client_id client_id: String,
  session session: List(message),
  watch watch: ConnectionWatch,
) -> Connection(model, message) {
  cast(server, ClientJoined(client_id:, send:, session:))
  // inert on JavaScript, hence the discard
  let _ = case watch {
    WatchCaller ->
      actor.watch(
        server.handle,
        watched: actor.watched_here(),
        down: ClientLeft(client_id:),
      )
    WatchProcess(pid) ->
      actor.watch(
        server.handle,
        watched: actor.watched_from(pid),
        down: ClientLeft(client_id:),
      )
    Unwatched -> Nil
  }
  Connection(server:, client_id:)
}

fn reinstate_topic(
  state: ServerState(model, message),
  id: String,
  topic: TopicActor(model, message),
  restarts: Int,
) -> ServerState(model, message) {
  actor.log(transport.Failure, "lily: topic actor died, restarted: " <> id)
  dict.each(state.clients, fn(client_id, client) {
    let subscriber = subscriber_of(state, client)
    case dict.get(client.topics, id) {
      Ok(Joined) ->
        actor.send(
          topic,
          TopicSubscribe(client_id:, subscriber:, report: False),
        )
      Ok(Pending) ->
        actor.send(topic, TopicSubscribe(client_id:, subscriber:, report: True))
      Error(_) -> Nil
    }
  })
  let topics = case dict.get(state.topics, id) {
    Ok(entry) ->
      dict.insert(
        state.topics,
        id,
        TopicEntry(..entry, actor: topic, restarts:),
      )
    Error(_) -> state.topics
  }
  ServerState(..state, topics:)
}

fn reject(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
  reason: RejectionReason,
) -> ServerState(model, message) {
  let state = case dict.get(state.clients, client_id) {
    Ok(client) ->
      push(state, client_id, client, transport.Rejected(topic_id:, reason:))
    Error(_) -> state
  }
  notify(state, SubscriptionRejected(client_id:, topic_id:, reason:))
  state
}

fn remove_subscription(
  state: ServerState(model, message),
  client_id: String,
  topic_id: String,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(_) -> state
    Ok(client) ->
      case dict.has_key(client.topics, topic_id) {
        False -> state
        True -> {
          let topics = dict.delete(client.topics, topic_id)
          put_client(state, client_id, Client(..client, topics:))
          |> leave_count(topic_id)
        }
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

// a decoded payload may be any constructor, `route` can crash on it
fn route_of(
  state: ServerState(model, message),
  message: message,
) -> Option(store.Route) {
  actor.rescue_or("route", option.None, fn() {
    option.Some(store.route(state.store, message))
  })
}

fn schedule_idle(
  state: ServerState(model, message),
  topic_id: String,
) -> ServerState(model, message) {
  case state.idle_after, dict.get(state.topics, topic_id) {
    option.Some(milliseconds), Ok(entry) -> {
      let generation = entry.generation + 1
      actor.send_after(
        state.server.handle,
        milliseconds,
        IdleTopic(topic_id:, generation:),
      )
      put_topic(state, topic_id, TopicEntry(..entry, generation:))
    }
    _, _ -> state
  }
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
      let joining = !dict.has_key(client.topics, topic_id)
      let topics = dict.insert(client.topics, topic_id, subscription)
      let state = put_client(state, client_id, Client(..client, topics:))
      case joining {
        True -> join_count(state, topic_id)
        False -> state
      }
    }
  }
}

fn start_topic(
  state: ServerState(model, message),
  id: String,
) -> Result(TopicActor(model, message), Nil) {
  let cell = state.server.handle
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
      serialiser: state.serialiser,
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
    topic
  })
}

fn still_permitted(
  state: ServerState(model, message),
  client_id: String,
  session: model,
  topic_id: String,
) -> Bool {
  case store.access_for(state.store, topic_id) {
    Ok(access) -> permitted(access, client_id, topic_id, session)
    Error(_) -> False
  }
}

fn subscriber_of(
  state: ServerState(model, message),
  client: Client(model),
) -> Subscriber {
  Subscriber(
    send: client.send,
    format: option.unwrap(client.format, state.format),
  )
}

@target(erlang)
fn supervised_as(
  builder: Builder(model, message),
  name: actor.CellName(InternalEvent(message), Option(Inspection)),
  started: fn(Server(model, message)) -> Nil,
) -> supervision.ChildSpecification(Server(model, message)) {
  supervision.worker(run: fn() {
    let cell =
      actor.start_with_supervisor(new_state(builder, _), reduce:, name:)
    case cell {
      Error(_) -> Error(otp_actor.InitFailed("lily: server failed to start"))
      Ok(handle) -> {
        let server = Server(handle:, origins: builder.origins)
        started(server)
        let pid = actor.watched_pid(actor.watched(handle))
        Ok(otp_actor.Started(pid:, data: server))
      }
    }
  })
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
      actor.log(
        transport.Warning,
        "lily: dropped malformed topic message on "
          <> state.id
          <> ": "
          <> reason,
      )
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
      // sender gets the ack, everyone else the update
      let subscribers =
        topic_send_to_subscribers(state.subscribers, fn(id, format) {
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
  subscriber: Subscriber,
) -> TopicState(model, message) {
  case dict.has_key(state.subscribers, client_id) {
    True -> topic_send_snapshot(state, subscriber)
    False -> Nil
  }
  state
}

fn topic_handle_stop(state: TopicState(model, message)) -> Nil {
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
    topic_send_to_subscribers(state.subscribers, fn(_, format) {
      topic_frame_in(acknowledge_frames, format)
    })
  Nil
}

// only the first admission is reported to the server
fn topic_handle_subscribe(
  state: TopicState(model, message),
  client_id: String,
  subscriber: Subscriber,
  report_admission: Bool,
) -> TopicState(model, message) {
  // asked twice before the first admission settled, already reported
  let already_in = dict.has_key(state.subscribers, client_id)
  let state =
    TopicState(
      ..state,
      subscribers: dict.insert(state.subscribers, client_id, subscriber),
    )
  topic_send_snapshot(state, subscriber)
  case report_admission && !already_in {
    True -> topic_report(state, Admitted(client_id:))
    False -> Nil
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

    TopicSendSnapshot(client_id:, subscriber:) ->
      Continue(topic_handle_send_snapshot(state, client_id, subscriber))

    TopicStop -> {
      topic_handle_stop(state)
      Halt(state)
    }

    TopicSubscribe(client_id:, subscriber:, report:) ->
      Continue(topic_handle_subscribe(state, client_id, subscriber, report))

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

fn topic_send(
  state: TopicState(model, message),
  subscriber: Subscriber,
  frame: transport.Protocol(model, message),
) -> Nil {
  case rescue_encode(frame, state.serialiser, subscriber.format) {
    option.None -> Nil
    option.Some(bytes) -> {
      let _ = actor.rescue_send("subscriber", subscriber.send, bytes)
      Nil
    }
  }
}

// reaches a sender the topic has already let go of too
fn topic_send_dropped(
  state: TopicState(model, message),
  from: Option(#(String, Subscriber)),
) -> Nil {
  case from {
    option.Some(#(_, subscriber)) ->
      topic_send(
        state,
        subscriber,
        transport.Dropped(target: transport.Topic(state.id)),
      )
    option.None -> Nil
  }
}

fn topic_send_snapshot(
  state: TopicState(model, message),
  subscriber: Subscriber,
) -> Nil {
  topic_send(
    state,
    subscriber,
    transport.Snapshot(
      target: transport.Topic(state.id),
      sequence: state.sequence,
      state: state.current,
    ),
  )
}

fn topic_send_to_subscribers(
  subscribers: Dict(String, Subscriber),
  frame_for: fn(String, Format) -> Option(BitArray),
) -> Dict(String, Subscriber) {
  use <- bool.guard(when: dict.is_empty(subscribers), return: subscribers)
  dict.fold(subscribers, subscribers, fn(kept, id, subscriber) {
    case frame_for(id, subscriber.format) {
      option.None -> kept
      option.Some(bytes) ->
        case actor.rescue_send("subscriber", subscriber.send, bytes) {
          True -> kept
          // a raising send is a dead connection, drop only that subscriber
          False -> dict.delete(kept, id)
        }
    }
  })
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
  client: Client(model),
  topic_id: String,
) -> Result(Nil, RejectionReason) {
  let joining = !dict.has_key(client.topics, topic_id)
  case
    string.byte_size(topic_id) > state.max_topic_id_length,
    joining && dict.size(client.topics) >= state.max_subscriptions
  {
    False, False -> Ok(Nil)
    _, _ -> Error(OverLimit)
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@external(erlang, "lily_server_ffi", "random_hex")
@external(javascript, "./server.ffi.mjs", "randomHex")
fn random_hex(byte_count byte_count: Int) -> String
