// Tests for server.rescue. Runs on both targets. The combinator must turn a
// runtime crash into Error rather than propagating it, which is what keeps one
// malformed client frame from dropping the shared server actor.

import gleeunit/should
import lily/server

pub fn rescue_returns_ok_on_success_test() {
  server.rescue(fn() { 1 + 1 })
  |> should.equal(Ok(2))
}

pub fn rescue_captures_panic_as_error_test() {
  server.rescue(fn() { panic as "boom" })
  |> should.be_error
}
