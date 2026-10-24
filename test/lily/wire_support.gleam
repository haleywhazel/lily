//// Drive a server the way a transport would, on either target. A mock client
//// records the frames it is sent and reads them back decoded, and every read
//// settles the server first, letting a test assert on exactly what had
//// arrived.
////
//// Running synchronously on JavaScript, the server and its topics make
//// settling a no-op. On Erlang they are processes, meaning settling asks each
//// of them a synchronous question, which is only answered once its mailbox
//// ahead of it is empty.

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleam/dict
@target(erlang)
import gleam/erlang/process
@target(javascript)
import gleam/javascript/promise
import gleam/list
import gleam/option

@target(erlang)
import lily/internal/actor
import lily/server.{type Builder, type Connection, type Server, type ServerEvent}
import lily/test_support.{type Message, type Model}
import lily/transport

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// A frame as a test sees it once decoded.
pub type Frame =
  transport.Protocol(Model, Message)

@target(erlang)
/// What a test that waits returns, gleeunit awaits it on JavaScript.
pub type Later =
  Nil

@target(javascript)
pub type Later =
  promise.Promise(Nil)

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(erlang)
/// Runs `next` once `milliseconds` have passed.
pub fn after(milliseconds: Int, next: fn() -> Nil) -> Later {
  process.sleep(milliseconds)
  next()
}

@target(javascript)
pub fn after(milliseconds: Int, next: fn() -> Nil) -> Later {
  promise.wait(milliseconds)
  |> promise.map(fn(_) { next() })
}

@target(erlang)
/// Like [`after`](#after) with another wait to follow.
pub fn after_then(milliseconds: Int, next: fn() -> Later) -> Later {
  process.sleep(milliseconds)
  next()
}

@target(javascript)
pub fn after_then(milliseconds: Int, next: fn() -> Later) -> Later {
  promise.wait(milliseconds)
  |> promise.await(fn(_) { next() })
}

@target(erlang)
/// Wait up to a second for `pid` to die, an already dead one counts.
pub fn await_down(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(within: 1000)
  Nil
}

/// The snapshot a `chat` subscriber gets of `model`, epoch read as 0.
pub fn chat_snapshot(model: Model) -> Frame {
  transport.Snapshot(
    target: transport.Topic("chat"),
    epoch: 0,
    sequence: 0,
    state: model,
  )
}

/// A snapshot's epoch is random per server, read as 0 so frames compare, see
/// [`decode_exact`](#decode_exact).
pub fn decode(bytes: BitArray) -> Frame {
  without_epoch(decode_exact(bytes))
}

/// Automatic serialiser, reads either format, epochs read as 0.
pub fn decode_automatic(bytes: BitArray) -> Frame {
  let assert Ok(protocol) =
    transport.decode(
      bytes,
      serialiser: test_support.automatic_serialiser(transport.Json),
    )
  without_epoch(protocol)
}

/// Keeps the epoch.
pub fn decode_exact(bytes: BitArray) -> Frame {
  let assert Ok(protocol) =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())
  protocol
}

pub fn encode(frame: Frame) -> BitArray {
  transport.encode(frame, serialiser: test_support.custom_serialiser())
}

@target(erlang)
/// Poll `condition` for up to `within` ms, for changes with no message.
pub fn eventually(condition: fn() -> Bool, within within: Int) -> Bool {
  case condition() {
    True -> True
    False if within <= 0 -> False
    False -> {
      process.sleep(2)
      eventually(condition, within: within - 2)
    }
  }
}

pub fn is_snapshot(frame: Frame) -> Bool {
  case frame {
    transport.Snapshot(..) -> True
    _ -> False
  }
}

/// Record server events, the getter settles and returns those since last call.
pub fn observed(
  builder: Builder(Model, Message),
) -> #(
  Builder(Model, Message),
  fn(Server(Model, Message)) -> List(ServerEvent(Model, Message)),
) {
  let #(record, recorded) = recorder()
  #(server.observe(builder, fn(event, _server) { record(event) }), fn(app) {
    settle(app)
    recorded()
  })
}

/// Unwatched mock client, greeting dropped, the getter settles first.
pub fn open(
  app: Server(Model, Message),
  client_id: String,
) -> #(Connection(Model, Message), fn() -> List(Frame)) {
  open_seeded(app, client_id, [])
}

/// Client whose send closure raises, a transport with a dead socket.
pub fn open_broken(
  app: Server(Model, Message),
  client_id: String,
) -> Connection(Model, Message) {
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: fn(_bytes) { panic as "send closure is gone" },
      client_id:,
      seed: [],
      watch: server.Unwatched,
    )
  connection
}

/// Mock client keeping raw bytes, greeting included.
pub fn open_raw(
  app: Server(Model, Message),
  client_id: String,
  seed: List(Message),
) -> #(Connection(Model, Message), fn() -> List(BitArray)) {
  let #(record, recorded) = recorder()
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: record,
      client_id:,
      seed:,
      watch: server.Unwatched,
    )
  #(connection, fn() {
    settle(app)
    recorded()
  })
}

/// Like [`open_seeded`](#open_seeded) but keeps the greeting.
pub fn open_recording(
  app: Server(Model, Message),
  client_id: String,
  seed: List(Message),
) -> #(Connection(Model, Message), fn() -> List(Frame)) {
  let #(record, recorded) = recorder()
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: record,
      client_id:,
      seed:,
      watch: server.Unwatched,
    )
  #(connection, fn() {
    settle(app)
    list.map(recorded(), decode)
  })
}

/// Like [`open`](#open) with `seed` applied first, its updates dropped.
pub fn open_seeded(
  app: Server(Model, Message),
  client_id: String,
  seed: List(Message),
) -> #(Connection(Model, Message), fn() -> List(Frame)) {
  let #(connection, frames) = open_recording(app, client_id, seed)
  let _ = frames()
  #(connection, frames)
}

@target(erlang)
/// Any process records, the test process drains in order. A subject on Erlang.
pub fn recorder() -> #(fn(value) -> Nil, fn() -> List(value)) {
  let subject = process.new_subject()
  #(process.send(subject, _), fn() { receive_all(subject) })
}

@target(javascript)
pub fn recorder() -> #(fn(value) -> Nil, fn() -> List(value)) {
  let cell = test_support.new([])
  #(
    fn(value) { test_support.set(cell, [value, ..test_support.get(cell)]) },
    fn() {
      let values = list.reverse(test_support.get(cell))
      test_support.set(cell, [])
      values
    },
  )
}

pub fn resync_session(connection: Connection(Model, Message)) -> Nil {
  send(
    connection,
    transport.Resync(cursors: [transport.Unknown(transport.Session)]),
  )
}

pub fn resync_topic(
  connection: Connection(Model, Message),
  topic_id: String,
) -> Nil {
  send(
    connection,
    transport.Resync(cursors: [transport.Unknown(transport.Topic(topic_id))]),
  )
}

pub fn send(connection: Connection(Model, Message), frame: Frame) -> Nil {
  let _ = server.incoming(connection, bytes: encode(frame))
  Nil
}

/// Send with the automatic serialiser in `format`.
pub fn send_in(
  connection: Connection(Model, Message),
  frame: Frame,
  format: transport.Format,
) -> Nil {
  let serialiser = test_support.automatic_serialiser(format)
  let _ =
    server.incoming(connection, bytes: transport.encode(frame, serialiser:))
  Nil
}

@target(erlang)
pub fn server_pid(app: Server(Model, Message)) -> process.Pid {
  actor.watched_pid(test_support.inspect(app).watched)
}

pub fn session_message(
  connection: Connection(Model, Message),
  payload: Message,
) -> Nil {
  send(connection, transport.SessionMessage(payload:))
}

@target(erlang)
/// Wait for the server and its topics to drain. Several rounds, frames can
/// bounce server to topic and back.
pub fn settle(app: Server(Model, Message)) -> Nil {
  case is_stopped(app) {
    True -> Nil
    False -> list.each([1, 2, 3, 4], fn(_) { settle_round(app) })
  }
}

@target(javascript)
pub fn settle(app: Server(Model, Message)) -> Nil {
  // already done, avoids a pure-expression warning at call sites
  let _ = server.inspect(app)
  Nil
}

@target(erlang)
/// Stop and wait for the server and its topics to die, final frames arrive.
pub fn stop(app: Server(Model, Message)) -> Nil {
  let processes = case server.inspect(app) {
    Error(Nil) -> []
    Ok(inspection) -> [
      inspection.watched,
      ..list.map(dict.values(inspection.topics), fn(topic) { topic.watched })
    ]
  }
  server.stop(app)
  mark_stopped(app)
  list.each(processes, fn(watched) { await_down(actor.watched_pid(watched)) })
}

@target(javascript)
pub fn stop(app: Server(Model, Message)) -> Nil {
  server.stop(app)
}

@target(erlang)
/// Stop and wait for one topic to die, final frames arrive.
pub fn stop_topic(app: Server(Model, Message), topic_id: String) -> Nil {
  let topic = test_support.topic_watched(app, topic_id)
  server.stop_topic(app, topic_id:)
  case topic {
    option.Some(watched) -> await_down(actor.watched_pid(watched))
    option.None -> Nil
  }
}

@target(javascript)
pub fn stop_topic(app: Server(Model, Message), topic_id: String) -> Nil {
  server.stop_topic(app, topic_id:)
}

pub fn subscribe(
  connection: Connection(Model, Message),
  topic_id: String,
) -> Nil {
  send(connection, transport.Subscribe(topic_id:))
}

pub fn topic_message(
  connection: Connection(Model, Message),
  topic_id: String,
  payload: Message,
) -> Nil {
  send(connection, transport.TopicMessage(topic_id:, payload:))
}

pub fn unsubscribe(
  connection: Connection(Model, Message),
  topic_id: String,
) -> Nil {
  send(connection, transport.Unsubscribe(topic_id:))
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(erlang)
fn receive_all(subject: process.Subject(value)) -> List(value) {
  case process.receive(subject, within: 0) {
    Ok(value) -> [value, ..receive_all(subject)]
    Error(Nil) -> []
  }
}

// one sync call to the server then each topic, dead topics skipped
@target(erlang)
fn settle_round(app: Server(Model, Message)) -> Nil {
  case server.inspect(app) {
    Error(Nil) -> Nil
    Ok(inspection) ->
      dict.each(inspection.topics, fn(_id, topic) {
        let _ = actor.rescue(topic.subscriber_count)
        Nil
      })
  }
}

fn without_epoch(frame: Frame) -> Frame {
  case frame {
    transport.Snapshot(..) -> transport.Snapshot(..frame, epoch: 0)
    _ -> frame
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

// remembered per test process, asking a dead server logs a crash
@target(erlang)
@external(erlang, "lily_test_support_ffi", "is_stopped")
fn is_stopped(app: Server(Model, Message)) -> Bool

@target(erlang)
@external(erlang, "lily_test_support_ffi", "mark_stopped")
fn mark_stopped(app: Server(Model, Message)) -> Nil
