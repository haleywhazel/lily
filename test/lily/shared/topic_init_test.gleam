// server.topic_init and topics_init, a topic loading its starting model,
// both targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list

import gleeunit/should

import lily/server
import lily/test_support.{type Message, type Model}
import lily/transport
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

/// One client's frames from `topic_id` once the topic settles.
fn subscribe_and_drain(
  builder: server.Builder(Model, Message),
  topic_id: String,
) -> List(transport.Protocol(Model, Message)) {
  let app = test_support.start_server(builder)
  let #(connection, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(connection, topic_id)
  frames()
}

fn named(name: String) -> Model {
  test_support.Model(..test_support.initial_model(), name:)
}

fn snapshot(
  topic_id: String,
  model: Model,
) -> transport.Protocol(Model, Message) {
  transport.Snapshot(
    target: transport.Topic(topic_id),
    epoch: 0,
    sequence: 0,
    state: model,
  )
}

// =============================================================================
// LOADING
// =============================================================================

pub fn topic_init_a_topic_starts_from_its_loaded_model_test() {
  test_support.topic_builder()
  |> server.topics_init(prefix: "room:", init: named)
  |> subscribe_and_drain("room:7")
  |> should.equal([snapshot("room:7", named("7"))])
}

pub fn topic_init_a_combining_mark_after_the_prefix_reaches_the_loader_test() {
  // by graphemes both ids would hand the loader 'x'
  let builder =
    test_support.topic_builder()
    |> server.topics_init(prefix: "room:", init: named)

  subscribe_and_drain(builder, "room:\u{0301}x")
  |> should.equal([snapshot("room:\u{0301}x", named("\u{0301}x"))])
  subscribe_and_drain(builder, "room:x")
  |> should.equal([snapshot("room:x", named("x"))])
}

pub fn topic_init_a_topic_without_a_loader_starts_from_the_initial_model_test() {
  test_support.topic_builder()
  |> server.topics_init(prefix: "room:", init: named)
  |> subscribe_and_drain("chat")
  |> should.equal([snapshot("chat", test_support.initial_model())])
}

pub fn topic_init_the_longest_loader_prefix_wins_test() {
  let builder =
    test_support.topic_builder()
    |> server.topics_init(prefix: "room:vip:", init: fn(_) { named("vip") })
    |> server.topics_init(prefix: "room:", init: fn(_) { named("plain") })

  subscribe_and_drain(builder, "room:vip:1")
  |> should.equal([snapshot("room:vip:1", named("vip"))])
  subscribe_and_drain(builder, "room:1")
  |> should.equal([snapshot("room:1", named("plain"))])
}

pub fn topic_init_a_redeclared_loader_prefix_replaces_the_earlier_one_test() {
  test_support.topic_builder()
  |> server.topics_init(prefix: "room:", init: fn(_) { named("first") })
  |> server.topics_init(prefix: "room:", init: fn(_) { named("second") })
  |> subscribe_and_drain("room:1")
  |> should.equal([snapshot("room:1", named("second"))])
}

pub fn topic_init_an_exact_id_loads_its_topic_test() {
  test_support.topic_builder()
  |> server.topic_init(id: "chat", init: fn() { named("chat") })
  |> subscribe_and_drain("chat")
  |> should.equal([snapshot("chat", named("chat"))])
}

pub fn topic_init_an_exact_id_does_not_load_a_longer_id_test() {
  test_support.topic_builder()
  |> server.topic_init(id: "room:", init: fn() { named("exact") })
  |> subscribe_and_drain("room:1")
  |> should.equal([snapshot("room:1", test_support.initial_model())])
}

pub fn topic_init_an_exact_id_beats_a_matching_prefix_test() {
  let builder =
    test_support.topic_builder()
    |> server.topic_init(id: "room:1", init: fn() { named("exact") })
    |> server.topics_init(prefix: "room:", init: fn(_) { named("family") })

  subscribe_and_drain(builder, "room:1")
  |> should.equal([snapshot("room:1", named("exact"))])
  subscribe_and_drain(builder, "room:2")
  |> should.equal([snapshot("room:2", named("family"))])
}

// =============================================================================
// A CRASHING LOADER
// =============================================================================

pub fn topic_init_a_crashing_loader_falls_back_to_the_initial_model_test() {
  let #(builder, events) =
    test_support.topic_builder()
    |> server.topics_init(prefix: "room:", init: fn(_) { panic as "no database" })
    |> wire_support.observed
  let app = test_support.start_server(builder)
  let #(connection, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(connection, "room:1")

  frames()
  |> should.equal([snapshot("room:1", test_support.initial_model())])
  events(app)
  |> list.filter(fn(event) {
    case event {
      server.Diagnostic(level: transport.Failure, ..) -> True
      _ -> False
    }
  })
  |> list.length
  |> should.equal(1)
}
