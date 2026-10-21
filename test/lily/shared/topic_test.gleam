// topics, started on first use, via wire_support on both targets
// topics are separate processes on Erlang, frame order pinned per topic only

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/string

import gleeunit/should

import lily/server
import lily/store
import lily/test_support.{Decrement, Increment, SetName}
import lily/transport
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

// `room:1` up to `room:count`
fn room_cursors(count: Int) -> List(transport.SyncTarget) {
  int.range(from: 1, to: count + 1, with: [], run: fn(cursors, n) {
    [transport.Topic("room:" <> int.to_string(n)), ..cursors]
  })
  |> list.reverse
}

// subscribed to `chat`, its snapshot drained
fn joined(
  app: server.Server(test_support.Model, test_support.Message),
  client_id: String,
) -> #(
  server.Connection(test_support.Model, test_support.Message),
  fn() -> List(wire_support.Frame),
) {
  let #(connection, frames) = wire_support.open(app, client_id)
  wire_support.subscribe(connection, "chat")
  let _ = frames()
  #(connection, frames)
}

fn is_diagnostic(event: server.ServerEvent(model, message)) -> Bool {
  case event {
    server.Diagnostic(..) -> True
    _ -> False
  }
}

fn is_subscribed(event: server.ServerEvent(model, message)) -> Bool {
  case event {
    server.Subscribed(..) -> True
    _ -> False
  }
}

fn assert_evicted(
  app: server.Server(test_support.Model, test_support.Message),
  connection: server.Connection(test_support.Model, test_support.Message),
  frames: fn() -> List(wire_support.Frame),
) -> Nil {
  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
  wire_support.topic_message(connection, "chat", Increment)
  frames()
  |> should.equal([transport.Dropped(target: transport.Topic("chat"))])
}

fn denying_server() -> server.Server(test_support.Model, test_support.Message) {
  test_support.new_topic_server_with_access(
    store.Allow(fn(_client_id, _topic_id, _session) { False }),
  )
}

// allows a session until its first `IncrementSecondary`
fn revocable_server() -> server.Server(test_support.Model, test_support.Message) {
  test_support.new_topic_server_with_access(
    store.Allow(fn(_client_id, _topic_id, session: test_support.Model) {
      session.secondary_count == 0
    }),
  )
}

fn switched_server(
  allowed: test_support.Shared(Bool),
) -> server.Server(test_support.Model, test_support.Message) {
  test_support.new_topic_server_with_access(
    store.Allow(fn(_client_id, _topic_id, _session) {
      test_support.get_shared(allowed)
    }),
  )
}

// =============================================================================
// ON-DEMAND START
// =============================================================================

pub fn topic_is_not_running_until_used_test() {
  let app = test_support.new_topic_server()

  test_support.subscriber_count(app, "chat")
  |> should.equal(-1)
  test_support.topic_watched(app, "chat")
  |> should.equal(option.None)
}

pub fn topic_starts_on_first_subscribe_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.settle(app)

  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn topic_starts_on_first_server_dispatch_test() {
  let app = test_support.new_topic_server()

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)

  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
  test_support.topic_watched(app, "chat")
  |> option.is_some
  |> should.be_true
}

pub fn topic_family_prefix_starts_one_topic_per_id_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  wire_support.settle(app)

  test_support.subscriber_count(app, "room:1")
  |> should.equal(1)
  test_support.subscriber_count(app, "room:2")
  |> should.equal(1)
}

pub fn topic_dispatch_to_an_undeclared_topic_is_dropped_with_a_diagnostic_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)

  server.dispatch_topic(app, topic_id: "nowhere", message: Increment)

  events(app)
  |> list.any(is_diagnostic)
  |> should.be_true
  test_support.subscriber_count(app, "nowhere")
  |> should.equal(-1)
}

// =============================================================================
// DISPATCH
// =============================================================================

pub fn topic_server_dispatch_emits_topic_update_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  server.dispatch_topic(app, topic_id: "chat", message: Increment)

  frames()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

pub fn topic_server_dispatch_increments_sequence_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  server.dispatch_topic(app, topic_id: "chat", message: Decrement)

  frames()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
    transport.TopicUpdate(topic_id: "chat", sequence: 2, payload: Decrement),
  ])
}

pub fn topic_client_message_acknowledges_the_sender_and_updates_the_rest_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames1) = wire_support.open(app, "c1")
  let #(c2, frames2) = wire_support.open(app, "c2")
  wire_support.subscribe(c1, "chat")
  wire_support.subscribe(c2, "chat")
  let _ = frames1()
  let _ = frames2()

  wire_support.topic_message(c1, "chat", Increment)

  // sender gets only an Acknowledge, not its own update
  frames1()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
  ])
  frames2()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

pub fn topic_two_clients_converge_in_the_order_the_topic_applied_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames1) = wire_support.open(app, "c1")
  let #(c2, frames2) = wire_support.open(app, "c2")
  wire_support.subscribe(c1, "chat")
  wire_support.subscribe(c2, "chat")
  let _ = frames1()
  let _ = frames2()

  wire_support.topic_message(c1, "chat", Increment)
  wire_support.topic_message(c2, "chat", Increment)

  // each gets its own ack and the other's update
  frames1()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
    transport.TopicUpdate(topic_id: "chat", sequence: 2, payload: Increment),
  ])
  frames2()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 2),
  ])
}

pub fn topic_each_keeps_its_own_sequence_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  let _ = frames()

  server.dispatch_topic(app, topic_id: "room:1", message: SetName("room:1"))
  server.dispatch_topic(app, topic_id: "room:1", message: SetName("room:1"))
  server.dispatch_topic(app, topic_id: "room:2", message: SetName("room:2"))

  let received = frames()
  received
  |> list.filter(fn(frame) {
    case frame {
      transport.TopicUpdate(topic_id: "room:1", ..) -> True
      _ -> False
    }
  })
  |> should.equal([
    transport.TopicUpdate(
      topic_id: "room:1",
      sequence: 1,
      payload: SetName("room:1"),
    ),
    transport.TopicUpdate(
      topic_id: "room:1",
      sequence: 2,
      payload: SetName("room:1"),
    ),
  ])
  received
  |> list.contains(transport.TopicUpdate(
    topic_id: "room:2",
    sequence: 1,
    payload: SetName("room:2"),
  ))
  |> should.be_true
}

pub fn topic_applies_the_full_update_to_its_own_model_test() {
  // snapshot holds the whole model, letting a late joiner see what was applied
  let app = test_support.new_topic_server()
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  case frames() {
    [transport.Snapshot(target: transport.Topic("chat"), sequence: 2, state:)] ->
      state.count
      |> should.equal(2)
    _ -> should.fail()
  }
}

pub fn topic_crashing_update_drops_the_message_test() {
  // a crashing update must not take the topic down
  let crashing =
    store.new(init: test_support.initial_model(), update: fn(model, message) {
      case message {
        Decrement -> panic as "update blew up"
        _ -> test_support.update(model, message)
      }
    })
    |> store.sync_with(
      route: test_support.topic_route,
      serialiser: test_support.custom_serialiser(),
    )
    |> store.topic(
      id: "chat",
      get: fn(model) { model },
      set: fn(_, model) { model },
      access: store.Open,
    )
  let app =
    test_support.start_server(server.new(crashing, origins: server.AnyOrigin))
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  server.dispatch_topic(app, topic_id: "chat", message: Decrement)

  frames()
  |> should.equal([])
  // same topic, still serving, sequence unchanged
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  frames()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

// =============================================================================
// SUBSCRIBE WITH SNAPSHOT
// =============================================================================

pub fn topic_subscribe_sends_snapshot_to_new_subscriber_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

pub fn topic_snapshot_arrives_before_any_update_test() {
  // snapshot first, or the next update has nothing to build on
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  server.dispatch_topic(app, topic_id: "chat", message: Increment)

  case frames() {
    [transport.Snapshot(..), transport.TopicUpdate(sequence: 1, ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn topic_subscribe_to_unknown_topic_sends_rejected_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "missing")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "missing", reason: transport.NotFound),
  ])
  test_support.subscriber_count(app, "missing")
  |> should.equal(-1)
}

pub fn topic_subscribing_twice_sends_a_second_snapshot_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.subscribe(c1, "chat")

  frames()
  |> list.filter(wire_support.is_snapshot)
  |> list.length
  |> should.equal(2)
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

// =============================================================================
// ACCESS
// =============================================================================

pub fn topic_allow_false_sends_rejected_test() {
  let app = denying_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  test_support.subscriber_count(app, "chat")
  |> should.equal(-1)
}

pub fn topic_allow_true_admits_test() {
  let app =
    test_support.new_topic_server_with_access(
      store.Allow(fn(_client_id, _topic_id, _session) { True }),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn topic_allow_sees_client_id_topic_id_and_session_test() {
  let #(record, seen) = wire_support.recorder()
  let app =
    test_support.new_topic_server_with_access(
      store.Allow(fn(client_id, topic_id, session: test_support.Model) {
        record(#(client_id, topic_id, session.secondary_count))
        True
      }),
    )
  let #(c1, _frames) =
    wire_support.open_seeded(app, "c1", [test_support.IncrementSecondary])

  wire_support.subscribe(c1, "room:9")
  wire_support.settle(app)

  seen()
  |> should.equal([#("c1", "room:9", 1)])
}

pub fn topic_allow_can_decide_from_the_session_model_test() {
  let app =
    test_support.new_topic_server_with_access(
      store.Allow(fn(_client_id, _topic_id, session: test_support.Model) {
        session.secondary_count > 0
      }),
    )
  let #(guest, guest_frames) = wire_support.open(app, "guest")
  let #(member, member_frames) =
    wire_support.open_seeded(app, "member", [test_support.IncrementSecondary])

  wire_support.subscribe(guest, "chat")
  wire_support.subscribe(member, "chat")

  guest_frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  case member_frames() {
    [transport.Snapshot(..)] -> Nil
    _ -> should.fail()
  }
}

pub fn topic_crashing_allow_predicate_denies_test() {
  // fails closed, a crashing rule refuses
  let app =
    test_support.new_topic_server_with_access(
      store.Allow(fn(_client_id, _topic_id, _session) {
        panic as "predicate blew up"
      }),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  test_support.client_count(app)
  |> should.equal(1)
}

pub fn topic_each_declared_prefix_has_its_own_access_rule_test() {
  let app =
    test_support.start_server(server.new(
      test_support.topic_store_with([
        #("chat", store.Open),
        #("room:", store.Allow(fn(_, _, _) { False })),
      ]),
      origins: server.AnyOrigin,
    ))
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.subscribe(c1, "room:1")

  let received = frames()
  list.any(received, wire_support.is_snapshot)
  |> should.be_true
  list.contains(
    received,
    transport.Rejected(topic_id: "room:1", reason: transport.AccessDenied),
  )
  |> should.be_true
}

pub fn topic_message_from_non_subscriber_is_dropped_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames1) = wire_support.open(app, "c1")
  let #(c2, frames2) = wire_support.open(app, "c2")
  wire_support.subscribe(c1, "chat")
  let _ = frames1()

  // c2 never subscribed, its write is dropped, not applied or fanned out
  wire_support.topic_message(c2, "chat", Increment)

  frames1()
  |> should.equal([])
  frames2()
  |> should.equal([transport.Dropped(target: transport.Topic("chat"))])
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  frames1()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

pub fn topic_server_dispatch_is_not_gated_by_access_test() {
  // access gates clients only, a server dispatch is trusted
  let app = denying_server()

  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  wire_support.settle(app)

  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

// =============================================================================
// ACCESS RECHECK
// =============================================================================

pub fn topic_access_is_rechecked_after_a_session_message_test() {
  let app = revocable_server()
  let #(c1, frames) = joined(app, "c1")

  wire_support.session_message(c1, test_support.IncrementSecondary)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  assert_evicted(app, c1, frames)
}

pub fn topic_access_is_rechecked_after_dispatch_to_test() {
  let app = revocable_server()
  let #(c1, frames) = joined(app, "c1")

  server.dispatch_to(
    app,
    client_id: "c1",
    message: test_support.IncrementSecondary,
  )

  frames()
  |> should.equal([
    transport.SessionUpdate(
      sequence: 1,
      payload: test_support.IncrementSecondary,
    ),
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  assert_evicted(app, c1, frames)
}

pub fn topic_resync_of_a_joined_topic_rechecks_access_test() {
  let allowed = test_support.new_shared(True)
  let app = switched_server(allowed)
  let #(c1, frames) = joined(app, "c1")
  test_support.set_shared(allowed, False)

  wire_support.resync_topic(c1, "chat")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  assert_evicted(app, c1, frames)
}

pub fn topic_recheck_access_evicts_after_outside_state_changes_test() {
  let allowed = test_support.new_shared(True)
  let app = switched_server(allowed)
  let #(c1, frames) = joined(app, "c1")

  test_support.set_shared(allowed, False)
  server.recheck_access(app, client_id: "c1")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
  assert_evicted(app, c1, frames)
}

pub fn topic_recheck_access_keeps_a_permitted_topic_test() {
  let allowed = test_support.new_shared(True)
  let app = switched_server(allowed)
  let #(_c1, frames) = joined(app, "c1")

  server.recheck_access(app, client_id: "c1")

  frames()
  |> should.equal([])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn topic_pending_admission_revoked_before_it_lands_never_joins_test() {
  // the rule revokes itself mid-subscribe, landing ahead of the admission
  let server_ref = test_support.new_shared(option.None)
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.topic_store_with([
        #(
          "chat",
          store.Allow(fn(client_id, _topic_id, session: test_support.Model) {
            case session.secondary_count, test_support.get_shared(server_ref) {
              0, option.Some(app) -> {
                server.dispatch_to(
                  app,
                  client_id:,
                  message: test_support.IncrementSecondary,
                )
                True
              }
              _, _ -> False
            }
          }),
        ),
      ]),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  test_support.set_shared(server_ref, option.Some(app))
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  frames()
  |> list.contains(transport.Rejected(
    topic_id: "chat",
    reason: transport.AccessDenied,
  ))
  |> should.be_true
  events(app)
  |> list.any(is_subscribed)
  |> should.be_false
  assert_evicted(app, c1, frames)
}

// =============================================================================
// LIMITS
// =============================================================================

pub fn topic_subscription_cap_rejects_until_one_is_left_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.max_subscriptions(per_client: 2),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  let _ = frames()

  wire_support.subscribe(c1, "room:3")
  frames()
  |> should.equal([
    transport.Rejected(topic_id: "room:3", reason: transport.OverLimit),
  ])
  test_support.subscriber_count(app, "room:3")
  |> should.equal(-1)

  wire_support.unsubscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:3")
  frames()
  |> list.all(wire_support.is_snapshot)
  |> should.be_true
  test_support.subscriber_count(app, "room:3")
  |> should.equal(1)
}

pub fn topic_subscription_cap_allows_a_repeat_subscribe_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.max_subscriptions(per_client: 1),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")

  wire_support.subscribe(c1, "chat")

  frames()
  |> list.all(wire_support.is_snapshot)
  |> should.be_true
}

pub fn topic_id_over_the_length_cap_is_rejected_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.max_topic_id_length(bytes: 8),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "room:1234")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "room:1234", reason: transport.OverLimit),
  ])
  test_support.subscriber_count(app, "room:1234")
  |> should.equal(-1)
}

pub fn topic_id_length_cap_defaults_to_256_bytes_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  let longest = "room:" <> string.repeat("x", 251)
  let too_long = longest <> "x"

  wire_support.subscribe(c1, longest)
  wire_support.subscribe(c1, too_long)

  let received = frames()
  list.count(received, wire_support.is_snapshot)
  |> should.equal(1)
  list.contains(
    received,
    transport.Rejected(topic_id: too_long, reason: transport.OverLimit),
  )
  |> should.be_true
}

pub fn topic_subscription_cap_defaults_to_1000_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.send(c1, transport.Resync(cursors: room_cursors(1001)))

  let received = frames()
  list.count(received, wire_support.is_snapshot)
  |> should.equal(1000)
  list.contains(
    received,
    transport.Rejected(topic_id: "room:1001", reason: transport.OverLimit),
  )
  |> should.be_true
}

pub fn topic_resync_with_a_huge_cursor_list_is_bounded_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.max_subscriptions(per_client: 2),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.send(c1, transport.Resync(cursors: room_cursors(10_000)))

  let received = frames()
  list.count(received, wire_support.is_snapshot)
  |> should.equal(2)
  received
  |> list.filter(fn(frame) { !wire_support.is_snapshot(frame) })
  |> should.equal([
    transport.Rejected(topic_id: "room:3", reason: transport.OverLimit),
  ])
  dict.size(test_support.inspect(app).topics)
  |> should.equal(2)
}

// =============================================================================
// RESYNC
// =============================================================================

pub fn topic_resync_does_not_bypass_access_test() {
  let app = denying_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.resync_topic(c1, "chat")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "chat", reason: transport.AccessDenied),
  ])
}

pub fn topic_denied_subscribe_then_resync_sends_no_snapshot_test() {
  let app = denying_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.resync_topic(c1, "chat")

  frames()
  |> list.any(wire_support.is_snapshot)
  |> should.be_false
}

pub fn topic_resync_joins_an_allowing_topic_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.resync_topic(c1, "chat")
  wire_support.settle(app)
  server.dispatch_topic(app, topic_id: "chat", message: Increment)

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn topic_resync_of_a_joined_topic_sends_only_a_snapshot_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  wire_support.resync_topic(c1, "chat")

  case frames() {
    [transport.Snapshot(..)] -> Nil
    _ -> should.fail()
  }
  // join announced once only
  events(app)
  |> list.filter(is_subscribed)
  |> list.length
  |> should.equal(1)
}

pub fn topic_a_resyncing_client_resubscribes_after_reconnecting_test() {
  let app = test_support.new_topic_server()
  // connection before the socket dropped
  let #(first, first_frames) = wire_support.open(app, "c1")
  wire_support.subscribe(first, "chat")
  let _ = first_frames()
  server.disconnect(first)
  // reconnection resyncs rather than resubscribes
  let #(second, second_frames) = wire_support.open(app, "c2")

  wire_support.resync_topic(second, "chat")

  second_frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
  // later dispatch still reaches it
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  second_frames()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

pub fn topic_message_right_behind_a_resync_is_applied_test() {
  // a reconnecting client's offline edits follow its resync without a pause
  let app = test_support.new_topic_server()
  let #(c1, frames1) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames1()
  let #(c2, frames2) = wire_support.open(app, "c2")

  wire_support.resync_topic(c2, "chat")
  wire_support.topic_message(c2, "chat", Increment)

  frames2()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
  ])
  frames1()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

pub fn topic_message_ahead_of_its_resync_is_dropped_test() {
  // the order the old offline queue used, the edit was lost
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.topic_message(c1, "chat", Increment)
  wire_support.resync_topic(c1, "chat")

  frames()
  |> should.equal([
    transport.Dropped(target: transport.Topic("chat")),
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

// =============================================================================
// UNSUBSCRIBE
// =============================================================================

pub fn topic_subscribe_then_unsubscribe_leaves_no_subscriber_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.unsubscribe(c1, "chat")
  wire_support.settle(app)

  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

pub fn topic_disconnect_leaves_no_subscriber_test() {
  let app = test_support.new_topic_server()
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  server.disconnect(c1)
  wire_support.settle(app)

  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

// =============================================================================
// SUBSCRIBED / UNSUBSCRIBED OBSERVERS
// =============================================================================

pub fn topic_subscribing_twice_announces_the_join_once_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")
  wire_support.subscribe(c1, "chat")

  events(app)
  |> list.filter(is_subscribed)
  |> should.equal([server.Subscribed(client_id: "c1", topic_id: "chat")])
}

pub fn topic_rejected_subscription_is_not_announced_test() {
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.topic_store_with([
        #("chat", store.Allow(fn(_, _, _) { False })),
      ]),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "chat")

  events(app)
  |> list.any(is_subscribed)
  |> should.be_false
}

pub fn topic_unsubscribed_is_announced_to_observers_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = events(app)

  wire_support.unsubscribe(c1, "chat")

  events(app)
  |> should.equal([server.Unsubscribed(client_id: "c1", topic_id: "chat")])
  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

// =============================================================================
// STOP
// =============================================================================

pub fn topic_stop_forgets_it_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  server.stop_topic(app, topic_id: "chat")

  test_support.subscriber_count(app, "chat")
  |> should.equal(-1)
  test_support.topic_watched(app, "chat")
  |> should.equal(option.None)
}

pub fn topic_stop_tells_subscribers_with_a_final_acknowledge_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  let _ = frames()

  wire_support.stop_topic(app, "chat")

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("chat"), sequence: 1),
  ])
}

pub fn topic_message_after_stop_is_dropped_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.stop_topic(app, "chat")
  let _ = frames()

  wire_support.topic_message(c1, "chat", Increment)

  frames()
  |> should.equal([transport.Dropped(target: transport.Topic("chat"))])
}

pub fn topic_subscribing_after_stop_starts_the_topic_afresh_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  server.stop_topic(app, topic_id: "chat")

  wire_support.subscribe(c1, "chat")

  frames()
  |> should.equal([
    transport.Snapshot(
      target: transport.Topic("chat"),
      sequence: 0,
      state: test_support.initial_model(),
    ),
  ])
}

pub fn topic_stop_of_an_unknown_id_is_a_no_op_test() {
  let app = test_support.new_topic_server()

  server.stop_topic(app, topic_id: "never-started")

  test_support.client_count(app)
  |> should.equal(0)
}

// =============================================================================
// ROUTE ENFORCEMENT
// =============================================================================

pub fn topic_message_with_a_mismatching_id_is_dropped_test() {
  // Increment routes to `chat`, making `room:1` the wrong target
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  let _ = frames()
  let _ = events(app)

  wire_support.topic_message(c1, "room:1", Increment)

  frames()
  |> should.equal([transport.Dropped(target: transport.Topic("room:1"))])
  case events(app) {
    [server.Diagnostic(level: transport.Warning, ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn topic_message_with_a_matching_id_is_not_a_diagnostic_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")

  wire_support.topic_message(c1, "chat", Increment)

  let seen = events(app)
  list.contains(
    seen,
    server.TopicMessageReceived(
      client_id: "c1",
      topic_id: "chat",
      message: Increment,
    ),
  )
  |> should.be_true
  list.any(seen, is_diagnostic)
  |> should.be_false
}

pub fn topic_session_message_routed_to_a_topic_is_dropped_test() {
  // Increment routes to chat, meaning it is rejected as a session message
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  let _ = events(app)

  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([transport.Dropped(target: transport.Session)])
  case events(app) {
    [server.Diagnostic(level: transport.Warning, ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn topic_local_message_sent_as_a_session_message_is_dropped_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, test_support.Reset)

  frames()
  |> should.equal([transport.Dropped(target: transport.Session)])
}

pub fn topic_session_message_routed_to_the_session_is_applied_test() {
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, test_support.IncrementSecondary)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}
