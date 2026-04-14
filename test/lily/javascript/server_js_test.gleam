// Tests for lily/server on JavaScript — synchronous closure-based server.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/list
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
  let app_store =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  let assert Ok(srv) = server.start(store: app_store, serialiser: ser())
  srv
}

@target(javascript)
/// Connect a mock client that appends received messages to a ref list.
/// Returns a getter fn that returns the collected messages.
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> fn() -> List(String) {
  let ref = test_ref.new([])
  server.connect(srv, client_id: client_id, send: fn(msg) {
    test_ref.set(ref, [msg, ..test_ref.get(ref)])
  })
  fn() {
    let msgs = list.reverse(test_ref.get(ref))
    test_ref.set(ref, [])
    msgs
  }
}

@target(javascript)
fn encode_client(msg: Message) -> String {
  transport.encode(transport.ClientMessage(payload: msg), serialiser: ser())
}

@target(javascript)
fn encode_resync(seq: Int) -> String {
  transport.encode(transport.Resync(after_sequence: seq), serialiser: ser())
}

// =============================================================================
// STARTUP
// =============================================================================

@target(javascript)
pub fn js_server_start_returns_ok_test() {
  let app_store =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  server.start(store: app_store, serialiser: ser())
  |> should.be_ok
}

// =============================================================================
// CLIENT MANAGEMENT
// =============================================================================

@target(javascript)
pub fn js_server_disconnect_stops_broadcast_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
  server.disconnect(srv, client_id: "c2")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  get_c2()
  |> list.length
  |> should.equal(0)
  get_c1()
  |> list.length
  |> should.equal(1)
}

@target(javascript)
pub fn js_server_disconnect_nonexistent_test() {
  let srv = new_server()
  server.disconnect(srv, client_id: "ghost")
  True
  |> should.be_true
}

// =============================================================================
// MESSAGE PROCESSING
// =============================================================================

@target(javascript)
pub fn js_server_incoming_acknowledges_sender_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(1)
  case messages {
    [msg, ..] -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Acknowledge(sequence: 1)))
    }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_incoming_broadcasts_to_others_test() {
  let srv = new_server()
  let _get_c1 = connect_client(srv, "c1")
  let get_c2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  let messages = get_c2()
  messages
  |> list.length
  |> should.equal(1)
  case messages {
    [msg, ..] -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.ServerMessage(sequence: 1, payload: Increment)),
      )
    }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_incoming_does_not_broadcast_to_sender_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  let _get_c2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(1)
  case messages {
    [msg, ..] -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(Ok(transport.Acknowledge(sequence: 1)))
    }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_sequence_increments_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(2)
  case messages {
    [_ack1, ack2] -> {
      transport.decode(ack2, serialiser: ser())
      |> should.equal(Ok(transport.Acknowledge(sequence: 2)))
    }
    _ -> should.fail()
  }
}

// =============================================================================
// RESYNC
// =============================================================================

@target(javascript)
pub fn js_server_resync_sends_snapshot_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_resync(0))
  let messages = get_c1()
  messages
  |> list.length
  |> should.equal(1)
  case messages {
    [msg, ..] -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 0, state: test_fixtures.initial_model())),
      )
    }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_resync_from_new_client_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  let _ = get_c1()
  let get_c2 = connect_client(srv, "c2")
  server.incoming(srv, client_id: "c2", text: encode_resync(0))
  let messages = get_c2()
  case messages {
    [msg, ..] -> {
      let expected_model =
        test_fixtures.Model(count: 1, name: "", connected: False)
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 1, state: expected_model)),
      )
    }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn js_server_resync_after_messages_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_client(SetName("Alice")))
  let _ = get_c1()
  server.incoming(srv, client_id: "c1", text: encode_resync(1))
  let messages = get_c1()
  case messages {
    [msg, ..] -> {
      let expected_model =
        test_fixtures.Model(count: 0, name: "Alice", connected: False)
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 1, state: expected_model)),
      )
    }
    [] -> should.fail()
  }
}

// =============================================================================
// ON-MESSAGE HOOK
// =============================================================================

@target(javascript)
pub fn js_server_on_message_hook_called_test() {
  let srv = new_server()
  let hook_ref = test_ref.new(False)
  server.on_message(srv, fn(msg, _model, _client_id) {
    case msg {
      Increment -> test_ref.set(hook_ref, True)
      _ -> Nil
    }
  })
  let _get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
  test_ref.get(hook_ref)
  |> should.be_true
}

@target(javascript)
pub fn js_server_no_hook_does_not_crash_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_client(Increment))
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
  server.incoming(srv, client_id: "c1", text: "not json at all")
  get_c1()
  |> list.length
  |> should.equal(0)
}

@target(javascript)
pub fn js_server_sequence_starts_at_zero_test() {
  let srv = new_server()
  let get_c1 = connect_client(srv, "c1")
  server.incoming(srv, client_id: "c1", text: encode_resync(0))
  case get_c1() {
    [msg, ..] -> {
      transport.decode(msg, serialiser: ser())
      |> should.equal(
        Ok(transport.Snapshot(sequence: 0, state: test_fixtures.initial_model())),
      )
    }
    [] -> should.fail()
  }
}
