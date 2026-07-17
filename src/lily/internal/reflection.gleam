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
/// `ReflectedConstructor` carries the constructor's PascalCase name plus its
/// positional fields. Zero-field constructors compile to atoms on Erlang and
/// to instances of an empty class on JavaScript, both round-trip through
/// `ReflectedConstructor(name, [])`.
///
/// `ReflectedTuple` is for raw Gleam tuples like `#(a, b)`, which have no
/// constructor name and so encode as a tag-less map with positional keys.
///
/// `ReflectedDict` and `ReflectedSet` cover `gleam/dict` and `gleam/set`.
/// Their natural runtime shapes (a JS class, an Erlang tagged map, etc.)
/// don't fit ReflectedConstructor cleanly, so they get their own
/// variants. On the wire they look like a CustomType with the reserved
/// sentinel names `$dict` / `$set` so the format stays consistent with
/// the JSON path.
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
/// every constructor name in the tree must be in the registry, or this returns
/// `Error(Nil)`. The result is `Dynamic` because the call site supplies the
/// final type through the `decode.Decoder` plumbing in transport.gleam.
@external(erlang, "lily_reflection_ffi", "construct")
@external(javascript, "./reflection.ffi.mjs", "construct")
@internal
pub fn construct(reflected: Reflected) -> Result(Dynamic, Nil)
