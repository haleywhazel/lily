// Erlang topic admission runs in the topic process so a client can cancel
// in between, JS admits synchronously, the rest is in shared/topic_test.gleam

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleam/list

@target(erlang)
import gleeunit/should

@target(erlang)
import lily/server
@target(erlang)
import lily/test_support
@target(erlang)
import lily/wire_support

// =============================================================================
// CANCELLED BEFORE ADMISSION
// =============================================================================

@target(erlang)
pub fn topic_cancelled_subscription_is_never_announced_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")

  events(app)
  |> list.any(fn(event) {
    case event {
      server.Subscribed(..) | server.Unsubscribed(..) -> True
      _ -> False
    }
  })
  |> should.be_false
}
