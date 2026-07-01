//// Erlang has a perfectly good [`logging`](https://hex.pm/packages/logging)
//// package, JavaScript does not.
////
//// Lily runs on both runtimes, so this module creates a wrapper over the
//// available Erlang one while (through FFI) also does the JS one.
////
//// On Erlang, this is a thin wrapper around the `logging` hex package
//// (the same logger used by `mist` and `wisp`), so Lily log lines blend
//// in with framework logs.
////
//// On JavaScript, log lines go to `console.error` / `console.warn` /
//// `console.info` / `console.debug` by level, with the same colour palette
//// the Erlang package uses for consistency.
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
////   // Logs `INFO SomeMessage("hello")`:
////   logging.auto_info(SomeMessage("hello"))
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

/// Inspect `value` with `string.inspect` and log the result at the given level.
/// The inspection is skipped when the level is suppressed, so passing a large
/// model at `Debug` is cheap in production.
pub fn auto_log(level: Level, value: a) -> Nil {
  case is_enabled(level) {
    True -> do_log(level, string.inspect(value))
    False -> Nil
  }
}

/// Inspect `value` with `string.inspect` and log the result at `Debug` level.
pub fn auto_debug(value: a) -> Nil {
  auto_log(Debug, value)
}

/// Inspect `value` with `string.inspect` and log the result at `Error` level.
pub fn auto_error(value: a) -> Nil {
  auto_log(Error, value)
}

/// Inspect `value` with `string.inspect` and log the result at `Info` level.
/// This is probably used the most.
///
/// ```gleam
/// server.on_message(srv, fn(message, _model, _client_id) {
///   logging.auto_info(message)  // e.g. logs "INFO AddTodo(\"milk\")"
/// })
/// ```
pub fn auto_info(value: a) -> Nil {
  auto_log(Info, value)
}

/// Inspect `value` with `string.inspect` and log the result at `Warning` level.
pub fn auto_warning(value: a) -> Nil {
  auto_log(Warning, value)
}

/// Configure the default logger. On Erlang, this installs the `logging`
/// package's pretty formatter and sets the level to `Info`. On JavaScript,
/// this is a no-op, the console is always ready.
pub fn configure() -> Nil {
  do_configure()
}

/// Shortcut for `log(Debug, message)`.
pub fn debug(message: String) -> Nil {
  log(Debug, message)
}

/// Shortcut for `log(Error, message)`.
pub fn error(message: String) -> Nil {
  log(Error, message)
}

/// Shortcut for `log(Info, message)`.
pub fn info(message: String) -> Nil {
  log(Info, message)
}

/// Returns `True` if a message at `level` would be emitted by the current
/// logger configuration. Useful for guarding expensive payload construction
/// outside the `auto_*` helpers.
///
/// ```gleam
/// case logging.is_enabled(logging.Debug) {
///   True -> logging.debug(expensive_dump(state))
///   False -> Nil
/// }
/// ```
pub fn is_enabled(level: Level) -> Bool {
  do_is_enabled(level)
}

/// Log a message at the given level.
pub fn log(level: Level, message: String) -> Nil {
  do_log(level, message)
}

/// Set the minimum level of log messages to emit. Messages below this level
/// are suppressed.
///
/// On Erlang, delegates to `logger:set_primary_config`. On JavaScript,
/// maintains a module-level threshold, useful on Node/Bun/Deno servers where
/// DevTools is not available.
pub fn set_level(level: Level) -> Nil {
  do_set_level(level)
}

/// Shortcut for `log(Warning, message)`.
pub fn warning(message: String) -> Nil {
  log(Warning, message)
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
fn do_is_enabled(level: Level) -> Bool {
  ffi_level_enabled(to_erlang_level(level))
}

@target(javascript)
fn do_is_enabled(level: Level) -> Bool {
  ffi_is_enabled(level_severity(level))
}

@target(erlang)
fn do_log(level: Level, message: String) -> Nil {
  erlang_logging.log(to_erlang_level(level), message)
}

@target(javascript)
fn do_log(level: Level, message: String) -> Nil {
  ffi_log(level_severity(level), message)
}

@target(erlang)
fn do_set_level(level: Level) -> Nil {
  erlang_logging.set_level(to_erlang_level(level))
}

@target(javascript)
fn do_set_level(level: Level) -> Nil {
  ffi_set_level(level_severity(level))
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
@external(javascript, "./logging.ffi.mjs", "isEnabled")
fn ffi_is_enabled(_severity: Int) -> Bool {
  True
}

@target(erlang)
@external(erlang, "lily_logging_ffi", "level_enabled")
fn ffi_level_enabled(_level: erlang_logging.LogLevel) -> Bool {
  True
}

@target(javascript)
@external(javascript, "./logging.ffi.mjs", "log")
fn ffi_log(_severity: Int, _message: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./logging.ffi.mjs", "setLevel")
fn ffi_set_level(_severity: Int) -> Nil {
  Nil
}
