// Tests for the server's static-asset policy: which file to send, how to type
// it, how long it may be cached. Pure, the filesystem arriving as an injected
// predicate, so these run on both targets and must agree on each.

import gleam/list
import gleam/option
import gleeunit/should
import lily/server

// =============================================================================
// HELPERS
// =============================================================================

const directory = "dist/assets"

const hashed = "lily-ui.a1b2c3d4.css"

// A filesystem holding exactly `present`, so a test states which precompressed
// siblings exist without touching a disk.
fn holding(present: List(String)) -> fn(String) -> Bool {
  fn(path) { list.contains(present, path) }
}

fn resolve(
  name: String,
  accepting: String,
  present: List(String),
) -> Result(server.Asset, Nil) {
  server.asset(
    name: name,
    in: directory,
    accepting: accepting,
    exists: holding(list.map(present, fn(file) { directory <> "/" <> file })),
  )
}

// =============================================================================
// NEGOTIATION
// =============================================================================

pub fn asset_serves_the_plain_file_test() {
  let assert Ok(found) = resolve(hashed, "", [hashed])

  found.path
  |> should.equal(directory <> "/" <> hashed)
  found.content_encoding
  |> should.equal(option.None)
}

pub fn asset_prefers_brotli_test() {
  let present = [hashed, hashed <> ".br", hashed <> ".gz"]

  let assert Ok(found) = resolve(hashed, "gzip, deflate, br", present)

  found.path
  |> should.equal(directory <> "/" <> hashed <> ".br")
  found.content_encoding
  |> should.equal(option.Some("br"))
}

pub fn asset_falls_back_to_gzip_test() {
  let present = [hashed, hashed <> ".br", hashed <> ".gz"]

  // The brotli sibling is there, but this client never offered to read it.
  let assert Ok(found) = resolve(hashed, "gzip, deflate", present)

  found.content_encoding
  |> should.equal(option.Some("gzip"))
}

pub fn asset_skips_a_missing_sibling_test() {
  let present = [hashed, hashed <> ".gz"]

  let assert Ok(found) = resolve(hashed, "gzip, deflate, br", present)

  found.content_encoding
  |> should.equal(option.Some("gzip"))
}

pub fn asset_ignores_a_refused_encoding_test() {
  let present = [hashed, hashed <> ".br", hashed <> ".gz"]

  // `q=0` is a refusal, not an offer.
  let assert Ok(found) = resolve(hashed, "br;q=0, gzip", present)

  found.content_encoding
  |> should.equal(option.Some("gzip"))
}

pub fn asset_ignores_a_partial_token_match_test() {
  let present = [hashed, hashed <> ".br"]

  // `brotli` is not `br`, so the sibling must not be taken.
  let assert Ok(found) = resolve(hashed, "brotli", present)

  found.content_encoding
  |> should.equal(option.None)
}

// =============================================================================
// TYPING
// =============================================================================

pub fn asset_types_from_the_requested_name_test() {
  let present = [hashed, hashed <> ".br"]

  // The file sent is the `.br`, but the type still describes the CSS inside.
  let assert Ok(found) = resolve(hashed, "br", present)

  found.content_type
  |> should.equal("text/css; charset=utf-8")
}

pub fn asset_types_an_unknown_extension_as_binary_test() {
  let name = "thing.a1b2c3d4.bin"

  let assert Ok(found) = resolve(name, "", [name])

  found.content_type
  |> should.equal("application/octet-stream")
}

// =============================================================================
// CACHING
// =============================================================================

pub fn asset_makes_a_hashed_name_immutable_test() {
  let assert Ok(found) = resolve(hashed, "", [hashed])

  found.cache_control
  |> should.equal("public, max-age=31536000, immutable")
  found.etag
  |> should.equal(option.Some("\"a1b2c3d4\""))
}

pub fn asset_makes_an_unhashed_name_uncacheable_test() {
  let name = "lily-ui.css"

  // What the dev watcher writes. It is rewritten in place, so the browser must
  // not hold on to it, and there is nothing stable to tag.
  let assert Ok(found) = resolve(name, "", [name])

  found.cache_control
  |> should.equal("no-store")
  found.etag
  |> should.equal(option.None)
}

pub fn asset_rejects_a_short_hash_test() {
  let name = "lily-ui.a1b2c3.css"

  let assert Ok(found) = resolve(name, "", [name])

  found.cache_control
  |> should.equal("no-store")
}

pub fn asset_rejects_a_non_hex_hash_test() {
  let name = "lily-ui.a1b2c3g4.css"

  let assert Ok(found) = resolve(name, "", [name])

  found.cache_control
  |> should.equal("no-store")
}

pub fn asset_varies_the_etag_by_encoding_test() {
  let present = [hashed, hashed <> ".gz"]

  let assert Ok(plain) = resolve(hashed, "", present)
  let assert Ok(gzipped) = resolve(hashed, "gzip", present)

  // A shared cache holding the gzip body must not hand it to a client reading
  // identity, so the tag cannot be the content hash alone.
  { plain.etag == gzipped.etag }
  |> should.be_false
}

// =============================================================================
// REFUSAL
// =============================================================================

pub fn asset_refuses_a_parent_reference_test() {
  resolve("../gleam.toml", "", [])
  |> should.equal(Error(Nil))
}

pub fn asset_refuses_a_nested_path_test() {
  // Assets are a flat directory of generated names, so a separator did not
  // come from a build.
  resolve("nested/thing.css", "", [])
  |> should.equal(Error(Nil))
}

pub fn asset_refuses_a_backslash_test() {
  resolve("nested\\thing.css", "", [])
  |> should.equal(Error(Nil))
}

pub fn asset_refuses_an_empty_name_test() {
  resolve("", "", [])
  |> should.equal(Error(Nil))
}

pub fn asset_refuses_an_absent_file_test() {
  resolve("nothing-here.css", "", [])
  |> should.equal(Error(Nil))
}
