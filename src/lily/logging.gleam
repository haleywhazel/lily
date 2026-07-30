//// Logging that reads the same on both runtimes. Erlang already has a solid
//// [`logging`](https://hex.pm/packages/logging) package (the same one `mist`
//// and `wisp` log through), JavaScript has the `console`, and Lily runs on
//// both, so this module papers over the gap and hands you one API that
//// behaves identically whether you're on the BEAM or in a browser or Node.
////
//// On Erlang it's a thin wrapper over the `logging` package, so your lines
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
////   logging.log(logging.Info, "server ready")
////   logging.log(logging.Warning, "cache miss")
////   logging.log(logging.Error, "payment gateway timed out")
////   logging.log(logging.Debug, "dropped while the level is Info")
//// }
//// ```
////
//// [`auto_log`](#auto_log) logs any value with `string.inspect`, skipping the
//// work when the level is suppressed.
////
//// For an HTTP server you probably want one compact line per request.
//// Build a [`RequestLog`](#RequestLog) and emit it with [`request`](#request).
//// In a real backend that's a small
//// middleware that times the handler and mints a correlation id, sat behind
//// your static-file serving so only real routes get a line:
////
//// ```gleam
//// fn log_request(req: wisp.Request, handler) -> wisp.Response {
////   let start = timestamp.system_time()
////
////   // Reuse an inbound correlation id when a proxy set one, otherwise make
////   // one, so a request's log lines (and any downstream service's) tie
////   // together.
////   let request_id = case request.get_header(req, "x-request-id") {
////     Ok(id) -> id
////     Error(Nil) -> wisp.random_string(16)
////   }
////
////   let response = handler()
////
////   logging.RequestLog(
////     method: string.uppercase(http.method_to_string(req.method)),
////     path: req.path,
////     status: response.status,
////     duration_milliseconds: elapsed_milliseconds(start),
////     request_id: option.Some(request_id),
////   )
////   |> logging.request
////
////   // Echo the id back so clients and downstream services can correlate.
////   response.set_header(response, "x-request-id", request_id)
//// }
////
//// // wire it in behind static serving, so assets stay silent
//// use <- wisp.serve_static(req, under: "/", from: "priv/static")
//// use <- log_request(req)
//// ```
////
//// The level is read from the status (5xx `Error`, 4xx `Warning`, else
//// `Info`) so a failing route stands out by colour, and a
//// [`RequestLog`](#RequestLog) has nowhere to put a request or response body,
//// keeping secrets out of your logs.

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

/// A single HTTP request to log. `request_id` is an optional correlation id
/// that, when set, is echoed into the line as `#<id>`. Construct a
/// `RequestLog(...)` directly and emit it with [`request()`](#request).
///
/// Request and response bodies are deliberately absent. Logging them risks
/// leaking passwords, tokens, and other GDPR-protected data, so the transport
/// should never put them here.
pub type RequestLog {
  RequestLog(
    method: String,
    path: String,
    status: Int,
    duration_milliseconds: Int,
    request_id: option.Option(String),
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

/// Configure the default logger. On Erlang, this installs the `logging`
/// package's pretty formatter and sets the level to `Info`. On JavaScript,
/// this is a no-op, the console is always ready.
pub fn configure() -> Nil {
  do_configure()
}

/// Returns `True` if a message at `level` would be emitted by the current
/// logger configuration. Useful for guarding expensive payload construction
/// outside [`auto_log`](#auto_log).
///
/// ```gleam
/// case logging.is_enabled(logging.Debug) {
///   True -> logging.log(logging.Debug, expensive_dump(state))
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

/// Emit a compact request log line through the same sink as the other
/// helpers, so it inherits the level tag and colour. The level comes from the
/// status (5xx is `Error`, 4xx is `Warning`, everything else `Info`), so a
/// failing route stands out. Suppressed levels short-circuit before the line
/// is built.
///
/// ```gleam
/// logging.RequestLog(
///   method: "GET",
///   path: "/controls",
///   status: 200,
///   duration_milliseconds: 12,
///   request_id: option.Some(request_id),
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

/// Set the minimum level of log messages to emit. Messages below this level
/// are suppressed.
///
/// On Erlang, delegates to `logger:set_primary_config`. On JavaScript,
/// maintains a module-level threshold, useful on Node/Bun/Deno servers where
/// DevTools is not available.
pub fn set_level(level: Level) -> Nil {
  do_set_level(level)
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
