// lily/event on both targets, data-message codec and inert SSR listeners

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/string
import gleeunit/should

import lily/component
import lily/event
import lily/test_support.{type Message, Increment, SetName}

// =============================================================================
// MESSAGE CODEC
// =============================================================================

pub fn event_encode_message_round_trips_test() {
  let encoded = event.encode_message(SetName("hi"))

  event.decode_message(encoded)
  |> should.equal(Ok(SetName("hi")))
}

pub fn event_encoded_messages_are_attribute_safe_test() {
  let encoded = event.encode_message(SetName("a \"quoted\" <tag> & more"))

  string.contains(encoded, "\"") |> should.be_false
  string.contains(encoded, "<") |> should.be_false
  string.contains(encoded, " ") |> should.be_false
}

pub fn event_decode_message_rejects_a_string_it_did_not_produce_test() {
  let decoded: Result(Message, Nil) = event.decode_message("increment")

  decoded |> should.equal(Error(Nil))
}

pub fn event_decode_message_rejects_a_corrupt_payload_test() {
  let decoded: Result(Message, Nil) = event.decode_message("lily-message:!!!")

  decoded |> should.equal(Error(Nil))
}

// =============================================================================
// RENDERING
// =============================================================================

pub fn event_listeners_do_not_change_server_rendered_markup_test() {
  let plain = fn(_) { component.static(fn(_) { "<button>go</button>" }) }
  let bound = fn(model) {
    plain(model)
    |> event.on_click(message: Increment, options: event.defaults)
  }
  let render = fn(view) {
    component.render_to_string(
      view:,
      model: test_support.initial_model(),
      to_html: test_support.to_html,
      from_string: fn(html) { html },
    )
  }

  render(bound) |> should.equal(render(plain))
}
