// lily/store, pure and target-agnostic

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/int

import gleeunit/should

import lily/store
import lily/test_support.{Decrement, Increment, SetName}
import lily/transport

// =============================================================================
// CONSTRUCTION
// =============================================================================

pub fn store_new_has_initial_model_test() {
  let app_store =
    store.new(init: test_support.initial_model(), update: test_support.update)
  store.get_model(app_store)
  |> should.equal(test_support.initial_model())
}

pub fn store_new_retains_update_function_test() {
  let update =
    store.new(init: test_support.initial_model(), update: test_support.update)
    |> store.update_function
  update(test_support.initial_model(), SetName("Alice")).name
  |> should.equal("Alice")
}

// =============================================================================
// SYNC
// =============================================================================

pub fn store_standalone_store_has_no_serialiser_test() {
  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.serialiser
  |> should.be_error
}

pub fn store_standalone_store_routes_everything_locally_test() {
  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.route(Increment)
  |> should.equal(store.Local)
}

pub fn store_synced_store_has_a_serialiser_test() {
  test_support.session_store()
  |> store.serialiser
  |> should.be_ok
}

pub fn store_serialiser_of_a_synced_store_round_trips_a_frame_test() {
  let serialiser = store.serialiser_of(test_support.session_store())
  let frame = transport.SessionMessage(payload: Decrement)

  transport.encode(frame, serialiser:)
  |> transport.decode(serialiser:)
  |> should.equal(Ok(frame))
}

pub fn store_synced_store_keeps_the_initial_model_test() {
  store.get_model(test_support.session_store())
  |> should.equal(test_support.initial_model())
}

pub fn store_sync_route_decides_where_a_message_goes_test() {
  let app_store = test_support.topic_store()

  store.route(app_store, Increment)
  |> should.equal(store.Topic("chat"))
  store.route(app_store, SetName("room:1"))
  |> should.equal(store.Topic("room:1"))
  store.route(app_store, test_support.IncrementSecondary)
  |> should.equal(store.Session)
  store.route(app_store, test_support.Reset)
  |> should.equal(store.Local)
}

pub fn store_local_store_routes_to_local_test() {
  test_support.local_store()
  |> store.route(Increment)
  |> should.equal(store.Local)
}

pub fn store_session_store_routes_to_session_test() {
  test_support.session_store()
  |> store.route(Increment)
  |> should.equal(store.Session)
}

pub fn store_update_function_is_the_stores_update_test() {
  let update = store.update_function(test_support.session_store())
  update(test_support.initial_model(), Increment).count
  |> should.equal(1)
}

// =============================================================================
// SUBSCRIPTIONS
// =============================================================================

pub fn store_subscriptions_default_to_none_test() {
  store.subscriptions_of(
    test_support.session_store(),
    test_support.initial_model(),
  )
  |> should.equal([])
}

pub fn store_subscriptions_are_a_function_of_the_model_test() {
  let app_store =
    test_support.session_store()
    |> store.subscriptions(fn(model) {
      case model.count {
        0 -> []
        count -> ["room:" <> int.to_string(count)]
      }
    })

  store.subscriptions_of(app_store, test_support.initial_model())
  |> should.equal([])
  store.subscriptions_of(
    app_store,
    test_support.Model(..test_support.initial_model(), count: 3),
  )
  |> should.equal(["room:3"])
}

pub fn store_standalone_store_has_no_subscriptions_test() {
  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.subscriptions_of(test_support.initial_model())
  |> should.equal([])
}

// =============================================================================
// ACCESS
// =============================================================================

pub fn store_access_for_an_undeclared_topic_is_an_error_test() {
  store.access_for(test_support.topic_store(), "unknown")
  |> should.be_error
}

pub fn store_access_for_a_store_without_topics_is_an_error_test() {
  store.access_for(test_support.session_store(), "chat")
  |> should.be_error
}

pub fn store_access_for_an_open_topic_is_open_test() {
  let assert Ok(access) = store.access_for(test_support.topic_store(), "chat")
  case access {
    store.Open -> Nil
    store.Allow(_) -> should.fail()
  }
}

pub fn store_access_for_an_exact_id_matches_only_that_id_test() {
  store.access_for(test_support.topic_store(), "chat")
  |> should.be_ok
  store.access_for(test_support.topic_store(), "chatter")
  |> should.be_error
}

pub fn store_access_for_an_id_matching_no_declaration_is_rejected_test() {
  store.access_for(test_support.topic_store(), "room")
  |> should.be_error
  store.access_for(test_support.topic_store(), "lobby:1")
  |> should.be_error
}

pub fn store_access_an_exact_id_beats_a_matching_prefix_test() {
  let app_store =
    test_support.topic_store_with([
      #("room:", store.Open),
      #("room:secret", store.Allow(fn(_, _, _) { False })),
    ])
  let assert Ok(store.Allow(_)) = store.access_for(app_store, "room:secret")
  let assert Ok(store.Open) = store.access_for(app_store, "room:secretive")
}

pub fn store_access_an_exact_id_beats_a_longer_declared_prefix_test() {
  let app_store =
    test_support.topic_store_with([
      #("room:1", store.Allow(fn(_, _, _) { False })),
      #("room:", store.Open),
      #("room:1:", store.Open),
    ])
  let assert Ok(store.Allow(_)) = store.access_for(app_store, "room:1")
}

pub fn store_access_for_a_family_covers_every_id_under_it_test() {
  store.access_for(test_support.topic_store(), "room:42")
  |> should.be_ok
}

pub fn store_access_allow_carries_the_predicate_test() {
  let app_store =
    test_support.topic_store_with([
      #(
        "vip:",
        store.Allow(fn(client_id, _topic_id, _session) { client_id == "alice" }),
      ),
    ])
  let assert Ok(store.Allow(allowed)) = store.access_for(app_store, "vip:1")

  allowed("alice", "vip:1", test_support.initial_model())
  |> should.be_true
  allowed("bob", "vip:1", test_support.initial_model())
  |> should.be_false
}

pub fn store_access_longest_prefix_wins_test() {
  let app_store =
    test_support.topic_store_with([
      #("room:", store.Open),
      #("room:secret:", store.Allow(fn(_, _, _) { False })),
    ])
  let assert Ok(store.Open) = store.access_for(app_store, "room:1")
  let assert Ok(store.Allow(_)) = store.access_for(app_store, "room:secret:1")
}

pub fn store_access_longest_prefix_wins_regardless_of_declaration_order_test() {
  let app_store =
    test_support.topic_store_with([
      #("room:secret:", store.Allow(fn(_, _, _) { False })),
      #("room:", store.Open),
    ])
  let assert Ok(store.Open) = store.access_for(app_store, "room:1")
  let assert Ok(store.Allow(_)) = store.access_for(app_store, "room:secret:1")
}

pub fn store_redeclaring_an_id_replaces_the_earlier_rule_test() {
  let app_store =
    test_support.topic_store_with([
      #("chat", store.Open),
      #("chat", store.Allow(fn(_, _, _) { False })),
    ])
  let assert Ok(store.Allow(_)) = store.access_for(app_store, "chat")
}

pub fn store_redeclaring_a_prefix_replaces_the_earlier_rule_test() {
  let app_store =
    test_support.topic_store_with([
      #("room:", store.Open),
      #("room:", store.Allow(fn(_, _, _) { False })),
    ])
  let assert Ok(store.Allow(_)) = store.access_for(app_store, "room:1")
}

// =============================================================================
// MATCHING
// =============================================================================

pub fn store_match_topic_picks_the_longest_prefix_test() {
  let entries = [
    #(store.IdPrefix("room:"), 1),
    #(store.IdPrefix("room:secret:"), 2),
    #(store.ExactId("chat"), 3),
  ]

  store.match_topic(entries, "room:secret:1", fn(entry) { entry.0 })
  |> should.equal(Ok(#(#(store.IdPrefix("room:secret:"), 2), "1")))
  store.match_topic(entries, "room:1", fn(entry) { entry.0 })
  |> should.equal(Ok(#(#(store.IdPrefix("room:"), 1), "1")))
  store.match_topic(entries, "lobby", fn(entry) { entry.0 })
  |> should.equal(Error(Nil))
}

pub fn store_match_topic_an_exact_id_has_an_empty_rest_test() {
  let entries = [#(store.IdPrefix("ch"), 1), #(store.ExactId("chat"), 2)]

  store.match_topic(entries, "chat", fn(entry) { entry.0 })
  |> should.equal(Ok(#(#(store.ExactId("chat"), 2), "")))
  store.match_topic(entries, "chatter", fn(entry) { entry.0 })
  |> should.equal(Ok(#(#(store.IdPrefix("ch"), 1), "atter")))
}
