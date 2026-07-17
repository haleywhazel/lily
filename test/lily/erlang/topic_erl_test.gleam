// Tests for lily/topic on Erlang, OTP actors with process.Subject.
// All functions are @target(erlang), skipped on JavaScript.

@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/int
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/server
@target(erlang)
import lily/store
@target(erlang)
import lily/test_fixtures.{type Message, type Model, Decrement, Increment}
@target(erlang)
import lily/topic
@target(erlang)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn ser() {
  test_fixtures.custom_serialiser()
}

@target(erlang)
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

@target(erlang)
/// Connect a mock client, draining the Connected frame. Returns the Subject.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subj = process.new_subject()
  server.connect(srv, client_id: client_id, send: process.send(subj, _))
  let _ = process.receive(subj, within: 200)
  subj
}

@target(erlang)
fn recv(subj: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subj, within: 200)
}

@target(erlang)
fn encode_subscribe(topic_id: String) -> BitArray {
  transport.encode(transport.Subscribe(topic_id:), serialiser: ser())
}

@target(erlang)
fn encode_unsubscribe(topic_id: String) -> BitArray {
  transport.encode(transport.Unsubscribe(topic_id:), serialiser: ser())
}

@target(erlang)
fn encode_topic_message(topic_id: String, payload: Message) -> BitArray {
  transport.encode(
    transport.TopicMessage(topic_id:, payload:),
    serialiser: ser(),
  )
}

@target(erlang)
fn decode(bytes: BitArray) -> transport.Protocol(Model, Message) {
  let assert Ok(protocol) = transport.decode(bytes, serialiser: ser())
  protocol
}

@target(erlang)
fn new_ephemeral_topic(
  srv: server.Server(Model, Message),
) -> topic.Topic(Model, Message, topic.Ephemeral) {
  let assert Ok(t) = topic.new(srv, id: "test")
  t
}

@target(erlang)
fn new_stateful_topic(
  srv: server.Server(Model, Message),
) -> topic.Topic(Model, Message, topic.Stateful) {
  let assert Ok(t) = topic.new(srv, id: "chat")
  t |> topic.with_store
}

// =============================================================================
// REGISTRATION
// =============================================================================

@target(erlang)
pub fn topic_new_returns_ok_test() {
  let srv = new_server()
  topic.new(srv, id: "chat")
  |> should.be_ok
}

@target(erlang)
pub fn topic_new_duplicate_id_returns_error_test() {
  let srv = new_server()
  let assert Ok(_) = topic.new(srv, id: "chat")
  topic.new(srv, id: "chat")
  |> should.be_error
}

// =============================================================================
// BROADCAST (EPHEMERAL)
// =============================================================================

@target(erlang)
pub fn topic_broadcast_reaches_all_subscribers_test() {
  let srv = new_server()
  let t = new_ephemeral_topic(srv)
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("test"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("test"))
  process.sleep(20)
  topic.broadcast(t, Increment)
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "test", payload: Increment))
    Error(_) -> should.fail()
  }
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "test", payload: Increment))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn topic_broadcast_to_zero_subscribers_does_not_crash_test() {
  let srv = new_server()
  let t = new_ephemeral_topic(srv)
  topic.broadcast(t, Increment)
  True
  |> should.be_true
}

@target(erlang)
pub fn topic_broadcast_from_skips_originator_test() {
  let srv = new_server()
  let t = new_ephemeral_topic(srv)
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("test"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("test"))
  process.sleep(20)
  topic.broadcast_from(t, except: "c1", message: Increment)
  // c1 sent the broadcast, must not receive it
  recv(s1)
  |> should.be_error
  // c2 is not the originator, must receive it
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "test", payload: Increment))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn topic_client_message_on_ephemeral_relays_to_others_test() {
  let srv = new_server()
  let _t = new_ephemeral_topic(srv)
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("test"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("test"))
  process.sleep(20)
  // c1 sends a topic message to the ephemeral topic
  server.incoming(
    srv,
    client_id: "c1",
    bytes: encode_topic_message("test", Increment),
  )
  process.sleep(20)
  // The originator does not get its own message echoed back
  recv(s1)
  |> should.be_error
  // Other subscribers receive it as a Push, no hook required
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "test", payload: Increment))
    Error(_) -> should.fail()
  }
}

// =============================================================================
// DISPATCH (STATEFUL)
// =============================================================================

@target(erlang)
pub fn topic_with_store_dispatch_emits_topic_update_test() {
  let srv = new_server()
  let t = new_stateful_topic(srv)
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  // Drain Snapshot from subscribe
  let _ = recv(s1)
  topic.dispatch(t, Increment)
  case recv(s1) {
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
pub fn topic_with_store_dispatch_increments_sequence_test() {
  let srv = new_server()
  let t = new_stateful_topic(srv)
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  let _ = recv(s1)
  topic.dispatch(t, Increment)
  let _ = recv(s1)
  topic.dispatch(t, Decrement)
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.TopicUpdate(
        topic_id: "chat",
        sequence: 2,
        payload: Decrement,
      ))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn topic_dispatch_from_client_sends_acknowledge_and_updates_test() {
  let srv = new_server()
  let _t = new_stateful_topic(srv)
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("chat"))
  let _ = recv(s1)
  let _ = recv(s2)
  // c1 sends a topic message
  server.incoming(
    srv,
    client_id: "c1",
    bytes: encode_topic_message("chat", Increment),
  )
  // c1 gets Acknowledge (not TopicUpdate, it's the sender)
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Acknowledge(
        target: transport.Topic("chat"),
        sequence: 1,
      ))
    Error(_) -> should.fail()
  }
  // c2 gets TopicUpdate (not the sender)
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
// SUBSCRIBE WITH SNAPSHOT
// =============================================================================

@target(erlang)
pub fn topic_subscribe_sends_snapshot_to_new_subscriber_test() {
  let srv = new_server()
  let _t = new_stateful_topic(srv)
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Snapshot(
        target: transport.Topic("chat"),
        sequence: 0,
        state: test_fixtures.initial_model(),
      ))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn topic_subscribe_to_unknown_topic_sends_rejected_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("missing"))
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Rejected(
        topic_id: "missing",
        reason: "not found",
      ))
    Error(_) -> should.fail()
  }
}

// =============================================================================
// CAN SUBSCRIBE
// =============================================================================

@target(erlang)
pub fn topic_with_can_subscribe_false_sends_rejected_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "private")
  let _ =
    t
    |> topic.with_can_subscribe(fn(_client_id, _topic_id) { False })
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("private"))
  process.sleep(20)
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Rejected(topic_id: "private", reason: "denied"))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn topic_message_from_non_subscriber_is_dropped_test() {
  let srv = new_server()
  let _t = new_stateful_topic(srv)
  let s1 = connect_client(srv, "c1")
  let _s2 = connect_client(srv, "c2")
  // Only c1 subscribes, c2 stays outside the topic.
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  // Drain c1's subscribe Snapshot.
  let _ = recv(s1)
  // c2, never subscribed, tries to write to the topic. The write must be
  // dropped rather than mutating shared state and fanning out to subscribers.
  server.incoming(
    srv,
    client_id: "c2",
    bytes: encode_topic_message("chat", Increment),
  )
  process.sleep(20)
  // The subscriber sees no TopicUpdate, the unauthorised write was ignored.
  recv(s1)
  |> should.be_error
}

// =============================================================================
// ON SUBSCRIBE / ON UNSUBSCRIBE
// =============================================================================

@target(erlang)
pub fn topic_with_on_subscribe_broadcasts_hook_messages_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "announce")
  let _ =
    t
    |> topic.with_on_subscribe(fn(_client_id) { [Increment] })
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("announce"))
  process.sleep(20)
  // c1 receives the Push from the on_subscribe hook
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "announce", payload: Increment))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn topic_with_on_unsubscribe_broadcasts_hook_messages_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "announce")
  let _ =
    t
    |> topic.with_on_unsubscribe(fn(_client_id) { [Decrement] })
  let _s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("announce"))
  server.incoming(srv, client_id: "c2", bytes: encode_subscribe("announce"))
  process.sleep(20)
  // c1 unsubscribes, on_unsubscribe hook fires, broadcasting Decrement
  server.incoming(srv, client_id: "c1", bytes: encode_unsubscribe("announce"))
  process.sleep(20)
  // c2 (still subscribed) receives the Push from the hook
  case recv(s2) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "announce", payload: Decrement))
    Error(_) -> should.fail()
  }
}

// =============================================================================
// PARAMETRIC KINDS
// =============================================================================

@target(erlang)
pub fn topic_kind_creates_topic_on_subscribe_test() {
  let srv = new_server()
  let assert Ok(_) =
    topic.kind(
      srv,
      prefix: "room:",
      parse_id: int.parse,
      configure: fn(_, topic) { topic },
    )
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:42"))
  // No snapshot for an ephemeral kind-created topic, no Rejected either.
  // Verify no Rejected frame was sent.
  recv(s1)
  |> should.be_error
}

@target(erlang)
pub fn topic_kind_parse_failure_sends_rejected_test() {
  let srv = new_server()
  let assert Ok(_) =
    topic.kind(
      srv,
      prefix: "room:",
      parse_id: int.parse,
      configure: fn(_, topic) { topic },
    )
  let s1 = connect_client(srv, "c1")
  // "room:abc", "abc" fails int.parse and is rejected
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:abc"))
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Rejected(
        topic_id: "room:abc",
        reason: "not found",
      ))
    Error(_) -> should.fail()
  }
}

// =============================================================================
// STOP
// =============================================================================

@target(erlang)
pub fn topic_stop_rejects_subsequent_subscribe_test() {
  let srv = new_server()
  let assert Ok(t) = topic.new(srv, id: "chat")
  topic.stop(t)
  process.sleep(20)
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("chat"))
  case recv(s1) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Rejected(topic_id: "chat", reason: "not found"))
    Error(_) -> should.fail()
  }
}
