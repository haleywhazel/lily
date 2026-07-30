/**
 * ACTOR CELL FFI
 *
 * The JavaScript-only mutable box an actor_cell keeps its state in. On Erlang
 * the cell is an OTP process; on JavaScript there is no actor, so the Cell
 * hosts its state here, reachable again from any async callback.
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
