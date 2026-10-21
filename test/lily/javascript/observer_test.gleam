// client.observe, client.model and client.update_model

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/list

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/client.{type ClientEvent}
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{type Message, type Model, Decrement, Increment}
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
type Events =
  test_support.Ref(List(ClientEvent(Model, Message)))

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message, store.Synced) {
  test_support.new_synced_runtime()
}

@target(javascript)
fn record(runtime: client.Runtime(Model, Message, store.Synced)) -> Events {
  let events = test_support.new([])
  let _ =
    client.observe(runtime, fn(event, _model) {
      test_support.set(events, [event, ..test_support.get(events)])
    })
  events
}

@target(javascript)
fn seen(events: Events) -> List(ClientEvent(Model, Message)) {
  list.reverse(test_support.get(events))
}

@target(javascript)
fn frame(protocol: transport.Protocol(Model, Message)) -> BitArray {
  transport.encode(protocol, serialiser: test_support.custom_serialiser())
}

// =============================================================================
// OBSERVERS
// =============================================================================

@target(javascript)
pub fn observer_observers_add_up_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let first = record(runtime)
  let second = record(runtime)

  client.dispatch(runtime)(Increment)

  seen(first)
  |> should.equal([client.MessageApplied(Increment, client.Dispatched)])
  seen(second)
  |> should.equal([client.MessageApplied(Increment, client.Dispatched)])
}

@target(javascript)
pub fn observer_a_crashing_observer_does_not_stop_the_others_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let _ = client.observe(runtime, fn(_event, _model) { panic as "observer" })
  let events = record(runtime)

  client.dispatch(runtime)(Increment)

  seen(events)
  |> should.equal([client.MessageApplied(Increment, client.Dispatched)])
}

@target(javascript)
pub fn observer_a_dispatch_from_an_observer_runs_after_the_current_event_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let dispatch = client.dispatch(runtime)
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.MessageApplied(Increment, client.Dispatched) ->
          dispatch(Decrement)
        _ -> Nil
      }
    })
  let events = record(runtime)

  dispatch(Increment)

  seen(events)
  |> should.equal([
    client.MessageApplied(Increment, client.Dispatched),
    client.MessageApplied(Decrement, client.Dispatched),
  ])
  client.model(runtime).count |> should.equal(0)
}

// =============================================================================
// MODEL
// =============================================================================

@target(javascript)
pub fn observer_model_reads_the_current_model_test() {
  test_support.reset_dom()
  let runtime = new_runtime()

  client.dispatch(runtime)(Increment)

  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn observer_update_model_changes_the_model_and_sends_nothing_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let events = record(runtime)
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.update_model(runtime, with: fn(model) {
    test_support.Model(..model, name: "changed")
  })

  client.model(runtime).name |> should.equal("changed")
  seen(events) |> should.equal([client.ModelUpdated])
  sent() |> should.equal([])
}

// =============================================================================
// LOCAL MESSAGES
// =============================================================================

@target(javascript)
pub fn observer_a_message_routed_locally_is_not_sent_test() {
  test_support.reset_dom()
  let runtime =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.sync_with(
      route: fn(message) {
        case message {
          Increment -> store.Session
          _ -> store.Local
        }
      },
      serialiser: test_support.custom_serialiser(),
    )
    |> client.start
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.dispatch(runtime)(Decrement)
  sent() |> should.equal([])
  client.model(runtime).count |> should.equal(-1)

  client.dispatch(runtime)(Increment)
  sent() |> list.length |> should.equal(1)
}

// =============================================================================
// EVENTS
// =============================================================================

@target(javascript)
pub fn observer_a_server_message_is_applied_as_remote_and_not_sent_back_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let events = record(runtime)
  let #(handler, sent) = test_support.connect_capturing(runtime)

  handler.received(frame(transport.SessionUpdate(1, Increment)))

  seen(events)
  |> should.equal([client.MessageApplied(Increment, client.Received)])
  client.model(runtime).count |> should.equal(1)
  sent() |> should.equal([])
}

@target(javascript)
pub fn observer_the_transport_opening_and_closing_are_events_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let events = record(runtime)
  let #(handler, _sent) = test_support.connect_capturing(runtime)

  handler.opened()
  handler.closed()

  seen(events)
  |> should.equal([client.ConnectionOpened, client.ConnectionClosed])
}

@target(javascript)
pub fn observer_connected_version_and_rejected_frames_are_events_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let events = record(runtime)
  let #(handler, _sent) = test_support.connect_capturing(runtime)

  handler.received(frame(transport.Connected(client_id: "abc")))
  handler.received(
    frame(transport.Version(hash: "v1", protocol: transport.protocol_version)),
  )
  handler.received(
    frame(transport.Rejected(topic_id: "t", reason: transport.AccessDenied)),
  )

  seen(events)
  |> should.equal([
    client.ClientIdAssigned("abc"),
    client.VersionAnnounced("v1"),
    client.SubscriptionRejected("t", transport.AccessDenied),
  ])
}

@target(javascript)
pub fn observer_a_snapshot_reports_the_model_before_the_merge_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let events = record(runtime)
  let #(handler, _sent) = test_support.connect_capturing(runtime)
  let incoming = test_support.Model(..test_support.initial_model(), count: 9)

  handler.received(
    frame(transport.Snapshot(
      target: transport.Session,
      sequence: 4,
      state: incoming,
    )),
  )

  seen(events)
  |> should.equal([
    client.SnapshotApplied(
      target: transport.Session,
      previous: test_support.initial_model(),
    ),
  ])
  client.model(runtime).count |> should.equal(9)
}

@target(javascript)
pub fn observer_an_undecodable_frame_is_a_diagnostic_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let events = record(runtime)
  let #(handler, _sent) = test_support.connect_capturing(runtime)

  handler.received(<<"not a frame":utf8>>)

  seen(events)
  |> should.equal([
    client.Diagnostic(
      level: transport.Warning,
      message: "dropped a frame that failed to decode",
    ),
  ])
}

@target(javascript)
pub fn observer_a_session_route_without_store_session_warns_once_test() {
  test_support.reset_dom()
  let runtime =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.sync_with(
      route: fn(_) { store.Session },
      serialiser: test_support.custom_serialiser(),
    )
    |> client.start
  let #(_handler, _sent) = test_support.connect_capturing(runtime)
  let events = record(runtime)

  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Decrement)

  seen(events)
  |> list.filter(fn(event) {
    case event {
      client.Diagnostic(..) -> True
      _ -> False
    }
  })
  |> list.length
  |> should.equal(1)
}

@target(javascript)
pub fn observer_a_session_route_with_store_session_does_not_warn_test() {
  test_support.reset_dom()
  let runtime = client.start(test_support.session_store())
  let #(_handler, _sent) = test_support.connect_capturing(runtime)
  let events = record(runtime)

  client.dispatch(runtime)(Increment)

  seen(events)
  |> list.any(fn(event) {
    case event {
      client.Diagnostic(..) -> True
      _ -> False
    }
  })
  |> should.be_false
}

// =============================================================================
// OBSERVERS ADD UP
// =============================================================================

@target(javascript)
pub fn observer_two_message_observers_both_fire_test() {
  test_support.reset_dom()
  let runtime = new_runtime()
  let calls = test_support.new(0)
  let count = fn(event, _model) {
    case event {
      client.MessageApplied(..) ->
        test_support.set(calls, test_support.get(calls) + 1)
      _ -> Nil
    }
  }
  let _ =
    runtime
    |> client.observe(count)
    |> client.observe(count)

  client.dispatch(runtime)(Increment)

  test_support.get(calls) |> should.equal(2)
}
