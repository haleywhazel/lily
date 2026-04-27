// Tests for lily/pub_sub on Erlang — uses OTP actor with process.Subject.
// All functions are @target(erlang) — skipped on JavaScript.

@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/pub_sub
@target(erlang)
import lily/test_fixtures.{type Message, Increment, SetName}
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
fn new_pub_sub() -> pub_sub.PubSub(Message) {
  let assert Ok(bus) = pub_sub.new()
  bus
}

@target(erlang)
/// Register a mock client that captures received messages in a Subject.
fn register_client(
  bus: pub_sub.PubSub(Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subj = process.new_subject()
  pub_sub.register(bus, client_id:, send: process.send(subj, _))
  subj
}

@target(erlang)
/// Receive one message from Subject with a 200ms timeout.
fn recv(subj: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subj, within: 200)
}

// =============================================================================
// STARTUP
// =============================================================================

@target(erlang)
pub fn pub_sub_new_returns_ok_test() {
  pub_sub.new()
  |> should.be_ok
}

// =============================================================================
// BROADCAST
// =============================================================================

@target(erlang)
pub fn pub_sub_broadcast_delivers_to_subscriber_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:general")
  pub_sub.broadcast(
    bus,
    topic: "room:general",
    message: Increment,
    serialiser: ser(),
  )
  recv(s1)
  |> should.be_ok
}

@target(erlang)
pub fn pub_sub_broadcast_decodes_as_push_frame_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:general")
  pub_sub.broadcast(
    bus,
    topic: "room:general",
    message: SetName("Alice"),
    serialiser: ser(),
  )
  case recv(s1) {
    Ok(msg) ->
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Push(payload: SetName("Alice"))))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn pub_sub_broadcast_only_to_topic_subscribers_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  let s2 = register_client(bus, "c2")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.subscribe(bus, client_id: "c2", topic: "room:b")
  pub_sub.broadcast(
    bus,
    topic: "room:a",
    message: Increment,
    serialiser: ser(),
  )
  recv(s1)
  |> should.be_ok
  recv(s2)
  |> should.be_error
}

@target(erlang)
pub fn pub_sub_broadcast_unknown_topic_no_crash_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  pub_sub.broadcast(
    bus,
    topic: "no-one-is-here",
    message: Increment,
    serialiser: ser(),
  )
  recv(s1)
  |> should.be_error
}

// =============================================================================
// BROADCAST_FROM
// =============================================================================

@target(erlang)
pub fn pub_sub_broadcast_from_excludes_sender_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  let s2 = register_client(bus, "c2")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.subscribe(bus, client_id: "c2", topic: "room:a")
  pub_sub.broadcast_from(
    bus,
    from: "c1",
    topic: "room:a",
    message: Increment,
    serialiser: ser(),
  )
  recv(s2)
  |> should.be_ok
  recv(s1)
  |> should.be_error
}

// =============================================================================
// UNREGISTER
// =============================================================================

@target(erlang)
pub fn pub_sub_unregister_stops_delivery_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.unregister(bus, client_id: "c1")
  pub_sub.broadcast(
    bus,
    topic: "room:a",
    message: Increment,
    serialiser: ser(),
  )
  recv(s1)
  |> should.be_error
}

// =============================================================================
// UNSUBSCRIBE
// =============================================================================

@target(erlang)
pub fn pub_sub_unsubscribe_stops_delivery_test() {
  let bus = new_pub_sub()
  let s1 = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.unsubscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.broadcast(
    bus,
    topic: "room:a",
    message: Increment,
    serialiser: ser(),
  )
  recv(s1)
  |> should.be_error
}
