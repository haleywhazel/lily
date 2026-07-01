// Round-trip tests for event.encode_message / event.decode_message, the
// reflection-codec pair stateless elements use to carry a typed message in a
// data-message attribute. Runs on both targets: the same client encodes (which
// caches the constructor) then decodes, so no register_types() is needed.

import gleeunit/should
import lily/event
import lily/test_fixtures.{type Message, Increment, SetName}

pub fn zero_field_message_round_trips_test() {
  event.decode_message(event.encode_message(Increment))
  |> should.equal(Ok(Increment))
}

pub fn value_carrying_message_round_trips_test() {
  let message: Message = SetName("Alice")
  event.decode_message(event.encode_message(message))
  |> should.equal(Ok(message))
}

pub fn decode_declines_a_readable_tag_test() {
  // A widget's readable tag must decline here so it composes with on_decoded
  // alongside readable-tag handlers.
  let decoded: Result(Message, Nil) =
    event.decode_message("lily-ui-switch:toggle")
  decoded
  |> should.equal(Error(Nil))
}
