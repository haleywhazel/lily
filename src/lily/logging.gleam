//// While the there is a logging package for Erlang, there isn't one for JS,
//// and since I've decided that the backend should also work on the JS target
//// for some reason, this module is essentially a wrapper around the logging
//// package for the Erlang target, alongside a JS version that aims to provide
//// the exact same results.
////
//// See [`logging`](https://hex.pm/packages/logging) for more information, it's
//// the same hex package (the same logger used by `mist` and `wisp`) so log
//// lines work cleanly with framework logs. On JavaScript, log lines are
//// written to `console.error` / `console.warn` / `console.info` /
//// `console.debug` by level, along with the colours used for the Erlang
//// package. This works identically in browsers, Node, Bun, and Deno.
////
//// On Erlang, `configure` installs the `logging` package's formatter and
//// `set_level` sets the minimum level. On JavaScript, `configure` is a no-op
//// and `set_level` maintains a programmatic level filter.
////
//// ```gleam
//// import lily/logging
////
//// pub fn main() {
////   logging.configure()
////   logging.set_level(logging.Info)
////   logging.info("server ready")
////   logging.auto_info(SomeMessage("hello"))  // logs "INFO SomeMessage(\"hello\")"
//// }
//// ```

import gleam/string
@target(erlang)
import logging as erlang_logging

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Log severity. Matches the eight levels used by Erlang's `logger` and the
/// `logging` hex package.
pub type Level {
  Alert
  Critical
  Debug
  Emergency
  Error
  Info
  Notice
  Warning
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Shortcut for `log(Alert, message)`.
pub fn alert(message: String) -> Nil {
  do_log(Alert, message)
}

/// Inspect `value` with `string.inspect` and log the result at `Alert` level.
pub fn auto_alert(value: a) -> Nil {
  do_log(Alert, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Critical`
/// level.
pub fn auto_critical(value: a) -> Nil {
  do_log(Critical, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Debug` level.
pub fn auto_debug(value: a) -> Nil {
  do_log(Debug, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Emergency`
/// level.
pub fn auto_emergency(value: a) -> Nil {
  do_log(Emergency, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Error` level.
pub fn auto_error(value: a) -> Nil {
  do_log(Error, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Info` level.
/// This is probably used the most.
///
/// ```gleam
/// server.on_message(srv, fn(msg, _model, _client_id) {
///   logging.auto_info(msg)  // e.g. logs "INFO AddTodo(\"milk\")"
/// })
/// ```
pub fn auto_info(value: a) -> Nil {
  do_log(Info, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at the given level.
pub fn auto_log(level: Level, value: a) -> Nil {
  do_log(level, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Notice` level.
pub fn auto_notice(value: a) -> Nil {
  do_log(Notice, string.inspect(value))
}

/// Inspect `value` with `string.inspect` and log the result at `Warning` level.
pub fn auto_warning(value: a) -> Nil {
  do_log(Warning, string.inspect(value))
}

/// Configure the default logger. On Erlang, this installs the `logging`
/// package's pretty formatter and sets the level to `Info`. On JavaScript,
/// this is a no-op — the console is always ready.
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

/// Set the minimum level of log messages to emit. Messages below this level
/// are suppressed.
///
/// On Erlang, delegates to `logger:set_primary_config`. On JavaScript,
/// maintains a module-level threshold — useful on Node/Bun/Deno servers where
/// DevTools is not available.
pub fn set_level(level: Level) -> Nil {
  do_set_level(level)
}

/// Shortcut for `log(Warning, message)`.
pub fn warning(message: String) -> Nil {
  do_log(Warning, message)
}

// =============================================================================
// PRIVATE HELPERS
// =============================================================================

@target(javascript)
fn level_code(level: Level) -> String {
  case level {
    Alert -> "ALRT"
    Critical -> "CRIT"
    Debug -> "DEBG"
    Emergency -> "EMRG"
    Error -> "EROR"
    Info -> "INFO"
    Notice -> "NTCE"
    Warning -> "WARN"
  }
}

@target(javascript)
fn level_severity(level: Level) -> Int {
  case level {
    Emergency -> 0
    Alert -> 1
    Critical -> 2
    Error -> 3
    Warning -> 4
    Notice -> 5
    Info -> 6
    Debug -> 7
  }
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
  ffi_log(level_code(level), level_severity(level), message)
}

@target(erlang)
fn do_set_level(level: Level) -> Nil {
  erlang_logging.set_level(to_erlang_level(level))
}

@target(javascript)
fn do_set_level(level: Level) -> Nil {
  ffi_set_level(level_severity(level))
}

@target(erlang)
fn to_erlang_level(level: Level) -> erlang_logging.LogLevel {
  case level {
    Alert -> erlang_logging.Alert
    Critical -> erlang_logging.Critical
    Debug -> erlang_logging.Debug
    Emergency -> erlang_logging.Emergency
    Error -> erlang_logging.Error
    Info -> erlang_logging.Info
    Notice -> erlang_logging.Notice
    Warning -> erlang_logging.Warning
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./logging.ffi.mjs", "log")
fn ffi_log(_level_code: String, _level_severity: Int, _message: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./logging.ffi.mjs", "setLevel")
fn ffi_set_level(_severity: Int) -> Nil {
  Nil
}
