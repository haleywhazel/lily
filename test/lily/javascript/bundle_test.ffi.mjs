/**
 * BUNDLE TEST FFI
 *
 * Drives a fresh codec instance the way a bundle entry does, so the bundle
 * flag never reaches the other tests.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { toList } from "../../gleam.mjs";
import * as parcel from "./bundle_fixture.mjs";
import { ReflectedConstructor, ReflectedString } from "../internal/codec.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** `#(registered synchronously, decoded Parcel)` from a bundled namespace. */
export async function decodeBundled() {
  const codec = await bundleCodec("decode");
  codec.registerBundled({ "lily/lily/javascript/bundle_fixture": parcel });
  codec.requestModule("lily", "lily/javascript/bundle_fixture");
  let synchronous = false;
  codec.whenRegistered(() => {
    synchronous = true;
  });
  const decoded = codec.construct(
    new ReflectedConstructor("Parcel", toList([new ReflectedString("box")])),
  );
  return [synchronous, decoded];
}

/** `#(registered synchronously, errors logged)` for a module left out. */
export async function requestUnbundled() {
  const codec = await bundleCodec("missing");
  codec.registerBundled({ "lily/lily/javascript/bundle_fixture": parcel });
  const lines = [];
  const original = console.error;
  console.error = (...parts) => lines.push(parts.join(" "));
  try {
    codec.requestModule("lily", "lily/javascript/left_out");
    codec.requestModule("lily", "lily/javascript/left_out");
  } finally {
    console.error = original;
  }
  let synchronous = false;
  codec.whenRegistered(() => {
    synchronous = true;
  });
  return [synchronous, toList(lines)];
}

// =============================================================================
// FUNCTIONS
// =============================================================================

// a query string makes a separate module instance with its own registry
function bundleCodec(label) {
  return import(`../internal/codec.ffi.mjs?bundle-${label}`);
}
