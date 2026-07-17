//// A plain mutable cell, JavaScript only. The browser runtime has to keep its
//// server and topic state somewhere it can reach again from an async callback,
//// a WebSocket message, a fetch that resolved, an EventSource event, a timer,
//// and on JavaScript there is no actor to hold it, so it lives in one of
//// these. Erlang gets the real thing, an OTP process, and never needs this.

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
