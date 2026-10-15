// observer sends into its own server apply after the reduction commits

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list
import gleeunit/should
import lily/server
import lily/test_support.{Increment}
import lily/transport
import lily/wire_support

// =============================================================================
// OBSERVERS THAT SEND BACK
// =============================================================================

pub fn reentrancy_client_connected_dispatch_to_delivers_session_update_test() {
  let app =
    server.observe(test_support.session_builder(), fn(event, app) {
      case event {
        server.ClientConnected(client_id:) ->
          server.dispatch_to(app, client_id:, message: Increment)
        _ -> Nil
      }
    })
    |> test_support.start_server

  let #(_connection, frames) = wire_support.open_recording(app, "c1", [])

  frames()
  |> list.contains(transport.SessionUpdate(sequence: 1, payload: Increment))
  |> should.be_true
}

pub fn reentrancy_session_applied_dispatch_to_keeps_both_updates_test() {
  let app =
    server.observe(test_support.session_builder(), fn(event, app) {
      case event {
        server.SessionMessageApplied(client_id:, ..) ->
          server.dispatch_to(app, client_id:, message: Increment)
        _ -> Nil
      }
    })
    |> test_support.start_server
  let #(connection, frames) = wire_support.open(app, "c1")

  wire_support.session_message(connection, Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
    transport.SessionUpdate(sequence: 2, payload: Increment),
  ])
}

pub fn reentrancy_subscribed_dispatch_topic_reaches_the_new_subscriber_test() {
  let app =
    server.observe(test_support.topic_builder(), fn(event, app) {
      case event {
        server.Subscribed(topic_id:, ..) ->
          server.dispatch_topic(app, topic_id:, message: Increment)
        _ -> Nil
      }
    })
    |> test_support.start_server
  let #(connection, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(connection, "chat")

  frames()
  |> list.contains(transport.TopicUpdate(
    topic_id: "chat",
    sequence: 1,
    payload: Increment,
  ))
  |> should.be_true
}
