// Tests for lily/event key events and their options.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/event
@target(javascript)
import lily/test_support.{Increment, Noop}

// =============================================================================
// KEY EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_key_down_extracts_key_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"key-tgt\" tabindex=\"0\"></div>",
  )
  let captured = test_support.new("")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.key_down,
      selector: "#key-tgt",
      handler: fn(key_event) {
        test_support.set(captured, key_event.key)
        Noop
      },
      options: event.defaults,
    )
  })
  test_support.key_event("#key-tgt", "keydown", "Enter")
  test_support.get(captured)
  |> should.equal("Enter")
}

@target(javascript)
pub fn event_on_key_up_extracts_key_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"key-up\" tabindex=\"0\"></div>",
  )
  let captured = test_support.new("")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.key_up,
      selector: "#key-up",
      handler: fn(key_event) {
        test_support.set(captured, key_event.key)
        Noop
      },
      options: event.defaults,
    )
  })
  test_support.key_event("#key-up", "keyup", "Escape")
  test_support.get(captured)
  |> should.equal("Escape")
}

// =============================================================================
// KEY WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_key_down_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"kdown-w-el\" tabindex=\"0\"></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.key_down,
      selector: "#kdown-w-el",
      options: event.EventOptions(..event.defaults, once: True),
      handler: fn(_key_event) { Increment },
    )
  })
  test_support.key_event("#kdown-w-el", "keydown", "Enter")
  test_support.key_event("#kdown-w-el", "keydown", "Enter")
  client.get_current_model(runtime).count
  |> should.equal(1)
}
