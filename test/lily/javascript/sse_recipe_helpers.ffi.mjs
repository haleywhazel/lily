/**
 * SSE RECIPE HELPERS
 *
 * Test-only fetch recorder and mock EventSource peeks. The recipe's own FFI
 * is sse_recipe_test.ffi.mjs.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** readyState, -1 with no source. */
export function eventSourceReadyState(source) {
  if (source === null || source === undefined) return -1;
  return source.readyState;
}

/** Hands each POST to `onPost`. */
export function recordFetch(onPost) {
  globalThis.fetch = (url, options) => {
    onPost(url, options.body);
    return Promise.resolve({ ok: true, status: 200 });
  };
}

export function resetFetch() {
  globalThis.fetch = originalFetch;
}

/** One message stamped with an SSE event id. */
export function triggerMessageWithId(source, data, id) {
  if (source.onmessage) source.onmessage({ data, lastEventId: id });
}

export function urlOf(source) {
  return source.url;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const originalFetch = globalThis.fetch;
