//// Event handlers attach browser events to DOM elements via CSS selectors.
//// Each handler produces a message that flows into the
//// [`Store`](./store.html#Store), so anything the user does on the page
//// becomes a tidy little `Message` value somewhere downstream.
////
//// The public API is two type-safe binders, [`on()`](#on) and
//// [`on_decoded()`](#on_decoded), paired with one constant per DOM event
//// (`event.click`, `event.mouse_down`, `event.key_down`, etc.). The
//// constant fixes the payload type, so the compiler enforces that the
//// handler matches. Bindings live on the [`Component`](./component.html#Component)
//// they relate to and are registered once at
//// [`component.mount()`](./component.html#mount).
////
//// Selectors are standard CSS, matched globally via document-level event
//// delegation. Locality is organisational, the framework does not scope
//// matches to the component the binding is attached to. Patterns like
//// `on(event.click, selector: "#app")` paired with `data-msg` attributes
//// keep working as you patch the DOM. Bindings declared inside
//// [`each`](./component.html#each) and
//// [`each_live`](./component.html#each_live) item bodies are not collected,
//// place them on the each/each_live wrapper or any static ancestor.
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/event
//// import lily/store
////
//// fn app(_model: Model) {
////   component.fragment([
////     component.simple(
////       slice: fn(m: Model) { m.search },
////       render: fn(value, _) { html.input([attribute.value(value)]) },
////     )
////     |> event.on(event: event.input, selector: "#search", handler: Search),
////   ])
////   |> event.on_decoded(
////     event: event.click,
////     selector: "#app",
////     decoder: parse_click,
////   )
////   |> event.on(
////     event: event.key_down,
////     selector: "document",
////     handler: fn(ke) { KeyPressed(ke.key) },
////   )
//// }
////
//// pub fn main() {
////   let runtime =
////     store.new(Model(count: 0), with: update)
////     |> client.start(store.wiring())
////
////   runtime
////   |> component.mount(
////     selector: "#app",
////     to_html: element.to_string,
////     to_slot: fn() { element.element("lily-slot", [], []) },
////     view: app,
////   )
//// }
////
//// fn parse_click(message_name: String) -> Result(Message, Nil) {
////   case message_name {
////     "increment" -> Ok(Increment)
////     "decrement" -> Ok(Decrement)
////     _ -> Error(Nil)
////   }
//// }
//// ```
////
//// For events that need debouncing, throttling, or `preventDefault`, build
//// an [`EventOptions`](#EventOptions) with [`options()`](#options) and the
//// builder functions, then use [`on_with_options()`](#on_with_options)
//// or [`on_decoded_with_options()`](#on_decoded_with_options).
////
//// ```gleam
//// component.simple(slice: ..., render: ...)
//// |> event.on_with_options(
////   event: event.input,
////   selector: "#search",
////   options: event.options() |> event.debounce_milliseconds(200),
////   handler: Search,
//// )
//// ```
////
//// All event handlers are JavaScript-only (`@target(javascript)`).
////
//// To validate a form submission with the
//// [`formal`](https://hexdocs.pm/formal/) library, pass
//// [`form_submit`](#form_submit) to [`on_decoded()`](#on_decoded) with a
//// decoder that builds the form, adds the submitted values, and calls
//// `form.run`. The error branch carries the whole `Form(model)` back so
//// the view can render field-level errors via `form.field_error_messages`:
////
//// ```gleam
//// import formal/form
////
//// fn login_schema() -> form.Schema(Login) {
////   use email <- form.field("email", form.parse_email)
////   use password <- form.field(
////     "password",
////     form.parse_string |> form.check_string_length_more_than(7),
////   )
////   form.success(Login(email:, password:))
//// }
////
//// fn login_decoder(
////   fields: List(#(String, String)),
//// ) -> Result(Message, Nil) {
////   let submitted = form.new(login_schema()) |> form.add_values(fields)
////   case form.run(submitted) {
////     Ok(login) -> Ok(LoginSubmitted(login))
////     Error(invalid_form) -> Ok(LoginFailed(invalid_form))
////   }
//// }
////
//// component.simple(slice: ..., render: ...)
//// |> event.on_decoded(
////   event: event.form_submit,
////   selector: "#login-form",
////   decoder: login_decoder,
//// )
//// ```
////
//// Store the returned `Form(model)` in your application model on the error
//// branch; the view calls `form.field_error_messages(invalid_form,
//// "email")` to render error text next to each field. Run the same schema
//// inside your server-side update function to re-validate untrusted input.
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/option.{type Option}
@target(javascript)
import lily/client.{type Runtime}
@target(javascript)
import lily/component.{type Component}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

@target(javascript)
/// Data extracted from the DOM element that matched the event handler's
/// selector. `dataset` contains all `data-*` attributes as name/value pairs
/// using their original kebab-case names (e.g., `data-card-id` →
/// `"card-id"`).
pub type ElementData {
  ElementData(dataset: List(#(String, String)))
}

@target(javascript)
/// A typed handle for a DOM event. The `payload` parameter is fixed by
/// each constant (e.g. [`mouse_down`](#mouse_down) is `Event(#(Int, Int,
/// ElementData))`), so the handler signature is checked at compile time.
/// Pass these constants to [`on()`](#on) and friends.
pub opaque type Event(payload) {
  Event(name: String, event_type: EventType)
}

@target(javascript)
/// Optional modifiers for an event handler: debounce, throttle, fire-once,
/// stop-propagation, prevent-default. Build with [`options()`](#options)
/// and the dedicated builder functions.
///
/// ```gleam
/// event.options()
/// |> event.debounce_milliseconds(200)
/// |> event.stop_propagation
/// ```
pub opaque type EventOptions {
  EventOptions(
    debounce_milliseconds: Option(Int),
    throttle_milliseconds: Option(Int),
    once: Bool,
    stop_propagation: Bool,
    prevent_default: Bool,
  )
}

@target(javascript)
/// Data extracted from a keyboard event. `key` is the key name (e.g.,
/// `"Enter"`, `"ArrowUp"`, `"a"`). The modifier flags match the
/// corresponding browser event properties.
pub type KeyEvent {
  KeyEvent(key: String, ctrl: Bool, shift: Bool, alt: Bool, meta: Bool)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
/// Set the debounce delay in milliseconds. Multiple events within the
/// window collapse to a single dispatch fired after the gap.
pub fn debounce_milliseconds(options: EventOptions, value: Int) -> EventOptions {
  EventOptions(..options, debounce_milliseconds: option.Some(value))
}

@target(javascript)
/// Programmatically move focus to the first element matching `selector`.
/// Runs after the next paint so the call is safe from a `client.on_message`
/// hook whose dispatch may have just rendered the target element. No-op if
/// the selector matches nothing.
///
/// ```gleam
/// client.on_message(runtime, fn(message, _model) {
///   case message {
///     OpenDialog -> event.focus(runtime, "#dialog-cancel")
///     CloseDialog -> event.focus(runtime, "#dialog-trigger")
///     _ -> Nil
///   }
/// })
/// ```
pub fn focus(_runtime: Runtime(model, message), selector: String) -> Nil {
  setup_focus(selector)
}

@target(javascript)
/// Confine Tab and Shift+Tab cycling to focusable descendants of the
/// element matching `within`. Pushes a new trap onto a stack so nested
/// overlays (a Combobox inside a Dialog inside a Drawer) each keep their
/// own keyboard scope. Focusable elements are re-enumerated on every Tab
/// press so dynamic content inside the container is handled.
///
/// While this trap is the top of the stack, `release_on` runs on every
/// keydown; returning `True` pops the trap and dispatches the message
/// produced by `on_exit`. Opening another trap on top suspends this one
/// (Tab cycles within the new trap, `release_on` and `on_exit` come from
/// the new trap); popping the top trap restores the one below.
///
/// Pair with [`focus`](#focus) to seed initial focus inside the trapped
/// region, and [`release_focus_trap`](#release_focus_trap) for imperative
/// release (e.g. clicking Cancel rather than pressing the exit key).
pub fn focus_trap(
  runtime: Runtime(model, message),
  within within: String,
  release_on release_on: fn(String) -> Bool,
  on_exit on_exit: fn() -> message,
) -> Nil {
  setup_focus_trap(within, release_on, fn() {
    client.send_message(runtime, on_exit())
  })
}

@target(javascript)
/// Bind an event handler to a component. The handler always dispatches a
/// message; the `event` argument fixes the payload type so the handler
/// signature is checked at compile time. The binding is registered during
/// [`component.mount()`](./component.html#mount), and a single registration
/// covers every DOM element matching `selector` via document-level
/// delegation.
///
/// Selectors are global CSS selectors, not scoped to the component the
/// binding is attached to. Locality is organisational, the framework does
/// not constrain which elements the listener matches. Bindings declared
/// inside [`each`](./component.html#each) and
/// [`each_live`](./component.html#each_live) item bodies are ignored,
/// attach them to the each/each_live wrapper or any static ancestor.
///
/// ```gleam
/// component.simple(slice: ..., render: ...)
/// |> event.on(event: event.input, selector: "#search", handler: Search)
/// |> event.on(
///   event: event.mouse_down,
///   selector: ".card",
///   handler: fn(payload) {
///     let #(x, y, element) = payload
///     Pressed(x, y, element)
///   },
/// )
/// ```
pub fn on(
  component: Component(model, message, html),
  event event: Event(payload),
  selector selector: String,
  handler handler: fn(payload) -> message,
) -> Component(model, message, html) {
  on_with_options(component, event, selector, options(), handler)
}

@target(javascript)
/// Bind an event handler whose decoder may decline to dispatch by
/// returning `Error(Nil)`. Useful for [`click`](#click) (the `data-msg`
/// attribute may not match a known message) and form events (validation
/// failure should skip dispatching).
///
/// ```gleam
/// component.fragment([...])
/// |> event.on_decoded(
///   event: event.click,
///   selector: "#app",
///   decoder: parse_click,
/// )
/// |> event.on_decoded(
///   event: event.form_submit,
///   selector: "#todo-form",
///   decoder: submit_todo,
/// )
/// ```
pub fn on_decoded(
  component: Component(model, message, html),
  event event: Event(payload),
  selector selector: String,
  decoder decoder: fn(payload) -> Result(message, Nil),
) -> Component(model, message, html) {
  on_decoded_with_options(component, event, selector, options(), decoder)
}

@target(javascript)
/// Like [`on_decoded`](#on_decoded) with an extra
/// [`EventOptions`](#EventOptions) parameter. See [`options()`](#options).
pub fn on_decoded_with_options(
  component: Component(model, message, html),
  event event: Event(payload),
  selector selector: String,
  options options: EventOptions,
  decoder decoder: fn(payload) -> Result(message, Nil),
) -> Component(model, message, html) {
  let binding = fn(runtime: Runtime(model, message)) {
    let dispatch = fn(payload: payload) {
      case decoder(payload) {
        Ok(message) -> client.send_message(runtime, message)
        Error(Nil) -> Nil
      }
    }
    register_event(event, selector, options, dispatch)
  }
  component.attach_event(component, binding)
}

@target(javascript)
/// Like [`on`](#on) with an extra [`EventOptions`](#EventOptions)
/// parameter. See [`options()`](#options).
///
/// ```gleam
/// component.simple(slice: ..., render: ...)
/// |> event.on_with_options(
///   event: event.input,
///   selector: "#search",
///   options: event.options() |> event.debounce_milliseconds(200),
///   handler: Search,
/// )
/// ```
pub fn on_with_options(
  component: Component(model, message, html),
  event event: Event(payload),
  selector selector: String,
  options options: EventOptions,
  handler handler: fn(payload) -> message,
) -> Component(model, message, html) {
  let binding = fn(runtime: Runtime(model, message)) {
    let dispatch = fn(payload: payload) {
      client.send_message(runtime, handler(payload))
    }
    register_event(event, selector, options, dispatch)
  }
  component.attach_event(component, binding)
}

@target(javascript)
/// Set the handler to fire only the first time. After that, all matching
/// events are ignored.
pub fn once(options: EventOptions) -> EventOptions {
  EventOptions(..options, once: True)
}

@target(javascript)
/// Build an [`EventOptions`](#EventOptions) with all modifiers off:
/// no debounce, no throttle, fires every time, does not stop propagation
/// or prevent default. Compose with the builder functions to enable
/// modifiers.
pub fn options() -> EventOptions {
  EventOptions(
    debounce_milliseconds: option.None,
    throttle_milliseconds: option.None,
    once: False,
    stop_propagation: False,
    prevent_default: False,
  )
}

@target(javascript)
/// Set `event.preventDefault()` to fire on every matching event,
/// regardless of debounce or throttle. Use to suppress browser defaults
/// (e.g. drop-target behaviour, native form submission).
pub fn prevent_default(options: EventOptions) -> EventOptions {
  EventOptions(..options, prevent_default: True)
}

@target(javascript)
/// Pop the top focus trap from the stack. If another trap was below it,
/// that trap becomes active again. No-op when the stack is empty. Does
/// not dispatch the popped trap's `on_exit` message, call this when the
/// caller is already running its own close logic and just needs the trap
/// unhooked (e.g. a click on a Cancel button that dispatches `CloseDialog`
/// and restores focus separately).
pub fn release_focus_trap(_runtime: Runtime(model, message)) -> Nil {
  release_focus_trap_ffi()
}

@target(javascript)
/// Set `event.stopPropagation()` to fire before the inner handler. Useful
/// for delegated events that should not bubble further up.
pub fn stop_propagation(options: EventOptions) -> EventOptions {
  EventOptions(..options, stop_propagation: True)
}

@target(javascript)
/// Set the throttle interval in milliseconds. Events fire at most once
/// per interval; subsequent events within the window are dropped.
pub fn throttle_milliseconds(options: EventOptions, value: Int) -> EventOptions {
  EventOptions(..options, throttle_milliseconds: option.Some(value))
}

// =============================================================================
// PUBLIC EVENTS
// =============================================================================

@target(javascript)
/// `blur` event, fires when an element loses focus.
pub const blur: Event(ElementData) = Event("blur", TypeElement)

@target(javascript)
/// `change` event, fires when an input value is committed (after blur).
/// For real-time updates, use [`input`](#input).
pub const change: Event(String) = Event("change", TypeValue)

@target(javascript)
/// `click` event, uses delegation against the `data-msg` attribute. The
/// payload is the matched element's `data-msg` value. Pair with
/// [`on_decoded()`](#on_decoded) so unknown messages can be skipped via
/// `Error(Nil)`.
pub const click: Event(String) = Event("click", TypeClick)

@target(javascript)
/// `contextmenu` event, fires on right-click. Payload is `(x, y,
/// element)` relative to the viewport.
pub const context_menu: Event(#(Int, Int, ElementData)) = Event(
  "contextmenu",
  TypeCoordinatesElement,
)

@target(javascript)
/// `copy` event, fires when text is copied to the clipboard.
pub const copy: Event(Nil) = Event("copy", TypeEmpty)

@target(javascript)
/// `cut` event, fires when text is cut to the clipboard.
pub const cut: Event(Nil) = Event("cut", TypeEmpty)

@target(javascript)
/// `dblclick` event, fires on a double click.
pub const double_click: Event(ElementData) = Event("dblclick", TypeElement)

@target(javascript)
/// `drag` event, fires repeatedly while an element is being dragged.
/// Consider pairing with [`throttle_milliseconds`](#throttle_milliseconds).
pub const drag: Event(#(Int, Int)) = Event("drag", TypeCoordinates)

@target(javascript)
/// `dragend` event, fires once when a drag operation ends.
pub const drag_end: Event(ElementData) = Event("dragend", TypeElement)

@target(javascript)
/// `dragover` event, fires repeatedly while a dragged element is over a
/// valid drop target. Pair with `prevent_default(options)` to enable
/// dropping.
pub const drag_over: Event(#(Int, Int, ElementData)) = Event(
  "dragover",
  TypeCoordinatesElement,
)

@target(javascript)
/// `dragstart` event, fires once when a drag operation starts.
pub const drag_start: Event(#(Int, Int, ElementData)) = Event(
  "dragstart",
  TypeCoordinatesElement,
)

@target(javascript)
/// `drop` event, fires when a dragged element is dropped on a valid
/// target.
pub const drop: Event(#(Int, Int, ElementData)) = Event(
  "drop",
  TypeCoordinatesElement,
)

@target(javascript)
/// `focus` event, fires when an element receives focus. Named
/// `focus_event` to avoid collision with the [`focus()`](#focus) function.
pub const focus_event: Event(ElementData) = Event("focus", TypeElement)

@target(javascript)
/// `input` on a form, payload is the current `FormData` as a list of
/// name/value pairs. The uncontrolled-form counterpart of [`input`](#input).
/// Pair with [`on_decoded()`](#on_decoded) to skip dispatch on validation
/// failure.
pub const form_change: Event(List(#(String, String))) = Event(
  "input",
  TypeFormChange,
)

@target(javascript)
/// `submit` on a form, payload is the submitted `FormData` as a list of
/// name/value pairs. Prevents the browser's default form submission and
/// resets the form after the handler runs. Pair with
/// [`on_decoded()`](#on_decoded) to skip dispatch on validation failure.
pub const form_submit: Event(List(#(String, String))) = Event(
  "submit",
  TypeFormSubmit,
)

@target(javascript)
/// `input` event, fires immediately when an input value changes. Payload
/// is the current value. For delayed updates use [`change`](#change).
pub const input: Event(String) = Event("input", TypeValue)

@target(javascript)
/// `keydown` event, fires when a key is pressed.
pub const key_down: Event(KeyEvent) = Event("keydown", TypeKey)

@target(javascript)
/// `keyup` event, fires when a key is released.
pub const key_up: Event(KeyEvent) = Event("keyup", TypeKey)

@target(javascript)
/// `mousedown` event, fires when a mouse button is pressed. Payload is
/// `(x, y, element)`.
pub const mouse_down: Event(#(Int, Int, ElementData)) = Event(
  "mousedown",
  TypeCoordinatesElement,
)

@target(javascript)
/// `mouseenter` event, fires when the mouse enters an element's
/// boundary. Mapped to `mouseover` with a relatedTarget guard so
/// delegation works.
pub const mouse_enter: Event(ElementData) = Event("mouseenter", TypeElement)

@target(javascript)
/// `mouseleave` event, fires when the mouse leaves an element's
/// boundary. Mapped to `mouseout` with a relatedTarget guard so
/// delegation works.
pub const mouse_leave: Event(ElementData) = Event("mouseleave", TypeElement)

@target(javascript)
/// `mousemove` event, fires repeatedly while the mouse moves. Consider
/// pairing with [`throttle_milliseconds`](#throttle_milliseconds).
pub const mouse_move: Event(#(Int, Int)) = Event("mousemove", TypeCoordinates)

@target(javascript)
/// `mouseup` event, fires when a mouse button is released.
pub const mouse_up: Event(#(Int, Int, ElementData)) = Event(
  "mouseup",
  TypeCoordinatesElement,
)

@target(javascript)
/// `paste` event, fires when text is pasted from the clipboard.
pub const paste: Event(Nil) = Event("paste", TypeEmpty)

@target(javascript)
/// `pointerdown` event, unifies mouse, touch, and pen.
pub const pointer_down: Event(#(Int, Int)) = Event(
  "pointerdown",
  TypeCoordinates,
)

@target(javascript)
/// `pointermove` event, unifies mouse, touch, and pen.
pub const pointer_move: Event(#(Int, Int)) = Event(
  "pointermove",
  TypeCoordinates,
)

@target(javascript)
/// `pointerup` event, unifies mouse, touch, and pen.
pub const pointer_up: Event(#(Int, Int)) = Event("pointerup", TypeCoordinates)

@target(javascript)
/// `resize` event, fires when an element (or window) resizes.
/// Typically used with `selector: "window"`.
pub const resize: Event(Nil) = Event("resize", TypeEmpty)

@target(javascript)
/// `scroll` event, payload is `(scroll_top, scroll_left)`. Consider
/// pairing with [`throttle_milliseconds`](#throttle_milliseconds).
pub const scroll: Event(#(Int, Int)) = Event("scroll", TypeScroll)

@target(javascript)
/// `submit` event, fires when a form is submitted, with no payload.
/// Prevents the browser's default form submission. Use for controlled
/// forms (input state already in the model). For uncontrolled forms,
/// use [`form_submit`](#form_submit).
pub const submit: Event(Nil) = Event("submit", TypeSubmit)

@target(javascript)
/// `touchend` event, fires when all touches are removed.
pub const touch_end: Event(ElementData) = Event("touchend", TypeElement)

@target(javascript)
/// `touchmove` event, fires repeatedly while a touch point moves.
/// Consider pairing with [`throttle_milliseconds`](#throttle_milliseconds).
pub const touch_move: Event(#(Int, Int)) = Event("touchmove", TypeCoordinates)

@target(javascript)
/// `touchstart` event, fires when a touch point is placed.
pub const touch_start: Event(#(Int, Int)) = Event("touchstart", TypeCoordinates)

@target(javascript)
/// `wheel` event, payload is `(delta_x, delta_y)`. Useful for scroll
/// hijacking and zoom controls.
pub const wheel: Event(#(Float, Float)) = Event("wheel", TypeWheel)

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(javascript)
type EventType {
  TypeClick
  TypeCoordinates
  TypeCoordinatesElement
  TypeElement
  TypeEmpty
  TypeFormChange
  TypeFormSubmit
  TypeKey
  TypeScroll
  TypeSubmit
  TypeValue
  TypeWheel
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(javascript)
fn register_event(
  event: Event(payload),
  selector: String,
  options: EventOptions,
  dispatch: fn(payload) -> Nil,
) -> Nil {
  // Each Event constant pairs `event_type` with the phantom `payload`
  // type at the declaration site, so the casts below are safe by
  // construction, the user's handler signature is already constrained
  // to match.
  let unpacked = unpack_options(options)
  case event.event_type {
    TypeClick -> {
      let typed: fn(String) -> Nil = unsafe_cast(dispatch)
      setup_click_event_with_options(selector, unpacked, typed)
    }

    TypeCoordinates -> {
      let typed: fn(#(Int, Int)) -> Nil = unsafe_cast(dispatch)
      setup_coordinate_event_with_options(
        selector,
        event.name,
        unpacked,
        fn(x, y) { typed(#(x, y)) },
      )
    }

    TypeCoordinatesElement -> {
      let typed: fn(#(Int, Int, ElementData)) -> Nil = unsafe_cast(dispatch)
      setup_coordinate_element_event_with_options(
        selector,
        event.name,
        unpacked,
        ElementData,
        fn(x, y, element) { typed(#(x, y, element)) },
      )
    }

    TypeElement -> {
      let typed: fn(ElementData) -> Nil = unsafe_cast(dispatch)
      setup_element_event_with_options(
        selector,
        event.name,
        unpacked,
        ElementData,
        typed,
      )
    }

    TypeEmpty -> {
      let typed: fn(Nil) -> Nil = unsafe_cast(dispatch)
      setup_simple_event_with_options(selector, event.name, unpacked, fn() {
        typed(Nil)
      })
    }

    TypeFormChange -> {
      let typed: fn(List(#(String, String))) -> Nil = unsafe_cast(dispatch)
      setup_form_change_event_with_options(selector, unpacked, typed)
    }

    TypeFormSubmit -> {
      let typed: fn(List(#(String, String))) -> Nil = unsafe_cast(dispatch)
      setup_submit_form_event_with_options(selector, unpacked, typed)
    }

    TypeKey -> {
      let typed: fn(KeyEvent) -> Nil = unsafe_cast(dispatch)
      setup_key_full_event_with_options(
        selector,
        event.name,
        unpacked,
        KeyEvent,
        typed,
      )
    }

    TypeScroll -> {
      let typed: fn(#(Int, Int)) -> Nil = unsafe_cast(dispatch)
      setup_scroll_position_event_with_options(
        selector,
        unpacked,
        fn(top, left) { typed(#(top, left)) },
      )
    }

    TypeSubmit -> {
      // Bake prevent-default in regardless of caller options.
      let typed: fn(Nil) -> Nil = unsafe_cast(dispatch)
      let with_prevent_default = unpack_options(prevent_default(options))
      setup_simple_event_with_options(
        selector,
        "submit",
        with_prevent_default,
        fn() { typed(Nil) },
      )
    }

    TypeValue -> {
      let typed: fn(String) -> Nil = unsafe_cast(dispatch)
      setup_value_event_with_options(selector, event.name, unpacked, typed)
    }

    TypeWheel -> {
      let typed: fn(#(Float, Float)) -> Nil = unsafe_cast(dispatch)
      setup_wheel_event_with_options(selector, unpacked, fn(delta_x, delta_y) {
        typed(#(delta_x, delta_y))
      })
    }
  }
}

@target(javascript)
fn unpack_options(options: EventOptions) -> #(Int, Int, Bool, Bool, Bool) {
  #(
    option.unwrap(options.debounce_milliseconds, -1),
    option.unwrap(options.throttle_milliseconds, -1),
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
@external(javascript, "./event.ffi.mjs", "identity")
fn unsafe_cast(value: a) -> b

@target(javascript)
@external(javascript, "./event.ffi.mjs", "releaseFocusTrap")
fn release_focus_trap_ffi() -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupClickEventWithOptions")
fn setup_click_event_with_options(
  selector: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(String) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupCoordinateElementEventWithOptions")
fn setup_coordinate_element_event_with_options(
  selector: String,
  event_name: String,
  options: #(Int, Int, Bool, Bool, Bool),
  make_element_data: fn(List(#(String, String))) -> ElementData,
  handler: fn(Int, Int, ElementData) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupCoordinateEventWithOptions")
fn setup_coordinate_event_with_options(
  selector: String,
  event_name: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(Int, Int) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupElementEventWithOptions")
fn setup_element_event_with_options(
  selector: String,
  event_name: String,
  options: #(Int, Int, Bool, Bool, Bool),
  make_element_data: fn(List(#(String, String))) -> ElementData,
  handler: fn(ElementData) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupFocus")
fn setup_focus(selector: String) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupFocusTrap")
fn setup_focus_trap(
  within: String,
  release_on: fn(String) -> Bool,
  on_exit: fn() -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupFormChangeEventWithOptions")
fn setup_form_change_event_with_options(
  selector: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(List(#(String, String))) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupKeyFullEventWithOptions")
fn setup_key_full_event_with_options(
  selector: String,
  event_name: String,
  options: #(Int, Int, Bool, Bool, Bool),
  make_key_event: fn(String, Bool, Bool, Bool, Bool) -> KeyEvent,
  handler: fn(KeyEvent) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupScrollPositionEventWithOptions")
fn setup_scroll_position_event_with_options(
  selector: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(Int, Int) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupSimpleEventWithOptions")
fn setup_simple_event_with_options(
  selector: String,
  event_name: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn() -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupSubmitFormEventWithOptions")
fn setup_submit_form_event_with_options(
  selector: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(List(#(String, String))) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupValueEventWithOptions")
fn setup_value_event_with_options(
  selector: String,
  event_name: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(String) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupWheelEventWithOptions")
fn setup_wheel_event_with_options(
  selector: String,
  options: #(Int, Int, Bool, Bool, Bool),
  handler: fn(Float, Float) -> Nil,
) -> Nil
