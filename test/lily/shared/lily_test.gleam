// Tests for lily — Store type, new, and apply. Pure, target-agnostic.

import gleeunit/should
import lily
import lily/test_fixtures.{Decrement, Increment, SetName}

// =============================================================================
// CONSTRUCTION
// =============================================================================

pub fn lily_new_has_initial_model_test() {
  let s = lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  s.model
  |> should.equal(test_fixtures.initial_model())
}

pub fn lily_new_retains_update_function_test() {
  let s = lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  let updated = s.update(s.model, Increment)
  updated.count
  |> should.equal(1)
}

// =============================================================================
// APPLY (internal)
// =============================================================================

pub fn apply_multiple_messages_test() {
  lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> lily.apply(message: Increment)
  |> lily.apply(message: Increment)
  |> lily.apply(message: Increment)
  |> fn(s) { s.model.count }
  |> should.equal(3)
}

pub fn apply_updates_model_test() {
  lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> lily.apply(message: Increment)
  |> fn(s) { s.model.count }
  |> should.equal(1)
}

pub fn apply_with_different_messages_test() {
  let s =
    lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> lily.apply(message: Increment)
    |> lily.apply(message: SetName("Alice"))
    |> lily.apply(message: Decrement)
  s.model.count
  |> should.equal(0)
  s.model.name
  |> should.equal("Alice")
}
