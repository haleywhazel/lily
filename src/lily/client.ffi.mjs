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
      if (isUnsafeAttribute(patch.name, patch.value)) {
        logLine(4, `lily: refused unsafe attribute "${patch.name}" in a live patch`);
      } else {
        element.setAttribute(patch.name, patch.value);
      }
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
  let serialiser = null;
  let sendFrameFn = null;
  let onConnectHook = null;
  let onDisconnectHook = null;
  let onReconnectHook = null;
  let connectedAtLeastOnce = false;
  let urlSetter = null;
  let popstateInstalled = false;
  let versionMismatchHook = null;
  let baselineVersion = null;

  // Per-target sequence tracking (in-memory, keyed by target key string)
  const sequences = new Map();

  // Per-mount-selector tracking so multi-mount works. Each mount call
  // routes its newly-allocated component IDs into the segment for its
  // selector, remounting the same selector tears down the prior segment
  // before the new render runs. Mounting a different selector appends.
  const mountSegments = new Map();
  let currentMountSegment = null;

  // Stack of active id-capture frames. Each frame collects the component IDs
  // registered while it is open, so renderChildAndCaptureIds can learn what a
  // child render added without snapshotting and diffing the whole registry.
  // A new ID is pushed onto every open frame, so an outer capture still sees
  // IDs registered by a nested capture (the old set-diff had the same reach).
  const idCaptureStack = [];

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
    getSerialiser() {
      return serialiser;
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
      // Feed every open capture frame so renderChildAndCaptureIds gets the
      // new IDs without diffing the registry.
      for (const frame of idCaptureStack) frame.push(id);
    },
    beginIdCapture() {
      const frame = [];
      idCaptureStack.push(frame);
      return frame;
    },
    endIdCapture() {
      idCaptureStack.pop();
    },
    unregisterComponent(id) {
      componentRegistry.delete(id);
      // Cheap, segments are small. Avoids leaking removed IDs into a
      // segment's teardown set.
      for (const segment of mountSegments.values()) segment.delete(id);
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
      // identity. The first one fires user.on_connect, subsequent ones
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
    setVersionMismatchHook(hook) {
      versionMismatchHook = hook;
    },
    handleVersion(hash) {
      // Remembers the first hash it sees as the baseline, every later one
      // (sent again on reconnect) is compared against it. A restart between
      // connections changes the hash, which is what surfaces a new deploy.
      if (baselineVersion === null) {
        baselineVersion = hash;
        return;
      }
      const mismatch = hash !== baselineVersion;
      if (mismatch && versionMismatchHook) versionMismatchHook();
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
    setSerialiser(s) {
      serialiser = s;
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

export function getSerialiser(runtime) {
  return runtime.getSerialiser();
}

export function handleClientId(runtime, clientId) {
  runtime.handleClientId(clientId);
}

export function handleVersion(runtime, hash) {
  runtime.handleVersion(hash);
}

export function initialNotify(runtime) {
  runtime.initialNotify();
}

// Turn ordinary same-origin <a href> left-clicks into warm client navigations.
// One idempotent document listener per runtime, everything that should stay a
// real navigation falls through untouched (see the ordered guards below).
export function installLinkInterception(runtime, within, optOut) {
  if (typeof document === "undefined") return;
  if (runtime.__linkInterceptionInstalled) return;
  runtime.__linkInterceptionInstalled = true;

  document.addEventListener("click", (event) => {
    // 1. another handler (e.g. a data-message binding) already claimed it
    if (event.defaultPrevented) return;
    // 2. only plain left-clicks
    if (event.button !== 0) return;
    // 3. modifier keys = open-in-new-tab / download / new-window intents
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    // 4. nearest ancestor anchor of the click target
    const target = event.target;
    const anchor = target && target.closest ? target.closest("a") : null;
    if (!anchor) return;
    // 5. an <a> with no href is a target/placeholder, not a link
    if (!anchor.hasAttribute("href")) return;
    // 6. scope: only intercept inside `within` (default whole document)
    if (within !== "document" && !anchor.closest(within)) return;
    // 7. explicit per-link opt-out (default data-lily-native)
    if (anchor.hasAttribute(optOut)) return;
    // 8. a target other than the current frame
    const anchorTarget = anchor.getAttribute("target");
    if (anchorTarget && anchorTarget !== "_self") return;
    // 9. downloads
    if (anchor.hasAttribute("download")) return;
    // 10. rel="external"
    const rel = anchor.getAttribute("rel");
    if (rel && rel.split(/\s+/).includes("external")) return;
    // 11. non-http(s) schemes: mailto:, tel:, sms:, javascript:
    if (anchor.protocol !== "http:" && anchor.protocol !== "https:") return;
    // 12. cross-origin links go to the network
    if (anchor.origin !== window.location.origin) return;
    // 13. in-page #fragment on the current path: let the browser scroll
    if (
      anchor.pathname === window.location.pathname &&
      anchor.search === window.location.search &&
      anchor.hash !== ""
    )
      return;

    // Accepted: warm navigation, no page reload.
    event.preventDefault();
    runtime.navigate(anchor.pathname + anchor.search + anchor.hash);
  });
}

// A full page navigation: leave the app entirely and let the server handle it.
export function load(_runtime, path) {
  if (typeof window !== "undefined") window.location.assign(path);
}

export function mergeLocals(incoming, current) {
  return mergeLocal(incoming, current);
}

export function navigate(runtime, path) {
  runtime.navigate(path);
}

export function recoverAfterReload(initial, migrate) {
  if (typeof sessionStorage === "undefined") return initial;
  const raw = sessionStorage.getItem(RELOAD_STASH_KEY);
  if (!raw) return initial;
  sessionStorage.removeItem(RELOAD_STASH_KEY);

  let stashed;
  try {
    stashed = JSON.parse(raw);
  } catch (_error) {
    return initial;
  }

  // The stash is undecoded (dev-only sessionStorage JSON, shape not
  // guaranteed), a migrate hook gets it as-is and decides for itself.
  if (migrate instanceof Some) return migrate[0](stashed, initial);

  const merged = Object.create(Object.getPrototypeOf(initial));
  for (const key of Object.keys(initial)) {
    const stashedValue = stashed[key];
    const isPrimitive =
      stashedValue === null || PRIMITIVE_TYPES.has(typeof stashedValue);
    merged[key] =
      key in stashed && isPrimitive && typeof stashedValue === typeof initial[key]
        ? stashedValue
        : initial[key];
  }
  return merged;
}

export function reload() {
  if (typeof window !== "undefined") window.location.reload();
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

export function setVersionMismatchHook(runtime, hook) {
  runtime.setVersionMismatchHook(hook);
}

export function setStore(runtime, store) {
  runtime.setStore(store);
}

// Guarded by a window flag so a re-run of the boot pipeline doesn't stack
// listeners.
export function installHotReload(runtime, url, reconnectMs, guardMs) {
  if (typeof window === "undefined") return;
  // Dev-only by host, so a production build never dials a dev socket.
  const host = window.location.hostname;
  if (host !== "localhost" && host !== "127.0.0.1") return;
  if (window.__lilyHotReloadInstalled) return;
  window.__lilyHotReloadInstalled = true;
  connectDevReload(runtime, url, reconnectMs, guardMs);
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

export function setSerialiser(runtime, serialiser) {
  runtime.setSerialiser(serialiser);
}

export function storeSendFrame(runtime, fn) {
  runtime.storeSendFrame(fn);
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/**
 * Reconnects on close. Every rebuild reloads the page, stashing the live model
 * first so recoverAfterReload can restore it on the other side. A storm guard
 * suppresses a reload that lands within a short window of the previous one, so
 * a misbehaving signal can never spin the page into a reload loop that would
 * hang or crash the browser. Normal edits are seconds apart and unaffected.
 */
function connectDevReload(runtime, url, reconnectMs, guardMs) {
  const target = url || devReloadUrl();
  const open = () => {
    const socket = new WebSocket(target);
    socket.onmessage = (event) => {
      let changed = [];
      try {
        changed = JSON.parse(event.data).changed || [];
      } catch (_error) {
        changed = [];
      }
      if (changed.length > 0) console.log("lily_dev: rebuilt", changed.join(", "));
      if (reloadedTooRecently(guardMs)) {
        console.warn("lily_dev: reload suppressed (storm guard)");
        return;
      }
      stashModelForReload(runtime.getModel());
      window.location.reload();
    };
    socket.onclose = () => setTimeout(open, reconnectMs);
  };
  open();
}

/**
 * True if a dev reload happened within the guard window. The timestamp lives in
 * sessionStorage so it survives the reload it is guarding against.
 */
function reloadedTooRecently(guardMs) {
  try {
    const now = new Date().getTime();
    const last = Number(sessionStorage.getItem(RELOAD_GUARD_KEY) || 0);
    if (now - last < guardMs) return true;
    sessionStorage.setItem(RELOAD_GUARD_KEY, String(now));
    return false;
  } catch (_error) {
    return false;
  }
}

/** Same-origin ws(s) URL for the dev-reload endpoint. */
// lily_dev hosts this socket itself rather than the app's own backend, on
// the page's port plus one by convention (lily_dev's own LILY_DEV_PORT
// defaults to match), so an app never has to add a dev-reload route.
function devReloadUrl() {
  const isSecure = window.location.protocol === "https:";
  const protocol = isSecure ? "wss:" : "ws:";
  const defaultPort = isSecure ? 443 : 80;
  const port = Number(window.location.port || defaultPort) + 1;
  return `${protocol}//${window.location.hostname}:${port}/dev-reload`;
}

/**
 * Best-effort, a stash that fails to write just means recoverAfterReload
 * finds nothing and returns the fresh initial model untouched.
 */
function stashModelForReload(model) {
  try {
    sessionStorage.setItem(RELOAD_STASH_KEY, JSON.stringify(model));
  } catch (_error) {
    // Ignore, nothing to recover on the other side.
  }
}

/**
 * Guardrail for live-patch attributes. Patch values commonly derive from the
 * server-driven model, which can carry other clients' input, so an on-handler
 * name or a script-scheme URL would be a scripting vector. Returns true for
 * those and lets everything else through. Embedded control characters and
 * whitespace are stripped first so an obfuscated scheme can't slip past,
 * matching how browsers normalise a URL scheme.
 */
function isUnsafeAttribute(name, value) {
  if (name.toLowerCase().startsWith("on")) return true;
  if (URL_ATTRIBUTES.has(name.toLowerCase())) {
    const scheme = String(value).replace(/[\u0000-\u0020]+/g, "").toLowerCase();
    if (UNSAFE_URL_SCHEME.test(scheme)) return true;
  }
  return false;
}

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

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// Attributes whose value the browser fetches or navigates to as a URL, where a
// script scheme is a code-execution vector. Data URLs are deliberately allowed
// through, since blocking them would break inline images, a common and benign
// pattern.
const URL_ATTRIBUTES = new Set([
  "href",
  "src",
  "xlink:href",
  "formaction",
  "action",
]);

// Schemes that execute script when placed in a URL attribute. Matched against
// the leading, control-and-whitespace-stripped scheme.
const UNSAFE_URL_SCHEME = /^(?:javascript|vbscript):/;

// JS types safe to copy straight across a reload, anything else (an object,
// an array, a class instance) needs a typed codec to migrate correctly.
const PRIMITIVE_TYPES = new Set(["string", "number", "boolean"]);

// sessionStorage key stashModelForReload writes and recoverAfterReload reads.
const RELOAD_STASH_KEY = "lily_dev_reload_state";

// Storm guard: reloads landing within the caller's guard window of the last
// one are suppressed, breaking any accidental reload loop before it can hang
// the page. The window itself comes from enable_hot_reload's config.
const RELOAD_GUARD_KEY = "lily_dev_last_reload";
