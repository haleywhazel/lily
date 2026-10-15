/**
 * SERVER (JAVASCRIPT)
 *
 * Random hex for client and boot IDs.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function randomHex(byteCount) {
  const bytes = new Uint8Array(byteCount);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
