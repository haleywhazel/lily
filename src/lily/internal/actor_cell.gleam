//// A minimal state cell over a typed event enum and a pure reducer, shared by
//// [`server`](../server.html) and [`topic`](../topic.html).
////
//// On Erlang the cell is an OTP actor. On JavaScript there is no actor, so it
//// is a mutable reference holding the state and the reducer, applied
//// synchronously in place, the same split the server and topic used to carry
//// by hand.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/option.{type Option}

@target(erlang)
import gleam/erlang/process.{type Subject}
@target(erlang)
import gleam/otp/actor
@target(erlang)
import gleam/result

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Outcome of reducing one event. `Continue` carries the next state, `Reply`
/// also answers a synchronous [`call`](#call), `Halt` stops the cell (cleanup
/// runs inside the reducer first).
pub type Reduction(state, reply) {
  Continue(state)
  Reply(state, reply)
  Halt(state)
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@target(erlang)
@internal
pub opaque type Cell(state, event, reply) {
  Cell(subject: Subject(Envelope(event, reply)))
}

@target(javascript)
@internal
pub opaque type Cell(state, event, reply) {
  Cell(runner: Reference(Option(Runner(state, event, reply))))
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

// Ceiling in milliseconds for a synchronous call to the Erlang actor. A stuck
// reducer surfaces as a timeout rather than blocking the caller forever.
@target(erlang)
const call_timeout_milliseconds = 5000

@target(erlang)
/// Synchronously send `event`, returning the reducer's `Reply` value or
/// `default` when the cell has stopped or the event does not reply. Erlang
/// blocks on the actor, JavaScript applies the reducer in place.
@internal
pub fn call(
  cell: Cell(state, event, reply),
  event: event,
  default _default: reply,
) -> reply {
  process.call(cell.subject, call_timeout_milliseconds, fn(reply_to) {
    Sync(event:, reply_to:)
  })
}

@target(javascript)
@internal
pub fn call(
  cell: Cell(state, event, reply),
  event: event,
  default default: reply,
) -> reply {
  case get(cell.runner) {
    option.None -> default
    option.Some(runner) ->
      case runner.reduce(event, runner.state) {
        Continue(state) -> {
          set(cell.runner, option.Some(Runner(..runner, state:)))
          default
        }
        Reply(state, reply) -> {
          set(cell.runner, option.Some(Runner(..runner, state:)))
          reply
        }
        Halt(_) -> {
          set(cell.runner, option.None)
          default
        }
      }
  }
}

@target(erlang)
/// Asynchronously send `event`. The reducer returns `Continue` or `Halt`.
@internal
pub fn send(cell: Cell(state, event, reply), event: event) -> Nil {
  actor.send(cell.subject, Cast(event:))
}

@target(javascript)
@internal
pub fn send(cell: Cell(state, event, reply), event: event) -> Nil {
  case get(cell.runner) {
    option.None -> Nil
    option.Some(runner) ->
      case runner.reduce(event, runner.state) {
        Continue(state) | Reply(state, _) ->
          set(cell.runner, option.Some(Runner(..runner, state:)))
        Halt(_) -> set(cell.runner, option.None)
      }
  }
}

@target(erlang)
/// Start a cell with an initial state and a pure reducer.
@internal
pub fn start(
  initial: state,
  reduce reduce: fn(event, state) -> Reduction(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  actor.new(Runner(state: initial, reduce:))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Cell(subject: started.data) })
  |> result.replace_error(Nil)
}

@target(javascript)
@internal
pub fn start(
  initial: state,
  reduce reduce: fn(event, state) -> Reduction(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  Ok(Cell(runner: make(option.Some(Runner(state: initial, reduce:)))))
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(erlang)
type Envelope(event, reply) {
  Cast(event: event)
  Sync(event: event, reply_to: Subject(reply))
}

// JavaScript-only mutable box holding the Cell's state, since there is no
// actor to hold it.
@target(javascript)
type Reference(value)

type Runner(state, event, reply) {
  Runner(state: state, reduce: fn(event, state) -> Reduction(state, reply))
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(erlang)
fn handle(
  runner: Runner(state, event, reply),
  envelope: Envelope(event, reply),
) -> actor.Next(Runner(state, event, reply), Envelope(event, reply)) {
  let #(event, reply_to) = case envelope {
    Cast(event:) -> #(event, option.None)
    Sync(event:, reply_to:) -> #(event, option.Some(reply_to))
  }
  case runner.reduce(event, runner.state) {
    Continue(state) -> actor.continue(Runner(..runner, state:))
    Reply(state, reply) -> {
      reply_to_caller(reply_to, reply)
      actor.continue(Runner(..runner, state:))
    }
    Halt(_) -> actor.stop()
  }
}

@target(erlang)
fn reply_to_caller(reply_to: Option(Subject(reply)), reply: reply) -> Nil {
  case reply_to {
    option.Some(subject) -> process.send(subject, reply)
    option.None -> Nil
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./actor_cell.ffi.mjs", "get")
fn get(reference: Reference(value)) -> value

@target(javascript)
@external(javascript, "./actor_cell.ffi.mjs", "make")
fn make(value: value) -> Reference(value)

@target(javascript)
@external(javascript, "./actor_cell.ffi.mjs", "set")
fn set(reference: Reference(value), value: value) -> Nil
