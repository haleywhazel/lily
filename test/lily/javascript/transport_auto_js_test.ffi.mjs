import * as fixtures from "../test_fixtures.mjs";
import { registerModule } from "../transport.ffi.mjs";

export function registerTestFixtures() {
  registerModule(fixtures);
}
