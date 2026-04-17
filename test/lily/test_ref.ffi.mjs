/** Mutable reference cell for JavaScript tests. */

export function newRef(initial) {
  return { value: initial };
}

export function getRef(ref) {
  return ref.value;
}

export function setRef(ref, value) {
  ref.value = value;
  return undefined;
}
