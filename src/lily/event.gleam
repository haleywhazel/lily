//// Event handlers attach browser events to DOM elements using CSS selectors.
//// Each handler produces a message that gets sent to the
//// [`Store`](./store.html#Store).
////
//// Handlers target elements using standard CSS selector strings and use
//// event delegation for dynamic elements (e.g., `on_click` with `data-msg`
//// attributes). They're set up once and persist until page unload
////
//// ```gleam
//// import lily/event
////
//// pub fn main() {
////   store.new(Model(count: 0), with: update)
////   |> component.mount("#app", to_html: element.to_string, view: app)
////   |> event.on_click(selector: "#increment", handler: fn() { Increment })
////   |> event.on_click(selector: "#decrement", handler: fn() { Decrement })
////   |> event.on_input(selector: "#name", decoder: decode_name_input)
////   |> client.start
//// }
////
//// fn decode_name_input(event: Dynamic) -> Result(Message, Nil) {
////   use target <- result.try(dynamic.field("target", dynamic.dynamic)(event))
////   use value <- result.try(dynamic.field("value", dynamic.string)(target))
////   Ok(SetName(value))
//// }
//// ```
////
//// All event handlers are JavaScript-only (`@target(javascript)`).
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import lily/client.{type Runtime}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
/// Fires when an element loses focus.
pub fn on_blur(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "blur", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when an input value changes (after focus is lost). For real-time
/// updates, use `on_input` instead.
pub fn on_change(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(String) -> message,
) -> Runtime(model, message) {
  setup_value_event(selector, "change", fn(value) {
    client.send_message(runtime, handler(value))
  })
  runtime
}

@target(javascript)
/// Fires on click events using event delegation with `data-msg` attributes.
/// The decoder receives the `data-msg` attribute value and should return the
/// corresponding message. Elements must have a `data-msg` attribute to trigger
/// this handler.
pub fn on_click(
  runtime: Runtime(model, message),
  selector selector: String,
  decoder decoder: fn(String) -> Result(message, Nil),
) -> Runtime(model, message) {
  setup_click_event(selector, fn(message_name) {
    case decoder(message_name) {
      Ok(message) -> client.send_message(runtime, message)
      Error(Nil) -> Nil
    }
  })
  runtime
}

@target(javascript)
/// Fires when the context menu is opened (usually right-click). Provides mouse
/// coordinates (x, y) relative to the viewport.
pub fn on_context_menu(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "contextmenu", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when text is copied to the clipboard.
pub fn on_copy(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "copy", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when text is cut to the clipboard.
pub fn on_cut(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "cut", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires on double-click events.
pub fn on_double_click(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "dblclick", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while an element is being dragged. Provides current mouse
/// coordinates (x, y). Note: This fires many times during a drag operation,
/// consider throttling if performing expensive operations.
pub fn on_drag(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "drag", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires once when a drag operation ends (mouse released).
pub fn on_drag_end(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "dragend", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires repeatedly when a dragged element is over a valid drop target.
/// Provides mouse coordinates (x, y). Note: You may need to call
/// `event.preventDefault()` in the browser to enable dropping.
pub fn on_drag_over(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "dragover", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires once when a drag operation starts. Provides initial mouse coordinates
/// (x, y).
pub fn on_drag_start(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "dragstart", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when a dragged element is dropped on a valid drop target. Provides
/// drop coordinates (x, y).
pub fn on_drop(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "drop", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when an element receives focus.
pub fn on_focus(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "focus", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires immediately when an input value changes. For delayed updates (after
/// blur), use `on_change` instead.
pub fn on_input(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(String) -> message,
) -> Runtime(model, message) {
  setup_value_event(selector, "input", fn(value) {
    client.send_message(runtime, handler(value))
  })
  runtime
}

@target(javascript)
/// Fires when a key is pressed down. Receives the key name (e.g., "Enter",
/// "ArrowUp", "a").
pub fn on_key_down(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(String) -> message,
) -> Runtime(model, message) {
  setup_key_event(selector, "keydown", fn(key) {
    client.send_message(runtime, handler(key))
  })
  runtime
}

@target(javascript)
/// Fires when a key is released. Receives the key name (e.g., "Enter",
/// "ArrowUp", "a").
pub fn on_key_up(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(String) -> message,
) -> Runtime(model, message) {
  setup_key_event(selector, "keyup", fn(key) {
    client.send_message(runtime, handler(key))
  })
  runtime
}

@target(javascript)
/// Fires when a mouse button is pressed down. Provides mouse coordinates (x, y)
/// relative to the viewport.
pub fn on_mouse_down(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "mousedown", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when the mouse enters an element's boundary. Does not bubble.
pub fn on_mouse_enter(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "mouseenter", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when the mouse leaves an element's boundary. Does not bubble.
pub fn on_mouse_leave(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "mouseleave", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while the mouse moves over an element. Provides current
/// mouse coordinates (x, y). Note: This can fire very frequently, consider
/// throttling for expensive operations.
pub fn on_mouse_move(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "mousemove", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when a mouse button is released. Provides mouse coordinates (x, y)
/// relative to the viewport.
pub fn on_mouse_up(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "mouseup", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when text is pasted from the clipboard.
pub fn on_paste(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "paste", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when a pointer (mouse, pen, touch) is pressed down. Provides pointer
/// coordinates (x, y). Pointer events unify mouse, touch, and pen input.
pub fn on_pointer_down(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "pointerdown", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while a pointer moves over an element. Provides current
/// pointer coordinates (x, y). Pointer events unify mouse, touch, and pen
/// input.
pub fn on_pointer_move(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "pointermove", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when a pointer (mouse, pen, touch) is released. Provides pointer
/// coordinates (x, y). Pointer events unify mouse, touch, and pen input.
pub fn on_pointer_up(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "pointerup", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when an element is resized. Typically used on `window` with selector
/// "window".
pub fn on_resize(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "resize", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when an element's scroll position changes.
pub fn on_scroll(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "scroll", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when a form is submitted. Prevents the browser's default form
/// submission behaviour automatically. Use this for controlled forms — where
/// input state is already tracked in the model via `on_input` — or for
/// action buttons wrapped in a `<form>`. For uncontrolled forms where the
/// handler needs the submitted field values, use
/// [`on_submit_form`](#on_submit_form) instead.
pub fn on_submit(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event_prevent_default(selector, "submit", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires when a form is submitted, passing the submitted field values as a
/// list of name/value pairs (from the form's `FormData`). Prevents the
/// browser's default form submission, and resets the form after the handler
/// runs so the inputs clear automatically.
///
/// The handler returns `Result(message, Nil)` — return `Error(Nil)` to skip
/// dispatching a message (e.g. when a required field is empty).
///
/// Use this for uncontrolled forms — where the DOM is the source of truth
/// for draft input — so you can avoid plumbing draft state through the
/// model. The list shape matches the `formal` hex package, which can decode
/// it into typed structs:
///
/// ```gleam
/// use fields <- event.on_submit_form(runtime, selector: "#my-form")
/// formal.decoding(my_decoder)
/// |> formal.add_values(fields)
/// |> formal.run
/// |> result.map(Submit)
/// ```
pub fn on_submit_form(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(List(#(String, String))) -> Result(message, Nil),
) -> Runtime(model, message) {
  setup_submit_form_event(selector, fn(fields) {
    case handler(fields) {
      Ok(message) -> client.send_message(runtime, message)
      Error(Nil) -> Nil
    }
  })
  runtime
}

@target(javascript)
/// Fires when all touches are removed from the screen.
pub fn on_touch_end(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event(selector, "touchend", fn() {
    client.send_message(runtime, handler())
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while a touch point moves across the screen. Provides
/// touch coordinates (x, y). Note: This can fire very frequently.
pub fn on_touch_move(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "touchmove", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when a touch point is placed on the screen. Provides initial touch
/// coordinates (x, y).
pub fn on_touch_start(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event(selector, "touchstart", fn(x, y) {
    client.send_message(runtime, handler(x, y))
  })
  runtime
}

@target(javascript)
/// Fires when the mouse wheel is scrolled. Provides scroll deltas (delta_x,
/// delta_y) indicating scroll direction and amount.
pub fn on_wheel(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Float, Float) -> message,
) -> Runtime(model, message) {
  setup_wheel_event(selector, fn(delta_x, delta_y) {
    client.send_message(runtime, handler(delta_x, delta_y))
  })
  runtime
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

// See event.ffi.mjs for explanations for each function.

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupClickEvent")
fn setup_click_event(_selector: String, _handler: fn(String) -> Nil) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupCoordinateEvent")
fn setup_coordinate_event(
  _selector: String,
  _event_name: String,
  _handler: fn(Int, Int) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupKeyEvent")
fn setup_key_event(
  _selector: String,
  _event_name: String,
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupSimpleEvent")
fn setup_simple_event(
  _selector: String,
  _event_name: String,
  _handler: fn() -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupSimpleEventWithPreventDefault")
fn setup_simple_event_prevent_default(
  _selector: String,
  _event_name: String,
  _handler: fn() -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupSubmitFormEvent")
fn setup_submit_form_event(
  _selector: String,
  _handler: fn(List(#(String, String))) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupValueEvent")
fn setup_value_event(
  _selector: String,
  _event_name: String,
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupWheelEvent")
fn setup_wheel_event(
  _selector: String,
  _handler: fn(Float, Float) -> Nil,
) -> Nil {
  Nil
}
