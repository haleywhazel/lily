/**
 * SERVER FFI (JAVASCRIPT)
 *
 * Currently only has client ID generation and this could change, there may be
 * other Gleam packages that can replace this.
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
