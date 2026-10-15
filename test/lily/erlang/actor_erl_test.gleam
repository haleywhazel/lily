// halted actor cell on Erlang (an OTP actor) and log level to logger level
// mapping, shared behaviour in test/lily/shared/actor_test.gleam

@target(erlang)
import gleam/option
@target(erlang)
import gleeunit/should
@target(erlang)
import lily/internal/actor.{Halt}
@target(erlang)
import lily/test_support
@target(erlang)
import lily/transport
@target(erlang)
import lily/wire_support

@target(erlang)
type Event {
  Stop
}

@target(erlang)
fn reduce(event: Event, state: Int) -> actor.Outcome(Int, Nil) {
  case event {
    Stop -> Halt(state)
  }
}

@target(erlang)
pub fn cell_halt_stops_the_actor_test() {
  let assert Ok(cell) =
    actor.start_seeded(fn(_) { 3 }, reduce:, on_down: fn(_) { option.None })
  let pid = actor.watched_pid(actor.watched(cell))

  actor.send(cell, Stop)

  wire_support.await_down(pid)
}

@target(erlang)
pub fn log_each_level_reaches_the_matching_logger_level_test() {
  let emit = fn() {
    actor.log(transport.Warning, "w")
    actor.log(transport.Failure, "e")
  }

  let captured = test_support.capture_log_levels(emit)

  captured
  |> should.equal([#("warning", "w"), #("error", "e")])
}
