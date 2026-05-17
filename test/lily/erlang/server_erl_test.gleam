// Tests for lily/server on Erlang, uses OTP actor with process.Subject.
// All functions are @target(erlang), skipped on JavaScript.

@target(erlang)
import gleam/bit_array
@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/string
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/server
@target(erlang)
import lily/store
@target(erlang)
import lily/test_fixtures.{type Message, type Model, Increment}
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

@target(erlang)
/// Connect a mock client that captures received messages in a Subject.
/// Drains the `Connected` frame sent immediately on connect so tests
/// that check for other frames don't have to skip it.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subj = process.new_subject()
  server.connect(srv, client_id: client_id, send: process.send(subj, _))
  let _ = process.receive(subj, within: 200)
  subj
}

@target(erlang)
/// Receive one message from Subject with a 200ms timeout.
fn recv(subj: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subj, within: 200)
}

@target(erlang)
/// Encode a session message (client to server).
fn encode_session(message: Message) -> BitArray {
  transport.encode(
    transport.SessionMessage(payload: message),
    serialiser: ser(),
  )
}

@target(erlang)
/// Encode a resync request for the session target.
fn encode_resync_session(_seq: Int) -> BitArray {
  transport.encode(
    transport.Resync(cursors: [transport.Session]),
    serialiser: ser(),
  )
}

// =============================================================================
// STARTUP
// =============================================================================

@target(erlang)
pub fn server_start_returns_ok_test() {
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
  True
  |> should.be_true
  let _ = subj
}

@target(erlang)
pub fn server_connect_sends_connected_frame_test() {
  let srv = new_server()
  let subj = process.new_subject()
  server.connect(srv, client_id: "c1", send: process.send(subj, _))
  case recv(subj) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(Ok(transport.Connected(client_id: "c1")))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_disconnect_nonexistent_test() {
  let srv = new_server()
  server.disconnect(srv, client_id: "ghost")
  True
  |> should.be_true
}

@target(erlang)
pub fn server_disconnect_prevents_acknowledgement_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.disconnect(srv, client_id: "c1")
  // Give the actor time to process Disconnect before Incoming
  process.sleep(50)
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  // c1 is disconnected, no Acknowledge sent
  recv(s1)
  |> should.be_error
}

// =============================================================================
// SESSION MESSAGE PROCESSING
// =============================================================================

@target(erlang)
pub fn server_session_message_acknowledges_sender_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  case recv(s1) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 1)),
      )
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_session_message_does_not_broadcast_test() {
  // Session messages are per-connection, c2 receives nothing when c1 sends.
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  // Consume c1's Acknowledge
  let _ = recv(s1)
  // c2 must receive nothing
  recv(s2)
  |> should.be_error
}

@target(erlang)
pub fn server_session_sequence_increments_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = recv(s1)
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  case recv(s1) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 2)),
      )
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_session_sequence_is_per_connection_test() {
  // Each client has its own sequence counter starting at 0.
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  server.incoming(srv, client_id: "c2", bytes: encode_session(Increment))
  case recv(s1) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 1)),
      )
    Error(_) -> should.fail()
  }
  case recv(s2) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Acknowledge(target: transport.Session, sequence: 1)),
      )
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_session_state_is_per_connection_test() {
  // c1 sending Increment does not affect c2's session snapshot.
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = recv(s1)
  server.incoming(srv, client_id: "c2", bytes: encode_resync_session(0))
  case recv(s2) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_fixtures.initial_model(),
        )),
      )
    Error(_) -> should.fail()
  }
}

// =============================================================================
// RESYNC
// =============================================================================

@target(erlang)
pub fn server_resync_sends_snapshot_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(0))
  case recv(s1) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_fixtures.initial_model(),
        )),
      )
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_resync_after_session_messages_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = recv(s1)
  server.incoming(srv, client_id: "c1", bytes: encode_resync_session(1))
  case recv(s1) {
    Ok(bytes) -> {
      let expected_model =
        test_fixtures.Model(
          ..test_fixtures.initial_model(),
          count: 1,
          name: "",
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
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn server_resync_reflects_own_session_only_test() {
  // c2's resync snapshot reflects c2's state, not c1's.
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = recv(s1)
  let s2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", bytes: encode_resync_session(0))
  case recv(s2) {
    Ok(bytes) ->
      transport.decode(bytes, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(
          target: transport.Session,
          sequence: 0,
          state: test_fixtures.initial_model(),
        )),
      )
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
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  recv(s1)
  |> should.be_ok
}

@target(erlang)
pub fn server_on_message_hook_called_test() {
  let srv = new_server()
  let hook_subj = process.new_subject()
  server.on_message(srv, fn(message, _model, _client_id) {
    process.send(hook_subj, message)
  })
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = recv(s1)
  process.receive(hook_subj, within: 200)
  |> should.equal(Ok(Increment))
}

@target(erlang)
pub fn server_on_message_hook_receives_updated_model_test() {
  let srv = new_server()
  let model_subj: process.Subject(Model) = process.new_subject()
  server.on_message(srv, fn(_message, model, _client_id) {
    process.send(model_subj, model)
  })
  let s1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  let _ = recv(s1)
  process.receive(model_subj, within: 200)
  |> should.equal(Ok(
    test_fixtures.Model(
      ..test_fixtures.initial_model(),
      count: 1,
      name: "",
      connected: False,
    ),
  ))
}

// =============================================================================
// INVALID INCOMING
// =============================================================================

@target(erlang)
pub fn server_incoming_from_unknown_client_test() {
  let srv = new_server()
  // c1 is not connected, Acknowledge goes nowhere, but server does not crash
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
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

// =============================================================================
// GENERATE CLIENT ID
// =============================================================================

@target(erlang)
pub fn server_generate_client_id_is_unique_test() {
  server.generate_client_id()
  |> should.not_equal(server.generate_client_id())
}

@target(erlang)
pub fn server_generate_client_id_returns_32_char_hex_test() {
  let id = server.generate_client_id()
  string.length(id)
  |> should.equal(32)
}

// =============================================================================
// STOP
// =============================================================================

@target(erlang)
pub fn server_stop_silently_drops_further_calls_test() {
  let srv = new_server()
  let s1 = connect_client(srv, "c1")
  server.stop(srv)
  process.sleep(50)
  server.incoming(srv, client_id: "c1", bytes: encode_session(Increment))
  server.disconnect(srv, client_id: "c1")
  recv(s1)
  |> should.be_error
}
