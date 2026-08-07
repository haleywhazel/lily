//// Random identifiers, client IDs on the server and session IDs on the
//// client.
////
//// `crypto` on Erlang and WebCrypto in the browser.

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// A random lowercase hex string of `byte_count` bytes, so twice that many
/// characters.
@external(erlang, "lily_id_ffi", "random_hex")
@external(javascript, "./id.ffi.mjs", "randomHex")
@internal
pub fn random_hex(byte_count: Int) -> String
