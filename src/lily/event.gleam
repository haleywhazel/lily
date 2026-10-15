//// Events are how the DOM talks back to your update function. You pipe a
//// binder onto the [`Component`](./component.html#Component) the event
//// belongs to, hand it a function from the event's payload to one of your
//// messages, and Lily dispatches that message when the event fires inside the
//// component.
////
//// Giving each common event a typed helper with one payload shape makes the
//// usual case a single line:
////
//// ```gleam
//// component.simple(slice: ..., render: ...)
//// |> event.on_input(handler: Search, options: event.defaults)
//// ```
////
//// [`on_click`](#on_click) sends a fixed message, [`on_input`](#on_input) and
//// [`on_change`](#on_change) the target's value, [`on_check`](#on_check) its
//// checked state, [`on_submit`](#on_submit) a form's fields,
//// [`on_key_down`](#on_key_down) and [`on_key_up`](#on_key_up) a
//// [`KeyEvent`](#KeyEvent), [`on_scroll`](#on_scroll) the scroll position, and
//// the `on_pointer_*` binders the pointer's coordinates.
////
//// For anything else there is [`on`](#on), which takes the event's name and a
//// `gleam/dynamic/decode` decoder that reads the browser's own event object.
//// Any package can use it for events of its own, a `CustomEvent` included:
////
//// ```gleam
//// event.on(
////   component,
////   event: "lily-markdown-change",
////   decoder: decode.at(["detail", "value"], decode.string)
////     |> decode.map(EditorChanged),
////   options: event.defaults,
//// )
//// ```
////
//// Three decoders read what only Lily knows. [`matched`](#matched) runs a
//// decoder on the element the binding matched, [`data`](#data) reads one of
//// its `data-*` attributes and [`form_fields`](#form_fields) reads the fields
//// of its form. A decoder that can fail decodes to a type of your own and the
//// message comes from mapping it, meaning a bad event is skipped rather than
//// dispatched. The first time that happens for a binding, Lily logs why.
////
//// A binding fires for events inside the component it is piped onto, meaning a
//// component should get the narrowest scope that works. Set `selector` in the
//// [`EventOptions`](#EventOptions) for a listener that belongs to the page
//// instead, a `document` keydown, a `window` resize, or something outside the
//// component. The other fields debounce, throttle, run once, prevent the
//// default or stop propagation, update the one you need on
//// [`defaults`](#defaults):
////
//// ```gleam
//// event.EventOptions(
////   ..event.defaults,
////   debounce_milliseconds: option.Some(200),
//// )
//// ```
////
//// A few events don't bubble, `focus`, `blur`, `scroll`, `mouseenter`,
//// `mouseleave`, `pointerenter`, `pointerleave`, `toggle`, `load` and `error`.
//// Lily still hears them, but a binding fires only for its own component's
//// element or its direct child, and a `selector` must match the target
//// itself. To react to focus anywhere inside, bind `focusin` with
//// [`on`](#on) instead.
////
//// Clicks on an element carrying `data-message` need no binder at all.
//// [`encode_message`](#encode_message) turns a message into an attribute-safe
//// string, [`component.mount`](./component.html#mount) listens for clicks on
//// such elements and dispatches the message back:
////
//// ```gleam
//// html.button(
////   [attribute.data("message", event.encode_message(SaveDraft))],
////   [html.text("Save")],
//// )
//// ```
////
//// To validate a form submission with the
//// [`formal`](https://hexdocs.pm/formal/) library, decode the submitted fields
//// with [`form_fields`](#form_fields), add them to the form and call
//// `form.run`. Map the result to a message of your own, the error branch can
//// carry the whole `Form(model)` back so the view can render field errors.
////
//// A component that has a listener but no wrapper of its own, a
//// [`static`](./component.html#static) or a
//// [`fragment`](./component.html#fragment), is rendered inside a
//// `display: contents` element so the scope has something to attach to and
//// the layout is unchanged.
////
//// Binders are dual-target. On the browser a binder registers a listener, on
//// the server it only records one, letting a `shared` view pipe them directly
//// and still render server-side.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

import lily/component.{type Component}
import lily/internal/codec

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Modifiers for a binding. Start from [`defaults`](#defaults) and update the
/// one field you need.
///
/// `selector` is any CSS selector, or `"document"` or `"window"`, for a
/// listener outside the component it is piped onto.
///
/// `debounce_milliseconds` waits for a pause, `throttle_milliseconds` allows
/// one dispatch per interval and `once` fires only the first time.
/// `prevent_default` and `stop_propagation` call the browser's methods, and
/// `reset_form` clears the surrounding form after dispatching.
///
/// ```gleam
/// event.EventOptions(
///   ..event.defaults,
///   debounce_milliseconds: option.Some(200),
/// )
/// ```
pub type EventOptions {
  EventOptions(
    selector: Option(String),
    debounce_milliseconds: Option(Int),
    throttle_milliseconds: Option(Int),
    once: Bool,
    prevent_default: Bool,
    stop_propagation: Bool,
    reset_form: Bool,
  )
}

/// A key press, with the key name such as `"Enter"` or `"a"` and its
/// modifier flags.
pub type KeyEvent {
  KeyEvent(key: String, ctrl: Bool, shift: Bool, alt: Bool, meta: Bool)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Options with no modifiers, update the field you need with a record update.
pub const defaults: EventOptions =
  EventOptions(
    selector: option.None,
    debounce_milliseconds: option.None,
    throttle_milliseconds: option.None,
    once: False,
    prevent_default: False,
    stop_propagation: False,
    reset_form: False,
  )

/// Reads a `data-*` attribute of the element the binding matched, by its
/// kebab-case name, meaning `data-card-id` is `data("card-id")`.
///
/// ```gleam
/// event.on(
///   component,
///   event: "dragstart",
///   decoder: event.data("card-id") |> decode.map(DragStarted),
///   options: event.defaults,
/// )
/// ```
pub fn data(name: String) -> decode.Decoder(String) {
  decode.at(["lilyMatched", "dataset", camel_case(name)], decode.string)
}

/// Recovers a message encoded by [`encode_message`](#encode_message), or
/// `Error(Nil)` for any other string.
///
/// You rarely need it, [`component.mount`](./component.html#mount) already
/// does this for clicks.
pub fn decode_message(encoded: String) -> Result(message, Nil) {
  codec.decode_data_message(encoded)
}

/// Serialises a message into a string for a `data-message` attribute, which
/// [`component.mount`](./component.html#mount) dispatches when the element is
/// clicked.
///
/// ```gleam
/// html.button(
///   [attribute.data("message", event.encode_message(SaveDraft))],
///   [html.text("Save")],
/// )
/// ```
pub fn encode_message(message: a) -> String {
  codec.encode_data_message(message)
}

/// Reads the fields of the form around the element the binding matched, as
/// name and value pairs. Files are left out.
pub fn form_fields() -> decode.Decoder(List(#(String, String))) {
  decode.new_primitive_decoder("FormFields", fn(native) {
    Ok(read_form_fields(native))
  })
}

/// Runs a decoder on the element the binding matched rather than on the event,
/// to read a property such as `value`.
///
/// With a `selector` that is the closest match to the event's target,
/// otherwise the target itself.
///
/// ```gleam
/// event.matched(decode.at(["value"], decode.string))
/// ```
pub fn matched(decoder: decode.Decoder(a)) -> decode.Decoder(a) {
  decode.at(["lilyMatched"], decoder)
}

/// Binds an event by name, reading the browser's event object with a decoder.
/// An event the decoder fails on is skipped, and the reason is logged once.
///
/// Prefer a helper such as [`on_input`](#on_input) where one fits.
///
/// Non-bubbling events such as `focus` or `scroll` fire only for the
/// component's own element, and a `selector` must match the target itself.
///
/// ```gleam
/// event.on(
///   component,
///   event: "toggle",
///   decoder: decode.at(["newState"], decode.string)
///     |> decode.map(Toggled),
///   options: event.defaults,
/// )
/// ```
pub fn on(
  component: Component(model, message, html),
  event event: String,
  decoder decoder: decode.Decoder(message),
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    event,
    fn(native) {
      decode.run(native, decoder) |> result.map_error(describe_errors)
    },
    options,
  )
}

/// Dispatches a fixed message when the element loses focus, not when its
/// children do.
pub fn on_blur(
  component: Component(model, message, html),
  message message: message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(component, "blur", fn(_) { Ok(message) }, options)
}

/// Dispatches a message built from the target's value when it is committed,
/// on blur or Enter for a text field.
pub fn on_change(
  component: Component(model, message, html),
  handler handler: fn(String) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "change",
    fn(native) { Ok(handler(read_value(native))) },
    options,
  )
}

/// Dispatches a message built from the target's checked state when a checkbox
/// or radio changes.
pub fn on_check(
  component: Component(model, message, html),
  handler handler: fn(Bool) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "change",
    fn(native) { Ok(handler(read_checked(native))) },
    options,
  )
}

/// Dispatches a fixed message when the component is clicked.
///
/// ```gleam
/// component.static(fn(_) { save_button() })
/// |> event.on_click(message: Save, options: event.defaults)
/// ```
pub fn on_click(
  component: Component(model, message, html),
  message message: message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(component, "click", fn(_) { Ok(message) }, options)
}

/// Dispatches a fixed message when the element gains focus, not when its
/// children do. Bind `focusin` with [`on`](#on) for focus anywhere inside.
pub fn on_focus(
  component: Component(model, message, html),
  message message: message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(component, "focus", fn(_) { Ok(message) }, options)
}

/// Dispatches a message built from the target's value on every keystroke.
///
/// Debounce it in the options to wait for a pause in typing.
pub fn on_input(
  component: Component(model, message, html),
  handler handler: fn(String) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "input",
    fn(native) { Ok(handler(read_value(native))) },
    options,
  )
}

/// Dispatches a message built from a key press, with the key and its modifiers.
pub fn on_key_down(
  component: Component(model, message, html),
  handler handler: fn(KeyEvent) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "keydown",
    fn(native) { Ok(handler(read_key(native))) },
    options,
  )
}

/// Dispatches a message built from a key release, with the key and its
/// modifiers.
pub fn on_key_up(
  component: Component(model, message, html),
  handler handler: fn(KeyEvent) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "keyup",
    fn(native) { Ok(handler(read_key(native))) },
    options,
  )
}

/// Dispatches the message in the closest `data-message` around the event's
/// target, for an event other than a click.
///
/// ```gleam
/// event.on_message(component, event: "focusin", options: event.defaults)
/// ```
pub fn on_message(
  component: Component(model, message, html),
  event event: String,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    event,
    fn(native) {
      decode_message(read_data_message(native)) |> result.replace_error("")
    },
    options,
  )
}

/// Dispatches a message built from the pointer's position when a button goes
/// down, as `clientX` and `clientY`.
pub fn on_pointer_down(
  component: Component(model, message, html),
  handler handler: fn(#(Float, Float)) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "pointerdown",
    fn(native) { Ok(handler(read_pointer(native))) },
    options,
  )
}

/// Dispatches a message built from the pointer's position as it moves, as
/// `clientX` and `clientY`.
pub fn on_pointer_move(
  component: Component(model, message, html),
  handler handler: fn(#(Float, Float)) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "pointermove",
    fn(native) { Ok(handler(read_pointer(native))) },
    options,
  )
}

/// Dispatches a message built from the pointer's position when a button is
/// released, as `clientX` and `clientY`.
pub fn on_pointer_up(
  component: Component(model, message, html),
  handler handler: fn(#(Float, Float)) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "pointerup",
    fn(native) { Ok(handler(read_pointer(native))) },
    options,
  )
}

/// Dispatches a message built from the scroll position, as rounded `scrollTop`
/// and `scrollLeft` of the element that scrolled.
pub fn on_scroll(
  component: Component(model, message, html),
  handler handler: fn(#(Int, Int)) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "scroll",
    fn(native) { Ok(handler(read_scroll(native))) },
    options,
  )
}

/// Dispatches a message built from a form's fields when it is submitted,
/// always preventing the browser's own submit.
///
/// Set `reset_form` in the options to clear the form afterwards.
///
/// ```gleam
/// event.on_submit(
///   component,
///   handler: SubmitRoom,
///   options: event.EventOptions(..event.defaults, reset_form: True),
/// )
/// ```
pub fn on_submit(
  component: Component(model, message, html),
  handler handler: fn(List(#(String, String))) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  listener(
    component,
    "submit",
    fn(native) { Ok(handler(read_form_fields(native))) },
    EventOptions(..options, prevent_default: True),
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn camel_case(name: String) -> String {
  case string.split(name, "-") {
    [] -> name
    [first, ..rest] ->
      string.concat([first, ..list.map(rest, string.capitalise)])
  }
}

fn describe_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    "expected "
    <> error.expected
    <> ", found "
    <> error.found
    <> " at '"
    <> string.join(error.path, ".")
    <> "'"
  })
  |> string.join("; ")
}

fn listener(
  component: Component(model, message, html),
  event: String,
  run: fn(Dynamic) -> Result(message, String),
  options: EventOptions,
) -> Component(model, message, html) {
  component.decorate(
    component,
    component.Listener(
      event:,
      run:,
      selector: options.selector,
      debounce_milliseconds: options.debounce_milliseconds,
      throttle_milliseconds: options.throttle_milliseconds,
      once: options.once,
      prevent_default: options.prevent_default,
      stop_propagation: options.stop_propagation,
      reset_form: options.reset_form,
    ),
  )
}

fn read_key(native: Dynamic) -> KeyEvent {
  let #(key, ctrl, shift, alt, meta) = read_key_ffi(native)
  KeyEvent(key:, ctrl:, shift:, alt:, meta:)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@external(javascript, "./event.ffi.mjs", "readChecked")
fn read_checked(_native: Dynamic) -> Bool {
  False
}

@external(javascript, "./event.ffi.mjs", "readDataMessage")
fn read_data_message(_native: Dynamic) -> String {
  ""
}

@external(javascript, "./event.ffi.mjs", "readFormFields")
fn read_form_fields(_native: Dynamic) -> List(#(String, String)) {
  []
}

@external(javascript, "./event.ffi.mjs", "readKey")
fn read_key_ffi(_native: Dynamic) -> #(String, Bool, Bool, Bool, Bool) {
  #("", False, False, False, False)
}

@external(javascript, "./event.ffi.mjs", "readPointer")
fn read_pointer(_native: Dynamic) -> #(Float, Float) {
  #(0.0, 0.0)
}

@external(javascript, "./event.ffi.mjs", "readScroll")
fn read_scroll(_native: Dynamic) -> #(Int, Int) {
  #(0, 0)
}

@external(javascript, "./event.ffi.mjs", "readValue")
fn read_value(_native: Dynamic) -> String {
  ""
}
