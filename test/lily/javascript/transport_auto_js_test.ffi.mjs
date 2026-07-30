import * as fixtures from "../test_support.mjs";
import { registerModule } from "../transport.ffi.mjs";

export function registerTestFixtures() {
  registerModule(fixtures);
}
