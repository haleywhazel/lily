// `server.open` and `server.attach`, a spawned process stands in for the socket
// no fixed sleeps, tests wait on a message or poll state

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/option
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/server
@target(erlang)
import lily/test_support.{type Message, type Model, IncrementSecondary}
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
/// Poll `condition` for up to `within` ms.
fn eventually(condition: fn() -> Bool, within within: Int) -> Bool {
  case condition() {
    True -> True
    False if within <= 0 -> False
    False -> {
      process.sleep(2)
      eventually(condition, within: within - 2)
    }
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

  eventually(fn() { test_support.client_count(app) == 0 }, within: 1000)
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
