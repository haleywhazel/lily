//// Reflection is how your types are serialised without needing a manual codec.
//// Each target peeks at its own native representation, tagged tuples and atoms
//// on Erlang, CustomType classes and `Object.keys` on JavaScript, and flattens
//// the value into a [`Reflected`](#Reflected) tree the pure-Gleam codec can
//// walk the same way on either side.
////
//// [`construct`](#construct) runs the tree back the other way to rebuild a
//// value. Erlang atoms are self-describing, so it just works there. JavaScript
//// classes are not, so the constructor registry has to be seeded first
//// (through `transport.ffi.mjs`'s `registerModule`) or decoding a type the
//// runtime hasn't seen fails.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

/// A Gleam value flattened into a target-neutral representation.
///
/// `ReflectedConstructor` carries the constructor's PascalCase name plus
/// positional fields. Zero-field constructors (atoms on Erlang, empty-class
/// instances on JavaScript) round-trip through
/// `ReflectedConstructor(name, [])`.
///
/// `ReflectedTuple` is for raw tuples like `#(a, b)`, which have no constructor
/// name and encode as a tag-less positional-keyed map.
///
/// `ReflectedDict` and `ReflectedSet` cover `gleam/dict` and `gleam/set`, whose
/// runtime shapes don't fit ReflectedConstructor cleanly. On the wire they look
/// like a CustomType with reserved sentinel names `$dict` / `$set` to stay
/// consistent with the JSON path.
@internal
pub type Reflected {
  ReflectedNil
  ReflectedBool(Bool)
  ReflectedInteger(Int)
  ReflectedFloat(Float)
  ReflectedString(String)
  ReflectedList(List(Reflected))
  ReflectedTuple(fields: List(Reflected))
  ReflectedDict(entries: List(#(Reflected, Reflected)))
  ReflectedSet(members: List(Reflected))
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

/// Rebuild a Gleam value from a [`Reflected`](#Reflected) tree. On JavaScript
/// every constructor name must be in the registry or this returns `Error(Nil)`.
/// Returns `Dynamic` because the call site supplies the type via the
/// `decode.Decoder` plumbing in transport.gleam.
@external(erlang, "lily_reflection_ffi", "construct")
@external(javascript, "./reflection.ffi.mjs", "construct")
@internal
pub fn construct(reflected: Reflected) -> Result(Dynamic, Nil)

/// Reinterpret a `Dynamic` as the call site's expected type. Runtime values
/// carry no static type, so recasting is sound when the value was just rebuilt
/// by [`construct`](#construct) and matches `a` by construction. Shared by
/// transport and event decoding.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./reflection.ffi.mjs", "passthrough")
@internal
pub fn passthrough(value: Dynamic) -> a
