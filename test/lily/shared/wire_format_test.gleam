// pinned MessagePack bytes for the auto-serialiser, on both targets
// every frame must also decode under the other format

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import lily/store
import lily/test_support.{
  type Message, type Model, Increment, SetName, WithDict, WithSet, WithTuple,
}
import lily/transport.{
  type Protocol, Acknowledge, Connected, Rejected, Resync, Session,
  SessionMessage, SessionUpdate, Snapshot, Subscribe, Topic, TopicMessage,
  TopicUpdate, Unsubscribe, Version,
}

// =============================================================================
// HELPERS
// =============================================================================

fn assert_encoded(
  protocol: Protocol(Model, Message),
  expected_hex: String,
) -> Nil {
  let bytes =
    transport.encode(
      protocol,
      serialiser: test_support.message_pack_serialiser(),
    )
  let actual_hex = bit_array.base16_encode(bytes)
  actual_hex
  |> should.equal(expected_hex)
}

fn assert_roundtrip(protocol: Protocol(Model, Message)) -> Nil {
  transport.encode(protocol, serialiser: test_support.message_pack_serialiser())
  |> transport.decode(serialiser: test_support.message_pack_serialiser())
  |> should.equal(Ok(protocol))
}

// generic variant for non-Model types (tuple/dict/set)
fn assert_encoded_generic(
  protocol: Protocol(model, message),
  expected_hex: String,
) -> Nil {
  let serialiser =
    transport.automatic(
      format: transport.MessagePack,
      max_decode_depth: 128,
      modules: [],
    )
  let bytes = transport.encode(protocol, serialiser: serialiser)
  let actual_hex = bit_array.base16_encode(bytes)
  actual_hex
  |> should.equal(expected_hex)
}

fn assert_roundtrip_generic(protocol: Protocol(model, message)) -> Nil {
  let serialiser =
    transport.automatic(
      format: transport.MessagePack,
      max_decode_depth: 128,
      modules: [],
    )
  transport.encode(protocol, serialiser: serialiser)
  |> transport.decode(serialiser: serialiser)
  |> should.equal(Ok(protocol))
}

// every protocol variant
fn every_frame() -> List(Protocol(Model, Message)) {
  [
    Acknowledge(target: Session, sequence: 42),
    Acknowledge(target: Topic(id: "chat"), sequence: 1),
    Connected(client_id: "abc123"),
    Rejected(topic_id: "secret", reason: "denied"),
    Resync(cursors: [Session, Topic(id: "chat")]),
    SessionMessage(payload: SetName("Alice")),
    SessionUpdate(sequence: 4, payload: Increment),
    Snapshot(
      target: Session,
      sequence: 7,
      state: test_support.Model(..test_support.initial_model(), name: "Bob"),
    ),
    Subscribe(topic_id: "chat"),
    TopicMessage(topic_id: "chat", payload: Increment),
    TopicUpdate(topic_id: "chat", sequence: 3, payload: Increment),
    Unsubscribe(topic_id: "chat"),
    Version(hash: "abc123"),
  ]
}

fn assert_crosses(written: transport.Format, read: transport.Format) -> Nil {
  test_support.register_fixtures()
  let writer = test_support.automatic_serialiser(written)
  let reader = test_support.automatic_serialiser(read)
  list.each(every_frame(), fn(frame) {
    transport.encode(frame, serialiser: writer)
    |> transport.decode(serialiser: reader)
    |> should.equal(Ok(frame))
  })
}

const embed_prefix =
  "<script type=\"application/octet-stream\" id=\"lily-snapshot\">"

fn embed_payload(embed: String) -> BitArray {
  let assert Ok(bytes) =
    embed
    |> string.drop_start(string.length(embed_prefix))
    |> string.drop_end(string.length("</script>"))
    |> bit_array.base64_decode
  bytes
}

fn embed_store(
  serialiser: transport.Serialiser(Model, Message),
) -> store.Store(Model, Message, store.Synced) {
  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.sync_with(route: fn(_) { store.Session }, serialiser:)
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

/// Gleam's empty list (`Empty` singleton on JS, `[]` on Erlang) encodes as
/// MessagePack array length 0 (`90`) on both targets, never as the custom
/// type `{"_":"Empty"}`.
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
      state: test_support.Model(
        ..test_support.initial_model(),
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

pub fn snapshot_version_test() {
  assert_encoded(
    Version(hash: "abc123"),
    "82A474797065A776657273696F6EA468617368A6616263313233",
  )
}

// =============================================================================
// CROSS-TARGET ROUNDTRIPS
// =============================================================================
// pinned bytes plus own-output roundtrip on both targets means consistency

pub fn roundtrip_acknowledge_session_test() {
  test_support.register_fixtures()
  assert_roundtrip(Acknowledge(target: Session, sequence: 42))
}

pub fn roundtrip_acknowledge_topic_test() {
  test_support.register_fixtures()
  assert_roundtrip(Acknowledge(target: Topic(id: "chat"), sequence: 1))
}

pub fn roundtrip_connected_test() {
  test_support.register_fixtures()
  assert_roundtrip(Connected(client_id: "abc123"))
}

pub fn roundtrip_resync_session_topic_test() {
  test_support.register_fixtures()
  assert_roundtrip(Resync(cursors: [Session, Topic(id: "chat")]))
}

pub fn roundtrip_session_message_set_name_test() {
  test_support.register_fixtures()
  assert_roundtrip(SessionMessage(payload: SetName("Alice")))
}

pub fn roundtrip_session_update_test() {
  test_support.register_fixtures()
  assert_roundtrip(SessionUpdate(sequence: 4, payload: Increment))
}

pub fn roundtrip_version_test() {
  test_support.register_fixtures()
  assert_roundtrip(Version(hash: "abc123"))
}

// =============================================================================
// CROSS-FORMAT DECODING
// =============================================================================

pub fn cross_json_frames_decode_under_message_pack_test() {
  assert_crosses(transport.Json, transport.MessagePack)
}

pub fn cross_message_pack_frames_decode_under_json_test() {
  assert_crosses(transport.MessagePack, transport.Json)
}

pub fn cross_by_host_frames_decode_under_either_format_test() {
  assert_crosses(transport.ByHost, transport.Json)
  assert_crosses(transport.ByHost, transport.MessagePack)
}

// =============================================================================
// INITIAL SNAPSHOT EMBED
// =============================================================================

pub fn initial_snapshot_wraps_in_script_tag_test() {
  let snapshot =
    store.initial_snapshot(
      embed_store(
        transport.automatic(
          format: transport.Json,
          max_decode_depth: 128,
          modules: [],
        ),
      ),
      model: test_support.initial_model(),
    )

  snapshot
  |> string.starts_with(embed_prefix)
  |> should.be_true
  snapshot
  |> string.ends_with("</script>")
  |> should.be_true
}

pub fn initial_snapshot_round_trips_via_decode_test() {
  test_support.register_fixtures()
  let model = test_support.initial_model()
  let serialiser =
    transport.automatic(
      format: transport.Json,
      max_decode_depth: 128,
      modules: [],
    )
  let embed = store.initial_snapshot(embed_store(serialiser), model:)

  transport.decode(embed_payload(embed), serialiser:)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: model)))
}

pub fn initial_snapshot_round_trips_message_pack_test() {
  test_support.register_fixtures()
  let model = test_support.initial_model()
  let serialiser =
    transport.automatic(
      format: transport.MessagePack,
      max_decode_depth: 128,
      modules: [],
    )
  let embed = store.initial_snapshot(embed_store(serialiser), model:)

  transport.decode(embed_payload(embed), serialiser:)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: model)))
}

pub fn initial_snapshot_by_host_is_written_in_message_pack_test() {
  test_support.register_fixtures()
  let model = test_support.initial_model()
  let embed =
    store.initial_snapshot(
      embed_store(test_support.automatic_serialiser(transport.ByHost)),
      model:,
    )
  let bytes = embed_payload(embed)

  transport.frame_format(
    bytes,
    serialiser: test_support.automatic_serialiser(transport.Json),
  )
  |> should.equal(Ok(transport.MessagePack))
  transport.decode(
    bytes,
    serialiser: test_support.automatic_serialiser(transport.Json),
  )
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: model)))
}

pub fn initial_snapshot_cannot_close_the_script_tag_test() {
  test_support.register_fixtures()
  let model =
    test_support.Model(
      ..test_support.initial_model(),
      name: "</script><script>alert(1)</script>",
    )
  let serialiser =
    transport.automatic(
      format: transport.Json,
      max_decode_depth: 128,
      modules: [],
    )

  let embed = store.initial_snapshot(embed_store(serialiser), model:)

  embed
  |> string.split("</script>")
  |> list.length
  |> should.equal(2)
  transport.decode(embed_payload(embed), serialiser:)
  |> should.equal(Ok(Snapshot(target: Session, sequence: 0, state: model)))
}

pub fn roundtrip_snapshot_test() {
  test_support.register_fixtures()
  assert_roundtrip(Snapshot(
    target: Session,
    sequence: 7,
    state: test_support.Model(
      ..test_support.initial_model(),
      count: 5,
      name: "Bob",
      connected: True,
    ),
  ))
}

pub fn roundtrip_subscribe_test() {
  test_support.register_fixtures()
  assert_roundtrip(Subscribe(topic_id: "chat"))
}

pub fn roundtrip_topic_update_test() {
  test_support.register_fixtures()
  assert_roundtrip(TopicUpdate(
    topic_id: "chat",
    sequence: 3,
    payload: Increment,
  ))
}

pub fn roundtrip_unsubscribe_test() {
  test_support.register_fixtures()
  assert_roundtrip(Unsubscribe(topic_id: "chat"))
}

// =============================================================================
// COLLECTION TYPES
// =============================================================================

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
  test_support.register_fixtures()
  assert_roundtrip_generic(Snapshot(
    target: Session,
    sequence: 1,
    state: WithTuple(pair: #(42, "answer")),
  ))
}

/// Empty Dict encodes as `{"_":"$dict","0":[]}`. The trailing `90` is
/// MessagePack fixarray length 0.
pub fn snapshot_empty_dict_test() {
  assert_encoded_generic(
    Snapshot(target: Session, sequence: 0, state: WithDict(entries: dict.new())),
    "84A474797065A8736E617073686F74A674617267657481A46B696E64A773657373696F6EA873657175656E636500A57374617465C41A82A13082A13090A15FA52464696374A15FA85769746844696374",
  )
}

pub fn roundtrip_dict_test() {
  test_support.register_fixtures()
  // single entry, keeping iteration order from affecting the bytes
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
  test_support.register_fixtures()
  let members = set.from_list([7])
  assert_roundtrip_generic(Snapshot(
    target: Session,
    sequence: 3,
    state: WithSet(members:),
  ))
}
