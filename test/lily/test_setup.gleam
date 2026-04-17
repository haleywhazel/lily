// jsdom initialisation and DOM reset helpers for JavaScript tests.
// Calling setup() from any test file is sufficient — the module-level side
// effects in test_setup.ffi.mjs patch globalThis once on first import.

@target(javascript)
import gleam/dynamic.{type Dynamic}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "setup")
pub fn setup() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "resetDom")
pub fn reset_dom() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "getLastWebSocket")
pub fn get_last_websocket() -> Dynamic {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "getLastEventSource")
pub fn get_last_event_source() -> Dynamic {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "resetMocks")
pub fn reset_mocks() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "triggerWebSocketOpen")
pub fn trigger_websocket_open(_websocket: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "triggerWebSocketMessage")
pub fn trigger_websocket_message(_websocket: Dynamic, _data: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "triggerWebSocketClose")
pub fn trigger_websocket_close(_websocket: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "getWebSocketSent")
pub fn get_websocket_sent(_websocket: Dynamic) -> List(String) {
  []
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "triggerEventSourceOpen")
pub fn trigger_event_source_open(_event_source: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "triggerEventSourceMessage")
pub fn trigger_event_source_message(
  _event_source: Dynamic,
  _data: String,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_setup.ffi.mjs", "triggerEventSourceError")
pub fn trigger_event_source_error(_event_source: Dynamic) -> Nil {
  Nil
}
