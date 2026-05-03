// Tests for lily/event — DOM event delegation.
// All functions are @target(javascript) — skipped on Erlang.

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
    event.on_key_down(runtime, selector: "#key-tgt", handler: fn(ke) {
      test_ref.set(captured, ke.key)
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
    event.on_key_up(runtime, selector: "#key-up", handler: fn(ke) {
      test_ref.set(captured, ke.key)
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
    event.on_blur(runtime, selector: "#blur-in", handler: fn(_el) { Increment })
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
    event.on_mouse_down(runtime, selector: "#coord-tgt", handler: fn(x, y, _el) {
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
  let _r =
    event.on_form_submit(runtime, selector: "#sub-form", handler: fn(fields) {
      case list.key_find(fields, "text") {
        Ok(v) -> {
          test_ref.set(captured, v)
          Ok(Noop)
        }
        Error(_) -> Error(Nil)
      }
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
  let _r =
    event.on_form_change(runtime, selector: "#chg-form", handler: fn(_fields) {
      test_ref.set(fired, True)
      Ok(Noop)
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
  let _r =
    event.on_form_change(runtime, selector: "#chg2-form", handler: fn(fields) {
      case list.key_find(fields, "username") {
        Ok(v) -> {
          test_ref.set(captured, v)
          Ok(Noop)
        }
        Error(_) -> Error(Nil)
      }
    })
  test_dom.input_event("#chg2-in", "alice")
  test_ref.get(captured)
  |> should.equal("alice")
}

// =============================================================================
// ON-CLICK-WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_click_with_once_fires_only_once_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<button data-msg=\"increment\">+</button>")
  let _r =
    event.on_click_with(
      runtime,
      selector: "#app",
      options: event.EventOptions(..event.default_options(), once: True),
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
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
  let _r1 =
    event.on_click_with(
      runtime,
      selector: "#sp-inner",
      options: event.EventOptions(
        ..event.default_options(),
        stop_propagation: True,
      ),
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
  let _r2 =
    event.on_click(runtime, selector: "#sp-outer", decoder: fn(name) {
      case name {
        "increment" -> Ok(Increment)
        _ -> Error(Nil)
      }
    })
  test_dom.click("[data-msg=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// ON-INPUT-WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_input_with_no_options_fires_normally_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"in-with\" />")
  let captured = test_ref.new("")
  let _r =
    event.on_input_with(
      runtime,
      selector: "#in-with",
      options: event.default_options(),
      handler: fn(value) {
        test_ref.set(captured, value)
        SetName(value)
      },
    )
  test_dom.input_event("#in-with", "hello")
  test_ref.get(captured)
  |> should.equal("hello")
}

@target(javascript)
pub fn event_on_input_with_throttle_limits_rate_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<input id=\"throttle-in\" />")
  let _r =
    event.on_input_with(
      runtime,
      selector: "#throttle-in",
      options: event.EventOptions(
        ..event.default_options(),
        throttle_ms: option.Some(10_000),
      ),
      handler: fn(_value) { Increment },
    )
  test_dom.input_event("#throttle-in", "a")
  test_dom.input_event("#throttle-in", "b")
  test_dom.input_event("#throttle-in", "c")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// CLIPBOARD EVENTS (simple — no data)
// =============================================================================

@target(javascript)
pub fn event_on_copy_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"copy-el\"></div>")
  let _r =
    event.on_copy(runtime, selector: "#copy-el", handler: fn() { Increment })
  test_dom.simple_event("#copy-el", "copy")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_cut_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"cut-el\"></div>")
  let _r =
    event.on_cut(runtime, selector: "#cut-el", handler: fn() { Increment })
  test_dom.simple_event("#cut-el", "cut")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_paste_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"paste-el\"></div>")
  let _r =
    event.on_paste(runtime, selector: "#paste-el", handler: fn() { Increment })
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
  let _r =
    event.on_resize(runtime, selector: "#resize-el", handler: fn() {
      test_ref.set(fired, True)
      Noop
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
  let _r =
    event.on_resize_with(
      runtime,
      selector: "#resize-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn() { Increment },
    )
  test_dom.simple_event("#resize-w-el", "resize")
  test_dom.simple_event("#resize-w-el", "resize")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// ELEMENT EVENTS (ElementData — no coordinates)
// =============================================================================

@target(javascript)
pub fn event_on_double_click_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"dbl-el\"></div>")
  let _r =
    event.on_double_click(runtime, selector: "#dbl-el", handler: fn(_el) {
      Increment
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
  let _r =
    event.on_focus(runtime, selector: "#foc-el", handler: fn(_el) { Increment })
  test_dom.simple_event("#foc-el", "focus")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_enter_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"enter-el\"></div>")
  let _r =
    event.on_mouse_enter(runtime, selector: "#enter-el", handler: fn(_el) {
      Increment
    })
  // setupElementEvent maps "mouseenter" to the bubbling "mouseover" on document
  test_dom.simple_event("#enter-el", "mouseover")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_leave_fires_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"leave-el\"></div>")
  let _r =
    event.on_mouse_leave(runtime, selector: "#leave-el", handler: fn(_el) {
      Increment
    })
  // setupElementEvent maps "mouseleave" to the bubbling "mouseout" on document
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
  let _r =
    event.on_drag_end(runtime, selector: "#dragend-el", handler: fn(_el) {
      Increment
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
  let _r =
    event.on_touch_end(runtime, selector: "#tend-el", handler: fn(_el) {
      Increment
    })
  test_dom.simple_event("#tend-el", "touchend")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE EVENTS (x, y — no element data)
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
  let _r =
    event.on_drag(runtime, selector: "#drag-el", handler: fn(x, y) {
      test_ref.set(x_ref, x)
      test_ref.set(y_ref, y)
      Noop
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
  let _r =
    event.on_mouse_move(runtime, selector: "#mmove-el", handler: fn(x, _y) {
      test_ref.set(x_ref, x)
      Noop
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
  let _r =
    event.on_pointer_down(runtime, selector: "#pdown-el", handler: fn(_x, y) {
      test_ref.set(y_ref, y)
      Noop
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
  let _r =
    event.on_pointer_up(runtime, selector: "#pup-el", handler: fn(x, _y) {
      test_ref.set(x_ref, x)
      Noop
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
  let _r =
    event.on_touch_start(runtime, selector: "#tstart-el", handler: fn(x, y) {
      test_ref.set(x_ref, x)
      test_ref.set(y_ref, y)
      Noop
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
  let _r =
    event.on_touch_move(runtime, selector: "#tmove-el", handler: fn(x, _y) {
      test_ref.set(x_ref, x)
      Noop
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
  let _r =
    event.on_drag_with(
      runtime,
      selector: "#drag-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_x, _y) { Increment },
    )
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
  let _r =
    event.on_mouse_move_with(
      runtime,
      selector: "#mmove-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_x, _y) { Increment },
    )
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
  let _r =
    event.on_pointer_move_with(
      runtime,
      selector: "#pmove-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_x, _y) { Increment },
    )
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
  let _r =
    event.on_touch_move_with(
      runtime,
      selector: "#tmove-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_x, _y) { Increment },
    )
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
  let _r =
    event.on_key_down_with(
      runtime,
      selector: "#kdown-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_ke) { Increment },
    )
  test_dom.key_event("#kdown-w-el", "keydown", "Enter")
  test_dom.key_event("#kdown-w-el", "keydown", "Enter")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE + ELEMENT EVENTS (x, y, ElementData — document delegation)
// =============================================================================

@target(javascript)
pub fn event_on_context_menu_extracts_coordinates_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  test_dom.set_inner_html("#app", "<div id=\"ctx-el\"></div>")
  let x_ref = test_ref.new(0)
  let y_ref = test_ref.new(0)
  let _r =
    event.on_context_menu(runtime, selector: "#ctx-el", handler: fn(x, y, _el) {
      test_ref.set(x_ref, x)
      test_ref.set(y_ref, y)
      Noop
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
  let _r =
    event.on_drag_over(
      runtime,
      selector: "#dragover-el",
      handler: fn(x, _y, _el) {
        test_ref.set(x_ref, x)
        Noop
      },
    )
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
  let _r =
    event.on_drag_start(
      runtime,
      selector: "#dragstart-el",
      handler: fn(_x, y, _el) {
        test_ref.set(y_ref, y)
        Noop
      },
    )
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
  let _r =
    event.on_drop(runtime, selector: "#drop-el", handler: fn(x, y, _el) {
      test_ref.set(x_ref, x)
      test_ref.set(y_ref, y)
      Noop
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
  let _r =
    event.on_mouse_up(runtime, selector: "#mup-el", handler: fn(x, y, _el) {
      test_ref.set(x_ref, x)
      test_ref.set(y_ref, y)
      Noop
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
  let _r =
    event.on_drag_over_with(
      runtime,
      selector: "#dragover-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_x, _y, _el) { Increment },
    )
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
  let _r =
    event.on_scroll(runtime, selector: "#scroll-el", handler: fn(_top, _left) {
      test_ref.set(fired, True)
      Noop
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
  let _r =
    event.on_scroll_with(
      runtime,
      selector: "#scroll-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_top, _left) { Increment },
    )
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
  let _r =
    event.on_wheel_with(
      runtime,
      selector: "#wheel-w-el",
      options: event.EventOptions(..event.default_options(), once: True),
      handler: fn(_dx, _dy) { Increment },
    )
  test_dom.wheel_event("#wheel-w-el", 1.0, 2.0)
  test_dom.wheel_event("#wheel-w-el", 3.0, 4.0)
  client.get_current_model(runtime).count
  |> should.equal(1)
}
