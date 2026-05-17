// Tests for lily/event, DOM event delegation.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/list
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/component
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
  client.start(s, store.wiring())
}

@target(javascript)
/// Wraps an empty static component in the caller's event attachments and
/// registers the bindings without mounting. Bypassing `component.mount`
/// means the DOM container is left untouched, which matters for the events
/// that attach listeners directly to a queried element (resize, scroll,
/// copy/cut/paste, value events) rather than via document delegation.
fn mount_event(
  runtime: client.Runtime(Model, Message),
  attach: fn(component.Component(Model, Message, String)) ->
    component.Component(Model, Message, String),
) -> Nil {
  let tree = attach(component.static(fn(_slot) { "" }))
  component.register_bindings(runtime, tree)
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
  mount_event(runtime, fn(component) {
    event.on_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(_name) { Ok(Increment) },
    )
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
  mount_event(runtime, fn(component) {
    event.on_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
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
  mount_event(runtime, fn(component) {
    event.on_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(_name) { Ok(Increment) },
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.change,
      selector: "#name-ch",
      handler: SetName,
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.input,
      selector: "#name-in",
      handler: SetName,
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.key_down,
      selector: "#key-tgt",
      handler: fn(key_event) {
        test_ref.set(captured, key_event.key)
        Noop
      },
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.key_up,
      selector: "#key-up",
      handler: fn(key_event) {
        test_ref.set(captured, key_event.key)
        Noop
      },
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.blur,
      selector: "#blur-in",
      handler: fn(_element) { Increment },
    )
  })
  test_dom.simple_event("#blur-in", "blur")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_submit_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<form id=\"test-form\"></form>")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.submit,
      selector: "#test-form",
      handler: fn(_) { Increment },
    )
  })
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.mouse_down,
      selector: "#coord-tgt",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_ref.set(x_ref, x)
        test_ref.set(y_ref, y)
        Noop
      },
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.pointer_move,
      selector: "#ptr-tgt",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_ref.set(x_ref, x)
        Noop
      },
    )
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
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.wheel,
      selector: "#wheel-tgt",
      handler: fn(payload) {
        let #(delta_x, delta_y) = payload
        test_ref.set(dx_ref, delta_x)
        test_ref.set(dy_ref, delta_y)
        Noop
      },
    )
  })
  test_dom.wheel_event("#wheel-tgt", 5.0, 10.0)
  test_ref.get(dx_ref)
  |> should.equal(5.0)
  test_ref.get(dy_ref)
  |> should.equal(10.0)
}

// =============================================================================
// FORM SUBMIT
// =============================================================================

@target(javascript)
pub fn event_on_form_submit_passes_fields_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<form id=\"sub-form\"><input name=\"text\" id=\"sub-input\" /></form>",
  )
  let captured = test_ref.new("")
  mount_event(runtime, fn(component) {
    event.on_decoded(
      component,
      event: event.form_submit,
      selector: "#sub-form",
      decoder: fn(fields) {
        case list.key_find(fields, "text") {
          Ok(value) -> {
            test_ref.set(captured, value)
            Ok(Noop)
          }
          Error(_) -> Error(Nil)
        }
      },
    )
  })
  test_dom.input_event("#sub-input", "hello")
  test_dom.simple_event("#sub-form", "submit")
  test_ref.get(captured)
  |> should.equal("hello")
}

// =============================================================================
// FORM CHANGE
// =============================================================================

@target(javascript)
pub fn event_on_form_change_fires_on_input_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<form id=\"chg-form\"><input name=\"q\" id=\"chg-q\" /></form>",
  )
  let fired = test_ref.new(False)
  mount_event(runtime, fn(component) {
    event.on_decoded(
      component,
      event: event.form_change,
      selector: "#chg-form",
      decoder: fn(_fields) {
        test_ref.set(fired, True)
        Ok(Noop)
      },
    )
  })
  test_dom.input_event("#chg-q", "abc")
  test_ref.get(fired)
  |> should.be_true
}

@target(javascript)
pub fn event_on_form_change_passes_fields_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<form id=\"chg2-form\"><input name=\"username\" id=\"chg2-in\" /></form>",
  )
  let captured = test_ref.new("")
  mount_event(runtime, fn(component) {
    event.on_decoded(
      component,
      event: event.form_change,
      selector: "#chg2-form",
      decoder: fn(fields) {
        case list.key_find(fields, "username") {
          Ok(value) -> {
            test_ref.set(captured, value)
            Ok(Noop)
          }
          Error(_) -> Error(Nil)
        }
      },
    )
  })
  test_dom.input_event("#chg2-in", "alice")
  test_ref.get(captured)
  |> should.equal("alice")
}

// =============================================================================
// CLICK WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_click_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<button data-msg=\"increment\">+</button>")
  mount_event(runtime, fn(component) {
    event.on_decoded_with_options(
      component,
      event: event.click,
      selector: "#app",
      options: event.options() |> event.once,
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
  })
  test_dom.click("[data-msg=\"increment\"]")
  test_dom.click("[data-msg=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_click_with_stop_propagation_blocks_parent_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"sp-outer\"><div id=\"sp-inner\"><button data-msg=\"increment\">+</button></div></div>",
  )
  mount_event(runtime, fn(component) {
    component
    |> event.on_decoded_with_options(
      event: event.click,
      selector: "#sp-inner",
      options: event.options() |> event.stop_propagation,
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
    |> event.on_decoded(
      event: event.click,
      selector: "#sp-outer",
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
  })
  test_dom.click("[data-msg=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// INPUT WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_input_with_no_options_fires_normally_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"in-with\" />")
  let captured = test_ref.new("")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.input,
      selector: "#in-with",
      options: event.options(),
      handler: fn(value) {
        test_ref.set(captured, value)
        SetName(value)
      },
    )
  })
  test_dom.input_event("#in-with", "hello")
  test_ref.get(captured)
  |> should.equal("hello")
}

@target(javascript)
pub fn event_on_input_with_throttle_limits_rate_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"throttle-in\" />")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.input,
      selector: "#throttle-in",
      options: event.options() |> event.throttle_milliseconds(10_000),
      handler: fn(_value) { Increment },
    )
  })
  test_dom.input_event("#throttle-in", "a")
  test_dom.input_event("#throttle-in", "b")
  test_dom.input_event("#throttle-in", "c")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// CLIPBOARD EVENTS (simple, no data)
// =============================================================================

@target(javascript)
pub fn event_on_copy_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"copy-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(component, event: event.copy, selector: "#copy-el", handler: fn(_) {
      Increment
    })
  })
  test_dom.simple_event("#copy-el", "copy")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_cut_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"cut-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(component, event: event.cut, selector: "#cut-el", handler: fn(_) {
      Increment
    })
  })
  test_dom.simple_event("#cut-el", "cut")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_paste_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"paste-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.paste,
      selector: "#paste-el",
      handler: fn(_) { Increment },
    )
  })
  test_dom.simple_event("#paste-el", "paste")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_resize_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"resize-el\"></div>")
  let fired = test_ref.new(False)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.resize,
      selector: "#resize-el",
      handler: fn(_) {
        test_ref.set(fired, True)
        Noop
      },
    )
  })
  test_dom.simple_event("#resize-el", "resize")
  test_ref.get(fired)
  |> should.be_true
}

@target(javascript)
pub fn event_on_resize_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"resize-w-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.resize,
      selector: "#resize-w-el",
      options: event.options() |> event.once,
      handler: fn(_) { Increment },
    )
  })
  test_dom.simple_event("#resize-w-el", "resize")
  test_dom.simple_event("#resize-w-el", "resize")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// ELEMENT EVENTS (ElementData, no coordinates)
// =============================================================================

@target(javascript)
pub fn event_on_double_click_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"dbl-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.double_click,
      selector: "#dbl-el",
      handler: fn(_element) { Increment },
    )
  })
  test_dom.simple_event("#dbl-el", "dblclick")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_focus_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"foc-el\" tabindex=\"0\" />")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.focus_event,
      selector: "#foc-el",
      handler: fn(_element) { Increment },
    )
  })
  test_dom.simple_event("#foc-el", "focus")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_enter_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"enter-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.mouse_enter,
      selector: "#enter-el",
      handler: fn(_element) { Increment },
    )
  })
  // setupElementEventWithOptions maps "mouseenter" to bubbling "mouseover"
  test_dom.simple_event("#enter-el", "mouseover")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_leave_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"leave-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.mouse_leave,
      selector: "#leave-el",
      handler: fn(_element) { Increment },
    )
  })
  // setupElementEventWithOptions maps "mouseleave" to bubbling "mouseout"
  test_dom.simple_event("#leave-el", "mouseout")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_drag_end_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"dragend-el\" draggable=\"true\"></div>",
  )
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.drag_end,
      selector: "#dragend-el",
      handler: fn(_element) { Increment },
    )
  })
  test_dom.simple_event("#dragend-el", "dragend")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_touch_end_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"tend-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.touch_end,
      selector: "#tend-el",
      handler: fn(_element) { Increment },
    )
  })
  test_dom.simple_event("#tend-el", "touchend")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE EVENTS (x, y, no element data)
// =============================================================================

@target(javascript)
pub fn event_on_drag_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"drag-el\" draggable=\"true\"></div>",
  )
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.drag,
      selector: "#drag-el",
      handler: fn(payload) {
        let #(x, y) = payload
        test_ref.set(x_ref, x)
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#drag-el", "drag", 15, 30)
  test_ref.get(x_ref)
  |> should.equal(15)
  test_ref.get(y_ref)
  |> should.equal(30)
}

@target(javascript)
pub fn event_on_mouse_move_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"mmove-el\"></div>")
  let x_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.mouse_move,
      selector: "#mmove-el",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_ref.set(x_ref, x)
        Noop
      },
    )
  })
  test_dom.mouse_event("#mmove-el", "mousemove", 55, 0)
  test_ref.get(x_ref)
  |> should.equal(55)
}

@target(javascript)
pub fn event_on_pointer_down_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"pdown-el\"></div>")
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.pointer_down,
      selector: "#pdown-el",
      handler: fn(payload) {
        let #(_x, y) = payload
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#pdown-el", "pointerdown", 0, 88)
  test_ref.get(y_ref)
  |> should.equal(88)
}

@target(javascript)
pub fn event_on_pointer_up_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"pup-el\"></div>")
  let x_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.pointer_up,
      selector: "#pup-el",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_ref.set(x_ref, x)
        Noop
      },
    )
  })
  test_dom.mouse_event("#pup-el", "pointerup", 33, 0)
  test_ref.get(x_ref)
  |> should.equal(33)
}

@target(javascript)
pub fn event_on_touch_start_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"tstart-el\"></div>")
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.touch_start,
      selector: "#tstart-el",
      handler: fn(payload) {
        let #(x, y) = payload
        test_ref.set(x_ref, x)
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#tstart-el", "touchstart", 7, 14)
  test_ref.get(x_ref)
  |> should.equal(7)
  test_ref.get(y_ref)
  |> should.equal(14)
}

@target(javascript)
pub fn event_on_touch_move_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"tmove-el\"></div>")
  let x_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.touch_move,
      selector: "#tmove-el",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_ref.set(x_ref, x)
        Noop
      },
    )
  })
  test_dom.mouse_event("#tmove-el", "touchmove", 22, 0)
  test_ref.get(x_ref)
  |> should.equal(22)
}

// =============================================================================
// COORDINATE EVENTS WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_drag_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"drag-w-el\" draggable=\"true\"></div>",
  )
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.drag,
      selector: "#drag-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.mouse_event("#drag-w-el", "drag", 1, 2)
  test_dom.mouse_event("#drag-w-el", "drag", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_move_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"mmove-w-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.mouse_move,
      selector: "#mmove-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.mouse_event("#mmove-w-el", "mousemove", 1, 2)
  test_dom.mouse_event("#mmove-w-el", "mousemove", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_pointer_move_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"pmove-w-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.pointer_move,
      selector: "#pmove-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.mouse_event("#pmove-w-el", "pointermove", 1, 2)
  test_dom.mouse_event("#pmove-w-el", "pointermove", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_touch_move_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"tmove-w-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.touch_move,
      selector: "#tmove-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.mouse_event("#tmove-w-el", "touchmove", 1, 2)
  test_dom.mouse_event("#tmove-w-el", "touchmove", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// KEY WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_key_down_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"kdown-w-el\" tabindex=\"0\"></div>",
  )
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.key_down,
      selector: "#kdown-w-el",
      options: event.options() |> event.once,
      handler: fn(_key_event) { Increment },
    )
  })
  test_dom.key_event("#kdown-w-el", "keydown", "Enter")
  test_dom.key_event("#kdown-w-el", "keydown", "Enter")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE + ELEMENT EVENTS (x, y, ElementData, document delegation)
// =============================================================================

@target(javascript)
pub fn event_on_context_menu_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"ctx-el\"></div>")
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.context_menu,
      selector: "#ctx-el",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_ref.set(x_ref, x)
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#ctx-el", "contextmenu", 20, 40)
  test_ref.get(x_ref)
  |> should.equal(20)
  test_ref.get(y_ref)
  |> should.equal(40)
}

@target(javascript)
pub fn event_on_drag_over_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"dragover-el\"></div>")
  let x_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.drag_over,
      selector: "#dragover-el",
      handler: fn(payload) {
        let #(x, _y, _element) = payload
        test_ref.set(x_ref, x)
        Noop
      },
    )
  })
  test_dom.mouse_event("#dragover-el", "dragover", 60, 0)
  test_ref.get(x_ref)
  |> should.equal(60)
}

@target(javascript)
pub fn event_on_drag_start_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"dragstart-el\" draggable=\"true\"></div>",
  )
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.drag_start,
      selector: "#dragstart-el",
      handler: fn(payload) {
        let #(_x, y, _element) = payload
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#dragstart-el", "dragstart", 0, 50)
  test_ref.get(y_ref)
  |> should.equal(50)
}

@target(javascript)
pub fn event_on_drop_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"drop-el\"></div>")
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.drop,
      selector: "#drop-el",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_ref.set(x_ref, x)
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#drop-el", "drop", 11, 22)
  test_ref.get(x_ref)
  |> should.equal(11)
  test_ref.get(y_ref)
  |> should.equal(22)
}

@target(javascript)
pub fn event_on_mouse_up_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"mup-el\"></div>")
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.mouse_up,
      selector: "#mup-el",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_ref.set(x_ref, x)
        test_ref.set(y_ref, y)
        Noop
      },
    )
  })
  test_dom.mouse_event("#mup-el", "mouseup", 77, 99)
  test_ref.get(x_ref)
  |> should.equal(77)
  test_ref.get(y_ref)
  |> should.equal(99)
}

// =============================================================================
// COORDINATE + ELEMENT WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_drag_over_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"dragover-w-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.drag_over,
      selector: "#dragover-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.mouse_event("#dragover-w-el", "dragover", 1, 2)
  test_dom.mouse_event("#dragover-w-el", "dragover", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// SCROLL EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_scroll_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"scroll-el\" style=\"overflow:auto;height:50px;\"></div>",
  )
  let fired = test_ref.new(False)
  mount_event(runtime, fn(component) {
    event.on(
      component,
      event: event.scroll,
      selector: "#scroll-el",
      handler: fn(_payload) {
        test_ref.set(fired, True)
        Noop
      },
    )
  })
  test_dom.simple_event("#scroll-el", "scroll")
  test_ref.get(fired)
  |> should.be_true
}

@target(javascript)
pub fn event_on_scroll_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html(
    "#app",
    "<div id=\"scroll-w-el\" style=\"overflow:auto;height:50px;\"></div>",
  )
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.scroll,
      selector: "#scroll-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.simple_event("#scroll-w-el", "scroll")
  test_dom.simple_event("#scroll-w-el", "scroll")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// WHEEL WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_wheel_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"wheel-w-el\"></div>")
  mount_event(runtime, fn(component) {
    event.on_with_options(
      component,
      event: event.wheel,
      selector: "#wheel-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_dom.wheel_event("#wheel-w-el", 1.0, 2.0)
  test_dom.wheel_event("#wheel-w-el", 3.0, 4.0)
  client.get_current_model(runtime).count
  |> should.equal(1)
}
