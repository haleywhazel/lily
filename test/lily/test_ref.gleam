// Cross-platform mutable reference cell for use in tests.
// Allows handler invocation to be captured in both Erlang and JavaScript tests
// without requiring platform-specific process primitives.
//
// Uses the Erlang process dictionary on Erlang and a plain JS object on JS.

pub type Ref(value)

@external(javascript, "./test_ref.ffi.mjs", "newRef")
@external(erlang, "lily_test_ref_ffi", "new_ref")
pub fn new(initial: value) -> Ref(value)

@external(javascript, "./test_ref.ffi.mjs", "getRef")
@external(erlang, "lily_test_ref_ffi", "get_ref")
pub fn get(ref: Ref(value)) -> value

@external(javascript, "./test_ref.ffi.mjs", "setRef")
@external(erlang, "lily_test_ref_ffi", "set_ref")
pub fn set(ref: Ref(value), value: value) -> Nil
