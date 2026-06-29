/**
 * This mjs file attaches event listeners to DOM elements. Every setup*
 * function delegates from the document (or window for window-only events
 * like resize) and filters by selector inside the listener, so a handler
 * survives any number of innerHTML re-renders of its target. The selector
 * scopes WHICH clicks match, not WHERE the listener lives.
 *
 * The *WithOptions variants accept an options array [debounceMs, throttleMs,
 * once, stopPropagation, preventDefault] (debounceMs and throttleMs are -1
 * when disabled). applyOptions wraps a raw DOM event listener with these
 * behaviours. preventDefaultFirst wraps the listener so that preventDefault
 * fires on every event even when debounce/throttle would skip the inner
 * handler.
 *
 * Non-bubbling events (mouseenter/mouseleave, focus/blur) are mapped to
 * their bubbling equivalents (mouseover/mouseout, focusin/focusout) with a
 * relatedTarget guard to preserve enter/leave semantics. Scroll uses
 * capture-phase delegation because scroll does not bubble.
 */

import { NonEmpty, Empty } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/**
 * Identity, used by Gleam-side unsafe_cast for phantom-typed Event
 * payloads.
 */
export function identity(value) {
  return value;
}

/**
 * Remove a focus group registered with setupFocusGroup, matched by its items
 * selector. No-op when no such group is registered.
 */
export function releaseFocusGroup(items) {
  focusGroups.delete(items);
  if (focusGroups.size === 0) uninstallGroupKeydownHandler();
}

/**
 * Pop the top focus trap, the imperative counterpart to watchFocusTraps for
 * traps pushed with setupFocusTrap. If another trap is below it that one
 * becomes active again. No onExit dispatched. No-op when the stack is empty.
 */
export function releaseFocusTrap() {
  popFocusTrap();
}

/**
 * Attaches a click event handler with data-message attribute delegation and
 * options.
 */
export function setupClickEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest("[data-message]");
    if (!matched) return;
    handler(matched.getAttribute("data-message"));
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener("click", listener);
}

/**
 * Attaches a coordinate event with x,y position, the matched element's
 * data-* attributes, and options. preventDefault is hoisted outside
 * debounce/throttle so drop targets stay receptive even when the inner
 * handler is suppressed. Uses event delegation via document so it works on
 * dynamically-rendered lists.
 */
export function setupCoordinateElementEventWithOptions(
  selector,
  eventName,
  options,
  makeElementData,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    handler(
      event.clientX,
      event.clientY,
      makeElementData(datasetToList(matched)),
    );
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(eventName, listener);
}

/**
 * Attaches a coordinate event (mouse/touch/pointer) with x,y position and
 * options.
 */
export function setupCoordinateEventWithOptions(
  selector,
  eventName,
  options,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.clientX, event.clientY);
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  delegationRoot(selector).addEventListener(eventName, listener);
}

/**
 * Attaches an element-delegated event that provides the matched element's
 * data-* attributes to the handler, with options. Non-bubbling events
 * (mouseenter, mouseleave, focus, blur) are mapped to their bubbling
 * equivalents with a relatedTarget guard to preserve semantics.
 */
export function setupElementEventWithOptions(
  selector,
  eventName,
  options,
  makeElementData,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  const domEvent = delegatedEventName(eventName);
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    if (shouldSkipDelegatedEvent(eventName, matched, event.relatedTarget))
      return;
    handler(makeElementData(datasetToList(matched)));
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(domEvent, listener);
}

/** Move focus to the first match of selector after the next paint. */
export function setupFocus(selector) {
  // Two rAFs guard against the case where the dispatch that reveals the
  // target was itself batched into the next frame (Lily's render loop).
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      const element = document.querySelector(selector);
      if (element && typeof element.focus === "function") element.focus();
    });
  });
}

/**
 * Register a set of sibling elements as an arrow-navigable focus group (the
 * roving-tabindex pattern). Several groups coexist; the active one on a
 * keypress is whichever contains the focused element.
 */
export function setupFocusGroup(items, orientation, wrap) {
  focusGroups.set(items, { orientation, wrap });
  installGroupKeydownHandler();
}

/**
 * Push a new focus trap onto the stack. Tab cycles within `within` while
 * this trap is the top of the stack; releaseOn runs on every keydown and
 * returning true pops the trap and dispatches onExit. Activation is
 * deferred by two frames so a dispatch that just rendered the container
 * has a chance to flush, mirrors the rAF strategy in setupFocus.
 */
export function setupFocusTrap(within, releaseOn, onExit) {
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      trapStack.push({ within, releaseOn, onExit });
      installTrapKeydownHandler();
    });
  });
}

/**
 * Attaches an input handler to a form element, passing current FormData as a
 * Gleam list of name/value tuples. Fires on any field change (input bubbles up
 * to the form). No preventDefault, no reset. Uses delegation at document so
 * forms re-rendered by innerHTML updates keep firing.
 */
export function setupFormChangeEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    const form =
      matched instanceof HTMLFormElement ? matched : matched.closest("form");
    if (!(form instanceof HTMLFormElement)) return;
    handler(formDataToList(form));
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener("input", listener);
}

/**
 * Attaches a keyboard event that passes key name and modifier flags, with
 * options.
 */
export function setupKeyFullEventWithOptions(
  selector,
  eventName,
  options,
  makeKeyEvent,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target.closest(selector);
    if (!matched) return;
    handler(
      makeKeyEvent(
        event.key,
        event.ctrlKey,
        event.shiftKey,
        event.altKey,
        event.metaKey,
      ),
    );
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(eventName, listener);
}

/**
 * Attaches a scroll event that passes the element's scrollTop and scrollLeft
 * values (not delta, absolute position), with options. Scroll does not
 * bubble so we listen in the capture phase at the delegation root and read
 * the scroll position from the originating element.
 */
export function setupScrollPositionEventWithOptions(
  selector,
  options,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest?.("[data-lily-disabled]")) return;
    const element = event.target;
    handler(element.scrollTop ?? 0, element.scrollLeft ?? 0);
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  delegationRoot(selector).addEventListener("scroll", listener, true);
}

/** Attaches a simple event with no event data, with options */
export function setupSimpleEventWithOptions(
  selector,
  eventName,
  options,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest?.("[data-lily-disabled]")) return;
    handler();
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  delegationRoot(selector).addEventListener(eventName, listener);
}

/**
 * Attaches a submit handler that extracts FormData entries as a Gleam list of
 * name/value tuples, calls the handler, then resets the form. preventDefault
 * fires unconditionally so the browser does not navigate away. File uploads
 * are skipped. Uses delegation at document so every form matching the
 * selector is handled, including forms rendered after setup.
 */
export function setupSubmitFormEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation] = options;
  let listener = (event) => {
    const form = event.target.closest(selector);
    if (!(form instanceof HTMLFormElement)) return;
    if (form.closest("[data-lily-disabled]")) return;
    handler(formDataToList(form));
    form.reset();
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  // preventDefault is unconditional for submit, the browser would
  // otherwise navigate before the handler can run. Wrap before applyOptions
  // would put preventDefault behind debounce/throttle gates, so we layer
  // it on top.
  const inner = listener;
  listener = (event) => {
    event.preventDefault();
    inner(event);
  };
  document.addEventListener("submit", listener);
}

/** Attaches an input/change event with input value, with options */
export function setupValueEventWithOptions(
  selector,
  eventName,
  options,
  handler,
) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.target.value || "");
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener(eventName, listener);
}

/** Attaches a wheel event with deltaX and deltaY values, with options */
export function setupWheelEventWithOptions(selector, options, handler) {
  const [debounceMs, throttleMs, once, stopPropagation, preventDefault] =
    options;
  let listener = (event) => {
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(event.deltaX, event.deltaY);
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  document.addEventListener("wheel", listener);
}

/**
 * Install the document-level focus-trap observer. Idempotent. Once installed,
 * any element carrying `data-lily-focus-trap` is focus-trapped while in the
 * DOM and releases (restoring focus to its opener) when removed.
 */
export function watchFocusTraps() {
  if (trapObserver !== null) return;
  trapObserver = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType === 1) {
          collectDeclaredTraps(node).forEach(activateDeclaredTrap);
        }
      }
      for (const node of mutation.removedNodes) {
        if (node.nodeType === 1) {
          collectDeclaredTraps(node).forEach(deactivateDeclaredTrap);
        }
      }
    }
  });
  trapObserver.observe(document.body, { childList: true, subtree: true });
}


// =============================================================================
// FUNCTIONS
// =============================================================================

/** Trap focus within a freshly-mounted element and seed its initial focus. */
function activateDeclaredTrap(element) {
  if (declaredTraps.has(element)) return;
  const dismiss = element.getAttribute("data-lily-focus-trap-dismiss") || "";
  const initial = element.getAttribute("data-lily-focus-trap-initial") || "";
  const trap = {
    element,
    within: null,
    // Escape dismisses only when the element names a dismiss target; without
    // one the trap is inert (e.g. an alertdialog forcing an explicit choice).
    releaseOn: (key) => dismiss !== "" && key === "Escape",
    // Dismiss flows through the normal data-message delegation. Click the
    // element carrying the dismiss message rather than dispatch a typed
    // message, so this stays agnostic of the consumer's message type.
    onExit: () => {
      const target = document.querySelector(dismiss);
      if (target && typeof target.click === "function") target.click();
    },
  };
  trapStack.push(trap);
  installTrapKeydownHandler();
  declaredTraps.set(element, { trap, opener: document.activeElement });

  // Defer initial focus a frame so the content is laid out (the trap push
  // itself was triggered by a mutation, so layout is imminent).
  requestAnimationFrame(() => {
    const target =
      (initial && document.querySelector(initial)) ||
      firstFocusable(element) ||
      element;
    if (target && typeof target.focus === "function") target.focus();
  });
}

/**
 * Wraps a raw DOM event listener with optional debounce, throttle, once, and
 * stopPropagation behaviours. debounceMs and throttleMs are -1 when disabled.
 * Applied in order: stopPropagation → once → throttle → debounce (outermost
 * last, so debounce gates before throttle fires).
 *
 * Note: preventDefault is handled separately in preventDefaultFirst so it
 * fires unconditionally even when the inner handler is throttled/debounced.
 */
function applyOptions(listener, debounceMs, throttleMs, once, stopPropagation) {
  if (stopPropagation) {
    const inner = listener;
    listener = (event) => {
      // Delegated handlers all live on the same node (document, or window
      // for window-only events), so a plain stopPropagation would not stop
      // the other delegated listeners on that node, only propagation to
      // ancestors. stopImmediatePropagation also skips the same-node
      // listeners registered after this one, which is what lets a specific
      // handler block a broader ancestor-selector handler registered later.
      event.stopImmediatePropagation();
      inner(event);
    };
  }

  if (once) {
    const inner = listener;
    let fired = false;
    listener = (event) => {
      if (fired) return;
      fired = true;
      inner(event);
    };
  }

  if (throttleMs >= 0) {
    const inner = listener;
    let lastFired = 0;
    listener = (event) => {
      const now = Date.now();
      if (now - lastFired >= throttleMs) {
        lastFired = now;
        inner(event);
      }
    };
  }

  if (debounceMs >= 0) {
    const inner = listener;
    let timer = null;
    listener = (event) => {
      clearTimeout(timer);
      timer = setTimeout(() => inner(event), debounceMs);
    };
  }

  return listener;
}

/** Collect `node` and its descendants that declare a focus trap. */
function collectDeclaredTraps(node) {
  const traps = [];
  if (node.matches && node.matches("[data-lily-focus-trap]")) traps.push(node);
  if (node.querySelectorAll) {
    traps.push(...node.querySelectorAll("[data-lily-focus-trap]"));
  }
  return traps;
}

/**
 * Extracts all data-* attributes from an element as a Gleam list of
 * [name, value] tuples, preserving original kebab-case names.
 * e.g. data-card-id="3" → ["card-id", "3"]
 */
function datasetToList(element) {
  let list = new Empty();
  const attributes = element.attributes;
  for (let i = attributes.length - 1; i >= 0; i--) {
    const attribute = attributes[i];
    if (attribute.name.startsWith("data-")) {
      list = new NonEmpty([attribute.name.slice(5), attribute.value], list);
    }
  }
  return list;
}

/** Release a declared trap and restore focus to its opener. */
function deactivateDeclaredTrap(element) {
  const record = declaredTraps.get(element);
  if (!record) return;
  declaredTraps.delete(element);
  removeTrap(record.trap);
  const opener = record.opener;
  if (
    opener &&
    document.contains(opener) &&
    typeof opener.focus === "function"
  ) {
    opener.focus();
  }
}

/**
 * Maps non-bubbling event names to their bubbling equivalents for delegation.
 * All other events bubble and are returned unchanged.
 */
function delegatedEventName(eventName) {
  switch (eventName) {
    case "mouseenter":
      return "mouseover";
    case "mouseleave":
      return "mouseout";
    case "focus":
      return "focusin";
    case "blur":
      return "focusout";
    default:
      return eventName;
  }
}

/**
 * Pick the delegation root for a selector. Window-only events listen on
 * window; everything else delegates from document.
 */
function delegationRoot(selector) {
  return selector === "window" ? window : document;
}

/** First visible focusable descendant of `container`, or null. */
function firstFocusable(container) {
  return (
    Array.from(container.querySelectorAll(FOCUSABLE_SELECTOR)).filter(
      (element) => element.offsetParent !== null,
    )[0] || null
  );
}

/**
 * Builds a Gleam list of [name, value] tuples from a form's FormData.
 * Skips File entries (only string values are passed through).
 */
function formDataToList(form) {
  const entries = [];
  for (const [name, value] of new FormData(form)) {
    if (typeof value === "string") entries.push([name, value]);
  }
  let list = new Empty();
  for (let i = entries.length - 1; i >= 0; i--) {
    list = new NonEmpty(entries[i], list);
  }
  return list;
}

/** Arrow-key direction for an orientation: +1 (next), -1 (prev), or 0. */
function groupStep(key, orientation) {
  const horizontal = orientation === "horizontal" || orientation === "both";
  const vertical = orientation === "vertical" || orientation === "both";
  if (vertical && key === "ArrowDown") return 1;
  if (vertical && key === "ArrowUp") return -1;
  if (horizontal && key === "ArrowRight") return 1;
  if (horizontal && key === "ArrowLeft") return -1;
  return 0;
}

/**
 * Move focus among a group's items when an Arrow/Home/End key is pressed
 * while focus sits on one of them. Items are re-queried per keypress so
 * dynamically-rendered groups are handled. Focus moves via element.focus(),
 * which works even on the tabindex="-1" items of a roving-tabindex render.
 */
function handleGroupKeydown(event) {
  const active = document.activeElement;
  if (!active) return;

  for (const [selector, config] of focusGroups) {
    const items = Array.from(document.querySelectorAll(selector));
    const current = items.indexOf(active);
    if (current === -1) continue;

    let next;
    if (event.key === "Home") {
      next = 0;
    } else if (event.key === "End") {
      next = items.length - 1;
    } else {
      const step = groupStep(event.key, config.orientation);
      if (step === 0) return;
      next = current + step;
      if (next < 0 || next >= items.length) {
        if (!config.wrap) return;
        next = (next + items.length) % items.length;
      }
    }
    event.preventDefault();
    items[next].focus();
    return;
  }
}

/**
 * Handle a keydown event against the given trap. Runs releaseOn first so a
 * user-defined exit (e.g. Escape) wins over Tab cycling. The container is
 * re-queried on every keydown so DOM swaps from a parent component.simple
 * re-render do not strand the trap on a detached node. Focusables are
 * re-enumerated on every Tab press for dynamic content inside the container.
 */
function handleTrapKeydown(event, trap) {
  if (trap.releaseOn(event.key)) {
    event.preventDefault();
    popFocusTrap();
    trap.onExit();
    return;
  }
  if (event.key !== "Tab") return;

  // A trap targets either a live element (declarative focus trap) or a
  // selector re-queried each keypress (imperative focus_trap).
  const container = trap.element || document.querySelector(trap.within);
  if (!container || !document.contains(container)) return;

  const focusables = Array.from(
    container.querySelectorAll(FOCUSABLE_SELECTOR),
  ).filter((element) => element.offsetParent !== null);
  if (focusables.length === 0) {
    event.preventDefault();
    return;
  }
  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  const current = document.activeElement;

  if (event.shiftKey && current === first) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && current === last) {
    event.preventDefault();
    first.focus();
  } else if (!container.contains(current)) {
    // Focus drifted outside (e.g. window blurred and refocused), pull back.
    event.preventDefault();
    first.focus();
  }
}

/** Install the focus-group keydown listener if not already installed. */
function installGroupKeydownHandler() {
  if (groupKeydownHandler !== null) return;
  groupKeydownHandler = (event) => handleGroupKeydown(event);
  // Capture phase, like the trap listener, so navigation wins over any
  // element-level keydown handlers.
  document.addEventListener("keydown", groupKeydownHandler, true);
}

/** Install the document keydown listener if not already installed. */
function installTrapKeydownHandler() {
  if (trapKeydownHandler !== null) return;
  trapKeydownHandler = (event) => {
    const trap = topTrap();
    if (trap !== null) handleTrapKeydown(event, trap);
  };
  // Capture phase so the trap sees Tab before any element-level handlers.
  document.addEventListener("keydown", trapKeydownHandler, true);
}

/**
 * Returns true when the event happened inside an element matching the
 * selector, treating "document" and "window" as "anywhere on the page".
 */
function matchesSelectorScope(event, selector) {
  if (selector === "document" || selector === "window") return true;
  return event.target.closest?.(selector) !== null;
}

/** Pop the top trap. Uninstall the document listener if the stack empties. */
function popFocusTrap() {
  if (trapStack.length === 0) return;
  trapStack.pop();
  if (trapStack.length === 0) uninstallTrapKeydownHandler();
}

/**
 * Wraps listener so that event.preventDefault() is called on every invocation,
 * outside any debounce/throttle gate. Use this after applyOptions so
 * preventDefault fires even when the inner handler is suppressed.
 */
function preventDefaultFirst(listener) {
  return (event) => {
    event.preventDefault();
    listener(event);
  };
}

/**
 * Remove a specific trap by identity (it need not be the top, and may have
 * already been popped). Idempotent. Used by the focus-trap observer, whose
 * traps release either by the exit key (popped from the top) or by their
 * element leaving the DOM (removed here on cleanup).
 */
function removeTrap(entry) {
  const index = trapStack.indexOf(entry);
  if (index === -1) return;
  trapStack.splice(index, 1);
  if (trapStack.length === 0) uninstallTrapKeydownHandler();
}

/**
 * Returns true when the relatedTarget check should suppress the event for
 * enter/leave semantics: fire enter only when arriving from outside the
 * matched element, and leave only when departing to outside.
 */
function shouldSkipDelegatedEvent(eventName, matched, relatedTarget) {
  switch (eventName) {
    case "mouseenter":
    case "mouseleave":
    case "focus":
    case "blur":
      return relatedTarget !== null && matched.contains(relatedTarget);
    default:
      return false;
  }
}

/** Return the top of the trap stack, or null if empty. */
function topTrap() {
  return trapStack.length === 0 ? null : trapStack[trapStack.length - 1];
}

/** Remove the focus-group keydown listener if installed. */
function uninstallGroupKeydownHandler() {
  if (groupKeydownHandler === null) return;
  document.removeEventListener("keydown", groupKeydownHandler, true);
  groupKeydownHandler = null;
}

/** Remove the document keydown listener if installed. */
function uninstallTrapKeydownHandler() {
  if (trapKeydownHandler === null) return;
  document.removeEventListener("keydown", trapKeydownHandler, true);
  trapKeydownHandler = null;
}


// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const declaredTraps = new Map();

// Standard focusable-elements selector, used by setupFocusTrap to enumerate
// Tab stops inside a container.
const FOCUSABLE_SELECTOR = [
  "a[href]",
  "area[href]",
  "button:not([disabled])",
  'input:not([disabled]):not([type="hidden"])',
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])',
  '[contenteditable]:not([contenteditable="false"])',
].join(",");

// Registry of arrow-navigable focus groups, keyed by the items selector.
// Unlike traps (a LIFO stack with one active entry), several groups coexist
// on a page; the active group on a keypress is the one whose items include
// the focused element. One document-level keydown listener serves them all.
const focusGroups = new Map();

let groupKeydownHandler = null;

let trapKeydownHandler = null;

// Declarative focus traps. The observer installed by watchFocusTraps
// confines focus to any element carrying `data-lily-focus-trap` while it is
// in the DOM, seeds its initial focus, and restores focus to the opener when
// it leaves.
//
// Each tracked element remembers the trap it pushed and the element focused
// before it opened.
let trapObserver = null;

// Stack of focus traps. Each entry is { within, releaseOn, onExit }. The
// top of the stack is the active trap; entries below are suspended until
// the entries above them are popped. A single document-level keydown
// listener (trapKeydownHandler) consults the top entry on every keypress,
// so nested overlays each get deterministic focus behaviour without
// listener races.
const trapStack = [];
