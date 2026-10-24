/**
 * BROWSER FFI
 *
 * Page-level helpers. No runtime access, Gleam hands in closures.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Error, List, Ok } from "../gleam.mjs";
import { parse as parseUri } from "../../gleam_stdlib/gleam/uri.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Blocked storage throws on access, it's left alone. */
export function clearStored(prefix) {
  try {
    if (typeof localStorage === "undefined") return;
    const keys = [];
    for (let index = 0; index < localStorage.length; index++) {
      const key = localStorage.key(index);
      if (key && key.startsWith(prefix)) keys.push(key);
    }
    for (const key of keys) localStorage.removeItem(key);
  } catch (_error) {
    // storage blocked, nothing to clear
  }
}

export function forgetProtocolReload() {
  try {
    sessionStorage.removeItem(PROTOCOL_RELOAD_KEY);
  } catch (_error) {
    // storage unavailable, nothing was recorded
  }
}

/** Listening only while a guard holds, a standing one blocks the bfcache. */
export function holdLeaveGuard(guard, holds) {
  if (typeof window === "undefined") return;
  if (holds) holdingGuards.add(guard);
  else holdingGuards.delete(guard);
  if (holdingGuards.size > 0) {
    window.addEventListener("beforeunload", askBeforeLeaving);
  } else {
    window.removeEventListener("beforeunload", askBeforeLeaving);
  }
}

/** A window flag stops a re-boot stacking sockets. */
export function installHotReload(
  getModel,
  reconnectMilliseconds,
  guardMilliseconds,
) {
  if (typeof window === "undefined") return;
  if (window.__lilyHotReloadInstalled) return;
  window.__lilyHotReloadInstalled = true;
  connectDevReload(
    getModel,
    devReloadUrl(),
    reconnectMilliseconds,
    guardMilliseconds,
  );
}

export function installLinkInterception(owner, navigate, within, optOut) {
  if (typeof document === "undefined") return;
  if (intercepting.has(owner)) return;
  intercepting.add(owner);

  document.addEventListener("click", (event) => {
    // already claimed
    if (event.defaultPrevented) return;
    // left-clicks only
    if (event.button !== 0) return;
    // modifiers mean new tab, window or download
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
      return;
    }
    // the nearest link on the composed path, inside a shadow root or around
    // one, a shadow root retargets `event.target` to its host
    const path = event.composedPath?.() ?? [event.target];
    const anchor = path.find((node) => node?.tagName === "A") ?? null;
    if (!anchor) return;
    // no href, a placeholder
    if (!anchor.hasAttribute("href")) return;
    if (within !== "document" && !closestSafely(anchor, within)) return;
    if (anchor.hasAttribute(optOut)) return;
    const anchorTarget = anchor.getAttribute("target");
    if (anchorTarget && anchorTarget !== "_self") return;
    if (anchor.hasAttribute("download")) return;
    const rel = anchor.getAttribute("rel");
    if (rel && rel.toLowerCase().split(/\s+/).includes("external")) return;
    // mailto, tel, sms and javascript schemes
    if (anchor.protocol !== "http:" && anchor.protocol !== "https:") return;
    if (anchor.origin !== window.location.origin) return;
    // in-page fragment, let the browser scroll
    if (
      anchor.pathname === window.location.pathname &&
      anchor.search === window.location.search &&
      anchor.hash !== ""
    )
      return;

    event.preventDefault();
    navigate(anchor.pathname + anchor.search + anchor.hash);
  });
}

export function listenLocation(apply) {
  if (typeof window === "undefined") return;
  onPage(window, "popstate", () => apply());
  onPage(window, LOCATION_EVENT, () => apply());
}

export function listenNetwork(runtime, apply) {
  if (typeof window === "undefined") return runtime;
  const report = () => apply(navigator.onLine !== false);
  onPage(window, "online", report);
  onPage(window, "offline", report);
  report();
  return runtime;
}

// at most once a frame while the window is dragged
export function listenViewport(runtime, apply) {
  if (typeof window === "undefined") return runtime;
  let pending = false;
  const report = () => {
    pending = false;
    apply([window.innerWidth, window.innerHeight]);
  };
  onPage(window, "resize", () => {
    if (pending) return;
    pending = true;
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(report);
    } else {
      setTimeout(report, 0);
    }
  });
  report();
  return runtime;
}

export function listenVisibility(runtime, apply) {
  if (typeof document === "undefined") return runtime;
  const report = () => apply(document.visibilityState !== "hidden");
  onPage(document, "visibilitychange", report);
  report();
  return runtime;
}

/** This origin only, `javascript:` and other sites are refused. */
export function load(path) {
  if (typeof window === "undefined") return;
  const url = sameOriginUrl(path);
  if (!url) {
    log(
      "warn",
      `lily: browser.load refused ${JSON.stringify(path)}, it only loads ` +
        "pages on this origin, use browser.load_external for another site",
    );
    return;
  }
  window.location.assign(url.href);
}

/** Any origin, but only an absolute http or https URL. */
export function loadExternal(address) {
  if (typeof window === "undefined") return;
  let url;
  try {
    url = new URL(address);
  } catch (_error) {
    url = null;
  }
  if (!url || !WEB_PROTOCOLS.has(url.protocol)) {
    log(
      "warn",
      `lily: browser.load_external refused ${JSON.stringify(address)}, it ` +
        "only loads an absolute http or https URL",
    );
    return;
  }
  window.location.assign(url.href);
}

export function navigate(path) {
  changeHistory("pushState", path);
}

export function newLeaveGuard() {
  return {};
}

export function readLocation() {
  if (typeof window === "undefined") return new Error(undefined);
  return parseUri(window.location.href);
}

export function readStored(key) {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? new Error(undefined) : new Ok(raw);
  } catch (_error) {
    return new Error(undefined);
  }
}

/** Adopts only same-typed top-level primitives, the rest stay fresh. */
export function recoverAfterReload(initial) {
  // only a record's fields, a tuple, list or number model starts fresh
  if (!isPlainRecord(initial)) return initial;
  let raw;
  try {
    if (typeof sessionStorage === "undefined") return initial;
    raw = sessionStorage.getItem(RELOAD_STASH_KEY);
    if (!raw) return initial;
    sessionStorage.removeItem(RELOAD_STASH_KEY);
  } catch (_error) {
    return initial;
  }

  let stashed;
  try {
    stashed = JSON.parse(raw);
  } catch (_error) {
    return initial;
  }
  if (
    stashed === null ||
    typeof stashed !== "object" ||
    Array.isArray(stashed)
  ) {
    return initial;
  }

  const merged = Object.create(Object.getPrototypeOf(initial));
  for (const key of Object.keys(initial)) {
    const stashedValue = stashed[key];
    const isPrimitive = PRIMITIVE_TYPES.has(typeof stashedValue);
    const sameType = typeof stashedValue === typeof initial[key];
    merged[key] =
      key in stashed && isPrimitive && sameType ? stashedValue : initial[key];
  }
  return merged;
}

export function reload() {
  if (typeof window !== "undefined") window.location.reload();
}

/** Once per protocol pair, a page still mismatched after it stays stopped. */
export function reloadForProtocol(server, client) {
  const pair = `${server}:${client}`;
  try {
    if (sessionStorage.getItem(PROTOCOL_RELOAD_KEY) === pair) {
      log(
        "warn",
        `lily: still on wire protocol ${client} after a reload, the server ` +
          `speaks ${server}, not reloading again`,
      );
      return;
    }
    sessionStorage.setItem(PROTOCOL_RELOAD_KEY, pair);
  } catch (_error) {
    // without storage nothing could stop a loop, reloadForVersion refuses
  }
  reloadForVersion();
}

/** Bounded, a server flipping builds or protocols can't loop the page. */
export function reloadForVersion() {
  if (!versionReloadAllowed()) {
    log(
      "warn",
      "lily: the server announced another build again, not reloading, the " +
        "page reloaded for a new build too often already",
    );
    return;
  }
  reload();
}

export function replace(path) {
  changeHistory("replaceState", path);
}

export function writeStored(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch (error) {
    log("warn", `lily: failed to persist "${key}": ${error}`);
  }
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function askBeforeLeaving(event) {
  event.preventDefault();
  // older browsers ask only when this is set
  event.returnValue = "";
}

// history calls emit no popstate, so this fires our own event
function changeHistory(method, path) {
  if (typeof window === "undefined") return;
  // the browser refuses another origin by throwing, this refuses it with a
  // warning
  const url = sameOriginUrl(path);
  if (!url) {
    log(
      "warn",
      `lily: refused to navigate to ${JSON.stringify(path)}, it isn't a ` +
        "page on this origin",
    );
    return;
  }
  window.history[method]({}, "", url.href);
  window.dispatchEvent(new Event(LOCATION_EVENT));
}

// an invalid `within` selector throws, it then matches nothing
function closestSafely(element, selector) {
  try {
    return element.closest(selector);
  } catch (_error) {
    return null;
  }
}

// stashes the live model before each reload for recoverAfterReload
function connectDevReload(
  getModel,
  target,
  reconnectMilliseconds,
  guardMilliseconds,
) {
  const open = () => {
    const socket = new WebSocket(target);
    socket.onmessage = (event) => {
      let changed = [];
      try {
        const parsed = JSON.parse(event.data).changed;
        changed = Array.isArray(parsed) ? parsed.map(String) : [];
      } catch (_error) {
        changed = [];
      }
      if (changed.length > 0) {
        log("info", `lily_dev: rebuilt ${changed.join(", ")}`);
      }
      if (reloadedTooRecently(guardMilliseconds)) {
        log("warn", "lily_dev: reload suppressed (storm guard)");
        return;
      }
      stashModelForReload(getModel());
      window.location.reload();
    };
    socket.onopen = () => {
      wait = reconnectMilliseconds;
    };
    // no dev server answering, the wait grows to 30 s rather than retrying
    // every second
    socket.onclose = () => {
      setTimeout(open, wait);
      wait = Math.min(wait * 2, 30_000);
    };
  };
  let wait = reconnectMilliseconds;
  open();
}

// page port plus one, sparing the app a route
function devReloadUrl() {
  const isSecure = window.location.protocol === "https:";
  const protocol = isSecure ? "wss:" : "ws:";
  const defaultPort = isSecure ? 443 : 80;
  const port = Number(window.location.port || defaultPort) + 1;
  return `${protocol}//${window.location.hostname}:${port}/dev-reload`;
}

// a Gleam record or a plain object, not a list, tuple or primitive
function isPlainRecord(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    !(value instanceof List)
  );
}

// one page listener per event, every call adds a callback to it
function onPage(target, name, callback) {
  let callbacks = pageCallbacks.get(name);
  if (!callbacks) {
    callbacks = [];
    pageCallbacks.set(name, callbacks);
    target.addEventListener(name, (event) => {
      for (const run of callbacks) run(event);
    });
  }
  callbacks.push(callback);
}

// in sessionStorage to survive the reload it guards
function reloadedTooRecently(guardMilliseconds) {
  try {
    const now = new Date().getTime();
    const last = Number(sessionStorage.getItem(RELOAD_GUARD_KEY) || 0);
    if (now - last < guardMilliseconds) return true;
    sessionStorage.setItem(RELOAD_GUARD_KEY, String(now));
    return false;
  } catch (_error) {
    return false;
  }
}

// an http(s) URL on this origin or null, a page served from `file:` or an
// app shell's own scheme has no origin, so its own scheme and host count
function sameOriginUrl(path) {
  try {
    const page = new URL(window.location.href);
    const url = new URL(path, page);
    if (WEB_PROTOCOLS.has(url.protocol)) {
      return url.origin === window.location.origin ? url : null;
    }
    const own =
      !WEB_PROTOCOLS.has(page.protocol) &&
      !UNSAFE_PROTOCOLS.has(url.protocol) &&
      url.protocol === page.protocol &&
      url.host === page.host;
    return own ? url : null;
  } catch (_error) {
    return null;
  }
}

function stashModelForReload(model) {
  try {
    sessionStorage.setItem(RELOAD_STASH_KEY, JSON.stringify(model));
  } catch (_error) {
    // recoverAfterReload then keeps the fresh model
  }
}

// two in ten seconds and six in ten minutes, a server alternating builds
// behind a load balancer stops reloading too, counted in sessionStorage to
// survive the reloads and refused without it
function versionReloadAllowed() {
  try {
    const now = new Date().getTime();
    const stored = JSON.parse(
      sessionStorage.getItem(VERSION_RELOAD_KEY) || "[]",
    );
    const recent = (Array.isArray(stored) ? stored : []).filter(
      (at) => typeof at === "number" && now - at < 600_000,
    );
    const burst = recent.filter((at) => now - at < 10_000);
    if (burst.length >= 2) return false;
    if (recent.length >= 6) return false;
    recent.push(now);
    sessionStorage.setItem(VERSION_RELOAD_KEY, JSON.stringify(recent));
    return true;
  } catch (_error) {
    return false;
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// confirm_leaving guards whose `when` holds
const holdingGuards = new Set();

// runtimes with a click listener
const intercepting = new WeakSet();

// fired by navigate and replace for the url setter
const LOCATION_EVENT = "lily-browser:location";

// event name to the callbacks its one listener runs
const pageCallbacks = new Map();

const PRIMITIVE_TYPES = new Set(["string", "number", "boolean"]);

// the protocol pair a reload was last made for
const PROTOCOL_RELOAD_KEY = "lily_protocol_reload";

// when the dev server last reloaded the page
const RELOAD_GUARD_KEY = "lily_dev_last_reload";

const RELOAD_STASH_KEY = "lily_dev_reload_state";

// never a page of the app's, whatever scheme it's served from
const UNSAFE_PROTOCOLS = new Set([
  "blob:",
  "data:",
  "javascript:",
  "vbscript:",
]);

const VERSION_RELOAD_KEY = "lily_version_reloads";

const WEB_PROTOCOLS = new Set(["http:", "https:"]);
