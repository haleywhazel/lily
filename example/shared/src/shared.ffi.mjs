import { registerModule } from "../lily/lily/transport.ffi.mjs";

import * as self from "./shared.mjs";

// For multiple Gleam modules, add them as imports and within registerTypes()
//
// import * as otherModule from "./other_module.mjs"

export function registerTypes() {
  registerModule(self);
  // For multiple Gleam modules, add them as imports and within registerTypes()
  //
  // registerModule(otherModule);
}
