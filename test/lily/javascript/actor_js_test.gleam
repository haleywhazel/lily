// halted actor cell on JS (a mutable reference) and log level to console
// method mapping, shared behaviour in test/lily/shared/actor_test.gleam

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/internal/actor.{Continue, Halt, Reply}
@target(javascript)
import lily/test_support
@target(javascript)
import lily/transport

@target(javascript)
type Event {
  Increment
  Read
  Stop
}

@target(javascript)
fn reduce(event: Event, state: Int) -> actor.CellOutcome(Int, Int) {
  case event {
    Increment -> Continue(state + 1)
    Read -> Reply(state, state)
    Stop -> Halt(state)
  }
}

@target(javascript)
pub fn cell_halt_stops_and_returns_default_test() {
  let assert Ok(cell) = actor.start_seeded(fn(_) { 3 }, reduce:)

  actor.send(cell, Stop)

  actor.call(cell, Read, default: -1)
  |> should.equal(-1)
  actor.send(cell, Increment)
  actor.call(cell, Read, default: -1)
  |> should.equal(-1)
}

@target(javascript)
pub fn log_each_level_reaches_the_matching_console_method_test() {
  let emit = fn() {
    actor.log(transport.Warning, "w")
    actor.log(transport.Failure, "e")
  }

  let captured = test_support.capture_log_levels(emit)

  captured
  |> should.equal([#("warn", "w"), #("error", "e")])
}
