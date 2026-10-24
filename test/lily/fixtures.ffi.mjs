/**
 * TEST FIXTURES (JAVASCRIPT)
 *
 * Registers the fixture types so decoding never depends on test order.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { registerModule } from "../lily/internal/codec.ffi.mjs";
import * as fixtures from "./test_support.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** A string Gleam can't write, half of a surrogate pair. */
export function loneSurrogate() {
  return "\ud800";
}

/** Register every custom type test_support defines. Idempotent. */
export function registerFixtures() {
  registerModule(fixtures);
}
