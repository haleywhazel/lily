/**
 * COMPONENT TREE RENDERING
 *
 * Renders the component tree and keeps dynamic components in step with the
 * store. One context and id prefix per runtime, a render's ids are a range.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { NonEmpty, isEqual } from "../gleam.mjs";
import { inspect } from "../../gleam_stdlib/gleam_stdlib.mjs";
import { Some } from "../../gleam_stdlib/gleam/option.mjs";
// circular with component.mjs, safe as these are only read inside functions
import {
  Each,
  Fragment,
  Listener,
  Live,
  RemoveAttribute,
  SetAttribute,
  SetStyle,
  SetText,
  Simple,
  Static,
} from "./component.mjs";
import {
  OWNER_ATTRIBUTE,
  createEvents,
  dropListeners,
  installMessageClicks,
  isMade,
  markMade,
  registerListener,
  reobserveOwner,
  setDispatch,
} from "./event.ffi.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function keyToString(key) {
  if (typeof key === "string") return key;
  if (typeof key === "number") return String(key);
  return inspect(key);
}

export function renderTree(
  runtime,
  rootSelector,
  component,
  model,
  toHtml,
  toPlaceholder,
  dispatch,
  decodeMessage,
) {
  const root = document.querySelector(rootSelector);
  if (!root) {
    log(
      "error",
      `lily: nothing was rendered, no element matches the mount selector ` +
        `"${rootSelector}"`,
    );
    return;
  }

  const context = contextFor(runtime.handle);
  setDispatch(context.events, dispatch, decodeMessage);

  const start = context.counter;
  const [html, owned] = collectOwners(context, () =>
    renderComponent(context, component, model, toHtml, toPlaceholder),
  );
  const end = context.counter;

  // new ids are all newer, keeping the sweep to the earlier mount
  unregisterSubtree(context, root);
  root.innerHTML = html;
  resolveMarks(context, root);
  setOwners(context, root, owned);

  // seeded components skip, leaving this to mostly populate keyed lists
  runRange(context, start, end, model);

  installMessageClicks(root, decodeMessage, dispatch);
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function addClasses(element, classes) {
  for (const name of classes.split(/\s+/)) {
    if (name !== "") element.classList.add(name);
  }
}

function addOwnerId(element, id) {
  setOwnerIds(element, [...ownerIds(element), id]);
}

function afterRows(context, node) {
  let next = node.nextSibling;
  if (node.tagName !== "TEMPLATE") return next;
  const id = node.getAttribute(OWNER_ATTRIBUTE);
  while (next && context.rows.get(next)?.list === id) next = next.nextSibling;
  return next;
}

// a pair the parser split, an implied tbody or a <p> closed by a block
function alignStart(start, end) {
  while (!start.parentNode.contains(end)) {
    const parent = start.parentNode;
    if (!parent.parentNode) return;
    parent.parentNode.insertBefore(start, parent.nextSibling);
  }
  while (start.parentNode !== end.parentNode) {
    let container = end.parentNode;
    while (container.parentNode !== start.parentNode) {
      container = container.parentNode;
    }
    container.insertBefore(start, container.firstChild);
  }
}

// rows patch their own root
function applyPatch(rootElement, patch, matchRoot) {
  const element =
    patch.target === "" || (matchRoot && rootElement.matches(patch.target))
      ? rootElement
      : rootElement.querySelector(patch.target);

  if (!element) return;

  if (patch instanceof SetText) {
    element.textContent = patch.value;
  } else if (patch instanceof SetAttribute) {
    if (isUnsafeAttribute(element, patch.name, patch.value)) {
      log(
        "warn",
        `lily: refused unsafe attribute "${patch.name}" in a live patch`,
      );
    } else if (element.getAttribute(patch.name) !== patch.value) {
      setAttribute(element, patch.name, patch.value);
    }
  } else if (patch instanceof SetStyle) {
    element.style.setProperty(patch.property, patch.value);
  } else if (patch instanceof RemoveAttribute) {
    const lower = patch.name.toLowerCase();
    if (isRuntimeAttribute(lower) || GUARD_ATTRIBUTES.has(lower)) {
      log("warn", `lily: refused to remove "${patch.name}" in a live patch`);
    } else {
      removeAttribute(element, patch.name);
    }
  }
}

// one bad patch doesn't stop the rest
function applyPatches(rootElement, patches, matchRoot = false) {
  for (const patch of patches) {
    try {
      applyPatch(rootElement, patch, matchRoot);
    } catch (error) {
      log("warn", `lily: a live patch failed: ${error?.stack ?? error}`);
    }
  }
}

function cancelExit(context, node) {
  const controller = context.exits.get(node);
  if (controller) {
    controller.abort();
    context.exits.delete(node);
  }
  setExiting(node, false);
  reverseExit(context, node);
}

// ids before `id` belong to a dropped child
function carryOwnerAttributes(from, to, id) {
  const ids = ownerIds(from);
  const kept = ids.slice(Math.max(0, ids.indexOf(id)));
  setOwnerIds(to, [...ownerIds(to), ...kept]);
  for (const name of ["data-lily-exiting", "data-lily-key"]) {
    const value = from.getAttribute(name);
    if (value !== null) to.setAttribute(name, value);
  }
  for (const name of exitingAttributes(from)) {
    to.setAttribute(name, from.getAttribute(name) ?? "");
  }
  // a transition belongs to the innermost id
  if (kept.length < ids.length) return;
  const { lilyTransitionEnter: enter, lilyTransitionExit: exit } = from.dataset;
  if (exit === undefined) return;
  to.setAttribute("data-lily-transition-enter", enter ?? "");
  to.setAttribute("data-lily-transition-exit", exit);
  const duration = from.style.getPropertyValue("--lily-transition-duration");
  if (duration !== "") {
    to.style.setProperty("--lily-transition-duration", duration);
  }
  for (const name of `${enter ?? ""} ${exit}`.split(/\s+/)) {
    if (name !== "" && from.classList.contains(name)) to.classList.add(name);
  }
}

/** Listener-only owners have no element of their own. */
function collectOwners(context, render) {
  const outer = context.collected;
  const owned = [];
  context.collected = owned;
  try {
    return [render(), owned];
  } finally {
    context.collected = outer;
  }
}

function contextFor(runtime) {
  let context = contexts.get(runtime);
  if (context) return context;
  const wrappers = new WeakSet();
  // random, so markup from data can't name a real component or row
  const nonce = randomNonce();
  context = {
    prefix: `r${runtimeCount++}_${nonce}_`,
    rowSeparator: `${ROW_SEPARATOR} ${nonce}`,
    // component ids, source of every render range
    counter: 0,
    // listener-only owner ids, never in a range
    listenerCounter: 0,
    // id to handler for model-reactive components
    registry: new Map(),
    // component or mount root to its listener-only owners
    owners: new Map(),
    collected: null,
    // pending exits by element, a returning key cancels its exit
    exits: new Map(),
    // replacement element to the shared child it pushed out
    departed: new WeakMap(),
    // cancelled exits easing back
    reversals: new Map(),
    // mark id to its pending spec
    marks: new Map(),
    // row element to its row record
    rows: new WeakMap(),
    // divs the renderer made, not the app's markup
    wrappers,
    events: createEvents(wrappers),
    // ids whose handler threw, logged once until unregistered
    crashed: new Set(),
  };
  contexts.set(runtime, context);
  const registry = context.registry;
  runtime.addRenderer((model) => {
    for (const [id, handler] of registry)
      runHandler(context, id, handler, model);
  });
  return context;
}

// all-selector listeners get a bare owner id, no element
function decorate(context, decorations, id) {
  // prepended, leaving newest first
  const listeners = [];
  const transitions = [];
  for (let node = decorations; node instanceof NonEmpty; node = node.tail) {
    if (node.head instanceof Listener) listeners.unshift(node.head);
    else transitions.unshift(node.head);
  }

  let owner = id;
  let listenerOwner = id;
  if (listeners.length > 0 && owner === null) {
    if (listeners.some((listener) => !(listener.selector instanceof Some))) {
      owner = listenerOwner = nextId(context);
    } else {
      listenerOwner = `${context.prefix}l${context.listenerCounter++}`;
      context.collected?.push(listenerOwner);
    }
  }
  for (const listener of listeners) {
    registerListener(context.events, listenerOwner, listener);
  }

  return {
    owner,
    transitions: transitions.map(({ enter, exit, duration_milliseconds }) => ({
      id: nextId(context),
      enter,
      exit,
      duration:
        duration_milliseconds instanceof Some ? duration_milliseconds[0] : null,
    })),
  };
}

function delay(milliseconds, signal) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

// the shared child exits, `next` takes the outer ids
function departChild(context, child, next, id) {
  const ids = ownerIds(child);
  setOwnerIds(child, ids.slice(0, ids.indexOf(id)));
  child.before(next);
  moveTracking(context, child, next);
  for (const owner of ownerIds(next)) reobserveOwner(context.events, owner);
  context.departed.set(next, child);
  removeMorphChild(context, child.parentNode, child);
}

function eachHandler(context, marker, id, component, toHtml, toPlaceholder) {
  const { slice, key: getKey, render } = component;
  const patch = component.patch instanceof Some ? component.patch[0] : null;
  // key to { element, item }
  const rows = new Map();
  let previousList = null;
  // unchanged order skips the walk
  let placed = [];

  return function (model) {
    // same list reference, unchanged
    const list = slice(model);
    if (list === previousList) return;
    const start = marker();
    const container = start?.parentNode;
    if (!container) return;
    previousList = list;

    const items = list.toArray();
    const keys = items.map(getKey);
    const currentKeys = new Set(keys);

    // drop departed keys, transition rows wait for their exit animation
    for (const [keyString, row] of rows) {
      if (currentKeys.has(keyString)) continue;
      // already exiting, avoids a duplicate timer
      if (context.exits.has(row.element)) continue;
      removeWithTransition(context, container, row.element, () => {
        rows.delete(keyString);
        unregisterSubtree(context, row.element);
      });
    }

    const renders = [];
    const ordered = [];
    let moved = false;
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      const keyString = keys[index];

      let row = rows.get(keyString);
      if (!row) {
        row = { element: null, item: undefined, list: id };
        rows.set(keyString, row);
      } else if (context.exits.has(row.element)) {
        // re-added mid-exit, cancel the removal
        cancelExit(context, row.element);
      }
      ordered.push(row);
      if (placed[index] !== row) moved = true;

      if (row.element && fastEqual(row.item, item)) continue;
      row.item = item;

      if (row.element && patch) {
        const wrapped = context.wrappers.has(row.element);
        applyPatches(row.element, patch(item).toArray(), !wrapped);
        continue;
      }

      const first = context.counter;
      const [html, owned] = collectOwners(context, () =>
        renderNested(context, model, toHtml, toPlaceholder, (nest) =>
          render(item, nest),
        ),
      );
      const last = context.counter;
      renders.push({ row, keyString, html, owned, first, last });
    }

    // one parse for all rows
    const roots = parseRows(
      context,
      renders.map((entry) => entry.html),
    );
    renders.forEach((entry, index) => {
      const root = roots[index];
      root.setAttribute("data-lily-key", entry.keyString);
      markMade(root);
      const element = entry.row.element
        ? updateRow(context, entry.row.element, root)
        : root;
      if (element !== entry.row.element) moved = true;
      entry.row.element = element;
      context.rows.set(element, entry.row);
      setOwners(context, element, entry.owned);
    });

    // cursor walk, indexing live children is quadratic
    if (moved || ordered.length !== placed.length) {
      let cursor = start.nextElementSibling;
      for (const { element } of ordered) {
        // exiting rows keep their place
        while (cursor && cursor !== element && context.exits.has(cursor)) {
          cursor = cursor.nextElementSibling;
        }
        if (cursor !== element) container.insertBefore(element, cursor);
        cursor = element.nextElementSibling;
      }
    }
    placed = ordered;

    // after placement so handlers find their elements
    for (const entry of renders) {
      sweepRange(context, entry.row.element, entry.first, entry.last, model);
    }
  };
}

// added by setExiting, a root's own stay
function exitingAttributes(element) {
  const added = element.getAttribute("data-lily-exiting") ?? "";
  return added.split(" ").filter((name) => name !== "");
}

/** isEqual with a shared-reference shortcut. */
function fastEqual(left, right) {
  if (left === right) return true;
  if (
    typeof left === "object" &&
    left !== null &&
    typeof right === "object" &&
    right !== null &&
    left.constructor === right.constructor
  ) {
    const keys = Object.keys(left);
    if (keys.length === Object.keys(right).length) {
      let same = true;
      for (const key of keys) {
        if (left[key] !== right[key]) {
          same = false;
          break;
        }
      }
      if (same) return true;
    }
  }
  return isEqual(left, right);
}

// a renderer wrapper can sit just above it
function findTransitionElement(context, element) {
  if (element.dataset?.lilyTransitionExit) return element;
  if (!context.wrappers.has(element)) return null;
  const child = element.firstElementChild;
  return child?.dataset?.lilyTransitionExit ? child : null;
}

// infinite ones, a spinner say, would never let it go
function finiteAnimations(element) {
  const animations = element.getAnimations?.({ subtree: true }) ?? [];
  return animations.filter(
    (animation) =>
      animation.playState !== "finished" &&
      Number.isFinite(animation.effect?.getComputedTiming().endTime),
  );
}

// this runtime's own marks only, markup from data can carry the attributes
// marked by the renderer, or a list's own marker, never markup from data
function isOwned(context, node) {
  if (node.nodeType !== 1) return false;
  if (context.rows.has(node) || isMade(node)) return true;
  return (
    node.tagName === "TEMPLATE" &&
    ownerIds(node).some((id) => id.startsWith(context.prefix))
  );
}

// a nested component's root the renderer made
function isOwnedComponent(node) {
  return isMade(node) && node.hasAttribute(OWNER_ATTRIBUTE);
}

// owner marks and data-lily-message, a patch could hijack either
function isRuntimeAttribute(name) {
  return name.toLowerCase().startsWith("data-lily-");
}

/**
 * Patch values may be other clients' input. Strips control chars and
 * whitespace before the scheme check, as browsers do. A data URL is only
 * allowed where it can't carry a document, an image or media source.
 */
function isUnsafeAttribute(element, name, value) {
  const lower = name.toLowerCase();
  if (lower.startsWith("on") || lower === "srcdoc") return true;
  if (isRuntimeAttribute(lower)) return true;
  // what an embedded document may do, set or loosened
  if (GUARD_ATTRIBUTES.has(lower)) return true;
  const tag = element.tagName.toUpperCase();
  // a base or stylesheet link redirects every relative URL or styles the page
  if (lower === "href" && (tag === "BASE" || tag === "LINK")) return true;
  // a meta refresh navigates, an SVG animation can write a link attribute
  if (tag === "META" && (lower === "content" || lower === "http-equiv")) {
    return true;
  }
  if (SVG_ANIMATIONS.has(tag) && SVG_ANIMATION_ATTRIBUTES.has(lower)) {
    return true;
  }
  if (URL_ATTRIBUTES.has(lower)) {
    const scheme = String(value)
      .replace(/[\u0000- ]+/g, "")
      .toLowerCase();
    if (UNSAFE_URL_SCHEME.test(scheme)) return true;
    if (
      scheme.startsWith("data:") &&
      !(MEDIA_SOURCE_ATTRIBUTES.has(lower) && MEDIA_TAGS.has(element.tagName))
    ) {
      return true;
    }
  }
  return false;
}

/** Consumes `next`. Runtime-owned elements match by position. */
function morph(context, live, next) {
  let liveNode = live.firstChild;
  let nextNode = next.firstChild;

  while (nextNode) {
    const nextAfter = nextNode.nextSibling;

    if (!liveNode) {
      live.appendChild(nextNode);
      nextNode = nextAfter;
      continue;
    }

    const liveOwned = isOwned(context, liveNode);
    const nextOwned = isOwned(context, nextNode);

    if (liveOwned && nextOwned) {
      // both runtime-owned, keep the live one, cancel any pending exit
      if (context.exits.has(liveNode)) cancelExit(context, liveNode);
      liveNode = afterRows(context, liveNode);
      nextNode = nextAfter;
    } else if (nextOwned) {
      live.insertBefore(nextNode, liveNode);
      nextNode = nextAfter;
    } else if (liveOwned) {
      const gone = liveNode;
      liveNode = afterRows(context, liveNode);
      removeMorphChild(context, live, gone);
    } else if (
      liveNode.nodeType === 1 &&
      nextNode.nodeType === 1 &&
      liveNode.tagName === nextNode.tagName
    ) {
      morphElement(context, liveNode, nextNode);
      liveNode = liveNode.nextSibling;
      nextNode = nextAfter;
    } else if (liveNode.nodeType === 3 && nextNode.nodeType === 3) {
      if (liveNode.nodeValue !== nextNode.nodeValue) {
        liveNode.nodeValue = nextNode.nodeValue;
      }
      liveNode = liveNode.nextSibling;
      nextNode = nextAfter;
    } else {
      // whatever components the old node held go with it
      const replaced = liveNode;
      liveNode = liveNode.nextSibling;
      unregisterSubtree(context, replaced);
      live.replaceChild(nextNode, replaced);
      nextNode = nextAfter;
    }
  }

  while (liveNode) {
    const gone = liveNode;
    liveNode = afterRows(context, liveNode);
    removeMorphChild(context, live, gone);
  }
}

/** Unchanged attributes are skipped to keep user input. */
function morphAttributes(live, next) {
  const nextAttributes = next.attributes;
  for (let index = 0; index < nextAttributes.length; index++) {
    const { name, value } = nextAttributes[index];
    if (live.getAttribute(name) !== value) setAttribute(live, name, value);
  }
  const liveAttributes = live.attributes;
  for (let index = liveAttributes.length - 1; index >= 0; index--) {
    const name = liveAttributes[index].name;
    if (!next.hasAttribute(name)) removeAttribute(live, name);
  }
}

function morphElement(context, live, next) {
  morphAttributes(live, next);
  // a dirty textarea ignores its text, meaning it is copied to value
  const textChanged =
    live.tagName === "TEXTAREA" && live.defaultValue !== next.defaultValue;
  morph(context, live, next);
  if (textChanged) live.value = live.defaultValue;
}

function moveTracking(context, old, next) {
  const row = context.rows.get(old);
  if (row) {
    context.rows.delete(old);
    context.rows.set(next, row);
    row.element = next;
  }
  const owned = context.owners.get(old);
  if (owned) {
    context.owners.delete(old);
    context.owners.set(next, owned);
  }
}

function nextId(context) {
  return context.prefix + "c" + context.counter++;
}

function ownableRoot(nodes) {
  const root = singleRoot(nodes);
  return root?.tagName === "TEMPLATE" ? null : root;
}

// innermost first, a nest-only component shares its child's element
function ownerIds(element) {
  const ids = element.getAttribute(OWNER_ATTRIBUTE) ?? "";
  return ids.split(" ").filter((id) => id !== "");
}

function ownerSelector(id) {
  return `[${OWNER_ATTRIBUTE}~="${id}"]`;
}

// one parse for every row, or one each when a row's markup, an unclosed
// comment say, swallowed the separators
function parseRows(context, htmls) {
  if (htmls.length === 0) return [];
  const together = parseRowsTogether(context, htmls);
  if (together.length === htmls.length) return together;
  return htmls.map((html) => parseRowsTogether(context, [html])[0]);
}

function parseRowsTogether(context, htmls) {
  const template = document.createElement("template");
  template.innerHTML = htmls.join(`<!--${context.rowSeparator}-->`);
  resolveMarks(context, template.content);
  const roots = [];
  let nodes = [];
  for (const node of Array.from(template.content.childNodes)) {
    if (node.nodeType === 8 && node.data === context.rowSeparator) {
      roots.push(rowRoot(context, nodes));
      nodes = [];
    } else {
      nodes.push(node);
    }
  }
  roots.push(rowRoot(context, nodes));
  return roots;
}

function placeTransition(element, transition) {
  const { enter, exit, duration } = transition;
  element.setAttribute("data-lily-transition-enter", enter);
  element.setAttribute("data-lily-transition-exit", exit);
  if (duration !== null) {
    element.style.setProperty("--lily-transition-duration", `${duration}ms`);
  }
  addClasses(element, enter);
  scheduleEnterClassRemoval(element, enter);
}

function randomNonce() {
  const bytes = new Uint8Array(8);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

// nest-only again mid-exit, the child comes back
function reclaimChild(context, host, child, id) {
  context.departed.delete(host);
  cancelExit(context, child);
  const ids = ownerIds(host);
  const kept = ids.slice(Math.max(0, ids.indexOf(id)));
  setOwnerIds(child, [...ownerIds(child), ...kept]);
  const key = host.getAttribute("data-lily-key");
  if (key !== null) child.setAttribute("data-lily-key", key);
  moveTracking(context, host, child);
  unregisterDescendants(context, host);
  host.remove();
  for (const owner of kept) reobserveOwner(context.events, owner);
  return child;
}

function registerComponent(context, makeHandler) {
  const id = nextId(context);
  const selector = ownerSelector(id);
  let cached = null;
  // a departing child stays connected without its id
  // the first the renderer made, an earlier copy from data isn't it, a list's
  // marker is parsed from its html and found by its id alone
  const element = () =>
    (cached =
      cached?.isConnected && cached.matches(selector)
        ? cached
        : (Array.from(document.querySelectorAll(selector)).find(
            (candidate) =>
              isMade(candidate) || candidate.tagName === "TEMPLATE",
          ) ?? null));
  context.registry.set(id, makeHandler(element, id));
  return id;
}

function removeAttribute(element, name) {
  element.removeAttribute(name);
  syncProperty(element, name, null);
}

function removeClasses(element, classes) {
  for (const name of classes.split(/\s+/)) {
    if (name !== "") element.classList.remove(name);
  }
}

function removeListRows(context, parent, marker) {
  if (marker.tagName !== "TEMPLATE") return;
  const id = marker.getAttribute(OWNER_ATTRIBUTE);
  let node = marker.nextSibling;
  while (node && context.rows.get(node)?.list === id) {
    const row = node;
    node = node.nextSibling;
    unregisterSubtree(context, row);
    if (row.parentNode === parent) parent.removeChild(row);
  }
}

function removeMorphChild(context, parent, node) {
  if (isOwned(context, node)) {
    if (context.exits.has(node)) return;
    removeListRows(context, parent, node);
    if (findTransitionElement(context, node)) {
      removeWithTransition(context, parent, node, () =>
        unregisterSubtree(context, node),
      );
      return;
    }
    unregisterSubtree(context, node);
  } else if (node.nodeType === 1) {
    unregisterDescendants(context, node);
  }
  if (node.parentNode === parent) parent.removeChild(node);
}

/** The pending exit is keyed by the outer row `element`. */
async function removeWithTransition(context, parent, element, onComplete) {
  const transitionElement = findTransitionElement(context, element);

  if (!transitionElement) {
    if (element.parentNode === parent) parent.removeChild(element);
    onComplete();
    return;
  }

  const exitClass = transitionElement.dataset.lilyTransitionExit;
  const controller = new AbortController();
  context.exits.set(element, controller);

  resumeExit(context, element);
  setExiting(element, true);
  const { lilyTransitionEnter: enterClass } = transitionElement.dataset;
  if (enterClass) removeClasses(transitionElement, enterClass);
  addClasses(transitionElement, exitClass);
  await whenAnimationDone(transitionElement, controller.signal);
  // cancelled by a re-add, reverseExit drops the class
  if (controller.signal.aborted) return;

  context.exits.delete(element);
  if (element.parentNode === parent) parent.removeChild(element);
  onComplete();
}

function renderComponent(context, component, model, toHtml, toPlaceholder) {
  const type = component.component_type;
  let html;
  let id = null;

  if (type instanceof Simple) {
    ({ html, id } = renderSimple(context, type, model, toHtml, toPlaceholder));
  } else if (type instanceof Each) {
    const listId = registerComponent(context, (marker, listId) =>
      eachHandler(context, marker, listId, type, toHtml, toPlaceholder),
    );
    // rows follow as siblings, valid in lists and tables
    html = `<template ${OWNER_ATTRIBUTE}="${listId}"></template>`;
  } else if (type instanceof Live) {
    ({ html, id } = renderLive(context, type, model, toHtml, toPlaceholder));
  } else if (type instanceof Static) {
    html = renderNested(context, model, toHtml, toPlaceholder, type.render);
  } else if (type instanceof Fragment) {
    html = "";
    for (const child of type.children) {
      html += renderComponent(context, child, model, toHtml, toPlaceholder);
    }
  } else {
    log("error", `lily: unknown component type ${type?.constructor?.name}`);
    return "";
  }

  const spec =
    component.decorations instanceof NonEmpty
      ? decorate(context, component.decorations, id)
      : { owner: id, transitions: [] };
  if (spec.owner === null && spec.transitions.length === 0) return html;
  // comments parse anywhere, a wrapper div would break a table
  const markId = spec.owner ?? spec.transitions[0].id;
  context.marks.set(markId, spec);
  return `<!--${MARK} ${markId}-->${html}<!--/${MARK} ${markId}-->`;
}

function renderLive(context, component, model, toHtml, toPlaceholder) {
  const { slice, render, patch } = component;
  const seed = slice(model);
  const id = registerComponent(context, (element) =>
    selective(seed, slice, (data) => {
      const host = element();
      if (!host) return;
      applyPatches(host, patch(data).toArray(), !context.wrappers.has(host));
    }),
  );
  // children live as long as the component, patches never touch them
  const [html, owned] = collectOwners(context, () =>
    renderNested(context, model, toHtml, toPlaceholder, (nest) =>
      render(seed, nest),
    ),
  );
  setOwners(context, id, owned);
  return { html, id };
}

/** Fills placeholders in DOM order. Orphaned children are unregistered. */
function renderNested(context, model, toHtml, toPlaceholder, produce) {
  const children = [];
  const html = toHtml(
    produce((child) => {
      children.push(child);
      return toPlaceholder();
    }),
  );
  if (children.length === 0) return html;

  const segments = html.split(NEST_PATTERN);
  let output = segments[0];
  for (let index = 0; index < children.length; index++) {
    const start = context.counter;
    const ownedBefore = context.collected?.length ?? 0;
    const childHtml = renderComponent(
      context,
      children[index],
      model,
      toHtml,
      toPlaceholder,
    );
    if (index + 1 < segments.length) {
      output += childHtml + segments[index + 1];
      continue;
    }
    log(
      "error",
      "lily: <lily-nest> placeholder missing from rendered HTML, child " +
        "component dropped. Make sure nest() return values are placed in the " +
        "template.",
    );
    for (let number = start; number < context.counter; number++) {
      unregister(context, context.prefix + "c" + number);
    }
    for (const owner of context.collected?.splice(ownedBefore) ?? []) {
      dropListeners(context.events, owner);
    }
  }

  // extra placeholders dropped
  for (let index = children.length + 1; index < segments.length; index++) {
    output += segments[index];
  }
  return output;
}

function renderSimple(context, component, model, toHtml, toPlaceholder) {
  const { slice, render } = component;
  const seed = slice(model);
  const id = registerComponent(context, (element, id) =>
    selective(seed, slice, (data, model) => {
      const host = element();
      if (!host) return;
      // re-render with nested children, then morph onto the live subtree
      const start = context.counter;
      const [html, owned] = collectOwners(context, () =>
        renderNested(context, model, toHtml, toPlaceholder, (nest) =>
          render(data, nest),
        ),
      );
      setOwners(context, id, owned);
      const template = document.createElement("template");
      template.innerHTML = html;
      resolveMarks(context, template.content);
      const next = updateHost(context, host, template.content, id);
      sweepRange(context, next, start, context.counter, model);
    }),
  );
  // run at mount by renderTree, kept across updates by the morph
  const [html, owned] = collectOwners(context, () =>
    renderNested(context, model, toHtml, toPlaceholder, (nest) =>
      render(seed, nest),
    ),
  );
  setOwners(context, id, owned);
  return { html, id };
}

function replaceHost(context, old, next) {
  old.replaceWith(next);
  unregisterDescendants(context, old);
  const kept = ownerIds(next);
  for (const id of ownerIds(old)) {
    if (kept.includes(id)) reobserveOwner(context.events, id);
    else unregister(context, id);
  }
  moveTracking(context, old, next);
  const enter = next.dataset.lilyTransitionEnter;
  if (enter) scheduleEnterClassRemoval(next, enter);
}

function resolveMark(context, start, end, spec) {
  alignStart(start, end);
  const nodes = [];
  for (let node = start.nextSibling; node !== end; node = node.nextSibling) {
    nodes.push(node);
  }

  let element = null;
  if (spec.owner !== null) {
    element = ownableRoot(nodes) ?? wrapNodes(context, nodes, end, true);
    addOwnerId(element, spec.owner);
  }
  spec.transitions.forEach((transition, index) => {
    const own = element ?? ownableRoot(nodes);
    // a transition belongs to its element's innermost id
    const free =
      index === 0 &&
      own !== null &&
      ownerIds(own).length === (element === null ? 0 : 1);
    if (!free) {
      const inner = element === null ? nodes : [element];
      element = wrapNodes(context, inner, end, false);
      addOwnerId(element, transition.id);
    } else if (element === null) {
      element = own;
      addOwnerId(element, transition.id);
    } else if (context.wrappers.has(element)) {
      // a contents box can't animate
      element.removeAttribute("style");
    }
    placeTransition(element, transition);
  });

  start.remove();
  end.remove();
}

// inner pairs first, a parent sees its child's root
function resolveMarks(context, root) {
  if (context.marks.size === 0) return;
  const starts = new Map();
  const ends = [];
  // NodeFilter.SHOW_COMMENT
  const walker = root.ownerDocument.createTreeWalker(root, 128);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.data.startsWith(`${MARK} `)) {
      starts.set(node.data.slice(MARK.length + 1), node);
    } else if (node.data.startsWith(`/${MARK} `)) {
      ends.push(node);
    }
  }
  for (const end of ends) {
    const id = end.data.slice(MARK.length + 2);
    const spec = context.marks.get(id);
    const start = starts.get(id);
    if (!spec || !start) continue;
    context.marks.delete(id);
    resolveMark(context, start, end, spec);
  }
}

function resumeExit(context, element) {
  const reversal = context.reversals.get(element);
  if (!reversal) return;
  context.reversals.delete(element);
  for (const animation of reversal) {
    if (animation.playbackRate < 0) animation.reverse();
  }
}

// transitions reverse on their own once the class goes
async function reverseExit(context, element) {
  const transitionElement = findTransitionElement(context, element);
  const exitClass = transitionElement?.dataset.lilyTransitionExit;
  if (!exitClass) return;
  const reversal = finiteAnimations(transitionElement).filter(
    (animation) =>
      !(
        typeof CSSTransition === "function" &&
        animation instanceof CSSTransition
      ),
  );
  if (reversal.length === 0) {
    removeClasses(transitionElement, exitClass);
    return;
  }

  context.reversals.set(element, reversal);
  for (const animation of reversal) animation.reverse();
  const remaining = Math.max(
    ...reversal.map((animation) => animation.currentTime ?? 0),
  );
  // a paused or missed animation
  await Promise.race([
    Promise.allSettled(reversal.map((animation) => animation.finished)),
    delay(remaining + 100),
  ]);
  // a re-exit took it over
  if (context.reversals.get(element) !== reversal) return;
  context.reversals.delete(element);
  removeClasses(transitionElement, exitClass);
}

function rowRoot(context, nodes) {
  const root = singleRoot(nodes);
  if (root && root.tagName !== "TEMPLATE") return root;
  return wrapNodes(context, nodes, null, true);
}

// one throwing component can't stop its siblings rendering
function runHandler(context, id, handler, model) {
  try {
    handler(model);
  } catch (error) {
    if (context.crashed.has(id)) return;
    context.crashed.add(id);
    log(
      "error",
      `lily: component ${id} crashed rendering: ${error?.stack ?? error}`,
    );
  }
}

function runRange(context, start, end, model) {
  for (let number = start; number < end; number++) {
    const id = context.prefix + "c" + number;
    const handler = context.registry.get(id);
    if (handler) runHandler(context, id, handler, model);
  }
}

function scheduleEnterClassRemoval(element, enterClass) {
  if (enterClass.trim() === "") return;
  const arm = () => {
    // never placed, or gone already
    if (!element.isConnected) return;
    whenAnimationDone(element).then(() => removeClasses(element, enterClass));
  };
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(arm);
  else setTimeout(arm, 0);
}

/** Starts from `seed` so mount doesn't render twice. */
function selective(seed, select, handler) {
  let previous = seed;
  return function (model) {
    const next = select(model);
    if (fastEqual(previous, next)) return;
    previous = next;
    handler(next, model);
  };
}

function setAttribute(element, name, value) {
  element.setAttribute(name, value);
  syncProperty(element, name, value);
}

// inert and hidden while it animates out
function setExiting(element, exiting) {
  if (exiting === element.hasAttribute("data-lily-exiting")) return;
  if (exiting) {
    const added = [];
    for (const [name, value] of [
      ["aria-hidden", "true"],
      ["inert", ""],
    ]) {
      if (element.hasAttribute(name)) continue;
      element.setAttribute(name, value);
      added.push(name);
    }
    element.setAttribute("data-lily-exiting", added.join(" "));
  } else {
    for (const name of exitingAttributes(element)) {
      element.removeAttribute(name);
    }
    element.removeAttribute("data-lily-exiting");
  }
}

function setOwnerIds(element, ids) {
  element.setAttribute(OWNER_ATTRIBUTE, ids.join(" "));
  markMade(element);
}

function setOwners(context, key, owned) {
  const previous = context.owners.get(key);
  if (previous) {
    for (const owner of previous) dropListeners(context.events, owner);
  }
  if (owned.length > 0) context.owners.set(key, owned);
  else context.owners.delete(key);
}

function singleRoot(nodes) {
  let root = null;
  for (const node of nodes) {
    if (node.nodeType === 1) {
      if (root) return null;
      root = node;
    } else if (node.nodeType === 3 && node.nodeValue.trim() !== "") {
      return null;
    }
  }
  return root;
}

// one pass over the subtree for every id in the range
function sweepRange(context, element, start, end, model) {
  const present = new Set(ownerIds(element));
  for (const owned of element.querySelectorAll(`[${OWNER_ATTRIBUTE}]`)) {
    if (isMade(owned)) for (const id of ownerIds(owned)) present.add(id);
  }
  for (let number = start; number < end; number++) {
    const id = context.prefix + "c" + number;
    if (present.has(id)) context.registry.get(id)?.(model);
    else unregister(context, id);
  }
}

/**
 * Sets the property too, edited fields ignore `value`, `checked` and
 * `selected` attributes. `value` is null on removal.
 */
function syncProperty(element, name, value) {
  if (name === "value") {
    const next = value ?? "";
    if ("value" in element && element.type !== "file") {
      if (element.value !== next) element.value = next;
    }
  } else if (name === "checked" || name === "selected") {
    if (name in element) element[name] = value !== null;
  }
}

function unregister(context, id) {
  context.registry.delete(id);
  context.crashed.delete(id);
  context.marks.delete(id);
  dropListeners(context.events, id);
  const owned = context.owners.get(id);
  if (owned) {
    context.owners.delete(id);
    for (const owner of owned) dropListeners(context.events, owner);
  }
}

// only marks the renderer made, a pasted copy of an id isn't that component
function unregisterDescendants(context, element) {
  for (const owned of element.querySelectorAll(`[${OWNER_ATTRIBUTE}]`)) {
    if (!isMade(owned)) continue;
    for (const id of ownerIds(owned)) unregister(context, id);
  }
  for (const row of element.querySelectorAll("[data-lily-key]")) {
    setOwners(context, row, []);
  }
}

function unregisterSubtree(context, element) {
  if (element.nodeType !== 1) return;
  for (const id of ownerIds(element)) unregister(context, id);
  if (element.hasAttribute("data-lily-key")) setOwners(context, element, []);
  unregisterDescendants(context, element);
}

// mirrors updateRow, an exiting host is kept
function updateHost(context, host, content, id) {
  const nodes = Array.from(content.childNodes);
  const root = ownableRoot(nodes);
  const nested = root ? isOwnedComponent(root) : false;
  const shared = ownerIds(host).indexOf(id) > 0;
  const wrapped = context.wrappers.has(host);
  // still nest-only, the child updates itself
  if (shared && nested) return host;
  if (nested && context.exits.has(context.departed.get(host))) {
    return reclaimChild(context, host, context.departed.get(host), id);
  }
  if (!shared && wrapped && !root) {
    morph(context, host, content);
    return host;
  }
  if (!shared && !wrapped && !nested && root?.tagName === host.tagName) {
    carryOwnerAttributes(host, root, id);
    morphElement(context, host, root);
    return host;
  }
  if (context.exits.has(host)) return host;
  const contents = shared || !host.hasAttribute("data-lily-transition-exit");
  const next = root ?? wrapNodes(context, nodes, null, contents);
  carryOwnerAttributes(host, next, id);
  if (shared) departChild(context, host, next, id);
  else replaceHost(context, host, next);
  return next;
}

function updateRow(context, old, root) {
  const oldOwned = isOwnedComponent(old);
  const rootOwned = isOwnedComponent(root);
  // a nested component root updates itself
  if (oldOwned && rootOwned) return old;
  if (!oldOwned && !rootOwned && old.tagName === root.tagName) {
    morphElement(context, old, root);
    return old;
  }
  old.replaceWith(root);
  unregisterSubtree(context, old);
  return root;
}

/**
 * Animations and transitions, on the element or inside it. Checks again after
 * they settle, CSS that changed mid-exit may have started others.
 */
async function whenAnimationDone(element, signal) {
  if (typeof element.getAnimations !== "function") {
    // jsdom has no animations, only the declared override
    const declared = /--lily-transition-duration:\s*(\d+)ms/.exec(
      element.getAttribute("style") ?? "",
    );
    if (declared) await delay(Number(declared[1]) + 60, signal);
    return;
  }
  for (let round = 0; round < 10 && !signal?.aborted; round++) {
    const running = finiteAnimations(element);
    if (running.length === 0) return;
    const remaining = Math.max(
      ...running.map(
        (animation) =>
          animation.effect.getComputedTiming().endTime -
          (animation.currentTime ?? 0),
      ),
    );
    // a paused or missed animation
    const backstop = delay(remaining + 100, signal);
    await Promise.race([
      Promise.allSettled(running.map((animation) => animation.finished)),
      backstop,
    ]);
  }
}

function wrapNodes(context, nodes, before, contents) {
  const wrapper = document.createElement("div");
  if (contents) wrapper.setAttribute("style", "display: contents");
  before?.parentNode.insertBefore(wrapper, before);
  for (const node of nodes) wrapper.appendChild(node);
  context.wrappers.add(wrapper);
  return wrapper;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// renderer state per runtime, the runtime is component-agnostic
const contexts = new WeakMap();

// setting or removing one of these changes what an embedded document may do
const GUARD_ATTRIBUTES = new Set(["allow", "csp", "sandbox"]);

// comment marks around a component that needs an element
const MARK = "lily-root";

const MEDIA_SOURCE_ATTRIBUTES = new Set(["src", "srcset"]);

const MEDIA_TAGS = new Set(["AUDIO", "IMG", "SOURCE", "TRACK", "VIDEO"]);

// split is global regardless of the `g` flag
const NEST_PATTERN = /<lily-nest[^>]*>\s*<\/lily-nest>/;

const ROW_SEPARATOR = "lily-row";

let runtimeCount = 0;

const SVG_ANIMATION_ATTRIBUTES = new Set([
  "attributename",
  "by",
  "from",
  "to",
  "values",
]);

// upper-cased, an SVG element's tagName keeps its own case
const SVG_ANIMATIONS = new Set(["ANIMATE", "ANIMATEMOTION", "SET"]);

const UNSAFE_URL_SCHEME = /^(?:javascript|vbscript):/;

const URL_ATTRIBUTES = new Set([
  "action",
  "background",
  "cite",
  "data",
  "formaction",
  "href",
  "longdesc",
  "ping",
  "poster",
  "src",
  "srcset",
  "xlink:href",
]);
