/**
 * BROWSER FFI
 *
 * Page-level helpers. No runtime access, Gleam hands in closures.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error } from "../gleam.mjs";
import { parse as parseUri } from "../../gleam_stdlib/gleam/uri.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function clearStored(prefix) {
  if (typeof localStorage === "undefined") return;
  const keys = [];
  for (let index = 0; index < localStorage.length; index++) {
    const key = localStorage.key(index);
    if (key && key.startsWith(prefix)) keys.push(key);
  }
  for (const key of keys) localStorage.removeItem(key);
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

/** One document listener per runtime. */
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
    const target = event.target;
    const anchor = target && target.closest ? target.closest("a") : null;
    if (!anchor) return;
    // no href, a placeholder
    if (!anchor.hasAttribute("href")) return;
    if (within !== "document" && !anchor.closest(within)) return;
    if (anchor.hasAttribute(optOut)) return;
    const anchorTarget = anchor.getAttribute("target");
    if (anchorTarget && anchorTarget !== "_self") return;
    if (anchor.hasAttribute("download")) return;
    const rel = anchor.getAttribute("rel");
    if (rel && rel.split(/\s+/).includes("external")) return;
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
  window.addEventListener("popstate", () => apply());
  window.addEventListener(LOCATION_EVENT, () => apply());
}

export function load(path) {
  if (typeof window !== "undefined") window.location.assign(path);
}

export function navigate(path) {
  changeHistory("pushState", path);
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
  if (stashed === null || typeof stashed !== "object") return initial;

  const merged = Object.create(Object.getPrototypeOf(initial));
  for (const key of Object.keys(initial)) {
    const stashedValue = stashed[key];
    const isPrimitive =
      stashedValue === null || PRIMITIVE_TYPES.has(typeof stashedValue);
    const sameType = typeof stashedValue === typeof initial[key];
    merged[key] =
      key in stashed && isPrimitive && sameType ? stashedValue : initial[key];
  }
  return merged;
}

export function reload() {
  if (typeof window !== "undefined") window.location.reload();
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

/** History calls emit no popstate, leaving us to fire our own event. */
function changeHistory(method, path) {
  if (typeof window === "undefined") return;
  window.history[method]({}, "", path);
  window.dispatchEvent(new Event(LOCATION_EVENT));
}

/** Stashes the live model before each reload for recoverAfterReload. */
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
        changed = JSON.parse(event.data).changed || [];
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
    socket.onclose = () => setTimeout(open, reconnectMilliseconds);
  };
  open();
}

/** Page port plus one, sparing the app a route. */
function devReloadUrl() {
  const isSecure = window.location.protocol === "https:";
  const protocol = isSecure ? "wss:" : "ws:";
  const defaultPort = isSecure ? 443 : 80;
  const port = Number(window.location.port || defaultPort) + 1;
  return `${protocol}//${window.location.hostname}:${port}/dev-reload`;
}

/** In sessionStorage to survive the reload it guards. */
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

function stashModelForReload(model) {
  try {
    sessionStorage.setItem(RELOAD_STASH_KEY, JSON.stringify(model));
  } catch (_error) {
    // recoverAfterReload then keeps the fresh model
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// runtimes with a click listener
const intercepting = new WeakSet();

// fired by navigate and replace for the url setter
const LOCATION_EVENT = "lily-browser:location";

const PRIMITIVE_TYPES = new Set(["string", "number", "boolean"]);

// shared with the client, one timestamp
const RELOAD_GUARD_KEY = "lily_dev_last_reload";

const RELOAD_STASH_KEY = "lily_dev_reload_state";
