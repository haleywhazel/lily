// Tests for lily/logging, auto_* inspect family (target-agnostic).

import gleam/option
import gleam/string
import gleeunit/should
import lily/logging

// =============================================================================
// AUTO_LOG SMOKE TESTS
// =============================================================================

pub fn logging_auto_log_does_not_crash_test() {
  logging.auto_log(logging.Info, "simple string")
  logging.auto_log(logging.Debug, 42)
  logging.auto_log(logging.Warning, #("tuple", 1))
  True
  |> should.be_true
}

pub fn logging_all_auto_levels_do_not_crash_test() {
  logging.auto_log(logging.Alert, "test")
  logging.auto_log(logging.Critical, "test")
  logging.auto_log(logging.Debug, "test")
  logging.auto_log(logging.Emergency, "test")
  logging.auto_log(logging.Error, "test")
  logging.auto_log(logging.Info, "test")
  logging.auto_log(logging.Notice, "test")
  logging.auto_log(logging.Warning, "test")
  True
  |> should.be_true
}

// =============================================================================
// INSPECT FORMAT
// =============================================================================

pub fn logging_auto_log_uses_string_inspect_test() {
  // auto_log calls string.inspect internally, verify the format it would use
  string.inspect(Nil)
  |> should.equal("Nil")
}

pub fn logging_auto_log_inspect_formats_string_test() {
  string.inspect("hello")
  |> should.equal("\"hello\"")
}

pub fn logging_auto_log_inspect_formats_int_test() {
  string.inspect(42)
  |> should.equal("42")
}

// =============================================================================
// IS ENABLED (reflects configured level)
// =============================================================================

pub fn logging_is_enabled_at_configured_level_test() {
  logging.set_level(logging.Warning)
  logging.is_enabled(logging.Warning)
  |> should.be_true
}

pub fn logging_is_enabled_more_severe_than_configured_test() {
  logging.set_level(logging.Warning)
  logging.is_enabled(logging.Error)
  |> should.be_true
}

pub fn logging_is_enabled_below_configured_is_false_test() {
  logging.set_level(logging.Warning)
  logging.is_enabled(logging.Debug)
  |> should.be_false
}

pub fn logging_is_enabled_debug_level_enables_everything_test() {
  logging.set_level(logging.Debug)
  logging.is_enabled(logging.Debug)
  |> should.be_true
}

pub fn logging_is_enabled_info_suppresses_debug_test() {
  logging.set_level(logging.Info)
  logging.is_enabled(logging.Debug)
  |> should.be_false
}

pub fn logging_is_enabled_restore_info_default_test() {
  logging.set_level(logging.Info)
  logging.is_enabled(logging.Info)
  |> should.be_true
}

// =============================================================================
// REQUEST (compact request log line)
// =============================================================================

pub fn logging_request_ok_does_not_crash_test() {
  logging.set_level(logging.Debug)
  logging.request(logging.RequestLog(
    method: "GET",
    path: "/controls",
    status: 200,
    duration_milliseconds: 12,
    request_id: option.None,
  ))
  True
  |> should.be_true
}

pub fn logging_request_with_request_id_does_not_crash_test() {
  logging.set_level(logging.Debug)
  logging.request(logging.RequestLog(
    method: "POST",
    path: "/save",
    status: 500,
    duration_milliseconds: 3,
    request_id: option.Some("abc"),
  ))
  True
  |> should.be_true
}

pub fn logging_request_suppressed_level_does_not_crash_test() {
  logging.set_level(logging.Error)
  logging.request(logging.RequestLog(
    method: "GET",
    path: "/",
    status: 200,
    duration_milliseconds: 1,
    request_id: option.None,
  ))
  logging.set_level(logging.Info)
  True
  |> should.be_true
}
