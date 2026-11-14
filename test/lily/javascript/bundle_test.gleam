// registerBundled, as a bundle entry calls it, on a fresh codec instance

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/javascript/promise.{type Promise}
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/javascript/bundle_fixture.{type Parcel, Parcel}

// =============================================================================
// BUNDLED MODULES
// =============================================================================

@target(javascript)
pub fn bundled_module_registers_without_an_import_test() -> Promise(Nil) {
  use #(synchronous, decoded) <- promise.map(decode_bundled())
  synchronous |> should.be_true
  decoded |> should.equal(Ok(Parcel(label: "box")))
}

@target(javascript)
pub fn module_left_out_of_the_bundle_logs_once_test() -> Promise(Nil) {
  use #(synchronous, lines) <- promise.map(request_unbundled())
  synchronous |> should.be_true
  lines
  |> list.filter(string.contains(_, "lily/lily/javascript/left_out"))
  |> list.length
  |> should.equal(1)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./bundle_test.ffi.mjs", "decodeBundled")
fn decode_bundled() -> Promise(#(Bool, Result(Parcel, Nil)))

@target(javascript)
@external(javascript, "./bundle_test.ffi.mjs", "requestUnbundled")
fn request_unbundled() -> Promise(#(Bool, List(String)))
