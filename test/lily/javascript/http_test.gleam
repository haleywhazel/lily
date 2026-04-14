// Tests for lily/transport/http — HTTP/SSE transport lifecycle.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/dynamic
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
import lily/transport/http

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start
}

// =============================================================================
// CONNECT LIFECYCLE
// =============================================================================

@target(javascript)
pub fn http_connect_creates_event_source_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let connector =
    http.config(
      post_url: "http://localhost/api/messages",
      events_url: "http://localhost/events",
    )
    |> http.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  is_null(test_setup.get_last_event_source())
  |> should.be_false
}

@target(javascript)
pub fn http_connect_calls_on_reconnect_test() {
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
pub fn http_connect_calls_on_disconnect_test() {
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
pub fn http_connect_receives_messages_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let received_ref = test_ref.new("")
  let connector = fn(handler: transport.Handler) {
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    |> fn(t) {
      handler.on_receive("test-message")
      test_ref.set(received_ref, "received")
      t
    }
  }
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  test_ref.get(received_ref)
  |> should.equal("received")
}

// =============================================================================
// SEND BEHAVIOUR
// =============================================================================

@target(javascript)
pub fn http_send_when_disconnected_queues_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let connector =
    http.config(
      post_url: "http://localhost/api/messages",
      events_url: "http://localhost/events",
    )
    |> http.connect
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  client.dispatch(runtime)(test_fixtures.Increment)
  let queued = read_local_storage("lily_http_pending")
  queued
  |> should.not_equal("")
}

// =============================================================================
// CLOSE
// =============================================================================

@target(javascript)
pub fn http_close_shuts_down_event_source_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()
  let transport_ref: test_ref.Ref(transport.Transport) =
    test_ref.new(transport.new(send: fn(_) { Nil }, close: fn() { Nil }))
  let connector = fn(handler: transport.Handler) {
    let t =
      http.config(
        post_url: "http://localhost/api/messages",
        events_url: "http://localhost/events",
      )
      |> http.connect
      |> fn(c) { c(handler) }
    test_ref.set(transport_ref, t)
    t
  }
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )
  let es = test_setup.get_last_event_source()
  // Get the transport and close it
  let t = test_ref.get(transport_ref)
  transport.close(t)
  // EventSource readyState should be 2 (CLOSED)
  event_source_ready_state(es)
  |> should.equal(2)
}

// =============================================================================
// PRIVATE FFI HELPERS
// =============================================================================

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
@external(javascript, "./http_test.ffi.mjs", "eventSourceReadyState")
fn event_source_ready_state(_es: dynamic.Dynamic) -> Int {
  0
}
