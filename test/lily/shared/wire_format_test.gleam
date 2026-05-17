// Wire-format snapshot tests for the MessagePack auto-serialiser. Encoded
// byte sequences are pinned here so any change to the codec (Erlang FFI, JS
// FFI, or a future pure-Gleam implementation) that produces non-identical
// output is caught immediately.
//
// The tests run on both targets, so any cross-target divergence also fails.

import gleam/bit_array
import gleeunit/should
import lily/test_fixtures.{type Message, type Model, Increment, SetName}
import lily/transport.{
  type Protocol, Acknowledge, Connected, Push, Rejected, Resync, Session,
  SessionMessage, Snapshot, Subscribe, Topic, TopicMessage, TopicUpdate,
  Unsubscribe,
}

// =============================================================================
// HELPERS
// =============================================================================

fn ser() {
  transport.automatic() |> transport.use_message_pack
}

fn assert_encoded(p: Protocol(Model, Message), expected_hex: String) -> Nil {
  let bytes = transport.encode(p, serialiser: ser())
  let actual_hex = bit_array.base16_encode(bytes)
  actual_hex
  |> should.equal(expected_hex)
}

fn assert_roundtrip(p: Protocol(Model, Message)) -> Nil {
  transport.encode(p, serialiser: ser())
  |> transport.decode(serialiser: ser())
  |> should.equal(Ok(p))
}

// =============================================================================
// ENCODE SNAPSHOTS
// =============================================================================

pub fn snapshot_acknowledge_session_test() {
  assert_encoded(
    Acknowledge(target: Session, sequence: 42),
    "83A474797065AB61636B6E6F776C65646765A674617267657481A46B696E64A773657373696F6EA873657175656E63652A",
  )
}

pub fn snapshot_acknowledge_topic_test() {
  assert_encoded(
    Acknowledge(target: Topic(id: "chat"), sequence: 1),
    "83A474797065AB61636B6E6F776C65646765A674617267657482A46B696E64A5746F706963A26964A463686174A873657175656E636501",
  )
}

pub fn snapshot_connected_test() {
  assert_encoded(
    Connected(client_id: "abc123"),
    "82A474797065A9636F6E6E6563746564A9636C69656E745F6964A6616263313233",
  )
}

pub fn snapshot_push_test() {
  assert_encoded(
    Push(topic_id: "typing", payload: Increment),
    "83A474797065A470757368A8746F7069635F6964A6747970696E67A77061796C6F6164C40D81A15FA9496E6372656D656E74",
  )
}

pub fn snapshot_rejected_test() {
  assert_encoded(
    Rejected(topic_id: "secret", reason: "denied"),
    "83A474797065A872656A6563746564A8746F7069635F6964A6736563726574A6726561736F6EA664656E696564",
  )
}

pub fn snapshot_resync_session_test() {
  assert_encoded(
    Resync(cursors: [Session]),
    "82A474797065A6726573796E63A7637572736F72739181A46B696E64A773657373696F6E",
  )
}

pub fn snapshot_resync_session_topic_test() {
  assert_encoded(
    Resync(cursors: [Session, Topic(id: "chat")]),
    "82A474797065A6726573796E63A7637572736F72739281A46B696E64A773657373696F6E82A46B696E64A5746F706963A26964A463686174",
  )
}

pub fn snapshot_session_message_increment_test() {
  assert_encoded(
    SessionMessage(payload: Increment),
    "82A474797065AF73657373696F6E5F6D657373616765A77061796C6F6164C40D81A15FA9496E6372656D656E74",
  )
}

pub fn snapshot_session_message_set_name_test() {
  assert_encoded(
    SessionMessage(payload: SetName("Alice")),
    "82A474797065AF73657373696F6E5F6D657373616765A77061796C6F6164C41382A130A5416C696365A15FA75365744E616D65",
  )
}

pub fn snapshot_snapshot_session_test() {
  assert_encoded(
    Snapshot(
      target: Session,
      sequence: 7,
      state: test_fixtures.Model(..test_fixtures.initial_model(), count: 5, name: "Bob", connected: True),
    ),
    "84A474797065A8736E617073686F74A674617267657481A46B696E64A773657373696F6EA873657175656E636507A57374617465C42D87A13005A131A3426F62A132C3A13381A15FA454616241A13400A13581A15FA5456D707479A15FA54D6F64656C",
  )
}

pub fn snapshot_subscribe_test() {
  assert_encoded(
    Subscribe(topic_id: "chat"),
    "82A474797065A9737562736372696265A8746F7069635F6964A463686174",
  )
}

pub fn snapshot_topic_message_test() {
  assert_encoded(
    TopicMessage(topic_id: "chat", payload: Increment),
    "83A474797065AD746F7069635F6D657373616765A8746F7069635F6964A463686174A77061796C6F6164C40D81A15FA9496E6372656D656E74",
  )
}

pub fn snapshot_topic_update_test() {
  assert_encoded(
    TopicUpdate(topic_id: "chat", sequence: 3, payload: Increment),
    "84A474797065AC746F7069635F757064617465A8746F7069635F6964A463686174A873657175656E636503A77061796C6F6164C40D81A15FA9496E6372656D656E74",
  )
}

pub fn snapshot_unsubscribe_test() {
  assert_encoded(
    Unsubscribe(topic_id: "chat"),
    "82A474797065AB756E737562736372696265A8746F7069635F6964A463686174",
  )
}

// =============================================================================
// CROSS-TARGET ROUNDTRIPS
// =============================================================================
// These run on both targets. If both targets agree on the wire format AND
// each can roundtrip its own output, the wire format is consistent.

pub fn roundtrip_acknowledge_session_test() {
  assert_roundtrip(Acknowledge(target: Session, sequence: 42))
}

pub fn roundtrip_acknowledge_topic_test() {
  assert_roundtrip(Acknowledge(target: Topic(id: "chat"), sequence: 1))
}

pub fn roundtrip_connected_test() {
  assert_roundtrip(Connected(client_id: "abc123"))
}

pub fn roundtrip_resync_session_topic_test() {
  assert_roundtrip(Resync(cursors: [Session, Topic(id: "chat")]))
}

pub fn roundtrip_session_message_set_name_test() {
  assert_roundtrip(SessionMessage(payload: SetName("Alice")))
}

pub fn roundtrip_snapshot_test() {
  assert_roundtrip(Snapshot(
    target: Session,
    sequence: 7,
    state: test_fixtures.Model(..test_fixtures.initial_model(), count: 5, name: "Bob", connected: True),
  ))
}

pub fn roundtrip_subscribe_test() {
  assert_roundtrip(Subscribe(topic_id: "chat"))
}

pub fn roundtrip_topic_update_test() {
  assert_roundtrip(TopicUpdate(
    topic_id: "chat",
    sequence: 3,
    payload: Increment,
  ))
}

pub fn roundtrip_unsubscribe_test() {
  assert_roundtrip(Unsubscribe(topic_id: "chat"))
}
