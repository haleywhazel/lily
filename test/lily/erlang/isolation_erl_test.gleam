// The frame half of the crash-isolation policy, capturing over a Subject so a
// denied subscribe can be checked for actually saying so. `test_support`'s Ref
// is the process dictionary, which a send closure inside the actor cannot
// reach.

@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/option
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/server
@target(erlang)
import lily/test_support.{type Message, type Model, Increment}
@target(erlang)
import lily/topic
@target(erlang)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn ser() {
  test_support.custom_serialiser()
}

@target(erlang)
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subject = process.new_subject()
  let assert Ok(Nil) =
    server.connect(
      srv,
      client_id: client_id,
      origin: option.None,
      send: process.send(subject, _),
      session: [],
    )
  // Drain the Version and Connected frames sent on registration.
  let _ = recv(subject)
  let _ = recv(subject)
  subject
}

@target(erlang)
fn incoming(
  srv: server.Server(Model, Message),
  client_id: String,
  frame: transport.Protocol(Model, Message),
) -> Nil {
  server.incoming(
    srv,
    client_id:,
    bytes: transport.encode(frame, serialiser: ser()),
  )
}

@target(erlang)
fn recv(subject: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subject, within: 200)
}

@target(erlang)
/// The next frame, decoded. Fails the test rather than returning a default, so
/// a silent absence cannot pass for the wrong reason.
fn next_frame(
  subject: process.Subject(BitArray),
) -> transport.Protocol(Model, Message) {
  let assert Ok(bytes) = recv(subject)
  let assert Ok(frame) = transport.decode(bytes, serialiser: ser())
  frame
}

// =============================================================================
// SESSION
// =============================================================================

@target(erlang)
pub fn crashing_on_message_still_acknowledges_test() {
  let srv = test_support.new_server()
  let client = connect_client(srv, "a")
  server.on_message(srv, fn(_message, _model, _client_id) {
    panic as "on_message blew up"
  })

  incoming(srv, "a", transport.SessionMessage(payload: Increment))

  // The ack goes out before the hook runs, so a client is never left waiting
  // on a message the server did in fact apply.
  next_frame(client)
  |> should.equal(transport.Acknowledge(target: transport.Session, sequence: 1))
}

// =============================================================================
// SUBSCRIBE
// =============================================================================

@target(erlang)
pub fn crashing_parametric_create_rejects_the_subscribe_test() {
  let srv = test_support.new_server()
  let assert Ok(Nil) =
    topic.kind(
      srv,
      prefix: "room:",
      parse_id: fn(id) { Ok(id) },
      configure: fn(_parsed, _topic) { panic as "configure blew up" },
    )
  let client = connect_client(srv, "a")

  // The path a client reaches by naming any id under the prefix, so the
  // user's `configure` runs on demand with a crash it chose the moment for.
  incoming(srv, "a", transport.Subscribe(topic_id: "room:anything"))

  next_frame(client)
  |> should.equal(transport.Rejected(
    topic_id: "room:anything",
    reason: "not found",
  ))
}

@target(erlang)
pub fn crashing_can_subscribe_denies_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat =
    chat
    |> topic.with_store
    |> topic.can_subscribe(fn(_client_id, _topic_id, _session) {
      panic as "can_subscribe blew up"
    })
  let client = connect_client(srv, "a")

  incoming(srv, "a", transport.Subscribe(topic_id: "chat"))

  // Fails closed, and says so, rather than crashing the topic and resetting it
  // for everybody already in the room.
  next_frame(client)
  |> should.equal(transport.Rejected(topic_id: "chat", reason: "denied"))
  topic.subscriber_count(chat)
  |> should.equal(0)
}

// =============================================================================
// FAN-OUT
// =============================================================================

@target(erlang)
pub fn crashing_subscriber_send_leaves_the_room_serving_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  let assert Ok(Nil) =
    server.connect(
      srv,
      client_id: "broken",
      origin: option.None,
      send: fn(_bytes) { panic as "send closure is gone" },
      session: [],
    )
  incoming(srv, "broken", transport.Subscribe(topic_id: "chat"))
  let _ = topic.subscriber_count(chat)

  let healthy = connect_client(srv, "healthy")
  incoming(srv, "healthy", transport.Subscribe(topic_id: "chat"))

  // The dead socket is pruned on the snapshot it could not take, and the room
  // keeps serving the next subscriber its own.
  case next_frame(healthy) {
    transport.Snapshot(target: transport.Topic("chat"), sequence: _, state: _) ->
      True
    _ -> False
  }
  |> should.be_true
  topic.subscriber_count(chat)
  |> should.equal(1)
}
