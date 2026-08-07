// Pins the no-op contract of the watch surface on JavaScript, so an
// Erlang-only field never becomes reachable here.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/list
@target(javascript)
import gleam/result
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/internal/actor_cell
@target(javascript)
import lily/server
@target(javascript)
import lily/test_support.{Increment}
@target(javascript)
import lily/topic
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn ser() {
  test_support.custom_serialiser()
}

@target(javascript)
fn decode(bytes: BitArray) -> transport.Protocol(_, _) {
  let assert Ok(protocol) = transport.decode(bytes, serialiser: ser())
  protocol
}

// =============================================================================
// WATCH IS INERT
// =============================================================================

@target(javascript)
pub fn watch_returns_nil_test() {
  let srv = test_support.new_server()
  let _drain = test_support.connect_client(srv, "c1")
  // Inert on JavaScript, so bind the Nil rather than leave a bare statement.
  let _ =
    server.watch(srv, client_id: "c1")
    |> should.equal(Nil)
}

@target(javascript)
pub fn watch_changes_nothing_test() {
  let srv = test_support.new_server()
  let _drain = test_support.connect_client(srv, "c1")
  server.client_count(srv)
  |> should.equal(1)
  // Inert on JavaScript, so bind the Nil rather than leave a bare statement.
  let _ = server.watch(srv, client_id: "c1")
  server.client_count(srv)
  |> should.equal(1)
}

@target(javascript)
pub fn topics_still_round_trip_after_watch_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  let drain = test_support.connect_client(srv, "c1")
  // Inert on JavaScript, so bind the Nil rather than leave a bare statement.
  let _ = server.watch(srv, client_id: "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: transport.encode(
      transport.Subscribe(topic_id: "chat"),
      serialiser: ser(),
    ),
  )
  let _ = drain()
  topic.subscriber_count(chat)
  |> should.equal(1)

  topic.dispatch(chat, Increment)
  drain()
  |> list.map(decode)
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

@target(javascript)
pub fn disconnect_stays_idempotent_test() {
  let srv = test_support.new_server()
  let _drain = test_support.connect_client(srv, "c1")
  // Inert on JavaScript, so bind the Nil rather than leave a bare statement.
  let _ = server.watch(srv, client_id: "c1")
  server.disconnect(srv, client_id: "c1")
  server.disconnect(srv, client_id: "c1")
  server.client_count(srv)
  |> should.equal(0)
}

@target(javascript)
pub fn resync_resubscribes_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  let drain = test_support.connect_client(srv, "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: transport.encode(
      transport.Resync(cursors: [transport.Topic("chat")]),
      serialiser: ser(),
    ),
  )
  let _ = drain()
  topic.subscriber_count(chat)
  |> should.equal(1)
}

// =============================================================================
// SUPERVISION IS INERT
// =============================================================================

@target(javascript)
pub fn the_supervisor_is_inert_test() {
  let srv = test_support.new_server()
  actor_cell.no_supervisor()
  |> should.equal(server.supervisor(srv))
}

@target(javascript)
pub fn topics_start_without_a_supervisor_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  let drain = test_support.connect_client(srv, "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: transport.encode(
      transport.Subscribe(topic_id: "chat"),
      serialiser: ser(),
    ),
  )
  let _ = drain()
  topic.subscriber_count(chat)
  |> should.equal(1)
}

@target(javascript)
pub fn chained_configuration_still_applies_test() {
  // config recording must not change what a chained topic actually does
  let srv = test_support.new_server()
  let assert Ok(chat) =
    topic.new(srv, id: "chat")
    |> result.map(topic.with_store)
    |> result.map(topic.can_subscribe(_, fn(_, _, _) { False }))
  let drain = test_support.connect_client(srv, "c1")
  server.incoming(
    srv,
    client_id: "c1",
    bytes: transport.encode(
      transport.Subscribe(topic_id: "chat"),
      serialiser: ser(),
    ),
  )
  drain()
  |> list.map(decode)
  |> should.equal([transport.Rejected(topic_id: "chat", reason: "denied")])
  topic.subscriber_count(chat)
  |> should.equal(0)
}
