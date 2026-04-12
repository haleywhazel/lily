/**
 * TRANSPORT AUTO-SERIALISER (JAVASCRIPT)
 *
 * Provides automatic JSON serialisation for Gleam custom types using a
 * positional encoding scheme. The wire format is:
 *
 *   {"_":"ConstructorName","0":field0,"1":field1,...}
 *
 * Primitives (Int, Float, String, Bool, Nil) and Lists encode naturally
 * to JSON. Custom types are encoded as objects with a "_" tag and numbered
 * fields matching constructor parameter order.
 *
 * The constructor registry is built automatically from:
 * 1. Encode-time caching — when encoding a value, cache its constructor
 * 2. Initial model walk — recursively walk the initial model to find types
 * 3. Manual registration — `register([...])` for server-only message types
 */

// =============================================================================
// CONSTRUCTOR REGISTRY
// =============================================================================

import { Ok, Error, NonEmpty, Empty } from "../gleam.mjs";

/**
 * Maps constructor name → constructor function.
 * Built automatically during encode and model walk.
 */
const constructorRegistry = new Map();

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/**
 * Automatically encode any Gleam value to JSON using positional fields.
 * Caches constructors during encoding to build the registry.
 */
export function autoEncode(value) {
  // Primitives
  if (value === null || value === undefined) return null;
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value;
  if (typeof value === "number") return value;

  // List (Gleam lists are built as nested objects with `head` and `tail`)
  if (value && typeof value === "object" && "head" in value && "tail" in value) {
    const result = [];
    let current = value;
    while (current && current.head !== undefined) {
      result.push(autoEncode(current.head));
      current = current.tail;
    }
    return result;
  }

  // Custom type (has a constructor property)
  if (value && typeof value === "object" && value.constructor) {
    const ctor = value.constructor;
    const name = ctor.name;

    // Cache constructor for decoding
    if (!constructorRegistry.has(name)) {
      constructorRegistry.set(name, ctor);
    }

    // Build JSON object with tag and positional fields.
    // Gleam JS classes store fields as named properties (e.g. this.text = text),
    // not numeric indices. Object.keys preserves constructor assignment order.
    const encoded = { _: name };
    Object.keys(value).forEach((field, index) => {
      encoded[String(index)] = autoEncode(value[field]);
    });

    return encoded;
  }

  // Fallback for plain objects (shouldn't happen in normal Gleam code)
  return value;
}

/**
 * Automatically decode JSON to a Gleam value using the constructor registry.
 * Returns Ok(value) on success, Error(undefined) on failure.
 * This is the exported function used by decode.new_primitive_decoder.
 */
export function autoDecode(json) {
  try {
    return new Ok(autoDecodeInner(json));
  } catch (_e) {
    return new Error(undefined);
  }
}

/**
 * Inner recursive decode — returns raw value or throws on unknown constructor.
 */
function autoDecodeInner(json) {
  // Primitives
  if (json === null) return undefined; // Gleam's Nil
  if (typeof json === "boolean") return json;
  if (typeof json === "string") return json;
  if (typeof json === "number") return json;

  // Array → Gleam List
  if (Array.isArray(json)) {
    // Build Gleam list from right to left using proper NonEmpty/Empty instances
    let result = new Empty();
    for (let i = json.length - 1; i >= 0; i--) {
      const decodedItem = autoDecodeInner(json[i]);
      result = new NonEmpty(decodedItem, result);
    }
    return result;
  }

  // Custom type (object with "_" tag)
  if (json && typeof json === "object" && "_" in json) {
    const tag = json._;
    const ctor = constructorRegistry.get(tag);

    if (!ctor) {
      throw new globalThis.Error(
        `Unknown constructor: ${tag}. Did you forget to call transport.register()?`,
      );
    }

    // Collect positional fields
    const fields = [];
    let fieldIndex = 0;
    while (String(fieldIndex) in json) {
      fields.push(autoDecodeInner(json[String(fieldIndex)]));
      fieldIndex++;
    }

    // Instantiate using the constructor
    return new ctor(...fields);
  }

  // Fallback
  return json;
}

/**
 * Register constructors by walking a list of example values.
 * Extracts constructor functions and adds them to the registry.
 */
export function register(constructors) {
  // Gleam lists are linked lists ({head, tail}), not JS arrays
  let current = constructors;
  while (current && current.head !== undefined) {
    walkAndRegister(current.head);
    current = current.tail;
  }
}

/**
 * Walk the initial model recursively to register all nested constructors.
 * Called automatically from client.connect.
 */
export function registerModel(model) {
  walkAndRegister(model);
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/**
 * Recursively walk a value and register all custom type constructors found.
 */
function walkAndRegister(value) {
  // Skip primitives and null/undefined
  if (
    value === null ||
    value === undefined ||
    typeof value === "boolean" ||
    typeof value === "string" ||
    typeof value === "number"
  ) {
    return;
  }

  // Handle Lists (Gleam lists are nested {head, tail} objects)
  if (value && typeof value === "object" && "head" in value && "tail" in value) {
    let current = value;
    while (current && current.head !== undefined) {
      walkAndRegister(current.head);
      current = current.tail;
    }
    return;
  }

  // Handle custom types
  if (value && typeof value === "object" && value.constructor) {
    const ctor = value.constructor;
    const name = ctor.name;

    // Skip built-in types
    if (name === "Object" || name === "Array") return;

    // Register constructor
    if (!constructorRegistry.has(name)) {
      constructorRegistry.set(name, ctor);
    }

    // Recursively walk fields (Gleam JS stores fields by name, not numeric index)
    for (const field of Object.keys(value)) {
      walkAndRegister(value[field]);
    }
  }
}
