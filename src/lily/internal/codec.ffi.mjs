/**
 * CODEC
 *
 * Reflect values to Reflected trees and rebuild them via a name/arity
 * constructor registry filled by registerModule.
 *
 * Data messages also fall back to a page-local registry filled by encoding
 * them. Wire decoding never consults it, so a missing registration still
 * fails loudly for frames.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import {
  CustomType,
  Empty,
  Error,
  NonEmpty,
  Ok,
  toList,
} from "../../gleam.mjs";
import { Some, None } from "../../../gleam_stdlib/gleam/option.mjs";
import { log } from "./actor.ffi.mjs";
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
} from "./codec.mjs";
import GleamDict, {
  from as dictFrom,
  fold as dictFold,
} from "../../../gleam_stdlib/dict.mjs";
import { from_list as setFromList } from "../../../gleam_stdlib/gleam/set.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function construct(reflected) {
  return constructWith(reflected, (key) => constructorRegistry.get(key));
}

export function constructDataMessage(reflected) {
  return constructWith(
    reflected,
    (key) => constructorRegistry.get(key) ?? dataMessageRegistry.get(key),
  );
}

export function passthrough(value) {
  return value;
}

export function reflect(value) {
  return reflectInner(value, undefined);
}

// records every custom-type class in the tree for constructDataMessage
export function reflectDataMessage(value) {
  return reflectInner(value, (constructor) =>
    dataMessageRegistry.set(
      registryKey(constructor.name, constructor.length),
      constructor,
    ),
  );
}

/** Called from the user's FFI shim before a transport connects. */
export function registerModule(moduleNamespace) {
  for (const key in moduleNamespace) {
    const value = moduleNamespace[key];
    if (typeof value === "function" && isCustomTypeClass(value)) {
      registerClass(value, false);
    }
  }
}

/** The import relies on this file's fixed depth in the build output. */
export function requestModule(packageName, path) {
  const url = new URL(`../../../${packageName}/${path}.mjs`, import.meta.url);
  if (requestedModules.has(url.href)) return;
  requestedModules.add(url.href);
  pendingModules++;
  import(url.href)
    .then((namespace) => registerModule(namespace))
    .catch((error) =>
      log(
        "error",
        `lily: could not load ${packageName}/${path}.mjs to register its ` +
          `types: ${error}`,
      ),
    )
    .finally(() => {
      pendingModules--;
      if (pendingModules === 0) runWaiting();
    });
}

export function whenRegistered(thunk) {
  if (pendingModules === 0) thunk();
  else whenRegisteredQueue.push(thunk);
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function constructInner(reflected, lookup) {
  if (reflected instanceof ReflectedNil) return undefined;
  if (reflected instanceof ReflectedBool) return reflected[0];
  if (reflected instanceof ReflectedInteger) return reflected[0];
  if (reflected instanceof ReflectedFloat) return reflected[0];
  if (reflected instanceof ReflectedString) return reflected[0];
  if (reflected instanceof ReflectedList) {
    return toList(reflected[0].toArray().map((item) => constructInner(item, lookup)));
  }
  if (reflected instanceof ReflectedTuple) {
    // tuples are plain JS arrays
    return reflected.fields.toArray().map((item) => constructInner(item, lookup));
  }
  if (reflected instanceof ReflectedDict) {
    // each entry is a `[key, value]` array
    const entries = reflected.entries.toArray().map((entry) => [
      constructInner(entry[0], lookup),
      constructInner(entry[1], lookup),
    ]);
    return dictFrom(entries);
  }
  if (reflected instanceof ReflectedSet) {
    const members = reflected.members.toArray().map((item) => constructInner(item, lookup));
    return setFromList(toList(members));
  }
  if (reflected instanceof ReflectedConstructor) {
    const fields = reflected.fields.toArray().map((item) => constructInner(item, lookup));
    const key = registryKey(reflected.name, fields.length);
    const constructor = lookup(key);
    if (!constructor) {
      if (!reportedUnknown.has(key)) {
        reportedUnknown.add(key);
        log(
          "error",
          `lily: unknown constructor ${key}, register its module with ` +
            "registerModule so the decoder can rebuild it",
        );
      }
      throw new globalThis.Error(`Unknown constructor: ${key}`);
    }
    return new constructor(...fields);
  }
  throw new globalThis.Error("Unknown Reflected variant");
}

// lookup maps a name/arity key to a class, or undefined
function constructWith(reflected, lookup) {
  try {
    return new Ok(constructInner(reflected, lookup));
  } catch (_error) {
    return new Error(undefined);
  }
}

// every package shares the one prelude CustomType
function isCustomTypeClass(candidate) {
  return candidate.prototype instanceof CustomType;
}

function reflectInner(value, record) {
  if (value === undefined || value === null) return new ReflectedNil();
  if (typeof value === "boolean") return new ReflectedBool(value);
  if (typeof value === "string") return new ReflectedString(value);
  if (typeof value === "number") {
    return Number.isInteger(value)
      ? new ReflectedInteger(value)
      : new ReflectedFloat(value);
  }

  // list, Empty has no head/tail and would otherwise encode as a CustomType
  if (value instanceof Empty || value instanceof NonEmpty) {
    const items = [];
    let current = value;
    while (current instanceof NonEmpty) {
      items.push(reflectInner(current.head, record));
      current = current.tail;
    }
    return new ReflectedList(toList(items));
  }

  // tuples are plain JS arrays
  if (Array.isArray(value)) {
    const fields = value.map((item) => reflectInner(item, record));
    return new ReflectedTuple(toList(fields));
  }

  // dict, by class identity
  if (value instanceof GleamDict) {
    const entries = [];
    dictFold(value, undefined, (_accumulator, key, entryValue) => {
      entries.push([
        reflectInner(key, record),
        reflectInner(entryValue, record),
      ]);
      return undefined;
    });
    // the pair arrays are already Gleam 2-tuples
    return new ReflectedDict(toList(entries));
  }

  // set, by class name plus an inner Dict
  if (
    value &&
    value.constructor &&
    value.constructor.name === "Set" &&
    value.dict instanceof GleamDict
  ) {
    const members = [];
    dictFold(value.dict, undefined, (_accumulator, member, _token) => {
      members.push(reflectInner(member, record));
      return undefined;
    });
    return new ReflectedSet(toList(members));
  }

  // custom type
  if (value && typeof value === "object" && value.constructor) {
    if (record && isCustomTypeClass(value.constructor)) {
      record(value.constructor);
    }
    const fields = Object.keys(value).map((field) =>
      reflectInner(value[field], record),
    );
    return new ReflectedConstructor(value.constructor.name, toList(fields));
  }

  // unreachable for lily values in practice
  return new ReflectedNil();
}

function registerClass(constructor, builtin) {
  const key = registryKey(constructor.name, constructor.length);
  const existing = constructorRegistry.get(key);
  if (existing && existing !== constructor) {
    log(
      "warn",
      builtinKeys.has(key)
        ? `lily: a type of yours replaces the built-in constructor ${key}, ` +
            "so values of the built-in type won't decode"
        : `lily: two types register the constructor ${key}, the later one wins`,
    );
  }
  constructorRegistry.set(key, constructor);
  if (builtin) builtinKeys.add(key);
  else builtinKeys.delete(key);
}

function registryKey(name, arity) {
  return `${name}/${arity}`;
}

function runWaiting() {
  const waiting = whenRegisteredQueue;
  whenRegisteredQueue = [];
  for (const thunk of waiting) {
    try {
      thunk();
    } catch (error) {
      log(
        "error",
        `lily: a callback waiting on module registration crashed: ${error}`,
      );
    }
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// keys still held by a built-in constructor
const builtinKeys = new Set();

const constructorRegistry = new Map();

// classes seen by reflectDataMessage, only data messages decode from it
const dataMessageRegistry = new Map();

let pendingModules = 0;

const reportedUnknown = new Set();

const requestedModules = new Set();

let whenRegisteredQueue = [];

registerClass(Ok, true);
registerClass(Error, true);
registerClass(Some, true);
registerClass(None, true);
