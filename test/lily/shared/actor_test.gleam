// lily/internal/actor, OTP actor on erlang, mutable ref on javascript
// halted cells and log level mapping differ, keeping them in target folders
// rescue must turn a crash into a value, one bad frame can't drop the server

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/option
import gleeunit/should
import lily/internal/actor.{type Cell, Continue, Reply}
import lily/test_support
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

type Event {
  Increment
  Read
}

fn reduce(event: Event, state: Int) -> actor.Outcome(Int, Int) {
  case event {
    Increment -> Continue(state + 1)
    Read -> Reply(state, state)
  }
}

fn start(initial: Int) -> Cell(Int, Event, Int) {
  let assert Ok(cell) =
    actor.start_seeded(fn(_) { initial }, reduce:, on_down: fn(_) {
      option.None
    })
  cell
}

type Relay {
  Bump
  BumpTwice
  Peek
}

/// A cell whose reducer sends to itself via its seeded state.
type RelayState {
  RelayState(own: Cell(RelayState, Relay, List(String)), log: List(String))
}

fn relay_cell() -> Cell(RelayState, Relay, List(String)) {
  let reduce = fn(event: Relay, state: RelayState) {
    case event {
      Bump -> Continue(RelayState(..state, log: ["bump", ..state.log]))
      BumpTwice -> {
        actor.send(state.own, Bump)
        actor.send(state.own, Bump)
        Continue(RelayState(..state, log: ["outer", ..state.log]))
      }
      Peek -> Reply(state, state.log)
    }
  }
  let assert Ok(cell) =
    actor.start_seeded(
      fn(toolkit) { RelayState(own: toolkit.cell, log: []) },
      reduce:,
      on_down: fn(_) { option.None },
    )
  cell
}

// =============================================================================
// CELL
// =============================================================================

pub fn cell_holds_initial_state_test() {
  actor.call(start(7), Read, default: -1)
  |> should.equal(7)
}

pub fn cell_send_applies_reducer_test() {
  let cell = start(0)

  actor.send(cell, Increment)
  actor.send(cell, Increment)

  actor.call(cell, Read, default: -1)
  |> should.equal(2)
}

pub fn cell_call_replies_with_state_test() {
  actor.call(start(5), Read, default: -1)
  |> should.equal(5)
}

pub fn cell_instances_are_independent_test() {
  let first = start(1)
  let second = start(100)

  actor.send(first, Increment)

  actor.call(first, Read, default: -1)
  |> should.equal(2)
  actor.call(second, Read, default: -1)
  |> should.equal(100)
}

pub fn cell_reentrant_send_runs_after_outer_commit_in_order_test() {
  let cell = relay_cell()

  actor.send(cell, BumpTwice)
  // reducer sends queue behind the pending call, only the second sees them
  let _ = actor.call(cell, Peek, default: [])

  actor.call(cell, Peek, default: [])
  |> should.equal(["bump", "bump", "outer"])
}

// =============================================================================
// LOG
// =============================================================================

pub fn log_writes_a_message_unchanged_test() {
  let line = "lily: dropped a frame, ünïcode and 100% intact ~p"

  let captured =
    test_support.capture_log_levels(fn() { actor.log(transport.Warning, line) })

  case captured {
    [#(_, message)] -> message
    _ -> ""
  }
  |> should.equal(line)
}

// =============================================================================
// RESCUE
// =============================================================================

pub fn rescue_returns_ok_on_success_test() {
  actor.rescue(fn() { 1 + 1 })
  |> should.equal(Ok(2))
}

pub fn rescue_captures_panic_as_error_test() {
  actor.rescue(fn() { panic as "boom" })
  |> should.be_error
}

pub fn rescue_or_returns_the_default_on_a_crash_test() {
  actor.rescue_or("test", 7, fn() { panic as "boom" })
  |> should.equal(7)
}

pub fn rescue_or_returns_the_value_on_success_test() {
  actor.rescue_or("test", 7, fn() { 1 })
  |> should.equal(1)
}

pub fn rescue_send_reports_a_crashing_send_test() {
  actor.rescue_send("test", fn(_) { panic as "gone" }, <<1>>)
  |> should.be_false
}

pub fn rescue_send_reports_a_working_send_test() {
  actor.rescue_send("test", fn(_) { Nil }, <<1>>)
  |> should.be_true
}
