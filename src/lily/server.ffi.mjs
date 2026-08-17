/**
 * SERVER FFI (JAVASCRIPT)
 *
 * Mostly rescue stuff for JS backend
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error as GleamError } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

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
