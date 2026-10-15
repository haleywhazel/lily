//// Focus helpers for the example, the small part of focus management it
//// needs. A full set (stacked traps, arrow groups) lives in `lily/ui/focus`.

import lily/client.{type Runtime}

/// Move focus to the first element matching `selector`, after the next paint.
pub fn focus(selector: String) -> Nil {
  focus_ffi(selector)
}

/// Stop trapping Tab, without calling the trap's `on_exit`.
pub fn release_trap() -> Nil {
  release_trap_ffi()
}

/// Keep Tab and Shift+Tab inside the element matching `within`. While trapped,
/// `release_on` runs on every key and returning `True` releases the trap and
/// dispatches the message `on_exit` builds.
pub fn trap(
  runtime: Runtime(model, message, mode),
  within within: String,
  release_on release_on: fn(String) -> Bool,
  on_exit on_exit: fn() -> message,
) -> Nil {
  let dispatch = client.dispatch(runtime)
  trap_ffi(within, release_on, fn() { dispatch(on_exit()) })
}

@external(javascript, "./focus.ffi.mjs", "focus")
fn focus_ffi(selector: String) -> Nil

@external(javascript, "./focus.ffi.mjs", "releaseTrap")
fn release_trap_ffi() -> Nil

@external(javascript, "./focus.ffi.mjs", "trap")
fn trap_ffi(
  within: String,
  release_on: fn(String) -> Bool,
  on_exit: fn() -> Nil,
) -> Nil
