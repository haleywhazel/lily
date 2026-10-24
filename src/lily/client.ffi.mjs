/**
 * CLIENT RUNTIME
 *
 * Model, observers and renderers driven by a FIFO step queue. DOM-free, the
 * component layer registers the renderers.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Error, Ok } from "../gleam.mjs";
import { log } from "./internal/actor.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

export function addObserver(runtime, observer) {
  runtime.observers.push(observer);
}

export function createRuntime(model) {
  const runtime = {
    model,
    observers: [],
    renderers: [],
    queue: [],
    draining: false,
    // steps wait while the embedded snapshot loads
    held: false,
    connected: false,
    scheduled: false,
    dirty: false,
    addRenderer(renderer) {
      runtime.renderers.push(renderer);
    },
  };
  return runtime;
}

export function getModel(runtime) {
  return runtime.model;
}

export function holdSteps(runtime) {
  runtime.held = true;
}

/** Skips the per-frame throttle. */
export function initialNotify(runtime) {
  flushNotify(runtime);
}

export function isSame(left, right) {
  return left === right;
}

/** `true` when the runtime was connected already. */
export function markConnected(runtime) {
  if (runtime.connected) return true;
  runtime.connected = true;
  return false;
}

/** The last match, user content carrying the id comes earlier. */
export function readEmbeddedSnapshot() {
  if (typeof document === "undefined") return new Error(undefined);
  const scripts = document.querySelectorAll(
    'script#lily-snapshot[type="application/octet-stream"]',
  );
  const text = scripts[scripts.length - 1]?.textContent;
  if (!text) return new Error(undefined);
  return new Ok(text);
}

export function releaseSteps(runtime) {
  runtime.held = false;
  if (runtime.queue.length > 0 && !runtime.draining) drain(runtime);
}

/** Re-entrant calls only enqueue. A throwing step is logged and skipped. */
export function run(runtime, step) {
  runtime.queue.push(step);
  if (runtime.draining || runtime.held) return;
  drain(runtime);
}

/** Queues `effect` in line with the steps, no model change, no observers. */
export function runEffect(runtime, effect) {
  run(runtime, () => {
    effect();
    return undefined;
  });
}

/** Skips the observers and renderers. */
export function setModel(runtime, model) {
  runtime.model = model;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function describe(error) {
  return error?.stack ?? String(error);
}

// `draining` resets however a step ends, a wedged flag would stop everything
function drain(runtime) {
  const queue = runtime.queue;
  // an index, a shift per step is quadratic on a long burst
  let index = 0;
  runtime.draining = true;
  try {
    while (index < queue.length) {
      const step = queue[index];
      queue[index++] = undefined;
      let next;
      try {
        next = step(runtime.model);
      } catch (error) {
        log("error", `lily: a client update crashed: ${describe(error)}`);
        continue;
      }
      // an effect, nothing changed and nothing to observe
      if (!Array.isArray(next)) continue;
      runtime.model = next[0];
      for (const observer of runtime.observers) {
        try {
          observer(next[1], runtime.model);
        } catch (error) {
          log("error", `lily: an observer crashed: ${describe(error)}`);
        }
      }
    }
  } finally {
    queue.splice(0, index);
    runtime.draining = false;
  }
  scheduleNotify(runtime);
}

// a throwing renderer is logged once and can't stop the others
function flushNotify(runtime) {
  for (const renderer of runtime.renderers) {
    try {
      renderer(runtime.model);
    } catch (error) {
      if (crashedRenderers.has(renderer)) continue;
      crashedRenderers.add(renderer);
      log("error", `lily: a renderer crashed: ${describe(error)}`);
    }
  }
}

// a timer stands in where there's no `requestAnimationFrame`, a worker say
function nextFrame(callback) {
  if (typeof requestAnimationFrame === "function")
    requestAnimationFrame(callback);
  else setTimeout(callback, 16);
}

// renders the first and last model of a frame's burst
function scheduleNotify(runtime) {
  if (runtime.scheduled) {
    runtime.dirty = true;
    return;
  }
  runtime.scheduled = true;
  // the next frame is asked for whatever happens, `scheduled` always resets
  try {
    flushNotify(runtime);
  } finally {
    nextFrame(() => {
      runtime.scheduled = false;
      if (runtime.dirty) {
        runtime.dirty = false;
        flushNotify(runtime);
      }
    });
  }
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

const crashedRenderers = new WeakSet();
