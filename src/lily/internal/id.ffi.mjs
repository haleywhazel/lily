/**
 * ID GENERATION (JAVASCRIPT)
 *
 * Random identifiers for the server's client IDs and the client's session
 * IDs. Uses the WebCrypto API off globalThis, which browsers, Node, Bun, and
 * Deno all provide, so nothing here imports a Node builtin. A static
 * `node:crypto` import would stop the whole client bundle loading in a
 * browser.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** A random lowercase hex string of `byteCount` bytes. */
export function randomHex(byteCount) {
  const bytes = new Uint8Array(byteCount);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
