//// Structured logging for lily apps. Works on both Erlang (server) and
//// JavaScript (client) targets. The output format is identical on both:
//// a four-character level code (`INFO`, `EROR`, `WARN`, etc.), a space, then
//// the message.
////
//// On Erlang, this delegates to the [`logging`](https://hex.pm/packages/logging)
//// hex package (the same logger used by `mist` and `wisp`) so log lines
//// interleave cleanly with framework logs. On JavaScript, log lines are
//// written to the browser console, routed to `console.error` / `console.warn`
//// / `console.info` / `console.debug` by level so DevTools colour them
//// appropriately. `configure` and `set_level` are no-ops on JavaScript —
//// browser DevTools has its own verbosity filter, and `Debug` is hidden by
//// default in Chrome and Firefox.
////
//// ```gleam
//// import lily/logging
////
//// pub fn main() {
////   logging.configure()
////   logging.info("server ready")
////   logging.error("something went wrong")
//// }
//// ```

@target(erlang)
import logging as erlang_logging

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Log severity. Matches the eight levels used by Erlang's `logger` and the
/// `logging` hex package.
pub type Level {
  Emergency
  Alert
  Critical
  Error
  Warning
  Notice
  Info
  Debug
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Shortcut for `log(Alert, message)`.
pub fn alert(message: String) -> Nil {
  do_log(Alert, message)
}

/// Configure the default logger. On Erlang, this installs the `logging`
/// package's pretty formatter and sets the level to `Info`. On JavaScript,
/// this is a no-op — use browser DevTools' own verbosity filter instead.
pub fn configure() -> Nil {
  do_configure()
}

/// Shortcut for `log(Critical, message)`.
pub fn critical(message: String) -> Nil {
  do_log(Critical, message)
}

/// Shortcut for `log(Debug, message)`.
pub fn debug(message: String) -> Nil {
  do_log(Debug, message)
}

/// Shortcut for `log(Emergency, message)`.
pub fn emergency(message: String) -> Nil {
  do_log(Emergency, message)
}

/// Shortcut for `log(Error, message)`.
pub fn error(message: String) -> Nil {
  do_log(Error, message)
}

/// Shortcut for `log(Info, message)`.
pub fn info(message: String) -> Nil {
  do_log(Info, message)
}

/// Log a message at the given level.
pub fn log(level: Level, message: String) -> Nil {
  do_log(level, message)
}

/// Shortcut for `log(Notice, message)`.
pub fn notice(message: String) -> Nil {
  do_log(Notice, message)
}

/// Set the minimum level of log messages to emit. On Erlang, delegates to
/// `logger:set_primary_config`. On JavaScript, this is a no-op.
pub fn set_level(level: Level) -> Nil {
  do_set_level(level)
}

/// Shortcut for `log(Warning, message)`.
pub fn warning(message: String) -> Nil {
  do_log(Warning, message)
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(erlang)
fn do_configure() -> Nil {
  erlang_logging.configure()
}

@target(javascript)
fn do_configure() -> Nil {
  Nil
}

@target(erlang)
fn do_log(level: Level, message: String) -> Nil {
  erlang_logging.log(to_erlang_level(level), message)
}

@target(javascript)
fn do_log(level: Level, message: String) -> Nil {
  ffi_log(level_code(level), message)
}

@target(erlang)
fn do_set_level(level: Level) -> Nil {
  erlang_logging.set_level(to_erlang_level(level))
}

@target(javascript)
fn do_set_level(_level: Level) -> Nil {
  Nil
}

@target(javascript)
fn level_code(level: Level) -> String {
  case level {
    Emergency -> "EMRG"
    Alert -> "ALRT"
    Critical -> "CRIT"
    Error -> "EROR"
    Warning -> "WARN"
    Notice -> "NTCE"
    Info -> "INFO"
    Debug -> "DEBG"
  }
}

@target(erlang)
fn to_erlang_level(level: Level) -> erlang_logging.LogLevel {
  case level {
    Emergency -> erlang_logging.Emergency
    Alert -> erlang_logging.Alert
    Critical -> erlang_logging.Critical
    Error -> erlang_logging.Error
    Warning -> erlang_logging.Warning
    Notice -> erlang_logging.Notice
    Info -> erlang_logging.Info
    Debug -> erlang_logging.Debug
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./logging.ffi.mjs", "log")
fn ffi_log(_level_code: String, _message: String) -> Nil {
  Nil
}
