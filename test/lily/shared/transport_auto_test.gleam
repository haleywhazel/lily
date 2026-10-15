// automatic serialiser, pure gleam on erlang, reflection FFI on javascript
// js constructor registry and erlang module list live in the target folders

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list
import gleeunit/should
import lily/test_support.{
  type Message, type Model, Decrement, Increment, Noop, Reset, SetName,
}
import lily/transport.{
  Acknowledge, Resync, Session, SessionMessage, Snapshot, TopicUpdate,
}

// =============================================================================
// HELPERS
// =============================================================================

fn json() -> transport.Serialiser(model, message) {
  transport.automatic(
    format: transport.Json,
    max_decode_depth: 128,
    modules: [],
  )
}

/// Roundtrip `frame`, registering the fixture types for the JS decoder.
fn roundtrip(
  frame: transport.Protocol(model, message),
  serialiser: transport.Serialiser(model, message),
) -> Result(transport.Protocol(model, message), Nil) {
  test_support.register_fixtures()
  transport.encode(frame, serialiser:)
  |> transport.decode(serialiser:)
}

fn assert_roundtrips(frame: transport.Protocol(Model, Message)) -> Nil {
  roundtrip(frame, json())
  |> should.equal(Ok(frame))
}

// =============================================================================
// ROUNDTRIPS, ZERO-FIELD CONSTRUCTORS
// =============================================================================

pub fn auto_roundtrip_zero_field_test() {
  assert_roundtrips(SessionMessage(payload: Increment))
}

pub fn auto_roundtrip_decrement_test() {
  assert_roundtrips(SessionMessage(payload: Decrement))
}

pub fn auto_roundtrip_reset_test() {
  assert_roundtrips(SessionMessage(payload: Reset))
}

pub fn auto_roundtrip_noop_test() {
  assert_roundtrips(SessionMessage(payload: Noop))
}

// =============================================================================
// ROUNDTRIPS, SINGLE-FIELD CONSTRUCTOR
// =============================================================================

pub fn auto_roundtrip_single_field_test() {
  assert_roundtrips(SessionMessage(payload: SetName("Alice")))
}

pub fn auto_roundtrip_empty_string_test() {
  assert_roundtrips(SessionMessage(payload: SetName("")))
}

// =============================================================================
// ROUNDTRIPS, MULTI-FIELD CONSTRUCTOR
// =============================================================================

pub fn auto_roundtrip_multi_field_test() {
  let model =
    test_support.Model(..test_support.initial_model(), count: 5, name: "Bob")

  assert_roundtrips(Snapshot(target: Session, sequence: 1, state: model))
}

pub fn auto_roundtrip_boolean_field_test() {
  let model =
    test_support.Model(..test_support.initial_model(), connected: True)

  assert_roundtrips(Snapshot(target: Session, sequence: 0, state: model))
}

// =============================================================================
// ROUNDTRIPS, PROTOCOL VARIANTS
// =============================================================================

pub fn auto_roundtrip_topic_update_test() {
  assert_roundtrips(TopicUpdate(
    topic_id: "chat",
    sequence: 7,
    payload: Increment,
  ))
}

pub fn auto_roundtrip_resync_test() {
  assert_roundtrips(Resync(cursors: [Session]))
}

pub fn auto_roundtrip_acknowledge_test() {
  assert_roundtrips(Acknowledge(target: Session, sequence: 2))
}

// =============================================================================
// ROUNDTRIPS, NESTED TYPES
// =============================================================================

pub fn auto_roundtrip_nested_test() {
  let inner =
    test_support.Model(..test_support.initial_model(), count: 3, name: "Eve")
  let frame: transport.Protocol(test_support.Nested, Message) =
    Snapshot(target: Session, sequence: 1, state: test_support.Nested(inner:))

  roundtrip(frame, json())
  |> should.equal(Ok(frame))
}

pub fn auto_roundtrip_list_field_test() {
  let frame: transport.Protocol(test_support.WithList, Message) =
    Snapshot(
      target: Session,
      sequence: 0,
      state: test_support.WithList(items: [1, 2, 3]),
    )

  roundtrip(frame, json())
  |> should.equal(Ok(frame))
}

// =============================================================================
// FORMAT SELECTION
// =============================================================================

pub fn auto_json_format_roundtrip_test() {
  let frame: transport.Protocol(Model, Message) =
    Acknowledge(target: Session, sequence: 9)

  roundtrip(frame, json())
  |> should.equal(Ok(frame))
}

pub fn auto_message_pack_format_roundtrip_test() {
  let frame: transport.Protocol(Model, Message) =
    Acknowledge(target: Session, sequence: 5)

  roundtrip(frame, test_support.message_pack_serialiser())
  |> should.equal(Ok(frame))
}

// =============================================================================
// FORMAT DETECTION
// =============================================================================

pub fn auto_message_pack_bytes_decode_under_json_test() {
  let frame: transport.Protocol(Model, Message) =
    Acknowledge(target: Session, sequence: 1)

  transport.encode(frame, serialiser: test_support.message_pack_serialiser())
  |> transport.decode(serialiser: json())
  |> should.equal(Ok(frame))
}

pub fn auto_json_bytes_decode_under_message_pack_test() {
  test_support.register_fixtures()
  let frame: transport.Protocol(Model, Message) =
    SessionMessage(payload: Increment)

  transport.encode(frame, serialiser: json())
  |> transport.decode(serialiser: test_support.message_pack_serialiser())
  |> should.equal(Ok(frame))
}

pub fn auto_json_after_leading_whitespace_decodes_test() {
  let frame: transport.Protocol(Model, Message) =
    Acknowledge(target: Session, sequence: 2)
  let bytes = transport.encode(frame, serialiser: json())

  transport.decode(<<" \n\t\r":utf8, bytes:bits>>, serialiser: json())
  |> should.equal(Ok(frame))
}

pub fn auto_whitespace_before_message_pack_is_an_error_test() {
  let frame: transport.Protocol(Model, Message) =
    Acknowledge(target: Session, sequence: 2)
  let bytes =
    transport.encode(frame, serialiser: test_support.message_pack_serialiser())

  transport.decode(<<" ":utf8, bytes:bits>>, serialiser: json())
  |> should.be_error
}

pub fn auto_garbage_first_byte_is_an_error_test() {
  let serialiser: transport.Serialiser(Model, Message) = json()

  list.each([<<"[1]":utf8>>, <<0x90>>, <<0x2A, 0x7B>>, <<0xC0>>], fn(bytes) {
    transport.decode(bytes, serialiser:)
    |> should.be_error
  })
}

pub fn auto_frame_format_reads_every_map_marker_test() {
  let serialiser: transport.Serialiser(Model, Message) = json()

  list.map(
    [<<0x80>>, <<0x8F>>, <<0xDE, 0, 0>>, <<0xDF, 0, 0, 0, 0>>],
    fn(bytes) { transport.frame_format(bytes, serialiser:) },
  )
  |> should.equal([
    Ok(transport.MessagePack),
    Ok(transport.MessagePack),
    Ok(transport.MessagePack),
    Ok(transport.MessagePack),
  ])
  transport.frame_format(<<"  {":utf8>>, serialiser:)
  |> should.equal(Ok(transport.Json))
}

pub fn auto_frame_format_is_an_error_for_an_open_serialiser_test() {
  transport.frame_format(
    <<"{}":utf8>>,
    serialiser: test_support.custom_serialiser(),
  )
  |> should.equal(Error(Nil))
}

// =============================================================================
// BY HOST
// =============================================================================

pub fn auto_by_host_is_json_on_a_local_host_test() {
  list.map(["localhost", "127.0.0.1"], transport.format_for_host(
    transport.ByHost,
    _,
  ))
  |> should.equal([transport.Json, transport.Json])
}

pub fn auto_by_host_is_message_pack_on_any_other_host_test() {
  list.map(
    ["example.com", "localhost.example.com", "10.0.0.1", ""],
    transport.format_for_host(transport.ByHost, _),
  )
  |> should.equal([
    transport.MessagePack,
    transport.MessagePack,
    transport.MessagePack,
    transport.MessagePack,
  ])
}

pub fn auto_explicit_format_ignores_the_host_test() {
  transport.format_for_host(transport.Json, "example.com")
  |> should.equal(transport.Json)
  transport.format_for_host(transport.MessagePack, "localhost")
  |> should.equal(transport.MessagePack)
}

pub fn auto_by_host_is_message_pack_on_the_server_test() {
  transport.server_format(test_support.automatic_serialiser(transport.ByHost))
  |> should.equal(transport.MessagePack)
  transport.server_format(test_support.automatic_serialiser(transport.Json))
  |> should.equal(transport.Json)
}

// =============================================================================
// ERROR PATHS
// =============================================================================

pub fn auto_empty_bytes_returns_error_test() {
  let serialiser: transport.Serialiser(Model, Message) = json()

  transport.decode(<<>>, serialiser:)
  |> should.be_error
}

pub fn auto_invalid_bytes_returns_error_test() {
  let serialiser: transport.Serialiser(Model, Message) = json()

  transport.decode(<<0xFF, 0xFE, 0x00>>, serialiser:)
  |> should.be_error
}
