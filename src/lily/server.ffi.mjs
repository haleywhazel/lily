/**
 * SERVER FFI (JAVASCRIPT)
 *
 * Browser-API helper for the JS server target. State management is handled
 * by lily/internal/reference; only browser-API helpers live here.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Generate a cryptographically random 32-character hex client ID. */
export function generateClientId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
