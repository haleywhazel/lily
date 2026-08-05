// Tests for transport.websocket, WebSocket transport lifecycle.
// All functions are @target(javascript), skipped on Erlang.

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
import lily/test_support.{type Message, type Model}
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_support.initial_model(), with: test_support.update)
  |> client.start(
    store.wiring()
      |> store.session(
        extract: fn(m) { Ok(m) },
        update: test_support.update,
        field_get: fn(model) { model },
        field_set: fn(_, model) { model },
      ),
    serialiser: test_support.custom_serialiser(),
  )
}

// =============================================================================
// CONFIGURATION
// =============================================================================

@target(javascript)
pub fn websocket_default_backoff_connects_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.DefaultBackoff,
    )
  let _r = client.connect(runtime, with: connector)
  is_null(test_support.get_last_websocket())
  |> should.be_false
}

@target(javascript)
pub fn websocket_custom_backoff_connects_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.Backoff(
        base_milliseconds: 1000,
        max_milliseconds: 30_000,
        jitter_ratio: 0.1,
        multiplier: 1.5,
      ),
    )
  let _r = client.connect(runtime, with: connector)
  is_null(test_support.get_last_websocket())
  |> should.be_false
}

// =============================================================================
// CONNECT LIFECYCLE
// =============================================================================

@target(javascript)
pub fn websocket_creates_websocket_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.DefaultBackoff,
    )
  let _r = client.connect(runtime, with: connector)
  is_null(test_support.get_last_websocket())
  |> should.be_false
}

@target(javascript)
pub fn websocket_calls_on_reconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let reconnect_ref = test_support.new(False)
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      handler.on_reconnect()
      test_support.set(reconnect_ref, True)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r = client.connect(runtime, with: connector)
  test_support.get(reconnect_ref)
  |> should.be_true
}

@target(javascript)
pub fn websocket_calls_on_disconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let disconnect_ref = test_support.new(False)
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      handler.on_disconnect()
      test_support.set(disconnect_ref, True)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r = client.connect(runtime, with: connector)
  test_support.get(disconnect_ref)
  |> should.be_true
}

@target(javascript)
pub fn websocket_receives_messages_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  // Use the real websocket connector and trigger open on the mock WS
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.DefaultBackoff,
    )
  let _r = client.connect(runtime, with: connector)
  let ws = test_support.get_last_websocket()
  test_support.trigger_websocket_open(ws)
  let snapshot_json =
    "{\"type\":\"snapshot\",\"target\":{\"kind\":\"session\"},\"sequence\":0,\"state\":{\"count\":5,\"name\":\"Bob\",\"connected\":false,\"active_tab\":\"TabA\",\"secondary_count\":0,\"transition_item\":null}}"
  test_support.trigger_websocket_message(ws, snapshot_json)
  client.get_current_model(runtime).count
  |> should.equal(5)
}

// =============================================================================
// SEND BEHAVIOUR
// =============================================================================

@target(javascript)
pub fn websocket_send_when_open_sends_directly_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.DefaultBackoff,
    )
  let _r = client.connect(runtime, with: connector)
  let ws = test_support.get_last_websocket()
  test_support.trigger_websocket_open(ws)
  client.dispatch(runtime)(test_support.Increment)
  let sent = test_support.get_websocket_sent(ws)
  list.any(sent, fn(frame) { string.contains(frame, "session_message") })
  |> should.be_true
}

@target(javascript)
pub fn websocket_send_when_closed_queues_to_sessionstorage_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = new_runtime()
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.DefaultBackoff,
    )
  let _r = client.connect(runtime, with: connector)
  // Do NOT open the WS, remains in CONNECTING state
  // Dispatch a message, should be queued in sessionStorage
  client.dispatch(runtime)(test_support.Increment)
  let queued = test_support.read_session_storage("lily_ws_pending")
  queued
  |> should.not_equal("")
}

// =============================================================================
// OFFLINE QUEUE FLUSH
// =============================================================================

@target(javascript)
pub fn websocket_flush_pending_on_reconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  // Pre-seed the pending queue in sessionStorage
  test_support.write_session_storage(
    "lily_ws_pending",
    "[\"queued-message-1\",\"queued-message-2\"]",
  )
  let runtime = new_runtime()
  let connector =
    transport.websocket(
      url: "ws://localhost/ws",
      reconnect: transport.DefaultBackoff,
    )
  let _r = client.connect(runtime, with: connector)
  let ws = test_support.get_last_websocket()
  test_support.trigger_websocket_open(ws)
  let sent = test_support.get_websocket_sent(ws)
  { sent != [] }
  |> should.be_true
}

// =============================================================================
// PRIVATE FFI HELPERS
// =============================================================================

@target(javascript)
@external(javascript, "./websocket_test.ffi.mjs", "isNull")
fn is_null(_value: dynamic.Dynamic) -> Bool {
  False
}
