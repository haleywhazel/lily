// Wire-format snapshot tests for the MessagePack auto-serialiser. Encoded
// byte sequences are pinned here so any change to the codec (Erlang FFI, JS
// FFI, or a future pure-Gleam implementation) that produces non-identical
// output is caught immediately.
//
// The tests run on both targets, so any cross-target divergence also fails.

import gleam/bit_array
import gleam/dict
import gleam/set
import gleam/string
import gleeunit/should
import lily/test_fixtures.{
  type Message, type Model, Increment, SetName, WithDict, WithSet, WithTuple,
}
import lily/transport.{
  type Protocol, Acknowledge, Connected, Push, Rejected, Resync, Session,
  SessionMessage, SessionUpdate, Snapshot, Subscribe, Topic, TopicMessage,
  TopicUpdate, Unsubscribe,
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

// Generic variants for tests that wrap non-Model types (tuple/dict/set).
// transport.automatic() is parametric, so the serialiser specialises to
// whatever model/message types the caller uses.
fn assert_encoded_generic(
  p: Protocol(model, message),
  expected_hex: String,
) -> Nil {
  let s = transport.automatic() |> transport.use_message_pack
  let bytes = transport.encode(p, serialiser: s)
  let actual_hex = bit_array.base16_encode(bytes)
  actual_hex
  |> should.equal(expected_hex)
}

fn assert_roundtrip_generic(p: Protocol(model, message)) -> Nil {
  let s = transport.automatic() |> transport.use_message_pack
  transport.encode(p, serialiser: s)
  |> transport.decode(serialiser: s)
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

/// Regression: Gleam's empty list (`Empty` singleton on JS, `[]` on Erlang)
/// must encode as MessagePack array length 0 (`90`) on both targets.
/// Before this was caught, the JS auto-encoder fell through to the
/// CustomType branch and produced `{"_":"Empty"}` instead, which diverged
/// from Erlang's native list encoding.
pub fn snapshot_resync_empty_cursors_test() {
  assert_encoded(
    Resync(cursors: []),
    "82A474797065A6726573796E63A7637572736F727390",
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

pub fn snapshot_session_update_test() {
  assert_encoded(
    SessionUpdate(sequence: 4, payload: Increment),
    "83A474797065AE73657373696F6E5F757064617465A873657175656E636504A77061796C6F6164C40D81A15FA9496E6372656D656E74",
  )
}

pub fn snapshot_snapshot_session_test() {
  assert_encoded(
    Snapshot(
      target: Session,
      sequence: 7,
      state: test_fixtures.Model(
        ..test_fixtures.initial_model(),
        count: 5,
        name: "Bob",
        connected: True,
      ),
    ),
    "84A474797065A8736E617073686F74A674617267657481A46B696E64A773657373696F6EA873657175656E636507A57374617465C42C87A13005A131A3426F62A132C3A13381A15FA454616241A13400A13581A15FA44E6F6E65A15FA54D6F64656C",
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

pub fn roundtrip_session_update_test() {
  assert_roundtrip(SessionUpdate(sequence: 4, payload: Increment))
}

// =============================================================================
// INITIAL SNAPSHOT EMBED
// =============================================================================

pub fn encode_initial_snapshot_wraps_in_script_tag_test() {
  let snapshot =
    transport.encode_initial_snapshot(
      serialiser: transport.automatic(),
      model: test_fixtures.initial_model(),
    )
  let expected_prefix =
    "<script type=\"application/json\" id=\"lily-snapshot\">"
  snapshot
  |> string.starts_with(expected_prefix)
  |> should.be_true
  snapshot
  |> string.ends_with("</script>")
  |> should.be_true
}

pub fn encode_initial_snapshot_round_trips_via_decode_test() {
  let model = test_fixtures.initial_model()
  let embed =
    transport.encode_initial_snapshot(
      serialiser: transport.automatic(),
      model: model,
    )
  let prefix = "<script type=\"application/json\" id=\"lily-snapshot\">"
  let suffix = "</script>"
  let json_only =
    embed
    |> string.drop_start(string.length(prefix))
    |> string.drop_end(string.length(suffix))

  transport.decode(
    bit_array.from_string(json_only),
    serialiser: transport.automatic(),
  )
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: model)))
}

pub fn roundtrip_snapshot_test() {
  assert_roundtrip(Snapshot(
    target: Session,
    sequence: 7,
    state: test_fixtures.Model(
      ..test_fixtures.initial_model(),
      count: 5,
      name: "Bob",
      connected: True,
    ),
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

// =============================================================================
// COLLECTION TYPES (tuple, dict, set) cross-target wire format
// =============================================================================
// These are values the auto-serialiser couldn't previously handle. The
// shapes are: tuples encode as tag-less `{"0":...,"1":...}` objects;
// dicts encode as `{"_":"$dict","0":[[k,v],...]}`, sets encode as
// `{"_":"$set","0":[v,...]}`. Empty bytes are pinned so cross-target
// divergence trips immediately, non-empty cases use roundtrip rather
// than byte-pinning because dict/set iteration order isn't guaranteed.

/// Tuple inside a CustomType wrapper. Tuple `#(1, "hi")` encodes as
/// `{"0":1,"1":"hi"}` (object with numeric keys, no `_` tag). The
/// surrounding WithTuple wrapper provides the `_:"WithTuple"` tag so
/// the constructor can be reconstructed.
pub fn snapshot_tuple_test() {
  assert_encoded_generic(
    Snapshot(target: Session, sequence: 0, state: WithTuple(pair: #(1, "hi"))),
    "84A474797065A8736E617073686F74A674617267657481A46B696E64A773657373696F6EA873657175656E636500A57374617465C41882A13082A13001A131A26869A15FA9576974685475706C65",
  )
}

pub fn roundtrip_tuple_test() {
  assert_roundtrip_generic(Snapshot(
    target: Session,
    sequence: 1,
    state: WithTuple(pair: #(42, "answer")),
  ))
}

/// Empty Dict encodes as `{"_":"$dict","0":[]}`. The trailing `90` is
/// MessagePack fixarray length 0 same as the empty-list case we
/// fixed earlier.
pub fn snapshot_empty_dict_test() {
  assert_encoded_generic(
    Snapshot(target: Session, sequence: 0, state: WithDict(entries: dict.new())),
    "84A474797065A8736E617073686F74A674617267657481A46B696E64A773657373696F6EA873657175656E636500A57374617465C41A82A13082A13090A15FA52464696374A15FA85769746844696374",
  )
}

pub fn roundtrip_dict_test() {
  // Single-entry dict so iteration order doesn't matter for the
  // roundtrip equality check. Multi-entry roundtrip would still work
  // because dict equality is order-independent.
  let entries = dict.from_list([#("only", 1)])
  assert_roundtrip_generic(Snapshot(
    target: Session,
    sequence: 2,
    state: WithDict(entries:),
  ))
}

/// Empty Set encodes as `{"_":"$set","0":[]}`.
pub fn snapshot_empty_set_test() {
  assert_encoded_generic(
    Snapshot(target: Session, sequence: 0, state: WithSet(members: set.new())),
    "84A474797065A8736E617073686F74A674617267657481A46B696E64A773657373696F6EA873657175656E636500A57374617465C41882A13082A13090A15FA424736574A15FA757697468536574",
  )
}

pub fn roundtrip_set_test() {
  let members = set.from_list([7])
  assert_roundtrip_generic(Snapshot(
    target: Session,
    sequence: 3,
    state: WithSet(members:),
  ))
}
