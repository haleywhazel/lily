// a malicious client against the server, one regression per attack, both
// targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
@target(erlang)
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/result
import gleam/string

import gleeunit/should

import lily/server
import lily/store
import lily/test_support.{
  type Message, type Model, Decrement, Increment, IncrementSecondary, Noop,
  Reset, SetName,
}
import lily/transport
import lily/wire_support.{type Later}

// =============================================================================
// HELPERS
// =============================================================================

fn advance(time: test_support.Shared(Int), milliseconds: Int) -> Nil {
  test_support.set_shared(time, test_support.get_shared(time) + milliseconds)
}

/// A clock the test moves by hand, readable from the server's process.
fn clocked(
  builder: server.Builder(Model, Message),
) -> #(server.Builder(Model, Message), test_support.Shared(Int)) {
  let time = test_support.new_shared(0)
  #(server.clock(builder, now: fn() { test_support.get_shared(time) }), time)
}

/// An `Allow` that counts its checks, readable from the server's process.
fn counting_access() -> #(store.Access(Model), test_support.Shared(Int)) {
  let checks = test_support.new_shared(0)
  let access =
    store.Allow(fn(_, _, _) {
      test_support.set_shared(checks, test_support.get_shared(checks) + 1)
      True
    })
  #(access, checks)
}

/// A session server on [`counting_serialiser`](#counting_serialiser).
fn counting_builder() -> #(
  server.Builder(Model, Message),
  test_support.Ref(Int),
) {
  let #(serialiser, count) = counting_serialiser()
  let app_store =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.sync_with(route: fn(_) { store.Session }, serialiser:)
    |> store.session(get: fn(model) { model }, set: fn(_, model) { model })
  #(server.new(app_store, origins: server.AnyOrigin), count)
}

/// The fixtures' serialiser, counting decodes in the calling process.
fn counting_serialiser() -> #(
  transport.Serialiser(Model, Message),
  test_support.Ref(Int),
) {
  let count = test_support.new(0)
  let inner = test_support.custom_serialiser()
  let serialiser =
    transport.serialiser(
      encode: transport.encode(_, serialiser: inner),
      decode: fn(bytes) {
        test_support.set(count, test_support.get(count) + 1)
        transport.decode(bytes, serialiser: inner)
      },
    )
  #(serialiser, count)
}

fn is_throttled(event: server.ServerEvent(Model, Message)) -> Bool {
  case event {
    server.ClientThrottled(..) -> True
    _ -> False
  }
}

/// Logged lines from `thunk` that contain `needle`.
fn logged(needle: String, thunk: fn() -> Nil) -> Int {
  test_support.capture_log_levels(thunk)
  |> list.count(fn(line) { string.contains(line.1, needle) })
}

fn session_message(payload: String) -> BitArray {
  bit_array.from_string(
    "{\"type\":\"session_message\",\"payload\":" <> payload <> "}",
  )
}

// slow enough that a second subscribe lands before the topic admits the first
@target(erlang)
fn slow_initial_model() -> Model {
  process.sleep(50)
  test_support.initial_model()
}

@target(javascript)
fn slow_initial_model() -> Model {
  test_support.initial_model()
}

// =============================================================================
// DECODING
// =============================================================================

pub fn hardening_an_oversized_frame_is_refused_before_decode_test() {
  let #(builder, count) = counting_builder()
  let #(builder, events) =
    wire_support.observed(builder |> server.max_frame_bytes(bytes: 16))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  let _ = events(app)

  wire_support.session_message(c1, Increment)

  // refused unread, its head still says which edit to roll back
  frames()
  |> should.equal([transport.Dropped(target: transport.Session)])
  test_support.get(count)
  |> should.equal(0)
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped an oversized frame from \"c1\"",
    ),
  ])
}

pub fn hardening_a_frame_is_decoded_once_in_the_callers_process_test() {
  // the count lives in this process, a decode in the server wouldn't show
  let #(builder, count) = counting_builder()
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, Increment)
  server.incoming(c1, bytes: <<"not a frame">>)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
  test_support.get(count)
  |> should.equal(2)
}

pub fn hardening_a_server_frame_from_a_client_is_refused_test() {
  // the payload would decode, a snapshot is just never a client's to send
  let #(builder, events) = wire_support.observed(test_support.session_builder())
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  let _ = events(app)

  wire_support.send(
    c1,
    transport.Snapshot(
      target: transport.Session,
      epoch: 0,
      sequence: 9,
      state: test_support.initial_model(),
    ),
  )

  frames()
  |> should.equal([])
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a frame from \"c1\" that failed to decode",
    ),
  ])
}

pub fn hardening_a_payload_the_json_parser_refuses_is_still_dropped_test() {
  // Erlang's parser refuses 1e400 outright, JavaScript reads Infinity
  test_support.register_fixtures()
  let app =
    test_support.start_server(server.new(
      test_support.automatic_session_store(transport.Json),
      origins: server.AnyOrigin,
    ))
  let #(c1, raw) = wire_support.open_raw(app, "c1", [])
  let _ = raw()

  let _ = server.incoming(c1, bytes: session_message("1e400"))

  raw()
  |> list.map(wire_support.decode_automatic)
  |> should.equal([transport.Dropped(target: transport.Session)])
}

pub fn hardening_a_frame_int_past_the_wire_range_is_refused_test() {
  let serialiser = test_support.automatic_serialiser(transport.Json)
  transport.decode(
    <<
      "{\"type\":\"acknowledge\",\"target\":{\"kind\":\"session\"},\"sequence\":9007199254740993}",
    >>,
    serialiser:,
  )
  |> should.equal(Error(Nil))
}

pub fn hardening_a_cursor_with_half_a_version_is_refused_test() {
  // an epoch without its sequence names no state
  let serialiser = test_support.automatic_serialiser(transport.Json)
  [
    "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\",\"epoch\":1}]}",
    "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\",\"sequence\":1}]}",
    "{\"type\":\"resync\",\"cursors\":[{\"kind\":\"session\",\"epoch\":9007199254740993,\"sequence\":1}]}",
  ]
  |> list.each(fn(frame) {
    transport.decode(bit_array.from_string(frame), serialiser:)
    |> should.equal(Error(Nil))
  })
}

pub fn hardening_an_undecodable_payload_without_a_schema_is_dropped_test() {
  test_support.register_fixtures()
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.automatic_session_store(transport.Json),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  let #(c1, raw) = wire_support.open_raw(app, "c1", [])
  let _ = raw()
  let _ = events(app)

  server.incoming(
    c1,
    bytes: session_message("{\"_\":\"NoSuchConstructorAnywhere\"}"),
  )

  raw()
  |> list.map(wire_support.decode_automatic)
  |> should.equal([transport.Dropped(target: transport.Session)])
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a message from \"c1\" whose payload failed to decode",
    ),
  ])
}

// =============================================================================
// SUBSCRIPTIONS
// =============================================================================

pub fn hardening_duplicate_session_cursors_send_one_snapshot_test() {
  let app = test_support.new_server()
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.send(
    c1,
    transport.Resync(cursors: list.repeat(
      transport.Unknown(transport.Session),
      50,
    )),
  )

  frames()
  |> list.count(wire_support.is_snapshot)
  |> should.equal(1)
}

pub fn hardening_duplicate_topic_cursors_send_one_snapshot_test() {
  // joined first, so each cursor would be a fresh snapshot of its own
  let app = test_support.new_topic_server()
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  wire_support.send(
    c1,
    transport.Resync(cursors: list.repeat(
      transport.Unknown(transport.Topic("chat")),
      50,
    )),
  )

  frames()
  |> list.count(wire_support.is_snapshot)
  |> should.equal(1)
}

pub fn hardening_subscribing_to_a_joined_topic_runs_no_access_check_test() {
  let #(access, checks) = counting_access()
  let app = test_support.new_topic_server_with_access(access)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  list.repeat(Nil, 20)
  |> list.each(fn(_) { wire_support.subscribe(c1, "chat") })

  frames()
  |> should.equal([])
  test_support.get_shared(checks)
  |> should.equal(1)
}

pub fn hardening_a_pending_topics_repeat_subscribe_is_ignored_test() {
  let #(access, checks) = counting_access()
  let app =
    test_support.start_server(
      server.new(
        test_support.topic_store_with([#("room:", access)]),
        origins: server.AnyOrigin,
      )
      |> server.topics_init(prefix: "room:", init: fn(_) {
        slow_initial_model()
      }),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:1")

  frames()
  |> list.count(wire_support.is_snapshot)
  |> should.equal(1)
  test_support.get_shared(checks)
  |> should.equal(1)
}

pub fn hardening_unsubscribing_from_an_unheld_topic_is_ignored_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(c1, c1_frames) = wire_support.open(app, "c1")
  let #(c2, _c2_frames) = wire_support.open(app, "c2")
  wire_support.subscribe(c2, "chat")
  let _ = events(app)

  wire_support.unsubscribe(c1, "chat")

  events(app)
  |> should.equal([])
  c1_frames()
  |> should.equal([])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn hardening_a_session_message_rechecks_access_only_on_a_change_test() {
  let #(access, checks) = counting_access()
  let app = test_support.new_topic_server_with_access(access)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.settle(app)

  wire_support.session_message(c1, Noop)
  wire_support.settle(app)
  test_support.get_shared(checks)
  |> should.equal(1)

  wire_support.session_message(c1, IncrementSecondary)
  wire_support.settle(app)
  test_support.get_shared(checks)
  |> should.equal(2)
}

pub fn hardening_stopping_an_idle_topic_leaves_other_subscriptions_test() -> Later {
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.stop_idle_topics(after: 40),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  wire_support.unsubscribe(c1, "room:1")
  let _ = frames()

  use <- wire_support.after(400)
  test_support.subscriber_count(app, "room:1")
  |> should.equal(-1)
  wire_support.topic_message(c1, "room:2", SetName("room:2"))
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Topic("room:2"), sequence: 1),
  ])
}

// =============================================================================
// LIMITS
// =============================================================================

pub fn hardening_an_over_limit_rejection_truncates_the_id_test() {
  // seven bytes, a cut at six would split the é
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.max_topic_id_bytes(bytes: 6),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "room:é")

  frames()
  |> should.equal([
    transport.Rejected(topic_id: "room:", reason: transport.OverLimit),
  ])
}

pub fn hardening_max_topics_is_configurable_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder()
      |> server.max_topics(count: 1),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")

  frames()
  |> list.filter(fn(frame) { !wire_support.is_snapshot(frame) })
  |> should.equal([
    transport.Rejected(topic_id: "room:2", reason: transport.OverLimit),
  ])
}

// =============================================================================
// IDENTITY
// =============================================================================

pub fn hardening_reusing_a_live_id_replaces_the_old_connection_test() {
  let #(builder, events) = wire_support.observed(test_support.topic_builder())
  let app = test_support.start_server(builder)
  let #(old, _old_frames) = wire_support.open(app, "c1")
  wire_support.subscribe(old, "chat")
  let _ = events(app)

  let #(_new, new_frames) = wire_support.open(app, "c1")

  events(app)
  |> should.equal([
    server.ClientEvicted(client_id: "c1", reason: server.Superseded),
    server.Unsubscribed(client_id: "c1", topic_id: "chat"),
    server.ClientDisconnected(client_id: "c1"),
    server.ClientConnected(client_id: "c1"),
  ])
  new_frames()
  |> should.equal([])
  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

pub fn hardening_a_stale_disconnect_does_not_remove_the_new_client_test() {
  let app = test_support.new_server()
  let #(old, _old_frames) = wire_support.open(app, "c1")
  let #(new, new_frames) = wire_support.open(app, "c1")

  server.disconnect(old)

  test_support.client_count(app)
  |> should.equal(1)
  wire_support.session_message(new, Increment)
  new_frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn hardening_frames_from_a_stale_connection_are_ignored_test() {
  let app = test_support.new_server()
  let #(old, old_frames) = wire_support.open(app, "c1")
  let #(_new, new_frames) = wire_support.open(app, "c1")

  wire_support.session_message(old, Increment)
  wire_support.resync_session(old)

  new_frames()
  |> should.equal([])
  old_frames()
  |> should.equal([])
}

pub fn hardening_a_connection_rebuilt_from_an_id_reaches_the_current_client_test() {
  let app = test_support.new_server()
  let #(_old, _old_frames) = wire_support.open(app, "c1")
  let #(_new, new_frames) = wire_support.open(app, "c1")

  server.connection(app, client_id: "c1")
  |> wire_support.session_message(Increment)

  new_frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn hardening_max_clients_refuses_and_frees_a_slot_on_disconnect_test() {
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_clients(count: 1),
    )
  let connect = fn(client_id) {
    server.connect_as(
      app,
      origin: option.None,
      send: fn(_) { Nil },
      client_id:,
      seed: [],
      watch: server.Unwatched,
    )
  }
  let assert Ok(first) = connect("c1")

  connect("c2")
  |> result.map(server.client_id)
  |> should.equal(Error(server.TooManyClients))

  server.disconnect(first)
  wire_support.settle(app)
  connect("c2")
  |> result.map(server.client_id)
  |> should.equal(Ok("c2"))
}

pub fn hardening_a_replaced_id_keeps_its_slot_test() {
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.max_clients(count: 2),
    )
  let #(_first, _) = wire_support.open(app, "c1")
  let #(_again, _) = wire_support.open(app, "c1")
  wire_support.settle(app)

  let #(_second, _) = wire_support.open(app, "c2")
  test_support.client_count(app)
  |> should.equal(2)
}

// =============================================================================
// RATE LIMIT
// =============================================================================

pub fn hardening_a_message_over_the_rate_limit_waits_its_turn_test() -> Later {
  // an offline replay past the burst is slowed down, not thrown away
  let #(builder, time) =
    clocked(
      test_support.session_builder()
      |> server.rate_limit(per_second: 1000, burst: 2),
    )
  let #(builder, events) = wire_support.observed(builder)
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  let _ = events(app)

  list.repeat(Nil, 3)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
    transport.Acknowledge(target: transport.Session, sequence: 2),
  ])
  events(app)
  |> list.filter(is_throttled)
  |> should.equal([server.ClientThrottled(client_id: "c1")])

  advance(time, 10)
  use <- wire_support.after(100)
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 3),
  ])
}

pub fn hardening_past_the_hold_a_message_is_dropped_in_order_test() -> Later {
  // two pass, two wait, the fifth can't wait and its `Dropped` queues behind
  let #(builder, time) =
    clocked(
      test_support.session_builder()
      |> server.rate_limit(per_second: 1000, burst: 2),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")

  list.repeat(Nil, 5)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  let _ = frames()

  advance(time, 10)
  use <- wire_support.after(100)
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 3),
    transport.Acknowledge(target: transport.Session, sequence: 4),
    transport.Dropped(target: transport.Session),
  ])
}

pub fn hardening_the_rate_limit_refills_over_time_test() {
  let #(builder, time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 1))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.session_message(c1, Increment)
  wire_support.session_message(c1, Increment)
  let _ = frames()

  advance(time, 1000)
  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 2),
  ])
}

pub fn hardening_a_rate_limited_resync_is_deferred_not_dropped_test() -> Later {
  let #(builder, time) =
    clocked(
      test_support.session_builder()
      |> server.rate_limit(per_second: 1000, burst: 1),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.session_message(c1, Increment)
  wire_support.resync_session(c1)
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])

  advance(time, 10)
  use <- wire_support.after(100)
  frames()
  |> list.count(wire_support.is_snapshot)
  |> should.equal(1)
}

pub fn hardening_a_resync_costs_its_distinct_cursors_test() {
  // two distinct cursors and the topic it starts, three of four
  let #(builder, _time) =
    clocked(test_support.topic_builder() |> server.rate_limit(1, burst: 4))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  let cursors =
    list.repeat([transport.Session, transport.Topic("chat")], 20)
    |> list.flatten
    |> list.map(transport.Unknown)

  wire_support.send(c1, transport.Resync(cursors:))
  wire_support.session_message(c1, IncrementSecondary)
  wire_support.session_message(c1, IncrementSecondary)

  let received = frames()
  list.count(received, wire_support.is_snapshot)
  |> should.equal(2)
  list.filter(received, fn(frame) { !wire_support.is_snapshot(frame) })
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn hardening_sustained_abuse_evicts_the_client_test() {
  let #(builder, _time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 2))
  let #(builder, events) = wire_support.observed(builder)
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  let _ = events(app)

  list.repeat(Nil, 10)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })

  let seen = events(app)
  list.contains(
    seen,
    server.ClientEvicted(client_id: "c1", reason: server.RateLimited),
  )
  |> should.be_true
  list.contains(seen, server.ClientDisconnected(client_id: "c1"))
  |> should.be_true
  test_support.client_count(app)
  |> should.equal(0)
}

pub fn hardening_a_throttled_client_is_reported_once_per_window_test() {
  let #(builder, time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 5))
  let #(builder, events) = wire_support.observed(builder)
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  let _ = events(app)
  let burst = fn(count) {
    list.repeat(Nil, count)
    |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  }

  burst(8)
  events(app)
  |> list.count(is_throttled)
  |> should.equal(1)

  advance(time, 10_000)
  burst(6)
  events(app)
  |> list.count(is_throttled)
  |> should.equal(1)
}

pub fn hardening_a_held_subscribe_over_the_id_cap_is_refused_in_turn_test() -> Later {
  // it waits like any frame, then meets the cap when it runs
  let #(builder, time) =
    clocked(
      test_support.topic_builder()
      |> server.rate_limit(per_second: 1000, burst: 1)
      |> server.max_topic_id_bytes(bytes: 8),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.session_message(c1, IncrementSecondary)
  wire_support.subscribe(c1, "room:123456789")
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])

  advance(time, 10)
  use <- wire_support.after(100)
  frames()
  |> should.equal([
    transport.Rejected(topic_id: "room:123", reason: transport.OverLimit),
  ])
}

pub fn hardening_a_held_subscribe_then_unsubscribe_run_in_order_test() -> Later {
  let #(builder, time) =
    clocked(
      test_support.topic_builder()
      |> server.rate_limit(per_second: 50, burst: 1),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.session_message(c1, IncrementSecondary)
  wire_support.subscribe(c1, "chat")
  // the retry is 21 ms out, long after the unsubscribe lands
  wire_support.settle(app)
  advance(time, 100)
  wire_support.unsubscribe(c1, "chat")
  let _ = frames()

  // handled in order, the subscribe first, so the client ends up out
  advance(time, 100)
  use <- wire_support.after(150)
  let _ = frames()
  test_support.subscriber_count(app, "chat")
  |> should.equal(0)
}

pub fn hardening_a_reused_id_keeps_its_rate_budget_test() {
  // reconnecting under the same id doesn't buy a fresh burst
  let #(builder, _time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 2))
  let app = test_support.start_server(builder)
  let #(old, _old_frames) = wire_support.open(app, "c1")
  wire_support.session_message(old, Increment)
  wire_support.session_message(old, Increment)
  wire_support.settle(app)

  let #(new, new_frames) = wire_support.open(app, "c1")
  wire_support.session_message(new, Increment)

  new_frames()
  |> should.equal([])
}

pub fn hardening_a_big_message_and_its_snapshot_cost_their_size_test() {
  // about 40 KiB, so the message and the snapshot it makes cost three each
  let #(builder, _time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 6))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, SetName(string.repeat("x", 40_000)))
  wire_support.resync_session(c1)
  wire_support.session_message(c1, Increment)

  let received = frames()
  list.count(received, wire_support.is_snapshot)
  |> should.equal(1)
  list.filter(received, fn(frame) { !wire_support.is_snapshot(frame) })
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn hardening_a_quiet_clients_big_edit_is_decoded_after_it_refilled_test() {
  // the server refills the allowance before the frame is weighed
  let #(builder, time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 3))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  list.repeat(Nil, 3)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  let _ = frames()

  advance(time, 10_000)
  let big = string.repeat("x", 70_000)
  server.incoming(
    c1,
    bytes: wire_support.encode(transport.SessionMessage(SetName(big))),
  )
  |> should.equal(server.Accepted)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 4),
  ])
}

pub fn hardening_a_held_unsubscribe_keeps_its_place_before_a_subscribe_test() -> Later {
  // leave then join again, in that order, the client ends up joined
  let #(builder, time) =
    clocked(
      test_support.topic_builder()
      |> server.rate_limit(per_second: 1000, burst: 2),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  wire_support.session_message(c1, IncrementSecondary)
  wire_support.session_message(c1, IncrementSecondary)
  wire_support.unsubscribe(c1, "chat")
  wire_support.subscribe(c1, "chat")
  let _ = frames()

  advance(time, 10)
  use <- wire_support.after(100)
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn hardening_an_empty_resync_still_costs_a_frame_test() {
  let #(builder, _time) =
    clocked(test_support.session_builder() |> server.rate_limit(1, burst: 2))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.send(c1, transport.Resync(cursors: []))
  wire_support.send(c1, transport.Resync(cursors: []))
  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([])
}

pub fn hardening_a_big_topic_snapshot_is_charged_to_the_subscriber_test() {
  // the subscribe and the topic it starts cost two, its 40 KiB snapshot two
  // more
  let #(builder, _time) =
    clocked(
      test_support.topic_builder()
      |> server.rate_limit(1, burst: 5)
      |> server.topics_init(prefix: "room:", init: fn(_) {
        test_support.Model(
          ..test_support.initial_model(),
          name: string.repeat("x", 40_000),
        )
      }),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  let _ = frames()

  wire_support.session_message(c1, IncrementSecondary)
  wire_support.session_message(c1, IncrementSecondary)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn hardening_held_frames_past_the_byte_cap_are_dropped_in_order_test() -> Later {
  // four 60 KiB edits fit the 256 KiB hold, the fifth is refused behind them
  let #(builder, time) =
    clocked(
      test_support.session_builder()
      |> server.rate_limit(per_second: 1000, burst: 30),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  list.repeat(Nil, 30)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  let big = string.repeat("x", 60_000)
  list.repeat(Nil, 5)
  |> list.each(fn(_) { wire_support.session_message(c1, SetName(big)) })
  let _ = frames()

  advance(time, 1000)
  use <- wire_support.after(200)
  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 31),
    transport.Acknowledge(target: transport.Session, sequence: 32),
    transport.Acknowledge(target: transport.Session, sequence: 33),
    transport.Acknowledge(target: transport.Session, sequence: 34),
    transport.Dropped(target: transport.Session),
  ])
}

pub fn hardening_max_held_bytes_lets_bigger_edits_wait_test() -> Later {
  // the same five 60 KiB edits as above, all held under a 1 MiB budget
  let #(builder, time) =
    clocked(
      test_support.session_builder()
      |> server.rate_limit(per_second: 1000, burst: 30)
      |> server.max_held_bytes(per_client: 1_048_576, total: 1_048_576),
    )
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  list.repeat(Nil, 30)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })
  let big = string.repeat("x", 60_000)
  list.repeat(Nil, 5)
  |> list.each(fn(_) { wire_support.session_message(c1, SetName(big)) })
  let _ = frames()

  advance(time, 1000)
  use <- wire_support.after(200)
  frames()
  |> list.count(fn(frame) {
    case frame {
      transport.Acknowledge(..) -> True
      _ -> False
    }
  })
  |> should.equal(5)
}

pub fn hardening_evict_after_raises_the_refusals_tolerated_test() {
  // the abuse above, under a higher threshold, is refused but not cut off
  let #(builder, _time) =
    clocked(
      test_support.session_builder()
      |> server.rate_limit(1, burst: 2)
      |> server.evict_after(refusals: 100, within: 10_000),
    )
  let #(builder, events) = wire_support.observed(builder)
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  let _ = events(app)

  list.repeat(Nil, 10)
  |> list.each(fn(_) { wire_support.session_message(c1, Increment) })

  events(app)
  |> list.contains(server.ClientEvicted(
    client_id: "c1",
    reason: server.RateLimited,
  ))
  |> should.be_false
  test_support.client_count(app)
  |> should.equal(1)
}

pub fn hardening_a_rate_limit_of_zero_still_works_test() {
  // clamped to one a second and a burst of one, not a server that refuses all
  let app =
    test_support.start_server(
      test_support.session_builder() |> server.rate_limit(0, burst: 0),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.session_message(c1, Increment)

  frames()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn hardening_a_revoked_topic_is_unsubscribed_before_it_is_rejected_test() {
  // observers hear the client leave, then why
  let allowed = test_support.new_shared(True)
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.topic_store_with([
        #("chat", store.Allow(fn(_, _, _) { test_support.get_shared(allowed) })),
      ]),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = events(app)

  test_support.set_shared(allowed, False)
  server.recheck_access(app, client_id: "c1")

  events(app)
  |> should.equal([
    server.Unsubscribed(client_id: "c1", topic_id: "chat"),
    server.SubscriptionRejected(
      client_id: "c1",
      topic_id: "chat",
      reason: transport.AccessDenied,
    ),
  ])
}

pub fn hardening_a_topic_that_finds_a_dead_send_disconnects_the_client_test() {
  let app = test_support.new_topic_server()
  let broken = wire_support.open_broken(app, "c1")
  wire_support.subscribe(broken, "chat")
  wire_support.settle(app)

  server.dispatch_topic(app, topic_id: "chat", message: Increment)

  wire_support.settle(app)
  test_support.client_count(app)
  |> should.equal(0)
}

// =============================================================================
// DIAGNOSTICS
// =============================================================================

pub fn hardening_diagnostics_are_throttled_per_client_test() {
  let #(builder, time) = clocked(test_support.session_builder())
  let #(builder, events) = wire_support.observed(builder)
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  let _ = events(app)

  list.repeat(Nil, 5)
  |> list.each(fn(_) { server.incoming(c1, bytes: <<"junk">>) })
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a frame from \"c1\" that failed to decode",
    ),
  ])

  advance(time, 10_000)
  server.incoming(c1, bytes: <<"junk">>)
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a frame from \"c1\" that failed to decode (4 similar since)",
    ),
  ])
}

pub fn hardening_a_diagnostic_escapes_and_truncates_the_client_id_test() {
  let #(builder, events) = wire_support.observed(test_support.session_builder())
  let app = test_support.start_server(builder)
  let client_id = "a\n" <> string.repeat("x", 100)
  let #(connection, _frames) = wire_support.open(app, client_id)
  let _ = events(app)

  server.incoming(connection, bytes: <<"junk">>)

  let shown = "\"a\\n" <> string.repeat("x", 62) <> "\""
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a frame from " <> shown <> " that failed to decode",
    ),
  ])
}

pub fn hardening_a_crashing_topic_update_is_diagnosed_through_the_server_test() {
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
  let #(builder, events) =
    wire_support.observed(server.new(crashing, origins: server.AnyOrigin))
  let app = test_support.start_server(builder)
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "chat")
  let _ = frames()
  let _ = events(app)

  wire_support.topic_message(c1, "chat", Decrement)

  frames()
  |> should.equal([transport.Dropped(target: transport.Topic("chat"))])
  let assert [server.TopicMessageReceived(..), server.Diagnostic(message:, ..)] =
    events(app)
  string.starts_with(
    message,
    "dropped malformed topic message on \"chat\" from \"c1\": ",
  )
  |> should.be_true
}

// =============================================================================
// RECEIVED
// =============================================================================

pub fn hardening_incoming_says_closed_once_the_id_is_taken_test() {
  let app = test_support.new_server()
  let #(old, _old_frames) = wire_support.open(app, "c1")
  server.incoming(old, bytes: wire_support.encode(transport.Resync([])))
  |> should.equal(server.Accepted)

  let _ = wire_support.open(app, "c1")
  wire_support.settle(app)

  server.incoming(old, bytes: wire_support.encode(transport.Resync([])))
  |> should.equal(server.Closed)
}

pub fn hardening_incoming_says_closed_once_the_server_stops_test() {
  let app = test_support.new_server()
  let #(c1, _frames) = wire_support.open(app, "c1")

  wire_support.stop(app)

  server.incoming(c1, bytes: wire_support.encode(transport.Resync([])))
  |> should.equal(server.Closed)
}

pub fn hardening_incoming_says_too_large_and_accepts_a_throttled_frame_test() {
  // a frame over the rate limit is taken and waits, nothing to tell the
  // transport
  let #(builder, _time) =
    clocked(
      test_support.session_builder()
      |> server.max_frame_bytes(bytes: 64)
      |> server.rate_limit(1, burst: 1),
    )
  let app = test_support.start_server(builder)
  let #(c1, _frames) = wire_support.open(app, "c1")
  let message = wire_support.encode(transport.SessionMessage(Increment))

  server.incoming(c1, bytes: <<0:size(1000)-unit(8)>>)
  |> should.equal(server.TooLarge)
  wire_support.settle(app)
  server.incoming(c1, bytes: message)
  |> should.equal(server.Accepted)
}

pub fn hardening_the_automatic_serialiser_refuses_server_tags_unread_test() {
  // a snapshot naming a constructor nobody declared is refused before it's
  // built, a schema wouldn't have looked at it
  let serialiser = test_support.automatic_serialiser(transport.Json)
  let frames = [
    "{\"type\":\"snapshot\",\"target\":{\"kind\":\"session\"},\"sequence\":1,\"state\":{\"_\":\"NoSuchConstructorAnywhere\"}}",
    "{\"type\":\"version\",\"hash\":\"x\",\"protocol\":1}",
    "{\"type\":\"acknowledge\",\"target\":{\"kind\":\"session\"},\"sequence\":1}",
    "{\"type\":\"connected\",\"client_id\":\"x\"}",
  ]
  list.each(frames, fn(frame) {
    transport.decode_inbound(
      bit_array.from_string(frame),
      serialiser:,
      conform: transport.message_conformer(option.None),
      from_client: True,
    )
    |> should.equal(Error(transport.Malformed))
  })
}

// =============================================================================
// TOPIC TABLE
// =============================================================================

pub fn hardening_a_full_table_stops_the_topic_unheld_longest_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder() |> server.max_topics(count: 2),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.unsubscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  let _ = frames()

  wire_support.subscribe(c1, "room:3")

  frames()
  |> list.count(wire_support.is_snapshot)
  |> should.equal(1)
  test_support.subscriber_count(app, "room:1")
  |> should.equal(-1)
  test_support.subscriber_count(app, "room:2")
  |> should.equal(1)
}

pub fn hardening_a_full_table_stops_the_oldest_unheld_first_test() {
  // room:1 left first, then room:2, room:1 goes to make room
  let app =
    test_support.start_server(
      test_support.topic_builder() |> server.max_topics(count: 2),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.unsubscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  wire_support.unsubscribe(c1, "room:2")
  let _ = frames()

  wire_support.subscribe(c1, "room:3")

  test_support.subscriber_count(app, "room:1")
  |> should.equal(-1)
  test_support.subscriber_count(app, "room:2")
  |> should.equal(0)
}

pub fn hardening_a_dispatched_unheld_topic_moves_to_the_back_test() {
  // in use by the server, so the other unheld topic goes first
  let app =
    test_support.start_server(
      test_support.topic_builder() |> server.max_topics(count: 2),
    )
  let #(c1, frames) = wire_support.open(app, "c1")
  wire_support.subscribe(c1, "room:1")
  wire_support.unsubscribe(c1, "room:1")
  wire_support.subscribe(c1, "room:2")
  wire_support.unsubscribe(c1, "room:2")
  server.dispatch_topic(app, topic_id: "room:1", message: SetName("room:1"))
  let _ = frames()

  wire_support.subscribe(c1, "room:3")

  test_support.subscriber_count(app, "room:1")
  |> should.equal(0)
  test_support.subscriber_count(app, "room:2")
  |> should.equal(-1)
}

pub fn hardening_a_full_table_of_held_topics_refuses_test() {
  let app =
    test_support.start_server(
      test_support.topic_builder() |> server.max_topics(count: 2),
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
}

pub fn hardening_a_resync_rechecks_a_pending_topic_test() {
  // the rule changes while the topic is still loading
  let allowed = test_support.new_shared(True)
  let app =
    test_support.start_server(
      server.new(
        test_support.topic_store_with([
          #(
            "room:",
            store.Allow(fn(_, _, _) { test_support.get_shared(allowed) }),
          ),
        ]),
        origins: server.AnyOrigin,
      )
      |> server.topics_init(prefix: "room:", init: fn(_) {
        slow_initial_model()
      }),
    )
  let #(c1, frames) = wire_support.open(app, "c1")

  wire_support.subscribe(c1, "room:1")
  test_support.set_shared(allowed, False)
  wire_support.resync_topic(c1, "room:1")

  // pending on Erlang, already joined on JavaScript, refused either way
  frames()
  |> list.contains(transport.Rejected(
    topic_id: "room:1",
    reason: transport.AccessDenied,
  ))
  |> should.be_true
}

// =============================================================================
// START-UP WARNINGS
// =============================================================================

pub fn hardening_start_up_warns_once_without_a_schema_test() {
  logged("automatic serialiser and no schema", fn() {
    let app =
      test_support.start_server(server.new(
        test_support.automatic_session_store(transport.Json),
        origins: server.AnyOrigin,
      ))
    wire_support.settle(app)
  })
  |> should.equal(1)
}

pub fn hardening_start_up_warns_when_a_schema_meets_a_custom_serialiser_test() {
  let schema =
    transport.schema(
      message: transport.Anything,
      model: transport.Anything,
      types: [],
    )
  logged("only checks the automatic serialiser", fn() {
    let app =
      test_support.start_server(server.new(
        test_support.session_store() |> store.schema(schema),
        origins: server.AnyOrigin,
      ))
    wire_support.settle(app)
  })
  |> should.equal(1)
}

pub fn hardening_a_session_routed_seed_warns_once_test() {
  let app = test_support.new_topic_server()

  logged("a seed message is routed to store.Session", fn() {
    let _ = wire_support.open_seeded(app, "c1", [IncrementSecondary])
    let _ = wire_support.open_seeded(app, "c2", [IncrementSecondary])
    wire_support.settle(app)
  })
  |> should.equal(1)
}

pub fn hardening_a_local_routed_seed_does_not_warn_test() {
  let app = test_support.new_topic_server()

  logged("a seed message is routed to store.Session", fn() {
    let _ = wire_support.open_seeded(app, "c1", [Reset])
    wire_support.settle(app)
  })
  |> should.equal(0)
}
