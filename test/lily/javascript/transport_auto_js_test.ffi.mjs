/**
 * TRANSPORT AUTO TEST FFI
 *
 * Auto-codec registry seams, fixture and clashing registrations.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { CustomType } from "../../gleam.mjs";
import { Some } from "../../../gleam_stdlib/gleam/option.mjs";
import * as verdict from "./verdict_fixture.mjs";
import { registerModule } from "../internal/codec.ffi.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Register an app class that reuses the built-in `Some` name and arity. */
export function registerImpostorSome() {
  class Impostor extends CustomType {
    constructor(value) {
      super();
      this.value = value;
    }
  }
  Object.defineProperty(Impostor, "name", { value: "Some" });
  registerModule({ Some: Impostor });
  // restore the real `Some` so later tests still decode Option
  const warn = console.warn;
  console.warn = () => {};
  try {
    registerModule({ Some });
  } finally {
    console.warn = warn;
  }
}

/** Register the verdict fixture module. */
export function registerThisModule() {
  registerModule(verdict);
}

/** Register two different classes that share a name and an arity. */
export function registerTwins() {
  class Twin extends CustomType {
    constructor(value) {
      super();
      this.value = value;
    }
  }
  const first = Twin;
  class Other extends CustomType {
    constructor(value) {
      super();
      this.value = value;
    }
  }
  Object.defineProperty(Other, "name", { value: "Twin" });
  registerModule({ Twin: first });
  registerModule({ Twin: Other });
}
