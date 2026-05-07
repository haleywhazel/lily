// Tests for the JavaScript auto-serialiser (transport.ffi.mjs).
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/test_fixtures.{
  type Message, type Model, Decrement, Increment, Noop, Reset, SetName,
}
@target(javascript)
import lily/transport.{
  Acknowledge, Resync, Session, SessionMessage, Snapshot, TopicUpdate,
}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn ser() {
  transport.automatic()
}

@target(javascript)
fn roundtrip_message(
  message: Message,
) -> Result(transport.Protocol(Model, Message), Nil) {
  let encoded =
    transport.encode(SessionMessage(payload: message), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
}

@target(javascript)
fn roundtrip_snapshot(
  model: Model,
  seq: Int,
) -> Result(transport.Protocol(Model, Message), Nil) {
  let encoded =
    transport.encode(
      Snapshot(target: Session, sequence: seq, state: model),
      serialiser: ser(),
    )
  transport.decode(encoded, serialiser: ser())
}

// =============================================================================
// ROUNDTRIPS, ZERO-FIELD CONSTRUCTORS
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_zero_field_test() {
  roundtrip_message(Increment)
  |> should.equal(Ok(SessionMessage(payload: Increment)))
}

@target(javascript)
pub fn auto_js_roundtrip_decrement_test() {
  roundtrip_message(Decrement)
  |> should.equal(Ok(SessionMessage(payload: Decrement)))
}

@target(javascript)
pub fn auto_js_roundtrip_reset_test() {
  roundtrip_message(Reset)
  |> should.equal(Ok(SessionMessage(payload: Reset)))
}

@target(javascript)
pub fn auto_js_roundtrip_noop_test() {
  roundtrip_message(Noop)
  |> should.equal(Ok(SessionMessage(payload: Noop)))
}

// =============================================================================
// ROUNDTRIPS, SINGLE-FIELD CONSTRUCTOR
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_single_field_test() {
  roundtrip_message(SetName("Alice"))
  |> should.equal(Ok(SessionMessage(payload: SetName("Alice"))))
}

@target(javascript)
pub fn auto_js_roundtrip_empty_string_test() {
  roundtrip_message(SetName(""))
  |> should.equal(Ok(SessionMessage(payload: SetName(""))))
}

// =============================================================================
// ROUNDTRIPS, MULTI-FIELD CONSTRUCTOR (Model in Snapshot)
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_multi_field_test() {
  let model = test_fixtures.Model(count: 5, name: "Bob", connected: False)
  roundtrip_snapshot(model, 1)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 1, state: model)))
}

@target(javascript)
pub fn auto_js_roundtrip_boolean_test() {
  let model = test_fixtures.Model(count: 0, name: "", connected: True)
  roundtrip_snapshot(model, 0)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: model)))
}

// =============================================================================
// ROUNDTRIPS, PROTOCOL VARIANTS
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_topic_update_test() {
  let encoded =
    transport.encode(
      TopicUpdate(topic_id: "chat", sequence: 7, payload: Increment),
      serialiser: ser(),
    )
  transport.decode(encoded, serialiser: ser())
  |> should.equal(
    Ok(TopicUpdate(topic_id: "chat", sequence: 7, payload: Increment)),
  )
}

@target(javascript)
pub fn auto_js_roundtrip_resync_test() {
  let encoded = transport.encode(Resync(cursors: [Session]), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(Resync(cursors: [Session])))
}

@target(javascript)
pub fn auto_js_roundtrip_acknowledge_test() {
  let encoded =
    transport.encode(
      Acknowledge(target: Session, sequence: 2),
      serialiser: ser(),
    )
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 2)))
}

// =============================================================================
// REGISTRY, MODULE REGISTRATION ENABLES DECODE
// =============================================================================

@target(javascript)
@external(javascript, "./transport_auto_js_test.ffi.mjs", "registerTestFixtures")
fn register_test_fixtures() -> Nil {
  Nil
}

@target(javascript)
pub fn auto_js_register_enables_decode_test() {
  register_test_fixtures()
  let encoded =
    transport.encode(
      TopicUpdate(topic_id: "t", sequence: 1, payload: SetName("Registered")),
      serialiser: ser(),
    )
  transport.decode(encoded, serialiser: ser())
  |> should.equal(
    Ok(TopicUpdate(topic_id: "t", sequence: 1, payload: SetName("Registered"))),
  )
}

// =============================================================================
// ROUNDTRIPS, JSON PATH (use_json toggle)
// =============================================================================

@target(javascript)
pub fn auto_js_json_roundtrip_test() {
  register_test_fixtures()
  let json_ser = transport.automatic() |> transport.use_json()
  let json_bytes =
    bit_array.from_string(
      "{\"type\":\"session_message\",\"payload\":{\"_\":\"SetName\",\"0\":\"JsonPath\"}}",
    )
  transport.decode(json_bytes, serialiser: json_ser)
  |> should.equal(Ok(SessionMessage(payload: SetName("JsonPath"))))
}

// =============================================================================
// ROUNDTRIPS, NESTED TYPES
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_nested_test() {
  let inner = test_fixtures.Model(count: 3, name: "Eve", connected: False)
  let nested = test_fixtures.Nested(inner:)
  let nested_ser: transport.Serialiser(test_fixtures.Nested, Message) =
    transport.automatic()
  let encoded =
    transport.encode(
      Snapshot(target: Session, sequence: 1, state: nested),
      serialiser: nested_ser,
    )
  transport.decode(encoded, serialiser: nested_ser)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 1, state: nested)))
}

@target(javascript)
pub fn auto_js_roundtrip_list_field_test() {
  let with_list = test_fixtures.WithList(items: [1, 2, 3])
  let list_ser: transport.Serialiser(test_fixtures.WithList, Message) =
    transport.automatic()
  let encoded =
    transport.encode(
      Snapshot(target: Session, sequence: 0, state: with_list),
      serialiser: list_ser,
    )
  transport.decode(encoded, serialiser: list_ser)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: with_list)))
}

// =============================================================================
// FORMAT ISOLATION
// =============================================================================

@target(javascript)
pub fn auto_js_message_pack_bytes_fail_under_json_test() {
  let mp_bytes =
    transport.encode(
      Acknowledge(target: Session, sequence: 1),
      serialiser: transport.automatic() |> transport.use_message_pack(),
    )
  let json_ser = transport.automatic()
  transport.decode(mp_bytes, serialiser: json_ser)
  |> should.be_error
}

// =============================================================================
// TOGGLE BEHAVIOUR
// =============================================================================

@target(javascript)
pub fn auto_js_use_json_roundtrip_test() {
  let json_ser = transport.automatic() |> transport.use_json()
  let encoded =
    transport.encode(
      Acknowledge(target: Session, sequence: 9),
      serialiser: json_ser,
    )
  transport.decode(encoded, serialiser: json_ser)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 9)))
}

@target(javascript)
pub fn auto_js_use_message_pack_after_json_roundtrip_test() {
  let mp_ser =
    transport.automatic()
    |> transport.use_json()
    |> transport.use_message_pack()
  let encoded =
    transport.encode(
      Acknowledge(target: Session, sequence: 5),
      serialiser: mp_ser,
    )
  transport.decode(encoded, serialiser: mp_ser)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 5)))
}

// =============================================================================
// ERROR PATHS
// =============================================================================

@target(javascript)
pub fn auto_js_empty_bytes_returns_error_test() {
  transport.decode(<<>>, serialiser: ser())
  |> should.be_error
}

@target(javascript)
pub fn auto_js_invalid_bytes_returns_error_test() {
  transport.decode(<<0xFF, 0xFE, 0x00>>, serialiser: ser())
  |> should.be_error
}
