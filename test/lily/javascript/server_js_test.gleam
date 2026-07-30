// Tests for lily/server on JavaScript, synchronous closure-based server.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/int
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/server
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{type Message, type Model, Increment, SetName}
@target(javascript)
import lily/topic
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn ser() {
  test_support.custom_serialiser()
}

@target(javascript)
fn encode_session(message: Message) -> BitArray {
  transport.encode(
    transport.SessionMessage(payload: message),
    serialiser: ser(),
  )
}

@target(javascript)
fn encode_resync_session(_seq: Int) -> BitArray {
  transport.encode(
    transport.Resync(cursors: [transport.Session]),
    serialiser: ser(),
  )
}

// =============================================================================
// STARTUP
// =============================================================================

@target(javascript)
pub fn js_server_start_returns_ok_test() {
  server.new(
    initial: test_support.initial_model(),
    serialiser: ser(),
    wiring: store.wiring()
      |> store.session(
        extract: fn(message) { Ok(message) },
        update: test_support.update,
        field_get: fn(model) { model },
        field_set: fn(_, model) { model },
      ),
  )
  |> server.start
  |> should.be_ok
}

// =============================================================================
// CLIENT MANAGEMENT
// =============================================================================

@target(javascript)
pub fn js_server_connect_sends_connected_frame_test() {
  let srv = test_support.new_server()
  let ref = test_support.new([])
  server.connect(srv, client_id: "c1", send: fn(bytes) {
    test_support.set(ref, [bytes, ..test_support.get(ref)])
  })
  case list.reverse(test_support.get(ref)) {
    [bytes] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(Ok(transport.Connected(client_id: "c1")))
    _ -> should.fail()
  }
}

@target(javascript)
pub fn js_server_disconnect_nonexistent_test() {
  let srv = test_support.new_server()
  server.disconnect(srv, client_id: "ghost")
  True
  |> should.be_true
}

@target(javascript)
pub fn js_server_disconnect_prevents_acknowledgement_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.disconnect(srv, client_id: "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  get_c1()
  |> list.length
  |> should.equal(0)
}

// =============================================================================
// SESSION MESSAGE PROCESSING
// =============================================================================

@target(javascript)
pub fn js_server_session_message_acknowledges_sender_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(1)
  case messages {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 1)),
      )
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_session_message_does_not_broadcast_test() {
  // Session messages are per-connection, c2 receives nothing when c1 sends.
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  let get_c2 = test_support.connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = get_c1()
  get_c2()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_server_session_sequence_increments_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(2)
  case messages {
    [_ack1, ack2] ->
      transport.decode(ack2, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 2)),
      )
    _ -> should.fail()
  }
}

@target(javascript)
pub fn js_server_session_sequence_is_per_connection_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  let get_c2 = test_support.connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  server.incoming(srv, client_id: "c2", bytes: encode_session(SetName("Alice")))
  case get_c1() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 1)),
      )
    [] -> should.fail()
  }
  case get_c2() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 1)),
      )
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_session_state_is_per_connection_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  let get_c2 = test_support.connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = get_c1()
  server.incoming(srv, client_id: "c2", bytes: encode_resync_session(0))
  case get_c2() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_support.initial_model(),
        )),
      )
    [] -> should.fail()
  }
}

// =============================================================================
// RESYNC
// =============================================================================

@target(javascript)
pub fn js_server_resync_sends_snapshot_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(0))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(1)
  case messages {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_support.initial_model(),
        )),
      )
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_resync_after_session_messages_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(SetName("Alice")))
  let _ = get_c1()
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(1))
  case get_c1() {
    [bytes, ..] -> {
      let expected_model =
        test_support.Model(
          ..test_support.initial_model(),
          count: 0,
          name: "Alice",
          connected: False,
        )
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 1,
          state: expected_model,
        )),
      )
    }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_resync_reflects_own_session_only_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = get_c1()
  let get_c2 = test_support.connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_resync_session(0))
  case get_c2() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_support.initial_model(),
        )),
      )
    [] -> should.fail()
  }
}

// =============================================================================
// DISPATCH-TO
// =============================================================================

@target(javascript)
pub fn js_server_dispatch_to_sends_session_update_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.dispatch_to(srv, client_id: "c1", message: Increment)
  let msgs = get_c1()
  msgs |> list.length |> should.equal(1)
  case msgs {
    [bytes] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.SessionUpdate(sequence: 1, payload: Increment)),
      )
    _ -> should.fail()
  }
}

@target(javascript)
pub fn js_server_dispatch_to_unknown_client_is_noop_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.dispatch_to(srv, client_id: "ghost", message: Increment)
  get_c1() |> list.length |> should.equal(0)
}

@target(javascript)
pub fn js_server_dispatch_to_does_not_reach_other_clients_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  let get_c2 = test_support.connect_client(srv, "c2")
  server.dispatch_to(srv, client_id: "c1", message: Increment)
  get_c1() |> list.length |> should.equal(1)
  get_c2() |> list.length |> should.equal(0)
}

@target(javascript)
pub fn js_server_dispatch_to_all_reaches_every_client_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  let get_c2 = test_support.connect_client(srv, "c2")
  server.dispatch_to_all(srv, message: Increment)
  get_c1() |> list.length |> should.equal(1)
  get_c2() |> list.length |> should.equal(1)
}

// =============================================================================
// ON-CONNECT / ON-DISCONNECT HOOKS
// =============================================================================

@target(javascript)
pub fn js_server_on_connect_fires_with_client_id_test() {
  let srv = test_support.new_server()
  let captured = test_support.new([])
  server.on_connect(srv, fn(client_id) {
    test_support.set(captured, [client_id, ..test_support.get(captured)])
  })
  let _ = test_support.connect_client(srv, "c1")
  test_support.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn js_server_on_connect_fires_once_per_connect_test() {
  let srv = test_support.new_server()
  let captured = test_support.new([])
  server.on_connect(srv, fn(client_id) {
    test_support.set(captured, [client_id, ..test_support.get(captured)])
  })
  let _ = test_support.connect_client(srv, "c1")
  let _ = test_support.connect_client(srv, "c2")
  test_support.get(captured) |> list.reverse |> should.equal(["c1", "c2"])
}

@target(javascript)
pub fn js_server_on_disconnect_fires_with_client_id_test() {
  let srv = test_support.new_server()
  let captured = test_support.new([])
  server.on_disconnect(srv, fn(client_id) {
    test_support.set(captured, [client_id, ..test_support.get(captured)])
  })
  let _ = test_support.connect_client(srv, "c1")
  server.disconnect(srv, client_id: "c1")
  test_support.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn js_server_no_connect_hook_does_not_crash_test() {
  let srv = test_support.new_server()
  let _ = test_support.connect_client(srv, "c1")
  server.disconnect(srv, client_id: "c1")
  True |> should.be_true
}

// =============================================================================
// ON-MESSAGE HOOK
// =============================================================================

@target(javascript)
pub fn js_server_no_hook_does_not_crash_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  get_c1()
  |> list.length
  |> should.equal(1)
}

// =============================================================================
// INVALID INCOMING
// =============================================================================

@target(javascript)
pub fn js_server_incoming_invalid_json_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: bit_array.from_string("not json at all"),
  )
  get_c1()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_server_sequence_starts_at_zero_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(0))
  case get_c1() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_support.initial_model(),
        )),
      )
    [] -> should.fail()
  }
}

// =============================================================================
// GENERATE CLIENT ID
// =============================================================================

@target(javascript)
pub fn js_server_generate_client_id_is_unique_test() {
  server.generate_client_id()
  |> should.not_equal(server.generate_client_id())
}

@target(javascript)
pub fn js_server_generate_client_id_returns_32_char_hex_test() {
  let id = server.generate_client_id()
  string.length(id)
  |> should.equal(32)
}

// =============================================================================
// STOP
// =============================================================================

@target(javascript)
pub fn js_server_stop_silently_drops_further_calls_test() {
  let srv = test_support.new_server()
  let get_c1 = test_support.connect_client(srv, "c1")
  server.stop(srv)
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  server.disconnect(srv, client_id: "c1")
  get_c1()
  |> list.length
  |> should.equal(0)
}

// =============================================================================
// MAX TOPICS + TOPIC LIFECYCLE
// =============================================================================

@target(javascript)
fn server_with_max_topics(maximum: Int) -> server.Server(Model, Message) {
  let assert Ok(srv) =
    server.new(
      initial: test_support.initial_model(),
      serialiser: ser(),
      wiring: store.wiring()
        |> store.session(
          extract: fn(message) { Ok(message) },
          update: test_support.update,
          field_get: fn(model) { model },
          field_set: fn(_, model) { model },
        ),
    )
    |> server.max_topics(maximum)
    |> server.start
  srv
}

@target(javascript)
fn encode_subscribe(topic_id: String) -> BitArray {
  transport.encode(transport.Subscribe(topic_id:), serialiser: ser())
}

@target(javascript)
pub fn js_server_max_topics_rejects_past_limit_test() {
  let srv = server_with_max_topics(1)
  let assert Ok(_) =
    topic.kind(srv, prefix: "room:", parse_id: int.parse, configure: fn(_, t) {
      t
    })
  let drain = test_support.connect_client(srv, "c1")

  // First parametric topic is created (fills the single slot).
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:1"))
  let _ = drain()

  // Second parametric topic is past the cap, server rejects it.
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:2"))
  case drain() {
    [bytes] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Rejected(topic_id: "room:2", reason: "not found")),
      )
    _ -> should.fail()
  }
}

@target(javascript)
pub fn js_server_register_then_unregister_topic_frees_slot_test() {
  let srv = server_with_max_topics(1)
  let assert Ok(t) = topic.new(srv, id: "fixed")

  // The fixed topic occupies the only slot, a parametric create is refused.
  let assert Ok(_) =
    topic.kind(srv, prefix: "room:", parse_id: int.parse, configure: fn(_, tk) {
      tk
    })
  let drain = test_support.connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:1"))
  case drain() {
    [bytes] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Rejected(topic_id: "room:1", reason: "not found")),
      )
    _ -> should.fail()
  }

  // Unregister the fixed topic, the slot frees and the parametric create wins.
  topic.stop(t)
  server.incoming(srv, client_id: "c1", bytes: encode_subscribe("room:2"))
  case drain() {
    [] -> True |> should.be_true
    frames ->
      list.any(frames, fn(bytes) {
        case transport.decode(bytes, serialiser: ser()) {
          Ok(transport.Rejected(_, _)) -> True
          _ -> False
        }
      })
      |> should.be_false
  }
}
