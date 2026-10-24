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

export function cancelLater(timer) {
  clearTimeout(timer);
}

export function later(milliseconds, run) {
  return setTimeout(run, milliseconds);
}

export function log(level, message) {
  const method = METHODS.has(level) ? level : "error";
  console[method](message);
}

/** `Ok(held since)` to log, `Error` to hold this one back. */
export function logAllowance(key) {
  const now = Date.now();
  const slot = logAllowances.get(key);
  if (slot && now - slot.last < LOG_WINDOW_MILLISECONDS) {
    slot.held += 1;
    return new GleamError(undefined);
  }
  logAllowances.set(key, { last: now, held: 0 });
  return new Ok(slot ? slot.held : 0);
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
    return new GleamError(reasonOf(exception));
  }
}

// =============================================================================
// FUNCTIONS
// =============================================================================

// one line, bounded, a hostile frame can make a reason huge
function reasonOf(exception) {
  let text;
  try {
    text =
      exception instanceof globalThis.Error
        ? exception.message
        : String(exception);
  } catch (_error) {
    text = "unprintable exception";
  }
  const line = text.replace(/\s+/g, " ");
  return line.length > REASON_LIMIT
    ? line.slice(0, REASON_LIMIT) + "..."
    : line;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const LOG_WINDOW_MILLISECONDS = 10_000;

// key to the time its last line went out and how many were held since
const logAllowances = new Map();

const METHODS = new Set(["debug", "error", "info", "warn"]);

const REASON_LIMIT = 1000;
