// Tests for lily/store — pure, target-agnostic.
// Handler invocation is tested indirectly via test_ref to avoid process imports.

import gleam/dict
import gleeunit/should
import lily/store
import lily/test_fixtures.{Decrement, Increment, SetName}
import lily/test_ref

// =============================================================================
// CONSTRUCTION
// =============================================================================

pub fn new_store_has_initial_model_test() {
  let test_store =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  test_store.model
  |> should.equal(test_fixtures.initial_model())
}

pub fn new_store_has_empty_handlers_test() {
  let test_store =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  test_store.handlers
  |> dict.size
  |> should.equal(0)
}

pub fn new_store_retains_update_function_test() {
  let test_store =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  // Apply via the update fn directly and verify it produces expected model
  let updated = test_store.update(test_store.model, Increment)
  updated.count
  |> should.equal(1)
}

// =============================================================================
// SUBSCRIBE
// =============================================================================

pub fn subscribe_adds_handler_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> fn(subscribed) { subscribed.handlers }
  |> dict.size
  |> should.equal(1)
}

pub fn subscribe_multiple_selectors_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.subscribe(selector: "#sidebar", with: fn(_model) { Nil })
  |> fn(subscribed) { subscribed.handlers }
  |> dict.size
  |> should.equal(2)
}

pub fn subscribe_same_selector_replaces_handler_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> fn(subscribed) { subscribed.handlers }
  |> dict.size
  |> should.equal(1)
}

pub fn subscribe_preserves_model_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> fn(subscribed) { subscribed.model }
  |> should.equal(test_fixtures.initial_model())
}

pub fn subscribe_preserves_other_handlers_test() {
  // #app replaced, #header preserved → still 2 handlers
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.subscribe(selector: "#header", with: fn(_model) { Nil })
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> fn(subscribed) { subscribed.handlers }
  |> dict.size
  |> should.equal(2)
}

// =============================================================================
// UNSUBSCRIBE
// =============================================================================

pub fn unsubscribe_removes_handler_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.unsubscribe("#app")
  |> fn(unsubscribed) { unsubscribed.handlers }
  |> dict.size
  |> should.equal(0)
}

pub fn unsubscribe_nonexistent_selector_is_noop_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.unsubscribe("#nonexistent")
  |> fn(unsubscribed) { unsubscribed.handlers }
  |> dict.size
  |> should.equal(0)
}

pub fn unsubscribe_preserves_other_handlers_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.subscribe(selector: "#sidebar", with: fn(_model) { Nil })
  |> store.unsubscribe("#app")
  |> fn(unsubscribed) { unsubscribed.handlers }
  |> dict.size
  |> should.equal(1)
}

pub fn unsubscribe_preserves_model_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.unsubscribe("#app")
  |> fn(unsubscribed) { unsubscribed.model }
  |> should.equal(test_fixtures.initial_model())
}

// =============================================================================
// APPLY (internal)
// =============================================================================

pub fn apply_updates_model_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.apply(message: Increment)
  |> fn(applied) { applied.model.count }
  |> should.equal(1)
}

pub fn apply_multiple_messages_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.apply(message: Increment)
  |> store.apply(message: Increment)
  |> store.apply(message: Increment)
  |> fn(applied) { applied.model.count }
  |> should.equal(3)
}

pub fn apply_with_different_messages_test() {
  let applied =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> store.apply(message: Increment)
    |> store.apply(message: SetName("Alice"))
    |> store.apply(message: Decrement)
  applied.model.count
  |> should.equal(0)
  applied.model.name
  |> should.equal("Alice")
}

pub fn apply_preserves_handlers_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#app", with: fn(_model) { Nil })
  |> store.apply(message: Increment)
  |> fn(applied) { applied.handlers }
  |> dict.size
  |> should.equal(1)
}

// =============================================================================
// NOTIFY (internal)
// =============================================================================

pub fn notify_calls_all_handlers_test() {
  let ref = test_ref.new(0)
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.subscribe(selector: "#a", with: fn(_model) {
    test_ref.set(ref, test_ref.get(ref) + 1)
  })
  |> store.subscribe(selector: "#b", with: fn(_model) {
    test_ref.set(ref, test_ref.get(ref) + 1)
  })
  |> store.notify
  test_ref.get(ref)
  |> should.equal(2)
}

pub fn notify_with_no_handlers_does_not_crash_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.notify
  // No crash — test passes
  True
  |> should.be_true
}
