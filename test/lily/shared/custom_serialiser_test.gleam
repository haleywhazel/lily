// JSON envelope on the open transport.serialiser, both targets
// server half goes through a real server

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/list

import gleeunit/should

import lily/server
import lily/test_support.{type Message, type Model, Increment, SetName}
import lily/transport.{type Protocol}
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

fn round_trip(frame: Protocol(Model, Message)) -> Nil {
  transport.encode(frame, serialiser: test_support.custom_serialiser())
  |> transport.decode(serialiser: test_support.custom_serialiser())
  |> should.equal(Ok(frame))
}

fn open_server() -> server.Server(Model, Message) {
  test_support.start_server(server.new(
    test_support.open_session_store(),
    origins: server.AnyOrigin,
  ))
}

// =============================================================================
// ROUND TRIP
// =============================================================================

pub fn open_serialiser_round_trips_every_frame_test() {
  let model = test_support.Model(..test_support.initial_model(), count: 3)
  [
    transport.Acknowledge(target: transport.Session, sequence: 1),
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 2),
    transport.Connected(client_id: "abc"),
    transport.Dropped(target: transport.Session),
    transport.Dropped(target: transport.Topic("chat")),
    transport.Rejected(topic_id: "t", reason: transport.AccessDenied),
    transport.Resync(cursors: [transport.Session, transport.Topic("a")]),
    transport.Resync(cursors: []),
    transport.SessionMessage(payload: Increment),
    transport.SessionUpdate(sequence: 4, payload: SetName("x")),
    transport.Snapshot(target: transport.Session, sequence: 5, state: model),
    transport.Snapshot(
      target: transport.Topic("room:1"),
      sequence: 0,
      state: model,
    ),
    transport.Subscribe(topic_id: "chat"),
    transport.TopicMessage(topic_id: "chat", payload: Increment),
    transport.TopicUpdate(topic_id: "chat", sequence: 6, payload: SetName("y")),
    transport.Unsubscribe(topic_id: "chat"),
    transport.Version(hash: "v1", protocol: 1),
  ]
  |> list.each(round_trip)
}

pub fn open_serialiser_writes_json_text_test() {
  transport.encode(
    transport.Connected(client_id: "abc"),
    serialiser: test_support.custom_serialiser(),
  )
  |> should.equal(bit_array.from_string(
    "{\"type\":\"connected\",\"client_id\":\"abc\"}",
  ))
}

pub fn open_serialiser_rejects_unknown_type_test() {
  bit_array.from_string("{\"type\":\"nope\"}")
  |> transport.decode(serialiser: test_support.custom_serialiser())
  |> should.be_error
}

pub fn open_serialiser_rejects_garbage_test() {
  bit_array.from_string("not json")
  |> transport.decode(serialiser: test_support.custom_serialiser())
  |> should.be_error
}

pub fn open_serialiser_rejects_non_utf8_test() {
  transport.decode(<<0xff, 0xfe>>, serialiser: test_support.custom_serialiser())
  |> should.be_error
}

// =============================================================================
// THROUGH A SERVER
// =============================================================================

pub fn open_serialiser_server_acknowledges_a_session_message_test() {
  let app = open_server()
  let #(connection, frames) = wire_support.open(app, "c1")

  server.incoming(
    connection,
    bytes: transport.encode(
      transport.SessionMessage(payload: Increment),
      serialiser: test_support.custom_serialiser(),
    ),
  )

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn open_serialiser_server_answers_a_resync_with_a_snapshot_test() {
  let app = open_server()
  let #(connection, frames) = wire_support.open(app, "c1")
  server.incoming(
    connection,
    bytes: transport.encode(
      transport.SessionMessage(payload: Increment),
      serialiser: test_support.custom_serialiser(),
    ),
  )
  let _ = frames()

  server.incoming(
    connection,
    bytes: transport.encode(
      transport.Resync(cursors: [transport.Session]),
      serialiser: test_support.custom_serialiser(),
    ),
  )

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Session,
      sequence: 1,
      state: test_support.Model(..test_support.initial_model(), count: 1),
    ),
  ])
}

pub fn open_serialiser_server_drops_a_frame_it_cannot_decode_test() {
  let app = open_server()
  let #(connection, frames) = wire_support.open(app, "c1")

  server.incoming(connection, bytes: bit_array.from_string("{\"type\":\"x\"}"))

  frames()
  |> should.equal([])
}

pub fn open_serialiser_server_greets_a_connection_test() {
  let app = open_server()

  let #(_connection, frames) = wire_support.open_recording(app, "c9", [])

  frames()
  |> list.contains(transport.Connected(client_id: "c9"))
  |> should.be_true
}
