/**
 * REFLECTION FFI (JAVASCRIPT)
 *
 * Inspects Gleam runtime values and produces target-neutral Reflected trees;
 * also reconstructs values from those trees using a constructor registry.
 *
 * The constructor registry is populated by transport.ffi.mjs (via
 * registerModule, called from the user's shared types FFI shim). At reflect
 * time we also opportunistically cache constructors we encounter, so values
 * that round-trip through reflect/construct on the same client always work.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error, NonEmpty, Empty, toList } from "../../gleam.mjs";
import {
  ReflectedNil,
  ReflectedBool,
  ReflectedInteger,
  ReflectedFloat,
  ReflectedString,
  ReflectedList,
  ReflectedTuple,
  ReflectedDict,
  ReflectedSet,
  ReflectedConstructor,
} from "./reflection.mjs";
import GleamDict, {
  from as dictFrom,
  fold as dictFold,
} from "../../../gleam_stdlib/dict.mjs";
import { from_list as setFromList } from "../../../gleam_stdlib/gleam/set.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Walk a Gleam runtime value and produce a Reflected tree. */
export function reflect(value) {
  if (value === undefined || value === null) return new ReflectedNil();
  if (typeof value === "boolean") return new ReflectedBool(value);
  if (typeof value === "string") return new ReflectedString(value);
  if (typeof value === "number") {
    return Number.isInteger(value)
      ? new ReflectedInteger(value)
      : new ReflectedFloat(value);
  }

  // Gleam list. Match both branches explicitly: Empty is a class with no
  // head/tail properties, so the "head in value" check below would miss
  // it and fall through to CustomType, encoding as `{"_":"Empty"}`. The
  // Erlang side encodes `[]` as an array, so the cross-target wire
  // format diverges without this check.
  if (value instanceof Empty || value instanceof NonEmpty) {
    const items = [];
    let current = value;
    while (current instanceof NonEmpty) {
      items.push(reflect(current.head));
      current = current.tail;
    }
    return new ReflectedList(arrayToGleamList(items));
  }

  // Gleam tuple (`#(a, b)`) compiles to a plain JS array on this target.
  // Distinguish from Lists (Empty/NonEmpty above) and CustomType class
  // instances (below) by the native Array test.
  if (Array.isArray(value)) {
    const fields = value.map(reflect);
    return new ReflectedTuple(arrayToGleamList(fields));
  }

  // Gleam Dict (`gleam_stdlib/dict.Dict`). Recognised by class identity.
  // Entries are stored as pairs of Reflected values so the encoder can
  // produce a key-value mapping that round-trips through the same
  // pairs-of-arrays shape on the wire.
  if (value instanceof GleamDict) {
    const entries = [];
    dictFold(value, undefined, (_acc, k, v) => {
      entries.push([reflect(k), reflect(v)]);
      return undefined;
    });
    return new ReflectedDict(arrayToGleamList(entries.map(pairToTuple)));
  }

  // Gleam Set (`gleam_stdlib/set.Set`). Internally `Set(dict: Dict)`, so
  // detect by class name plus the presence of an inner Dict.
  if (
    value &&
    value.constructor &&
    value.constructor.name === "Set" &&
    value.dict instanceof GleamDict
  ) {
    const members = [];
    dictFold(value.dict, undefined, (_acc, k, _v) => {
      members.push(reflect(k));
      return undefined;
    });
    return new ReflectedSet(arrayToGleamList(members));
  }

  // Custom type instance
  if (value && typeof value === "object" && value.constructor) {
    const name = value.constructor.name;
    if (!constructorRegistry.has(name)) {
      constructorRegistry.set(name, value.constructor);
    }
    const fields = Object.keys(value).map((field) => reflect(value[field]));
    return new ReflectedConstructor(name, arrayToGleamList(fields));
  }

  // Anything else falls back to nil; lily values are always one of the cases
  // above in practice.
  return new ReflectedNil();
}

// Convert a [k, v] JS array into a Gleam 2-tuple so the ReflectedDict's
// entries field has the right type at the Gleam level. Gleam tuples on
// this target are plain JS arrays, so the conversion is a no-op at
// runtime, kept as a named helper for clarity.
function pairToTuple(pair) {
  return pair;
}

/** Rebuild a Gleam runtime value from a Reflected tree. */
export function construct(reflected) {
  try {
    return new Ok(constructInner(reflected));
  } catch (_e) {
    return new Error(undefined);
  }
}

/** Identity passthrough: returns the input unchanged. Used to reinterpret
 *  Dynamic as a concrete type after reflection has reconstructed the value. */
export function passthrough(value) {
  return value;
}

/**
 * Walk a module namespace (the result of `import * as mod from "..."`) and
 * register every class that extends `CustomType`. Called from the
 * user-provided FFI shim before connecting a transport.
 */
export function registerModule(moduleNamespace) {
  for (const key in moduleNamespace) {
    const value = moduleNamespace[key];
    if (typeof value === "function" && isCustomTypeClass(value)) {
      constructorRegistry.set(value.name, value);
    }
  }
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function constructInner(reflected) {
  if (reflected instanceof ReflectedNil) return undefined;
  if (reflected instanceof ReflectedBool) return reflected[0];
  if (reflected instanceof ReflectedInteger) return reflected[0];
  if (reflected instanceof ReflectedFloat) return reflected[0];
  if (reflected instanceof ReflectedString) return reflected[0];
  if (reflected instanceof ReflectedList) {
    const items = gleamListToArray(reflected[0]).map(constructInner);
    let list = new Empty();
    for (let i = items.length - 1; i >= 0; i--) {
      list = new NonEmpty(items[i], list);
    }
    return list;
  }
  if (reflected instanceof ReflectedTuple) {
    // Gleam tuples are plain JS arrays on this target.
    return gleamListToArray(reflected.fields).map(constructInner);
  }
  if (reflected instanceof ReflectedDict) {
    // Entries are a Gleam list of 2-tuples; tuples are plain JS arrays
    // on this target, so each entry is `[reflected_k, reflected_v]`.
    const entries = gleamListToArray(reflected.entries).map((entry) => [
      constructInner(entry[0]),
      constructInner(entry[1]),
    ]);
    return dictFrom(entries);
  }
  if (reflected instanceof ReflectedSet) {
    const members = gleamListToArray(reflected.members).map(constructInner);
    return setFromList(toList(members));
  }
  if (reflected instanceof ReflectedConstructor) {
    const name = reflected.name;
    const constructor = constructorRegistry.get(name);
    if (!constructor) {
      throw new globalThis.Error(
        `Unknown constructor: ${name}. Did you forget to call register_types()?`,
      );
    }
    const fields = gleamListToArray(reflected.fields).map(constructInner);
    return new constructor(...fields);
  }
  throw new globalThis.Error("Unknown Reflected variant");
}

function arrayToGleamList(items) {
  let list = new Empty();
  for (let i = items.length - 1; i >= 0; i--) {
    list = new NonEmpty(items[i], list);
  }
  return list;
}

function gleamListToArray(list) {
  const items = [];
  let current = list;
  while (current instanceof NonEmpty) {
    items.push(current.head);
    current = current.tail;
  }
  return items;
}

function isCustomTypeClass(fn) {
  let proto = fn.prototype;
  while (proto) {
    if (proto.constructor && proto.constructor.name === "CustomType")
      return true;
    proto = Object.getPrototypeOf(proto);
  }
  return false;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const constructorRegistry = new Map();
