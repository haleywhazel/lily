//// A minimal state cell over a typed event enum and a pure reducer, shared by
//// [`server`](../server.html) and [`topic`](../topic.html).
////
//// On Erlang the cell is an OTP actor. On JavaScript there is no actor, so it
//// is a mutable reference holding the state and the reducer, applied
//// synchronously in place, the same split the server and topic used to carry
//// by hand.
////
//// A cell can also watch other processes. On Erlang
//// [`watch`](#watch) monitors a pid under a caller-chosen key and feeds the
//// reducer whatever event `on_down` returns when that process dies, so a
//// dead connection or a dead topic becomes an ordinary event. On JavaScript
//// there are no processes, so the whole watch surface is inert.
////
//// A cell can also own a [`Supervisor`](#Supervisor), a `factory_supervisor`
//// its child cells hang off, so a crashing child is contained by OTP rather
//// than by the process that happened to start it. It is created inside the
//// owning cell's own initialiser, which links the two, so the supervisor and
//// every child in it go down with the owner and come back with it. On
//// JavaScript a `Supervisor` carries nothing and children start as plain
//// cells.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/option.{type Option}

@target(erlang)
import gleam/dict.{type Dict}
@target(erlang)
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
@target(erlang)
import gleam/otp/actor
@target(erlang)
import gleam/otp/factory_supervisor
@target(erlang)
import gleam/otp/supervision

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Outcome of reducing one event. `Continue` carries the next state, `Reply`
/// also answers a synchronous [`call`](#call), `Halt` stops the cell (cleanup
/// runs inside the reducer first).
pub type Outcome(state, reply) {
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
  Cell(subject: Subject(Envelope(event, reply)), pid: Pid)
}

@target(javascript)
@internal
pub opaque type Cell(state, event, reply) {
  Cell(runner: Box(Option(Runner(state, event, reply))))
}

@target(erlang)
/// A `factory_supervisor` that child cells hang off. `NoSupervisor` is the
/// unsupervised case, where a child is started as a plain linked-then-unlinked
/// cell exactly as before.
@internal
pub opaque type Supervisor {
  NoSupervisor
  Supervisor(factory: factory_supervisor.Supervisor(ChildStart, Pid), pid: Pid)
}

@target(javascript)
/// A supervisor that child cells hang off. JavaScript has no processes, so
/// this carries nothing and children always start as plain cells.
@internal
pub opaque type Supervisor {
  NoSupervisor
}

@target(erlang)
/// A process a cell can watch, identified by its pid on Erlang.
@internal
pub opaque type Watched {
  Watched(pid: Pid)
}

@target(javascript)
/// A process a cell can watch. JavaScript has no processes, so this carries
/// nothing and every watch operation is a no-op.
@internal
pub opaque type Watched {
  Watched
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
  apply_event(cell, event)
  |> option.unwrap(default)
}

/// The inert supervisor, for a cell started outside any supervision tree. Child
/// cells started against it are plain cells.
///
/// ```gleam
/// let supervisor = actor_cell.no_supervisor()
/// ```
@internal
pub fn no_supervisor() -> Supervisor {
  NoSupervisor
}

@target(erlang)
/// The process running `supervisor`, or `None` when it is inert. For tests that
/// need to assert the supervisor came down with its owner.
///
/// ```gleam
/// let assert Some(pid) = actor_cell.supervisor_pid(supervisor)
/// ```
@internal
pub fn supervisor_pid(supervisor: Supervisor) -> Option(Pid) {
  case supervisor {
    NoSupervisor -> option.None
    Supervisor(pid:, ..) -> option.Some(pid)
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
  let _ = apply_event(cell, event)
  Nil
}

/// Start a cell with an initial state and a pure reducer, watching nothing.
///
/// ```gleam
/// let cell = actor_cell.start(0, reduce:)
/// ```
@internal
pub fn start(
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  start_watching(initial, reduce:, on_down: fn(_) { option.None })
}

@target(erlang)
/// Start a cell as a child of `supervisor`, or as a plain cell when the
/// supervisor is inert. A supervised child stays linked to the supervisor, so
/// a crash is contained there rather than reaching whoever asked for the child.
///
/// The supervisor's child type is monomorphic, so the generic cell never
/// crosses it. The child argument is a closure that starts the cell and
/// reports it back over a channel this function owns, and the only thing the
/// supervisor ever sees is a pid.
///
/// ```gleam
/// let cell = actor_cell.start_in_supervisor(supervisor, 0, reduce:)
/// ```
@internal
pub fn start_in_supervisor(
  supervisor: Supervisor,
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  case supervisor {
    NoSupervisor -> start(initial, reduce:)
    Supervisor(factory:, ..) -> {
      let reply_to = process.new_subject()
      let child = fn() {
        case start_linked(initial, reduce:, on_down: fn(_) { option.None }) {
          Error(_) -> Error(Nil)
          Ok(cell) -> {
            process.send(reply_to, cell)
            Ok(cell.pid)
          }
        }
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
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
) -> Result(Cell(state, event, reply), Nil) {
  start(initial, reduce:)
}

@target(erlang)
/// Start a cell that can watch other processes. When a watched process dies,
/// `on_down` is called with the key it was watched under and any event it
/// returns is fed to `reduce`, exactly as if it had been sent.
///
/// ```gleam
/// actor_cell.start_watching(state, reduce:, on_down: fn(k) { Some(Gone(k)) })
/// ```
@internal
pub fn start_watching(
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down on_down: fn(String) -> Option(event),
) -> Result(Cell(state, event, reply), Nil) {
  case start_linked(initial, reduce:, on_down:) {
    Error(_) -> Error(Nil)
    Ok(cell) -> {
      // `actor.start` spawn-links, so a crashing cell would take its starter
      // down with it. Lily stops every cell explicitly, so the link buys
      // nothing and costs the whole server.
      process.unlink(cell.pid)
      Ok(cell)
    }
  }
}

@target(javascript)
@internal
pub fn start_watching(
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down _on_down: fn(String) -> Option(event),
) -> Result(Cell(state, event, reply), Nil) {
  Ok(Cell(runner: make(option.Some(Runner(state: initial, reduce:)))))
}

@target(erlang)
/// Start a cell that owns a [`Supervisor`](#Supervisor) for its own child
/// cells. The supervisor is started inside the cell's initialiser, so the two
/// are linked and the supervisor goes down with the cell and comes back with
/// it.
///
/// Unlike [`start_watching`](#start_watching) the cell stays linked to
/// whatever started it, because this is the supervised path and the link is
/// how a supervisor learns the cell died.
///
/// ```gleam
/// let assert Ok(#(cell, supervisor)) =
///   actor_cell.start_with_supervisor(state, reduce:, on_down:)
/// ```
@internal
pub fn start_with_supervisor(
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down on_down: fn(String) -> Option(event),
) -> Result(#(Cell(state, event, reply), Supervisor), Nil) {
  let runner = new_runner(initial, reduce, on_down)
  let builder =
    actor.new_with_initialiser(call_timeout_milliseconds, fn(subject) {
      case start_supervisor() {
        Error(_) -> Error("lily: supervisor failed to start")
        Ok(supervisor) ->
          actor.initialised(runner)
          |> actor.selecting(cell_selector(subject))
          |> actor.returning(#(subject, supervisor))
          |> Ok
      }
    })
    |> actor.on_message(handle)
  case actor.start(builder) {
    Error(_) -> Error(Nil)
    Ok(started) -> {
      let #(subject, supervisor) = started.data
      Ok(#(Cell(subject:, pid: started.pid), supervisor))
    }
  }
}

@target(javascript)
@internal
pub fn start_with_supervisor(
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down on_down: fn(String) -> Option(event),
) -> Result(#(Cell(state, event, reply), Supervisor), Nil) {
  case start_watching(initial, reduce:, on_down:) {
    Error(_) -> Error(Nil)
    Ok(cell) -> Ok(#(cell, NoSupervisor))
  }
}

@target(erlang)
/// Stop watching whatever was registered under `key`, flushing any death
/// message already in flight. Unknown keys are ignored.
///
/// ```gleam
/// actor_cell.unwatch(cell, "abc")
/// ```
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
/// Watch `watched` under `key`. When it dies the cell's `on_down` runs with
/// `key`. Watching a key twice replaces the earlier watch.
///
/// ```gleam
/// actor_cell.watch(cell, "abc", actor_cell.watched_here())
/// ```
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
/// The process running `cell`, so one cell can watch another.
///
/// ```gleam
/// actor_cell.watch(server, "topic:chat", actor_cell.watched(topic))
/// ```
@internal
pub fn watched(cell: Cell(state, event, reply)) -> Watched {
  Watched(pid: cell.pid)
}

@target(javascript)
@internal
pub fn watched(_cell: Cell(state, event, reply)) -> Watched {
  Watched
}

@target(erlang)
/// The calling process. Evaluate this at the call site, never inside a
/// reducer, since the watch itself is asynchronous.
///
/// ```gleam
/// actor_cell.watch(cell, client_id, actor_cell.watched_here())
/// ```
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
/// The pid behind a `Watched`, for tests that need to kill it directly.
///
/// ```gleam
/// process.kill(actor_cell.watched_pid(watched))
/// ```
@internal
pub fn watched_pid(watched: Watched) -> Pid {
  watched.pid
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(erlang)
type Envelope(event, reply) {
  Call(event: event, reply_to: Subject(reply))
  Cast(event: event)
  Down(down: process.Down)
  Unwatch(key: String)
  Watch(key: String, watched: Watched)
}

// Type for supervisor child.
@target(erlang)
type ChildStart =
  fn() -> Result(Pid, Nil)

// JavaScript-only mutable box holding the Cell's state, since there is no
// actor to hold it.
@target(javascript)
type Box(value)

@target(erlang)
type Runner(state, event, reply) {
  Runner(
    state: state,
    reduce: fn(event, state) -> Outcome(state, reply),
    on_down: fn(String) -> Option(event),
    keys: Dict(Monitor, String),
    monitors: Dict(String, Monitor),
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
  reply_to: Option(Subject(reply)),
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

// Apply one event to the reducer in place, storing the next state and handing
// back a `Reply` value if there was one. `call` and `send` differ only in what
// they do with it.
@target(javascript)
fn apply_event(cell: Cell(state, event, reply), event: event) -> Option(reply) {
  case get(cell.runner) {
    option.None -> option.None
    option.Some(runner) ->
      case runner.reduce(event, runner.state) {
        Continue(state) -> {
          set(cell.runner, option.Some(Runner(..runner, state:)))
          option.None
        }
        Reply(state, reply) -> {
          set(cell.runner, option.Some(Runner(..runner, state:)))
          option.Some(reply)
        }
        Halt(_) -> {
          set(cell.runner, option.None)
          option.None
        }
      }
  }
}

// `actor.selecting` replaces the default selector, so the cell's own subject
// has to be put back or no event would ever arrive.
@target(erlang)
fn cell_selector(
  subject: Subject(Envelope(event, reply)),
) -> process.Selector(Envelope(event, reply)) {
  process.new_selector()
  |> process.select(subject)
  |> process.select_monitors(Down)
}

@target(erlang)
fn drop_watch(
  runner: Runner(state, event, reply),
  key: String,
) -> Runner(state, event, reply) {
  case dict.get(runner.monitors, key) {
    Error(_) -> runner
    Ok(monitor) -> {
      // also flushes a death message already sitting in the mailbox
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
      // `drop_watch` owns the paired delete, so the two dicts cannot drift.
      // Demonitoring a monitor that has already fired is a no-op.
      let runner = drop_watch(runner, key)
      case runner.on_down(key) {
        option.None -> actor.continue(runner)
        option.Some(event) -> apply_event(runner, event, option.None)
      }
    }
  }
}

@target(erlang)
fn new_runner(
  initial: state,
  reduce: fn(event, state) -> Outcome(state, reply),
  on_down: fn(String) -> Option(event),
) -> Runner(state, event, reply) {
  Runner(
    state: initial,
    reduce:,
    on_down:,
    keys: dict.new(),
    monitors: dict.new(),
  )
}

@target(erlang)
fn reply_to_caller(reply_to: Option(Subject(reply)), reply: reply) -> Nil {
  case reply_to {
    option.Some(subject) -> process.send(subject, reply)
    option.None -> Nil
  }
}

@target(erlang)
/// Start a cell and leave it linked to the calling process. Every public start
/// path goes through this and then decides whether to keep the link.
fn start_linked(
  initial: state,
  reduce reduce: fn(event, state) -> Outcome(state, reply),
  on_down on_down: fn(String) -> Option(event),
) -> Result(Cell(state, event, reply), Nil) {
  let runner = new_runner(initial, reduce, on_down)
  let builder =
    actor.new_with_initialiser(call_timeout_milliseconds, fn(subject) {
      actor.initialised(runner)
      |> actor.selecting(cell_selector(subject))
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
  case actor.start(builder) {
    Error(_) -> Error(Nil)
    Ok(started) -> Ok(Cell(subject: started.data, pid: started.pid))
  }
}

@target(erlang)
/// Start the `factory_supervisor` child cells hang off.
fn start_supervisor() -> Result(Supervisor, Nil) {
  let builder =
    factory_supervisor.worker_child(template)
    |> factory_supervisor.restart_strategy(supervision.Temporary)
  case factory_supervisor.start(builder) {
    Error(_) -> Error(Nil)
    Ok(started) -> Ok(Supervisor(factory: started.data, pid: started.pid))
  }
}

@target(erlang)
/// The supervisor's one child template.
fn template(child: ChildStart) -> actor.StartResult(Pid) {
  case child() {
    Ok(pid) -> Ok(actor.Started(pid:, data: pid))
    Error(_) -> Error(actor.InitFailed("lily: child cell failed to start"))
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./actor_cell.ffi.mjs", "get")
fn get(box: Box(value)) -> value

@target(javascript)
@external(javascript, "./actor_cell.ffi.mjs", "make")
fn make(value: value) -> Box(value)

@target(javascript)
@external(javascript, "./actor_cell.ffi.mjs", "set")
fn set(box: Box(value), value: value) -> Nil
