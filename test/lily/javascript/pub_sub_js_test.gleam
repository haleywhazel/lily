// Tests for lily/pub_sub on JavaScript — synchronous closure-based pubsub.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/pub_sub
@target(javascript)
import lily/test_fixtures.{type Message, type Model, Increment, Reset, SetName}
@target(javascript)
import lily/test_ref
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
fn new_pub_sub() -> pub_sub.PubSub(Message) {
  let assert Ok(bus) = pub_sub.new()
  bus
}

@target(javascript)
/// Register a mock client that captures received messages in a ref list.
/// Returns a drain fn that returns and clears the captured messages.
fn register_client(
  bus: pub_sub.PubSub(Message),
  client_id: String,
) -> fn() -> List(BitArray) {
  let ref = test_ref.new([])
  pub_sub.register(bus, client_id:, send: fn(msg) {
    test_ref.set(ref, [msg, ..test_ref.get(ref)])
  })
  fn() {
    let msgs = list.reverse(test_ref.get(ref))
    test_ref.set(ref, [])
    msgs
  }
}

// =============================================================================
// STARTUP
// =============================================================================

@target(javascript)
pub fn js_pub_sub_new_returns_ok_test() {
  pub_sub.new()
  |> should.be_ok
}

// =============================================================================
// BROADCAST
// =============================================================================

@target(javascript)
pub fn js_pub_sub_broadcast_delivers_to_subscriber_test() {
  let bus = new_pub_sub()
  let drain = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:general")
  pub_sub.broadcast(
    bus,
    topic: "room:general",
    message: Increment,
    serialiser: ser(),
  )
  drain()
  |> list.length
  |> should.equal(1)
}

@target(javascript)
pub fn js_pub_sub_broadcast_decodes_as_push_frame_test() {
  let bus = new_pub_sub()
  let drain = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:general")
  pub_sub.broadcast(
    bus,
    topic: "room:general",
    message: SetName("Alice"),
    serialiser: ser(),
  )
  case drain() {
    [msg, ..] ->
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Push(payload: SetName("Alice"))))
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_pub_sub_broadcast_only_to_topic_subscribers_test() {
  let bus = new_pub_sub()
  let drain_a = register_client(bus, "c1")
  let drain_b = register_client(bus, "c2")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.subscribe(bus, client_id: "c2", topic: "room:b")
  pub_sub.broadcast(bus, topic: "room:a", message: Increment, serialiser: ser())
  drain_a()
  |> list.length
  |> should.equal(1)
  drain_b()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_pub_sub_broadcast_unknown_topic_no_crash_test() {
  let bus = new_pub_sub()
  let drain = register_client(bus, "c1")
  pub_sub.broadcast(
    bus,
    topic: "no-one-is-here",
    message: Increment,
    serialiser: ser(),
  )
  drain()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_pub_sub_broadcast_without_registration_no_crash_test() {
  // Subscribe without registering first — no send fn, but broadcast shouldn't
  // crash. Verifies the broadcast logic tolerates a subscribers-without-clients
  // edge case (e.g., race between register and subscribe).
  let bus = new_pub_sub()
  pub_sub.subscribe(bus, client_id: "ghost", topic: "room:general")
  pub_sub.broadcast(
    bus,
    topic: "room:general",
    message: Increment,
    serialiser: ser(),
  )
  True
  |> should.be_true
}

// =============================================================================
// BROADCAST_FROM
// =============================================================================

@target(javascript)
pub fn js_pub_sub_broadcast_from_excludes_sender_test() {
  let bus = new_pub_sub()
  let drain_a = register_client(bus, "c1")
  let drain_b = register_client(bus, "c2")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.subscribe(bus, client_id: "c2", topic: "room:a")
  pub_sub.broadcast_from(
    bus,
    from: "c1",
    topic: "room:a",
    message: Increment,
    serialiser: ser(),
  )
  drain_a()
  |> list.length
  |> should.equal(0)
  drain_b()
  |> list.length
  |> should.equal(1)
}

// =============================================================================
// UNREGISTER
// =============================================================================

@target(javascript)
pub fn js_pub_sub_unregister_stops_delivery_test() {
  let bus = new_pub_sub()
  let drain = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.unregister(bus, client_id: "c1")
  pub_sub.broadcast(bus, topic: "room:a", message: Increment, serialiser: ser())
  drain()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_pub_sub_unregister_auto_unsubscribes_all_topics_test() {
  // Unregister should drop the client from every topic it was in. After
  // re-registering, a broadcast to the old topic should not deliver.
  let bus = new_pub_sub()
  let _drain_old = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:b")
  pub_sub.unregister(bus, client_id: "c1")
  // Re-register with a fresh capture — if unregister didn't clear subs,
  // the broadcast would still target "c1" and land here.
  let drain_new = register_client(bus, "c1")
  pub_sub.broadcast(bus, topic: "room:a", message: Increment, serialiser: ser())
  pub_sub.broadcast(bus, topic: "room:b", message: Increment, serialiser: ser())
  drain_new()
  |> list.length
  |> should.equal(0)
}

// =============================================================================
// UNSUBSCRIBE
// =============================================================================

@target(javascript)
pub fn js_pub_sub_unsubscribe_stops_delivery_test() {
  let bus = new_pub_sub()
  let drain = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.unsubscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.broadcast(bus, topic: "room:a", message: Increment, serialiser: ser())
  drain()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_pub_sub_unsubscribe_unknown_topic_no_crash_test() {
  let bus = new_pub_sub()
  let _drain = register_client(bus, "c1")
  pub_sub.unsubscribe(bus, client_id: "c1", topic: "nowhere")
  True
  |> should.be_true
}

// =============================================================================
// MULTIPLE TOPICS
// =============================================================================

@target(javascript)
pub fn js_pub_sub_client_receives_from_multiple_subscribed_topics_test() {
  let bus = new_pub_sub()
  let drain = register_client(bus, "c1")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:a")
  pub_sub.subscribe(bus, client_id: "c1", topic: "room:b")
  pub_sub.broadcast(bus, topic: "room:a", message: Increment, serialiser: ser())
  pub_sub.broadcast(bus, topic: "room:b", message: Reset, serialiser: ser())
  drain()
  |> list.length
  |> should.equal(2)
}

// =============================================================================
// PUSH PROTOCOL (wire-format invariants)
// =============================================================================

@target(javascript)
pub fn js_pub_sub_push_roundtrip_json_test() {
  let bytes =
    transport.encode(transport.Push(payload: SetName("bob")), serialiser: ser())
  transport.decode(bytes, serialiser: ser())
  |> should.equal(Ok(transport.Push(payload: SetName("bob"))))
}

@target(javascript)
pub fn js_pub_sub_push_wire_has_no_sequence_field_test() {
  // Critical invariant: Push frames carry no sequence number, so clients
  // cannot accidentally advance their resync cursor on receipt.
  let bytes =
    transport.encode(transport.Push(payload: Increment), serialiser: ser())
  let assert Ok(text) = bit_array.to_string(bytes)
  string.contains(text, "sequence")
  |> should.be_false
}
