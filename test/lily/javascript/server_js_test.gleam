// Tests for lily/server on JavaScript, synchronous closure-based server.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/bit_array
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
import lily/test_fixtures.{type Message, type Model, Increment, SetName}
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
fn new_server() -> server.Server(Model, Message) {
  let assert Ok(srv) =
    server.new(
      initial: test_fixtures.initial_model(),
      serialiser: ser(),
      wiring: store.wiring()
        |> store.session(
          extract: fn(message) { Ok(message) },
          update: test_fixtures.update,
          field_get: fn(model) { model },
          field_set: fn(_, model) { model },
        ),
    )
    |> server.start
  srv
}

@target(javascript)
/// Connect a mock client that appends received messages to a ref list.
/// Returns a drain fn that returns and clears the captured messages.
/// Drains the `Connected` frame sent immediately on connect so tests
/// that check for other frames don't have to skip it.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> fn() -> List(BitArray) {
  let ref = test_ref.new([])
  server.connect(srv, client_id: client_id, send: fn(bytes) {
    test_ref.set(ref, [bytes, ..test_ref.get(ref)])
  })
  test_ref.set(ref, [])
  fn() {
    let msgs = list.reverse(test_ref.get(ref))
    test_ref.set(ref, [])
    msgs
  }
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
    initial: test_fixtures.initial_model(),
    serialiser: ser(),
    wiring: store.wiring()
      |> store.session(
        extract: fn(message) { Ok(message) },
        update: test_fixtures.update,
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
  let srv = new_server()
  let ref = test_ref.new([])
  server.connect(srv, client_id: "c1", send: fn(bytes) {
    test_ref.set(ref, [bytes, ..test_ref.get(ref)])
  })
  case list.reverse(test_ref.get(ref)) {
    [bytes] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(Ok(transport.Connected(client_id: "c1")))
    _ -> should.fail()
  }
}

@target(javascript)
pub fn js_server_disconnect_nonexistent_test() {
  let srv = new_server()
  server.disconnect(srv, client_id: "ghost")
  True
  |> should.be_true
}

@target(javascript)
pub fn js_server_disconnect_prevents_acknowledgement_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = get_c1()
  get_c2()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_server_session_sequence_increments_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
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
          state: test_fixtures.initial_model(),
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
          state: test_fixtures.initial_model(),
        )),
      )
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_resync_after_session_messages_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(SetName("Alice")))
  let _ = get_c1()
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(1))
  case get_c1() {
    [bytes, ..] -> {
      let expected_model =
        test_fixtures.Model(
          ..test_fixtures.initial_model(),
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = get_c1()
  let get_c2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_resync_session(0))
  case get_c2() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_fixtures.initial_model(),
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.dispatch_to(srv, client_id: "ghost", message: Increment)
  get_c1() |> list.length |> should.equal(0)
}

@target(javascript)
pub fn js_server_dispatch_to_does_not_reach_other_clients_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
  server.dispatch_to(srv, client_id: "c1", message: Increment)
  get_c1() |> list.length |> should.equal(1)
  get_c2() |> list.length |> should.equal(0)
}

@target(javascript)
pub fn js_server_dispatch_to_all_reaches_every_client_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
  server.dispatch_to_all(srv, message: Increment)
  get_c1() |> list.length |> should.equal(1)
  get_c2() |> list.length |> should.equal(1)
}

// =============================================================================
// ON-CONNECT / ON-DISCONNECT HOOKS
// =============================================================================

@target(javascript)
pub fn js_server_on_connect_fires_with_client_id_test() {
  let srv = new_server()
  let captured = test_ref.new([])
  server.on_connect(srv, fn(client_id) {
    test_ref.set(captured, [client_id, ..test_ref.get(captured)])
  })
  let _ = connect_client(srv, "c1")
  test_ref.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn js_server_on_connect_fires_once_per_connect_test() {
  let srv = new_server()
  let captured = test_ref.new([])
  server.on_connect(srv, fn(client_id) {
    test_ref.set(captured, [client_id, ..test_ref.get(captured)])
  })
  let _ = connect_client(srv, "c1")
  let _ = connect_client(srv, "c2")
  test_ref.get(captured) |> list.reverse |> should.equal(["c1", "c2"])
}

@target(javascript)
pub fn js_server_on_disconnect_fires_with_client_id_test() {
  let srv = new_server()
  let captured = test_ref.new([])
  server.on_disconnect(srv, fn(client_id) {
    test_ref.set(captured, [client_id, ..test_ref.get(captured)])
  })
  let _ = connect_client(srv, "c1")
  server.disconnect(srv, client_id: "c1")
  test_ref.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn js_server_no_connect_hook_does_not_crash_test() {
  let srv = new_server()
  let _ = connect_client(srv, "c1")
  server.disconnect(srv, client_id: "c1")
  True |> should.be_true
}

// =============================================================================
// ON-MESSAGE HOOK
// =============================================================================

@target(javascript)
pub fn js_server_no_hook_does_not_crash_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(0))
  case get_c1() {
    [bytes, ..] ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_fixtures.initial_model(),
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
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.stop(srv)
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  server.disconnect(srv, client_id: "c1")
  get_c1()
  |> list.length
  |> should.equal(0)
}
