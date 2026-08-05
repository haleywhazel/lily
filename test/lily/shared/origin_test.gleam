// Tests for the server's Origins policy: which browser origins may open a
// connection. Origin matching is pure, so these run on both targets and
// must give identical verdicts on each.

import gleam/option
import gleeunit/should
import lily/server
import lily/test_support.{type Message, type Model}

// =============================================================================
// HELPERS
// =============================================================================

fn allowlisted() -> server.Server(Model, Message) {
  test_support.new_server_with_origins(
    server.AllowedOrigins(["https://example.com", "http://localhost:1234"]),
  )
}

/// Attempt a connection with a throwaway send that records nothing, so the
/// return value is the only thing under test.
fn try_connect(
  srv: server.Server(Model, Message),
  client_id: String,
  origin: option.Option(String),
) -> Result(Nil, server.ConnectError) {
  server.connect(
    srv,
    client_id: client_id,
    origin: origin,
    send: fn(_bytes) { Nil },
    session: [],
  )
}

// =============================================================================
// ALLOWED ORIGINS
// =============================================================================

pub fn allowed_origins_exact_match_connects_test() {
  try_connect(allowlisted(), "c1", option.Some("https://example.com"))
  |> should.equal(Ok(Nil))
}

pub fn allowed_origins_second_entry_connects_test() {
  try_connect(allowlisted(), "c1", option.Some("http://localhost:1234"))
  |> should.equal(Ok(Nil))
}

pub fn allowed_origins_scheme_mismatch_is_refused_test() {
  try_connect(allowlisted(), "c1", option.Some("http://example.com"))
  |> should.equal(Error(server.OriginNotAllowed(origin: "http://example.com")))
}

pub fn allowed_origins_host_mismatch_is_refused_test() {
  try_connect(allowlisted(), "c1", option.Some("https://evil.com"))
  |> should.equal(Error(server.OriginNotAllowed(origin: "https://evil.com")))
}

pub fn allowed_origins_port_mismatch_is_refused_test() {
  try_connect(allowlisted(), "c1", option.Some("http://localhost:4321"))
  |> should.equal(
    Error(server.OriginNotAllowed(origin: "http://localhost:4321")),
  )
}

pub fn allowed_origins_missing_header_is_refused_test() {
  try_connect(allowlisted(), "c1", option.None)
  |> should.equal(Error(server.OriginMissing))
}

// =============================================================================
// ANY ORIGIN
// =============================================================================

pub fn any_origin_accepts_a_named_origin_test() {
  try_connect(test_support.new_server(), "c1", option.Some("https://evil.com"))
  |> should.equal(Ok(Nil))
}

pub fn any_origin_accepts_a_missing_header_test() {
  try_connect(test_support.new_server(), "c1", option.None)
  |> should.equal(Ok(Nil))
}

pub fn any_origin_accepts_the_null_origin_test() {
  try_connect(test_support.new_server(), "c1", option.Some("null"))
  |> should.equal(Ok(Nil))
}

// =============================================================================
// THE LITERAL "null" ORIGIN
// =============================================================================
// A sandboxed or opaque document sends the literal string "null". It is not a
// real origin, so an allowlist only ever accepts it when it names it verbatim.

pub fn null_origin_is_refused_by_a_normal_allowlist_test() {
  try_connect(allowlisted(), "c1", option.Some("null"))
  |> should.equal(Error(server.OriginNotAllowed(origin: "null")))
}

pub fn null_origin_is_accepted_when_listed_verbatim_test() {
  let srv =
    test_support.new_server_with_origins(server.AllowedOrigins(["null"]))
  try_connect(srv, "c1", option.Some("null"))
  |> should.equal(Ok(Nil))
}

// =============================================================================
// NORMALISATION
// =============================================================================
// Scheme and host are case-insensitive, and one trailing slash is dropped,
// because browsers and proxies differ on both.

pub fn uppercase_and_trailing_slash_origin_matches_test() {
  try_connect(allowlisted(), "c1", option.Some("HTTPS://Example.com/"))
  |> should.equal(Ok(Nil))
}

pub fn trailing_slash_on_the_allowlist_entry_matches_test() {
  let srv =
    test_support.new_server_with_origins(
      server.AllowedOrigins(["https://Example.com/"]),
    )
  try_connect(srv, "c1", option.Some("https://example.com"))
  |> should.equal(Ok(Nil))
}

// =============================================================================
// CHECK_ORIGIN AGREES WITH CONNECT
// =============================================================================
// A transport can refuse the upgrade before it has a client id, so
// `check_origin` must give exactly the verdict `connect` would.

pub fn check_origin_matches_connect_for_an_allowed_origin_test() {
  let srv = allowlisted()
  let origin = option.Some("https://example.com")
  server.check_origin(srv, origin: origin)
  |> should.equal(try_connect(srv, "c1", origin))
}

pub fn check_origin_matches_connect_for_a_refused_origin_test() {
  let srv = allowlisted()
  let origin = option.Some("https://evil.com")
  server.check_origin(srv, origin: origin)
  |> should.equal(try_connect(srv, "c1", origin))
}

pub fn check_origin_matches_connect_for_a_missing_origin_test() {
  let srv = allowlisted()
  server.check_origin(srv, origin: option.None)
  |> should.equal(try_connect(srv, "c1", option.None))
}

pub fn check_origin_matches_connect_under_any_origin_test() {
  let srv = test_support.new_server()
  server.check_origin(srv, origin: option.None)
  |> should.equal(try_connect(srv, "c1", option.None))
}

// =============================================================================
// A REFUSED CONNECTION REGISTERS NOTHING
// =============================================================================

pub fn refused_connect_sends_no_frame_test() {
  let srv = allowlisted()
  let sent = test_support.new([])
  server.connect(
    srv,
    client_id: "ghost",
    origin: option.Some("https://evil.com"),
    send: fn(bytes) {
      test_support.set(sent, [bytes, ..test_support.get(sent)])
    },
    session: [],
  )
  |> should.be_error
  // No Connected frame, the origin is validated before the actor is touched.
  test_support.get(sent)
  |> should.equal([])
}

pub fn refused_client_is_not_registered_test() {
  let srv = allowlisted()
  let sent = test_support.new([])
  let assert Error(_) =
    server.connect(
      srv,
      client_id: "ghost",
      origin: option.None,
      send: fn(bytes) {
        test_support.set(sent, [bytes, ..test_support.get(sent)])
      },
      session: [],
    )
  // Both routes into a connection are no-ops for an unregistered client.
  server.incoming(srv, client_id: "ghost", bytes: <<>>)
  server.dispatch_to(srv, client_id: "ghost", message: test_support.Increment)
  test_support.get(sent)
  |> should.equal([])
}
