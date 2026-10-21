// Erlang liveness, monitors, supervision and crash isolation
// no fixed sleeps, tests wait on a `Down` or poll state

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleam/dynamic
@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/list
@target(erlang)
import gleam/option
@target(erlang)
import gleam/otp/static_supervisor
@target(erlang)
import gleam/otp/supervision

@target(erlang)
import gleeunit/should

@target(erlang)
import lily/internal/actor
@target(erlang)
import lily/server
@target(erlang)
import lily/test_support.{type Message, type Model, Increment}
@target(erlang)
import lily/transport
@target(erlang)
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn chat_snapshot(model: Model) -> transport.Protocol(Model, Message) {
  transport.Snapshot(target: transport.Topic("chat"), sequence: 0, state: model)
}

@target(erlang)
fn count_disconnects(events: List(server.ServerEvent(Model, Message))) -> Int {
  list.filter(events, fn(event) {
    case event {
      server.ClientDisconnected(..) -> True
      _ -> False
    }
  })
  |> list.length
}

@target(erlang)
/// Whether the server got down to `count` clients within a second.
fn eventually_clients(app: server.Server(Model, Message), count: Int) -> Bool {
  eventually(fn() { test_support.client_count(app) == count }, within: 1000)
}

@target(erlang)
/// Poll `condition` for up to `within` ms, for changes with no message.
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
fn kill(pid: process.Pid) -> Nil {
  process.kill(pid)
  wire_support.await_down(pid)
}

@target(erlang)
/// Wait until the server runs the topic on a new process.
fn kill_and_await_respawn(
  app: server.Server(Model, Message),
  topic_id: String,
) -> Nil {
  let first = topic_pid(app, topic_id)
  kill(first)
  eventually(
    fn() {
      case test_support.topic_watched(app, topic_id) {
        option.Some(watched) -> actor.watched_pid(watched) != first
        option.None -> False
      }
    },
    within: 1000,
  )
  |> should.be_true
  wire_support.settle(app)
}

@target(erlang)
/// Wait until the server gives up on the topic.
fn kill_and_await_forgotten(
  app: server.Server(Model, Message),
  topic_id: String,
) -> Nil {
  kill(topic_pid(app, topic_id))
  eventually(
    fn() { test_support.topic_watched(app, topic_id) == option.None },
    within: 1000,
  )
  |> should.be_true
}

@target(erlang)
fn server_pid(app: server.Server(Model, Message)) -> process.Pid {
  actor.watched_pid(test_support.inspect(app).watched)
}

@target(erlang)
/// Idle socket stand-in connected with `watch`, returns once connected.
fn spawn_connected_owner(
  app: server.Server(Model, Message),
  watch: server.ConnectionWatch,
) -> process.Pid {
  let done = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(connection) =
        server.connect_as(
          app,
          origin: option.None,
          send: fn(_) { Nil },
          client_id: "c1",
          seed: [],
          watch:,
        )
      process.send(done, connection)
      process.sleep_forever()
    })
  let assert Ok(_connection) = process.receive(done, within: 1000)
  owner
}

@target(erlang)
/// Test-owned tree around `server.supervised`, each start's handle is sent.
fn start_tree() -> #(
  process.Pid,
  process.Subject(server.Server(Model, Message)),
) {
  let ready = process.new_subject()
  let child =
    server.supervised(test_support.topic_builder())
    |> supervision.map_data(fn(app) {
      process.send(ready, app)
      app
    })
  let assert Ok(tree) =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 10)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  #(tree.pid, ready)
}

@target(erlang)
fn stop_tree(tree: process.Pid) -> Nil {
  process.send_exit(tree)
  wire_support.await_down(tree)
}

@target(erlang)
/// Live topic supervisor children, tells a restart from a respawn.
fn supervisor_children(app: server.Server(Model, Message)) -> Int {
  let assert option.Some(pid) =
    actor.supervisor_pid(test_support.inspect(app).supervisor)
  which_children(pid) |> list.length
}

@target(erlang)
fn topic_pid(
  app: server.Server(Model, Message),
  topic_id: String,
) -> process.Pid {
  let assert option.Some(watched) = test_support.topic_watched(app, topic_id)
  actor.watched_pid(watched)
}

// =============================================================================
// CONNECTION LIVENESS
// =============================================================================

@target(erlang)
pub fn supervision_connect_watches_the_calling_process_by_default_test() {
  let app = test_support.new_server()
  let done = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(_) =
        server.connect(app, origin: option.None, send: fn(_) { Nil })
      process.send(done, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(done, within: 1000)
  test_support.client_count(app)
  |> should.equal(1)

  kill(owner)

  eventually_clients(app, 0)
  |> should.be_true
}

@target(erlang)
pub fn supervision_connect_as_watch_caller_watches_the_calling_process_test() {
  let app = test_support.new_server()
  let owner = spawn_connected_owner(app, server.WatchCaller)

  kill(owner)

  eventually_clients(app, 0)
  |> should.be_true
}

@target(erlang)
pub fn supervision_unwatched_connection_survives_its_creator_dying_test() {
  let app = test_support.new_server()
  let owner = spawn_connected_owner(app, server.Unwatched)

  kill(owner)
  wire_support.settle(app)

  test_support.client_count(app)
  |> should.equal(1)
}

@target(erlang)
pub fn supervision_watching_another_process_disconnects_when_that_one_dies_test() {
  let app = test_support.new_server()
  let socket = process.spawn_unlinked(process.sleep_forever)
  let assert Ok(_) =
    server.connect_as(
      app,
      origin: option.None,
      send: fn(_) { Nil },
      client_id: "c1",
      seed: [],
      watch: server.WatchProcess(socket),
    )
  test_support.client_count(app)
  |> should.equal(1)

  kill(socket)

  eventually_clients(app, 0)
  |> should.be_true
}

@target(erlang)
pub fn supervision_watched_connection_closed_explicitly_is_not_disconnected_twice_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let socket = process.spawn_unlinked(process.sleep_forever)
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: fn(_) { Nil },
      client_id: "c1",
      seed: [],
      watch: server.WatchProcess(socket),
    )

  server.disconnect(connection)
  kill(socket)

  events(app)
  |> count_disconnects
  |> should.equal(1)
}

@target(erlang)
pub fn supervision_dead_connection_process_is_pruned_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let done = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(connection) =
        server.connect(app, origin: option.None, send: fn(_) { Nil })
      wire_support.subscribe(connection, "chat")
      process.send(done, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(done, within: 1000)
  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(1)
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)

  kill(owner)

  eventually_clients(app, 0)
  |> should.be_true
  wire_support.settle(app)
  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
  // exactly once, no second event from the same death
  events(app)
  |> count_disconnects
  |> should.equal(1)
}

@target(erlang)
pub fn supervision_monitor_reports_the_server_stopping_test() {
  let app = test_support.start_server(test_support.topic_builder())
  let monitor = server.monitor(app)

  server.stop(app)

  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(within: 1000)
  |> should.equal(Ok(Nil))
}

// =============================================================================
// TOPIC LIVENESS
// =============================================================================

@target(erlang)
pub fn supervision_a_dying_topic_leaves_the_server_alive_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames1) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.settle(app)

  kill(topic_pid(app, "room:1"))

  // the server actor is still answering
  test_support.client_count(app)
  |> should.equal(1)
  // and every other topic still serves
  let #(c2, frames2) = wire_support.open(app, "c2")
  wire_support.subscribe(c2, "chat")
  frames2()
  |> should.equal([chat_snapshot(test_support.initial_model())])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

@target(erlang)
pub fn supervision_a_dying_topic_is_respawned_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames1) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.settle(app)

  // the id is still registered, on a different process
  kill_and_await_respawn(app, "room:1")

  process.is_alive(topic_pid(app, "room:1")) |> should.be_true
  // a later subscribe lands on the respawned topic
  let #(c2, frames2) = wire_support.open(app, "c2")
  wire_support.subscribe(c2, "room:1")
  frames2()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("room:1"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

// =============================================================================
// SUPERVISION TREE
// =============================================================================

@target(erlang)
pub fn supervision_start_supervised_serves_and_owns_a_topic_supervisor_test() {
  let assert Ok(#(_tree, app)) =
    server.start_supervised(test_support.topic_builder())
  let #(c1, frames) = wire_support.open(app, "c1")

  // a full round trip through the supervised server
  wire_support.subscribe(c1, "chat")

  frames()
  |> should.equal([chat_snapshot(test_support.initial_model())])
  supervisor_children(app)
  |> should.equal(1)
}

@target(erlang)
pub fn supervision_stopping_the_tree_stops_every_process_test() {
  let #(tree, ready) = start_tree()
  let assert Ok(app) = process.receive(ready, within: 2000)
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)
  let chat = topic_pid(app, "chat")
  let assert option.Some(supervisor) =
    actor.supervisor_pid(test_support.inspect(app).supervisor)
  let server = server_pid(app)

  stop_tree(tree)

  wire_support.await_down(server)
  wire_support.await_down(supervisor)
  wire_support.await_down(chat)
}

@target(erlang)
pub fn supervision_a_server_crash_restarts_the_tree_test() {
  let #(tree, ready) = start_tree()
  let assert Ok(first) = process.receive(ready, within: 2000)
  server.dispatch_topic(first, topic_id: "chat", message: Increment)
  wire_support.settle(first)
  let first_chat = topic_pid(first, "chat")
  // snapshot, the handle resolves the name and follows the restart
  let first_pid = server_pid(first)

  kill(first_pid)

  // the child started again, on a genuinely new server
  let assert Ok(second) = process.receive(ready, within: 2000)
  { server_pid(second) == first_pid } |> should.be_false
  // and the handle taken before the crash reaches the process that came back
  { server_pid(first) == server_pid(second) } |> should.be_true
  // old topics died with the old server, the new one redeclares them
  wire_support.await_down(first_chat)
  server.dispatch_topic(second, topic_id: "chat", message: Increment)
  wire_support.settle(second)
  process.is_alive(topic_pid(second, "chat")) |> should.be_true

  stop_tree(tree)
}

@target(erlang)
pub fn supervision_a_handle_from_before_a_restart_still_serves_test() {
  let #(tree, ready) = start_tree()
  let assert Ok(first) = process.receive(ready, within: 2000)

  kill(server_pid(first))
  let assert Ok(_second) = process.receive(ready, within: 2000)

  // transports keep the boot-time handle, reconnects depend on this
  let assert Ok(_) =
    server.connect_as(
      first,
      client_id: "after",
      origin: option.None,
      send: fn(_bytes) { Nil },
      seed: [],
      watch: server.Unwatched,
    )
  test_support.client_count(first)
  |> should.equal(1)

  stop_tree(tree)
}

@target(erlang)
pub fn supervision_topic_children_are_temporary_test() {
  let assert Ok(#(_tree, app)) =
    server.start_supervised(test_support.topic_builder())
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  server.dispatch_topic(
    app,
    topic_id: "room:1",
    message: test_support.SetName("room:1"),
  )
  wire_support.settle(app)
  supervisor_children(app) |> should.equal(2)

  kill_and_await_respawn(app, "chat")

  // still two, a third would mean topic children stopped being Temporary
  supervisor_children(app) |> should.equal(2)
}

// =============================================================================
// TOPIC RESPAWN
// =============================================================================

@target(erlang)
pub fn supervision_a_restarted_topic_reattaches_subscribers_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames1) = wire_support.open(app, "c1")
  let #(c2, frames2) = wire_support.open(app, "c2")
  wire_support.subscribe(c1, "chat")
  wire_support.subscribe(c2, "chat")
  // reach sequence 3, then drain what that produced
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  let _ = frames1()
  let _ = frames2()

  kill_and_await_respawn(app, "chat")

  // both subscribers get a replacing snapshot back at sequence 0
  frames1() |> should.equal([chat_snapshot(test_support.initial_model())])
  frames2() |> should.equal([chat_snapshot(test_support.initial_model())])
  // and the respawned topic serves both of them from sequence 1
  wire_support.topic_message(c1, "chat", Increment)
  frames2()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

@target(erlang)
pub fn supervision_subscribed_does_not_refire_on_reattach_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  events(app)
  |> should.equal([
    server.ClientConnected("c1"),
    server.Subscribed("c1", "chat"),
  ])

  kill_and_await_respawn(app, "chat")

  // re-attached, but not re-joined
  events(app) |> should.equal([])
  // still attached, letting the respawned topic reach it
  let _ = frames()
  wire_support.topic_message(c1, "chat", Increment)
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
  ])
}

@target(erlang)
pub fn supervision_restarted_topic_starts_from_the_declared_initial_model_test() {
  let app = test_support.new_topic_server()
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)

  kill_and_await_respawn(app, "chat")

  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  frames()
  |> should.equal([chat_snapshot(test_support.initial_model())])
}

@target(erlang)
pub fn supervision_restart_storms_are_bounded_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.settle(app)

  // five respawns are allowed, the sixth death is given up on
  list.each([1, 2, 3, 4, 5], fn(_) { kill_and_await_respawn(app, "chat") })
  kill_and_await_forgotten(app, "chat")

  // and the server itself is untouched
  test_support.client_count(app) |> should.equal(1)
  // giving up is a failure, not a warning
  events(app)
  |> list.any(fn(event) {
    case event {
      server.Diagnostic(level: transport.Failure, ..) -> True
      _ -> False
    }
  })
  |> should.be_true
}

@target(erlang)
pub fn supervision_a_forgotten_topic_starts_its_next_life_with_a_full_budget_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.settle(app)
  list.each([1, 2, 3, 4, 5], fn(_) { kill_and_await_respawn(app, "chat") })
  kill_and_await_forgotten(app, "chat")

  // started again on demand, it may crash and come back like a new topic
  wire_support.subscribe(c1, "chat")
  wire_support.settle(app)
  kill_and_await_respawn(app, "chat")
}

// =============================================================================
// TOPIC LOADING
// =============================================================================

@target(erlang)
pub fn supervision_a_restarted_topic_loads_its_model_again_test() {
  let #(record, loads) = wire_support.recorder()
  let loaded = test_support.Model(..test_support.initial_model(), count: 42)
  let app =
    test_support.topic_builder()
    |> server.topic_init(id: "chat", init: fn() {
      record(Nil)
      loaded
    })
    |> test_support.start_server
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  kill_and_await_respawn(app, "chat")

  frames()
  |> should.equal([chat_snapshot(loaded)])
  loads()
  |> should.equal([Nil, Nil])
}

@target(erlang)
pub fn supervision_a_slow_loader_holds_up_its_topic_and_not_the_server_test() {
  let app =
    test_support.topic_builder()
    |> server.topic_init(id: "chat", init: fn() {
      process.sleep(300)
      test_support.initial_model()
    })
    |> test_support.start_server
  // no settle, it would wait on the loading topic
  let #(record1, recorded1) = wire_support.recorder()
  let #(record2, recorded2) = wire_support.recorder()
  let assert Ok(c1) =
    server.connect_as(
      app,
      origin: option.None,
      send: record1,
      client_id: "c1",
      seed: [],
      watch: server.Unwatched,
    )
  let assert Ok(c2) =
    server.connect_as(
      app,
      origin: option.None,
      send: record2,
      client_id: "c2",
      seed: [],
      watch: server.Unwatched,
    )
  let _ = test_support.client_count(app)
  let _ = recorded1()
  let _ = recorded2()
  wire_support.subscribe(c1, "chat")

  // another client is served while the topic is still loading
  wire_support.session_message(c2, test_support.IncrementSecondary)
  let _ = test_support.client_count(app)

  list.map(recorded2(), wire_support.decode)
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
  recorded1() |> should.equal([])
  // and the subscriber hears once it's loaded
  wire_support.settle(app)
  list.map(recorded1(), wire_support.decode)
  |> should.equal([chat_snapshot(test_support.initial_model())])
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(erlang)
@external(erlang, "supervisor", "which_children")
fn which_children(supervisor: process.Pid) -> List(dynamic.Dynamic)
