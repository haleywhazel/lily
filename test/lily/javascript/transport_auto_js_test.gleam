// Tests for the JavaScript auto-serialiser (transport.ffi.mjs).
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/test_fixtures.{
  type Model, type Message, Decrement, Increment, Noop, Reset, SetName,
}
@target(javascript)
import lily/transport.{
  Acknowledge, ClientMessage, Resync, ServerMessage, Snapshot,
}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn ser() {
  transport.automatic()
}

@target(javascript)
fn roundtrip_msg(msg: Message) -> Result(transport.Protocol(Model, Message), Nil) {
  let encoded = transport.encode(ClientMessage(payload: msg), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
}

@target(javascript)
fn roundtrip_snapshot(model: Model, seq: Int) -> Result(transport.Protocol(Model, Message), Nil) {
  let encoded = transport.encode(Snapshot(sequence: seq, state: model), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
}

// =============================================================================
// ROUNDTRIPS — ZERO-FIELD CONSTRUCTORS
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_zero_field_test() {
  roundtrip_msg(Increment)
  |> should.equal(Ok(ClientMessage(payload: Increment)))
}

@target(javascript)
pub fn auto_js_roundtrip_decrement_test() {
  roundtrip_msg(Decrement)
  |> should.equal(Ok(ClientMessage(payload: Decrement)))
}

@target(javascript)
pub fn auto_js_roundtrip_reset_test() {
  roundtrip_msg(Reset)
  |> should.equal(Ok(ClientMessage(payload: Reset)))
}

@target(javascript)
pub fn auto_js_roundtrip_noop_test() {
  roundtrip_msg(Noop)
  |> should.equal(Ok(ClientMessage(payload: Noop)))
}

// =============================================================================
// ROUNDTRIPS — SINGLE-FIELD CONSTRUCTOR
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_single_field_test() {
  roundtrip_msg(SetName("Alice"))
  |> should.equal(Ok(ClientMessage(payload: SetName("Alice"))))
}

@target(javascript)
pub fn auto_js_roundtrip_empty_string_test() {
  roundtrip_msg(SetName(""))
  |> should.equal(Ok(ClientMessage(payload: SetName(""))))
}

// =============================================================================
// ROUNDTRIPS — MULTI-FIELD CONSTRUCTOR (Model in Snapshot)
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_multi_field_test() {
  let model = test_fixtures.Model(count: 5, name: "Bob", connected: False)
  roundtrip_snapshot(model, 1)
  |> should.equal(Ok(Snapshot(sequence: 1, state: model)))
}

@target(javascript)
pub fn auto_js_roundtrip_boolean_test() {
  let model = test_fixtures.Model(count: 0, name: "", connected: True)
  roundtrip_snapshot(model, 0)
  |> should.equal(Ok(Snapshot(sequence: 0, state: model)))
}

// =============================================================================
// ROUNDTRIPS — PROTOCOL VARIANTS
// =============================================================================

@target(javascript)
pub fn auto_js_roundtrip_server_message_test() {
  let encoded =
    transport.encode(
      ServerMessage(sequence: 7, payload: Increment),
      serialiser: ser(),
    )
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(ServerMessage(sequence: 7, payload: Increment)))
}

@target(javascript)
pub fn auto_js_roundtrip_resync_test() {
  let encoded = transport.encode(Resync(after_sequence: 3), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(Resync(after_sequence: 3)))
}

@target(javascript)
pub fn auto_js_roundtrip_acknowledge_test() {
  let encoded = transport.encode(Acknowledge(sequence: 2), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(Acknowledge(sequence: 2)))
}

// =============================================================================
// REGISTRY — REGISTER ENABLES DECODE
// =============================================================================

@target(javascript)
pub fn auto_js_register_enables_decode_test() {
  // Register constructors that would normally only come from the server.
  // After registering, decode should succeed even without a prior encode.
  transport.register([Noop, Reset, SetName("")])
  // Decode a server-sent SetName without having encoded it first in this test.
  let json =
    "{\"type\":\"client_message\",\"payload\":{\"_\":\"SetName\",\"0\":\"Registered\"}}"
  transport.decode(json, serialiser: ser())
  |> should.equal(Ok(ClientMessage(payload: SetName("Registered"))))
}

@target(javascript)
pub fn auto_js_roundtrip_nested_test() {
  let inner = test_fixtures.Model(count: 3, name: "Eve", connected: False)
  let nested = test_fixtures.Nested(inner:)
  // Encode Nested via a Snapshot so the constructor gets cached in the registry.
  let nested_ser =
    transport.custom(
      encode_message: fn(msg) { transport.automatic().encode_message(msg) },
      decode_message: transport.automatic().decode_message,
      encode_model: fn(model) { transport.automatic().encode_model(model) },
      decode_model: transport.automatic().decode_model,
    )
  let encoded =
    transport.encode(Snapshot(sequence: 1, state: nested), serialiser: nested_ser)
  transport.decode(encoded, serialiser: nested_ser)
  |> should.equal(Ok(Snapshot(sequence: 1, state: nested)))
}

@target(javascript)
pub fn auto_js_roundtrip_list_field_test() {
  let with_list = test_fixtures.WithList(items: [1, 2, 3])
  let list_ser =
    transport.custom(
      encode_message: fn(msg) { transport.automatic().encode_message(msg) },
      decode_message: transport.automatic().decode_message,
      encode_model: fn(model) { transport.automatic().encode_model(model) },
      decode_model: transport.automatic().decode_model,
    )
  let encoded =
    transport.encode(Snapshot(sequence: 0, state: with_list), serialiser: list_ser)
  transport.decode(encoded, serialiser: list_ser)
  |> should.equal(Ok(Snapshot(sequence: 0, state: with_list)))
}
