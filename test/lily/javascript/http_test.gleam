// Tests for transport.http, HTTP/SSE transport lifecycle.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/dynamic
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

// =============================================================================
// CONFIGURATION
// =============================================================================

@target(javascript)
pub fn http_config_has_default_batch_size_test() {
  transport.http(
    post_url: "http://localhost/api/messages",
    events_url: "http://localhost/events",
  )
  |> get_flush_batch_size
  |> should.equal(10)
}

@target(javascript)
pub fn http_flush_batch_size_sets_value_test() {
  transport.http(
    post_url: "http://localhost/api/messages",
    events_url: "http://localhost/events",
  )
  |> transport.flush_batch_size(5)
  |> get_flush_batch_size
  |> should.equal(5)
}

// =============================================================================
// CONNECT LIFECYCLE
// =============================================================================

@target(javascript)
pub fn http_connect_creates_event_source_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
  let connector =
    transport.http(
      post_url: "http://localhost/api/messages",
      events_url: "http://localhost/events",
    )
    |> transport.http_connect
  let _r = client.connect(runtime, with: connector)
  is_null(test_support.get_last_event_source())
  |> should.be_false
}

@target(javascript)
pub fn http_connect_calls_on_reconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
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
pub fn http_connect_calls_on_disconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
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
pub fn http_connect_receives_messages_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
  let received_ref = test_support.new("")
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
      |> fn(t) {
        handler.on_receive(bit_array.from_string("test-message"))
        test_support.set(received_ref, "received")
        t
      }
    })
  let _r = client.connect(runtime, with: connector)
  test_support.get(received_ref)
  |> should.equal("received")
}

// =============================================================================
// SEND BEHAVIOUR
// =============================================================================

@target(javascript)
pub fn http_send_when_disconnected_queues_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
  let connector =
    transport.http(
      post_url: "http://localhost/api/messages",
      events_url: "http://localhost/events",
    )
    |> transport.http_connect
  let _r = client.connect(runtime, with: connector)
  client.dispatch(runtime)(test_support.Increment)
  let queued = test_support.read_session_storage("lily_http_pending")
  queued
  |> should.not_equal("")
}

// =============================================================================
// CLOSE
// =============================================================================

@target(javascript)
pub fn http_close_shuts_down_event_source_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
  let transport_ref: test_support.Ref(transport.Transport) =
    test_support.new(transport.new(send: fn(_) { Nil }, close: fn() { Nil }))
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      let t =
        transport.http(
          post_url: "http://localhost/api/messages",
          events_url: "http://localhost/events",
        )
        |> transport.http_connect
        |> transport.run_connector(handler)
      test_support.set(transport_ref, t)
      t
    })
  let _r = client.connect(runtime, with: connector)
  let es = test_support.get_last_event_source()
  // Get the transport and close it
  let t = test_support.get(transport_ref)
  transport.close(t)
  // EventSource readyState should be 2 (CLOSED)
  event_source_ready_state(es)
  |> should.equal(2)
}

// =============================================================================
// PRIVATE FFI HELPERS
// =============================================================================

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

@target(javascript)
@external(javascript, "./http_test.ffi.mjs", "getFlushBatchSize")
fn get_flush_batch_size(_config: transport.HttpConfig) -> Int {
  0
}
