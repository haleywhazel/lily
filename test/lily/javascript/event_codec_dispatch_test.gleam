// Regression tests for the codec-dispatch pattern lily_ui relies on: a child
// component slotted into a parent's render emits its typed message via
// event.encode_message, and a single decoder on the MOUNTED view recovers it
// with event.decode_message. This is the pattern that works through slots;
// a decoder attached to the slotted child itself is not collected at mount.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/component
@target(javascript)
import lily/event
@target(javascript)
import lily/test_support.{type Message, type Model, Increment, SetName}

// A slotted child that carries a typed message in its data-message via the
// codec, exactly as a converted lily_ui component does.
@target(javascript)
fn encoded_child() -> component.Component(Model, Message, String) {
  component.simple(slice: fn(_) { Nil }, render: fn(_, _slot) {
    "<button id=\"child\" data-message=\""
    <> event.encode_message(Increment)
    <> "\">+</button>"
  })
}

@target(javascript)
pub fn slotted_encoded_message_dispatches_via_root_decoder_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()

  component.mount(
    runtime,
    selector: "#app",
    to_html: test_support.to_html,
    to_slot: test_support.to_slot,
    view: fn(_model) {
      component.simple(slice: fn(_) { Nil }, render: fn(_, slot) {
        "<div>" <> slot(encoded_child()) <> "</div>"
      })
      |> event.on_global_decoded(
        event: event.click,
        selector: "#app",
        decoder: event.decode_message,
        options: event.defaults,
      )
    },
  )

  test_support.click("#child")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// A value-carrying message (the `fn(key) -> message` shape used by radio,
// tabs, pagination, etc.) round-trips through the codec and dispatches with
// its payload intact.
@target(javascript)
pub fn slotted_value_carrying_message_dispatches_via_root_decoder_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()

  let child =
    component.simple(slice: fn(_) { Nil }, render: fn(_, _slot) {
      "<button id=\"named\" data-message=\""
      <> event.encode_message(SetName("Ada"))
      <> "\">x</button>"
    })

  component.mount(
    runtime,
    selector: "#app",
    to_html: test_support.to_html,
    to_slot: test_support.to_slot,
    view: fn(_model) {
      component.simple(slice: fn(_) { Nil }, render: fn(_, slot) {
        "<div>" <> slot(child) <> "</div>"
      })
      |> event.on_global_decoded(
        event: event.click,
        selector: "#app",
        decoder: event.decode_message,
        options: event.defaults,
      )
    },
  )

  test_support.click("#named")
  client.get_current_model(runtime).name
  |> should.equal("Ada")
}
