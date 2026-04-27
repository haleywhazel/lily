/**
 * PUB_SUB FFI (JAVASCRIPT)
 *
 * Closure-based mutable state for the JavaScript pubsub. Mirrors the
 * pattern used by server.ffi.mjs — the FFI encapsulates state mutation and
 * delegates all logic to the Gleam logic functions passed at creation time.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Create a pubsub instance with closure-scoped mutable state. */
export function createPubSub(
  initialState,
  handleRegister,
  handleUnregister,
  handleSubscribe,
  handleUnsubscribe,
  handleBroadcast,
) {
  let state = initialState;

  return {
    register(clientId, send) {
      state = handleRegister(state, clientId, send);
    },

    unregister(clientId) {
      state = handleUnregister(state, clientId);
    },

    subscribe(clientId, topic) {
      state = handleSubscribe(state, clientId, topic);
    },

    unsubscribe(clientId, topic) {
      state = handleUnsubscribe(state, clientId, topic);
    },

    broadcast(topic, bytes, exclude) {
      state = handleBroadcast(state, topic, bytes, exclude);
    },
  };
}

// =============================================================================
// WRAPPER EXPORTS
// =============================================================================

export function register(handle, clientId, send) {
  handle.register(clientId, send);
}

export function unregister(handle, clientId) {
  handle.unregister(clientId);
}

export function subscribe(handle, clientId, topic) {
  handle.subscribe(clientId, topic);
}

export function unsubscribe(handle, clientId, topic) {
  handle.unsubscribe(clientId, topic);
}

export function broadcast(handle, topic, bytes, exclude) {
  handle.broadcast(topic, bytes, exclude);
}
