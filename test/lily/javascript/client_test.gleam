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
  type Message, type Model, Increment, Model, Noop, SetName,
}
@target(javascript)
import lily/transport

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
  |> should.equal([transport.TopicMessage(topic_id: "chat", payload: Increment)])
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
      transport.Session,
      transport.Topic("chat"),
      transport.Topic("room:1"),
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
    transport.connector(fn(handler: transport.Handler) {
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
    transport.Resync(cursors: [transport.Session, transport.Topic("chat")]),
  ])

  // and the sync carries on from there
  client.update_model(runtime, with: wanting("chat,room:1"))
  test_support.get(sent) |> list.length |> should.equal(2)
}

@target(javascript)
pub fn client_open_with_no_subscriptions_resyncs_only_the_session_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = subscribing_runtime()
  let #(handler, sent) = test_support.connect_capturing(runtime)

  handler.opened()

  sent()
  |> should.equal([transport.Resync(cursors: [transport.Session])])
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
    transport.Resync(cursors: [transport.Session, transport.Topic("room:7")]),
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
      transport.Resync(cursors: [transport.Session]),
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
