//// Lily is a web framework for live server updates and offline-friendly
//// interactivity, with components deciding for themselves how and when they
//// re-render.
////
//// Every part is modular and replaceable, and Lily is designed to integrate
//// with existing Gleam libraries (such as wisp/mist/ewe).
////
//// Browser-facing modules are JavaScript-only; server-side modules compile to
//// both JavaScript and Erlang, though the BEAM is the recommended for the
//// backend.
////
//// Lily is still young and breaking changes are expected at this stage.
////

// =============================================================================
// PUBLIC CONSTANTS
// =============================================================================

/// The current version of Lily.
pub const version: String = "0.5.0"
