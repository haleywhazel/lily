// server wire-format negotiation, replies follow the first decodable frame
// own format until then, via wire_support so both targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list

import gleeunit/should

import lily/server
import lily/store
import lily/test_support.{type Message, type Model, Increment, Noop}
import lily/transport.{Json, MessagePack}
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

// `store.sync` store, making it `ByHost`
fn by_host_server() -> server.Server(Model, Message) {
  test_support.register_fixtures()
  test_support.start_server(server.new(
    test_support.automatic_topic_store(),
    origins: server.AnyOrigin,
  ))
}

// format the auto serialiser reads `bytes` as
fn format_of(bytes: BitArray) -> transport.Format {
  let assert Ok(format) =
    transport.frame_format(
      bytes,
      serialiser: test_support.automatic_serialiser(Json),
    )
  format
}

// own format forced to JSON
fn json_server() -> server.Server(Model, Message) {
  test_support.register_fixtures()
  test_support.start_server(server.new(
    test_support.automatic_session_store(Json),
    origins: server.AnyOrigin,
  ))
}

// greeting dropped, returns the raw frames reader
fn open_quiet(
  app: server.Server(Model, Message),
  client_id: String,
) -> #(server.Connection(Model, Message), fn() -> List(BitArray)) {
  let #(connection, frames) = wire_support.open_raw(app, client_id, [])
  let _ = frames()
  #(connection, frames)
}

// subscribed to `chat` in `format`, greeting and snapshot dropped
fn subscribed_in(
  app: server.Server(Model, Message),
  client_id: String,
  format: transport.Format,
) -> #(server.Connection(Model, Message), fn() -> List(BitArray)) {
  let #(connection, frames) = open_quiet(app, client_id)
  wire_support.send_in(
    connection,
    transport.Subscribe(topic_id: "chat"),
    format,
  )
  let _ = frames()
  #(connection, frames)
}

// =============================================================================
// GREETING
// =============================================================================

pub fn negotiation_greeting_goes_out_in_the_server_format_test() {
  let app = by_host_server()

  let #(_connection, frames) = wire_support.open_raw(app, "c1", [])
  let sent = frames()

  list.map(sent, format_of)
  |> should.equal([MessagePack, MessagePack])
  list.map(sent, wire_support.decode_automatic)
  |> list.drop(1)
  |> should.equal([transport.Connected(client_id: "c1")])
}

pub fn negotiation_seeded_session_update_goes_out_in_the_server_format_test() {
  let app = by_host_server()

  let #(_connection, frames) = wire_support.open_raw(app, "c1", [Noop])
  let sent = frames()

  list.map(sent, format_of)
  |> should.equal([MessagePack, MessagePack, MessagePack])
  list.last(sent)
  |> should.be_ok
  |> wire_support.decode_automatic
  |> should.equal(transport.SessionUpdate(sequence: 1, payload: Noop))
}

pub fn negotiation_greeting_follows_a_forced_server_format_test() {
  let app = json_server()

  let #(_connection, frames) = wire_support.open_raw(app, "c1", [])

  list.map(frames(), format_of)
  |> should.equal([Json, Json])
}

// =============================================================================
// REPLIES
// =============================================================================

pub fn negotiation_json_client_gets_json_replies_test() {
  let app = by_host_server()
  let #(connection, frames) = open_quiet(app, "c1")

  wire_support.send_in(
    connection,
    transport.Resync(cursors: [transport.Unknown(transport.Session)]),
    Json,
  )
  let sent = frames()

  list.map(sent, format_of)
  |> should.equal([Json])
  list.map(sent, wire_support.decode_automatic)
  |> list.all(wire_support.is_snapshot)
  |> should.be_true
}

pub fn negotiation_message_pack_client_gets_message_pack_replies_test() {
  let app = json_server()
  let #(connection, frames) = open_quiet(app, "c1")

  wire_support.send_in(
    connection,
    transport.Resync(cursors: [transport.Unknown(transport.Session)]),
    MessagePack,
  )

  list.map(frames(), format_of)
  |> should.equal([MessagePack])
}

pub fn negotiation_acknowledge_goes_out_in_the_client_format_test() {
  let app = by_host_server()
  let #(connection, frames) = open_quiet(app, "c1")

  wire_support.send_in(connection, transport.SessionMessage(Noop), Json)
  let sent = frames()

  list.map(sent, format_of)
  |> should.equal([Json])
  list.map(sent, wire_support.decode_automatic)
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn negotiation_rejected_goes_out_in_the_client_format_test() {
  let app = by_host_server()
  let #(connection, frames) = open_quiet(app, "c1")

  wire_support.send_in(connection, transport.Subscribe("nowhere"), Json)
  let sent = frames()

  list.map(sent, format_of)
  |> should.equal([Json])
  list.map(sent, wire_support.decode_automatic)
  |> should.equal([
    transport.Rejected(topic_id: "nowhere", reason: transport.NotFound),
  ])
}

pub fn negotiation_remembers_the_first_frame_format_test() {
  let app = by_host_server()
  let #(connection, frames) = open_quiet(app, "c1")

  wire_support.send_in(connection, transport.SessionMessage(Noop), Json)
  wire_support.send_in(connection, transport.SessionMessage(Noop), MessagePack)

  list.map(frames(), format_of)
  |> should.equal([Json, Json])
}

pub fn negotiation_ignores_a_frame_that_fails_to_decode_test() {
  let app = by_host_server()
  let #(connection, frames) = open_quiet(app, "c1")

  server.incoming(connection, bytes: <<"{not json":utf8>>)
  wire_support.send_in(connection, transport.SessionMessage(Noop), Json)

  list.map(frames(), format_of)
  |> should.equal([Json])
}

// =============================================================================
// TOPICS
// =============================================================================

pub fn negotiation_topic_snapshot_goes_out_in_each_client_format_test() {
  let app = by_host_server()
  let #(json_client, json_frames) = open_quiet(app, "a")
  let #(pack_client, pack_frames) = open_quiet(app, "b")

  wire_support.send_in(json_client, transport.Subscribe("chat"), Json)
  wire_support.send_in(pack_client, transport.Subscribe("chat"), MessagePack)

  list.map(json_frames(), format_of)
  |> should.equal([Json])
  list.map(pack_frames(), format_of)
  |> should.equal([MessagePack])
}

pub fn negotiation_topic_update_reaches_each_subscriber_in_its_format_test() {
  let app = by_host_server()
  let #(_json_client, json_frames) = subscribed_in(app, "a", Json)
  let #(_pack_client, pack_frames) = subscribed_in(app, "b", MessagePack)

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  let json_sent = json_frames()
  let pack_sent = pack_frames()

  list.map(json_sent, format_of)
  |> should.equal([Json])
  list.map(pack_sent, format_of)
  |> should.equal([MessagePack])
  let update =
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment)
  list.map(json_sent, wire_support.decode_automatic)
  |> should.equal([update])
  list.map(pack_sent, wire_support.decode_automatic)
  |> should.equal([update])
}

pub fn negotiation_topic_originator_is_acknowledged_in_its_format_test() {
  let app = by_host_server()
  let #(json_client, json_frames) = subscribed_in(app, "a", Json)
  let #(_pack_client, pack_frames) = subscribed_in(app, "b", MessagePack)

  wire_support.send_in(
    json_client,
    transport.TopicMessage(topic_id: "chat", payload: Increment),
    Json,
  )
  let json_sent = json_frames()
  let pack_sent = pack_frames()

  list.map(json_sent, format_of)
  |> should.equal([Json])
  list.map(json_sent, wire_support.decode_automatic)
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
  ])
  list.map(pack_sent, format_of)
  |> should.equal([MessagePack])
}

pub fn negotiation_topic_resync_snapshot_goes_out_in_the_client_format_test() {
  let app = by_host_server()
  let #(json_client, json_frames) = subscribed_in(app, "a", Json)

  wire_support.send_in(
    json_client,
    transport.Resync(cursors: [transport.Unknown(transport.Topic("chat"))]),
    Json,
  )
  let sent = json_frames()

  list.map(sent, format_of)
  |> should.equal([Json])
  list.map(sent, wire_support.decode_automatic)
  |> list.all(wire_support.is_snapshot)
  |> should.be_true
}

pub fn negotiation_topic_stop_reaches_each_subscriber_in_its_format_test() {
  let app = by_host_server()
  let #(_json_client, json_frames) = subscribed_in(app, "a", Json)
  let #(_pack_client, pack_frames) = subscribed_in(app, "b", MessagePack)

  wire_support.stop_topic(app, "chat")

  // the final `Acknowledge` and the `Rejected` after it
  list.map(json_frames(), format_of)
  |> should.equal([Json, Json])
  list.map(pack_frames(), format_of)
  |> should.equal([MessagePack, MessagePack])
}

pub fn negotiation_topic_encodes_an_update_once_not_per_subscriber_test() {
  let #(record, recorded) = wire_support.recorder()
  let custom = test_support.custom_serialiser()
  let counting =
    transport.serialiser(
      encode: fn(frame) {
        record(frame)
        transport.encode(frame, serialiser: custom)
      },
      decode: fn(bytes) { transport.decode(bytes, serialiser: custom) },
    )
  let app_store =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.sync_with(route: test_support.topic_route, serialiser: counting)
    |> store.topic(
      id: "chat",
      get: fn(model) { model },
      set: fn(_, model) { model },
      access: store.Open,
    )
  let app =
    test_support.start_server(server.new(app_store, origins: server.AnyOrigin))
  list.each(["a", "b", "c"], fn(client_id) {
    let #(connection, _frames) = wire_support.open(app, client_id)
    wire_support.subscribe(connection, "chat")
  })
  wire_support.settle(app)
  let _ = recorded()

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)

  recorded()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}
