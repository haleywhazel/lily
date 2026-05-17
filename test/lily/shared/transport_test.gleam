// Tests for lily/transport encode/decode with the custom serialiser.
// Pure Gleam, no FFI, runs on both Erlang and JavaScript targets.

import gleam/bit_array
import gleeunit/should
import lily/test_fixtures.{
  type Message, type Model, Decrement, Increment, SetName,
}
import lily/test_ref
import lily/transport.{
  Acknowledge, Connected, Resync, Session, SessionMessage, Snapshot, TopicUpdate,
}

// =============================================================================
// HELPERS
// =============================================================================

fn ser() {
  test_fixtures.custom_serialiser()
}

// =============================================================================
// ENCODE
// =============================================================================

pub fn encode_connected_test() {
  transport.encode(Connected(client_id: "abc123"), serialiser: ser())
  |> should.equal(bit_array.from_string(
    "{\"type\":\"connected\",\"client_id\":\"abc123\"}",
  ))
}

pub fn encode_acknowledge_test() {
  let result =
    transport.encode(
      Acknowledge(target: Session, sequence: 1),
      serialiser: ser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"acknowledge\",\"target\":{\"kind\":\"session\"},\"sequence\":1}",
  ))
}

pub fn encode_session_message_test() {
  let result =
    transport.encode(SessionMessage(payload: Increment), serialiser: ser())
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"session_message\",\"payload\":{\"tag\":\"Increment\"}}",
  ))
}

pub fn encode_resync_test() {
  let result = transport.encode(Resync(cursors: [Session]), serialiser: ser())
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\"}]}",
  ))
}

pub fn encode_topic_update_test() {
  let result =
    transport.encode(
      TopicUpdate(topic_id: "test", sequence: 3, payload: Decrement),
      serialiser: ser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"topic_update\",\"topic_id\":\"test\",\"sequence\":3,\"payload\":{\"tag\":\"Decrement\"}}",
  ))
}

pub fn encode_snapshot_test() {
  let model = test_fixtures.Model(..test_fixtures.initial_model(), count: 5, name: "Bob", connected: True)
  let result =
    transport.encode(
      Snapshot(target: Session, sequence: 2, state: model),
      serialiser: ser(),
    )
  result
  |> should.equal(bit_array.from_string(
    "{\"type\":\"snapshot\",\"target\":{\"kind\":\"session\"},\"sequence\":2,\"state\":{\"count\":5,\"name\":\"Bob\",\"connected\":true,\"active_tab\":\"TabA\",\"secondary_count\":0,\"transition_items\":[]}}",
  ))
}

// =============================================================================
// DECODE ROUNDTRIP
// =============================================================================

pub fn decode_connected_test() {
  transport.decode(
    bit_array.from_string("{\"type\":\"connected\",\"client_id\":\"abc123\"}"),
    serialiser: ser(),
  )
  |> should.equal(Ok(Connected(client_id: "abc123")))
}

pub fn decode_acknowledge_test() {
  let bytes =
    bit_array.from_string(
      "{\"type\":\"acknowledge\",\"target\":{\"kind\":\"session\"},\"sequence\":1}",
    )
  let result = transport.decode(bytes, serialiser: ser())
  result
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 1)))
}

pub fn decode_session_message_test() {
  let bytes =
    bit_array.from_string(
      "{\"type\":\"session_message\",\"payload\":{\"tag\":\"Increment\"}}",
    )
  let result = transport.decode(bytes, serialiser: ser())
  result
  |> should.equal(Ok(SessionMessage(payload: Increment)))
}

pub fn decode_session_message_with_fields_test() {
  let bytes =
    bit_array.from_string(
      "{\"type\":\"session_message\",\"payload\":{\"tag\":\"SetName\",\"name\":\"Alice\"}}",
    )
  let result = transport.decode(bytes, serialiser: ser())
  result
  |> should.equal(Ok(SessionMessage(payload: SetName("Alice"))))
}

pub fn decode_resync_test() {
  let bytes =
    bit_array.from_string(
      "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\"}]}",
    )
  let result = transport.decode(bytes, serialiser: ser())
  result
  |> should.equal(Ok(Resync(cursors: [Session])))
}

pub fn decode_topic_update_test() {
  let bytes =
    bit_array.from_string(
      "{\"type\":\"topic_update\",\"topic_id\":\"test\",\"sequence\":3,\"payload\":{\"tag\":\"Decrement\"}}",
    )
  let result = transport.decode(bytes, serialiser: ser())
  result
  |> should.equal(
    Ok(TopicUpdate(topic_id: "test", sequence: 3, payload: Decrement)),
  )
}

pub fn decode_snapshot_test() {
  let bytes =
    bit_array.from_string(
      "{\"type\":\"snapshot\",\"target\":{\"kind\":\"session\"},\"sequence\":2,\"state\":{\"count\":0,\"name\":\"\",\"connected\":false,\"active_tab\":\"TabA\",\"secondary_count\":0,\"transition_items\":[]}}",
    )
  let result = transport.decode(bytes, serialiser: ser())
  result
  |> should.equal(
    Ok(Snapshot(
      target: Session,
      sequence: 2,
      state: test_fixtures.initial_model(),
    )),
  )
}

pub fn decode_snapshot_with_complex_model_test() {
  let model = test_fixtures.Model(..test_fixtures.initial_model(), count: 42, name: "Eve", connected: True)
  let encoded =
    transport.encode(
      Snapshot(target: Session, sequence: 10, state: model),
      serialiser: ser(),
    )
  let result = transport.decode(encoded, serialiser: ser())
  result
  |> should.equal(Ok(Snapshot(target: Session, sequence: 10, state: model)))
}

// =============================================================================
// DECODE ERROR PATHS
// =============================================================================

pub fn decode_empty_returns_error_test() {
  let result = transport.decode(<<>>, serialiser: ser())
  result
  |> should.be_error
}

pub fn decode_invalid_bytes_returns_error_test() {
  let result =
    transport.decode(bit_array.from_string("not json"), serialiser: ser())
  result
  |> should.be_error
}

pub fn decode_malformed_payload_returns_error_test() {
  let result =
    transport.decode(
      bit_array.from_string(
        "{\"type\":\"session_message\",\"payload\":\"not_an_object\"}",
      ),
      serialiser: ser(),
    )
  result
  |> should.be_error
}

pub fn decode_missing_payload_returns_error_test() {
  let result =
    transport.decode(
      bit_array.from_string("{\"type\":\"session_message\"}"),
      serialiser: ser(),
    )
  result
  |> should.be_error
}

pub fn decode_missing_sequence_returns_error_test() {
  let result =
    transport.decode(
      bit_array.from_string(
        "{\"type\":\"topic_update\",\"topic_id\":\"t\",\"payload\":{\"tag\":\"Increment\"}}",
      ),
      serialiser: ser(),
    )
  result
  |> should.be_error
}

pub fn decode_missing_type_field_returns_error_test() {
  let result =
    transport.decode(
      bit_array.from_string("{\"sequence\":1}"),
      serialiser: ser(),
    )
  result
  |> should.be_error
}

pub fn decode_unknown_type_returns_error_test() {
  let result =
    transport.decode(
      bit_array.from_string("{\"type\":\"unknown_type\"}"),
      serialiser: ser(),
    )
  result
  |> should.be_error
}

// =============================================================================
// FORMAT ISOLATION
// =============================================================================

pub fn json_bytes_decode_fails_under_message_pack_test() {
  let json_bytes =
    transport.encode(SessionMessage(payload: Increment), serialiser: ser())
  let message_pack_ser = transport.automatic() |> transport.use_message_pack()
  transport.decode(json_bytes, serialiser: message_pack_ser)
  |> should.be_error
}

// =============================================================================
// TOGGLE BEHAVIOUR (automatic serialiser)
// =============================================================================

pub fn custom_json_use_json_is_noop_test() {
  let serialiser = ser()
  let after_toggle = transport.use_json(serialiser)
  let bytes =
    transport.encode(
      Acknowledge(target: Session, sequence: 5),
      serialiser: after_toggle,
    )
  transport.decode(bytes, serialiser: after_toggle)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 5)))
}

pub fn use_json_forces_json_path_test() {
  let serialiser = transport.automatic() |> transport.use_json()
  let bytes =
    transport.encode(
      Acknowledge(target: Session, sequence: 1),
      serialiser: serialiser,
    )
  transport.decode(bytes, serialiser: serialiser)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 1)))
}

pub fn use_message_pack_restores_message_pack_path_test() {
  let serialiser =
    transport.automatic()
    |> transport.use_json()
    |> transport.use_message_pack()
  let bytes =
    transport.encode(
      Acknowledge(target: Session, sequence: 1),
      serialiser: serialiser,
    )
  transport.decode(bytes, serialiser: serialiser)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 1)))
}

// =============================================================================
// TRANSPORT HANDLE
// =============================================================================

pub fn transport_close_calls_close_function_test() {
  let ref = test_ref.new(False)
  let t =
    transport.new(send: fn(_) { Nil }, close: fn() { test_ref.set(ref, True) })
  transport.close(t)
  test_ref.get(ref)
  |> should.be_true
}

pub fn transport_new_creates_transport_test() {
  let t = transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  transport.send(t, <<>>)
  transport.close(t)
  True
  |> should.be_true
}

pub fn transport_send_calls_send_function_test() {
  let ref = test_ref.new(<<>>)
  let t =
    transport.new(send: fn(bytes) { test_ref.set(ref, bytes) }, close: fn() {
      Nil
    })
  transport.send(t, bit_array.from_string("hello"))
  test_ref.get(ref)
  |> should.equal(bit_array.from_string("hello"))
}

// =============================================================================
// CUSTOM BINARY SERIALISER
// =============================================================================

fn binary_serialiser() -> transport.Serialiser(Model, Message) {
  transport.custom_binary(
    encode_message: fn(message: Message) {
      case message {
        test_fixtures.Increment -> <<1>>
        test_fixtures.Decrement -> <<2>>
        test_fixtures.Reset -> <<3>>
        test_fixtures.Noop -> <<4>>
        test_fixtures.SetName(n) ->
          bit_array.concat([<<5>>, bit_array.from_string(n)])
        test_fixtures.SetTab(_)
        | test_fixtures.IncrementSecondary
        | test_fixtures.AddTransitionItem(_)
        | test_fixtures.RemoveTransitionItem(_) -> <<6>>
      }
    },
    decode_message: fn(bytes) {
      case bytes {
        <<1>> -> Ok(test_fixtures.Increment)
        <<2>> -> Ok(test_fixtures.Decrement)
        <<3>> -> Ok(test_fixtures.Reset)
        <<4>> -> Ok(test_fixtures.Noop)
        <<5, rest:bytes>> ->
          case bit_array.to_string(rest) {
            Ok(name) -> Ok(test_fixtures.SetName(name))
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    },
    encode_model: fn(m: Model) { <<m.count>> },
    decode_model: fn(bytes) {
      case bytes {
        <<n>> -> Ok(test_fixtures.Model(..test_fixtures.initial_model(), count: n, name: "", connected: False))
        _ -> Error(Nil)
      }
    },
  )
}

pub fn custom_binary_roundtrip_session_message_test() {
  let ser = binary_serialiser()
  transport.encode(SessionMessage(payload: Increment), serialiser: ser)
  |> transport.decode(serialiser: ser)
  |> should.equal(Ok(SessionMessage(payload: Increment)))
}

pub fn custom_binary_roundtrip_decrement_test() {
  let ser = binary_serialiser()
  transport.encode(SessionMessage(payload: Decrement), serialiser: ser)
  |> transport.decode(serialiser: ser)
  |> should.equal(Ok(SessionMessage(payload: Decrement)))
}

pub fn custom_binary_roundtrip_set_name_test() {
  let ser = binary_serialiser()
  transport.encode(SessionMessage(payload: SetName("Eve")), serialiser: ser)
  |> transport.decode(serialiser: ser)
  |> should.equal(Ok(SessionMessage(payload: SetName("Eve"))))
}

pub fn custom_binary_roundtrip_snapshot_test() {
  let ser = binary_serialiser()
  let model = test_fixtures.Model(..test_fixtures.initial_model(), count: 7, name: "", connected: False)
  transport.encode(
    Snapshot(target: Session, sequence: 3, state: model),
    serialiser: ser,
  )
  |> transport.decode(serialiser: ser)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 3, state: model)))
}

pub fn custom_binary_roundtrip_acknowledge_test() {
  let ser = binary_serialiser()
  transport.encode(Acknowledge(target: Session, sequence: 5), serialiser: ser)
  |> transport.decode(serialiser: ser)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 5)))
}

pub fn custom_binary_roundtrip_resync_test() {
  let ser = binary_serialiser()
  transport.encode(Resync(cursors: [Session]), serialiser: ser)
  |> transport.decode(serialiser: ser)
  |> should.equal(Ok(Resync(cursors: [Session])))
}

pub fn custom_binary_use_json_is_noop_test() {
  let ser = binary_serialiser()
  let ser_after = transport.use_json(ser)
  transport.encode(
    Acknowledge(target: Session, sequence: 9),
    serialiser: ser_after,
  )
  |> transport.decode(serialiser: ser_after)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 9)))
}

pub fn custom_binary_use_message_pack_is_noop_test() {
  let ser = binary_serialiser()
  let ser_after = transport.use_message_pack(ser)
  transport.encode(
    Acknowledge(target: Session, sequence: 9),
    serialiser: ser_after,
  )
  |> transport.decode(serialiser: ser_after)
  |> should.equal(Ok(Acknowledge(target: Session, sequence: 9)))
}

// =============================================================================
// CONNECTOR (make_connector / run_connector)
// =============================================================================

pub fn make_connector_wraps_function_test() {
  let connector =
    transport.make_connector(fn(_handler) {
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let handler =
    transport.Handler(
      on_receive: fn(_) { Nil },
      on_reconnect: fn() { Nil },
      on_disconnect: fn() { Nil },
    )
  let _t = transport.run_connector(connector, handler)
  // If we got here without crashing, the connector pipeline worked.
  True
  |> should.be_true
}

pub fn run_connector_passes_handler_through_test() {
  let received_ref = test_ref.new(<<>>)
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      // Invoke the handler's on_receive to prove it was passed through.
      handler.on_receive(bit_array.from_string("relayed"))
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let handler =
    transport.Handler(
      on_receive: fn(bytes) { test_ref.set(received_ref, bytes) },
      on_reconnect: fn() { Nil },
      on_disconnect: fn() { Nil },
    )
  let _t = transport.run_connector(connector, handler)
  test_ref.get(received_ref)
  |> should.equal(bit_array.from_string("relayed"))
}

pub fn run_connector_returns_built_transport_test() {
  let send_ref = test_ref.new(<<>>)
  let connector =
    transport.make_connector(fn(_handler) {
      transport.new(send: fn(b) { test_ref.set(send_ref, b) }, close: fn() {
        Nil
      })
    })
  let handler =
    transport.Handler(
      on_receive: fn(_) { Nil },
      on_reconnect: fn() { Nil },
      on_disconnect: fn() { Nil },
    )
  let t = transport.run_connector(connector, handler)
  transport.send(t, bit_array.from_string("payload"))
  test_ref.get(send_ref)
  |> should.equal(bit_array.from_string("payload"))
}
