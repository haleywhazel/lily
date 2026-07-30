// Tests for lily/internal/actor_cell on the JavaScript target, where the Cell
// is backed by a mutable reference rather than an OTP actor.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/internal/actor_cell.{Continue, Halt, Reply}

@target(javascript)
type Event {
  Increment
  Read
  Stop
}

@target(javascript)
fn reduce(event: Event, state: Int) -> actor_cell.Reduction(Int, Int) {
  case event {
    Increment -> Continue(state + 1)
    Read -> Reply(state, state)
    Stop -> Halt(state)
  }
}

@target(javascript)
fn start(initial: Int) {
  let assert Ok(cell) = actor_cell.start(initial, reduce:)
  cell
}

@target(javascript)
pub fn cell_holds_initial_state_test() {
  actor_cell.call(start(7), Read, default: -1)
  |> should.equal(7)
}

@target(javascript)
pub fn cell_send_applies_reducer_test() {
  let cell = start(0)
  actor_cell.send(cell, Increment)
  actor_cell.send(cell, Increment)
  actor_cell.call(cell, Read, default: -1)
  |> should.equal(2)
}

@target(javascript)
pub fn cell_call_replies_with_state_test() {
  actor_cell.call(start(5), Read, default: -1)
  |> should.equal(5)
}

@target(javascript)
pub fn cell_halt_stops_and_returns_default_test() {
  let cell = start(3)
  actor_cell.send(cell, Stop)
  actor_cell.call(cell, Read, default: -1)
  |> should.equal(-1)
  actor_cell.send(cell, Increment)
  actor_cell.call(cell, Read, default: -1)
  |> should.equal(-1)
}

@target(javascript)
pub fn cell_instances_are_independent_test() {
  let a = start(1)
  let b = start(100)
  actor_cell.send(a, Increment)
  actor_cell.call(a, Read, default: -1)
  |> should.equal(2)
  actor_cell.call(b, Read, default: -1)
  |> should.equal(100)
}
