// Tests for transport.websocket — WebSocket transport lifecycle.
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

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start
}

// =============================================================================
// CONFIGURATION
// =============================================================================

@target(javascript)
pub fn websocket_config_has_default_jitter_ratio_test() {
  get_jitter_ratio(transport.websocket(url: "ws://localhost/ws"))
  |> should.equal(0.25)
}

@target(javascript)
pub fn websocket_config_has_default_multiplier_test() {
  get_multiplier(transport.websocket(url: "ws://localhost/ws"))
  |> should.equal(2.0)
}

@target(javascript)
pub fn websocket_reconnect_jitter_ratio_sets_value_test() {
  transport.websocket(url: "ws://localhost/ws")
  |> transport.reconnect_jitter_ratio(0.1)
  |> get_jitter_ratio
  |> should.equal(0.1)
}

@target(javascript)
pub fn websocket_reconnect_multiplier_sets_value_test() {
  transport.websocket(url: "ws://localhost/ws")
  |> transport.reconnect_multiplier(1.5)
  |> get_multiplier
  |> should.equal(1.5)
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
    transport.websocket(url: "ws://localhost/ws") |> transport.websocket_connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
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
    test_ref.set(reconnect_ref, True)
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  }
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
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
    transport.websocket(url: "ws://localhost/ws") |> transport.websocket_connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let ws = test_setup.get_last_websocket()
  test_setup.trigger_websocket_open(ws)
  let snapshot_json =
    "{\"type\":\"snapshot\",\"sequence\":0,\"state\":{\"count\":5,\"name\":\"Bob\",\"connected\":false}}"
  test_setup.trigger_websocket_message(ws, snapshot_json)
  client.get_current_model(runtime).count
  |> should.equal(5)
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
    transport.websocket(url: "ws://localhost/ws") |> transport.websocket_connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let ws = test_setup.get_last_websocket()
  test_setup.trigger_websocket_open(ws)
  client.dispatch(runtime)(test_fixtures.Increment)
  let sent = test_setup.get_websocket_sent(ws)
  list.any(sent, fn(msg) { string.contains(msg, "client_message") })
  |> should.be_true
}

@target(javascript)
pub fn websocket_send_when_closed_queues_to_localstorage_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let connector =
    transport.websocket(url: "ws://localhost/ws") |> transport.websocket_connect
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
    transport.websocket(url: "ws://localhost/ws") |> transport.websocket_connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let ws = test_setup.get_last_websocket()
  test_setup.trigger_websocket_open(ws)
  let sent = test_setup.get_websocket_sent(ws)
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

@target(javascript)
@external(javascript, "./websocket_test.ffi.mjs", "getJitterRatio")
fn get_jitter_ratio(_config: transport.WebSocketConfig) -> Float {
  0.0
}

@target(javascript)
@external(javascript, "./websocket_test.ffi.mjs", "getMultiplier")
fn get_multiplier(_config: transport.WebSocketConfig) -> Float {
  0.0
}
