// lily/transport encode/decode with the custom serialiser
// pure gleam, no FFI, both targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/string
import gleeunit/should
import lily/store
import lily/test_support.{
  type Message, type Model, Decrement, Increment, SetName,
}
import lily/transport.{
  Acknowledge, Connected, Resync, Session, SessionMessage, Snapshot, TopicUpdate,
  Version,
}

// =============================================================================
// HELPERS
// =============================================================================

fn message_pack_capped(depth: Int) -> transport.Serialiser(Model, Message) {
  transport.automatic(
    format: transport.MessagePack,
    max_decode_depth: depth,
    modules: [],
  )
}

// =============================================================================
// ENCODE
// =============================================================================

pub fn encode_connected_test() {
  transport.encode(
    Connected(client_id: "abc123"),
    serialiser: test_support.custom_serialiser(),
  )
  |> should.equal(bit_array.from_string(
    "{\"type\":\"connected\",\"client_id\":\"abc123\"}",
  ))
}

pub fn encode_version_test() {
  transport.encode(
    Version(hash: "abc123"),
    serialiser: test_support.custom_serialiser(),
  )
  |> should.equal(bit_array.from_string(
    "{\"type\":\"version\",\"hash\":\"abc123\"}",
  ))
}

pub fn encode_acknowledge_test() {
  let result =
    transport.encode(
      Acknowledge(target: Session, sequence: 1),
      serialiser: test_support.custom_serialiser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"acknowledge\",\"target\":{\"kind\":\"session\"},\"sequence\":1}",
  ))
}

pub fn encode_session_message_test() {
  let result =
    transport.encode(
      SessionMessage(payload: Increment),
      serialiser: test_support.custom_serialiser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"session_message\",\"payload\":{\"tag\":\"Increment\"}}",
  ))
}

pub fn encode_resync_test() {
  let result =
    transport.encode(
      Resync(cursors: [Session]),
      serialiser: test_support.custom_serialiser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\"}]}",
  ))
}

pub fn encode_topic_update_test() {
  let result =
    transport.encode(
      TopicUpdate(topic_id: "test", sequence: 3, payload: Decrement),
      serialiser: test_support.custom_serialiser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"topic_update\",\"topic_id\":\"test\",\"sequence\":3,\"payload\":{\"tag\":\"Decrement\"}}",
  ))
}

pub fn encode_snapshot_test() {
  let model =
    test_support.Model(
      ..test_support.initial_model(),
      count: 5,
      name: "Bob",
      connected: True,
    )
  let result =
    transport.encode(
      Snapshot(target: Session, sequence: 2, state: model),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"snapshot\",\"target\":{\"kind\":\"session\"},\"sequence\":2,\"state\":{\"count\":5,\"name\":\"Bob\",\"connected\":true,\"active_tab\":\"TabA\",\"secondary_count\":0,\"transition_item\":null}}",
  ))
}

// =============================================================================
// DECODE ROUNDTRIP
// =============================================================================

pub fn decode_connected_test() {
  test_support.register_fixtures()
  transport.decode(
    bit_array.from_string("{\"type\":\"connected\",\"client_id\":\"abc123\"}"),
    serialiser: test_support.custom_serialiser(),
  )
  |> should.equal(Ok(Connected(client_id: "abc123")))
}

pub fn decode_version_test() {
  test_support.register_fixtures()
  transport.decode(
    bit_array.from_string("{\"type\":\"version\",\"hash\":\"abc123\"}"),
    serialiser: test_support.custom_serialiser(),
  )
  |> should.equal(Ok(Version(hash: "abc123")))
}

pub fn decode_acknowledge_test() {
  test_support.register_fixtures()
  let bytes =
    bit_array.from_string(
      "{\"type\":\"acknowledge\",\"target\":{\"kind\":\"session\"},\"sequence\":1}",
    )
  let result =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 1)))
}

pub fn decode_session_message_test() {
  test_support.register_fixtures()
  let bytes =
    bit_array.from_string(
      "{\"type\":\"session_message\",\"payload\":{\"tag\":\"Increment\"}}",
    )
  let result =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(Ok(SessionMessage(payload: Increment)))
}

pub fn decode_session_message_with_fields_test() {
  test_support.register_fixtures()
  let bytes =
    bit_array.from_string(
      "{\"type\":\"session_message\",\"payload\":{\"tag\":\"SetName\",\"name\":\"Alice\"}}",
    )
  let result =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(Ok(SessionMessage(payload: SetName("Alice"))))
}

pub fn decode_resync_test() {
  test_support.register_fixtures()
  let bytes =
    bit_array.from_string(
      "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\"}]}",
    )
  let result =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(Ok(Resync(cursors: [Session])))
}

pub fn decode_topic_update_test() {
  test_support.register_fixtures()
  let bytes =
    bit_array.from_string(
      "{\"type\":\"topic_update\",\"topic_id\":\"test\",\"sequence\":3,\"payload\":{\"tag\":\"Decrement\"}}",
    )
  let result =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(
    Ok(TopicUpdate(topic_id: "test", sequence: 3, payload: Decrement)),
  )
}

pub fn decode_snapshot_test() {
  test_support.register_fixtures()
  let bytes =
    bit_array.from_string(
      "{\"type\":\"snapshot\",\"target\":{\"kind\":\"session\"},\"sequence\":2,\"state\":{\"count\":0,\"name\":\"\",\"connected\":false,\"active_tab\":\"TabA\",\"secondary_count\":0,\"transition_item\":null}}",
    )
  let result =
    transport.decode(bytes, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(
    Ok(Snapshot(
      target: Session,
      sequence: 2,
      state: test_support.initial_model(),
    )),
  )
}

pub fn decode_snapshot_with_complex_model_test() {
  test_support.register_fixtures()
  let model =
    test_support.Model(
      ..test_support.initial_model(),
      count: 42,
      name: "Eve",
      connected: True,
    )
  let encoded =
    transport.encode(
      Snapshot(target: Session, sequence: 10, state: model),
      serialiser: test_support.custom_serialiser(),
    )
  let result =
    transport.decode(encoded, serialiser: test_support.custom_serialiser())

  result
  |> should.equal(Ok(Snapshot(target: Session, sequence: 10, state: model)))
}

// =============================================================================
// DECODE ERROR PATHS
// =============================================================================

pub fn decode_empty_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(<<>>, serialiser: test_support.custom_serialiser())

  result
  |> should.be_error
}

pub fn decode_invalid_bytes_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(
      bit_array.from_string("not json"),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.be_error
}

pub fn decode_malformed_payload_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(
      bit_array.from_string(
        "{\"type\":\"session_message\",\"payload\":\"not_an_object\"}",
      ),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.be_error
}

pub fn decode_missing_payload_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(
      bit_array.from_string("{\"type\":\"session_message\"}"),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.be_error
}

pub fn decode_missing_sequence_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(
      bit_array.from_string(
        "{\"type\":\"topic_update\",\"topic_id\":\"t\",\"payload\":{\"tag\":\"Increment\"}}",
      ),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.be_error
}

pub fn decode_missing_type_field_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(
      bit_array.from_string("{\"sequence\":1}"),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.be_error
}

pub fn decode_unknown_type_returns_error_test() {
  test_support.register_fixtures()
  let result =
    transport.decode(
      bit_array.from_string("{\"type\":\"unknown_type\"}"),
      serialiser: test_support.custom_serialiser(),
    )

  result
  |> should.be_error
}

// =============================================================================
// OPEN SERIALISER
// =============================================================================

pub fn open_serialiser_round_trips_through_its_own_codec_test() {
  test_support.register_fixtures()
  let inner = test_support.custom_serialiser()
  let open =
    transport.serialiser(
      encode: fn(protocol) { transport.encode(protocol, serialiser: inner) },
      decode: fn(bytes) { transport.decode(bytes, serialiser: inner) },
    )
  let frame = transport.SessionMessage(payload: test_support.Increment)

  transport.encode(frame, serialiser: open)
  |> transport.decode(serialiser: open)
  |> should.equal(Ok(frame))
}

pub fn open_serialiser_embeds_a_snapshot_test() {
  test_support.register_fixtures()
  let inner = test_support.custom_serialiser()
  let open =
    transport.serialiser(
      encode: fn(protocol) { transport.encode(protocol, serialiser: inner) },
      decode: fn(bytes) { transport.decode(bytes, serialiser: inner) },
    )

  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.sync_with(route: fn(_) { store.Session }, serialiser: open)
  |> store.initial_snapshot(model: test_support.initial_model())
  |> string.starts_with("<script")
  |> should.be_true
}

// =============================================================================
// CHANNEL
// =============================================================================

pub fn channel_close_calls_close_function_test() {
  let cell = test_support.new(False)
  let channel =
    transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() {
      test_support.set(cell, True)
    })
  channel.close()

  test_support.get(cell)
  |> should.be_true
}

pub fn channel_send_calls_send_function_test() {
  let cell = test_support.new(<<>>)
  let channel =
    transport.Channel(
      send: fn(bytes) {
        test_support.set(cell, bytes)
        Ok(Nil)
      },
      close: fn() { Nil },
    )

  channel.send(bit_array.from_string("hello")) |> should.equal(Ok(Nil))
  test_support.get(cell)
  |> should.equal(bit_array.from_string("hello"))
}

pub fn channel_send_reports_an_undelivered_frame_test() {
  let channel =
    transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
  channel.send(<<1>>) |> should.equal(Error(Nil))
}

// =============================================================================
// CONNECTOR
// =============================================================================

pub fn run_connector_passes_handler_through_test() {
  let received_cell = test_support.new(<<>>)
  let connector =
    transport.connector(fn(handler: transport.Handler) {
      // proves the handler was passed through
      handler.received(bit_array.from_string("relayed"))
      transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
    })
  let handler =
    transport.Handler(
      received: fn(bytes) { test_support.set(received_cell, bytes) },
      opened: fn() { Nil },
      closed: fn() { Nil },
    )
  let _channel = transport.run_connector(connector, handler)

  test_support.get(received_cell)
  |> should.equal(bit_array.from_string("relayed"))
}

pub fn run_connector_returns_built_transport_test() {
  let send_cell = test_support.new(<<>>)
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(
        send: fn(bytes) {
          test_support.set(send_cell, bytes)
          Ok(Nil)
        },
        close: fn() { Nil },
      )
    })
  let handler =
    transport.Handler(
      received: fn(_) { Nil },
      opened: fn() { Nil },
      closed: fn() { Nil },
    )
  let channel = transport.run_connector(connector, handler)
  let _ = channel.send(bit_array.from_string("payload"))

  test_support.get(send_cell)
  |> should.equal(bit_array.from_string("payload"))
}

// =============================================================================
// MAX DECODE DEPTH
// =============================================================================

pub fn max_decode_depth_session_message_within_cap_decodes_test() {
  test_support.register_fixtures()
  let bytes =
    transport.encode(
      SessionMessage(payload: Increment),
      serialiser: test_support.message_pack_serialiser(),
    )

  transport.decode(bytes, serialiser: test_support.message_pack_serialiser())
  |> should.equal(Ok(SessionMessage(payload: Increment)))
}

pub fn max_decode_depth_zero_rejects_session_message_test() {
  test_support.register_fixtures()
  let bytes =
    transport.encode(
      SessionMessage(payload: Increment),
      serialiser: test_support.message_pack_serialiser(),
    )
  let capped = message_pack_capped(0)

  transport.decode(bytes, serialiser: capped)
  |> should.be_error
}

pub fn max_decode_depth_one_allows_session_message_test() {
  test_support.register_fixtures()
  let bytes =
    transport.encode(
      SessionMessage(payload: Increment),
      serialiser: test_support.message_pack_serialiser(),
    )
  let capped = message_pack_capped(1)

  transport.decode(bytes, serialiser: capped)
  |> should.equal(Ok(SessionMessage(payload: Increment)))
}

pub fn max_decode_depth_one_rejects_deeper_snapshot_test() {
  test_support.register_fixtures()
  let model = test_support.initial_model()
  let bytes =
    transport.encode(
      Snapshot(target: Session, sequence: 1, state: model),
      serialiser: test_support.message_pack_serialiser(),
    )
  let capped = message_pack_capped(1)

  transport.decode(bytes, serialiser: capped)
  |> should.be_error
}

pub fn max_decode_depth_high_allows_snapshot_test() {
  test_support.register_fixtures()
  let model = test_support.initial_model()
  let bytes =
    transport.encode(
      Snapshot(target: Session, sequence: 1, state: model),
      serialiser: test_support.message_pack_serialiser(),
    )
  let uncapped = message_pack_capped(128)

  transport.decode(bytes, serialiser: uncapped)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 1, state: model)))
}
