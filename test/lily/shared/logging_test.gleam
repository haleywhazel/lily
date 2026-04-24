// Tests for lily/logging — auto_* inspect family (target-agnostic).

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
  logging.auto_alert("test")
  logging.auto_critical("test")
  logging.auto_debug("test")
  logging.auto_emergency("test")
  logging.auto_error("test")
  logging.auto_info("test")
  logging.auto_notice("test")
  logging.auto_warning("test")
  True
  |> should.be_true
}

// =============================================================================
// INSPECT FORMAT
// =============================================================================

pub fn logging_auto_log_uses_string_inspect_test() {
  // auto_log calls string.inspect internally — verify the format it would use
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
