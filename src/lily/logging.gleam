//// Logging that reads the same on both runtimes. Erlang already has a solid
//// [`logging`](https://hex.pm/packages/logging) package (the same one `mist`
//// and `wisp` log through), JavaScript has the `console`, and Lily runs on
//// both, so this module papers over the gap and hands you one API that
//// behaves identically whether you're on the BEAM or in a browser or Node.
////
//// On Erlang it's a thin wrapper over that `logging` package, so your lines
//// blend in with the framework's own output. On JavaScript they go to
//// `console.error` / `console.warn` / `console.info` / `console.debug` by
//// level, wearing the same colour palette the Erlang package uses so the two
//// look the same side by side.
////
//// Call [`configure`](#configure) once at startup, optionally pick a minimum
//// level with [`set_level`](#set_level) (anything below it is dropped), then
//// log with the level shortcuts:
////
//// ```gleam
//// import lily/logging
////
//// pub fn main() {
////   logging.configure()
////   logging.set_level(logging.Info)
////
////   logging.info("server ready")
////   logging.warning("cache miss")
////   logging.error("payment gateway timed out")
////   logging.debug("dropped while the level is Info")
//// }
//// ```
////
//// From there, [`auto_info`](#auto_info) and its siblings log any value with
//// `string.inspect` (and skip the work when the level is suppressed), and
//// [`request`](#request) prints one compact line per HTTP request from a
//// [`RequestLog`](#RequestLog).

import gleam/int
import gleam/option
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

/// A single HTTP request to log. The four core fields are always present; the
/// rest are `option.None` until the transport fills them in. Build one with
/// [`request_log()`](#request_log) and emit it with [`request()`](#request).
///
/// Request and response bodies are deliberately absent: logging them risks
/// leaking passwords, tokens, and other GDPR-protected data, so the transport
/// should never put them here.
pub type RequestLog {
  RequestLog(
    method: String,
    path: String,
    status: Int,
    duration_milliseconds: Int,
    bytes: option.Option(Int),
    remote_ip: option.Option(String),
    request_id: option.Option(String),
    user_agent: option.Option(String),
  )
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
/// server.on_message(server, fn(message, _model, _client_id) {
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

/// Emit a compact request log line through the same sink as the other helpers,
/// so it inherits the level tag and colour. The level is derived from the
/// status (5xx is `Error`, 4xx is `Warning`, everything else `Info`), so a
/// failing route stands out by colour. Suppressed levels short-circuit before
/// the line is built.
///
/// ```gleam
/// logging.request_log(
///   method: "GET",
///   path: "/controls",
///   status: 200,
///   duration_milliseconds: 12,
/// )
/// |> logging.request
/// // Logs `INFO GET /controls 200 in 12ms`
/// ```
pub fn request(entry: RequestLog) -> Nil {
  let level = level_for_status(entry.status)
  case is_enabled(level) {
    False -> Nil
    True -> do_log(level, request_pretty(entry))
  }
}

/// Build a [`RequestLog`](#RequestLog) from the four fields every transport
/// can supply, leaving the optional fields (`bytes`, `remote_ip`,
/// `request_id`, `user_agent`) as `option.None`. Set the extras with a record
/// update where the transport has them.
///
/// ```gleam
/// logging.request_log(method: "GET", path: "/", status: 200, duration_milliseconds: 3)
/// |> fn(entry) { logging.RequestLog(..entry, request_id: option.Some(id)) }
/// ```
pub fn request_log(
  method method: String,
  path path: String,
  status status: Int,
  duration_milliseconds duration_milliseconds: Int,
) -> RequestLog {
  RequestLog(
    method:,
    path:,
    status:,
    duration_milliseconds:,
    bytes: option.None,
    remote_ip: option.None,
    request_id: option.None,
    user_agent: option.None,
  )
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

fn level_for_status(status: Int) -> Level {
  case status {
    status if status >= 500 -> Error
    status if status >= 400 -> Warning
    _ -> Info
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

fn request_pretty(entry: RequestLog) -> String {
  let line =
    entry.method
    <> " "
    <> entry.path
    <> " "
    <> int.to_string(entry.status)
    <> " in "
    <> int.to_string(entry.duration_milliseconds)
    <> "ms"
  case entry.request_id {
    option.Some(id) -> line <> " #" <> id
    option.None -> line
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
