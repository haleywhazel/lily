// one client's crashing callback must not take down the shared actor

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic/decode

import gleeunit/should

import lily/server
import lily/store
import lily/test_support.{type Message, type Model, Increment, SetName}
import lily/transport
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

/// Topic-store server whose observer panics where `crash_on` holds.
fn server_with_crashing_observer(
  crash_on: fn(server.ServerEvent(Model, Message)) -> Bool,
) -> server.Server(Model, Message) {
  server.observe(test_support.topic_builder(), fn(event, _server) {
    case crash_on(event) {
      True -> panic as "observer blew up"
      False -> Nil
    }
  })
  |> test_support.start_server
}

// =============================================================================
// OBSERVERS
// =============================================================================

pub fn crashing_observer_on_connect_keeps_the_server_alive_test() {
  let app =
    server_with_crashing_observer(fn(event) {
      case event {
        server.ClientConnected(..) -> True
        _ -> False
      }
    })

  let _ = wire_support.open(app, "a")

  // registered anyway, and still accepting connections
  test_support.client_count(app)
  |> should.equal(1)
  let _ = wire_support.open(app, "b")
  test_support.client_count(app)
  |> should.equal(2)
}

pub fn crashing_observer_on_disconnect_keeps_the_server_alive_test() {
  let app =
    server_with_crashing_observer(fn(event) {
      case event {
        server.ClientDisconnected(..) -> True
        _ -> False
      }
    })
  let #(connection, _frames) = wire_support.open(app, "a")

  server.disconnect(connection)

  // cleanup either side of the observer still committed
  test_support.client_count(app)
  |> should.equal(0)
}

pub fn crashing_observer_on_message_still_acknowledges_test() {
  let app =
    server.observe(test_support.session_builder(), fn(_event, _server) {
      panic as "observer blew up"
    })
    |> test_support.start_server
  let #(connection, frames) = wire_support.open(app, "a")

  wire_support.session_message(connection, Increment)

  // ack before observers, meaning a client never waits on an applied message
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn crashing_decoder_drops_the_frame_test() {
  let app = test_support.new_server()
  let #(connection, frames) = wire_support.open(app, "a")

  server.incoming(connection, bytes: <<"not a frame at all":utf8>>)

  // dropped, not fatal
  frames()
  |> should.equal([])
  test_support.client_count(app)
  |> should.equal(1)
}

pub fn crashing_decoder_in_the_user_serialiser_drops_the_frame_test() {
  // decoder runs on client bytes, a crash counts as a failed decode
  let decoder =
    decode.then(decode.at(["tag"], decode.string), fn(tag) {
      case tag {
        "Reset" -> panic as "decoder blew up"
        _ -> test_support.message_decoder()
      }
    })
  let serialiser =
    test_support.json_envelope(
      encode_message: test_support.encode_message,
      message_decoder: decoder,
      encode_model: test_support.encode_model,
      model_decoder: test_support.model_decoder(),
    )
  let app =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.sync_with(route: fn(_) { store.Session }, serialiser:)
    |> server.new(origins: server.AnyOrigin)
    |> test_support.start_server
  let #(connection, frames) = wire_support.open(app, "a")

  wire_support.session_message(connection, test_support.Reset)

  frames()
  |> should.equal([])
  test_support.client_count(app)
  |> should.equal(1)
}

// =============================================================================
// EVICTION
// =============================================================================

pub fn crashing_send_drops_only_that_client_test() {
  let app = test_support.new_server()
  let _broken = wire_support.open_broken(app, "broken")
  let _ = wire_support.open(app, "healthy")

  server.dispatch_to_all(app, message: Increment)

  // only the broken one goes
  test_support.client_count(app)
  |> should.equal(1)
}

// =============================================================================
// TOPIC OBSERVERS
// =============================================================================

pub fn crashing_observer_on_subscribed_still_admits_test() {
  let app =
    server_with_crashing_observer(fn(event) {
      case event {
        server.Subscribed(..) -> True
        _ -> False
      }
    })
  let #(connection, _frames) = wire_support.open(app, "a")

  wire_support.subscribe(connection, "chat")
  wire_support.settle(app)

  // membership committed before observers, letting the join stand
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn crashing_observer_on_unsubscribed_still_removes_test() {
  let app =
    server_with_crashing_observer(fn(event) {
      case event {
        server.Unsubscribed(..) -> True
        _ -> False
      }
    })
  let #(connection, _frames) = wire_support.open(app, "a")
  wire_support.subscribe(connection, "chat")
  wire_support.settle(app)

  wire_support.unsubscribe(connection, "chat")
  wire_support.settle(app)

  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

pub fn crashing_allow_predicate_denies_and_leaves_the_topic_unstarted_test() {
  let app =
    test_support.new_topic_server_with_access(
      store.Allow(fn(_client_id, _topic_id, _session) {
        panic as "predicate blew up"
      }),
    )
  let #(connection, frames) = wire_support.open(app, "a")

  wire_support.subscribe(connection, "chat")

  // fails closed and reports it, nobody else affected
  frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  test_support.subscriber_count(app, "chat")
  |> should.equal(-1)
  test_support.client_count(app)
  |> should.equal(1)
}

// =============================================================================
// TOPIC FAN-OUT
// =============================================================================

pub fn crashing_subscriber_send_is_pruned_test() {
  let app = test_support.new_topic_server()
  let broken = wire_support.open_broken(app, "broken")
  let #(healthy, _frames) = wire_support.open(app, "healthy")
  wire_support.subscribe(broken, "chat")
  wire_support.subscribe(healthy, "chat")
  wire_support.settle(app)

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)

  // dead socket dropped, everyone else kept
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn crashing_subscriber_send_leaves_the_room_serving_test() {
  let app = test_support.new_topic_server()
  let broken = wire_support.open_broken(app, "broken")
  wire_support.subscribe(broken, "chat")
  wire_support.settle(app)
  let #(healthy, frames) = wire_support.open(app, "healthy")

  wire_support.subscribe(healthy, "chat")

  // dead socket pruned on its failed snapshot, the next joiner still served
  case frames() {
    [transport.Snapshot(target: transport.Topic("chat"), ..)] -> Nil
    _ -> should.fail()
  }
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn crashing_topic_update_drops_the_message_test() {
  let crashing =
    store.new(init: test_support.initial_model(), update: fn(model, message) {
      case message {
        SetName(_) -> panic as "update blew up"
        _ -> test_support.update(model, message)
      }
    })
    |> store.sync_with(
      route: test_support.topic_route,
      serialiser: test_support.custom_serialiser(),
    )
    |> store.topics(
      prefix: "room:",
      get: fn(model, _) { model },
      set: fn(_, _, model) { model },
      access: store.Open,
    )
  let app =
    test_support.start_server(server.new(crashing, origins: server.AnyOrigin))
  let #(connection, frames) = wire_support.open(app, "a")
  wire_support.subscribe(connection, "room:1")
  let _ = frames()

  wire_support.topic_message(connection, "room:1", SetName("room:1"))

  // the sender hears of it, topic and subscriber both survive
  frames()
  |> should.equal([transport.Dropped(target: transport.Topic("room:1"))])
  test_support.subscriber_count(app, "room:1")
  |> should.equal(1)
}

pub fn crashing_encode_on_a_topic_update_drops_only_that_frame_test() {
  // an unencodable message drops nobody, the next one still goes out
  let serialiser =
    test_support.json_envelope(
      encode_message: fn(message) {
        case message {
          test_support.Decrement -> panic as "cannot encode"
          _ -> test_support.encode_message(message)
        }
      },
      message_decoder: test_support.message_decoder(),
      encode_model: test_support.encode_model,
      model_decoder: test_support.model_decoder(),
    )
  let crashing =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.sync_with(route: test_support.topic_route, serialiser:)
    |> store.topic(
      id: "chat",
      get: fn(model) { model },
      set: fn(_, model) { model },
      access: store.Open,
    )
  let app =
    test_support.start_server(server.new(crashing, origins: server.AnyOrigin))
  let #(connection, frames) = wire_support.open(app, "a")
  wire_support.subscribe(connection, "chat")
  let _ = frames()

  server.dispatch_topic(app, topic_id: "chat", message: test_support.Decrement)
  server.dispatch_topic(app, topic_id: "chat", message: Increment)

  // sequence 1 spent on the unencodable frame
  frames()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 2, payload: Increment),
  ])
  test_support.client_count(app)
  |> should.equal(1)
}

// =============================================================================
// SESSION
// =============================================================================

pub fn crashing_session_update_drops_the_message_test() {
  let crashing =
    store.new(init: test_support.initial_model(), update: fn(_model, _message) {
      panic as "update blew up"
    })
    |> store.sync_with(
      route: fn(_) { store.Session },
      serialiser: test_support.custom_serialiser(),
    )
  let app =
    test_support.start_server(server.new(crashing, origins: server.AnyOrigin))
  let #(connection, frames) = wire_support.open(app, "a")

  wire_support.session_message(connection, Increment)

  frames()
  |> should.equal([transport.Dropped(target: transport.Session)])
  test_support.client_count(app)
  |> should.equal(1)
}
