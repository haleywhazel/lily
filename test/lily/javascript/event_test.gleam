// Tests for lily/event — DOM event delegation.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/event
@target(javascript)
import lily/store
@target(javascript)
import lily/test_dom
@target(javascript)
import lily/test_fixtures.{type Message, type Model, Increment, Noop, SetName}
@target(javascript)
import lily/test_ref
@target(javascript)
import lily/test_setup

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  let s = store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  client.start(s)
}

// =============================================================================
// CLICK DELEGATION
// =============================================================================

@target(javascript)
pub fn event_on_click_disabled_ignored_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div data-lily-disabled=\"true\"><button data-msg=\"increment\">+</button></div>",
  )
  let _r =
    event.on_click(runtime, selector: "#app", decoder: fn(_name) {
      Ok(Increment)
    })
  test_dom.click("[data-msg=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(0)
}

@target(javascript)
pub fn event_on_click_with_data_msg_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<button data-msg=\"increment\">+</button>")
  let _r =
    event.on_click(runtime, selector: "#app", decoder: fn(name) {
      case name {
        "increment" -> Ok(Increment)
        _ -> Error(Nil)
      }
    })
  test_dom.click("[data-msg=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_click_without_data_msg_ignored_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<button id=\"no-msg\">+</button>")
  let _r =
    event.on_click(runtime, selector: "#app", decoder: fn(_name) {
      Ok(Increment)
    })
  test_dom.click("#no-msg")
  client.get_current_model(runtime).count
  |> should.equal(0)
}

// =============================================================================
// VALUE EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_change_extracts_value_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"name-ch\" />")
  let _r =
    event.on_change(runtime, selector: "#name-ch", handler: fn(value) {
      SetName(value)
    })
  test_dom.input_event("#name-ch", "Bob")
  client.get_current_model(runtime).name
  |> should.equal("Bob")
}

@target(javascript)
pub fn event_on_input_extracts_value_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"name-in\" />")
  let _r =
    event.on_input(runtime, selector: "#name-in", handler: fn(value) {
      SetName(value)
    })
  test_dom.input_event("#name-in", "Alice")
  client.get_current_model(runtime).name
  |> should.equal("Alice")
}

// =============================================================================
// KEY EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_key_down_extracts_key_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"key-tgt\" tabindex=\"0\"></div>")
  let captured = test_ref.new("")
  let _r =
    event.on_key_down(runtime, selector: "#key-tgt", handler: fn(key) {
      test_ref.set(captured, key)
      Noop
    })
  test_dom.key_event("#key-tgt", "keydown", "Enter")
  test_ref.get(captured)
  |> should.equal("Enter")
}

@target(javascript)
pub fn event_on_key_up_extracts_key_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"key-up\" tabindex=\"0\"></div>")
  let captured = test_ref.new("")
  let _r =
    event.on_key_up(runtime, selector: "#key-up", handler: fn(key) {
      test_ref.set(captured, key)
      Noop
    })
  test_dom.key_event("#key-up", "keyup", "Escape")
  test_ref.get(captured)
  |> should.equal("Escape")
}

// =============================================================================
// SIMPLE EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_blur_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"blur-in\" />")
  let _r =
    event.on_blur(runtime, selector: "#blur-in", handler: fn() { Increment })
  test_dom.simple_event("#blur-in", "blur")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_submit_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<form id=\"test-form\"></form>")
  let _r =
    event.on_submit(runtime, selector: "#test-form", handler: fn() { Increment })
  test_dom.simple_event("#test-form", "submit")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_mouse_down_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"coord-tgt\"></div>")
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  let _r =
    event.on_mouse_down(runtime, selector: "#coord-tgt", handler: fn(x, y) {
      test_ref.set(x_ref, x)
      test_ref.set(y_ref, y)
      Noop
    })
  test_dom.mouse_event("#coord-tgt", "mousedown", 42, 77)
  test_ref.get(x_ref)
  |> should.equal(42)
  test_ref.get(y_ref)
  |> should.equal(77)
}

@target(javascript)
pub fn event_on_pointer_move_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"ptr-tgt\"></div>")
  let x_ref = test_ref.new(0)
  let _r =
    event.on_pointer_move(runtime, selector: "#ptr-tgt", handler: fn(x, _y) {
      test_ref.set(x_ref, x)
      Noop
    })
  test_dom.mouse_event("#ptr-tgt", "pointermove", 100, 200)
  test_ref.get(x_ref)
  |> should.equal(100)
}

// =============================================================================
// WHEEL
// =============================================================================

@target(javascript)
pub fn event_on_wheel_extracts_deltas_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"wheel-tgt\"></div>")
  let dx_ref = test_ref.new(0.0)
  let dy_ref = test_ref.new(0.0)
  let _r =
    event.on_wheel(runtime, selector: "#wheel-tgt", handler: fn(dx, dy) {
      test_ref.set(dx_ref, dx)
      test_ref.set(dy_ref, dy)
      Noop
    })
  test_dom.wheel_event("#wheel-tgt", 5.0, 10.0)
  test_ref.get(dx_ref)
  |> should.equal(5.0)
  test_ref.get(dy_ref)
  |> should.equal(10.0)
}
