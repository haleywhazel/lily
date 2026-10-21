// JS transport seams, connector, with_offline_queue and the websocket connector

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/list

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/client
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support
@target(javascript)
import lily/transport

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

  test_support.get(delivered) |> list.reverse |> should.equal([<<1>>, <<2>>])
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
  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<1>>, <<2>>])
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
  test_support.write_session_storage("test_queue_d", "[\"AQID\"]")
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
  test_support.write_session_storage("test_queue_e", "[\"AQID\"]")
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
  test_support.get(delivered)
  |> list.reverse
  |> should.equal([<<1, 2, 3>>, <<4>>])
}

@target(javascript)
pub fn plain_connector_has_nothing_pending_test() {
  transport.connector(fn(_handler) {
    transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
  })
  |> transport.pending
  |> should.equal([])
}

// =============================================================================
// REPLAY ON CONNECT
// =============================================================================

@target(javascript)
pub fn connect_applies_edits_left_in_the_queue_and_sends_them_once_test() {
  test_support.reset_dom()
  let frame =
    transport.encode(
      transport.SessionMessage(payload: test_support.Increment),
      serialiser: test_support.custom_serialiser(),
    )
  test_support.write_session_storage(
    "test_queue_replay",
    "[\"" <> bit_array.base64_encode(frame, True) <> "\"]",
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
  handler.opened()

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
  handler.opened()

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> should.equal([
    transport.Resync(cursors: [transport.Session, transport.Topic("chat")]),
    transport.TopicMessage(topic_id: "chat", payload: test_support.Increment),
    transport.TopicMessage(topic_id: "chat", payload: test_support.Increment),
  ])
}

@target(javascript)
pub fn connect_sends_the_resync_ahead_of_a_reloaded_queue_test() {
  test_support.reset_dom()
  let frame =
    encode(transport.TopicMessage(
      topic_id: "chat",
      payload: test_support.Increment,
    ))
  test_support.write_session_storage(
    "test_queue_reloaded_order",
    "[\"" <> bit_array.base64_encode(frame, True) <> "\"]",
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
  handler.opened()

  test_support.get(delivered)
  |> list.reverse
  |> decode_all
  |> should.equal([
    transport.Resync(cursors: [transport.Session, transport.Topic("chat")]),
    transport.TopicMessage(topic_id: "chat", payload: test_support.Increment),
  ])
}

@target(javascript)
pub fn connect_keeps_a_reloaded_edit_on_top_of_the_snapshot_test() {
  // replayed edits count as unconfirmed until the server answers them
  test_support.reset_dom()
  let frame =
    encode(transport.TopicMessage(
      topic_id: "chat",
      payload: test_support.Increment,
    ))
  test_support.write_session_storage(
    "test_queue_reloaded_pending",
    "[\"" <> bit_array.base64_encode(frame, True) <> "\"]",
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
  handler.opened()

  // the snapshot was taken before the queued edit landed
  handler.received(
    encode(transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    )),
  )
  client.model(runtime).count |> should.equal(1)
  handler.received(
    encode(transport.Acknowledge(target: transport.Topic("chat"), sequence: 1)),
  )
  handler.received(
    encode(transport.Snapshot(
      target: transport.Topic("chat"),
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
