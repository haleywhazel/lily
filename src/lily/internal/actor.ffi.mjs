/**
 * ACTOR (JAVASCRIPT)
 *
 * Mutable box, try/catch and try/finally wrappers, timers, console logging.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error as GleamError } from "../../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function boxGet(box) {
  return box.value;
}

export function boxNew(value) {
  return { value };
}

export function boxSet(box, value) {
  box.value = value;
}

export function later(milliseconds, run) {
  setTimeout(run, milliseconds);
}

export function log(level, message) {
  const method = METHODS.has(level) ? level : "error";
  console[method](message);
}

export function protect(operation, cleanup) {
  try {
    return operation();
  } finally {
    cleanup();
  }
}

export function rescue(operation) {
  try {
    return new Ok(operation());
  } catch (exception) {
    const reason =
      exception instanceof globalThis.Error
        ? exception.message
        : String(exception);
    return new GleamError(reason);
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const METHODS = new Set(["debug", "error", "info", "warn"]);
