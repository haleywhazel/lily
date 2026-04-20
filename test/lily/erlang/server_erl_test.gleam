// Tests for lily/server on Erlang — uses OTP actor with process.Subject.
// All functions are @target(erlang) — skipped on JavaScript.

@target(erlang)
import gleam/bit_array
@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleeunit/should
@target(erlang)
import lily
@target(erlang)
import lily/server
@target(erlang)
import lily/test_fixtures.{type Message, type Model, Increment, SetName}
@target(erlang)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn ser() {
  test_fixtures.custom_serialiser()
}

@target(erlang)
fn new_server() -> server.Server(Model, Message) {
  let s = lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  let assert Ok(srv) = server.start(store: s, serialiser: ser())
  srv
}

@target(erlang)
/// Connect a mock client that captures received messages in a Subject.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subj = process.new_subject()
  server.connect(srv, client_id: client_id, send: process.send(subj, _))
  subj
}

@target(erlang)
/// Receive one message from Subject with a 200ms timeout.
fn recv(subj: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subj, within: 200)
}

@target(erlang)
/// Encode a client protocol message.
fn encode_client(msg: Message) -> BitArray {
  transport.encode(transport.ClientMessage(payload: msg), serialiser: ser())
}

@target(erlang)
/// Encode a resync request.
fn encode_resync(seq: Int) -> BitArray {
  transport.encode(transport.Resync(after_sequence: seq), serialiser: ser())
}

// =============================================================================
// STARTUP
// =============================================================================

@target(erlang)
pub fn server_start_returns_ok_test() {
  let s = lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  server.start(store: s, serialiser: ser())
  |> should.be_ok
}

// =============================================================================
// CLIENT MANAGEMENT
// =============================================================================

@target(erlang)
pub fn server_connect_multiple_clients_test() {
  let srv = new_server()
  let _s1 = connect_client(srv, "c1")
  let _s2 = connect_client(srv, "c2")
  let _s3 = connect_client(srv, "c3")
  True
  |> should.be_true
}

@target(erlang)
pub fn server_connect_single_client_test() {
  let srv = new_server()
  let subj = connect_client(srv, "c1")
  // No crash — actor accepted the connect message
  True
  |> should.be_true
  let _ = subj
}

@target(erlang)
pub fn server_disconnect_nonexistent_test() {
  let srv = new_server()
  // Should not crash
  server.disconnect(srv, client_id: "ghost")
  True
  |> should.be_true
}

@target(erlang)
pub fn server_disconnect_stops_broadcast_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  // Disconnect c2, then c1 sends — c2 should not receive
  server.disconnect(srv, client_id: "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  // c1 gets an Acknowledge
  let _ = recv(s1)
  // c2 gets nothing — timeout expected
  recv(s2)
  |> should.be_error
}

// =============================================================================
// MESSAGE PROCESSING
// =============================================================================

@target(erlang)
pub fn server_incoming_acknowledges_sender_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  case recv(s1) {
    Ok(msg) -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Acknowledge(sequence: 1)))
    }
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_incoming_broadcasts_to_others_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  // c2 receives a ServerMessage
  case recv(s2) {
    Ok(msg) -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.ServerMessage(sequence: 1, payload: Increment)),
      )
    }
    Error(_) -> should.fail()
  }
  // Consume c1's Acknowledge
  let _ = recv(s1)
}

@target(erlang)
pub fn server_incoming_does_not_broadcast_to_sender_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let _s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  // Consume the Acknowledge on c1
  let ack = recv(s1)
  ack
  |> should.be_ok
  // c1 should not receive a ServerMessage (only Acknowledge)
  recv(s1)
  |> should.be_error
}

@target(erlang)
pub fn server_multiple_clients_broadcast_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  let s3 = connect_client(srv, "c3")
  server.incoming(srv, client_id: "c2", bytes: encode_client(SetName("Alice")))
  // c1 and c3 get ServerMessage
  recv(s1)
  |> should.be_ok
  recv(s3)
  |> should.be_ok
  // c2 gets Acknowledge, not ServerMessage
  case recv(s2) {
    Ok(msg) -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Acknowledge(sequence: 1)))
    }
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_sequence_increments_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  let _ = recv(s1)
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  case recv(s1) {
    Ok(msg) -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Acknowledge(sequence: 2)))
    }
    Error(_) -> should.fail()
  }
}

// =============================================================================
// RESYNC
// =============================================================================

@target(erlang)
pub fn server_resync_after_messages_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  let _ = recv(s1)
  server.incoming(srv, client_id: "c1", bytes: encode_resync(1))
  case recv(s1) {
    Ok(msg) -> {
      let expected_model =
        test_fixtures.Model(count: 1, name: "", connected: False)
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 1, state: expected_model)),
      )
    }
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_resync_from_new_client_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  // Apply some updates via c1
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  let _ = recv(s1)
  // c2 connects later and resyncs
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_resync(0))
  case recv(s2) {
    Ok(msg) -> {
      let expected_model =
        test_fixtures.Model(count: 1, name: "", connected: False)
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 1, state: expected_model)),
      )
    }
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_resync_sends_snapshot_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_resync(0))
  case recv(s1) {
    Ok(msg) -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 0, state: test_fixtures.initial_model())),
      )
    }
    Error(_) -> should.fail()
  }
}

// =============================================================================
// ON-MESSAGE HOOK
// =============================================================================

@target(erlang)
pub fn server_no_hook_does_not_crash_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  recv(s1)
  |> should.be_ok
}

@target(erlang)
pub fn server_on_message_hook_called_test() {
  let srv = new_server()
  let hook_subj = process.new_subject()
  server.on_message(srv, fn(msg, _model, _client_id) {
    process.send(hook_subj, msg)
  })
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  let _ = recv(s1)
  process.receive(hook_subj, within: 200)
  |> should.equal(Ok(Increment))
}

@target(erlang)
pub fn server_on_message_hook_receives_updated_model_test() {
  let srv = new_server()
  let model_subj: process.Subject(Model) = process.new_subject()
  server.on_message(srv, fn(_msg, model, _client_id) {
    process.send(model_subj, model)
  })
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  let _ = recv(s1)
  process.receive(model_subj, within: 200)
  |> should.equal(Ok(test_fixtures.Model(count: 1, name: "", connected: False)))
}

// =============================================================================
// INVALID INCOMING
// =============================================================================

@target(erlang)
pub fn server_incoming_from_unknown_client_test() {
  let srv = new_server()
  // c1 is not connected — Acknowledge goes nowhere, but server does not crash
  server.incoming(srv, client_id: "c1", bytes: encode_client(Increment))
  True
  |> should.be_true
}

@target(erlang)
pub fn server_incoming_invalid_json_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: bit_array.from_string("not json at all"),
  )
  // Server ignores invalid JSON — no message sent
  recv(s1)
  |> should.be_error
}

@target(erlang)
pub fn server_incoming_unknown_protocol_type_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: bit_array.from_string("{\"type\":\"unknown\"}"),
  )
  recv(s1)
  |> should.be_error
}

@target(erlang)
pub fn server_sequence_starts_at_zero_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_resync(0))
  case recv(s1) {
    Ok(msg) -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 0, state: test_fixtures.initial_model())),
      )
    }
    Error(_) -> should.fail()
  }
}
