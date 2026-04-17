// Cross-platform mutable reference cell for use in tests.
// Allows handler invocation to be captured in both Erlang and JavaScript tests
// without requiring platform-specific process primitives.
//
// Uses the Erlang process dictionary on Erlang and a plain JS object on JS.

pub type Ref(value)

@external(erlang, "lily_test_ref_ffi", "new_ref")
@external(javascript, "./test_ref.ffi.mjs", "newRef")
pub fn new(initial: value) -> Ref(value)

@external(erlang, "lily_test_ref_ffi", "get_ref")
@external(javascript, "./test_ref.ffi.mjs", "getRef")
pub fn get(ref: Ref(value)) -> value

@external(erlang, "lily_test_ref_ffi", "set_ref")
@external(javascript, "./test_ref.ffi.mjs", "setRef")
pub fn set(ref: Ref(value), value: value) -> Nil
