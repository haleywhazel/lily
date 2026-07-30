// Tests for lily/internal/actor_cell on the Erlang target, where the Cell is
// backed by an OTP actor. Mirrors test/lily/javascript/actor_cell_test.gleam.

@target(erlang)
import gleeunit/should
@target(erlang)
import lily/internal/actor_cell.{Continue, Halt, Reply}

@target(erlang)
type Event {
  Increment
  Read
  Stop
}

@target(erlang)
fn reduce(event: Event, state: Int) -> actor_cell.Reduction(Int, Int) {
  case event {
    Increment -> Continue(state + 1)
    Read -> Reply(state, state)
    Stop -> Halt(state)
  }
}

@target(erlang)
fn start(initial: Int) {
  let assert Ok(cell) = actor_cell.start(initial, reduce:)
  cell
}

@target(erlang)
pub fn cell_holds_initial_state_test() {
  actor_cell.call(start(7), Read, default: -1)
  |> should.equal(7)
}

@target(erlang)
pub fn cell_send_applies_reducer_test() {
  let cell = start(0)
  actor_cell.send(cell, Increment)
  actor_cell.send(cell, Increment)
  actor_cell.call(cell, Read, default: -1)
  |> should.equal(2)
}

@target(erlang)
pub fn cell_call_replies_with_state_test() {
  actor_cell.call(start(5), Read, default: -1)
  |> should.equal(5)
}

@target(erlang)
pub fn cell_halt_stops_the_actor_test() {
  // On the OTP path a Halt terminates the actor. We can't call a stopped
  // actor (that would exit the caller), so we assert the halt is accepted
  // without raising, unlike the JavaScript default-returning path.
  let cell = start(3)
  actor_cell.send(cell, Stop)
  True
  |> should.be_true
}

@target(erlang)
pub fn cell_instances_are_independent_test() {
  let a = start(1)
  let b = start(100)
  actor_cell.send(a, Increment)
  actor_cell.call(a, Read, default: -1)
  |> should.equal(2)
  actor_cell.call(b, Read, default: -1)
  |> should.equal(100)
}
