// Tests for the Erlang auto-serialiser (lily_transport_ffi.erl).
// All functions are @target(erlang) — skipped on JavaScript.

@target(erlang)
import gleeunit/should
@target(erlang)
import lily/test_fixtures.{Decrement, Increment, Noop, Reset, SetName}
@target(erlang)
import lily/transport.{
  Acknowledge, ClientMessage, Resync, ServerMessage, Snapshot,
}

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn ser() {
  transport.automatic()
}

@target(erlang)
fn roundtrip_msg(
  msg: test_fixtures.Message,
) -> Result(transport.Protocol(test_fixtures.Model, test_fixtures.Message), Nil) {
  let encoded = transport.encode(ClientMessage(payload: msg), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
}

@target(erlang)
fn roundtrip_snapshot(
  model: test_fixtures.Model,
  seq: Int,
) -> Result(transport.Protocol(test_fixtures.Model, test_fixtures.Message), Nil) {
  let encoded =
    transport.encode(Snapshot(sequence: seq, state: model), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
}

// =============================================================================
// ROUNDTRIPS — ZERO-FIELD CONSTRUCTORS
// =============================================================================

@target(erlang)
pub fn auto_erl_roundtrip_zero_field_test() {
  roundtrip_msg(Increment)
  |> should.equal(Ok(ClientMessage(payload: Increment)))
}

@target(erlang)
pub fn auto_erl_roundtrip_decrement_test() {
  roundtrip_msg(Decrement)
  |> should.equal(Ok(ClientMessage(payload: Decrement)))
}

@target(erlang)
pub fn auto_erl_roundtrip_reset_test() {
  roundtrip_msg(Reset)
  |> should.equal(Ok(ClientMessage(payload: Reset)))
}

@target(erlang)
pub fn auto_erl_roundtrip_noop_test() {
  roundtrip_msg(Noop)
  |> should.equal(Ok(ClientMessage(payload: Noop)))
}

// =============================================================================
// ROUNDTRIPS — SINGLE-FIELD CONSTRUCTOR
// =============================================================================

@target(erlang)
pub fn auto_erl_roundtrip_single_field_test() {
  roundtrip_msg(SetName("Alice"))
  |> should.equal(Ok(ClientMessage(payload: SetName("Alice"))))
}

@target(erlang)
pub fn auto_erl_roundtrip_empty_string_test() {
  roundtrip_msg(SetName(""))
  |> should.equal(Ok(ClientMessage(payload: SetName(""))))
}

// =============================================================================
// ROUNDTRIPS — MULTI-FIELD CONSTRUCTOR (Model in Snapshot)
// =============================================================================

@target(erlang)
pub fn auto_erl_roundtrip_multi_field_test() {
  let model = test_fixtures.Model(count: 5, name: "Bob", connected: False)
  roundtrip_snapshot(model, 1)
  |> should.equal(Ok(Snapshot(sequence: 1, state: model)))
}

@target(erlang)
pub fn auto_erl_roundtrip_boolean_field_test() {
  let model = test_fixtures.Model(count: 0, name: "", connected: True)
  roundtrip_snapshot(model, 0)
  |> should.equal(Ok(Snapshot(sequence: 0, state: model)))
}

// =============================================================================
// ROUNDTRIPS — PROTOCOL VARIANTS
// =============================================================================

@target(erlang)
pub fn auto_erl_roundtrip_server_message_test() {
  let encoded =
    transport.encode(
      ServerMessage(sequence: 7, payload: Increment),
      serialiser: ser(),
    )
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(ServerMessage(sequence: 7, payload: Increment)))
}

@target(erlang)
pub fn auto_erl_roundtrip_resync_test() {
  let encoded = transport.encode(Resync(after_sequence: 3), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(Resync(after_sequence: 3)))
}

@target(erlang)
pub fn auto_erl_roundtrip_acknowledge_test() {
  let encoded = transport.encode(Acknowledge(sequence: 2), serialiser: ser())
  transport.decode(encoded, serialiser: ser())
  |> should.equal(Ok(Acknowledge(sequence: 2)))
}

// =============================================================================
// ROUNDTRIPS — NESTED TYPES
// =============================================================================

@target(erlang)
pub fn auto_erl_roundtrip_nested_test() {
  let inner = test_fixtures.Model(count: 3, name: "Eve", connected: False)
  let nested = test_fixtures.Nested(inner:)
  // Encode Nested directly as a client message payload.
  // We use a custom wrapper approach: encode the outer Snapshot with the nested
  // model as the "state". We need a Serialiser(Nested, Message) which we build inline.
  let nested_ser =
    transport.custom(
      encode_message: fn(msg) { transport.automatic().encode_message(msg) },
      decode_message: transport.automatic().decode_message,
      encode_model: fn(model) { transport.automatic().encode_model(model) },
      decode_model: transport.automatic().decode_model,
    )
  let encoded =
    transport.encode(
      Snapshot(sequence: 1, state: nested),
      serialiser: nested_ser,
    )
  let result = transport.decode(encoded, serialiser: nested_ser)
  result
  |> should.equal(Ok(Snapshot(sequence: 1, state: nested)))
}

@target(erlang)
pub fn auto_erl_roundtrip_list_field_test() {
  let with_list = test_fixtures.WithList(items: [1, 2, 3])
  let list_ser =
    transport.custom(
      encode_message: fn(msg) { transport.automatic().encode_message(msg) },
      decode_message: transport.automatic().decode_message,
      encode_model: fn(model) { transport.automatic().encode_model(model) },
      decode_model: transport.automatic().decode_model,
    )
  let encoded =
    transport.encode(
      Snapshot(sequence: 0, state: with_list),
      serialiser: list_ser,
    )
  transport.decode(encoded, serialiser: list_ser)
  |> should.equal(Ok(Snapshot(sequence: 0, state: with_list)))
}
