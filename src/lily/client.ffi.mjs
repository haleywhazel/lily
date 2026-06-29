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

import { Ok, Error, toList, BitArray } from "../gleam.mjs";
import { Some, None } from "../../gleam_stdlib/gleam/option.mjs";
import { parse as parseUri } from "../../gleam_stdlib/gleam/uri.mjs";
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
  let onConnectHook = null;
  let onDisconnectHook = null;
  let onReconnectHook = null;
  let connectedAtLeastOnce = false;
  let urlSetter = null;
  let popstateInstalled = false;

  // Per-target sequence tracking (in-memory; keyed by target key string)
  const sequences = new Map();

  // Per-mount-selector tracking so multi-mount works. Each mount call
  // routes its newly-allocated component IDs into the segment for its
  // selector; remounting the same selector tears down the prior segment
  // before the new render runs. Mounting a different selector appends.
  const mountSegments = new Map();
  let currentMountSegment = null;

  // Pending transition exits, keyed by element. Lets the each/each_live
  // reconciler cancel an in-flight exit when the same key reappears
  // before the duration elapses.
  const pendingExits = new Map();

  // Bindings collected during render that need to fire after the
  // innerHTML pass. Pushed to by renderDecorated (in component.ffi.mjs);
  // drained by renderTree. The `collectingBindings` flag is toggled
  // off by renderEach / renderEachLive / renderSwitch around their
  // per-item / per-case child renders, so events declared inside those
  // bodies are ignored by design.
  let pendingBindings = [];
  let collectingBindings = true;
  // Stashed at mount so renderDecorated can pass it to the binding
  // closures (which take a Runtime, not just the handle).
  let runtimeRef = null;

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

  function applyUrlFromLocation() {
    if (!urlSetter || typeof window === "undefined") return;
    const parsed = parseUri(window.location.href);
    if (!(parsed instanceof Ok)) return;
    currentStore.model = urlSetter(currentStore.model, parsed[0]);
    scheduleNotify();
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
      // Record into the active mount segment so this mount knows which
      // IDs belong to it, used to tear down on re-mount of the same
      // selector.
      if (currentMountSegment) currentMountSegment.add(id);
    },
    unregisterComponent(id) {
      componentRegistry.delete(id);
      // Cheap, segments are small. Avoids leaking removed IDs into a
      // segment's teardown set.
      for (const segment of mountSegments.values()) segment.delete(id);
    },
    resetComponentCounter() {
      componentCounter = 0;
    },
    startMountSegment(selector) {
      // Tear down the prior segment for this selector if any, so a
      // re-mount on the same selector replaces rather than accumulates.
      const prior = mountSegments.get(selector);
      if (prior) {
        for (const id of prior) componentRegistry.delete(id);
      }
      const fresh = new Set();
      mountSegments.set(selector, fresh);
      currentMountSegment = fresh;
    },
    endMountSegment() {
      // Returns the IDs that were registered during this mount so the
      // caller can trigger their handlers once with the initial model.
      // Clearing the tracker stops subsequent renders from leaking into
      // this segment.
      const ids = currentMountSegment
        ? Array.from(currentMountSegment)
        : [];
      currentMountSegment = null;
      return ids;
    },
    registerPendingExit(element, controller) {
      pendingExits.set(element, controller);
    },
    setRuntime(runtime) {
      runtimeRef = runtime;
    },
    getRuntime() {
      return runtimeRef;
    },
    queueBinding(fire) {
      if (collectingBindings) pendingBindings.push(fire);
    },
    drainBindings() {
      const queued = pendingBindings;
      pendingBindings = [];
      for (const fire of queued) fire();
    },
    suppressBindings() {
      const was = collectingBindings;
      collectingBindings = false;
      return was;
    },
    restoreBindings(was) {
      collectingBindings = was;
    },
    cancelPendingExit(element) {
      const controller = pendingExits.get(element);
      if (controller) {
        controller.abort();
        pendingExits.delete(element);
      }
    },
    clearPendingExit(element) {
      pendingExits.delete(element);
    },
    getPendingExit(element) {
      return pendingExits.get(element);
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
      // Connected is the server-acknowledged signal that the client has an
      // identity. The first one fires user.on_connect; subsequent ones
      // (after a reconnect) don't, since the user already saw on_connect
      // and any reconnect lifecycle is delivered via on_reconnect.
      if (!connectedAtLeastOnce) {
        connectedAtLeastOnce = true;
        if (onConnectHook) onConnectHook(clientId);
      }
      if (clientIdSetter === null) return;
      currentStore.model = clientIdSetter(currentStore.model, clientId);
      scheduleNotify();
    },
    fireReconnectHook() {
      // Transport on_reconnect fires on every WebSocket open, including the
      // first. Only fire the user hook on subsequent opens, not the first
      // (the first one is delivered via on_connect once the server
      // acknowledges with a Connected frame).
      if (connectedAtLeastOnce && onReconnectHook) onReconnectHook();
    },
    fireDisconnectHook() {
      if (onDisconnectHook) onDisconnectHook();
    },
    setOnConnectHook(hook) {
      onConnectHook = hook;
    },
    setOnDisconnectHook(hook) {
      onDisconnectHook = hook;
    },
    setOnReconnectHook(hook) {
      onReconnectHook = hook;
    },
    setUrlSetter(set) {
      urlSetter = set;
      // popstate fires when the user uses the browser back/forward buttons.
      // pushState/replaceState don't emit popstate themselves, so navigate
      // and replace re-read window.location explicitly after the history op.
      if (!popstateInstalled && typeof window !== "undefined") {
        popstateInstalled = true;
        window.addEventListener("popstate", () => applyUrlFromLocation());
      }
      // Read the initial URL on attach so the model reflects the page the
      // user landed on.
      applyUrlFromLocation();
    },
    navigate(path) {
      if (typeof window === "undefined") return;
      window.history.pushState({}, "", path);
      applyUrlFromLocation();
    },
    replace(path) {
      if (typeof window === "undefined") return;
      window.history.replaceState({}, "", path);
      applyUrlFromLocation();
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

export function fireDisconnectHook(runtime) {
  runtime.fireDisconnectHook();
}

export function fireReconnectHook(runtime) {
  runtime.fireReconnectHook();
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

export function navigate(runtime, path) {
  runtime.navigate(path);
}

export function replace(runtime, path) {
  runtime.replace(path);
}

export function readEmbeddedSnapshot() {
  if (typeof document === "undefined") return new Error(undefined);
  const element = document.getElementById("lily-snapshot");
  if (!element) return new Error(undefined);
  const text = element.textContent;
  if (text === null || text === "") return new Error(undefined);
  const bytes = new TextEncoder().encode(text);
  return new Ok(new BitArray(bytes, bytes.length * 8, 0));
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

export function setOnConnectHook(runtime, hook) {
  runtime.setOnConnectHook(hook);
}

export function setOnDisconnectHook(runtime, hook) {
  runtime.setOnDisconnectHook(hook);
}

export function setOnMessageHook(runtime, hook) {
  runtime.setOnMessageHook(hook);
}

export function setOnReconnectHook(runtime, hook) {
  runtime.setOnReconnectHook(hook);
}

export function setUrlSetter(runtime, set) {
  runtime.setUrlSetter(set);
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
