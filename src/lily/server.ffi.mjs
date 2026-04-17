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
  let state = initialState;

  return {
    /** Register a client connection */
    connect(clientId, send) {
      state = handleConnect(state, clientId, send);
    },

    /** Unregister a client connection */
    disconnect(clientId) {
      state = handleDisconnect(state, clientId);
    },

    /** Process an incoming message */
    incoming(clientId, text) {
      state = handleIncoming(state, clientId, text);
    },

    /** Set the message hook */
    setHook(hook) {
      state.on_message_hook = new Some(hook);
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

/** Call the incoming method on the server handle */
export function incoming(handle, clientId, text) {
  handle.incoming(clientId, text);
}

/** Call the setHook method on the server handle */
export function setHook(handle, hook) {
  handle.setHook(hook);
}
