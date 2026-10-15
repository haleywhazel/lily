// lily/server via wire_support on both targets
// process watching and supervision live in the target folders

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import lily/server
import lily/test_support.{Increment, SetName}
import lily/transport
import lily/wire_support

// =============================================================================
// STARTUP
// =============================================================================

pub fn server_start_returns_ok_test() {
  server.start(server.new(
    test_support.session_store(),
    origins: server.AnyOrigin,
  ))
  |> should.be_ok
}

pub fn server_boot_id_is_stable_for_one_server_and_differs_between_servers_test() {
  let one = test_support.new_server()
  let two = test_support.new_server()

  test_support.boot_id(one)
  |> should.equal(test_support.boot_id(one))
  test_support.boot_id(one)
  |> should.not_equal(test_support.boot_id(two))
}

// =============================================================================
// CLIENT MANAGEMENT
// =============================================================================

pub fn server_connect_single_client_test() {
  let app = test_support.new_server()

  let _ = wire_support.open(app, "c1")

  test_support.client_count(app)
  |> should.equal(1)
}

pub fn server_connect_multiple_clients_test() {
  let app = test_support.new_server()

  let _ = wire_support.open(app, "c1")
  let _ = wire_support.open(app, "c2")
  let _ = wire_support.open(app, "c3")

  test_support.client_count(app)
  |> should.equal(3)
}

pub fn server_connect_sends_version_then_connected_test() {
  // incarnation first, letting the client know which server it reached
  let app = test_support.new_server()

  let #(_connection, frames) = wire_support.open_recording(app, "c1", [])

  case frames() {
    [transport.Version(hash:), connected] -> {
      { hash != "" } |> should.be_true
      connected |> should.equal(transport.Connected(client_id: "c1"))
    }
    _ -> should.fail()
  }
}

pub fn server_connect_mints_a_fresh_32_char_client_id_test() {
  let app = test_support.new_server()

  let assert Ok(first) =
    server.connect(app, origin: option.None, send: fn(_) { Nil })
  let assert Ok(second) =
    server.connect(app, origin: option.None, send: fn(_) { Nil })

  server.client_id(first)
  |> string.length
  |> should.equal(32)
  server.client_id(first)
  |> should.not_equal(server.client_id(second))
  test_support.client_count(app)
  |> should.equal(2)
}

pub fn server_connect_announces_its_own_id_in_the_connected_frame_test() {
  let app = test_support.new_server()
  let #(record, recorded) = wire_support.recorder()

  let assert Ok(connection) =
    server.connect(app, origin: option.None, send: record)
  wire_support.settle(app)

  case list.map(recorded(), wire_support.decode) {
    [_version, connected] ->
      connected
      |> should.equal(
        transport.Connected(client_id: server.client_id(connection)),
      )
    _ -> should.fail()
  }
}

pub fn server_disconnect_removes_the_client_test() {
  let app = test_support.new_server()
  let _ = wire_support.open(app, "c1")

  server.disconnect(server.connection(app, "c1"))

  test_support.client_count(app)
  |> should.equal(0)
}

pub fn server_disconnect_nonexistent_test() {
  let app = test_support.new_server()

  server.disconnect(server.connection(app, "ghost"))

  test_support.client_count(app)
  |> should.equal(0)
}

pub fn server_disconnect_prevents_acknowledgement_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  server.disconnect(c1)
  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([])
}

pub fn server_disconnect_twice_is_reported_once_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(connection, _frames) = wire_support.open(app, "c1")

  server.disconnect(connection)
  server.disconnect(connection)

  events(app)
  |> list.filter(fn(event) {
    case event {
      server.ClientDisconnected(..) -> True
      _ -> False
    }
  })
  |> list.length
  |> should.equal(1)
  test_support.client_count(app)
  |> should.equal(0)
}

// =============================================================================
// CONNECTION HANDLE
// =============================================================================

pub fn server_connection_reports_the_client_id_it_was_made_for_test() {
  let app = test_support.new_server()

  server.connection(app, "c1")
  |> server.client_id
  |> should.equal("c1")
}

pub fn server_connect_as_returns_a_connection_with_the_chosen_id_test() {
  let app = test_support.new_server()

  let #(connection, _frames) = wire_support.open(app, "chosen")

  server.client_id(connection)
  |> should.equal("chosen")
}

pub fn server_a_connection_handle_made_from_an_id_reaches_the_same_client_test() {
  let app = test_support.new_server()
  let #(opened, frames) = wire_support.open(app, "c1")

  let rebuilt = server.connection(app, server.client_id(opened))
  wire_support.session_message(rebuilt, Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

// =============================================================================
// SESSION MESSAGE PROCESSING
// =============================================================================

pub fn server_session_message_acknowledges_sender_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn server_session_message_does_not_broadcast_test() {
  // session messages are per-connection
  let app = test_support.new_server()
  let #(c1, _frames1) = wire_support.open(app, "c1")
  let #(_c2, frames2) = wire_support.open(app, "c2")

  wire_support.session_message(c1, Increment)

  frames2()
  |> should.equal([])
}

pub fn server_session_sequence_increments_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, Increment)
  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
    transport.Acknowledge(target: transport.Session, sequence: 2),
  ])
}

pub fn server_session_sequence_is_per_connection_test() {
  // per-client sequence counter from 0
  let app = test_support.new_server()
  let #(c1, frames1) = wire_support.open(app, "c1")
  let #(c2, frames2) = wire_support.open(app, "c2")

  wire_support.session_message(c1, Increment)
  wire_support.session_message(c2, Increment)

  frames1()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
  frames2()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn server_session_state_is_per_connection_test() {
  let app = test_support.new_server()
  let #(c1, _frames1) = wire_support.open(app, "c1")
  let #(c2, frames2) = wire_support.open(app, "c2")

  wire_support.session_message(c1, Increment)
  wire_support.resync_session(c2)

  frames2()
  |> should.equal([
    transport.Snapshot(
      target: transport.Session,
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

// =============================================================================
// SESSION SEEDING
// =============================================================================

pub fn server_connect_streams_the_seed_back_to_the_client_test() {
  // client needs the seeds to stay in step
  let app = test_support.new_server()

  let #(_connection, frames) =
    wire_support.open_recording(app, "c1", [SetName("Alice"), Increment])

  case frames() {
    [transport.Version(..), transport.Connected(..), ..seeds] ->
      seeds
      |> should.equal([
        transport.SessionUpdate(sequence: 1, payload: SetName("Alice")),
        transport.SessionUpdate(sequence: 2, payload: Increment),
      ])
    _ -> should.fail()
  }
}

pub fn server_connect_seeds_session_model_test() {
  // `connect(session:)` seeds apply first, meaning resync reports the seeded
  // model
  let app = test_support.new_server()
  let #(c1, frames) =
    wire_support.open_seeded(app, "c1", [SetName("Alice"), Increment])

  wire_support.resync_session(c1)

  case frames() {
    [transport.Snapshot(state:, ..)] -> {
      state.name |> should.equal("Alice")
      state.count |> should.equal(1)
    }
    _ -> should.fail()
  }
}

pub fn server_connect_with_empty_session_keeps_initial_model_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open_seeded(app, "c1", [])

  wire_support.resync_session(c1)

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Session,
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

// =============================================================================
// RESYNC
// =============================================================================

pub fn server_resync_sends_snapshot_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.resync_session(c1)

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Session,
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

pub fn server_resync_after_session_messages_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.session_message(c1, Increment)
  let _ = frames()

  wire_support.resync_session(c1)

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Session,
      sequence: 1,
      state: test_support.Model(..test_support.initial_model(), count: 1),
    ),
  ])
}

pub fn server_resync_reflects_own_session_only_test() {
  let app = test_support.new_server()
  let #(c1, _frames1) = wire_support.open(app, "c1")
  wire_support.session_message(c1, Increment)
  let #(c2, frames2) = wire_support.open(app, "c2")

  wire_support.resync_session(c2)

  frames2()
  |> should.equal([
    transport.Snapshot(
      target: transport.Session,
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

// =============================================================================
// DISPATCH-TO
// =============================================================================

pub fn server_dispatch_to_sends_session_update_test() {
  let app = test_support.new_server()
  let #(_c1, frames) = wire_support.open(app, "c1")

  server.dispatch_to(app, client_id: "c1", message: Increment)

  frames()
  |> should.equal([transport.SessionUpdate(sequence: 1, payload: Increment)])
}

pub fn server_dispatch_to_increments_session_sequence_test() {
  let app = test_support.new_server()
  let #(_c1, frames) = wire_support.open(app, "c1")

  server.dispatch_to(app, client_id: "c1", message: Increment)
  server.dispatch_to(app, client_id: "c1", message: Increment)

  frames()
  |> should.equal([
    transport.SessionUpdate(sequence: 1, payload: Increment),
    transport.SessionUpdate(sequence: 2, payload: Increment),
  ])
}

pub fn server_dispatch_to_unknown_client_is_noop_test() {
  let app = test_support.new_server()
  let #(_c1, frames) = wire_support.open(app, "c1")

  server.dispatch_to(app, client_id: "ghost", message: Increment)

  frames()
  |> should.equal([])
}

pub fn server_dispatch_to_does_not_reach_other_clients_test() {
  let app = test_support.new_server()
  let #(_c1, frames1) = wire_support.open(app, "c1")
  let #(_c2, frames2) = wire_support.open(app, "c2")

  server.dispatch_to(app, client_id: "c1", message: Increment)

  frames1() |> list.length |> should.equal(1)
  frames2() |> should.equal([])
}

pub fn server_dispatch_to_all_reaches_every_client_test() {
  let app = test_support.new_server()
  let #(_c1, frames1) = wire_support.open(app, "c1")
  let #(_c2, frames2) = wire_support.open(app, "c2")

  server.dispatch_to_all(app, message: Increment)

  frames1()
  |> should.equal([transport.SessionUpdate(sequence: 1, payload: Increment)])
  frames2()
  |> should.equal([transport.SessionUpdate(sequence: 1, payload: Increment)])
}

// =============================================================================
// ROUTE ENFORCEMENT
// =============================================================================

pub fn server_session_message_routed_elsewhere_is_dropped_test() {
  // Increment routes to a topic, meaning no client can apply it to its session
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([])
  wire_support.resync_session(c1)
  case frames() {
    [transport.Snapshot(state:, sequence: 0, ..)] ->
      state.count
      |> should.equal(0)
    _ -> should.fail()
  }
}

pub fn server_dispatch_to_ignores_the_route_test() {
  // the server is trusted with any session message
  let app = test_support.new_topic_server()
  let #(_c1, frames) = wire_support.open(app, "c1")

  server.dispatch_to(app, client_id: "c1", message: Increment)

  frames()
  |> should.equal([transport.SessionUpdate(sequence: 1, payload: Increment)])
}

// =============================================================================
// INVALID INCOMING
// =============================================================================

pub fn server_incoming_from_unknown_client_test() {
  // c1 not connected, ack goes nowhere and the server carries on
  let app = test_support.new_server()

  wire_support.session_message(server.connection(app, "c1"), Increment)

  test_support.client_count(app)
  |> should.equal(0)
}

pub fn server_incoming_invalid_json_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  server.incoming(c1, bytes: bit_array.from_string("not json at all"))

  frames()
  |> should.equal([])
}

pub fn server_incoming_unknown_protocol_type_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  server.incoming(c1, bytes: bit_array.from_string("{\"type\":\"unknown\"}"))

  frames()
  |> should.equal([])
}

// =============================================================================
// GENERATE CLIENT ID
// =============================================================================

pub fn server_generate_client_id_is_unique_test() {
  server.generate_client_id()
  |> should.not_equal(server.generate_client_id())
}

pub fn server_generate_client_id_returns_32_char_hex_test() {
  server.generate_client_id()
  |> string.length
  |> should.equal(32)
}

// =============================================================================
// STOP
// =============================================================================

pub fn server_stop_sends_each_topic_subscriber_a_final_acknowledge_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  wire_support.stop(app)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 0),
  ])
}

pub fn server_stop_silently_drops_further_calls_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.stop(app)
  wire_support.session_message(c1, Increment)
  server.disconnect(c1)

  frames()
  |> should.equal([])
}
