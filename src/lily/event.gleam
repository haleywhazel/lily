//// Event handlers attach browser events to DOM elements using CSS selectors.
//// Each handler produces a message that gets sent to the
//// [`Store`](./store.html#Store).
////
//// Whenever an event is fired, instead of sending a message, it fires a
//// handler instead to be able to deal with events that also emit some kind of
//// value.
////
//// Handlers target elements using standard CSS selector strings and use
//// event delegation for dynamic elements (e.g., `on_click` with `data-msg`
//// attributes). They're set up once and persist until page unload.
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/event
//// import lily/store
////
//// pub fn main() {
////   let runtime =
////     store.new(Model(count: 0), with: update)
////     |> client.start
////
////   runtime
////   |> component.mount(selector: "#app", to_html: element.to_string, view: app)
////   |> event.on_click(selector: "#app", decoder: parse_click)
////   |> event.on_input(selector: "#search", handler: fn(text) { Search(text) })
////   |> event.on_key_down(selector: "document", handler: fn(ke) { KeyPressed(ke.key) })
//// }
////
//// fn parse_click(msg_name: String) -> Result(Message, Nil) {
////   case msg_name {
////     "increment" -> Ok(Increment)
////     "decrement" -> Ok(Decrement)
////     _ -> Error(Nil)
////   }
//// }
//// ```
////
//// All event handlers are JavaScript-only (`@target(javascript)`).
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/option.{type Option}
@target(javascript)
import lily/client.{type Runtime}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

@target(javascript)
/// Options for event handlers created with `*_with` variants. Controls
/// debouncing, throttling, once-only firing, propagation, and default action.
///
/// Build with [`default_options`](#default_options) and update fields:
///
/// ```gleam
/// event.default_options()
/// |> fn(options) { event.EventOptions(..options, debounce_ms: option.Some(200)) }
/// ```
pub type EventOptions {
  EventOptions(
    debounce_ms: Option(Int),
    stop_propagation: Bool,
    prevent_default: Bool,
    throttle_ms: Option(Int),
    once: Bool,
  )
}

@target(javascript)
/// Data extracted from the DOM element that matched the event handler's
/// selector. `dataset` contains all `data-*` attributes as name/value pairs
/// using their original kebab-case names (e.g., `data-card-id` → `"card-id"`).
///
/// ```gleam
/// event.on_mouse_enter(runtime, selector: ".card", handler: fn(el) {
///   case list.key_find(el.dataset, "id") {
///     Ok(id) -> CardHovered(id)
///     Error(Nil) -> NoOp
///   }
/// })
/// ```
pub type ElementData {
  ElementData(dataset: List(#(String, String)))
}

@target(javascript)
/// Data extracted from a keyboard event. `key` is the key name (e.g.,
/// `"Enter"`, `"ArrowUp"`, `"a"`). The modifier flags match the corresponding
/// browser event properties.
///
/// ```gleam
/// event.on_key_down(runtime, selector: "#search", handler: fn(ke) {
///   case ke.key, ke.ctrl {
///     "k", True -> OpenSearch
///     "Escape", _ -> CloseSearch
///     _, _ -> NoOp
///   }
/// })
/// ```
pub type KeyEvent {
  KeyEvent(key: String, ctrl: Bool, shift: Bool, alt: Bool, meta: Bool)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
/// Returns an `EventOptions` with all modifiers disabled: no debounce,
/// no throttle, fires every time, does not stop propagation or prevent default.
pub fn default_options() -> EventOptions {
  EventOptions(
    debounce_ms: option.None,
    throttle_ms: option.None,
    once: False,
    stop_propagation: False,
    prevent_default: False,
  )
}

@target(javascript)
/// Fires when an element loses focus. The handler receives [`ElementData`](#ElementData)
/// for the element that lost focus, giving access to its `data-*` attributes.
pub fn on_blur(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "blur", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
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
  setup_value_event_with_options(
    selector,
    "change",
    #(-1, -1, False, False, False),
    fn(value) { client.send_message(runtime, handler(value)) },
  )
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
  setup_click_event_with_options(
    selector,
    #(-1, -1, False, False, False),
    fn(message_name) {
      case decoder(message_name) {
        Ok(message) -> client.send_message(runtime, message)
        Error(Nil) -> Nil
      }
    },
  )
  runtime
}

@target(javascript)
/// Like `on_click`, but with event modifiers. See [`EventOptions`](#EventOptions)
/// and [`default_options`](#default_options).
pub fn on_click_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  decoder decoder: fn(String) -> Result(message, Nil),
) -> Runtime(model, message) {
  setup_click_event_with_options(
    selector,
    unpack_options(options),
    fn(message_name) {
      case decoder(message_name) {
        Ok(message) -> client.send_message(runtime, message)
        Error(Nil) -> Nil
      }
    },
  )
  runtime
}

@target(javascript)
/// Fires when the context menu is opened (usually right-click). Provides mouse
/// coordinates (x, y) relative to the viewport and [`ElementData`](#ElementData)
/// for the matched element.
pub fn on_context_menu(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "contextmenu",
    #(-1, -1, False, False, False),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Fires when text is copied to the clipboard.
pub fn on_copy(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event_with_options(
    selector,
    "copy",
    #(-1, -1, False, False, False),
    fn() { client.send_message(runtime, handler()) },
  )
  runtime
}

@target(javascript)
/// Fires when text is cut to the clipboard.
pub fn on_cut(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event_with_options(
    selector,
    "cut",
    #(-1, -1, False, False, False),
    fn() { client.send_message(runtime, handler()) },
  )
  runtime
}

@target(javascript)
/// Fires on double-click events. The handler receives [`ElementData`](#ElementData)
/// for the matched element, giving access to its `data-*` attributes to
/// identify which item was double-clicked.
pub fn on_double_click(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "dblclick", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while an element is being dragged. Provides current mouse
/// coordinates (x, y). Note: This fires many times during a drag operation,
/// consider using `on_drag_with` with a throttle option.
pub fn on_drag(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "drag",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Fires once when a drag operation ends (mouse released). The handler receives
/// [`ElementData`](#ElementData) for the dragged element.
pub fn on_drag_end(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "dragend", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
  })
  runtime
}

@target(javascript)
/// Fires repeatedly when a dragged element is over a valid drop target.
/// Provides mouse coordinates (x, y) and [`ElementData`](#ElementData) for
/// the drop target element. Note: call with `prevent_default: True` in options
/// to enable dropping on the target.
pub fn on_drag_over(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "dragover",
    #(-1, -1, False, False, False),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Like `on_drag_over`, but with event modifiers. See [`EventOptions`](#EventOptions).
/// Set `prevent_default: True` to allow dropping on the target element.
pub fn on_drag_over_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "dragover",
    unpack_options(options),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Fires once when a drag operation starts. Provides initial mouse coordinates
/// (x, y) and [`ElementData`](#ElementData) for the element being dragged.
pub fn on_drag_start(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "dragstart",
    #(-1, -1, False, False, False),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Like `on_drag`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_drag_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "drag",
    unpack_options(options),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Fires when a dragged element is dropped on a valid drop target. Provides
/// drop coordinates (x, y) and [`ElementData`](#ElementData) for the drop
/// target element.
pub fn on_drop(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "drop",
    #(-1, -1, False, False, False),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Fires when an element receives focus. The handler receives
/// [`ElementData`](#ElementData) for the focused element.
pub fn on_focus(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "focus", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
  })
  runtime
}

@target(javascript)
/// Fires whenever any field in a form changes, passing the current field
/// values as a list of name/value pairs. The handler returns
/// `Result(message, Nil)` — return `Error(Nil)` to skip dispatching.
///
/// This is the uncontrolled-form counterpart to `on_input`: rather than
/// tracking each field individually, you read all field values at once on
/// each change.
///
/// ```gleam
/// use fields <- event.on_form_change(runtime, selector: "#my-form")
/// formal.decoding(my_decoder)
/// |> formal.add_values(fields)
/// |> formal.run
/// |> result.map(FormChanged)
/// ```
pub fn on_form_change(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(List(#(String, String))) -> Result(message, Nil),
) -> Runtime(model, message) {
  setup_form_change_event(selector, fn(fields) {
    case handler(fields) {
      Ok(message) -> client.send_message(runtime, message)
      Error(Nil) -> Nil
    }
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
/// use fields <- event.on_form_submit(runtime, selector: "#my-form")
/// formal.decoding(my_decoder)
/// |> formal.add_values(fields)
/// |> formal.run
/// |> result.map(Submit)
/// ```
pub fn on_form_submit(
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
/// Fires immediately when an input value changes. For delayed updates (after
/// blur), use `on_change` instead.
pub fn on_input(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(String) -> message,
) -> Runtime(model, message) {
  setup_value_event_with_options(
    selector,
    "input",
    #(-1, -1, False, False, False),
    fn(value) { client.send_message(runtime, handler(value)) },
  )
  runtime
}

@target(javascript)
/// Like `on_input`, but with event modifiers. See [`EventOptions`](#EventOptions).
/// Particularly useful with `debounce_ms` to avoid dispatching on every keystroke.
pub fn on_input_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(String) -> message,
) -> Runtime(model, message) {
  setup_value_event_with_options(
    selector,
    "input",
    unpack_options(options),
    fn(value) { client.send_message(runtime, handler(value)) },
  )
  runtime
}

@target(javascript)
/// Fires when a key is pressed down. Receives a [`KeyEvent`](#KeyEvent) with
/// the key name and modifier flags (ctrl, shift, alt, meta).
pub fn on_key_down(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(KeyEvent) -> message,
) -> Runtime(model, message) {
  setup_key_full_event_with_options(
    selector,
    "keydown",
    #(-1, -1, False, False, False),
    KeyEvent,
    fn(ke) { client.send_message(runtime, handler(ke)) },
  )
  runtime
}

@target(javascript)
/// Like `on_key_down`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_key_down_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(KeyEvent) -> message,
) -> Runtime(model, message) {
  setup_key_full_event_with_options(
    selector,
    "keydown",
    unpack_options(options),
    KeyEvent,
    fn(ke) { client.send_message(runtime, handler(ke)) },
  )
  runtime
}

@target(javascript)
/// Fires when a key is released. Receives a [`KeyEvent`](#KeyEvent) with
/// the key name and modifier flags (ctrl, shift, alt, meta).
pub fn on_key_up(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(KeyEvent) -> message,
) -> Runtime(model, message) {
  setup_key_full_event_with_options(
    selector,
    "keyup",
    #(-1, -1, False, False, False),
    KeyEvent,
    fn(ke) { client.send_message(runtime, handler(ke)) },
  )
  runtime
}

@target(javascript)
/// Fires when a mouse button is pressed down. Provides mouse coordinates (x, y)
/// relative to the viewport and [`ElementData`](#ElementData) for the matched
/// element.
pub fn on_mouse_down(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "mousedown",
    #(-1, -1, False, False, False),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Fires when the mouse enters an element's boundary. Does not bubble.
/// The handler receives [`ElementData`](#ElementData) for the element being
/// entered, giving access to its `data-*` attributes to identify which item
/// is being hovered.
pub fn on_mouse_enter(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "mouseenter", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
  })
  runtime
}

@target(javascript)
/// Fires when the mouse leaves an element's boundary. Does not bubble.
/// The handler receives [`ElementData`](#ElementData) for the element being
/// left.
pub fn on_mouse_leave(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "mouseleave", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while the mouse moves over an element. Provides current
/// mouse coordinates (x, y). Consider using `on_mouse_move_with` with a
/// throttle option for expensive operations.
pub fn on_mouse_move(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "mousemove",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Like `on_mouse_move`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_mouse_move_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "mousemove",
    unpack_options(options),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Fires when a mouse button is released. Provides mouse coordinates (x, y)
/// relative to the viewport and [`ElementData`](#ElementData) for the matched
/// element.
pub fn on_mouse_up(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int, ElementData) -> message,
) -> Runtime(model, message) {
  setup_coordinate_element_event_with_options(
    selector,
    "mouseup",
    #(-1, -1, False, False, False),
    ElementData,
    fn(x, y, el) { client.send_message(runtime, handler(x, y, el)) },
  )
  runtime
}

@target(javascript)
/// Fires when text is pasted from the clipboard.
pub fn on_paste(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event_with_options(
    selector,
    "paste",
    #(-1, -1, False, False, False),
    fn() { client.send_message(runtime, handler()) },
  )
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
  setup_coordinate_event_with_options(
    selector,
    "pointerdown",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Fires repeatedly while a pointer moves over an element. Provides current
/// pointer coordinates (x, y). Pointer events unify mouse, touch, and pen input.
pub fn on_pointer_move(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "pointermove",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Like `on_pointer_move`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_pointer_move_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "pointermove",
    unpack_options(options),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
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
  setup_coordinate_event_with_options(
    selector,
    "pointerup",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Fires when an element is resized. Typically used on `window` with selector
/// "window". Consider using `on_resize_with` with a debounce option.
pub fn on_resize(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event_with_options(
    selector,
    "resize",
    #(-1, -1, False, False, False),
    fn() { client.send_message(runtime, handler()) },
  )
  runtime
}

@target(javascript)
/// Like `on_resize`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_resize_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn() -> message,
) -> Runtime(model, message) {
  setup_simple_event_with_options(
    selector,
    "resize",
    unpack_options(options),
    fn() { client.send_message(runtime, handler()) },
  )
  runtime
}

@target(javascript)
/// Fires when an element's scroll position changes. Provides the element's
/// current `scrollTop` and `scrollLeft` values as (scroll_top, scroll_left).
/// Consider using `on_scroll_with` with a throttle option for expensive work.
pub fn on_scroll(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_scroll_position_event_with_options(
    selector,
    #(-1, -1, False, False, False),
    fn(top, left) { client.send_message(runtime, handler(top, left)) },
  )
  runtime
}

@target(javascript)
/// Like `on_scroll`, but with event modifiers. See [`EventOptions`](#EventOptions).
/// Particularly useful with `throttle_ms` to limit scroll handler frequency.
pub fn on_scroll_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_scroll_position_event_with_options(
    selector,
    unpack_options(options),
    fn(top, left) { client.send_message(runtime, handler(top, left)) },
  )
  runtime
}

@target(javascript)
/// Fires when a form is submitted. Prevents the browser's default form
/// submission behaviour automatically. Use this for controlled forms — where
/// input state is already tracked in the model via `on_input` — or for
/// action buttons wrapped in a `<form>`. For uncontrolled forms where the
/// handler needs the submitted field values, use
/// [`on_form_submit`](#on_form_submit) instead.
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
/// Fires when all touches are removed from the screen. The handler receives
/// [`ElementData`](#ElementData) for the element where the touch ended.
pub fn on_touch_end(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(ElementData) -> message,
) -> Runtime(model, message) {
  setup_element_event(selector, "touchend", ElementData, fn(el) {
    client.send_message(runtime, handler(el))
  })
  runtime
}

@target(javascript)
/// Fires repeatedly while a touch point moves across the screen. Provides
/// touch coordinates (x, y). Consider using `on_touch_move_with` with a
/// throttle option.
pub fn on_touch_move(
  runtime: Runtime(model, message),
  selector selector: String,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "touchmove",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
  runtime
}

@target(javascript)
/// Like `on_touch_move`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_touch_move_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Int, Int) -> message,
) -> Runtime(model, message) {
  setup_coordinate_event_with_options(
    selector,
    "touchmove",
    unpack_options(options),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
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
  setup_coordinate_event_with_options(
    selector,
    "touchstart",
    #(-1, -1, False, False, False),
    fn(x, y) { client.send_message(runtime, handler(x, y)) },
  )
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
  setup_wheel_event_with_options(
    selector,
    #(-1, -1, False, False, False),
    fn(delta_x, delta_y) {
      client.send_message(runtime, handler(delta_x, delta_y))
    },
  )
  runtime
}

@target(javascript)
/// Like `on_wheel`, but with event modifiers. See [`EventOptions`](#EventOptions).
pub fn on_wheel_with(
  runtime: Runtime(model, message),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(Float, Float) -> message,
) -> Runtime(model, message) {
  setup_wheel_event_with_options(
    selector,
    unpack_options(options),
    fn(delta_x, delta_y) {
      client.send_message(runtime, handler(delta_x, delta_y))
    },
  )
  runtime
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(javascript)
fn unpack_options(options: EventOptions) -> #(Int, Int, Bool, Bool, Bool) {
  #(
    option.unwrap(options.debounce_ms, -1),
    option.unwrap(options.throttle_ms, -1),
    options.once,
    options.stop_propagation,
    options.prevent_default,
  )
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

// See event.ffi.mjs for explanations for each function.

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupClickEventWithOptions")
fn setup_click_event_with_options(
  _selector: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupCoordinateElementEventWithOptions")
fn setup_coordinate_element_event_with_options(
  _selector: String,
  _event_name: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _make_element_data: fn(List(#(String, String))) -> ElementData,
  _handler: fn(Int, Int, ElementData) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupCoordinateEventWithOptions")
fn setup_coordinate_event_with_options(
  _selector: String,
  _event_name: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _handler: fn(Int, Int) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupElementEvent")
fn setup_element_event(
  _selector: String,
  _event_name: String,
  _make_element_data: fn(List(#(String, String))) -> ElementData,
  _handler: fn(ElementData) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupFormChangeEvent")
fn setup_form_change_event(
  _selector: String,
  _handler: fn(List(#(String, String))) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupKeyFullEventWithOptions")
fn setup_key_full_event_with_options(
  _selector: String,
  _event_name: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _make_key_event: fn(String, Bool, Bool, Bool, Bool) -> KeyEvent,
  _handler: fn(KeyEvent) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupScrollPositionEventWithOptions")
fn setup_scroll_position_event_with_options(
  _selector: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _handler: fn(Int, Int) -> Nil,
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
@external(javascript, "./event.ffi.mjs", "setupSimpleEventWithOptions")
fn setup_simple_event_with_options(
  _selector: String,
  _event_name: String,
  _options: #(Int, Int, Bool, Bool, Bool),
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
@external(javascript, "./event.ffi.mjs", "setupValueEventWithOptions")
fn setup_value_event_with_options(
  _selector: String,
  _event_name: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupWheelEventWithOptions")
fn setup_wheel_event_with_options(
  _selector: String,
  _options: #(Int, Int, Bool, Bool, Bool),
  _handler: fn(Float, Float) -> Nil,
) -> Nil {
  Nil
}
