/**
 * SERVER (JAVASCRIPT)
 *
 * Random hex for client and boot IDs, the client gauge, connection tokens, the
 * rate limit's clock.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function gaugeAdd(gauge, delta) {
  gauge.value += delta;
  return gauge.value;
}

export function gaugeRelease(gauge) {
  if (gauge.value > 0) gauge.value -= 1;
}

export function gaugeSet(gauge, value) {
  gauge.value = value;
}

export function gaugeValue(gauge) {
  return gauge.value;
}

export function monotonicMilliseconds() {
  return Math.floor(performance.now());
}

export function newGauge() {
  return { value: 0 };
}

export function randomHex(byteCount) {
  const bytes = new Uint8Array(byteCount);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export function uniqueInteger() {
  lastUniqueInteger += 1;
  return lastUniqueInteger;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

let lastUniqueInteger = 0;
