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

import { Ok, Error } from "../gleam.mjs";
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
  const previousFieldValues = new Map();
  let connectionStatusConfig = null;

  function flushNotify() {
    const model = currentStore.model;
    for (const handler of componentRegistry.values()) {
      handler(model);
    }
  }

  function scheduleNotify() {
    dirty = true;
    if (!frameScheduled) {
      frameScheduled = true;
      dirty = false;
      flushNotify();
      requestAnimationFrame(() => {
        frameScheduled = false;
        if (dirty) {
          dirty = false;
          flushNotify();
        }
      });
    }
  }

  function persistSessionChanges(session) {
    if (!sessionConfig) return;
    const fields = sessionConfig.fields;
    const prefix = "lily_session_";

    for (const field of fields) {
      // Serialise first — JSON values are objects, string comparison is stable
      const serialised = JSON.stringify(field.get(session));
      const previous = previousFieldValues.get(field.key);
      if (previous !== undefined && previous === serialised) continue;
      previousFieldValues.set(field.key, serialised);
      const key = prefix + field.key;
      try {
        localStorage.setItem(key, serialised);
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
      scheduleNotify();
    },
    clearRegistry() {
      componentRegistry.clear();
    },
    createSelective(selector, select, compare, handler) {
      let previous = undefined;
      let hasPrevious = false;
      return function (model) {
        const next = select(model);
        if (hasPrevious && compare(previous, next)) return;
        previous = next;
        hasPrevious = true;
        handler(next);
      };
    },
    dispatchModel(model) {
      currentStore.model = model;
      scheduleNotify();
    },
    getComponentRegistry() {
      return componentRegistry;
    },
    getLastSequence() {
      const raw = localStorage.getItem(STORAGE_KEY_SEQUENCE);
      return raw ? parseInt(raw, 10) || 0 : 0;
    },
    getModel() {
      return currentStore.model;
    },
    initialNotify() {
      flushNotify();
    },
    nextComponentId() {
      return `c${componentCounter++}`;
    },
    referenceEqual(a, b) {
      return a === b;
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
      if (!connectionStatusConfig) return;
      const updatedModel = connectionStatusConfig.set(
        currentStore.model,
        connected,
      );
      currentStore.model = updatedModel;
      scheduleNotify();
    },
    setConnectionStatusConfig(get, set) {
      connectionStatusConfig = { get, set };
    },
    setInnerHtml(selector, html) {
      const element = document.querySelector(selector);
      if (element) {
        element.innerHTML = html;
      }
    },
    setLastSequence(sequence) {
      localStorage.setItem(STORAGE_KEY_SEQUENCE, String(sequence));
    },
    setModel(model) {
      currentStore.model = model;
    },
    setOnMessageHook(hook) {
      onMessageHook = hook;
    },
    setSessionConfig(config) {
      sessionConfig = config;
      // Seed per-field previous values so the first update only writes changes
      if (sessionConfig) {
        const session = sessionConfig.get(currentStore.model);
        for (const field of sessionConfig.fields) {
          previousFieldValues.set(
            field.key,
            JSON.stringify(field.get(session)),
          );
        }
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
  };
}

/** JavaScript's reference equality exported for Gleam */
export function referenceEqual(a, b) {
  return a === b;
}

// =============================================================================
// WRAPPER EXPORTS (for Gleam FFI bindings)
// =============================================================================

export function applyRemoteMessage(runtime, message) {
  runtime.applyRemoteMessage(message);
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

export function getLastSequence(runtime) {
  return runtime.getLastSequence();
}

export function getModel(runtime) {
  return runtime.getModel();
}

export function initialNotify(runtime) {
  runtime.initialNotify();
}

export function mergeLocalAndDispatch(runtime, incoming) {
  const current = runtime.getModel();
  const merged = mergeLocal(current, incoming);
  runtime.dispatchModel(merged);
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

export function setConnectionStatus(runtime, connected) {
  runtime.setConnectionStatus(connected);
}

export function setConnectionStatusConfig(runtime, get, set) {
  runtime.setConnectionStatusConfig(get, set);
}

export function setLastSequence(runtime, sequence) {
  runtime.setLastSequence(sequence);
}

export function setModel(runtime, model) {
  runtime.setModel(model);
}

export function setOnMessageHook(runtime, hook) {
  runtime.setOnMessageHook(hook);
}

export function setSessionConfig(runtime, persistence, get, set) {
  const fields = persistence.fields.toArray();
  runtime.setSessionConfig({
    persistence,
    get,
    set,
    fields,
  });
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

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// Sequence tracking at the protocol-level
const STORAGE_KEY_SEQUENCE = "lily_last_sequence";

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/** Merges local values to the model */
function mergeLocal(current, incoming) {
  if (current instanceof StoreLocal) return current;
  if (!incoming || typeof incoming !== "object" || !incoming.withFields)
    return incoming;
  if (!current || typeof current !== "object") return incoming;
  const merged = Object.create(Object.getPrototypeOf(incoming));
  for (const key of Object.keys(incoming)) {
    merged[key] = mergeLocal(current[key], incoming[key]);
  }
  return merged;
}
