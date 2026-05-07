//// JS-only mutable reference cell. Used internally to host server and topic
//// state across asynchronous browser callbacks (WebSocket onmessage, fetch
//// resolutions, EventSource events, setTimeout). On Erlang, the same role
//// is played by OTP actors; this module provides the equivalent on
//// JavaScript.
////
//// All functions are marked `@internal` so sibling Lily modules can use
//// them, but they are not part of the public API.

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@target(javascript)
@internal
pub type Reference(value)

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@target(javascript)
@external(javascript, "./reference.ffi.mjs", "get")
@internal
pub fn get(reference: Reference(value)) -> value

@target(javascript)
@external(javascript, "./reference.ffi.mjs", "make")
@internal
pub fn make(value: value) -> Reference(value)

@target(javascript)
@external(javascript, "./reference.ffi.mjs", "set")
@internal
pub fn set(reference: Reference(value), value: value) -> Nil
