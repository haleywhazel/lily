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

/** Register every custom type test_support defines. Idempotent. */
export function registerFixtures() {
  registerModule(fixtures);
}
