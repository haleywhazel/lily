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

/** Identity, backs Gleam-side unsafe_cast for phantom-typed Event payloads. */
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

/** Click handler with data-message delegation and options. */
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "click\x1f" + selector,
    document,
    "click",
    false,
    listener,
  );
}

/**
 * Coordinate event with x,y plus the concrete target's data-* attributes and
 * options. The selector is the match gate, the ElementData is read from
 * event.target (the element that fired), so a scoped listener on `#<id>` still
 * distinguishes the sub-element acted on. preventDefault is hoisted outside
 * debounce/throttle so drop targets stay receptive. Delegates via document so
 * it works on dynamically-rendered lists.
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
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest("[data-lily-disabled]")) return;
    handler(
      event.clientX,
      event.clientY,
      makeElementData(datasetToList(event.target)),
    );
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "coordel\x1f" + eventName + "\x1f" + selector,
    document,
    eventName,
    false,
    listener,
  );
}

/** Coordinate event (mouse/touch/pointer) with x,y position and options. */
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "coord\x1f" + eventName + "\x1f" + selector,
    delegationRoot(selector),
    eventName,
    false,
    listener,
  );
}

/**
 * Element-delegated event passing the matched element's data-* attributes,
 * with options. Non-bubbling events (mouseenter, mouseleave, focus, blur) map
 * to their bubbling equivalents with a relatedTarget guard.
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
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest("[data-lily-disabled]")) return;
    const matched = event.target;
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "el\x1f" + eventName + "\x1f" + selector,
    document,
    domEvent,
    false,
    listener,
  );
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
 * Register elements as an arrow-navigable grid of `columns` columns (roving
 * tabindex in 2D). Left/right move one cell, up/down a full row. Shares the
 * focus-group registry and keydown handler, so releaseFocusGroup removes it.
 */
export function setupFocusGrid(items, columns, wrap) {
  focusGroups.set(items, { columns, wrap });
  installGroupKeydownHandler();
}

/**
 * Register a set of sibling elements as an arrow-navigable focus group (the
 * roving-tabindex pattern). Several groups coexist, the active one on a
 * keypress is whichever contains the focused element.
 */
export function setupFocusGroup(items, orientation, wrap) {
  focusGroups.set(items, { orientation, wrap });
  installGroupKeydownHandler();
}

/**
 * Push a new focus trap onto the stack. Tab cycles within `within` while
 * this trap is the top of the stack, releaseOn runs on every keydown and
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
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest?.("[data-lily-disabled]")) return;
    const form = event.target.closest?.("form");
    if (!(form instanceof HTMLFormElement)) return;
    handler(formDataToList(form));
  };
  listener = applyOptions(
    listener,
    debounceMs,
    throttleMs,
    once,
    stopPropagation,
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "formchange\x1f" + selector,
    document,
    "input",
    false,
    listener,
  );
}

/** Keyboard event passing key name and modifier flags, with options. */
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
    if (!matchesSelectorScope(event, selector)) return;
    if (event.target.closest?.("[data-lily-disabled]")) return;
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "key\x1f" + eventName + "\x1f" + selector,
    document,
    eventName,
    false,
    listener,
  );
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "scroll\x1f" + selector,
    delegationRoot(selector),
    "scroll",
    true,
    listener,
  );
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "simple\x1f" + eventName + "\x1f" + selector,
    delegationRoot(selector),
    eventName,
    false,
    listener,
  );
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
    if (!matchesSelectorScope(event, selector)) return;
    const form = event.target.closest?.("form");
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
    selector,
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
  registerDelegatedListener(
    "formsubmit\x1f" + selector,
    document,
    "submit",
    false,
    listener,
  );
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "value\x1f" + eventName + "\x1f" + selector,
    document,
    eventName,
    false,
    listener,
  );
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
    selector,
  );
  if (preventDefault) listener = preventDefaultFirst(listener);
  registerDelegatedListener(
    "wheel\x1f" + selector,
    document,
    "wheel",
    false,
    listener,
  );
}

/**
 * Warn that an `event.on*` binding was attached to a component with no scope,
 * so it fell back to a document-wide listener. Nudges the author to give the
 * component an `id` (or call `component.scoped`) so the listener is confined
 * to its own subtree.
 */
export function warnScopeless() {
  console.warn(
    "lily/event: on* was attached to a component with no scope; the listener " +
      "falls back to document-wide matching. Give the component an id (or call " +
      "component.scoped) to confine it, or use on_global for a deliberate " +
      "page-level listener.",
  );
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

/**
 * Install a document-level Escape-to-dismiss handler. Idempotent. On Escape,
 * the topmost element carrying `data-lily-escape-dismiss` is consulted, its
 * attribute value is a CSS selector, and the element it points at is clicked.
 * Dismissal flows through the ordinary data-message delegation without trapping
 * focus, so non-modal overlays (popover, menu, select, date picker) can close
 * on Escape while staying non-modal.
 */
export function watchEscapeDismiss() {
  if (escapeDismissHandler !== null) return;
  escapeDismissHandler = (event) => {
    if (event.key !== "Escape") return;
    const openers = document.querySelectorAll("[data-lily-escape-dismiss]");
    if (openers.length === 0) return;
    // Last in document order is the most-recently opened / innermost overlay.
    const opener = openers[openers.length - 1];
    const selector = opener.getAttribute("data-lily-escape-dismiss") || "";
    if (selector === "") return;
    const target = document.querySelector(selector);
    if (target && typeof target.click === "function") {
      // Consume the key and click the dismiss target, so dismissal flows
      // through the ordinary data-message delegation. Mirrors a focus trap's
      // Escape dismiss, without trapping focus.
      event.preventDefault();
      target.click();
    }
  };
  // Capture phase so Escape dismisses even when focus sits outside the panel.
  document.addEventListener("keydown", escapeDismissHandler, true);
}

/**
 * Install a document-level drag-and-drop handler for file dropzones.
 * Idempotent. A dropzone opts in with `data-lily-file-drop="<input selector>"`,
 * dropping files onto it assigns them to that input and fires a `change` event,
 * so drops flow through the same path as picking files. While a drag is over
 * the zone it carries a `data-lily-file-dragover` attribute for styling.
 */
export function watchFileDrops() {
  if (fileDropsInstalled) return;
  fileDropsInstalled = true;
  const zoneOf = (event) => event.target.closest?.("[data-lily-file-drop]");

  document.addEventListener("dragover", (event) => {
    const zone = zoneOf(event);
    if (!zone) return;
    event.preventDefault();
    zone.setAttribute("data-lily-file-dragover", "");
  });
  document.addEventListener("dragleave", (event) => {
    const zone = zoneOf(event);
    if (zone && !zone.contains(event.relatedTarget)) {
      zone.removeAttribute("data-lily-file-dragover");
    }
  });
  document.addEventListener("drop", (event) => {
    const zone = zoneOf(event);
    if (!zone) return;
    event.preventDefault();
    zone.removeAttribute("data-lily-file-dragover");
    const input = document.querySelector(
      zone.getAttribute("data-lily-file-drop") || "",
    );
    if (!input || input.disabled || !event.dataTransfer) return;
    input.files = event.dataTransfer.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

/**
 * Manage native <details> popups carrying `data-lily-focus-on-open`. Opening
 * seeds focus on the selected option (arrow group and typeahead then work with
 * no manual tab in), Escape closes it back to the summary, and focus leaving it
 * closes it so it never blocks the next tab stop. Closing via `open = false`
 * never steals the incoming focus. toggle and focusout do not bubble, so both
 * listen in the capture phase.
 */
export function watchDetailsOpen() {
  if (detailsOpenHandler !== null) return;
  detailsOpenHandler = (event) => {
    const details = event.target;
    if (!details.matches || !details.matches("[data-lily-focus-on-open]")) return;
    if (!details.open) return;
    const target =
      details.querySelector('[aria-selected="true"]') || firstFocusable(details);
    if (target) target.focus();
  };
  document.addEventListener("toggle", detailsOpenHandler, true);

  document.addEventListener(
    "keydown",
    (event) => {
      if (event.key !== "Escape") return;
      const details = event.target.closest?.(
        "[data-lily-focus-on-open][open]",
      );
      if (!details) return;
      event.preventDefault();
      details.open = false;
      details.querySelector("summary")?.focus();
    },
    true,
  );

  document.addEventListener(
    "focusout",
    (event) => {
      const details = event.target.closest?.(
        "[data-lily-focus-on-open][open]",
      );
      if (!details) return;
      if (event.relatedTarget && details.contains(event.relatedTarget)) return;
      details.open = false;
    },
    true,
  );
}

/**
 * Install a document-level handler that dismisses a model-controlled popup when
 * focus leaves it. A panel opts in with `data-lily-focusout-dismiss="<trigger
 * selector>"`. The dismiss is deferred a frame and only fires if the trigger is
 * still `aria-expanded="true"`, so picking an option (which closes via its own
 * message) does not race into a reopen. Clicking the trigger does not steal the
 * incoming focus, so the tab moves on. focusout does not bubble, capture it.
 */
export function watchFocusoutDismiss() {
  if (focusoutDismissHandler !== null) return;
  focusoutDismissHandler = (event) => {
    const panel = event.target.closest?.("[data-lily-focusout-dismiss]");
    if (!panel) return;
    if (event.relatedTarget && panel.contains(event.relatedTarget)) return;
    const selector = panel.getAttribute("data-lily-focusout-dismiss") || "";
    const trigger = selector && document.querySelector(selector);
    if (!trigger) return;
    requestAnimationFrame(() => {
      if (trigger.getAttribute("aria-expanded") === "true") trigger.click();
    });
  };
  document.addEventListener("focusout", focusoutDismissHandler, true);
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
    // Escape dismisses only when the element names a dismiss target, without
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
  // itself was triggered by a mutation, so layout is imminent). preventScroll
  // keeps a bare focus from scrolling the modal into view, which jumps the
  // page on open.
  requestAnimationFrame(() => {
    const target =
      (initial && document.querySelector(initial)) ||
      firstFocusable(element) ||
      element;
    if (target && typeof target.focus === "function")
      target.focus({ preventScroll: true });
  });
}

/**
 * Wraps a raw DOM event listener with optional debounce, throttle, once, and
 * stopPropagation behaviours. debounceMs and throttleMs are -1 when disabled.
 * Applied in this order, stopPropagation then once then throttle then debounce
 * (outermost last, so debounce gates before throttle fires).
 *
 * preventDefault is handled separately in preventDefaultFirst so it
 * fires unconditionally even when the inner handler is throttled/debounced.
 */
function applyOptions(
  listener,
  debounceMs,
  throttleMs,
  once,
  stopPropagation,
  selector,
) {
  if (stopPropagation) {
    const inner = listener;
    listener = (event) => {
      // Delegated handlers all live on the same node (document, or window
      // for window-only events), so a plain stopPropagation would not stop
      // the other delegated listeners on that node, only propagation to
      // ancestors. stopImmediatePropagation also skips the same-node
      // listeners registered after this one, which is what lets a specific
      // handler block a broader ancestor-selector handler registered later.
      // Scope the suppression to events matching this binding's selector so a
      // listener still attached from an earlier mount cannot swallow unrelated
      // events on the shared node.
      if (selector === undefined || matchesSelectorScope(event, selector)) {
        event.stopImmediatePropagation();
      }
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
 * e.g. data-card-id="3" becomes ["card-id", "3"]
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
    // preventScroll so restoring focus to the opener does not jump the page
    // back when the modal closes.
    opener.focus({ preventScroll: true });
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
 * window, everything else delegates from document.
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

/**
 * Arrow-key step for a grid focus group. Left/right move by one, up/down by a
 * full row (`columns`). Returns 0 for keys that shouldn't move focus.
 */
function gridStep(key, columns) {
  if (key === "ArrowRight") return 1;
  if (key === "ArrowLeft") return -1;
  if (key === "ArrowDown") return columns;
  if (key === "ArrowUp") return -columns;
  return 0;
}

function groupStep(key, orientation) {
  const horizontal = orientation === "horizontal" || orientation === "both";
  const vertical = orientation === "vertical" || orientation === "both";
  if (vertical && key === "ArrowDown") return 1;
  if (vertical && key === "ArrowUp") return -1;
  if (horizontal && key === "ArrowRight") return 1;
  if (horizontal && key === "ArrowLeft") return -1;
  return 0;
}

// Printable keys build up a prefix within the debounce window, cleared on pause.
let typeaheadBuffer = "";
let typeaheadClearTimer = null;

/**
 * Focus the next group item whose label matches the typed buffer. A repeat of
 * one key cycles same-initial items, a growing prefix narrows. Returns the
 * matched index or -1.
 */
function typeaheadMatch(items, current, key) {
  if (typeaheadClearTimer !== null) clearTimeout(typeaheadClearTimer);
  typeaheadClearTimer = setTimeout(() => {
    typeaheadBuffer = "";
    typeaheadClearTimer = null;
  }, 500);

  const repeat = typeaheadBuffer === key;
  typeaheadBuffer = repeat ? key : typeaheadBuffer + key;
  const prefix = typeaheadBuffer.toLowerCase();

  // Single char looks past the current item to cycle, a prefix re-checks it.
  const start = typeaheadBuffer.length === 1 ? current + 1 : current;
  for (let offset = 0; offset < items.length; offset++) {
    const index = (start + offset) % items.length;
    const label = (items[index].textContent || "").trim().toLowerCase();
    if (label.startsWith(prefix)) return index;
  }
  return -1;
}

/** A printable single character with no command modifier, i.e. typeahead. */
function isTypeaheadKey(event) {
  return (
    event.key.length === 1 &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey
  );
}

/**
 * Move focus among a group's items when an Arrow/Home/End key is pressed, or
 * jump by typeahead when a printable key is pressed, while focus sits on one of
 * them. Items are re-queried per keypress so dynamically-rendered groups are
 * handled. Focus moves via element.focus(), which works even on the
 * tabindex="-1" items of a roving-tabindex render.
 */
function handleGroupKeydown(event) {
  const active = document.activeElement;
  if (!active) return;

  for (const [selector, config] of focusGroups) {
    const items = Array.from(document.querySelectorAll(selector));
    const current = items.indexOf(active);
    if (current === -1) continue;

    if (isTypeaheadKey(event)) {
      const match = typeaheadMatch(items, current, event.key);
      if (match !== -1) {
        event.preventDefault();
        items[match].focus();
      }
      return;
    }

    let next;
    if (event.key === "Home") {
      next = 0;
    } else if (event.key === "End") {
      next = items.length - 1;
    } else {
      const step = config.columns
        ? gridStep(event.key, config.columns)
        : groupStep(event.key, config.orientation);
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
    // Escape is a stack. A non-modal overlay opened on top (popover, menu,
    // ...) handles Escape first via watchEscapeDismiss and marks it handled.
    // Only dismiss this trapped modal once nothing shallower has claimed the
    // key, so one Escape closes exactly one overlay.
    if (event.defaultPrevented) return;
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
 * selector, treating 'document' and 'window' as 'anywhere on the page'.
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
 * Register a delegated listener, replacing any prior one with the same key.
 *
 * `key` identifies the binding by its event semantics and selector, not the
 * closure, so re-registering the same logical binding (which happens every
 * time a component re-renders and drains its bindings) swaps the stale
 * listener for the fresh one instead of stacking. Exactly one live listener
 * per (event, selector), so co-located events survive navigation without
 * duplicate dispatches. Distinct events or selectors coexist.
 */
function registerDelegatedListener(key, target, domEvent, capture, listener) {
  const existing = delegatedListeners.get(key);
  if (existing) {
    existing.target.removeEventListener(
      existing.domEvent,
      existing.listener,
      existing.capture,
    );
  }
  target.addEventListener(domEvent, listener, capture);
  delegatedListeners.set(key, { target, domEvent, listener, capture });
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

// One live delegated listener per binding key (see registerDelegatedListener).
// Keyed by event semantics + selector so a re-registered binding replaces its
// predecessor rather than stacking, distinct events/selectors coexist.
const delegatedListeners = new Map();

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
// on a page, the active group on a keypress is the one whose items include
// the focused element. One document-level keydown listener serves them all.
const focusGroups = new Map();

let groupKeydownHandler = null;

let trapKeydownHandler = null;

// Document-level Escape-to-dismiss handler installed by watchEscapeDismiss.
// Unlike a focus trap it holds no state beyond the listener itself. On every
// Escape it consults the live DOM for the topmost element opting into
// dismissal, so it needs no observer or registry.
let escapeDismissHandler = null;

// Guards the idempotent install of the file-drop handlers (watchFileDrops).
let fileDropsInstalled = false;

// Document-level toggle handler installed by watchDetailsOpen. Seeds focus into
// a <details data-lily-focus-on-open> as it opens, holds no state.
let detailsOpenHandler = null;

// Document-level focusout handler installed by watchFocusoutDismiss. Closes a
// model-controlled popup when focus leaves it, holds no state.
let focusoutDismissHandler = null;

// Declarative focus traps. The observer installed by watchFocusTraps
// confines focus to any element carrying `data-lily-focus-trap` while it is
// in the DOM, seeds its initial focus, and restores focus to the opener when
// it leaves.
//
// Each tracked element remembers the trap it pushed and the element focused
// before it opened.
let trapObserver = null;

// Stack of focus traps. Each entry is { within, releaseOn, onExit }. The
// top of the stack is the active trap, entries below are suspended until
// the entries above them are popped. A single document-level keydown
// listener (trapKeydownHandler) consults the top entry on every keypress,
// so nested overlays each get deterministic focus behaviour without
// listener races.
const trapStack = [];
