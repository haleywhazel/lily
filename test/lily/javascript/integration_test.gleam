// End-to-end integration test on JavaScript, where the server and topic
// actor cells run synchronously. Proves the full serialise -> server ->
// topic -> client loop: a client encodes a frame, the server ingests it,
// a topic broadcast fans out, and the client decodes the outgoing bytes.

@target(javascript)
import gleam/list
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/server
@target(javascript)
import lily/test_support.{type Message, type Model, Increment}
@target(javascript)
import lily/topic
@target(javascript)
import lily/transport.{type Protocol}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn ser() {
  test_support.custom_serialiser()
}

@target(javascript)
fn decode(bytes: BitArray) -> Protocol(Model, Message) {
  let assert Ok(protocol) = transport.decode(bytes, serialiser: ser())
  protocol
}

// =============================================================================
// FULL LOOP
// =============================================================================

@target(javascript)
pub fn integration_session_message_roundtrips_through_server_test() {
  let srv = test_support.new_server()
  let drain = test_support.connect_client(srv, "c1")

  let client_bytes =
    transport.encode(
      transport.SessionMessage(payload: Increment),
      serialiser: ser(),
    )
  server.incoming(srv, client_id: "c1", bytes: client_bytes)

  case drain() {
    [ack] ->
      decode(ack)
      |> should.equal(transport.Acknowledge(
        target: transport.Session,
        sequence: 1,
      ))
    _ -> should.fail()
  }
}

@target(javascript)
pub fn integration_topic_broadcast_reaches_client_test() {
  let srv = test_support.new_server()
  let assert Ok(t) = topic.new(srv, id: "test")
  let drain = test_support.connect_client(srv, "c1")

  let subscribe_bytes =
    transport.encode(transport.Subscribe(topic_id: "test"), serialiser: ser())
  server.incoming(srv, client_id: "c1", bytes: subscribe_bytes)
  let _ = drain()

  topic.broadcast(t, Increment)

  case drain() {
    frames ->
      list.any(frames, fn(bytes) {
        decode(bytes) == transport.Push(topic_id: "test", payload: Increment)
      })
      |> should.be_true
  }
}
