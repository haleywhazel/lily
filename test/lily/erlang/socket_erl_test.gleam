// `server.open` and `server.attach`, a spawned process stands in for the socket
// no fixed sleeps, tests wait on a message or poll state

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleam/dynamic.{type Dynamic}
@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/list
@target(erlang)
import gleam/option

@target(erlang)
import gleeunit/should

@target(erlang)
import lily/server
@target(erlang)
import lily/test_support.{
  type Message, type Model, Increment, IncrementSecondary,
}
@target(erlang)
import lily/transport
@target(erlang)
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
/// What the socket process saw on its selector.
type Received {
  Frame(wire_support.Frame)
  /// Server went down, `downs` counts the `Error(Nil)`s queued by then
  Gone(downs: Int)
}

@target(erlang)
fn allowlisted() -> server.Server(Model, Message) {
  test_support.new_server_with_origins(
    server.AllowedOrigins(["https://example.com"]),
  )
}

@target(erlang)
/// Spawn a socket process, returns once attached.
fn attach_in_process(
  app: server.Server(Model, Message),
) -> #(
  process.Pid,
  server.Connection(Model, Message),
  process.Subject(Received),
) {
  let assert Ok(opened) = server.open(app, origin: option.None)
  attach_opened(opened)
}

@target(erlang)
/// [`attach_in_process`](#attach_in_process) for an `Opened` of your own.
fn attach_opened(
  opened: server.Opened(Model, Message),
) -> #(
  process.Pid,
  server.Connection(Model, Message),
  process.Subject(Received),
) {
  let attached = process.new_subject()
  let received = process.new_subject()
  let socket =
    process.spawn_unlinked(fn() {
      let #(connection, selector) = server.attach(opened)
      process.send(attached, connection)
      forward(selector, received)
    })
  let assert Ok(connection) = process.receive(attached, within: 1000)
  #(socket, connection, received)
}

@target(erlang)
/// Count queued `Error(Nil)`s without blocking.
fn drain_downs(
  selector: process.Selector(Result(BitArray, Nil)),
  downs: Int,
) -> Int {
  case process.selector_receive(selector, within: 0) {
    Ok(Ok(_)) -> drain_downs(selector, downs)
    Ok(Error(Nil)) -> drain_downs(selector, downs + 1)
    Error(Nil) -> downs
  }
}

@target(erlang)
fn forward(
  selector: process.Selector(Result(BitArray, Nil)),
  received: process.Subject(Received),
) -> Nil {
  case process.selector_receive_forever(selector) {
    Ok(bytes) -> {
      process.send(received, Frame(wire_support.decode(bytes)))
      forward(selector, received)
    }
    Error(Nil) -> {
      process.send(received, Gone(downs: drain_downs(selector, 1)))
      process.sleep_forever()
    }
  }
}

@target(erlang)
fn next(received: process.Subject(Received)) -> Received {
  let assert Ok(message) = process.receive(received, within: 1000)
  message
}

// =============================================================================
// OPEN
// =============================================================================

@target(erlang)
pub fn socket_open_accepts_an_allowed_origin_without_registering_test() {
  let app = allowlisted()

  server.open(app, origin: option.Some("https://example.com"))
  |> should.be_ok

  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(0)
}

@target(erlang)
pub fn socket_open_refuses_a_disallowed_origin_test() {
  let app = allowlisted()

  case server.open(app, origin: option.Some("https://evil.example")) {
    Ok(_) -> should.fail()
    Error(error) ->
      error
      |> should.equal(server.OriginNotAllowed(origin: "https://evil.example"))
  }

  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(0)
}

@target(erlang)
pub fn socket_open_refuses_a_missing_origin_test() {
  let app = allowlisted()

  case server.open(app, origin: option.None) {
    Ok(_) -> should.fail()
    Error(error) -> error |> should.equal(server.OriginMissing)
  }

  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(0)
}

// =============================================================================
// ATTACH
// =============================================================================

@target(erlang)
pub fn socket_attach_yields_the_greeting_and_dispatched_frames_test() {
  let app = test_support.new_server()
  let #(_socket, connection, received) = attach_in_process(app)
  let client_id = server.client_id(connection)

  let assert Frame(transport.Version(..)) = next(received)
  next(received)
  |> should.equal(Frame(transport.Connected(client_id:)))

  server.dispatch_to(app, client_id:, message: IncrementSecondary)

  let assert Frame(transport.SessionUpdate(payload: IncrementSecondary, ..)) =
    next(received)
  Nil
}

@target(erlang)
pub fn socket_attach_registers_a_client_with_a_fresh_id_test() {
  let app = test_support.new_server()
  let #(_first, first, _received) = attach_in_process(app)
  let #(_second, second, _received) = attach_in_process(app)

  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(2)
  { server.client_id(first) == server.client_id(second) }
  |> should.be_false
}

@target(erlang)
pub fn socket_attach_disconnects_when_the_socket_process_dies_test() {
  let app = test_support.new_server()
  let #(socket, _connection, _received) = attach_in_process(app)
  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(1)

  process.kill(socket)
  wire_support.await_down(socket)

  wire_support.eventually(
    fn() { test_support.client_count(app) == 0 },
    within: 1000,
  )
  |> should.be_true
}

@target(erlang)
pub fn socket_attach_yields_one_error_when_the_server_stops_test() {
  let app = test_support.new_server()
  let #(_socket, _connection, received) = attach_in_process(app)
  let assert Frame(transport.Version(..)) = next(received)
  let assert Frame(transport.Connected(..)) = next(received)

  wire_support.stop(app)

  next(received)
  |> should.equal(Gone(downs: 1))
}

// =============================================================================
// IDENTITY
// =============================================================================

@target(erlang)
pub fn socket_open_as_seeds_the_session_test() {
  let app = test_support.new_server()
  let assert Ok(opened) =
    server.open_as(app, origin: option.None, client_id: "u1", seed: [
      IncrementSecondary,
    ])

  let #(_socket, _connection, received) = attach_opened(opened)

  let assert Frame(transport.Version(..)) = next(received)
  next(received)
  |> should.equal(Frame(transport.Connected(client_id: "u1")))
  let assert Frame(transport.SessionUpdate(payload: IncrementSecondary, ..)) =
    next(received)
  Nil
}

@target(erlang)
pub fn socket_a_superseded_socket_is_closed_test() {
  let app = test_support.new_server()
  let assert Ok(first) =
    server.open_as(app, origin: option.None, client_id: "u1", seed: [])
  let #(_socket, _connection, received) = attach_opened(first)
  let assert Frame(transport.Version(..)) = next(received)
  let assert Frame(transport.Connected(..)) = next(received)

  let assert Ok(second) =
    server.open_as(app, origin: option.None, client_id: "u1", seed: [])
  let _ = attach_opened(second)

  next(received)
  |> should.equal(Gone(downs: 1))
}

@target(erlang)
pub fn socket_a_stale_watch_down_does_not_remove_the_new_client_test() {
  let app = test_support.new_server()
  let assert Ok(first) =
    server.open_as(app, origin: option.None, client_id: "u1", seed: [])
  let #(old_socket, _old, _received) = attach_opened(first)
  let assert Ok(second) =
    server.open_as(app, origin: option.None, client_id: "u1", seed: [])
  let #(_socket, _connection, _received) = attach_opened(second)
  wire_support.settle(app)

  process.kill(old_socket)
  wire_support.await_down(old_socket)

  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(1)
}

@target(erlang)
pub fn socket_attach_holds_max_clients_against_handshakes_in_flight_test() {
  // both pass `open`, only the first to attach gets in
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_clients(count: 1),
    )
  let assert Ok(first) = server.open(app, origin: option.None)
  let assert Ok(second) = server.open(app, origin: option.None)

  let #(_socket, _connection, _received) = attach_opened(first)
  let #(_socket, refused, received) = attach_opened(second)

  next(received)
  |> should.equal(Gone(downs: 1))
  server.incoming(refused, bytes: <<>>)
  |> should.equal(server.Closed)
  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(1)
}

@target(erlang)
pub fn socket_open_refuses_past_max_clients_test() {
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_clients(count: 1),
    )
  let #(_socket, _connection, _received) = attach_in_process(app)

  case server.open(app, origin: option.None) {
    Ok(_) -> should.fail()
    Error(error) -> error |> should.equal(server.TooManyClients)
  }
}

// =============================================================================
// BACKPRESSURE
// =============================================================================

@target(erlang)
pub fn socket_a_slow_reader_is_disconnected_test() {
  let #(builder, events) =
    wire_support.observed(
      test_support.session_builder() |> server.max_outbound_queue(frames: 5),
    )
  let app = test_support.start_server(builder)
  let assert Ok(opened) =
    server.open_as(app, origin: option.None, client_id: "slow", seed: [])
  // attaches, then never reads its selector
  let attached = process.new_subject()
  let socket =
    process.spawn_unlinked(fn() {
      let _ = server.attach(opened)
      process.send(attached, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(attached, within: 1000)
  let _ = events(app)

  list.repeat(Nil, 20)
  |> list.each(fn(_) {
    server.dispatch_to(app, client_id: "slow", message: IncrementSecondary)
  })

  wire_support.await_down(socket)
  let seen = events(app)
  list.contains(
    seen,
    server.ClientEvicted(client_id: "slow", reason: server.SlowReader),
  )
  |> should.be_true
  list.contains(seen, server.ClientDisconnected(client_id: "slow"))
  |> should.be_true
}

@target(erlang)
pub fn socket_a_reader_past_its_byte_budget_is_disconnected_test() {
  // few frames, but more bytes than the socket may hold unread
  let #(builder, events) =
    wire_support.observed(
      test_support.session_builder() |> server.max_outbound_bytes(bytes: 512),
    )
  let app = test_support.start_server(builder)
  let assert Ok(opened) =
    server.open_as(app, origin: option.None, client_id: "slow", seed: [])
  let attached = process.new_subject()
  let socket =
    process.spawn_unlinked(fn() {
      let _ = server.attach(opened)
      process.send(attached, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(attached, within: 1000)
  let _ = events(app)

  // well under the 1000 frame cap, well over 512 bytes
  list.repeat(Nil, 50)
  |> list.each(fn(_) {
    server.dispatch_to(app, client_id: "slow", message: IncrementSecondary)
  })

  wire_support.await_down(socket)
  events(app)
  |> list.contains(server.ClientEvicted(
    client_id: "slow",
    reason: server.SlowReader,
  ))
  |> should.be_true
}

@target(erlang)
pub fn socket_inbound_frames_are_shed_when_the_server_is_overloaded_test() {
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_inbound_queue(frames: 3),
    )
  let #(_socket, connection, received) = attach_in_process(app)
  let assert Frame(transport.Version(..)) = next(received)
  let assert Frame(transport.Connected(..)) = next(received)
  let pid = wire_support.server_pid(app)

  let _ = suspend(pid)
  list.repeat(Nil, 10)
  |> list.each(fn(_) { wire_support.session_message(connection, Increment) })
  let _ = resume(pid)

  // closed rather than left queueing, once per shed frame
  let assert Gone(downs:) = next(received)
  { downs > 0 }
  |> should.be_true
}

@target(erlang)
pub fn socket_a_shed_message_frame_gets_dropped_test() {
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_inbound_queue(frames: 3),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  let pid = wire_support.server_pid(app)

  let _ = suspend(pid)
  list.repeat(Nil, 10)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  let _ = resume(pid)

  let received = frames()
  let #(acknowledged, dropped) =
    list.split_while(received, fn(frame) {
      frame != transport.Dropped(target: transport.Session)
    })
  // the drops come from the server, after the acks for the frames before them
  list.all(dropped, fn(frame) {
    frame == transport.Dropped(target: transport.Session)
  })
  |> should.be_true
  {
    dropped != []
    && list.length(acknowledged) <= 4
    && list.length(dropped) + list.length(acknowledged) == 10
  }
  |> should.be_true
}

@target(erlang)
pub fn socket_a_shed_frame_on_a_handle_rebuilt_from_an_id_gets_dropped_test() {
  // the handle has no way to answer, the server does it on the client's stream
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_inbound_queue(frames: 3),
    )
  let #(_c1, frames) = wire_support.open(app, "c1")
  let handle = server.connection(app, client_id: "c1")
  let pid = wire_support.server_pid(app)

  let _ = suspend(pid)
  let answers =
    list.repeat(Nil, 10)
    |> list.map(fn(_) {
      server.incoming(
        handle,
        bytes: wire_support.encode(transport.SessionMessage(Increment)),
      )
    })
  let _ = resume(pid)

  let shed = list.count(answers, fn(answer) { answer == server.Overloaded })
  let dropped =
    frames()
    |> list.count(fn(frame) {
      frame == transport.Dropped(target: transport.Session)
    })
  { shed > 0 && dropped == shed }
  |> should.be_true
}

@target(erlang)
pub fn socket_a_shed_control_is_still_handled_test() {
  // a resync lost to shedding would leave the client waiting for its snapshot
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_inbound_queue(frames: 3),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  let pid = wire_support.server_pid(app)

  let _ = suspend(pid)
  list.repeat(Nil, 6)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  wire_support.resync_session(c1)
  let _ = resume(pid)

  frames()
  |> list.count(wire_support.is_snapshot)
  |> should.equal(1)
}

@target(erlang)
pub fn socket_a_control_past_the_held_cap_closes_the_socket_test() {
  // it can't be answered in order, so the client reconnects and resyncs
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.rate_limit(per_second: 1, burst: 1)
      |> server.max_subscriptions(per_client: 1),
    )
  let #(_socket, connection, received) = attach_in_process(app)
  let assert Frame(transport.Version(..)) = next(received)
  let assert Frame(transport.Connected(..)) = next(received)

  wire_support.send(connection, transport.SessionMessage(IncrementSecondary))
  let assert Frame(transport.Acknowledge(..)) = next(received)
  list.each(["a", "b", "c"], fn(topic_id) {
    wire_support.send(connection, transport.Subscribe(topic_id:))
  })

  let assert Gone(..) = next(received)
  Nil
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(erlang)
@external(erlang, "sys", "resume")
fn resume(pid: process.Pid) -> Dynamic

@target(erlang)
@external(erlang, "sys", "suspend")
fn suspend(pid: process.Pid) -> Dynamic
