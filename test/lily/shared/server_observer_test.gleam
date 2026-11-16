// server observers, via wire_support so both targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list
import gleam/option
import gleam/string

import gleeunit/should

import lily/server.{type ServerEvent}
import lily/store
import lily/test_support.{type Message, type Model, Increment}
import lily/transport
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

/// Events are read back with the returned function.
fn observed_server() -> #(
  server.Server(Model, Message),
  fn() -> List(ServerEvent(Model, Message)),
) {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  #(app, fn() { events(app) })
}

/// Only topic is `private`, guarded by `access`.
fn guarded_server(
  access: store.Access(Model),
) -> #(server.Server(Model, Message), fn() -> List(ServerEvent(Model, Message))) {
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.topic_store_with([#("private", access)]),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  #(app, fn() { events(app) })
}

/// Frames are discarded.
fn connect_quiet(
  app: server.Server(Model, Message),
  client_id: String,
) -> server.Connection(Model, Message) {
  let #(connection, _frames) = wire_support.open(app, client_id)
  connection
}

// =============================================================================
// OBSERVERS
// =============================================================================

pub fn observers_add_up_test() {
  let #(first_builder, first) =
    wire_support.observed(test_support.topic_builder())
  let #(builder, second) = wire_support.observed(first_builder)
  let app = test_support.start_server(builder)

  connect_quiet(app, "c1")

  first(app) |> should.equal([server.ClientConnected("c1")])
  second(app) |> should.equal([server.ClientConnected("c1")])
}

pub fn observers_run_in_the_order_they_were_added_test() {
  let #(record, order) = wire_support.recorder()
  let builder =
    test_support.topic_builder()
    |> server.observe(fn(_event, _server) { record(1) })
    |> server.observe(fn(_event, _server) { record(2) })
  let app = test_support.start_server(builder)

  connect_quiet(app, "c1")
  wire_support.settle(app)

  order() |> should.equal([1, 2])
}

pub fn observers_a_crashing_one_does_not_stop_the_others_test() {
  let #(builder, events) =
    wire_support.observed(
      server.observe(test_support.topic_builder(), fn(_event, _server) {
        panic as "observer"
      }),
    )
  let app = test_support.start_server(builder)

  connect_quiet(app, "c1")

  events(app) |> should.equal([server.ClientConnected("c1")])
  // server carries on
  test_support.client_count(app) |> should.equal(1)
}

// =============================================================================
// EVENTS
// =============================================================================

pub fn observers_see_connect_and_disconnect_test() {
  let #(app, events) = observed_server()

  let connection = connect_quiet(app, "c1")
  server.disconnect(connection)

  events()
  |> should.equal([
    server.ClientConnected("c1"),
    server.ClientDisconnected("c1"),
  ])
}

pub fn observers_see_a_session_message_with_the_client_and_its_model_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.session_message(connection, test_support.IncrementSecondary)

  events()
  |> should.equal([
    server.SessionMessageApplied(
      client_id: "c1",
      message: test_support.IncrementSecondary,
      model: test_support.Model(
        ..test_support.initial_model(),
        secondary_count: 1,
      ),
    ),
  ])
}

pub fn observers_see_a_topic_message_with_the_model_after_it_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  wire_support.subscribe(connection, "chat")
  let _ = events()

  wire_support.topic_message(connection, "chat", Increment)

  events()
  |> should.equal([
    server.TopicMessageApplied(
      client_id: option.Some("c1"),
      topic_id: "chat",
      message: Increment,
      model: test_support.Model(..test_support.initial_model(), count: 1),
    ),
  ])
}

pub fn observers_see_a_topic_message_applied_before_its_acknowledgement_test() {
  let sent = test_support.new_shared([])
  let #(record, recorded) = wire_support.recorder()
  let builder =
    test_support.topic_builder()
    |> server.observe(fn(event, _app) {
      case event {
        server.TopicMessageApplied(..) ->
          record(list.contains(
            test_support.get_shared(sent),
            transport.Acknowledge(
              target: transport.Topic("chat"),
              sequence: 1,
              id: 0,
            ),
          ))
        _ -> Nil
      }
    })
  let app = test_support.start_server(builder)
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: fn(bytes) {
        test_support.set_shared(sent, [
          wire_support.decode(bytes),
          ..test_support.get_shared(sent)
        ])
      },
      client_id: "c1",
      seed: [],
      watch: server.Unwatched,
    )
  wire_support.subscribe(connection, "chat")

  wire_support.topic_message(connection, "chat", Increment)

  wire_support.settle(app)
  recorded()
  |> should.equal([False])
  test_support.get_shared(sent)
  |> list.contains(transport.Acknowledge(
    target: transport.Topic("chat"),
    sequence: 1,
    id: 0,
  ))
  |> should.be_true
}

pub fn observers_see_a_topic_dispatch_applied_with_no_client_test() {
  let #(app, events) = observed_server()
  let _ = events()

  server.dispatch_to_topic(app, topic_id: "chat", message: Increment)

  events()
  |> should.equal([
    server.TopicMessageApplied(
      client_id: option.None,
      topic_id: "chat",
      message: Increment,
      model: test_support.Model(..test_support.initial_model(), count: 1),
    ),
  ])
}

pub fn observers_see_no_topic_message_applied_when_update_crashes_test() {
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.crashing_topic_store(),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  let connection = connect_quiet(app, "c1")
  wire_support.subscribe(connection, "chat")
  let _ = events(app)

  wire_support.topic_message(connection, "chat", test_support.Decrement)

  events(app)
  |> list.any(fn(event) {
    case event {
      server.TopicMessageApplied(..) -> True
      _ -> False
    }
  })
  |> should.be_false
}

pub fn observers_crashing_on_a_topic_message_still_let_the_acknowledgement_out_test() {
  let app =
    test_support.topic_builder()
    |> server.observe(fn(event, _app) {
      case event {
        server.TopicMessageApplied(..) -> panic as "observer blew up"
        _ -> Nil
      }
    })
    |> test_support.start_server
  let #(connection, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(connection, "chat")
  let _ = frames()

  wire_support.topic_message(connection, "chat", Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1, id: 0),
  ])
}

pub fn observers_see_subscribed_and_unsubscribed_for_a_joined_topic_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.subscribe(connection, "chat")
  wire_support.settle(app)
  wire_support.unsubscribe(connection, "chat")

  events()
  |> should.equal([
    server.Subscribed("c1", "chat"),
    server.Unsubscribed("c1", "chat"),
  ])
}

pub fn observers_see_disconnect_unsubscribe_then_disconnect_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  wire_support.subscribe(connection, "chat")
  let _ = events()

  server.disconnect(connection)

  events()
  |> should.equal([
    server.Unsubscribed("c1", "chat"),
    server.ClientDisconnected("c1"),
  ])
}

// =============================================================================
// REJECTIONS
// =============================================================================

pub fn observers_see_no_rejection_for_an_admitted_subscription_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.subscribe(connection, "chat")

  events() |> should.equal([server.Subscribed("c1", "chat")])
}

pub fn observers_see_an_unknown_topic_rejected_as_not_found_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.subscribe(connection, "nowhere")

  events()
  |> should.equal([
    server.SubscriptionRejected(
      client_id: "c1",
      topic_id: "nowhere",
      reason: transport.NotFound,
    ),
  ])
}

pub fn observers_see_a_refused_subscription_rejected_as_denied_test() {
  let #(app, events) =
    guarded_server(store.Allow(fn(_client, _topic, _session) { False }))
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.subscribe(connection, "private")
  // never joined, meaning no leave event
  wire_support.unsubscribe(connection, "private")

  events()
  |> should.equal([
    server.SubscriptionRejected(
      client_id: "c1",
      topic_id: "private",
      reason: transport.AccessDenied,
    ),
  ])
}

pub fn observers_see_a_crashing_access_rule_rejected_as_denied_test() {
  let #(app, events) =
    guarded_server(
      store.Allow(fn(_client, _topic, _session) { panic as "rule blew up" }),
    )
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.subscribe(connection, "private")

  let assert [server.Diagnostic(level: transport.Failure, message:), rejected] =
    events()
  string.starts_with(
    message,
    "access to \"private\" crashed for \"c1\", refused: ",
  )
  |> should.be_true
  rejected
  |> should.equal(server.SubscriptionRejected(
    client_id: "c1",
    topic_id: "private",
    reason: transport.AccessDenied,
  ))
}

pub fn observers_see_a_resync_refused_on_the_access_recheck_test() {
  let #(app, events) =
    guarded_server(
      store.Allow(fn(client_id, _topic, _session) { client_id == "c1" }),
    )
  let connection = connect_quiet(app, "c2")
  let _ = events()

  wire_support.resync_topic(connection, "private")

  events()
  |> should.equal([
    server.SubscriptionRejected(
      client_id: "c2",
      topic_id: "private",
      reason: transport.AccessDenied,
    ),
  ])
}

// =============================================================================
// DIAGNOSTICS
// =============================================================================

pub fn observers_see_an_undecodable_frame_as_a_diagnostic_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  let _ = events()

  server.receive(connection, bytes: <<"nonsense":utf8>>)

  events()
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a frame from \"c1\" that failed to decode",
    ),
  ])
}

pub fn observers_see_a_misrouted_session_message_as_a_diagnostic_test() {
  let #(app, events) = observed_server()
  let connection = connect_quiet(app, "c1")
  let _ = events()

  wire_support.session_message(connection, Increment)

  case events() {
    [server.Diagnostic(level: transport.Warning, ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn observers_see_a_crashing_session_update_as_a_diagnostic_test() {
  let crashing =
    store.new(init: test_support.initial_model(), update: fn(_model, _message) {
      panic as "update blew up"
    })
    |> store.sync_with(
      route: fn(_) { store.Session },
      serialiser: test_support.custom_serialiser(),
    )
  let #(builder, events) =
    wire_support.observed(server.new(crashing, origins: server.AnyOrigin))
  let app = test_support.start_server(builder)
  let connection = connect_quiet(app, "c1")
  let _ = events(app)

  wire_support.session_message(connection, Increment)

  events(app)
  |> list.any(fn(event) {
    case event {
      server.Diagnostic(..) -> True
      _ -> False
    }
  })
  |> should.be_true
  test_support.client_count(app) |> should.equal(1)
}
