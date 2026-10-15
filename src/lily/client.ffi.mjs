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

/** Skips the per-frame throttle. */
export function initialNotify(runtime) {
  flushNotify(runtime);
}

export function readEmbeddedSnapshot() {
  if (typeof document === "undefined") return new Error(undefined);
  const text = document.getElementById("lily-snapshot")?.textContent;
  if (!text) return new Error(undefined);
  return new Ok(text);
}

/** Re-entrant calls only enqueue. A throwing step is logged and skipped. */
export function run(runtime, step) {
  const queue = runtime.queue;
  queue.push(step);
  if (runtime.draining) return;
  runtime.draining = true;
  while (queue.length > 0) {
    let next;
    try {
      next = queue.shift()(runtime.model);
    } catch (error) {
      log("error", `lily: a client update crashed: ${describe(error)}`);
      continue;
    }
    runtime.model = next[0];
    for (const observer of runtime.observers) {
      try {
        observer(next[1], runtime.model);
      } catch (error) {
        log("error", `lily: an observer crashed: ${error}`);
      }
    }
  }
  runtime.draining = false;
  scheduleNotify(runtime);
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

function flushNotify(runtime) {
  for (const renderer of runtime.renderers) renderer(runtime.model);
}

/** Renders the first and last model of a frame's burst. */
function scheduleNotify(runtime) {
  if (runtime.scheduled) {
    runtime.dirty = true;
    return;
  }
  runtime.scheduled = true;
  flushNotify(runtime);
  requestAnimationFrame(() => {
    runtime.scheduled = false;
    if (runtime.dirty) {
      runtime.dirty = false;
      flushNotify(runtime);
    }
  });
}
