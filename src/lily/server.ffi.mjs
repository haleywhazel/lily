/**
 * SERVER FFI (JAVASCRIPT)
 *
 * Closure-based mutable state for the JavaScript server implementation.
 * The FFI encapsulates state mutation and calls Gleam logic functions passed
 * at creation time. This matches the pattern used by client.ffi.mjs.
 *
 * While having a mutable state is impure and doesn't feel great to use, this
 * allows for the public API to remain the same for both Erlang and JavaScript
 * targets.
 */

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

import { Some } from "../../gleam_stdlib/gleam/option.mjs";

/** Create server with closure-scoped mutable state */
export function createServer(
  initialState,
  handleConnect,
  handleDisconnect,
  handleIncoming,
) {
  // Closure-scoped state (not module-level, allows multiple instances)
  // Set to null on stop() — all methods short-circuit in that case.
  let state = initialState;

  return {
    /** Register a client connection */
    connect(clientId, send) {
      if (state === null) return;
      state = handleConnect(state, clientId, send);
    },

    /** Unregister a client connection */
    disconnect(clientId) {
      if (state === null) return;
      state = handleDisconnect(state, clientId);
    },

    /** Process an incoming message */
    incoming(clientId, bytes) {
      if (state === null) return;
      state = handleIncoming(state, clientId, bytes);
    },

    /** Set the message hook */
    setHook(hook) {
      if (state === null) return;
      state.on_message_hook = new Some(hook);
    },

    /** Stop the server — releases state. Further calls are no-ops. */
    stop() {
      state = null;
    },
  };
}

// =============================================================================
// WRAPPER EXPORTS
// =============================================================================

/** Call the connect method on the server handle */
export function connect(handle, clientId, send) {
  handle.connect(clientId, send);
}

/** Call the disconnect method on the server handle */
export function disconnect(handle, clientId) {
  handle.disconnect(clientId);
}

/** Generate a cryptographically random 32-character hex client ID */
export function generateClientId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Call the incoming method on the server handle */
export function incoming(handle, clientId, bytes) {
  handle.incoming(clientId, bytes);
}

/** Call the setHook method on the server handle */
export function setHook(handle, hook) {
  handle.setHook(hook);
}

/** Call the stop method on the server handle */
export function stop(handle) {
  handle.stop();
}
