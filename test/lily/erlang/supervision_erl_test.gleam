// Tests for Lily's process liveness on Erlang, monitors and crash isolation.
// All functions are @target(erlang), skipped on JavaScript.

@target(erlang)
import gleam/dynamic
@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/int
@target(erlang)
import gleam/list
@target(erlang)
import gleam/option
@target(erlang)
import gleam/otp/static_supervisor
@target(erlang)
import gleam/result
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/internal/actor_cell
@target(erlang)
import lily/server
@target(erlang)
import lily/store
@target(erlang)
import lily/test_support.{type Message, type Model, Increment}
@target(erlang)
import lily/topic
@target(erlang)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn ser() {
  test_support.custom_serialiser()
}

@target(erlang)
fn recv(subj: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subj, within: 200)
}

@target(erlang)
/// Connect a mock client backed by a Subject, draining the Connected frame
/// sent immediately on connect so tests can assert on subsequent frames.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subj = process.new_subject()
  let assert Ok(Nil) =
    server.connect(
      srv,
      client_id: client_id,
      origin: option.None,
      send: process.send(subj, _),
      session: [],
    )
  let _ = recv(subj)
  subj
}

@target(erlang)
/// Take every frame already queued for a mock client, so a later assertion
/// starts from an empty mailbox.
fn drain(subj: process.Subject(BitArray)) -> Nil {
  case process.receive(subj, within: 50) {
    Error(_) -> Nil
    Ok(_) -> drain(subj)
  }
}

@target(erlang)
fn decode(bytes: BitArray) -> transport.Protocol(Model, Message) {
  let assert Ok(protocol) = transport.decode(bytes, serialiser: ser())
  protocol
}

@target(erlang)
fn encode_resync(topic_id: String) -> BitArray {
  transport.encode(
    transport.Resync(cursors: [transport.Topic(topic_id)]),
    serialiser: ser(),
  )
}

@target(erlang)
fn encode_subscribe(topic_id: String) -> BitArray {
  transport.encode(transport.Subscribe(topic_id:), serialiser: ser())
}

@target(erlang)
/// Register a parametric kind whose topics are created inside the server's
/// own reducer, the path that used to link them to the server.
fn register_rooms(srv: server.Server(Model, Message)) -> Nil {
  let configure = fn(_id, t) { topic.with_store(t) }
  let assert Ok(Nil) =
    topic.kind(srv, prefix: "room:", parse_id: int.parse, configure:)
  Nil
}

@target(erlang)
/// Live children of a server's topic supervisor, straight from OTP, so a test
/// can tell a supervisor restart from a server-driven respawn.
fn supervisor_children(srv: server.Server(Model, Message)) -> Int {
  let assert option.Some(pid) =
    actor_cell.supervisor_pid(server.supervisor(srv))
  which_children(pid) |> list.length
}

@target(erlang)
fn server_pid(srv: server.Server(Model, Message)) -> process.Pid {
  actor_cell.watched_pid(server.watched(srv))
}

@target(erlang)
/// A supervised server in a tree this test owns, so it can kill the tree and
/// see every `started` call. Exercises `server.supervised`.
fn start_tree(
  started: fn(server.Server(Model, Message)) -> Nil,
) -> #(process.Pid, process.Subject(server.Server(Model, Message))) {
  let ready = process.new_subject()
  let child =
    server.supervised(
      initial: test_support.initial_model(),
      serialiser: ser(),
      wiring: store.wiring(),
      origins: server.AnyOrigin,
      started: fn(srv) {
        process.send(ready, srv)
        started(srv)
      },
    )
  let assert Ok(tree) =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 10)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  #(tree.pid, ready)
}

@target(erlang)
@external(erlang, "supervisor", "which_children")
fn which_children(supervisor: process.Pid) -> List(dynamic.Dynamic)

@target(erlang)
fn topic_pid(
  srv: server.Server(Model, Message),
  topic_id: String,
) -> process.Pid {
  let assert option.Some(watched) = server.topic_watched(srv, topic_id)
  actor_cell.watched_pid(watched)
}

// =============================================================================
// CONNECTION LIVENESS
// =============================================================================

@target(erlang)
pub fn dead_connection_process_is_pruned_test() {
  let srv = test_support.new_server()
  let disconnects = process.new_subject()
  server.on_disconnect(srv, process.send(disconnects, _))
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)

  let frames = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) =
        server.connect(
          srv,
          client_id: "c1",
          origin: option.None,
          send: process.send(frames, _),
          session: [],
        )
      server.watch(srv, client_id: "c1")
      server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
      process.sleep(2000)
    })
  process.sleep(100)
  server.client_count(srv)
  |> should.equal(1)
  topic.subscriber_count(chat)
  |> should.equal(1)

  process.kill(owner)
  process.sleep(100)
  server.client_count(srv)
  |> should.equal(0)
  topic.subscriber_count(chat)
  |> should.equal(0)
  process.receive(disconnects, within: 200)
  |> should.equal(Ok("c1"))
  // exactly once, no second hook call from the same death
  process.receive(disconnects, within: 100)
  |> should.be_error
}

@target(erlang)
pub fn double_disconnect_fires_the_hook_once_test() {
  let srv = test_support.new_server()
  let disconnects = process.new_subject()
  server.on_disconnect(srv, process.send(disconnects, _))
  let _ = connect_client(srv, "c1")

  server.disconnect(srv, client_id: "c1")
  server.disconnect(srv, client_id: "c1")
  process.sleep(50)

  process.receive(disconnects, within: 200)
  |> should.equal(Ok("c1"))
  process.receive(disconnects, within: 100)
  |> should.be_error
}

// =============================================================================
// TOPIC LIVENESS
// =============================================================================

@target(erlang)
pub fn a_dying_topic_leaves_the_server_alive_test() {
  let srv = test_support.new_server()
  register_rooms(srv)
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:1"))
  process.sleep(50)
  let _ = recv(s1)

  process.kill(topic_pid(srv, "room:1"))
  process.sleep(100)

  // the server actor is still answering
  server.client_count(srv)
  |> should.equal(1)
  // and every other topic still serves
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("chat"))
  process.sleep(50)
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Snapshot(
        target: transport.Topic("chat"),
        sequence: 0,
        state: test_support.initial_model(),
      ))
    Error(_) -> should.fail()
  }
  topic.subscriber_count(chat)
  |> should.equal(1)
}

@target(erlang)
pub fn a_dying_topic_is_respawned_test() {
  let srv = test_support.new_server()
  register_rooms(srv)
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:1"))
  process.sleep(50)
  let _ = recv(s1)
  let first = topic_pid(srv, "room:1")

  process.kill(first)
  process.sleep(100)
  // the id is still registered, on a different process
  let second = topic_pid(srv, "room:1")
  { second == first } |> should.equal(False)
  process.is_alive(second) |> should.equal(True)

  // a later subscribe lands on the respawned topic
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("room:1"))
  process.sleep(50)
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Snapshot(
        target: transport.Topic("room:1"),
        sequence: 0,
        state: test_support.initial_model(),
      ))
    Error(_) -> should.fail()
  }
}

// =============================================================================
// RECONNECT
// =============================================================================

@target(erlang)
pub fn a_resyncing_client_resubscribes_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)

  // the connection the client had before the socket dropped
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  process.sleep(50)
  let _ = recv(s1)
  server.disconnect(srv, client_id: "c1")

  // the connection it comes back on, which resyncs rather than resubscribes
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_resync("chat"))
  process.sleep(50)
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Snapshot(
        target: transport.Topic("chat"),
        sequence: 0,
        state: test_support.initial_model(),
      ))
    Error(_) -> should.fail()
  }
  topic.subscriber_count(chat)
  |> should.equal(1)

  // and a later broadcast still reaches it
  topic.dispatch(chat, Increment)
  process.sleep(50)
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.TopicUpdate(
        topic_id: "chat",
        sequence: 1,
        payload: Increment,
      ))
    Error(_) -> should.fail()
  }
}

// =============================================================================
// SUPERVISION TREE
// =============================================================================

@target(erlang)
pub fn start_supervised_serves_and_stops_cleanly_test() {
  let assert Ok(#(_tree, srv)) =
    server.start_supervised(
      initial: test_support.initial_model(),
      serialiser: ser(),
      wiring: store.wiring(),
      origins: server.AnyOrigin,
      started: fn(srv) {
        let assert Ok(chat) = topic.new(srv, id: "chat")
        let _ = topic.with_store(chat)
        Nil
      },
    )

  // a full round trip through the supervised server
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  process.sleep(50)
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Snapshot(
        target: transport.Topic("chat"),
        sequence: 0,
        state: test_support.initial_model(),
      ))
    Error(_) -> should.fail()
  }
  supervisor_children(srv)
  |> should.equal(1)
}

@target(erlang)
pub fn stopping_the_tree_stops_every_process_test() {
  let #(tree, ready) =
    start_tree(fn(srv) {
      let assert Ok(chat) = topic.new(srv, id: "chat")
      let _ = topic.with_store(chat)
      Nil
    })
  let assert Ok(srv) = process.receive(ready, within: 2000)
  let chat = topic_pid(srv, "chat")
  let assert option.Some(supervisor) =
    actor_cell.supervisor_pid(server.supervisor(srv))

  process.send_exit(tree)
  process.sleep(200)

  process.is_alive(tree) |> should.equal(False)
  process.is_alive(server_pid(srv)) |> should.equal(False)
  process.is_alive(supervisor) |> should.equal(False)
  process.is_alive(chat) |> should.equal(False)
}

@target(erlang)
pub fn a_server_crash_restarts_the_tree_test() {
  let #(tree, ready) =
    start_tree(fn(srv) {
      let assert Ok(chat) = topic.new(srv, id: "chat")
      let _ = topic.with_store(chat)
      Nil
    })
  let assert Ok(first) = process.receive(ready, within: 2000)
  let first_chat = topic_pid(first, "chat")

  process.kill(server_pid(first))
  process.sleep(200)

  // `started` fired again, on a genuinely new server
  let assert Ok(second) = process.receive(ready, within: 2000)
  { server_pid(second) == server_pid(first) } |> should.equal(False)
  // and the old topics went with the old server
  process.is_alive(first_chat) |> should.equal(False)
  process.is_alive(topic_pid(second, "chat")) |> should.equal(True)

  process.send_exit(tree)
  process.sleep(100)
}

@target(erlang)
pub fn topic_children_are_temporary_test() {
  let assert Ok(#(_tree, srv)) =
    server.start_supervised(
      initial: test_support.initial_model(),
      serialiser: ser(),
      wiring: store.wiring(),
      origins: server.AnyOrigin,
      started: fn(srv) {
        let assert Ok(chat) = topic.new(srv, id: "chat")
        let _ = topic.with_store(chat)
        let assert Ok(_) = topic.new(srv, id: "typing")
        Nil
      },
    )
  supervisor_children(srv) |> should.equal(2)
  let first = topic_pid(srv, "chat")

  process.kill(first)
  process.sleep(150)

  // exactly two again. The server respawned one, the supervisor restarted none.
  // A third child here would mean the topic child stopped being Temporary.
  supervisor_children(srv) |> should.equal(2)
  process.is_alive(first) |> should.equal(False)
}

// =============================================================================
// TOPIC RESPAWN
// =============================================================================

@target(erlang)
pub fn a_restarted_topic_reattaches_subscribers_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("chat"))
  process.sleep(50)
  let _ = recv(s1)
  let _ = recv(s2)

  // reach sequence 3, then drain what that produced
  topic.dispatch(chat, Increment)
  topic.dispatch(chat, Increment)
  topic.dispatch(chat, Increment)
  process.sleep(50)
  drain(s1)
  drain(s2)

  process.kill(topic_pid(srv, "chat"))
  process.sleep(150)

  // both subscribers get a replacing snapshot back at sequence 0
  let replacing =
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    )
  case recv(s1) {
    Ok(bytes) -> decode(bytes) |> should.equal(replacing)
    Error(_) -> should.fail()
  }
  case recv(s2) {
    Ok(bytes) -> decode(bytes) |> should.equal(replacing)
    Error(_) -> should.fail()
  }

  // and the respawned topic serves both of them from sequence 1
  server.incoming(
    srv,
    client_id: "c1",
    bytes: transport.encode(
      transport.TopicMessage(topic_id: "chat", payload: Increment),
      serialiser: ser(),
    ),
  )
  process.sleep(50)
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.TopicUpdate(
        topic_id: "chat",
        sequence: 1,
        payload: Increment,
      ))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn join_hooks_do_not_refire_on_reattach_test() {
  let srv = test_support.new_server()
  let joins = process.new_subject()
  let assert Ok(chat) =
    topic.new(srv, id: "chat")
    |> result.map(topic.with_store)
    |> result.map(
      topic.on_subscribe(_, fn(client_id) {
        process.send(joins, client_id)
        []
      }),
    )
  let _ = chat
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  process.sleep(50)
  process.receive(joins, within: 200) |> should.equal(Ok("c1"))

  process.kill(topic_pid(srv, "chat"))
  process.sleep(150)

  // re-attached, but not re-joined
  process.receive(joins, within: 200) |> should.be_error

  // still attached, so the respawned topic reaches it
  drain(s1)
  server.incoming(
    srv,
    client_id: "c1",
    bytes: transport.encode(
      transport.TopicMessage(topic_id: "chat", payload: Increment),
      serialiser: ser(),
    ),
  )
  process.sleep(50)
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Acknowledge(
        target: transport.Topic("chat"),
        sequence: 1,
      ))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn restart_storms_are_bounded_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let _ = topic.with_store(chat)
  let _ = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  process.sleep(50)

  // five respawns are allowed, the sixth death is given up on
  list.each([1, 2, 3, 4, 5], fn(_) {
    process.kill(topic_pid(srv, "chat"))
    process.sleep(80)
  })
  case server.topic_watched(srv, "chat") {
    option.Some(_) -> Nil
    option.None -> should.fail()
  }

  process.kill(topic_pid(srv, "chat"))
  process.sleep(150)
  server.topic_watched(srv, "chat") |> should.equal(option.None)
  // and the server itself is untouched
  server.client_count(srv) |> should.equal(1)
}
