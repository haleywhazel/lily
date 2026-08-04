//// Random identifiers, client IDs on the server and session IDs on the
//// client. One entry point over a small FFI per target, `crypto` on Erlang
//// and WebCrypto in the browser. It cannot go through `gleam_crypto`, whose
//// JavaScript FFI statically imports `node:crypto` and so will not load in a
//// browser.

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// A random lowercase hex string of `byte_count` bytes, so twice that many
/// characters.
@internal
@external(erlang, "lily_id_ffi", "random_hex")
@external(javascript, "./id.ffi.mjs", "randomHex")
pub fn random_hex(byte_count: Int) -> String
