/**
 * SERVER FFI (JAVASCRIPT)
 *
 * Client ID generation and the rescue combinator used to keep one bad frame
 * from tearing down the runtime.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error as GleamError } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Generate a cryptographically random 32-character hex client ID. */
export function generateClientId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Run the operation, capturing any thrown value as Error(description). */
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
