/**
 * SERVER FFI (JAVASCRIPT)
 *
 * The rescue combinator used to keep one bad frame from tearing down the
 * runtime. Client IDs come from lily/internal/id on both targets.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error as GleamError } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

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
