// Tests for lily/event coordinate and element events, consolidated across the
// coordinate, element and coordinate+element families.
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
// COORDINATE EVENTS (x, y, ElementData)
// =============================================================================

@target(javascript)
pub fn event_on_mouse_down_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"coord-tgt\"></div>")
  let x_ref = test_support.new(0)
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.mouse_down,
      selector: "#coord-tgt",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_support.set(x_ref, x)
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#coord-tgt", "mousedown", 42, 77)
  test_support.get(x_ref)
  |> should.equal(42)
  test_support.get(y_ref)
  |> should.equal(77)
}

@target(javascript)
pub fn event_on_pointer_move_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"ptr-tgt\"></div>")
  let x_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.pointer_move,
      selector: "#ptr-tgt",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_support.set(x_ref, x)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#ptr-tgt", "pointermove", 100, 200)
  test_support.get(x_ref)
  |> should.equal(100)
}

// =============================================================================
// COORDINATE EVENTS (x, y, no element data)
// =============================================================================

@target(javascript)
pub fn event_on_drag_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"drag-el\" draggable=\"true\"></div>",
  )
  let x_ref = test_support.new(0)
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drag,
      selector: "#drag-el",
      handler: fn(payload) {
        let #(x, y) = payload
        test_support.set(x_ref, x)
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#drag-el", "drag", 15, 30)
  test_support.get(x_ref)
  |> should.equal(15)
  test_support.get(y_ref)
  |> should.equal(30)
}

@target(javascript)
pub fn event_on_mouse_move_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"mmove-el\"></div>")
  let x_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.mouse_move,
      selector: "#mmove-el",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_support.set(x_ref, x)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#mmove-el", "mousemove", 55, 0)
  test_support.get(x_ref)
  |> should.equal(55)
}

@target(javascript)
pub fn event_on_pointer_down_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"pdown-el\"></div>")
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.pointer_down,
      selector: "#pdown-el",
      handler: fn(payload) {
        let #(_x, y) = payload
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#pdown-el", "pointerdown", 0, 88)
  test_support.get(y_ref)
  |> should.equal(88)
}

@target(javascript)
pub fn event_on_pointer_up_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"pup-el\"></div>")
  let x_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.pointer_up,
      selector: "#pup-el",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_support.set(x_ref, x)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#pup-el", "pointerup", 33, 0)
  test_support.get(x_ref)
  |> should.equal(33)
}

@target(javascript)
pub fn event_on_touch_start_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"tstart-el\"></div>")
  let x_ref = test_support.new(0)
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.touch_start,
      selector: "#tstart-el",
      handler: fn(payload) {
        let #(x, y) = payload
        test_support.set(x_ref, x)
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#tstart-el", "touchstart", 7, 14)
  test_support.get(x_ref)
  |> should.equal(7)
  test_support.get(y_ref)
  |> should.equal(14)
}

@target(javascript)
pub fn event_on_touch_move_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"tmove-el\"></div>")
  let x_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.touch_move,
      selector: "#tmove-el",
      handler: fn(payload) {
        let #(x, _y) = payload
        test_support.set(x_ref, x)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#tmove-el", "touchmove", 22, 0)
  test_support.get(x_ref)
  |> should.equal(22)
}

// =============================================================================
// ELEMENT EVENTS (ElementData, no coordinates)
// =============================================================================

@target(javascript)
pub fn event_on_double_click_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"dbl-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.double_click,
      selector: "#dbl-el",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#dbl-el", "dblclick")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_focus_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<input id=\"foc-el\" tabindex=\"0\" />")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.focus_event,
      selector: "#foc-el",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#foc-el", "focus")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_enter_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"enter-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.mouse_enter,
      selector: "#enter-el",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  // setupElementEventWithOptions maps "mouseenter" to bubbling "mouseover"
  test_support.simple_event("#enter-el", "mouseover")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_leave_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"leave-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.mouse_leave,
      selector: "#leave-el",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  // setupElementEventWithOptions maps "mouseleave" to bubbling "mouseout"
  test_support.simple_event("#leave-el", "mouseout")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_drag_end_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"dragend-el\" draggable=\"true\"></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drag_end,
      selector: "#dragend-el",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#dragend-el", "dragend")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_touch_end_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"tend-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.touch_end,
      selector: "#tend-el",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#tend-el", "touchend")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE + ELEMENT EVENTS (x, y, ElementData, document delegation)
// =============================================================================

@target(javascript)
pub fn event_on_context_menu_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"ctx-el\"></div>")
  let x_ref = test_support.new(0)
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.context_menu,
      selector: "#ctx-el",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_support.set(x_ref, x)
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#ctx-el", "contextmenu", 20, 40)
  test_support.get(x_ref)
  |> should.equal(20)
  test_support.get(y_ref)
  |> should.equal(40)
}

@target(javascript)
pub fn event_on_drag_over_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"dragover-el\"></div>")
  let x_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drag_over,
      selector: "#dragover-el",
      handler: fn(payload) {
        let #(x, _y, _element) = payload
        test_support.set(x_ref, x)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#dragover-el", "dragover", 60, 0)
  test_support.get(x_ref)
  |> should.equal(60)
}

@target(javascript)
pub fn event_on_drag_start_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"dragstart-el\" draggable=\"true\"></div>",
  )
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drag_start,
      selector: "#dragstart-el",
      handler: fn(payload) {
        let #(_x, y, _element) = payload
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#dragstart-el", "dragstart", 0, 50)
  test_support.get(y_ref)
  |> should.equal(50)
}

@target(javascript)
pub fn event_on_drop_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"drop-el\"></div>")
  let x_ref = test_support.new(0)
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drop,
      selector: "#drop-el",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_support.set(x_ref, x)
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#drop-el", "drop", 11, 22)
  test_support.get(x_ref)
  |> should.equal(11)
  test_support.get(y_ref)
  |> should.equal(22)
}

@target(javascript)
pub fn event_on_mouse_up_extracts_coordinates_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"mup-el\"></div>")
  let x_ref = test_support.new(0)
  let y_ref = test_support.new(0)
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.mouse_up,
      selector: "#mup-el",
      handler: fn(payload) {
        let #(x, y, _element) = payload
        test_support.set(x_ref, x)
        test_support.set(y_ref, y)
        Noop
      },
      options: event.options(),
    )
  })
  test_support.mouse_event("#mup-el", "mouseup", 77, 99)
  test_support.get(x_ref)
  |> should.equal(77)
  test_support.get(y_ref)
  |> should.equal(99)
}

// =============================================================================
// COORDINATE EVENTS WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_drag_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"drag-w-el\" draggable=\"true\"></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drag,
      selector: "#drag-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_support.mouse_event("#drag-w-el", "drag", 1, 2)
  test_support.mouse_event("#drag-w-el", "drag", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_mouse_move_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"mmove-w-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.mouse_move,
      selector: "#mmove-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_support.mouse_event("#mmove-w-el", "mousemove", 1, 2)
  test_support.mouse_event("#mmove-w-el", "mousemove", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_pointer_move_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"pmove-w-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.pointer_move,
      selector: "#pmove-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_support.mouse_event("#pmove-w-el", "pointermove", 1, 2)
  test_support.mouse_event("#pmove-w-el", "pointermove", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_touch_move_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"tmove-w-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.touch_move,
      selector: "#tmove-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_support.mouse_event("#tmove-w-el", "touchmove", 1, 2)
  test_support.mouse_event("#tmove-w-el", "touchmove", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COORDINATE + ELEMENT WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_drag_over_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<div id=\"dragover-w-el\"></div>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.drag_over,
      selector: "#dragover-w-el",
      options: event.options() |> event.once,
      handler: fn(_payload) { Increment },
    )
  })
  test_support.mouse_event("#dragover-w-el", "dragover", 1, 2)
  test_support.mouse_event("#dragover-w-el", "dragover", 3, 4)
  client.get_current_model(runtime).count
  |> should.equal(1)
}
