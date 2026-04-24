//// Lily is a web framework for live server updates and offline interactivity.
//// This was made since I was running into issues within Phoenix LiveView when
//// combining real-time updates with offline-interactivity where needed.
//// Instead of a VDOM, Lily allows components to dictate how/when they should
//// be rendered.
////
//// Lily is designed to be modular, with each part replaceable by your own
//// implementation. The browser facing modules are designed to be JS-only, and
//// any server-based modules will have both a JS and Erlang implementation.
//// That said, I would recommend using the Erlang/BEAM compilation target on
//// the backend to get the full benefits of the BEAM VM.
////
//// Note that Lily is still under development, with breaking changes expected
//// quite regularly at this stage.
////

// =============================================================================
// PUBLIC CONSTANTS
// =============================================================================

/// The current version of Lily.
pub const version: String = "0.2.0"
