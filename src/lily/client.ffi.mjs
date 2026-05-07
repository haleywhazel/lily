/**
 * CLIENT RUNTIME
 *
 * This .mjs file handles the main runtime (apart from transport). It's the
 * browser-side entry point for Lily apps. Runtimes are closure-scoped, so in
 * the file you'll see that createRuntime creates a lot of functions which are
 * then re-exported. Most of the logic is within that function, with the
 * re-exporting not being very interesting.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error, toList } from "../gleam.mjs";
import { Some, None } from "../../gleam_stdlib/gleam/option.mjs";
import {
  SetText,
  SetAttribute,
  SetStyle,
  RemoveAttribute,
} from "./component.mjs";
import { log as logLine } from "./logging.ffi.mjs";
import { Local as StoreLocal } from "./store.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Apply patches to a specific element */
export function applyPatchesToElement(rootElement, patches) {
  for (const patch of patches) {
    const element =
      patch.target === ""
        ? rootElement
        : rootElement.querySelector(patch.target);

    if (!element) continue;

    if (patch instanceof SetText) {
      element.textContent = patch.value;
    } else if (patch instanceof SetAttribute) {
      element.setAttribute(patch.name, patch.value);
    } else if (patch instanceof SetStyle) {
      element.style.setProperty(patch.property, patch.value);
    } else if (patch instanceof RemoveAttribute) {
      element.removeAttribute(patch.name);
    }
  }
}

/** Create a specific Runtime */
export function createRuntime(store, apply) {
  let currentStore = store;
  const applyMessage = apply;
  let onMessageHook = null;
  let userMessageHook = null;
  let frameScheduled = false;
  let dirty = false;
  let currentTransport = null;
  let componentCounter = 0;
  const componentRegistry = new Map();
  let sessionConfig = null;
  let lastSession = null;
  const previousFieldValues = new Map();
  let clientIdSetter = null;
  let setConnectionStatusModel = null;
  let snapshotHook = null;
  let wiring = null;
  let sendFrameFn = null;

  // Per-target sequence tracking (in-memory; keyed by target key string)
  const sequences = new Map();

  function flushNotify() {
    const model = currentStore.model;
    for (const handler of componentRegistry.values()) {
      handler(model);
    }
  }

  function scheduleNotify() {
    if (frameScheduled) {
      dirty = true;
      return;
    }
    frameScheduled = true;
    flushNotify();
    requestAnimationFrame(() => {
      frameScheduled = false;
      if (dirty) {
        dirty = false;
        flushNotify();
      }
    });
  }

  function persistSessionChanges(session) {
    if (!sessionConfig) return;
    // Skip the per-field loop when the session slice didn't change at all,
    // by far the common case, since most messages don't touch the session.
    if (session === lastSession) return;
    lastSession = session;

    for (const field of sessionConfig.fields) {
      const serialised = JSON.stringify(field.get(session));
      if (previousFieldValues.get(field.key) === serialised) continue;
      previousFieldValues.set(field.key, serialised);
      try {
        localStorage.setItem(field.storageKey, serialised);
      } catch (error) {
        logLine(
          "EROR",
          `failed to persist session field "${field.key}": ${error}`,
        );
      }
    }
  }

  return {
    applyRemoteMessage(message) {
      currentStore = applyMessage(currentStore, message);
      if (userMessageHook) userMessageHook(message, currentStore.model);
      scheduleNotify();
    },
    callStoredSendFrame(frame) {
      if (sendFrameFn) sendFrameFn(frame);
    },
    clearRegistry() {
      componentRegistry.clear();
    },
    dispatchModel(model) {
      currentStore.model = model;
      scheduleNotify();
    },
    getComponentRegistry() {
      return componentRegistry;
    },
    getAllSequences() {
      // Return a Gleam List of [targetKey, sequence] 2-tuples (JS arrays)
      return toList(Array.from(sequences.entries()));
    },
    getModel() {
      return currentStore.model;
    },
    getWiring() {
      return wiring;
    },
    getSnapshotHook() {
      return snapshotHook ? new Some(snapshotHook) : new None();
    },
    initialNotify() {
      flushNotify();
    },
    nextComponentId() {
      return `c${componentCounter++}`;
    },
    registerComponent(id, handler) {
      componentRegistry.set(id, handler);
    },
    unregisterComponent(id) {
      componentRegistry.delete(id);
    },
    resetComponentCounter() {
      componentCounter = 0;
    },
    sendMessage(message) {
      currentStore = applyMessage(currentStore, message);
      if (onMessageHook) onMessageHook(message);
      if (userMessageHook) userMessageHook(message, currentStore.model);

      // Persist session changes if configured
      if (sessionConfig) {
        persistSessionChanges(sessionConfig.get(currentStore.model));
      }

      scheduleNotify();
    },
    sendViaTransport(bytes) {
      if (currentTransport) {
        currentTransport.send(bytes);
      }
    },
    setConnectionStatus(connected) {
      if (!setConnectionStatusModel) return;
      currentStore.model = setConnectionStatusModel(
        currentStore.model,
        connected,
      );
      scheduleNotify();
    },
    setClientIdSetter(set) {
      clientIdSetter = set;
    },
    handleClientId(clientId) {
      if (clientIdSetter === null) return;
      currentStore.model = clientIdSetter(currentStore.model, clientId);
      scheduleNotify();
    },
    setConnectionStatusConfig(set) {
      setConnectionStatusModel = set;
    },
    setInnerHtml(selector, html) {
      const element = document.querySelector(selector);
      if (element) {
        element.innerHTML = html;
      }
    },
    setLastSequenceForTarget(targetKey, sequence) {
      sequences.set(targetKey, sequence);
    },
    setModel(model) {
      currentStore.model = model;
    },
    setOnMessageHook(hook) {
      onMessageHook = hook;
    },
    setWiring(r) {
      wiring = r;
    },
    setSessionConfig(config) {
      sessionConfig = config;
      if (!sessionConfig) return;
      const session = sessionConfig.get(currentStore.model);
      lastSession = session;
      for (const field of sessionConfig.fields) {
        previousFieldValues.set(
          field.key,
          JSON.stringify(field.get(session)),
        );
      }
    },
    setStore(store) {
      currentStore = store;
    },
    setTransport(transport) {
      currentTransport = transport;
    },
    setUserMessageHook(hook) {
      userMessageHook = hook;
    },
    setSnapshotHook(hook) {
      snapshotHook = hook;
    },
    storeSendFrame(fn) {
      sendFrameFn = fn;
    },
  };
}

/** JavaScript's reference equality exported for Gleam */
export function referenceEqual(a, b) {
  return a === b;
}

/**
 * Wrap a render handler so it only runs when `select(model)` produces a
 * value `compare`-different from the previous one. Pure helper, no
 * runtime state captured, exported for `component.ffi.mjs`.
 */
export function createSelective(select, compare, handler) {
  let previous = undefined;
  let hasPrevious = false;
  return function (model) {
    const next = select(model);
    if (hasPrevious && compare(previous, next)) return;
    previous = next;
    hasPrevious = true;
    handler(next);
  };
}

// =============================================================================
// WRAPPER EXPORTS (for Gleam FFI bindings)
// =============================================================================

export function applyRemoteMessage(runtime, message) {
  runtime.applyRemoteMessage(message);
}

export function callStoredSendFrame(runtime, frame) {
  runtime.callStoredSendFrame(frame);
}

export function clearSession(prefix) {
  const keysToRemove = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key && key.startsWith(prefix)) {
      keysToRemove.push(key);
    }
  }
  for (const key of keysToRemove) {
    localStorage.removeItem(key);
  }
}

export function dispatchModel(runtime, model) {
  runtime.dispatchModel(model);
}

/**
 * Generate a random 32-character hex string for use as a client-side
 * session identifier.
 */
export function generateSessionId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function getAllSequences(runtime) {
  return runtime.getAllSequences();
}

export function getModel(runtime) {
  return runtime.getModel();
}

export function getSnapshotHook(runtime) {
  return runtime.getSnapshotHook();
}

export function getWiring(runtime) {
  return runtime.getWiring();
}

export function handleClientId(runtime, clientId) {
  runtime.handleClientId(clientId);
}

export function initialNotify(runtime) {
  runtime.initialNotify();
}

export function mergeLocals(incoming, current) {
  return mergeLocal(incoming, current);
}

export function readField(prefix, key) {
  try {
    const fullKey = prefix + key;
    const raw = localStorage.getItem(fullKey);
    if (raw === null) return new Error(undefined);
    const parsed = JSON.parse(raw);
    return new Ok(parsed);
  } catch (_error) {
    return new Error(undefined);
  }
}

export function sendMessage(runtime, message) {
  runtime.sendMessage(message);
}

export function sendViaTransport(runtime, bytes) {
  runtime.sendViaTransport(bytes);
}

export function setClientIdSetter(runtime, set) {
  runtime.setClientIdSetter(set);
}

export function setConnectionStatus(runtime, connected) {
  runtime.setConnectionStatus(connected);
}

export function setConnectionStatusConfig(runtime, set) {
  runtime.setConnectionStatusConfig(set);
}

export function setLastSequenceForTarget(runtime, targetKey, sequence) {
  runtime.setLastSequenceForTarget(targetKey, sequence);
}

export function setModel(runtime, model) {
  runtime.setModel(model);
}

export function setOnMessageHook(runtime, hook) {
  runtime.setOnMessageHook(hook);
}

export function setSessionConfig(runtime, persistence, prefix, get, set) {
  const fields = persistence.fields.toArray().map((field) => ({
    ...field,
    storageKey: prefix + field.key,
  }));
  runtime.setSessionConfig({ persistence, get, set, fields });
}

export function setSnapshotHook(runtime, hook) {
  runtime.setSnapshotHook(hook);
}

export function setStore(runtime, store) {
  runtime.setStore(store);
}

export function setTransport(runtime, transport) {
  runtime.setTransport(transport);
}

export function setUserMessageHook(runtime, hook) {
  runtime.setUserMessageHook(hook);
}

export function setWiring(runtime, wiring) {
  runtime.setWiring(wiring);
}

export function storeSendFrame(runtime, fn) {
  runtime.storeSendFrame(fn);
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/** Merges local values to the model */
function mergeLocal(incoming, current) {
  if (current instanceof StoreLocal) return current;
  if (!incoming || typeof incoming !== "object" || !incoming.withFields)
    return incoming;
  if (!current || typeof current !== "object") return incoming;
  const merged = Object.create(Object.getPrototypeOf(incoming));
  for (const key of Object.keys(incoming)) {
    merged[key] = mergeLocal(incoming[key], current[key]);
  }
  return merged;
}
