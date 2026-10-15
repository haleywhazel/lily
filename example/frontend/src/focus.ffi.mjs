// A single focus trap and a plain focus call, enough for the example's
// dialog.

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

let active = null;

export function focus(selector) {
  // Two frames, so a render batched into the next frame has landed first.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      const element = document.querySelector(selector);
      if (element && typeof element.focus === "function") element.focus();
    });
  });
}

export function releaseTrap() {
  active = null;
}

export function trap(within, releaseOn, onExit) {
  active = { within, releaseOn, onExit };
}

document.addEventListener(
  "keydown",
  (event) => {
    if (!active) return;
    if (active.releaseOn(event.key)) {
      event.preventDefault();
      const { onExit } = active;
      active = null;
      onExit();
      return;
    }
    if (event.key !== "Tab") return;
    const container = document.querySelector(active.within);
    if (!container) return;
    const items = Array.from(container.querySelectorAll(FOCUSABLE));
    if (items.length === 0) return;
    const first = items[0];
    const last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  },
  true,
);
