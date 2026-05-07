/**
 * REFERENCE FFI
 *
 * Minimal mutable cell for hosting Gleam state across asynchronous
 * boundaries on JavaScript. Mirrors the test-only test_ref helper but
 * lives in the library proper so server.gleam and topic.gleam can host
 * their per-instance state without each one rolling its own closure.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Read the current value held by the reference. */
export function get(reference) {
  return reference.value;
}

/** Allocate a new reference holding the given initial value. */
export function make(value) {
  return { value };
}

/** Replace the value held by the reference. */
export function set(reference, value) {
  reference.value = value;
}
