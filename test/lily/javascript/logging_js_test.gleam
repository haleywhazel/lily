// Tests for lily/logging on JavaScript — set_level filtering.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/logging

// =============================================================================
// SET LEVEL
// =============================================================================

@target(javascript)
pub fn logging_set_level_does_not_crash_test() {
  logging.set_level(logging.Warning)
  logging.set_level(logging.Debug)
  logging.set_level(logging.Info)
  True
  |> should.be_true
}

@target(javascript)
pub fn logging_configure_does_not_crash_test() {
  let _ = logging.configure()
  True
  |> should.be_true
}

@target(javascript)
pub fn logging_log_does_not_crash_test() {
  logging.log(logging.Info, "test message")
  logging.log(logging.Warning, "warning message")
  logging.log(logging.Debug, "debug message")
  True
  |> should.be_true
}
