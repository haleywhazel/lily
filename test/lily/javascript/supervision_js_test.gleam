// watch and supervision stay inert on JS, Erlang-only behaviour stays out

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/option
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/server
@target(javascript)
import lily/test_support
@target(javascript)
import lily/wire_support

// =============================================================================
// WATCHING IS INERT
// =============================================================================

@target(javascript)
pub fn supervision_connect_watching_the_caller_changes_nothing_test() {
  let app = test_support.new_server()

  let assert Ok(_) =
    server.connect(app, origin: option.None, send: fn(_) { Nil })

  test_support.client_count(app)
  |> should.equal(1)
}

@target(javascript)
pub fn supervision_connect_as_watch_caller_changes_nothing_test() {
  let app = test_support.new_server()

  let assert Ok(_) =
    server.connect_as(
      app,
      origin: option.None,
      send: fn(_) { Nil },
      client_id: "c1",
      session: [],
      watch: server.WatchCaller,
    )

  test_support.client_count(app)
  |> should.equal(1)
}

@target(javascript)
pub fn supervision_topics_still_round_trip_for_a_watched_client_test() {
  let app = test_support.new_topic_server()
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: fn(_) { Nil },
      client_id: "c1",
      session: [],
      watch: server.WatchCaller,
    )

  wire_support.subscribe(connection, "chat")

  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

// =============================================================================
// SUPERVISION IS INERT
// =============================================================================

@target(javascript)
pub fn supervision_the_supervisor_is_inert_test() {
  // every server shares the same empty supervisor
  test_support.inspect(test_support.new_server()).supervisor
  |> should.equal(
    test_support.inspect(test_support.new_topic_server()).supervisor,
  )
}
