// JS transport seams, connector, with_offline_queue and the websocket connector

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/browser
@target(javascript)
import lily/client
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support
@target(javascript)
import lily/transport
@target(javascript)
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn quiet_handler() -> transport.ConnectorHandler {
  transport.ConnectorHandler(
    received: fn(_) { Nil },
    opened: fn() { Nil },
    closed: fn() { Nil },
  )
}

@target(javascript)
fn decode_all(
  frames: List(BitArray),
) -> List(transport.Protocol(test_support.Model, test_support.Message)) {
  list.map(frames, fn(bytes) {
    let assert Ok(frame) =
      transport.decode(bytes, serialiser: test_support.custom_serialiser())
    frame
  })
}

@target(javascript)
fn encode(
  frame: transport.Protocol(test_support.Model, test_support.Message),
) -> BitArray {
  transport.encode(frame, serialiser: test_support.custom_serialiser())
}

@target(javascript)
/// Topic store runtime that always wants `chat`.
fn chat_runtime() -> client.Runtime(
  test_support.Model,
  test_support.Message,
  store.Synced,
) {
  test_support.topic_store()
  |> store.subscriptions(fn(_) { ["chat"] })
  |> client.start
}

@target(javascript)
/// Records sends, succeeds only while `online` is True. Returns the handler.
fn recording_connector(
  online: test_support.Ref(Bool),
  delivered: test_support.Ref(List(BitArray)),
  handler_cell: test_support.Ref(transport.ConnectorHandler),
) -> transport.Connector {
  transport.connector(fn(handler) {
    test_support.set(handler_cell, handler)
    transport.Channel(
      send: fn(bytes) {
        case test_support.get(online) {
          True -> {
            test_support.set(delivered, [bytes, ..test_support.get(delivered)])
            Ok(Nil)
          }
          False -> Error(Nil)
        }
      },
      close: fn() { Nil },
    )
  })
}

// =============================================================================
// WITH OFFLINE QUEUE
// =============================================================================

@target(javascript)
pub fn offline_queue_holds_an_undelivered_frame_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_a", "")
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_a")
  let channel = transport.run_connector(connector, quiet_handler())

  channel.send(<<1, 2, 3>>) |> should.equal(Error(Nil))

  test_support.get(delivered) |> should.equal([])
  transport.pending(connector) |> should.equal([<<1, 2, 3>>])
}

@target(javascript)
pub fn offline_queue_replays_in_order_when_the_channel_opens_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_b", "")
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let opened = test_support.new(0)
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_b")
  let channel =
    transport.run_connector(
      connector,
      transport.ConnectorHandler(..quiet_handler(), opened: fn() {
        test_support.set(opened, test_support.get(opened) + 1)
      }),
    )
  let _ = channel.send(<<1>>)
  let _ = channel.send(<<2>>)

  test_support.set(online, True)
  let inner_handler = test_support.get(handler_cell)
  inner_handler.opened()
  // held until the first frame after the open, the runtime's resync
  test_support.get(delivered) |> should.equal([])
  let _ = channel.send(<<0>>)

  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<0>>, <<1>>, <<2>>])
  transport.pending(connector) |> should.equal([])
  test_support.get(opened) |> should.equal(1)
}

@target(javascript)
pub fn offline_queue_lets_the_first_frame_after_an_open_go_ahead_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_f", "")
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let channel_cell =
    test_support.new(
      transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil }),
    )
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_f")
  let channel =
    transport.run_connector(
      connector,
      transport.ConnectorHandler(..quiet_handler(), opened: fn() {
        let _ = test_support.get(channel_cell).send(<<9>>)
        Nil
      }),
    )
  test_support.set(channel_cell, channel)
  let _ = channel.send(<<1>>)
  let _ = channel.send(<<2>>)

  test_support.set(online, True)
  let inner_handler = test_support.get(handler_cell)
  inner_handler.opened()

  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<9>>, <<1>>, <<2>>])
}

@target(javascript)
pub fn offline_queue_keeps_a_later_frame_behind_queued_ones_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_g", "")
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_g")
  let channel = transport.run_connector(connector, quiet_handler())
  let _ = channel.send(<<1>>)
  test_support.set(online, True)

  // deliverable, but <<1>> is still waiting
  channel.send(<<2>>) |> should.equal(Error(Nil))

  test_support.get(delivered) |> should.equal([])
  let inner_handler = test_support.get(handler_cell)
  inner_handler.opened()
  let _ = channel.send(<<0>>)
  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<0>>, <<1>>, <<2>>])
}

@target(javascript)
pub fn offline_queue_passes_a_delivered_frame_straight_through_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_c", "")
  let online = test_support.new(True)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_c")
  let channel = transport.run_connector(connector, quiet_handler())

  channel.send(<<7>>) |> should.equal(Ok(Nil))

  test_support.get(delivered) |> should.equal([<<7>>])
  transport.pending(connector) |> should.equal([])
}

@target(javascript)
pub fn offline_queue_pending_reads_frames_left_by_an_earlier_page_test() {
  test_support.reset_dom()
  // `AQID` is base64 for bytes 1, 2, 3
  test_support.write_session_storage(
    "test_queue_d",
    "{\"protocol\":2,\"frames\":[\"AQID\"]}",
  )
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_d")

  transport.pending(connector) |> should.equal([<<1, 2, 3>>])
}

@target(javascript)
pub fn offline_queue_keeps_an_earlier_page_frames_when_a_send_fails_test() {
  test_support.reset_dom()
  // `AQID` is base64 for bytes 1, 2, 3
  test_support.write_session_storage(
    "test_queue_e",
    "{\"protocol\":2,\"frames\":[\"AQID\"]}",
  )
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_e")
  let channel = transport.run_connector(connector, quiet_handler())

  // fails before the first open, meaning it joins the earlier page's frame
  let _ = channel.send(<<4>>)

  test_support.set(online, True)
  let inner_handler = test_support.get(handler_cell)
  inner_handler.opened()
  let _ = channel.send(<<0>>)
  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<0>>, <<1, 2, 3>>, <<4>>])
}

@target(javascript)
pub fn offline_queue_drops_frames_queued_before_message_ids_test() {
  test_support.reset_dom()
  // a bare array is a version 1 queue, whose frames carry no ids
  test_support.write_session_storage("test_queue_v1", "[\"AQID\"]")
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_v1")

  transport.pending(connector) |> should.equal([])
}

@target(javascript)
pub fn offline_queue_requeue_replaces_what_is_held_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_requeue", "")
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_requeue")
  let channel = transport.run_connector(connector, quiet_handler())
  let _ = channel.send(<<9>>)

  transport.requeue(connector, [<<1>>, <<2>>], delivered: 0)

  transport.pending(connector) |> should.equal([<<1>>, <<2>>])
}

@target(javascript)
pub fn offline_queue_requeue_sends_in_order_on_the_next_open_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_requeue_open", "")
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_requeue_open")
  let channel = transport.run_connector(connector, quiet_handler())

  transport.requeue(connector, [<<1>>, <<2>>], delivered: 0)
  test_support.set(online, True)
  test_support.get(handler_cell).opened()
  let _ = channel.send(<<0>>)

  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<0>>, <<1>>, <<2>>])
}

@target(javascript)
pub fn offline_queue_requeue_keeps_what_was_on_the_wire_for_a_reload_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_requeue_reload", "")
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_requeue_reload")
  let _ = transport.run_connector(connector, quiet_handler())

  transport.requeue(connector, [<<1>>], delivered: 4)

  transport.connector(fn(_handler) {
    transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
  })
  |> transport.with_offline_queue(storage_key: "test_queue_requeue_reload")
  |> transport.pending_delivered
  |> should.equal(4)
}

@target(javascript)
pub fn plain_connector_has_nothing_pending_test() {
  transport.connector(fn(_handler) {
    transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
  })
  |> transport.pending
  |> should.equal([])
}

@target(javascript)
pub fn offline_queue_is_emptied_by_clear_persisted_and_stays_out_of_storage_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_cleared", "")
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_cleared")
  let channel = transport.run_connector(connector, quiet_handler())
  let _ = channel.send(<<1>>)
  transport.keep_owner(connector, "alice")

  browser.clear_persisted()

  transport.pending(connector) |> should.equal([])
  transport.pending_owner(connector) |> should.equal(option.None)
  test_support.read_session_storage("test_queue_cleared_owner")
  |> should.equal("")

  // a close on the way out of the page requeues, which mustn't be kept
  transport.requeue(connector, [<<2>>], delivered: 0)
  let _ = channel.send(<<3>>)
  test_support.read_session_storage("test_queue_cleared") |> should.equal("")
}

@target(javascript)
pub fn offline_queue_keeps_its_owner_without_any_frames_test() {
  test_support.reset_dom()
  let connector = fn() {
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_owner")
  }
  transport.pending_owner(connector()) |> should.equal(option.None)

  transport.keep_owner(connector(), "alice")

  // read back by the next page
  transport.pending_owner(connector()) |> should.equal(option.Some("alice"))
}

// =============================================================================
// REPLAY ON CONNECT
// =============================================================================

@target(javascript)
pub fn connect_applies_edits_left_in_the_queue_and_sends_them_once_test() {
  test_support.reset_dom()
  let frame =
    transport.encode(
      transport.SessionMessage(id: 1, payload: test_support.Increment),
      serialiser: test_support.custom_serialiser(),
    )
  test_support.write_session_storage(
    "test_queue_replay",
    "{\"protocol\":2,\"frames\":[\""
      <> bit_array.base64_encode(frame, True)
      <> "\"]}",
  )
  let runtime = test_support.new_synced_runtime()
  let online = test_support.new(True)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_replay")

  let _ = client.connect(runtime, with: connector)

  // on screen before the connection opens
  client.model(runtime).count |> should.equal(1)
  test_support.get(delivered) |> should.equal([])

  let handler = test_support.get(handler_cell)
  test_support.open(handler)

  // sent exactly once, the replay did not queue it a second time
  test_support.get(delivered)
  |> list.filter(fn(bytes) { bytes == frame })
  |> list.length
  |> should.equal(1)
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn connect_sends_the_resync_ahead_of_edits_queued_offline_test() {
  // the server drops a topic message from a client that hasn't joined
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_order", "")
  let runtime = chat_runtime()
  let online = test_support.new(False)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_order")
  let _ = client.connect(runtime, with: connector)
  client.dispatch(runtime)(test_support.Increment)
  client.dispatch(runtime)(test_support.Increment)

  test_support.set(online, True)
  let handler = test_support.get(handler_cell)
  test_support.open(handler)

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> should.equal([
    transport.Resync(
      cursors: [
        transport.Unknown(transport.Session),
        transport.Unknown(transport.Topic("chat")),
      ],
      resume: option.None,
      delivered: 0,
    ),
    transport.TopicMessage(
      topic_id: "chat",
      id: 1,
      payload: test_support.Increment,
    ),
    transport.TopicMessage(
      topic_id: "chat",
      id: 2,
      payload: test_support.Increment,
    ),
  ])
}

@target(javascript)
pub fn connect_sends_the_resync_ahead_of_a_reloaded_queue_test() {
  test_support.reset_dom()
  let frame =
    encode(transport.TopicMessage(
      topic_id: "chat",
      id: 1,
      payload: test_support.Increment,
    ))
  test_support.write_session_storage(
    "test_queue_reloaded_order",
    "{\"protocol\":2,\"frames\":[\""
      <> bit_array.base64_encode(frame, True)
      <> "\"]}",
  )
  let runtime = chat_runtime()
  let online = test_support.new(True)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_reloaded_order")
  let _ = client.connect(runtime, with: connector)

  let handler = test_support.get(handler_cell)
  test_support.open(handler)

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> should.equal([
    transport.Resync(
      cursors: [
        transport.Unknown(transport.Session),
        transport.Unknown(transport.Topic("chat")),
      ],
      resume: option.None,
      delivered: 0,
    ),
    transport.TopicMessage(
      topic_id: "chat",
      id: 1,
      payload: test_support.Increment,
    ),
  ])
}

@target(javascript)
pub fn connect_resyncs_with_what_an_earlier_page_put_on_the_wire_test() {
  // its retransmits may have landed, a fresh session refuses them
  test_support.reset_dom()
  let frame =
    encode(transport.TopicMessage(
      topic_id: "chat",
      id: 3,
      payload: test_support.Increment,
    ))
  test_support.write_session_storage(
    "test_queue_reloaded_delivered",
    "{\"protocol\":2,\"frames\":[\""
      <> bit_array.base64_encode(frame, True)
      <> "\"],\"delivered\":3}",
  )
  let runtime = chat_runtime()
  let online = test_support.new(True)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(
      storage_key: "test_queue_reloaded_delivered",
    )
  let _ = client.connect(runtime, with: connector)

  test_support.open(test_support.get(handler_cell))

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> list.first
  |> should.equal(
    Ok(transport.Resync(
      cursors: [
        transport.Unknown(transport.Session),
        transport.Unknown(transport.Topic("chat")),
      ],
      resume: option.None,
      delivered: 3,
    )),
  )
}

@target(javascript)
/// A `chat` runtime over a queue holding one stored edit, kept as `owner`.
fn reloaded(
  storage_key: String,
  owner: option.Option(String),
) -> #(
  client.Runtime(test_support.Model, test_support.Message, store.Synced),
  test_support.Ref(transport.ConnectorHandler),
  fn() -> List(transport.Protocol(test_support.Model, test_support.Message)),
) {
  test_support.reset_dom()
  let frame =
    encode(transport.TopicMessage(
      topic_id: "chat",
      id: 1,
      payload: test_support.Increment,
    ))
  test_support.write_session_storage(
    storage_key,
    "{\"protocol\":2,\"frames\":[\""
      <> bit_array.base64_encode(frame, True)
      <> "\"]}",
  )
  case owner {
    option.Some(owner) ->
      test_support.write_session_storage(storage_key <> "_owner", owner)
    option.None -> Nil
  }
  let runtime = chat_runtime()
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(test_support.new(True), delivered, handler_cell)
    |> transport.with_offline_queue(storage_key:)
  let _ = client.connect(runtime, with: connector)
  #(runtime, handler_cell, fn() {
    test_support.get(delivered) |> list.reverse |> decode_all
  })
}

@target(javascript)
fn is_message(
  frame: transport.Protocol(test_support.Model, test_support.Message),
) -> Bool {
  case frame {
    transport.TopicMessage(..) | transport.SessionMessage(..) -> True
    _ -> False
  }
}

@target(javascript)
pub fn connect_waits_for_the_greeting_before_it_sends_anything_test() {
  let #(runtime, handler_cell, sent) =
    reloaded("test_queue_waits", option.Some("alice"))
  let handler = test_support.get(handler_cell)

  handler.opened()
  client.dispatch(runtime)(test_support.Increment)
  sent() |> should.equal([])

  handler.received(test_support.greeting(owner: "alice"))
  case sent() {
    [transport.Resync(..), ..messages] ->
      list.map(messages, fn(frame) {
        case frame {
          transport.TopicMessage(id:, ..) -> id
          _ -> 0
        }
      })
      |> should.equal([1, 2])
    _ -> should.fail()
  }
}

@target(javascript)
pub fn connect_replays_a_queue_its_own_session_left_test() {
  let #(runtime, handler_cell, sent) =
    reloaded("test_queue_same_owner", option.Some("alice"))
  let handler = test_support.get(handler_cell)

  handler.opened()
  handler.received(test_support.greeting(owner: "alice"))

  sent() |> list.filter(is_message) |> list.length |> should.equal(1)
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn connect_discards_a_queue_another_session_left_test() {
  let #(runtime, handler_cell, sent) =
    reloaded("test_queue_other_owner", option.Some("alice"))
  let handler = test_support.get(handler_cell)
  let #(record, recorded) = wire_support.recorder()
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.Diagnostic(message:, ..) -> record(<<message:utf8>>)
        _ -> Nil
      }
    })

  handler.opened()
  handler.received(test_support.greeting(owner: "bob"))

  sent() |> list.filter(is_message) |> should.equal([])
  test_support.read_session_storage("test_queue_other_owner")
  |> should.equal("")
  test_support.read_session_storage("test_queue_other_owner_owner")
  |> should.equal("bob")
  recorded()
  |> should.equal([
    <<
      "lily: discarded 1 queued messages, they belong to another session":utf8,
    >>,
  ])

  // the server's copy replaces the edit that was on screen
  handler.received(
    encode(wire_support.chat_snapshot(test_support.initial_model())),
  )
  client.model(runtime).count |> should.equal(0)
}

@target(javascript)
pub fn connect_discards_what_is_pending_when_a_reconnect_is_someone_else_test() {
  test_support.reset_dom()
  test_support.write_session_storage("test_queue_swapped", "")
  let runtime = chat_runtime()
  let online = test_support.new(True)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_swapped")
  let _ = client.connect(runtime, with: connector)
  let handler = test_support.get(handler_cell)
  handler.opened()
  handler.received(test_support.greeting(owner: "alice"))

  handler.closed()
  test_support.set(online, False)
  client.dispatch(runtime)(test_support.Increment)
  test_support.set(online, True)
  test_support.set(delivered, [])
  handler.opened()
  handler.received(test_support.greeting(owner: "bob"))

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> list.filter(is_message)
  |> should.equal([])
}

@target(javascript)
pub fn connect_keeps_an_unclaimed_queue_where_sessions_have_no_owner_test() {
  let #(_runtime, handler_cell, sent) =
    reloaded("test_queue_no_owner", option.None)
  let handler = test_support.get(handler_cell)

  handler.opened()
  handler.received(test_support.greeting(owner: ""))

  sent() |> list.filter(is_message) |> list.length |> should.equal(1)
}

@target(javascript)
pub fn connect_discards_an_unclaimed_queue_once_sessions_have_owners_test() {
  // an earlier page that was never greeted can't say whose edits these are
  let #(_runtime, handler_cell, sent) =
    reloaded("test_queue_unclaimed", option.None)
  let handler = test_support.get(handler_cell)

  handler.opened()
  handler.received(test_support.greeting(owner: "alice"))

  sent() |> list.filter(is_message) |> should.equal([])
}

@target(javascript)
pub fn connect_keeps_what_this_page_made_before_its_first_greeting_test() {
  test_support.reset_dom()
  let runtime = chat_runtime()
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(test_support.new(True), delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_own_page")
  let _ = client.connect(runtime, with: connector)
  let handler = test_support.get(handler_cell)

  handler.opened()
  client.dispatch(runtime)(test_support.Increment)
  handler.received(test_support.greeting(owner: "alice"))

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> list.filter(is_message)
  |> list.length
  |> should.equal(1)
}

@target(javascript)
pub fn connect_keeps_a_reloaded_edit_on_top_of_the_snapshot_test() {
  // replayed edits count as unconfirmed until the server answers them
  test_support.reset_dom()
  let frame =
    encode(transport.TopicMessage(
      topic_id: "chat",
      id: 1,
      payload: test_support.Increment,
    ))
  test_support.write_session_storage(
    "test_queue_reloaded_pending",
    "{\"protocol\":2,\"frames\":[\""
      <> bit_array.base64_encode(frame, True)
      <> "\"]}",
  )
  let runtime = chat_runtime()
  let online = test_support.new(True)
  let delivered = test_support.new([])
  let handler_cell = test_support.new(quiet_handler())
  let connector =
    recording_connector(online, delivered, handler_cell)
    |> transport.with_offline_queue(storage_key: "test_queue_reloaded_pending")
  let _ = client.connect(runtime, with: connector)
  let handler = test_support.get(handler_cell)
  test_support.open(handler)

  // the snapshot was taken before the queued edit landed
  handler.received(
    encode(transport.Snapshot(
      target: transport.Topic("chat"),
      epoch: 0,
      sequence: 0,
      state: test_support.initial_model(),
    )),
  )
  client.model(runtime).count |> should.equal(1)
  handler.received(
    encode(transport.Acknowledge(
      target: transport.Topic("chat"),
      sequence: 1,
      id: 1,
    )),
  )
  handler.received(
    encode(transport.Snapshot(
      target: transport.Topic("chat"),
      epoch: 0,
      sequence: 1,
      state: test_support.Model(..test_support.initial_model(), count: 1),
    )),
  )

  client.model(runtime).count |> should.equal(1)
}

// =============================================================================
// WEBSOCKET
// =============================================================================

@target(javascript)
pub fn websocket_drives_the_handler_through_open_receive_and_close_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  test_support.write_session_storage("lily_ws_pending", "")
  let opened = test_support.new(0)
  let closed = test_support.new(0)
  let received = test_support.new([])
  let _channel =
    transport.run_connector(
      transport.websocket("ws://localhost/ws"),
      transport.ConnectorHandler(
        received: fn(bytes) {
          test_support.set(received, [bytes, ..test_support.get(received)])
        },
        opened: fn() { test_support.set(opened, test_support.get(opened) + 1) },
        closed: fn() { test_support.set(closed, test_support.get(closed) + 1) },
      ),
    )
  let socket = test_support.get_last_websocket()

  test_support.trigger_websocket_open(socket)
  test_support.trigger_websocket_message(socket, "hello")
  test_support.trigger_websocket_close(socket)

  test_support.get(opened) |> should.equal(1)
  test_support.get(closed) |> should.equal(1)
  test_support.get(received)
  |> should.equal([bit_array.from_string("hello")])
}

@target(javascript)
pub fn websocket_resolves_a_relative_url_against_the_page_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let _ =
    transport.run_connector(
      transport.websocket_with(
        url: "/live/socket",
        reconnect: transport.DefaultBackoff,
      ),
      quiet_handler(),
    )

  test_support.websocket_url(test_support.get_last_websocket())
  |> should.equal("ws://localhost:8080/live/socket")
}

@target(javascript)
pub fn websocket_leaves_an_absolute_url_alone_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let _ =
    transport.run_connector(
      transport.websocket("wss://example.com:9000/ws"),
      quiet_handler(),
    )

  test_support.websocket_url(test_support.get_last_websocket())
  |> should.equal("wss://example.com:9000/ws")
}

@target(javascript)
pub fn websocket_with_a_custom_backoff_connects_test() {
  test_support.reset_dom()
  test_support.reset_mocks()

  let _ =
    transport.run_connector(
      transport.websocket_with(
        url: "ws://localhost/ws",
        reconnect: transport.Backoff(
          base_milliseconds: 1000,
          max_milliseconds: 30_000,
          jitter_ratio: 0.1,
          multiplier: 1.5,
        ),
      ),
      quiet_handler(),
    )

  test_support.websocket_url(test_support.get_last_websocket())
  |> should.equal("ws://localhost/ws")
}

@target(javascript)
pub fn websocket_send_when_closed_queues_to_sessionstorage_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_synced_runtime()
  let _ =
    client.connect(runtime, with: transport.websocket("ws://localhost/ws"))

  // never opened, still connecting
  client.dispatch(runtime)(test_support.Increment)

  test_support.read_session_storage("lily_ws_pending")
  |> should.not_equal("")
}
