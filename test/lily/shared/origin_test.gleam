// server Origins policy, pure so both targets must give identical verdicts

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/option
import gleam/result
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

/// Connect with a no-op send, only the return value is under test.
fn try_connect(
  app: server.Server(Model, Message),
  client_id: String,
  origin: option.Option(String),
) -> Result(Nil, server.ConnectError) {
  server.connect_as(
    app,
    client_id: client_id,
    origin: origin,
    send: fn(_bytes) { Nil },
    session: [],
    watch: server.Unwatched,
  )
  |> result.replace(Nil)
}

// =============================================================================
// ALLOWED ORIGINS
// =============================================================================

pub fn origin_allowed_origins_exact_match_connects_test() {
  try_connect(allowlisted(), "c1", option.Some("https://example.com"))
  |> should.equal(Ok(Nil))
}

pub fn origin_allowed_origins_second_entry_connects_test() {
  try_connect(allowlisted(), "c1", option.Some("http://localhost:1234"))
  |> should.equal(Ok(Nil))
}

pub fn origin_allowed_origins_scheme_mismatch_is_refused_test() {
  try_connect(allowlisted(), "c1", option.Some("http://example.com"))
  |> should.equal(Error(server.OriginNotAllowed(origin: "http://example.com")))
}

pub fn origin_allowed_origins_host_mismatch_is_refused_test() {
  try_connect(allowlisted(), "c1", option.Some("https://evil.com"))
  |> should.equal(Error(server.OriginNotAllowed(origin: "https://evil.com")))
}

pub fn origin_allowed_origins_port_mismatch_is_refused_test() {
  try_connect(allowlisted(), "c1", option.Some("http://localhost:4321"))
  |> should.equal(
    Error(server.OriginNotAllowed(origin: "http://localhost:4321")),
  )
}

pub fn origin_allowed_origins_missing_header_is_refused_test() {
  try_connect(allowlisted(), "c1", option.None)
  |> should.equal(Error(server.OriginMissing))
}

// =============================================================================
// ANY ORIGIN
// =============================================================================

pub fn origin_any_origin_accepts_a_named_origin_test() {
  try_connect(test_support.new_server(), "c1", option.Some("https://evil.com"))
  |> should.equal(Ok(Nil))
}

pub fn origin_any_origin_accepts_a_missing_header_test() {
  try_connect(test_support.new_server(), "c1", option.None)
  |> should.equal(Ok(Nil))
}

pub fn origin_any_origin_accepts_the_null_origin_test() {
  try_connect(test_support.new_server(), "c1", option.Some("null"))
  |> should.equal(Ok(Nil))
}

// =============================================================================
// NULL ORIGIN
// =============================================================================
// sandboxed or opaque documents send literal `null`, allowed only if listed

pub fn origin_null_origin_is_refused_by_a_normal_allowlist_test() {
  try_connect(allowlisted(), "c1", option.Some("null"))
  |> should.equal(Error(server.OriginNotAllowed(origin: "null")))
}

pub fn origin_null_origin_is_accepted_when_listed_verbatim_test() {
  let app =
    test_support.new_server_with_origins(server.AllowedOrigins(["null"]))
  try_connect(app, "c1", option.Some("null"))
  |> should.equal(Ok(Nil))
}

// =============================================================================
// NORMALISATION
// =============================================================================
// scheme and host case-insensitive, one trailing slash dropped
// browsers and proxies differ on both

pub fn origin_uppercase_and_trailing_slash_origin_matches_test() {
  try_connect(allowlisted(), "c1", option.Some("HTTPS://Example.com/"))
  |> should.equal(Ok(Nil))
}

pub fn origin_trailing_slash_on_the_allowlist_entry_matches_test() {
  let app =
    test_support.new_server_with_origins(
      server.AllowedOrigins(["https://Example.com/"]),
    )
  try_connect(app, "c1", option.Some("https://example.com"))
  |> should.equal(Ok(Nil))
}

// =============================================================================
// CHECK ORIGIN AGREES WITH CONNECT
// =============================================================================
// transports refuse the upgrade before a client id exists, meaning
// `check_origin` must match `connect`

pub fn origin_check_origin_matches_connect_for_an_allowed_origin_test() {
  let app = allowlisted()
  let origin = option.Some("https://example.com")

  server.check_origin(app, origin: origin)
  |> should.equal(try_connect(app, "c1", origin))
}

pub fn origin_check_origin_matches_connect_for_a_refused_origin_test() {
  let app = allowlisted()
  let origin = option.Some("https://evil.com")

  server.check_origin(app, origin: origin)
  |> should.equal(try_connect(app, "c1", origin))
}

pub fn origin_check_origin_matches_connect_for_a_missing_origin_test() {
  let app = allowlisted()
  server.check_origin(app, origin: option.None)
  |> should.equal(try_connect(app, "c1", option.None))
}

pub fn origin_check_origin_matches_connect_under_any_origin_test() {
  let app = test_support.new_server()
  server.check_origin(app, origin: option.None)
  |> should.equal(try_connect(app, "c1", option.None))
}

// =============================================================================
// A REFUSED CONNECTION REGISTERS NOTHING
// =============================================================================

pub fn origin_refused_connect_sends_no_frame_test() {
  let app = allowlisted()
  let sent = test_support.new([])

  server.connect(app, origin: option.Some("https://evil.com"), send: fn(bytes) {
    test_support.set(sent, [bytes, ..test_support.get(sent)])
  })
  |> should.be_error
  // no Connected frame, origin checked before the actor is touched
  test_support.get(sent)
  |> should.equal([])
}

pub fn origin_refused_client_is_not_registered_test() {
  let app = allowlisted()
  let sent = test_support.new([])
  let assert Error(_) =
    server.connect_as(
      app,
      client_id: "ghost",
      origin: option.None,
      send: fn(bytes) {
        test_support.set(sent, [bytes, ..test_support.get(sent)])
      },
      session: [],
      watch: server.Unwatched,
    )
  // both routes are no-ops for an unregistered client
  server.incoming(server.connection(app, "ghost"), bytes: <<>>)
  server.dispatch_to(app, client_id: "ghost", message: test_support.Increment)

  test_support.client_count(app)
  |> should.equal(0)
  test_support.get(sent)
  |> should.equal([])
}
