// Tests for lily/event value events, input options and form events.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/list
@target(javascript)
import gleam/option
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/event
@target(javascript)
import lily/test_support.{Increment, Noop, SetName}

// =============================================================================
// VALUE EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_change_extracts_value_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<input id=\"name-ch\" />")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.change,
      selector: "#name-ch",
      handler: SetName,
      options: event.defaults,
    )
  })
  test_support.input_event("#name-ch", "Bob")
  client.get_current_model(runtime).name
  |> should.equal("Bob")
}

@target(javascript)
pub fn event_on_input_extracts_value_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<input id=\"name-in\" />")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.input,
      selector: "#name-in",
      handler: SetName,
      options: event.defaults,
    )
  })
  test_support.input_event("#name-in", "Alice")
  client.get_current_model(runtime).name
  |> should.equal("Alice")
}

// =============================================================================
// INPUT WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_input_with_no_options_fires_normally_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<input id=\"in-with\" />")
  let captured = test_support.new("")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.input,
      selector: "#in-with",
      options: event.defaults,
      handler: fn(value) {
        test_support.set(captured, value)
        SetName(value)
      },
    )
  })
  test_support.input_event("#in-with", "hello")
  test_support.get(captured)
  |> should.equal("hello")
}

@target(javascript)
pub fn event_on_input_with_throttle_limits_rate_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<input id=\"throttle-in\" />")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.input,
      selector: "#throttle-in",
      options: event.EventOptions(
        ..event.defaults,
        throttle_milliseconds: option.Some(10_000),
      ),
      handler: fn(_value) { Increment },
    )
  })
  test_support.input_event("#throttle-in", "a")
  test_support.input_event("#throttle-in", "b")
  test_support.input_event("#throttle-in", "c")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// FORM SUBMIT
// =============================================================================

@target(javascript)
pub fn event_on_form_submit_passes_fields_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<form id=\"sub-form\"><input name=\"text\" id=\"sub-input\" /></form>",
  )
  let captured = test_support.new("")
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.form_submit,
      selector: "#sub-form",
      decoder: fn(fields) {
        case list.key_find(fields, "text") {
          Ok(value) -> {
            test_support.set(captured, value)
            Ok(Noop)
          }
          Error(_) -> Error(Nil)
        }
      },
      options: event.defaults,
    )
  })
  test_support.input_event("#sub-input", "hello")
  test_support.simple_event("#sub-form", "submit")
  test_support.get(captured)
  |> should.equal("hello")
}

// =============================================================================
// FORM CHANGE
// =============================================================================

@target(javascript)
pub fn event_on_form_change_fires_on_input_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<form id=\"chg-form\"><input name=\"q\" id=\"chg-q\" /></form>",
  )
  let fired = test_support.new(False)
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.form_change,
      selector: "#chg-form",
      decoder: fn(_fields) {
        test_support.set(fired, True)
        Ok(Noop)
      },
      options: event.defaults,
    )
  })
  test_support.input_event("#chg-q", "abc")
  test_support.get(fired)
  |> should.be_true
}

@target(javascript)
pub fn event_on_form_change_passes_fields_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<form id=\"chg2-form\"><input name=\"username\" id=\"chg2-in\" /></form>",
  )
  let captured = test_support.new("")
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.form_change,
      selector: "#chg2-form",
      decoder: fn(fields) {
        case list.key_find(fields, "username") {
          Ok(value) -> {
            test_support.set(captured, value)
            Ok(Noop)
          }
          Error(_) -> Error(Nil)
        }
      },
      options: event.defaults,
    )
  })
  test_support.input_event("#chg2-in", "alice")
  test_support.get(captured)
  |> should.equal("alice")
}
