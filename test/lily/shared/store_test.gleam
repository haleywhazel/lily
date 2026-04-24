// Tests for lily/store — Store type, new, and apply. Pure, target-agnostic.

import gleeunit/should
import lily/store
import lily/test_fixtures.{Decrement, Increment, SetName}

// =============================================================================
// CONSTRUCTION
// =============================================================================

pub fn store_new_has_initial_model_test() {
  let s = store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  s.model
  |> should.equal(test_fixtures.initial_model())
}

pub fn store_new_retains_update_function_test() {
  let s = store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  let updated = s.update(s.model, Increment)
  updated.count
  |> should.equal(1)
}

// =============================================================================
// APPLY (internal)
// =============================================================================

pub fn store_apply_multiple_messages_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.apply(message: Increment)
  |> store.apply(message: Increment)
  |> store.apply(message: Increment)
  |> fn(s) { s.model.count }
  |> should.equal(3)
}

pub fn store_apply_updates_model_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.apply(message: Increment)
  |> fn(s) { s.model.count }
  |> should.equal(1)
}

pub fn store_apply_with_different_messages_test() {
  let s =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> store.apply(message: Increment)
    |> store.apply(message: SetName("Alice"))
    |> store.apply(message: Decrement)
  s.model.count
  |> should.equal(0)
  s.model.name
  |> should.equal("Alice")
}
