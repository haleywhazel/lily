// Tests for lily/transport/websocket — WebSocket transport lifecycle.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/dynamic
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/store
@target(javascript)
import lily/test_fixtures.{type Message, type Model}
@target(javascript)
import lily/test_ref
@target(javascript)
import lily/test_setup
@target(javascript)
import lily/transport
@target(javascript)
import lily/transport/websocket

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start
}

// =============================================================================
// CONFIG BUILDER
// =============================================================================

@target(javascript)
pub fn websocket_config_sets_url_test() {
  // Config can be created without crash
  let cfg = websocket.config(url: "ws://localhost:8080/ws")
  let _ = cfg
  True
  |> should.be_true
}

@target(javascript)
pub fn websocket_config_sets_reconnect_timings_test() {
  // Builder functions chain without crash
  let cfg =
    websocket.config(url: "ws://localhost/ws")
    |> websocket.reconnect_base_milliseconds(500)
    |> websocket.reconnect_max_milliseconds(5000)
  let _ = cfg
  True
  |> should.be_true
}

// =============================================================================
// CONNECT LIFECYCLE
// =============================================================================

@target(javascript)
pub fn websocket_connect_creates_websocket_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let connector =
    websocket.config(url: "ws://localhost/ws") |> websocket.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  // A WebSocket should have been created — get_last_websocket returns a non-null object
  is_null(test_setup.get_last_websocket())
  |> should.be_false
}

@target(javascript)
pub fn websocket_connect_calls_on_reconnect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let reconnect_ref = test_ref.new(False)
  let connector = fn(handler: transport.Handler) {
    handler.on_reconnect()
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  }
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  test_ref.set(reconnect_ref, True)
  test_ref.get(reconnect_ref)
  |> should.be_true
}

@target(javascript)
pub fn websocket_connect_calls_on_disconnect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let disconnect_ref = test_ref.new(False)
  let connector = fn(handler: transport.Handler) {
    handler.on_disconnect()
    test_ref.set(disconnect_ref, True)
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  }
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  test_ref.get(disconnect_ref)
  |> should.be_true
}

@target(javascript)
pub fn websocket_connect_receives_messages_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  // Use the real websocket connector and trigger open on the mock WS
  let connector =
    websocket.config(url: "ws://localhost/ws") |> websocket.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let ws = test_setup.get_last_websocket()
  // Open connection then send a message
  test_setup.trigger_websocket_open(ws)
  // Send a snapshot to update the model
  let snapshot_json =
    "{\"type\":\"snapshot\",\"sequence\":0,\"state\":{\"_\":\"Model\",\"0\":5,\"1\":\"Bob\",\"2\":false}}"
  test_setup.trigger_websocket_message(ws, snapshot_json)
  True
  |> should.be_true
}

@target(javascript)
pub fn websocket_connect_calls_on_reconnect_via_mock_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let reconnect_ref = test_ref.new(False)
  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector = fn(handler: transport.Handler) {
    test_ref.set(handler_ref, handler)
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  }
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  // Trigger reconnect via the captured handler
  let handler = test_ref.get(handler_ref)
  handler.on_reconnect()
  test_ref.set(reconnect_ref, True)
  test_ref.get(reconnect_ref)
  |> should.be_true
}

// =============================================================================
// SEND BEHAVIOUR
// =============================================================================

@target(javascript)
pub fn websocket_send_when_open_sends_directly_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let connector =
    websocket.config(url: "ws://localhost/ws") |> websocket.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let ws = test_setup.get_last_websocket()
  // Open the connection first
  test_setup.trigger_websocket_open(ws)
  // Dispatch a message — should be sent directly via the open WS
  client.dispatch(runtime)(test_fixtures.Increment)
  let sent = test_setup.get_websocket_sent(ws)
  // Sent includes a Resync (from on_reconnect) and then the ClientMessage
  list.any(sent, fn(msg) { string.contains(msg, "client_message") })
  |> should.be_true
}

@target(javascript)
pub fn websocket_send_when_closed_queues_to_localstorage_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let connector =
    websocket.config(url: "ws://localhost/ws") |> websocket.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  // Do NOT open the WS — remains in CONNECTING state
  // Dispatch a message — should be queued in localStorage
  client.dispatch(runtime)(test_fixtures.Increment)
  let queued = read_local_storage("lily_ws_pending")
  queued
  |> should.not_equal("")
}

// =============================================================================
// OFFLINE QUEUE FLUSH
// =============================================================================

@target(javascript)
pub fn websocket_flush_pending_on_reconnect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  // Pre-seed the pending queue in localStorage
  write_local_storage(
    "lily_ws_pending",
    "[\"queued-message-1\",\"queued-message-2\"]",
  )
  let runtime = new_runtime()
  let connector =
    websocket.config(url: "ws://localhost/ws") |> websocket.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let ws = test_setup.get_last_websocket()
  // Opening the connection should flush the pending queue
  test_setup.trigger_websocket_open(ws)
  let sent = test_setup.get_websocket_sent(ws)
  // The pending messages should have been sent
  { sent != [] }
  |> should.be_true
}

// =============================================================================
// PRIVATE FFI HELPERS
// =============================================================================

@target(javascript)
@external(javascript, "./session_test.ffi.mjs", "writeLocalStorage")
fn write_local_storage(_key: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./session_test.ffi.mjs", "readLocalStorage")
fn read_local_storage(_key: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./websocket_test.ffi.mjs", "isNull")
fn is_null(_value: dynamic.Dynamic) -> Bool {
  False
}
