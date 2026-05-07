// Tests for lily/topic on JavaScript, synchronous closure-based actors.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/int
@target(javascript)
import gleam/list
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/server
@target(javascript)
import lily/store
@target(javascript)
import lily/test_fixtures.{type Message, type Model, Decrement, Increment}
@target(javascript)
import lily/test_ref
@target(javascript)
import lily/topic
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn ser() {
  test_fixtures.custom_serialiser()
}

@target(javascript)
fn new_server() -> server.Server(Model, Message) {
  let assert Ok(srv) =
    server.new(
      initial: test_fixtures.initial_model(),
      serialiser: ser(),
      wiring: store.wiring()
        |> store.topic(
          id: "chat",
          extract: fn(message) { Ok(message) },
          update: test_fixtures.update,
          field_get: fn(model) { model },
          field_set: fn(_, inner) { inner },
        ),
    )
    |> server.start
  srv
}

@target(javascript)
/// Connect a mock client that accumulates received frames in a ref.
/// Returns a drain function that returns and clears the accumulated frames.
/// Drains the Connected frame sent on connect.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> fn() -> List(BitArray) {
  let ref = test_ref.new([])
  server.connect(srv, client_id: client_id, send: fn(frame) {
    test_ref.set(ref, [frame, ..test_ref.get(ref)])
  })
  test_ref.set(ref, [])
  fn() {
    let frames = list.reverse(test_ref.get(ref))
    test_ref.set(ref, [])
    frames
  }
}

@target(javascript)
fn encode_subscribe(topic_id: String) -> BitArray {
  transport.encode(transport.Subscribe(topic_id:), serialiser: ser())
}

@target(javascript)
fn encode_unsubscribe(topic_id: String) -> BitArray {
  transport.encode(transport.Unsubscribe(topic_id:), serialiser: ser())
}

@target(javascript)
fn encode_topic_message(topic_id: String, payload: Message) -> BitArray {
  transport.encode(
    transport.TopicMessage(topic_id:, payload:),
    serialiser: ser(),
  )
}

@target(javascript)
fn decode(bytes: BitArray) -> transport.Protocol(Model, Message) {
  let assert Ok(protocol) = transport.decode(bytes, serialiser: ser())
  protocol
}

@target(javascript)
fn new_ephemeral_topic(
  srv: server.Server(Model, Message),
) -> topic.Topic(Model, Message, topic.Ephemeral) {
  let assert Ok(t) = topic.new(srv, id: "test")
  t
}

@target(javascript)
fn new_stateful_topic(
  srv: server.Server(Model, Message),
) -> topic.Topic(Model, Message, topic.Stateful) {
  let assert Ok(t) = topic.new(srv, id: "chat")
  t |> topic.with_store
}

// =============================================================================
// REGISTRATION
// =============================================================================

@target(javascript)
pub fn topic_new_returns_ok_test() {
  let srv = new_server()
  topic.new(srv, id: "chat")
  |> should.be_ok
}

@target(javascript)
pub fn topic_new_duplicate_id_returns_error_test() {
  let srv = new_server()
  let assert Ok(_) = topic.new(srv, id: "chat")
  topic.new(srv, id: "chat")
  |> should.be_error
}

// =============================================================================
// BROADCAST (EPHEMERAL)
// =============================================================================

@target(javascript)
pub fn topic_broadcast_reaches_all_subscribers_test() {
  let srv = new_server()
  let t = new_ephemeral_topic(srv)
  let drain1 = connect_client(srv, "c1")
  let drain2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("test"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("test"))
  let _ = drain1()
  let _ = drain2()
  topic.broadcast(t, Increment)
  drain1()
  |> list.map(decode)
  |> should.equal([transport.Push(topic_id: "test", payload: Increment)])
  drain2()
  |> list.map(decode)
  |> should.equal([transport.Push(topic_id: "test", payload: Increment)])
}

@target(javascript)
pub fn topic_broadcast_to_zero_subscribers_does_not_crash_test() {
  let srv = new_server()
  let t = new_ephemeral_topic(srv)
  topic.broadcast(t, Increment)
  True
  |> should.be_true
}

@target(javascript)
pub fn topic_broadcast_from_skips_originator_test() {
  let srv = new_server()
  let t = new_ephemeral_topic(srv)
  let drain1 = connect_client(srv, "c1")
  let drain2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("test"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("test"))
  let _ = drain1()
  let _ = drain2()
  topic.broadcast_from(t, except: "c1", message: Increment)
  // c1 sent the broadcast, must receive nothing
  drain1()
  |> should.equal([])
  // c2 is not the originator, must receive the Push
  drain2()
  |> list.map(decode)
  |> should.equal([transport.Push(topic_id: "test", payload: Increment)])
}

// =============================================================================
// DISPATCH (STATEFUL)
// =============================================================================

@target(javascript)
pub fn topic_with_store_dispatch_emits_topic_update_test() {
  let srv = new_server()
  let t = new_stateful_topic(srv)
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  let _ = drain1()
  topic.dispatch(t, Increment)
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

@target(javascript)
pub fn topic_with_store_dispatch_increments_sequence_test() {
  let srv = new_server()
  let t = new_stateful_topic(srv)
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  let _ = drain1()
  topic.dispatch(t, Increment)
  let _ = drain1()
  topic.dispatch(t, Decrement)
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 2, payload: Decrement),
  ])
}

@target(javascript)
pub fn topic_dispatch_from_client_sends_acknowledge_and_updates_test() {
  let srv = new_server()
  let _t = new_stateful_topic(srv)
  let drain1 = connect_client(srv, "c1")
  let drain2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("chat"))
  let _ = drain1()
  let _ = drain2()
  server.incoming(
    srv,
    client_id: "c1",
    bytes: encode_topic_message("chat", Increment),
  )
  // c1 (sender) gets Acknowledge
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
  ])
  // c2 (not sender) gets TopicUpdate
  drain2()
  |> list.map(decode)
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

// =============================================================================
// SUBSCRIBE WITH SNAPSHOT
// =============================================================================

@target(javascript)
pub fn topic_subscribe_sends_snapshot_to_new_subscriber_test() {
  let srv = new_server()
  let _t = new_stateful_topic(srv)
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_fixtures.initial_model(),
    ),
  ])
}

@target(javascript)
pub fn topic_subscribe_to_unknown_topic_sends_rejected_test() {
  let srv = new_server()
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("missing"))
  drain1()
  |> list.map(decode)
  |> should.equal([transport.Rejected(topic_id: "missing", reason: "not found")])
}

// =============================================================================
// CAN SUBSCRIBE
// =============================================================================

@target(javascript)
pub fn topic_with_can_subscribe_false_sends_rejected_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "private")
  let _ =
    t
    |> topic.with_can_subscribe(fn(_client_id, _topic_id) { False })
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("private"))
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.Rejected(topic_id: "private", reason: "denied"),
  ])
}

// =============================================================================
// ON SUBSCRIBE / ON UNSUBSCRIBE
// =============================================================================

@target(javascript)
pub fn topic_with_on_subscribe_broadcasts_hook_messages_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "announce")
  let _ =
    t
    |> topic.with_on_subscribe(fn(_client_id) { [Increment] })
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("announce"))
  drain1()
  |> list.map(decode)
  |> should.equal([transport.Push(topic_id: "announce", payload: Increment)])
}

@target(javascript)
pub fn topic_with_on_unsubscribe_broadcasts_hook_messages_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "announce")
  let _ =
    t
    |> topic.with_on_unsubscribe(fn(_client_id) { [Decrement] })
  let drain1 = connect_client(srv, "c1")
  let drain2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("announce"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("announce"))
  let _ = drain1()
  let _ = drain2()
  server.incoming(srv, client_id: "c1", bytes: encode_unsubscribe("announce"))
  drain2()
  |> list.map(decode)
  |> should.equal([transport.Push(topic_id: "announce", payload: Decrement)])
}

// =============================================================================
// PARAMETRIC KINDS
// =============================================================================

@target(javascript)
pub fn topic_kind_creates_topic_on_subscribe_test() {
  let srv = new_server()
  let assert Ok(_) =
    topic.kind(
      srv,
      prefix: "room:",
      parse_id: int.parse,
      configure: fn(_, topic) { topic },
    )
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:42"))
  // Ephemeral kind topic, no Snapshot, no Rejected
  drain1()
  |> should.equal([])
}

@target(javascript)
pub fn topic_kind_parse_failure_sends_rejected_test() {
  let srv = new_server()
  let assert Ok(_) =
    topic.kind(
      srv,
      prefix: "room:",
      parse_id: int.parse,
      configure: fn(_, topic) { topic },
    )
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:abc"))
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.Rejected(topic_id: "room:abc", reason: "not found"),
  ])
}

// =============================================================================
// STOP
// =============================================================================

@target(javascript)
pub fn topic_stop_rejects_subsequent_subscribe_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "chat")
  topic.stop(t)
  let drain1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  drain1()
  |> list.map(decode)
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: "not found"),
  ])
}
