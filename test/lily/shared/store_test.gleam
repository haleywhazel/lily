// Tests for lily/store, Store type, new, and apply. Pure, target-agnostic.

import gleeunit/should
import lily/store
import lily/test_fixtures.{Decrement, Increment, SetName}

// =============================================================================
// CONSTRUCTION
// =============================================================================

pub fn store_new_has_initial_model_test() {
  let s = store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  store.get_model(s)
  |> should.equal(test_fixtures.initial_model())
}

pub fn store_new_retains_update_function_test() {
  let s =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> store.apply(message: Increment)
  store.get_model(s).count
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
  |> store.get_model
  |> fn(model) { model.count }
  |> should.equal(3)
}

pub fn store_apply_updates_model_test() {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> store.apply(message: Increment)
  |> store.get_model
  |> fn(model) { model.count }
  |> should.equal(1)
}

pub fn store_apply_with_different_messages_test() {
  let model =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> store.apply(message: Increment)
    |> store.apply(message: SetName("Alice"))
    |> store.apply(message: Decrement)
    |> store.get_model
  model.count
  |> should.equal(0)
  model.name
  |> should.equal("Alice")
}

// =============================================================================
// LOCAL
// =============================================================================

pub fn unwrap_local_returns_inner_value_test() {
  store.Local("hello")
  |> store.unwrap_local
  |> should.equal("hello")
}

pub fn unwrap_local_with_integer_test() {
  store.Local(42)
  |> store.unwrap_local
  |> should.equal(42)
}

pub fn unwrap_local_nested_unwraps_one_level_test() {
  // unwrap_local unwraps exactly one layer, the result is still a Local.
  store.Local(store.Local(99))
  |> store.unwrap_local
  |> should.equal(store.Local(99))
}
