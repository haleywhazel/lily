// Tests for lily/event scroll and wheel events.
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
// WHEEL
// =============================================================================

@target(javascript)
pub fn event_on_wheel_extracts_deltas_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"wheel-tgt\"></div>")
  let dx_ref = test_support.new(0.0)
  let dy_ref = test_support.new(0.0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.wheel,
      selector: "#wheel-tgt",
      handler: fn(payload) {
        let #(delta_x, delta_y) = payload
        test_support.set(dx_ref, delta_x)
        test_support.set(dy_ref, delta_y)
        Noop
      },
      options: event.defaults,
    )
  })
  test_support.wheel_event("#wheel-tgt", 5.0, 10.0)
  test_support.get(dx_ref)
  |> should.equal(5.0)
  test_support.get(dy_ref)
  |> should.equal(10.0)
}

// =============================================================================
// WHEEL WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_wheel_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"wheel-w-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.wheel,
      selector: "#wheel-w-el",
      options: event.EventOptions(..event.defaults, once: True),
      handler: fn(_payload) { Increment },
    )
  })
  test_support.wheel_event("#wheel-w-el", 1.0, 2.0)
  test_support.wheel_event("#wheel-w-el", 3.0, 4.0)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// SCROLL EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_scroll_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"scroll-el\" style=\"overflow:auto;height:50px;\"></div>",
  )
  let fired = test_support.new(False)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.scroll,
      selector: "#scroll-el",
      handler: fn(_payload) {
        test_support.set(fired, True)
        Noop
      },
      options: event.defaults,
    )
  })
  test_support.simple_event("#scroll-el", "scroll")
  test_support.get(fired)
  |> should.be_true
}

@target(javascript)
pub fn event_on_scroll_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"scroll-w-el\" style=\"overflow:auto;height:50px;\"></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.scroll,
      selector: "#scroll-w-el",
      options: event.EventOptions(..event.defaults, once: True),
      handler: fn(_payload) { Increment },
    )
  })
  test_support.simple_event("#scroll-w-el", "scroll")
  test_support.simple_event("#scroll-w-el", "scroll")
  client.get_current_model(runtime).count
  |> should.equal(1)
}
