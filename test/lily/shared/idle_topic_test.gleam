// server.stop_idle_topics, a topic nobody uses stops after its ttl, both
// targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleeunit/should

import lily/server
import lily/test_support.{type Message, type Model, Increment}
import lily/transport
import lily/wire_support.{type Later}

// =============================================================================
// HELPERS
// =============================================================================

const ttl = 40

fn idle_server(milliseconds: Int) -> server.Server(Model, Message) {
  test_support.start_server(
    test_support.topic_builder()
    |> server.stop_idle_topics(after: milliseconds),
  )
}

fn is_running(app: server.Server(Model, Message)) -> Bool {
  test_support.subscriber_count(app, "chat") >= 0
}

// =============================================================================
// STOPPING
// =============================================================================

pub fn idle_topic_stops_after_the_last_subscriber_leaves_test() -> Later {
  let app = idle_server(ttl)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")
  wire_support.settle(app)

  is_running(app)
  |> should.be_true
  use <- wire_support.after(ttl * 5)
  is_running(app)
  |> should.be_false
}

pub fn idle_topic_stops_after_its_last_subscriber_disconnects_test() -> Later {
  let app = idle_server(ttl)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  server.disconnect(c1)

  use <- wire_support.after(ttl * 5)
  is_running(app)
  |> should.be_false
}

pub fn idle_topic_with_a_subscriber_keeps_running_test() -> Later {
  let app = idle_server(ttl)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")

  use <- wire_support.after(ttl * 5)
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn idle_topic_started_by_a_dispatch_stops_test() -> Later {
  let app = idle_server(ttl)

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)

  is_running(app)
  |> should.be_true
  use <- wire_support.after(ttl * 5)
  is_running(app)
  |> should.be_false
}

pub fn idle_topic_resubscribed_before_the_ttl_ignores_the_stale_timer_test() -> Later {
  // the first timer fires between the two waits, the topic outlives it
  let ttl = 200
  let app = idle_server(ttl)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")

  use <- wire_support.after_then(ttl / 2)
  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")
  use <- wire_support.after_then(ttl * 7 / 10)
  is_running(app)
  |> should.be_true
  use <- wire_support.after(ttl)
  is_running(app)
  |> should.be_false
}

pub fn idle_topic_is_not_stopped_without_the_option_test() -> Later {
  let app = test_support.new_topic_server()
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")

  use <- wire_support.after(ttl * 3)
  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

pub fn idle_topic_reloads_through_topic_init_on_the_next_subscribe_test() -> Later {
  let loads = test_support.new_shared(0)
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.stop_idle_topics(after: ttl)
      |> server.topic_init(id: "chat", init: fn() {
        let count = test_support.get_shared(loads) + 1
        test_support.set_shared(loads, count)
        test_support.Model(..test_support.initial_model(), count: count * 10)
      }),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")
  let _ = frames()

  use <- wire_support.after(ttl * 5)
  wire_support.subscribe(c1, "chat")
  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.Model(..test_support.initial_model(), count: 20),
    ),
  ])
  test_support.get_shared(loads)
  |> should.equal(2)
}
