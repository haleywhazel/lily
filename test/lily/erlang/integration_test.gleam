// End-to-end integration test on Erlang, where the server and topic actor
// cells run as OTP actors. Proves the full serialise -> server -> topic ->
// client loop. Mirrors test/lily/javascript/integration_test.gleam, with
// process.Subject mailboxes and sleeps for the asynchronous actor path.

@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/server
@target(erlang)
import lily/test_support.{type Message, type Model, Increment}
@target(erlang)
import lily/topic
@target(erlang)
import lily/transport.{type Protocol}

// =============================================================================
// HELPERS
// =============================================================================

@target(erlang)
fn ser() {
  test_support.custom_serialiser()
}

@target(erlang)
fn recv(subj: process.Subject(BitArray)) -> Result(BitArray, Nil) {
  process.receive(subj, within: 200)
}

@target(erlang)
fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> process.Subject(BitArray) {
  let subj = process.new_subject()
  server.connect(srv, client_id: client_id, send: process.send(subj, _))
  let _ = recv(subj)
  subj
}

@target(erlang)
fn decode(bytes: BitArray) -> Protocol(Model, Message) {
  let assert Ok(protocol) = transport.decode(bytes, serialiser: ser())
  protocol
}

// =============================================================================
// FULL LOOP
// =============================================================================

@target(erlang)
pub fn integration_session_message_roundtrips_through_server_test() {
  let srv = test_support.new_server()
  let subj = connect_client(srv, "c1")

  let client_bytes =
    transport.encode(
      transport.SessionMessage(payload: Increment),
      serialiser: ser(),
    )
  server.incoming(srv, client_id: "c1", bytes: client_bytes)

  case recv(subj) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Acknowledge(
        target: transport.Session,
        sequence: 1,
      ))
    Error(_) -> should.fail()
  }
}

@target(erlang)
pub fn integration_topic_broadcast_reaches_client_test() {
  let srv = test_support.new_server()
  let assert Ok(t) = topic.new(srv, id: "test")
  let subj = connect_client(srv, "c1")

  let subscribe_bytes =
    transport.encode(transport.Subscribe(topic_id: "test"), serialiser: ser())
  server.incoming(srv, client_id: "c1", bytes: subscribe_bytes)
  process.sleep(20)

  topic.broadcast(t, Increment)

  case recv(subj) {
    Ok(bytes) ->
      decode(bytes)
      |> should.equal(transport.Push(topic_id: "test", payload: Increment))
    Error(_) -> should.fail()
  }
}
