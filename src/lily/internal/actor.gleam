//// Cells, reducers over a typed event backing the server and topics. An OTP
//// actor on Erlang, a mutable ref on JavaScript. Also rescue and logging.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}
import gleam/result
import lily/transport.{type Level}

@target(javascript)
import gleam/list

@target(erlang)
import gleam/dict.{type Dict}
@target(erlang)
import gleam/otp/actor
@target(erlang)
import gleam/otp/factory_supervisor
@target(erlang)
import gleam/otp/supervision

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@target(javascript)
@internal
pub type Box(value)

@target(erlang)
@internal
pub opaque type Cell(state, event, reply) {
  Cell(subject: process.Subject(Envelope(event, reply)), pid: Pid)
}

@target(javascript)
@internal
pub opaque type Cell(state, event, reply) {
  Cell(
    runner: Box(Option(Runner(state, event, reply))),
    draining: Box(Bool),
    queue: Box(List(event)),
  )
}

@target(erlang)
/// Keeps a handle valid across a restart.
@internal
pub opaque type CellName(event, reply) {
  CellName(name: process.Name(Envelope(event, reply)))
}

@target(javascript)
@internal
pub type CellName(event, reply)

/// Only `Reply` answers a [`call`](#call).
@internal
pub type Outcome(state, reply) {
  Continue(state)
  Reply(state, reply)
  Halt(state)
}

@target(erlang)
@internal
pub opaque type Supervisor {
  NoSupervisor
  Supervisor(factory: factory_supervisor.Supervisor(ChildStart, Pid), pid: Pid)
}

@target(javascript)
@internal
pub opaque type Supervisor {
  NoSupervisor
}

/// Events sent to `cell` during `initial` are reduced first.
@internal
pub type Toolkit(state, event, reply) {
  Toolkit(cell: Cell(state, event, reply), supervisor: Supervisor)
}

@target(erlang)
@internal
pub opaque type Watched {
  Watched(pid: Pid)
}

@target(javascript)
@internal
pub opaque type Watched {
  Watched
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@target(erlang)
const call_timeout_milliseconds = 5000

@target(javascript)
@external(javascript, "./actor.ffi.mjs", "boxGet")
@internal
pub fn box_get(box: Box(value)) -> value

@target(javascript)
@external(javascript, "./actor.ffi.mjs", "boxNew")
@internal
pub fn box_new(value: value) -> Box(value)

@target(javascript)
@external(javascript, "./actor.ffi.mjs", "boxSet")
@internal
pub fn box_set(box: Box(value), value: value) -> Nil

@target(erlang)
/// Raises on Erlang if the cell is gone, meaning callers must rescue it.
/// JavaScript returns `default`, also when called mid-reduction.
@internal
pub fn call(
  cell: Cell(state, event, reply),
  event: event,
  default _default: reply,
) -> reply {
  process.call(cell.subject, call_timeout_milliseconds, fn(reply_to) {
    Call(event:, reply_to:)
  })
}

@target(javascript)
@internal
pub fn call(
  cell: Cell(state, event, reply),
  event: event,
  default default: reply,
) -> reply {
  case box_get(cell.draining) {
    True -> {
      log(
        transport.Warning,
        "lily: call into a cell that is mid-reduction, returned its default",
      )
      default
    }
    False -> option.unwrap(run(cell, event), default)
  }
}

@internal
pub fn log(level: Level, message: String) -> Nil {
  do_log(level, message)
}

@target(erlang)
/// Leaks an atom, meaning it should be called once at startup, never in a
/// loop or restart path.
@internal
pub fn new_name(prefix: String) -> CellName(event, reply) {
  CellName(name: process.new_name(prefix))
}

@external(erlang, "lily_actor_ffi", "rescue")
@external(javascript, "./actor.ffi.mjs", "rescue")
@internal
pub fn rescue(operation: fn() -> value) -> Result(value, String)

@internal
pub fn rescue_or(
  label: String,
  default: value,
  operation: fn() -> value,
) -> value {
  case rescue(operation) {
    Ok(value) -> value
    Error(reason) -> {
      log(transport.Failure, "lily: " <> label <> " crashed: " <> reason)
      default
    }
  }
}

/// `False` means the send raised, leaving the client to be dropped rather
/// than retried.
@internal
pub fn rescue_send(
  label: String,
  send: fn(BitArray) -> Nil,
  frame: BitArray,
) -> Bool {
  case rescue(fn() { send(frame) }) {
    Ok(Nil) -> True
    Error(reason) -> {
      log(transport.Failure, "lily: " <> label <> " send crashed: " <> reason)
      False
    }
  }
}

@target(erlang)
@internal
pub fn send(cell: Cell(state, event, reply), event: event) -> Nil {
  actor.send(cell.subject, Cast(event:))
}

@target(javascript)
@internal
pub fn send(cell: Cell(state, event, reply), event: event) -> Nil {
  case box_get(cell.draining) {
    True -> box_set(cell.queue, [event, ..box_get(cell.queue)])
    False -> {
      let _ = run(cell, event)
      Nil
    }
  }
}

@target(erlang)
@internal
pub fn start_in_supervisor(
  supervisor: Supervisor,
  initial: fn(Toolkit(state, event, reply)) -> state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  let on_down = fn(_) { option.None }
  case supervisor {
    NoSupervisor -> start_seeded(initial, reduce:, on_down:)
    Supervisor(factory:, ..) -> {
      let reply_to = process.new_subject()
      let child = fn() {
        start_linked(initial, reduce, on_down, False, option.None)
        |> result.map(fn(cell) {
          process.send(reply_to, cell)
          cell.pid
        })
      }
      case factory_supervisor.start_child(factory, child) {
        Error(_) -> Error(Nil)
        Ok(_) -> process.receive(reply_to, within: call_timeout_milliseconds)
      }
    }
  }
}

@target(javascript)
@internal
pub fn start_in_supervisor(
  _supervisor: Supervisor,
  initial: fn(Toolkit(state, event, reply)) -> state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  start_seeded(initial, reduce:, on_down: fn(_) { option.None })
}

/// Unlinked, keeping a crashing cell from taking the caller down.
@internal
pub fn start_seeded(
  initial: fn(Toolkit(state, event, reply)) -> state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down on_down: fn(String) -> Option(event),
) -> Result(Cell(state, event, reply), Nil) {
  start_linked(initial, reduce, on_down, False, option.None)
  |> result.map(unlinked)
}

@target(erlang)
/// Stays linked, the link is how a parent supervisor sees it die.
@internal
pub fn start_with_supervisor(
  initial: fn(Toolkit(state, event, reply)) -> state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down on_down: fn(String) -> Option(event),
  name name: CellName(event, reply),
) -> Result(Cell(state, event, reply), Nil) {
  start_linked(initial, reduce, on_down, True, option.Some(name))
}

@target(erlang)
@internal
pub fn supervisor_pid(supervisor: Supervisor) -> Option(Pid) {
  case supervisor {
    NoSupervisor -> option.None
    Supervisor(pid:, ..) -> option.Some(pid)
  }
}

@target(erlang)
/// Also flushes a death message already in flight.
@internal
pub fn unwatch(cell: Cell(state, event, reply), key: String) -> Nil {
  actor.send(cell.subject, Unwatch(key:))
}

@target(javascript)
@internal
pub fn unwatch(_cell: Cell(state, event, reply), _key: String) -> Nil {
  Nil
}

@target(erlang)
/// Watching a key twice replaces the earlier watch.
@internal
pub fn watch(
  cell: Cell(state, event, reply),
  key: String,
  watched: Watched,
) -> Nil {
  actor.send(cell.subject, Watch(key:, watched:))
}

@target(javascript)
@internal
pub fn watch(
  _cell: Cell(state, event, reply),
  _key: String,
  _watched: Watched,
) -> Nil {
  Nil
}

@target(erlang)
@internal
pub fn watched(cell: Cell(state, event, reply)) -> Watched {
  // a named cell outlives its boot pid, making the current owner the one to ask
  case process.subject_owner(cell.subject) {
    Ok(pid) -> Watched(pid:)
    Error(Nil) -> Watched(pid: cell.pid)
  }
}

@target(javascript)
@internal
pub fn watched(_cell: Cell(state, event, reply)) -> Watched {
  Watched
}

@target(erlang)
@internal
pub fn watched_from(pid: Pid) -> Watched {
  Watched(pid:)
}

@target(javascript)
@internal
pub fn watched_from(_pid: Pid) -> Watched {
  Watched
}

@target(erlang)
/// Call at the call site, never in a reducer, since watching is async.
@internal
pub fn watched_here() -> Watched {
  Watched(pid: process.self())
}

@target(javascript)
@internal
pub fn watched_here() -> Watched {
  Watched
}

@target(erlang)
@internal
pub fn watched_pid(watched: Watched) -> Pid {
  watched.pid
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(erlang)
type ChildStart =
  fn() -> Result(Pid, Nil)

@target(erlang)
type Envelope(event, reply) {
  Call(event: event, reply_to: process.Subject(reply))
  Cast(event: event)
  Down(down: process.Down)
  Unwatch(key: String)
  Watch(key: String, watched: Watched)
}

@target(erlang)
type Runner(state, event, reply) {
  Runner(
    state: state,
    reduce: fn(event, state) -> Outcome(state, reply),
    on_down: fn(String) -> Option(event),
    keys: Dict(process.Monitor, String),
    monitors: Dict(String, process.Monitor),
  )
}

@target(javascript)
type Runner(state, event, reply) {
  Runner(state: state, reduce: fn(event, state) -> Outcome(state, reply))
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(erlang)
fn add_watch(
  runner: Runner(state, event, reply),
  key: String,
  watched: Watched,
) -> Runner(state, event, reply) {
  let runner = drop_watch(runner, key)
  let monitor = process.monitor(watched.pid)
  Runner(
    ..runner,
    keys: dict.insert(runner.keys, monitor, key),
    monitors: dict.insert(runner.monitors, key, monitor),
  )
}

@target(erlang)
fn apply_event(
  runner: Runner(state, event, reply),
  event: event,
  reply_to: Option(process.Subject(reply)),
) -> actor.Next(Runner(state, event, reply), Envelope(event, reply)) {
  case runner.reduce(event, runner.state) {
    Continue(state) -> actor.continue(Runner(..runner, state:))
    Reply(state, reply) -> {
      reply_to_caller(reply_to, reply)
      actor.continue(Runner(..runner, state:))
    }
    Halt(_) -> actor.stop()
  }
}

@target(javascript)
fn apply_event(cell: Cell(state, event, reply), event: event) -> Option(reply) {
  case box_get(cell.runner) {
    option.None -> option.None
    option.Some(runner) ->
      case runner.reduce(event, runner.state) {
        Continue(state) -> {
          box_set(cell.runner, option.Some(Runner(..runner, state:)))
          option.None
        }
        Reply(state, reply) -> {
          box_set(cell.runner, option.Some(Runner(..runner, state:)))
          option.Some(reply)
        }
        Halt(_) -> {
          box_set(cell.runner, option.None)
          option.None
        }
      }
  }
}

// `actor.selecting` replaces the default selector, meaning the subject is
// re-added
@target(erlang)
fn cell_selector(
  subject: process.Subject(Envelope(event, reply)),
) -> process.Selector(Envelope(event, reply)) {
  process.new_selector()
  |> process.select(subject)
  |> process.select_monitors(Down)
}

@target(erlang)
fn do_log(level: Level, message: String) -> Nil {
  ffi_log(level, message)
}

@target(javascript)
fn do_log(level: Level, message: String) -> Nil {
  let method = case level {
    transport.Failure -> "error"
    transport.Warning -> "warn"
  }
  ffi_log(method, message)
}

@target(erlang)
fn drop_watch(
  runner: Runner(state, event, reply),
  key: String,
) -> Runner(state, event, reply) {
  case dict.get(runner.monitors, key) {
    Error(_) -> runner
    Ok(monitor) -> {
      // also flushes an in-flight death message
      process.demonitor_process(monitor:)
      Runner(
        ..runner,
        keys: dict.delete(runner.keys, monitor),
        monitors: dict.delete(runner.monitors, key),
      )
    }
  }
}

@target(erlang)
fn handle(
  runner: Runner(state, event, reply),
  envelope: Envelope(event, reply),
) -> actor.Next(Runner(state, event, reply), Envelope(event, reply)) {
  case envelope {
    Call(event:, reply_to:) -> apply_event(runner, event, option.Some(reply_to))
    Cast(event:) -> apply_event(runner, event, option.None)
    Down(down:) -> handle_down(runner, down)
    Unwatch(key:) -> actor.continue(drop_watch(runner, key))
    Watch(key:, watched:) -> actor.continue(add_watch(runner, key, watched))
  }
}

@target(erlang)
fn handle_down(
  runner: Runner(state, event, reply),
  down: process.Down,
) -> actor.Next(Runner(state, event, reply), Envelope(event, reply)) {
  case dict.get(runner.keys, down.monitor) {
    Error(_) -> actor.continue(runner)
    Ok(key) -> {
      // drop_watch owns the paired delete so the dicts can't drift, and
      // demonitoring a fired monitor is a no-op
      let runner = drop_watch(runner, key)
      case runner.on_down(key) {
        option.None -> actor.continue(runner)
        option.Some(event) -> apply_event(runner, event, option.None)
      }
    }
  }
}

@target(erlang)
fn reply_to_caller(
  reply_to: Option(process.Subject(reply)),
  reply: reply,
) -> Nil {
  case reply_to {
    option.Some(subject) -> process.send(subject, reply)
    option.None -> Nil
  }
}

// sends from a reducer queue, flag resets on throw so a bad event can't wedge
@target(javascript)
fn run(cell: Cell(state, event, reply), event: event) -> Option(reply) {
  box_set(cell.draining, True)
  protect(
    fn() {
      let reply = apply_event(cell, event)
      run_queue(cell)
      reply
    },
    fn() {
      box_set(cell.draining, False)
      box_set(cell.queue, [])
    },
  )
}

@target(javascript)
fn run_queue(cell: Cell(state, event, reply)) -> Nil {
  case box_get(cell.queue) {
    [] -> Nil
    queued -> {
      box_set(cell.queue, [])
      list.each(list.reverse(queued), fn(event) {
        let _ = apply_event(cell, event)
        Nil
      })
      run_queue(cell)
    }
  }
}

@target(erlang)
fn start_linked(
  initial: fn(Toolkit(state, event, reply)) -> state,
  reduce: fn(event, state) -> Outcome(state, reply),
  on_down: fn(String) -> Option(event),
  supervised: Bool,
  name: Option(CellName(event, reply)),
) -> Result(Cell(state, event, reply), Nil) {
  let builder =
    actor.new_with_initialiser(call_timeout_milliseconds, fn(subject) {
      case start_supervisor(supervised) {
        Error(Nil) -> Error("lily: supervisor failed to start")
        Ok(supervisor) -> {
          let cell = Cell(subject:, pid: process.self())
          let runner =
            Runner(
              state: initial(Toolkit(cell:, supervisor:)),
              reduce:,
              on_down:,
              keys: dict.new(),
              monitors: dict.new(),
            )
          actor.initialised(runner)
          |> actor.selecting(cell_selector(subject))
          |> actor.returning(cell)
          |> Ok
        }
      }
    })
    |> actor.on_message(handle)
  // named subject, callers reach whoever holds the name now
  let builder = case name {
    option.Some(CellName(name:)) -> actor.named(builder, name)
    option.None -> builder
  }
  case actor.start(builder) {
    Error(_) -> Error(Nil)
    Ok(started) -> Ok(started.data)
  }
}

// sends from `initial` queue until the first state exists
@target(javascript)
fn start_linked(
  initial: fn(Toolkit(state, event, reply)) -> state,
  reduce: fn(event, state) -> Outcome(state, reply),
  _on_down: fn(String) -> Option(event),
  _supervised: Bool,
  _name: Option(CellName(event, reply)),
) -> Result(Cell(state, event, reply), Nil) {
  let cell =
    Cell(
      runner: box_new(option.None),
      draining: box_new(True),
      queue: box_new([]),
    )
  protect(
    fn() {
      let state = initial(Toolkit(cell:, supervisor: NoSupervisor))
      box_set(cell.runner, option.Some(Runner(state:, reduce:)))
      run_queue(cell)
    },
    fn() {
      box_set(cell.draining, False)
      box_set(cell.queue, [])
    },
  )
  Ok(cell)
}

@target(erlang)
fn start_supervisor(supervised: Bool) -> Result(Supervisor, Nil) {
  case supervised {
    False -> Ok(NoSupervisor)
    True -> {
      let builder =
        factory_supervisor.worker_child(template)
        |> factory_supervisor.restart_strategy(supervision.Temporary)
      case factory_supervisor.start(builder) {
        Error(_) -> Error(Nil)
        Ok(started) -> Ok(Supervisor(factory: started.data, pid: started.pid))
      }
    }
  }
}

@target(erlang)
fn template(child: ChildStart) -> actor.StartResult(Pid) {
  case child() {
    Ok(pid) -> Ok(actor.Started(pid:, data: pid))
    Error(_) -> Error(actor.InitFailed("lily: child cell failed to start"))
  }
}

@target(erlang)
fn unlinked(cell: Cell(state, event, reply)) -> Cell(state, event, reply) {
  process.unlink(cell.pid)
  cell
}

@target(javascript)
fn unlinked(cell: Cell(state, event, reply)) -> Cell(state, event, reply) {
  cell
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(erlang)
@external(erlang, "lily_actor_ffi", "log")
fn ffi_log(level: Level, message: String) -> Nil

@target(javascript)
@external(javascript, "./actor.ffi.mjs", "log")
fn ffi_log(level: String, message: String) -> Nil

@target(javascript)
@external(javascript, "./actor.ffi.mjs", "protect")
fn protect(operation: fn() -> value, cleanup: fn() -> Nil) -> value
