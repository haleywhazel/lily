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
  let nested_ser: transport.Serialiser(
    test_fixtures.Nested,
    test_fixtures.Message,
  ) = transport.automatic()
  let encoded =
    transport.encode(
      Snapshot(sequence: 1, state: nested),
      serialiser: nested_ser,
    )
  transport.decode(encoded, serialiser: nested_ser)
  |> should.equal(Ok(Snapshot(sequence: 1, state: nested)))
}

@target(erlang)
pub fn auto_erl_roundtrip_list_field_test() {
  let with_list = test_fixtures.WithList(items: [1, 2, 3])
  let list_ser: transport.Serialiser(
    test_fixtures.WithList,
    test_fixtures.Message,
  ) = transport.automatic()
  let encoded =
    transport.encode(
      Snapshot(sequence: 0, state: with_list),
      serialiser: list_ser,
    )
  transport.decode(encoded, serialiser: list_ser)
  |> should.equal(Ok(Snapshot(sequence: 0, state: with_list)))
}

// =============================================================================
// FORMAT ISOLATION
// =============================================================================

@target(erlang)
pub fn auto_erl_message_pack_bytes_fail_under_json_test() {
  // MessagePack bytes should not decode as JSON
  let mp_bytes =
    transport.encode(
      Acknowledge(sequence: 1),
      serialiser: transport.automatic() |> transport.use_message_pack(),
    )
  let json_ser = transport.automatic()
  transport.decode(mp_bytes, serialiser: json_ser)
  |> should.be_error
}

// =============================================================================
// TOGGLE BEHAVIOUR
// =============================================================================

@target(erlang)
pub fn auto_erl_use_json_roundtrip_test() {
  let json_ser = transport.automatic() |> transport.use_json()
  let encoded = transport.encode(Acknowledge(sequence: 9), serialiser: json_ser)
  transport.decode(encoded, serialiser: json_ser)
  |> should.equal(Ok(Acknowledge(sequence: 9)))
}

@target(erlang)
pub fn auto_erl_use_message_pack_after_json_roundtrip_test() {
  let mp_ser =
    transport.automatic()
    |> transport.use_json()
    |> transport.use_message_pack()
  let encoded = transport.encode(Acknowledge(sequence: 5), serialiser: mp_ser)
  transport.decode(encoded, serialiser: mp_ser)
  |> should.equal(Ok(Acknowledge(sequence: 5)))
}

// =============================================================================
// ERROR PATHS
// =============================================================================

@target(erlang)
pub fn auto_erl_empty_bytes_returns_error_test() {
  transport.decode(<<>>, serialiser: ser())
  |> should.be_error
}

@target(erlang)
pub fn auto_erl_invalid_bytes_returns_error_test() {
  transport.decode(<<0xFF, 0xFE, 0x00>>, serialiser: ser())
  |> should.be_error
}
