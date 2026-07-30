// Tests for lily/event clipboard and resize events.
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
// CLIPBOARD EVENTS (simple, no data)
// =============================================================================

@target(javascript)
pub fn event_on_copy_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"copy-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.copy,
      selector: "#copy-el",
      handler: fn(_) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#copy-el", "copy")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_cut_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"cut-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.cut,
      selector: "#cut-el",
      handler: fn(_) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#cut-el", "cut")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_paste_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"paste-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.paste,
      selector: "#paste-el",
      handler: fn(_) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#paste-el", "paste")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_resize_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"resize-el\"></div>")
  let fired = test_support.new(False)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.resize,
      selector: "#resize-el",
      handler: fn(_) {
        test_support.set(fired, True)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.simple_event("#resize-el", "resize")
  test_support.get(fired)
  |> should.be_true
}

@target(javascript)
pub fn event_on_resize_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"resize-w-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.resize,
      selector: "#resize-w-el",
      options: event.options() |> event.once,
      handler: fn(_) { Increment },
    )
  })
  test_support.simple_event("#resize-w-el", "resize")
  test_support.simple_event("#resize-w-el", "resize")
  client.get_current_model(runtime).count
  |> should.equal(1)
}
