//// Target-neutral reflection over Gleam runtime values. This is the only
//// FFI layer the auto-serialiser needs: each target inspects its native
//// representation (tagged tuples and atoms on Erlang, CustomType classes
//// and `Object.keys` on JavaScript) and produces a [`Reflected`](#Reflected)
//// value the pure-Gleam codec can walk.
////
//// The inverse, [`construct`](#construct), takes a [`Reflected`](#Reflected)
//// produced by decoding and rebuilds a Gleam value. On JavaScript a
//// constructor registry must be populated (via `transport.ffi.mjs`'s
//// `registerModule`) before decoding can recover types whose constructors
//// the runtime has not seen during encoding. On Erlang, atoms are
//// self-describing and no registry is needed.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

/// A Gleam value flattened into a target-neutral representation.
///
/// `ReflectedConstructor` carries the constructor's PascalCase name plus its
/// positional fields. Zero-field constructors compile to atoms on Erlang and
/// to instances of an empty class on JavaScript; both round-trip through
/// `ReflectedConstructor(name, [])`.
@internal
pub type Reflected {
  ReflectedNil
  ReflectedBool(Bool)
  ReflectedInteger(Int)
  ReflectedFloat(Float)
  ReflectedString(String)
  ReflectedList(List(Reflected))
  ReflectedConstructor(name: String, fields: List(Reflected))
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Inspect a Gleam runtime value and produce a [`Reflected`](#Reflected) tree.
@external(erlang, "lily_reflection_ffi", "reflect")
@external(javascript, "./reflection.ffi.mjs", "reflect")
@internal
pub fn reflect(value: a) -> Reflected

/// Rebuild a Gleam runtime value from a [`Reflected`](#Reflected) tree. The
/// caller is responsible for ensuring the result is the type the call site
/// expects; on JavaScript, the constructor registry must contain every
/// constructor name the tree references or this returns `Error(Nil)`.
///
/// The result is wrapped as `Dynamic` because the call site supplies the
/// final type via `decode.Decoder` plumbing in transport.gleam.
@external(erlang, "lily_reflection_ffi", "construct")
@external(javascript, "./reflection.ffi.mjs", "construct")
@internal
pub fn construct(reflected: Reflected) -> Result(Dynamic, Nil)
