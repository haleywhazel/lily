// lily/client tests, all @target(javascript), skipped on Erlang

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/client
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{
  type Message, type Model, Claim, Increment, Model, Noop, SetName,
}
@target(javascript)
import lily/transport
@target(javascript)
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
/// Wanted topics are the comma separated model `name`.
fn subscribing_runtime() -> client.Runtime(Model, Message, store.Synced) {
  test_support.topic_store()
  |> store.subscriptions(fn(model: Model) {
    case model.name {
      "" -> []
      names -> string.split(names, ",")
    }
  })
  |> client.start
}

@target(javascript)
/// Always wants `chat`, opened, with the resync drained.
fn chat_client() -> #(
  client.Runtime(Model, Message, store.Synced),
  transport.ConnectorHandler,
  fn() -> List(transport.Protocol(Model, Message)),
) {
  let runtime =
    test_support.topic_store()
    |> store.subscriptions(fn(_) { ["chat"] })
    |> client.start
  let #(handler, sent) = test_support.connect_capturing(runtime)
  handler.opened()
  let _ = sent()
  #(runtime, handler, sent)
}

@target(javascript)
fn receive(
  handler: transport.ConnectorHandler,
  frame: transport.Protocol(Model, Message),
) -> Nil {
  handler.received(transport.encode(
    frame,
    serialiser: test_support.custom_serialiser(),
  ))
}

@target(javascript)
fn wanting(names: String) -> fn(Model) -> Model {
  fn(model) { Model(..model, name: names) }
}

@target(javascript)
fn frame_key(frame: transport.Protocol(Model, Message)) -> String {
  case frame {
    transport.Subscribe(topic_id:) -> "subscribe " <> topic_id
    transport.Unsubscribe(topic_id:) -> "unsubscribe " <> topic_id
    _ -> "other"
  }
}

// =============================================================================
// RUNTIME LIFECYCLE
// =============================================================================

@target(javascript)
pub fn client_start_returns_runtime_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  client.model(runtime)
  |> should.equal(test_support.initial_model())
}

// =============================================================================
// DISPATCH
// =============================================================================

@target(javascript)
pub fn client_dispatch_multiple_messages_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let dispatch = client.dispatch(runtime)
  dispatch(Increment)
  dispatch(Increment)
  dispatch(Increment)

  client.model(runtime).count
  |> should.equal(3)
}

@target(javascript)
pub fn client_dispatch_set_name_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(SetName("Alice"))

  client.model(runtime).name
  |> should.equal("Alice")
}

@target(javascript)
pub fn client_dispatch_updates_model_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let dispatch = client.dispatch(runtime)
  dispatch(Increment)

  client.model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn client_update_that_crashes_is_logged_and_the_queue_continues_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let dispatch = client.dispatch(runtime)
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.MessageApplied(Noop, _) -> {
          client.update_model(runtime, with: fn(_) { panic as "update blew up" })
          dispatch(Increment)
        }
        _ -> Nil
      }
    })

  let logs = test_support.capture_logs(fn() { dispatch(Noop) })

  client.model(runtime).count |> should.equal(1)
  list.any(logs, string.contains(_, "update blew up")) |> should.be_true
  // the loop is free again, a later dispatch runs as usual
  dispatch(Increment)
  client.model(runtime).count |> should.equal(2)
}

// =============================================================================
// HYDRATE
// =============================================================================

@target(javascript)
pub fn client_hydrate_uses_embedded_snapshot_test() {
  test_support.reset_dom()
  // differs from the initial model, proves hydrate read the embed
  let server_rendered_model =
    test_support.Model(..test_support.initial_model(), count: 7, name: "Hi")
  let frame_bytes =
    transport.encode(
      transport.Snapshot(
        target: transport.Session,
        epoch: 0,
        sequence: 0,
        state: server_rendered_model,
      ),
      serialiser: test_support.custom_serialiser(),
    )
  test_support.inject_snapshot_script(bit_array.base64_encode(frame_bytes, True))

  let runtime = test_support.new_runtime()

  let model = client.model(runtime)
  model.count |> should.equal(7)
  model.name |> should.equal("Hi")
}

@target(javascript)
pub fn client_hydrate_ignores_user_content_carrying_the_snapshot_id_test() {
  test_support.reset_dom()
  let encode = fn(count) {
    transport.encode(
      transport.Snapshot(
        target: transport.Session,
        epoch: 0,
        sequence: 0,
        state: test_support.Model(..test_support.initial_model(), count:),
      ),
      serialiser: test_support.custom_serialiser(),
    )
    |> bit_array.base64_encode(True)
  }
  // earlier in the page, as rendered user content would be
  test_support.set_inner_html(
    "#app",
    "<pre id=\"lily-snapshot\">" <> encode(666) <> "</pre>",
  )
  test_support.inject_snapshot_script(encode(7))

  let runtime = test_support.new_runtime()

  client.model(runtime).count |> should.equal(7)
}

@target(javascript)
pub fn client_hydrate_keeps_a_script_closing_tag_in_the_model_test() {
  test_support.reset_dom()
  let hostile = "</script><img src=x onerror=alert(1)>"
  let embed =
    store.initial_snapshot(
      test_support.local_store(),
      model: test_support.Model(..test_support.initial_model(), name: hostile),
    )
  let assert Ok(payload) =
    embed
    |> string.split(">")
    |> list.drop(1)
    |> list.first
  test_support.inject_snapshot_script(string.replace(payload, "</script", ""))

  let runtime = test_support.new_runtime()

  client.model(runtime).name |> should.equal(hostile)
}

@target(javascript)
pub fn client_hydrate_falls_back_to_store_when_snapshot_missing_test() {
  test_support.reset_dom()
  // no lily-snapshot script, falls back to the initial model
  let runtime = test_support.new_runtime()

  let model = client.model(runtime)
  model.count |> should.equal(0)
  model.name |> should.equal("")
}

// =============================================================================
// INBOUND SESSION-UPDATE
// =============================================================================

@target(javascript)
pub fn client_session_update_applies_to_session_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()
  let #(handler, _sent) = test_support.connect_capturing(runtime)

  let frame =
    transport.encode(
      transport.SessionUpdate(sequence: 1, payload: Increment),
      serialiser: test_support.custom_serialiser(),
    )
  handler.received(frame)

  client.model(runtime).count |> should.equal(1)
}

// =============================================================================
// CONNECT, TRANSPORT INTEGRATION
// =============================================================================

@target(javascript)
pub fn client_dispatch_routed_to_a_topic_sends_topic_message_test() {
  // topic-routed messages go out as TopicMessage so the topic fans out
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = client.start(test_support.topic_store())
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.dispatch(runtime)(Increment)

  sent()
  |> should.equal([
    transport.TopicMessage(topic_id: "chat", payload: Increment),
  ])
}

@target(javascript)
pub fn client_dispatch_routed_to_a_family_member_sends_its_concrete_id_test() {
  // route names the concrete id, letting a `room:` family hit the right one
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = client.start(test_support.topic_store())
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.dispatch(runtime)(SetName("room:42"))

  sent()
  |> should.equal([
    transport.TopicMessage(topic_id: "room:42", payload: SetName("room:42")),
  ])
}

@target(javascript)
pub fn client_dispatch_routed_to_the_session_sends_session_message_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = client.start(test_support.topic_store())
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.dispatch(runtime)(test_support.IncrementSecondary)

  sent()
  |> should.equal([
    transport.SessionMessage(payload: test_support.IncrementSecondary),
  ])
}

@target(javascript)
pub fn client_dispatch_routed_locally_is_applied_but_never_sent_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = client.start(test_support.topic_store())
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.dispatch(runtime)(test_support.SetTab(test_support.TabB))

  sent()
  |> should.equal([])
  client.model(runtime).active_tab
  |> should.equal(test_support.TabB)
}

// =============================================================================
// SUBSCRIPTION DIFFING
// =============================================================================

@target(javascript)
pub fn client_open_resyncs_the_session_and_every_wanted_topic_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  client.update_model(runtime, with: wanting("chat,room:1"))
  let #(handler, sent) = test_support.connect_capturing(runtime)

  handler.opened()

  sent()
  |> should.equal([
    transport.Resync(cursors: [
      transport.Unknown(transport.Session),
      transport.Unknown(transport.Topic("chat")),
      transport.Unknown(transport.Topic("room:1")),
    ]),
  ])
}

@target(javascript)
pub fn client_connector_that_opens_inside_connect_still_resyncs_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  client.update_model(runtime, with: wanting("chat"))
  let sent: test_support.Ref(List(BitArray)) = test_support.new([])
  let connector =
    transport.connector(fn(handler: transport.ConnectorHandler) {
      // ready before connect returns, like a synchronous transport
      handler.opened()
      transport.Channel(
        send: fn(bytes) {
          test_support.set(sent, [bytes, ..test_support.get(sent)])
          Ok(Nil)
        },
        close: fn() { Nil },
      )
    })

  let _ = client.connect(runtime, with: connector)

  test_support.get(sent)
  |> list.map(fn(bytes) {
    let assert Ok(frame) =
      transport.decode(bytes, serialiser: test_support.custom_serialiser())
    frame
  })
  |> should.equal([
    transport.Resync(cursors: [
      transport.Unknown(transport.Session),
      transport.Unknown(transport.Topic("chat")),
    ]),
  ])

  // and the sync carries on from there
  client.update_model(runtime, with: wanting("chat,room:1"))
  test_support.get(sent) |> list.length |> should.equal(2)
}

@target(javascript)
pub fn client_protocol_mismatch_closes_for_good_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = client.start(test_support.topic_store())
  let events = test_support.new([])
  let _ =
    client.observe(runtime, fn(event, _model) {
      test_support.set(events, [event, ..test_support.get(events)])
    })
  let handler =
    test_support.new(
      transport.ConnectorHandler(
        received: fn(_) { Nil },
        opened: fn() { Nil },
        closed: fn() { Nil },
      ),
    )
  let sent: test_support.Ref(List(BitArray)) = test_support.new([])
  let closes = test_support.new(0)
  let connector =
    transport.connector(fn(connected) {
      test_support.set(handler, connected)
      transport.Channel(
        send: fn(bytes) {
          test_support.set(sent, [bytes, ..test_support.get(sent)])
          Ok(Nil)
        },
        close: fn() { test_support.set(closes, test_support.get(closes) + 1) },
      )
    })
  let _ = client.connect(runtime, with: connector)
  let handler = test_support.get(handler)
  let server = transport.protocol_version + 1

  handler.received(transport.encode(
    transport.Version(hash: "v2", protocol: server),
    serialiser: test_support.custom_serialiser(),
  ))

  test_support.get(closes) |> should.equal(1)
  let assert [client.Diagnostic(level: transport.Failure, ..), mismatch, ..] =
    test_support.get(events)
  mismatch
  |> should.equal(client.ProtocolMismatch(
    server:,
    client: transport.protocol_version,
  ))

  // a later open or dispatch sends nothing, frames may be misread
  handler.opened()
  client.dispatch(runtime)(Increment)
  test_support.get(sent) |> should.equal([])
}

@target(javascript)
pub fn client_open_with_no_subscriptions_resyncs_only_the_session_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  let #(handler, sent) = test_support.connect_capturing(runtime)

  handler.opened()

  sent()
  |> should.equal([
    transport.Resync(cursors: [transport.Unknown(transport.Session)]),
  ])
}

@target(javascript)
pub fn client_subscribes_when_the_model_starts_wanting_a_topic_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  let #(handler, sent) = test_support.connect_capturing(runtime)
  handler.opened()
  let _ = sent()

  client.update_model(runtime, with: wanting("chat"))

  sent()
  |> should.equal([transport.Subscribe(topic_id: "chat")])
}

@target(javascript)
pub fn client_unsubscribes_when_the_model_stops_wanting_a_topic_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  client.update_model(runtime, with: wanting("chat"))
  let #(handler, sent) = test_support.connect_capturing(runtime)
  handler.opened()
  let _ = sent()

  client.update_model(runtime, with: wanting(""))

  sent()
  |> should.equal([transport.Unsubscribe(topic_id: "chat")])
}

@target(javascript)
pub fn client_sends_only_the_difference_between_subscription_sets_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  client.update_model(runtime, with: wanting("chat,room:1"))
  let #(handler, sent) = test_support.connect_capturing(runtime)
  handler.opened()
  let _ = sent()

  client.update_model(runtime, with: wanting("room:1,room:2"))

  sent()
  |> list.sort(fn(left, right) {
    string.compare(frame_key(left), frame_key(right))
  })
  |> should.equal([
    transport.Subscribe(topic_id: "room:2"),
    transport.Unsubscribe(topic_id: "chat"),
  ])
}

@target(javascript)
pub fn client_sends_nothing_when_the_subscriptions_do_not_change_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  let #(handler, sent) = test_support.connect_capturing(runtime)
  handler.opened()
  client.update_model(runtime, with: wanting("chat"))
  let _ = sent()

  // different model, same wanted topics
  client.update_model(runtime, with: fn(model) {
    Model(..model, count: model.count + 1)
  })
  client.update_model(runtime, with: wanting("chat"))

  sent()
  |> should.equal([])
}

@target(javascript)
pub fn client_sends_no_subscription_frames_while_offline_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  let #(handler, sent) = test_support.connect_capturing(runtime)

  // never opened
  client.update_model(runtime, with: wanting("chat"))
  sent()
  |> should.equal([])

  // opened, then dropped
  handler.opened()
  let _ = sent()
  handler.closed()
  client.update_model(runtime, with: wanting("chat,room:1"))
  client.update_model(runtime, with: wanting(""))
  sent()
  |> should.equal([])
}

@target(javascript)
pub fn client_reconnect_names_the_state_a_topic_was_confirmed_at_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(_runtime, handler, sent) = chat_client()
  receive(
    handler,
    transport.Snapshot(
      target: transport.Topic("chat"),
      epoch: 7,
      sequence: 3,
      state: test_support.initial_model(),
    ),
  )
  receive(
    handler,
    transport.TopicUpdate(topic_id: "chat", sequence: 4, payload: Increment),
  )

  handler.closed()
  handler.opened()

  sent()
  |> should.equal([
    transport.Resync(cursors: [
      transport.Unknown(transport.Session),
      transport.Known(target: transport.Topic("chat"), epoch: 7, sequence: 4),
    ]),
  ])
}

@target(javascript)
pub fn client_reconnect_after_an_unanswered_edit_asks_for_a_snapshot_test() {
  // the edit may or may not have landed, the slice can't vouch for itself
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  receive(handler, wire_support.chat_snapshot(test_support.initial_model()))
  client.dispatch(runtime)(Increment)
  let _ = sent()

  handler.closed()
  handler.opened()

  sent()
  |> list.first
  |> should.equal(
    Ok(
      transport.Resync(cursors: [
        transport.Unknown(transport.Session),
        transport.Unknown(transport.Topic("chat")),
      ]),
    ),
  )
}

@target(javascript)
pub fn client_a_crossed_update_resyncs_without_a_cursor_test() {
  // another client's update landed under our edit, the slice is out of step
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  receive(handler, wire_support.chat_snapshot(test_support.initial_model()))
  client.dispatch(runtime)(Increment)
  receive(
    handler,
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  )
  receive(handler, transport.Acknowledge(transport.Topic("chat"), 2))

  sent()
  |> list.last
  |> should.equal(
    Ok(transport.Resync(cursors: [transport.Unknown(transport.Topic("chat"))])),
  )
}

@target(javascript)
pub fn client_unchanged_keeps_the_slice_and_says_so_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  let unchanged = test_support.new([])
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.SnapshotUnchanged(target:) ->
          test_support.set(unchanged, [target, ..test_support.get(unchanged)])
        _ -> Nil
      }
    })
  receive(
    handler,
    wire_support.chat_snapshot(Model(..test_support.initial_model(), count: 2)),
  )
  handler.closed()
  handler.opened()
  let _ = sent()

  receive(handler, transport.Unchanged(transport.Topic("chat")))

  client.model(runtime).count |> should.equal(2)
  test_support.get(unchanged)
  |> should.equal([transport.Topic("chat")])
  // and edits go on as before
  client.dispatch(runtime)(Increment)
  sent()
  |> should.equal([transport.TopicMessage(topic_id: "chat", payload: Increment)])
}

@target(javascript)
pub fn client_reconnect_resyncs_everything_currently_wanted_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  let #(handler, sent) = test_support.connect_capturing(runtime)
  client.update_model(runtime, with: wanting("chat"))
  handler.opened()
  let _ = sent()
  handler.closed()
  // changed while the connection was down
  client.update_model(runtime, with: wanting("room:7"))

  handler.opened()

  sent()
  |> should.equal([
    transport.Resync(cursors: [
      transport.Unknown(transport.Session),
      transport.Unknown(transport.Topic("room:7")),
    ]),
  ])
}

@target(javascript)
pub fn client_does_not_resubscribe_after_a_resync_covers_the_topic_test() {
  // the resync on open already names it, the diff adds nothing
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  client.update_model(runtime, with: wanting("chat"))
  let #(handler, sent) = test_support.connect_capturing(runtime)

  handler.opened()

  list.any(sent(), fn(frame) {
    case frame {
      transport.Subscribe(..) -> True
      _ -> False
    }
  })
  |> should.be_false
}

// =============================================================================
// UNCONFIRMED EDITS
// =============================================================================

@target(javascript)
pub fn client_snapshot_keeps_an_unconfirmed_message_applied_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, _sent) = chat_client()
  client.dispatch(runtime)(Increment)

  // the server hasn't applied it yet
  receive(handler, wire_support.chat_snapshot(test_support.initial_model()))

  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn client_snapshot_does_not_replay_an_acknowledged_message_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, _sent) = chat_client()
  client.dispatch(runtime)(Increment)
  receive(handler, transport.Acknowledge(transport.Topic("chat"), 1))

  receive(
    handler,
    wire_support.chat_snapshot(Model(..test_support.initial_model(), count: 1)),
  )

  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn client_snapshot_replays_only_its_own_target_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, _sent) = chat_client()
  client.dispatch(runtime)(Increment)

  // the session's snapshot leaves the edit pending on chat out
  receive(
    handler,
    transport.Snapshot(
      target: transport.Session,
      epoch: 0,
      sequence: 0,
      state: test_support.initial_model(),
    ),
  )

  client.model(runtime).count |> should.equal(0)
}

@target(javascript)
pub fn client_ignores_a_snapshot_for_a_topic_it_left_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, _sent) = chat_client()
  client.dispatch(runtime)(Increment)

  receive(
    handler,
    transport.Snapshot(
      target: transport.Topic("room:1"),
      epoch: 0,
      sequence: 0,
      state: test_support.initial_model(),
    ),
  )

  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn client_remote_update_under_a_pending_message_asks_for_a_snapshot_test() {
  // the server applied b before a, this client applied a before b
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  client.dispatch(runtime)(Claim("a"))
  let _ = sent()

  receive(handler, transport.TopicUpdate("chat", 1, Claim("b")))
  client.model(runtime).name |> should.equal("a")
  sent() |> should.equal([])
  receive(handler, transport.Acknowledge(transport.Topic("chat"), 2))

  sent()
  |> should.equal([
    transport.Resync(cursors: [transport.Unknown(transport.Topic("chat"))]),
  ])
  receive(
    handler,
    wire_support.chat_snapshot(Model(..test_support.initial_model(), name: "b")),
  )
  client.model(runtime).name |> should.equal("b")
}

@target(javascript)
pub fn client_remote_update_with_nothing_pending_asks_for_nothing_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  client.dispatch(runtime)(Claim("a"))
  receive(handler, transport.Acknowledge(transport.Topic("chat"), 1))
  let _ = sent()

  receive(handler, transport.TopicUpdate("chat", 2, Claim("b")))

  sent() |> should.equal([])
  client.model(runtime).name |> should.equal("a")
}

@target(javascript)
pub fn client_remote_update_waits_for_every_pending_message_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Increment)
  receive(handler, transport.TopicUpdate("chat", 1, Increment))
  let _ = sent()

  receive(handler, transport.Acknowledge(transport.Topic("chat"), 2))
  sent() |> should.equal([])
  receive(handler, transport.Acknowledge(transport.Topic("chat"), 3))

  sent()
  |> should.equal([
    transport.Resync(cursors: [transport.Unknown(transport.Topic("chat"))]),
  ])
}

@target(javascript)
pub fn client_dropped_message_rolls_back_through_a_snapshot_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  client.dispatch(runtime)(Increment)
  let _ = sent()

  receive(handler, transport.Dropped(transport.Topic("chat")))

  sent()
  |> should.equal([
    transport.Resync(cursors: [transport.Unknown(transport.Topic("chat"))]),
  ])
  receive(handler, wire_support.chat_snapshot(test_support.initial_model()))
  client.model(runtime).count |> should.equal(0)
}

@target(javascript)
pub fn client_dropped_on_a_topic_not_joined_asks_for_nothing_test() {
  // a resync would join it
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  client.dispatch(runtime)(SetName("room:1"))
  let _ = sent()

  receive(handler, transport.Dropped(transport.Topic("room:1")))

  sent() |> should.equal([])
}

@target(javascript)
pub fn client_a_rejected_topic_is_cleared_by_a_snapshot_test() {
  // a stopped topic came back up and the server rejoined this client
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  receive(
    handler,
    transport.Rejected(topic_id: "chat", reason: transport.NotFound),
  )
  client.dispatch(runtime)(Increment)
  receive(handler, transport.Dropped(transport.Topic("chat")))
  // refused, a resync would join it
  sent()
  |> should.equal([transport.TopicMessage(topic_id: "chat", payload: Increment)])

  receive(handler, wire_support.chat_snapshot(test_support.initial_model()))
  client.model(runtime).count |> should.equal(0)
  client.dispatch(runtime)(Increment)
  receive(handler, transport.Acknowledge(transport.Topic("chat"), 1))
  client.dispatch(runtime)(Increment)
  receive(handler, transport.Dropped(transport.Topic("chat")))

  sent()
  |> should.equal([
    transport.TopicMessage(topic_id: "chat", payload: Increment),
    transport.TopicMessage(topic_id: "chat", payload: Increment),
    transport.Resync(cursors: [transport.Unknown(transport.Topic("chat"))]),
  ])
  receive(
    handler,
    wire_support.chat_snapshot(Model(..test_support.initial_model(), count: 1)),
  )
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn client_dropped_while_closed_waits_for_the_reconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, sent) = chat_client()
  client.dispatch(runtime)(Increment)
  handler.closed()
  receive(handler, transport.Dropped(transport.Topic("chat")))
  client.dispatch(runtime)(Increment)
  // nothing asked for while closed
  sent()
  |> should.equal([
    transport.TopicMessage(topic_id: "chat", payload: Increment),
    transport.TopicMessage(topic_id: "chat", payload: Increment),
  ])

  handler.opened()

  sent()
  |> should.equal([
    transport.Resync(cursors: [
      transport.Unknown(transport.Session),
      transport.Unknown(transport.Topic("chat")),
    ]),
  ])
}

@target(javascript)
pub fn client_reconnect_snapshot_does_not_replay_a_delivered_message_test() {
  // the old connection's fate is unknown, the new snapshot decides
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, _sent) = chat_client()
  client.dispatch(runtime)(Increment)
  handler.closed()

  handler.opened()
  receive(
    handler,
    wire_support.chat_snapshot(Model(..test_support.initial_model(), count: 1)),
  )

  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn client_snapshot_does_not_fire_message_applied_for_replayed_messages_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let #(runtime, handler, _sent) = chat_client()
  client.dispatch(runtime)(Increment)
  let applied = test_support.new(0)
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.MessageApplied(..) ->
          test_support.set(applied, test_support.get(applied) + 1)
        _ -> Nil
      }
    })

  receive(handler, wire_support.chat_snapshot(test_support.initial_model()))

  test_support.get(applied) |> should.equal(0)
}

// =============================================================================
// WIRE FORMAT
// =============================================================================

@target(javascript)
pub fn client_by_host_store_writes_json_on_localhost_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = client.start(test_support.automatic_topic_store())
  let #(handler, sent) = test_support.connect_raw(runtime)

  handler.opened()

  sent()
  |> list.map(transport.frame_format(
    _,
    serialiser: test_support.automatic_serialiser(transport.Json),
  ))
  |> should.equal([Ok(transport.Json)])
}

@target(javascript)
pub fn client_forced_message_pack_writes_message_pack_on_localhost_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime =
    client.start(test_support.automatic_session_store(transport.MessagePack))
  let #(handler, sent) = test_support.connect_raw(runtime)

  handler.opened()

  sent()
  |> should.equal([
    transport.encode(
      transport.Resync(cursors: [transport.Unknown(transport.Session)]),
      serialiser: test_support.message_pack_serialiser(),
    ),
  ])
}

@target(javascript)
pub fn client_json_store_reads_message_pack_frames_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  test_support.register_fixtures()
  let runtime =
    client.start(test_support.automatic_session_store(transport.Json))
  let #(handler, _sent) = test_support.connect_raw(runtime)
  let assigned = test_support.new("")
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.ClientIdAssigned(client_id:) ->
          test_support.set(assigned, client_id)
        _ -> Nil
      }
    })
  let message_pack = test_support.message_pack_serialiser()

  handler.received(transport.encode(
    transport.Connected(client_id: "c1"),
    serialiser: message_pack,
  ))
  handler.received(transport.encode(
    transport.SessionUpdate(sequence: 1, payload: Increment),
    serialiser: message_pack,
  ))

  test_support.get(assigned) |> should.equal("c1")
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn client_json_store_hydrates_from_a_message_pack_snapshot_test() {
  test_support.reset_dom()
  test_support.register_fixtures()
  let server_rendered_model =
    test_support.Model(..test_support.initial_model(), count: 7, name: "Hi")
  let frame_bytes =
    transport.encode(
      transport.Snapshot(
        target: transport.Session,
        epoch: 0,
        sequence: 0,
        state: server_rendered_model,
      ),
      serialiser: test_support.message_pack_serialiser(),
    )
  test_support.inject_snapshot_script(bit_array.base64_encode(frame_bytes, True))

  let runtime =
    client.start(test_support.automatic_session_store(transport.Json))

  client.model(runtime) |> should.equal(server_rendered_model)
}

@target(javascript)
pub fn client_json_store_replays_a_message_pack_offline_queue_test() {
  test_support.reset_dom()
  test_support.register_fixtures()
  let frame =
    transport.encode(
      transport.SessionMessage(payload: Increment),
      serialiser: test_support.message_pack_serialiser(),
    )
  test_support.write_session_storage(
    "test_queue_cross_format",
    "[\"" <> bit_array.base64_encode(frame, True) <> "\"]",
  )
  let runtime =
    client.start(test_support.automatic_session_store(transport.Json))
  let connector =
    transport.connector(fn(_handler) {
      transport.Channel(send: fn(_) { Error(Nil) }, close: fn() { Nil })
    })
    |> transport.with_offline_queue(storage_key: "test_queue_cross_format")

  let _ = client.connect(runtime, with: connector)

  client.model(runtime).count |> should.equal(1)
}
