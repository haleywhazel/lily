// Tests for lily/internal/reference, the JS-only mutable cell used as the
// state container for server.gleam and topic.gleam on JavaScript.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/internal/reference

@target(javascript)
pub fn reference_make_holds_initial_value_test() {
  let cell = reference.make(42)
  reference.get(cell)
  |> should.equal(42)
}

@target(javascript)
pub fn reference_set_replaces_value_test() {
  let cell = reference.make(0)
  reference.set(cell, 100)
  reference.get(cell)
  |> should.equal(100)
}

@target(javascript)
pub fn reference_set_multiple_times_test() {
  let cell = reference.make("first")
  reference.set(cell, "second")
  reference.set(cell, "third")
  reference.get(cell)
  |> should.equal("third")
}

@target(javascript)
pub fn reference_holds_strings_test() {
  let cell = reference.make("hello")
  reference.get(cell)
  |> should.equal("hello")
}

@target(javascript)
pub fn reference_holds_lists_test() {
  let cell = reference.make([1, 2, 3])
  reference.get(cell)
  |> should.equal([1, 2, 3])

  reference.set(cell, [4, 5])
  reference.get(cell)
  |> should.equal([4, 5])
}

@target(javascript)
pub fn reference_holds_tuples_test() {
  let cell = reference.make(#("a", 1))
  reference.get(cell)
  |> should.equal(#("a", 1))

  reference.set(cell, #("b", 2))
  reference.get(cell)
  |> should.equal(#("b", 2))
}

@target(javascript)
pub fn reference_independent_cells_test() {
  let cell_a = reference.make(1)
  let cell_b = reference.make(2)
  reference.set(cell_a, 10)
  reference.get(cell_a)
  |> should.equal(10)
  reference.get(cell_b)
  |> should.equal(2)
}

@target(javascript)
pub fn reference_holds_option_test() {
  let cell = reference.make(Ok(5))
  reference.get(cell)
  |> should.equal(Ok(5))

  reference.set(cell, Error(Nil))
  reference.get(cell)
  |> should.equal(Error(Nil))
}
