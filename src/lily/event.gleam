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
//// |> event.on_input(handler: Search)
//// ```
////
//// Events that report data hand your function their payload and always
//// dispatch: [`on_input`](#on_input) and [`on_change`](#on_change) the value,
//// [`on_check`](#on_check) the checked state, [`on_submit`](#on_submit) a
//// form's fields, [`on_files`](#on_files) the picked files,
//// [`on_paste`](#on_paste) and [`on_drop`](#on_drop) a
//// [`DataTransfer`](#DataTransfer), [`on_media`](#on_media) a player's
//// [`MediaState`](#MediaState), [`on_resize`](#on_resize) the component's
//// size and [`on_visible`](#on_visible) whether it is on screen.
//// Fixed-message binders such as [`on_click`](#on_click),
//// [`on_double_click`](#on_double_click) and [`on_focus_in`](#on_focus_in)
//// take the message itself.
////
//// [`on_key_down`](#on_key_down) and [`on_key_up`](#on_key_up) return a
//// `Result`, since most keys aren't for you, and `Error(Nil)` skips one.
//// Frequent events, the `on_pointer_*` binders with a
//// [`PointerEvent`](#PointerEvent), [`on_wheel`](#on_wheel) and
//// [`on_scroll`](#on_scroll), always dispatch, pipe [`throttle`](#throttle)
//// after them.
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
//// component should get the narrowest scope that works. Pipe
//// [`selector`](#selector) after the binder for a listener that belongs to the
//// page instead, a `document` keydown, a `window` resize, or something outside
//// the component. The other modifiers, [`debounce`](#debounce),
//// [`throttle`](#throttle), [`once`](#once),
//// [`prevent_default`](#prevent_default),
//// [`stop_propagation`](#stop_propagation) and [`reset_form`](#reset_form),
//// pipe the same way. Each one changes the listener piped just before it,
//// skipping a transition in between, and does nothing without one:
////
//// ```gleam
//// component.simple(slice: ..., render: ...)
//// |> event.on_input(handler: Search)
//// |> event.debounce(milliseconds: 200)
//// ```
////
//// A few events don't bubble, `focus`, `blur`, `scroll`, `mouseenter`,
//// `mouseleave`, `pointerenter`, `pointerleave`, `toggle`, `load`, `error` and
//// the media events. Lily still hears them, but a binding fires only for its
//// own component's element or its direct child, and a `selector` must match
//// the target itself. To react to focus anywhere inside, use
//// [`on_focus_in`](#on_focus_in).
////
//// Clicks on an element carrying `data-lily-message` need no binder at all.
//// [`encode_message`](#encode_message) turns a message into an attribute-safe
//// string, [`component.mount`](./component.html#mount) listens for clicks on
//// such elements and dispatches the message back:
////
//// ```gleam
//// html.button(
////   [attribute.data("lily-message", event.encode_message(SaveDraft))],
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
//// A listener is scoped to the element of the component it is piped onto,
//// [`static`](./component.html#static) and
//// [`fragment`](./component.html#fragment) included.
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
import gleam/option
import gleam/string

import lily/component.{type Component}
import lily/internal/codec

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Text and files moved by a paste or a drop. `html` is empty when the source
/// had none.
pub type DataTransfer {
  DataTransfer(text: String, html: String, files: List(File))
}

/// A file the user picked, pasted or dropped. `handle` is the browser's own
/// `File`, for your FFI or a fetch library to read or upload.
pub type File {
  File(name: String, size: Int, mime_type: String, handle: Dynamic)
}

/// A key press. `key` is what the key types, such as `"Enter"` or `"a"`,
/// `code` the physical key, such as `"KeyA"`, the same on every keyboard
/// layout.
///
/// `repeat` is set while a key is held down, and `is_composing` while an input
/// method is still composing a character, when Enter confirms it rather than
/// submitting.
pub type KeyEvent {
  KeyEvent(
    key: String,
    code: String,
    ctrl: Bool,
    shift: Bool,
    alt: Bool,
    meta: Bool,
    repeat: Bool,
    is_composing: Bool,
  )
}

/// The state of an `<audio>` or `<video>` element when one of its events
/// fired. `duration` is `0.0` until it is known.
pub type MediaState {
  MediaState(
    current_time: Float,
    duration: Float,
    paused: Bool,
    ended: Bool,
    muted: Bool,
    volume: Float,
    playback_rate: Float,
  )
}

/// A pointer event, at `x` and `y` in the viewport. `button` is `0` for the
/// main button, `1` the middle and `2` the secondary. `pointer_type` is
/// `"mouse"`, `"pen"` or `"touch"`, and `pointer_id` tells apart the fingers of
/// a multi-touch gesture.
pub type PointerEvent {
  PointerEvent(
    x: Float,
    y: Float,
    button: Int,
    pointer_id: Int,
    pointer_type: String,
    ctrl: Bool,
    shift: Bool,
    alt: Bool,
    meta: Bool,
  )
}

/// A wheel or trackpad scroll, in pixels. A trackpad pinch arrives with `ctrl`
/// set.
pub type WheelEvent {
  WheelEvent(
    delta_x: Float,
    delta_y: Float,
    ctrl: Bool,
    shift: Bool,
    alt: Bool,
    meta: Bool,
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Reads a `data-*` attribute of the element the binding matched, by its
/// kebab-case name, meaning `data-card-id` is `data("card-id")`.
///
/// ```gleam
/// event.on(
///   component,
///   event: "dragstart",
///   decoder: event.data("card-id") |> decode.map(DragStarted),
/// )
/// ```
pub fn data(name: String) -> decode.Decoder(String) {
  decode.at(["lilyMatched", "dataset", camel_case(name)], decode.string)
}

/// Waits for a pause before dispatching, for a search box or anything else
/// that fires in bursts. Pipe it after the binder it applies to.
///
/// The message comes from the last event of the burst, read when it fired.
///
/// ```gleam
/// event.on_input(component, handler: Search)
/// |> event.debounce(milliseconds: 200)
/// ```
pub fn debounce(
  component: Component(model, message, html),
  milliseconds milliseconds: Int,
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) ->
      component.Listener(
        ..listener,
        debounce_milliseconds: option.Some(milliseconds),
      )
    _ -> listener
  }
}

/// Recovers a message encoded by [`encode_message`](#encode_message), or
/// `Error(Nil)` for any other string.
///
/// You rarely need it, [`component.mount`](./component.html#mount) already
/// does this for clicks.
pub fn decode_message(encoded: String) -> Result(message, Nil) {
  codec.decode_data_message(encoded)
}

/// Serialises a message into a string for a `data-lily-message` attribute,
/// which [`component.mount`](./component.html#mount) dispatches when the
/// element is clicked.
///
/// ```gleam
/// html.button(
///   [attribute.data("lily-message", event.encode_message(SaveDraft))],
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
/// With a [`selector`](#selector) that is the closest match to the event's
/// target, otherwise the target itself.
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
/// component's own element, and a [`selector`](#selector) must match the
/// target itself.
///
/// ```gleam
/// event.on(
///   component,
///   event: "toggle",
///   decoder: decode.at(["newState"], decode.string)
///     |> decode.map(Toggled),
/// )
/// ```
pub fn on(
  component: Component(model, message, html),
  event event: String,
  decoder decoder: decode.Decoder(message),
) -> Component(model, message, html) {
  listener(component, event, fn(native) {
    case decode.run(native, decoder) {
      Ok(message) -> component.Dispatch(message)
      Error(errors) -> component.DecodeFailed(describe_errors(errors))
    }
  })
}

/// Dispatches a fixed message when the element loses focus, not when its
/// children do.
pub fn on_blur(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "blur", fn(_) { component.Dispatch(message) })
}

/// Dispatches a message built from the target's value when it is committed,
/// on blur or Enter for a text field.
pub fn on_change(
  component: Component(model, message, html),
  handler handler: fn(String) -> message,
) -> Component(model, message, html) {
  listener(component, "change", fn(native) {
    component.Dispatch(handler(read_value(native)))
  })
}

/// Dispatches a message built from the target's checked state when a checkbox
/// or radio changes.
pub fn on_check(
  component: Component(model, message, html),
  handler handler: fn(Bool) -> message,
) -> Component(model, message, html) {
  listener(component, "change", fn(native) {
    component.Dispatch(handler(read_checked(native)))
  })
}

/// Dispatches a fixed message when the component is clicked.
///
/// ```gleam
/// component.static(fn(_) { save_button() })
/// |> event.on_click(message: Save)
/// ```
pub fn on_click(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "click", fn(_) { component.Dispatch(message) })
}

/// Dispatches a message built from the pointer on a right-click or a long
/// press. Pipe [`prevent_default`](#prevent_default) after it to replace the
/// browser's menu with your own.
pub fn on_context_menu(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "contextmenu", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
}

/// Dispatches a fixed message when the user copies from inside the component.
pub fn on_copy(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "copy", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message when the user cuts from inside the component.
pub fn on_cut(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "cut", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message on a double click.
pub fn on_double_click(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "dblclick", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message when a drag started here ends, dropped or
/// cancelled.
pub fn on_drag_end(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "dragend", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message when a drag enters the component, for
/// highlighting a drop zone.
pub fn on_drag_enter(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "dragenter", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message when a drag leaves the component.
pub fn on_drag_leave(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "dragleave", fn(_) { component.Dispatch(message) })
}

/// Dispatches a message built from the pointer as a drag moves over the
/// component. Fires many times a second, so pipe [`throttle`](#throttle)
/// after it. [`on_drop`](#on_drop) alone is enough to accept a drop.
pub fn on_drag_over(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "dragover", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
  |> prevent_default
}

/// Dispatches a fixed message when the user starts dragging the element. Give
/// it `draggable="true"` in your markup.
pub fn on_drag_start(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "dragstart", fn(native) {
    start_drag(native, component.Dispatch(message))
  })
}

/// Dispatches a message built from what was dropped on the component,
/// accepting the drop and stopping the browser from opening a dropped file.
///
/// ```gleam
/// event.on_drop(component, handler: fn(transfer) {
///   FilesDropped(transfer.files)
/// })
/// ```
pub fn on_drop(
  component: Component(model, message, html),
  handler handler: fn(DataTransfer) -> message,
) -> Component(model, message, html) {
  // the browser only allows a drop where dragenter and dragover are cancelled
  component
  |> listener("dragenter", fn(_) { component.SkipAndPreventDefault })
  |> prevent_default
  |> listener("dragover", fn(_) { component.SkipAndPreventDefault })
  |> prevent_default
  |> listener("drop", fn(native) {
    component.Dispatch(handler(read_transfer(native)))
  })
  |> prevent_default
}

/// Dispatches a message built from the files picked in an
/// `<input type="file">`.
pub fn on_files(
  component: Component(model, message, html),
  handler handler: fn(List(File)) -> message,
) -> Component(model, message, html) {
  listener(component, "change", fn(native) {
    component.Dispatch(handler(list.map(read_files(native), to_file)))
  })
}

/// Dispatches a fixed message when the element gains focus, not when its
/// children do, see [`on_focus_in`](#on_focus_in).
pub fn on_focus(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "focus", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message when focus moves to the component or anything
/// inside it.
pub fn on_focus_in(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "focusin", fn(_) { component.Dispatch(message) })
}

/// Dispatches a fixed message when focus leaves the component or anything
/// inside it.
pub fn on_focus_out(
  component: Component(model, message, html),
  message message: message,
) -> Component(model, message, html) {
  listener(component, "focusout", fn(_) { component.Dispatch(message) })
}

/// Dispatches a message built from the target's value on every keystroke.
///
/// Pipe [`debounce`](#debounce) after it to wait for a pause in typing.
pub fn on_input(
  component: Component(model, message, html),
  handler handler: fn(String) -> message,
) -> Component(model, message, html) {
  listener(component, "input", fn(native) {
    component.Dispatch(handler(read_value(native)))
  })
}

/// Dispatches a message built from a key press, with the key and its
/// modifiers. Return `Error(Nil)` for keys you don't handle.
///
/// ```gleam
/// event.on_key_down(component, handler: fn(key) {
///   case key {
///     event.KeyEvent(key: "k", meta: True, ..)
///     | event.KeyEvent(key: "k", ctrl: True, ..) -> Ok(OpenSearch)
///     _ -> Error(Nil)
///   }
/// })
/// |> event.selector("document")
/// |> event.prevent_default
/// ```
pub fn on_key_down(
  component: Component(model, message, html),
  handler handler: fn(KeyEvent) -> Result(message, Nil),
) -> Component(model, message, html) {
  listener(component, "keydown", fn(native) {
    handler(read_key(native)) |> from_result
  })
}

/// Like [`on_key_down`](#on_key_down), for a key release.
pub fn on_key_up(
  component: Component(model, message, html),
  handler handler: fn(KeyEvent) -> Result(message, Nil),
) -> Component(model, message, html) {
  listener(component, "keyup", fn(native) {
    handler(read_key(native)) |> from_result
  })
}

/// Dispatches a message built from an `<audio>` or `<video>` element's state
/// when `event` fires on it, such as `"play"`, `"pause"`, `"ended"` or
/// `"timeupdate"`. Pipe it onto the component whose element is the player.
pub fn on_media(
  component: Component(model, message, html),
  event event: String,
  handler handler: fn(MediaState) -> message,
) -> Component(model, message, html) {
  listener(component, event, fn(native) {
    component.Dispatch(handler(read_media(native)))
  })
}

/// Dispatches the message in the closest `data-lily-message` around the event's
/// target, for an event other than a click.
///
/// ```gleam
/// event.on_message(component, event: "focusin")
/// ```
pub fn on_message(
  component: Component(model, message, html),
  event event: String,
) -> Component(model, message, html) {
  listener(component, event, fn(native) {
    decode_message(read_data_message(native)) |> from_result
  })
}

/// Dispatches a message built from what the user pastes inside the component.
pub fn on_paste(
  component: Component(model, message, html),
  handler handler: fn(DataTransfer) -> message,
) -> Component(model, message, html) {
  listener(component, "paste", fn(native) {
    component.Dispatch(handler(read_transfer(native)))
  })
}

/// Dispatches a message built from the pointer when a button goes down.
pub fn on_pointer_down(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "pointerdown", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
}

/// Dispatches a message built from the pointer as it enters the component's
/// element, not its children.
pub fn on_pointer_enter(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "pointerenter", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
}

/// Dispatches a message built from the pointer as it leaves the component's
/// element.
pub fn on_pointer_leave(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "pointerleave", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
}

/// Dispatches a message built from the pointer as it moves.
pub fn on_pointer_move(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "pointermove", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
}

/// Dispatches a message built from the pointer when a button is released.
pub fn on_pointer_up(
  component: Component(model, message, html),
  handler handler: fn(PointerEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "pointerup", fn(native) {
    component.Dispatch(handler(read_pointer(native)))
  })
}

/// Dispatches a message built from the component's width and height, once
/// when it mounts and whenever its size changes, for charts and panes that
/// lay themselves out. For the window's size see
/// [`browser.viewport`](./browser.html#viewport).
pub fn on_resize(
  component: Component(model, message, html),
  handler handler: fn(#(Float, Float)) -> message,
) -> Component(model, message, html) {
  listener_for(component, component.ElementResize, fn(native) {
    component.Dispatch(handler(read_size(native)))
  })
}

/// Dispatches a message built from the scroll position, as rounded `scrollTop`
/// and `scrollLeft` of the element that scrolled.
pub fn on_scroll(
  component: Component(model, message, html),
  handler handler: fn(#(Int, Int)) -> message,
) -> Component(model, message, html) {
  listener(component, "scroll", fn(native) {
    component.Dispatch(handler(read_scroll(native)))
  })
}

/// Dispatches a message built from a form's fields when it is submitted,
/// always preventing the browser's own submit.
///
/// Pipe [`reset_form`](#reset_form) after it to clear the form afterwards.
///
/// ```gleam
/// event.on_submit(component, handler: SubmitRoom)
/// |> event.reset_form
/// ```
pub fn on_submit(
  component: Component(model, message, html),
  handler handler: fn(List(#(String, String))) -> message,
) -> Component(model, message, html) {
  listener(component, "submit", fn(native) {
    component.Dispatch(handler(read_form_fields(native)))
  })
  |> prevent_default
}

/// Dispatches a message built from whether the component is on screen, once
/// when it mounts and whenever that changes, for loading the next page when a
/// list's last row shows, lazy content or marking something as seen.
///
/// ```gleam
/// event.on_visible(component, handler: fn(visible) {
///   case visible {
///     True -> LoadNextPage
///     False -> Ignored
///   }
/// })
/// ```
pub fn on_visible(
  component: Component(model, message, html),
  handler handler: fn(Bool) -> message,
) -> Component(model, message, html) {
  listener_for(component, component.ElementVisibility, fn(native) {
    component.Dispatch(handler(read_visible(native)))
  })
}

/// Dispatches a message built from a wheel or trackpad scroll. Pipe
/// [`prevent_default`](#prevent_default) after it to zoom or pan instead of
/// scrolling the page.
pub fn on_wheel(
  component: Component(model, message, html),
  handler handler: fn(WheelEvent) -> message,
) -> Component(model, message, html) {
  listener(component, "wheel", fn(native) {
    component.Dispatch(handler(read_wheel(native)))
  })
}

/// Fires only for the first event, for a one-off such as a first interaction
/// hint. Pipe it after the binder it applies to.
///
/// ```gleam
/// event.on_click(component, message: DismissHint) |> event.once
/// ```
pub fn once(
  component: Component(model, message, html),
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) -> component.Listener(..listener, once: True)
    _ -> listener
  }
}

/// Calls the browser's `preventDefault` on events the binder dispatches a
/// message for, for a link or key the page handles itself. Pipe it after the
/// binder it applies to.
///
/// [`on_submit`](#on_submit) already does this.
///
/// ```gleam
/// event.on_click(component, message: OpenRow) |> event.prevent_default
/// ```
pub fn prevent_default(
  component: Component(model, message, html),
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) ->
      component.Listener(..listener, prevent_default: True)
    _ -> listener
  }
}

/// Resets the form around the matched element once the message is dispatched,
/// for a form that starts empty again. Pipe it after the binder it applies to.
///
/// ```gleam
/// event.on_submit(component, handler: SendMessage) |> event.reset_form
/// ```
pub fn reset_form(
  component: Component(model, message, html),
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) -> component.Listener(..listener, reset_form: True)
    _ -> listener
  }
}

/// Binds the listener to elements matching a CSS selector anywhere on the
/// page rather than its component, or to `"document"` or `"window"`. Pipe it
/// after the binder it applies to.
///
/// ```gleam
/// event.on_key_down(component, handler: fn(key) { Ok(KeyPressed(key)) })
/// |> event.selector("document")
/// ```
pub fn selector(
  component: Component(model, message, html),
  selector selector: String,
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) ->
      component.Listener(..listener, selector: option.Some(selector))
    _ -> listener
  }
}

/// Calls the browser's `stopPropagation` and stops Lily running bindings
/// further out for the same event. Pipe it after the binder it applies to.
///
/// ```gleam
/// event.on_click(component, message: Delete) |> event.stop_propagation
/// ```
pub fn stop_propagation(
  component: Component(model, message, html),
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) ->
      component.Listener(..listener, stop_propagation: True)
    _ -> listener
  }
}

/// Allows one dispatch per interval and drops the events in between, for a
/// scroll or pointer move. Pipe it after the binder it applies to.
///
/// ```gleam
/// event.on_scroll(component, handler: Scrolled)
/// |> event.throttle(milliseconds: 100)
/// ```
pub fn throttle(
  component: Component(model, message, html),
  milliseconds milliseconds: Int,
) -> Component(model, message, html) {
  use listener <- component.update_listener(component)
  case listener {
    component.Listener(..) ->
      component.Listener(
        ..listener,
        throttle_milliseconds: option.Some(milliseconds),
      )
    _ -> listener
  }
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

fn from_result(
  result: Result(message, Nil),
) -> component.ListenerOutcome(message) {
  case result {
    Ok(message) -> component.Dispatch(message)
    Error(Nil) -> component.Skip
  }
}

fn listener(
  component: Component(model, message, html),
  event: String,
  run: fn(Dynamic) -> component.ListenerOutcome(message),
) -> Component(model, message, html) {
  listener_for(component, component.DomEvent(event), run)
}

fn listener_for(
  component: Component(model, message, html),
  trigger: component.ListenerTrigger,
  run: fn(Dynamic) -> component.ListenerOutcome(message),
) -> Component(model, message, html) {
  component.decorate(
    component,
    component.Listener(
      trigger:,
      run:,
      selector: option.None,
      debounce_milliseconds: option.None,
      throttle_milliseconds: option.None,
      once: False,
      prevent_default: False,
      stop_propagation: False,
      reset_form: False,
    ),
  )
}

fn read_key(native: Dynamic) -> KeyEvent {
  let #(key, code, ctrl, shift, alt, meta, repeat, is_composing) =
    read_key_ffi(native)
  KeyEvent(key:, code:, ctrl:, shift:, alt:, meta:, repeat:, is_composing:)
}

fn read_media(native: Dynamic) -> MediaState {
  let #(current_time, duration, paused, ended, muted, volume, playback_rate) =
    read_media_ffi(native)
  MediaState(
    current_time:,
    duration:,
    paused:,
    ended:,
    muted:,
    volume:,
    playback_rate:,
  )
}

fn read_pointer(native: Dynamic) -> PointerEvent {
  let #(x, y, button, pointer_id, pointer_type, ctrl, shift, alt, meta) =
    read_pointer_ffi(native)
  PointerEvent(
    x:,
    y:,
    button:,
    pointer_id:,
    pointer_type:,
    ctrl:,
    shift:,
    alt:,
    meta:,
  )
}

fn read_transfer(native: Dynamic) -> DataTransfer {
  let #(text, html, files) = read_transfer_ffi(native)
  DataTransfer(text:, html:, files: list.map(files, to_file))
}

fn read_wheel(native: Dynamic) -> WheelEvent {
  let #(delta_x, delta_y, ctrl, shift, alt, meta) = read_wheel_ffi(native)
  WheelEvent(delta_x:, delta_y:, ctrl:, shift:, alt:, meta:)
}

fn to_file(fields: #(String, Int, String, Dynamic)) -> File {
  let #(name, size, mime_type, handle) = fields
  File(name:, size:, mime_type:, handle:)
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

@external(javascript, "./event.ffi.mjs", "readFiles")
fn read_files(_native: Dynamic) -> List(#(String, Int, String, Dynamic)) {
  []
}

@external(javascript, "./event.ffi.mjs", "readFormFields")
fn read_form_fields(_native: Dynamic) -> List(#(String, String)) {
  []
}

@external(javascript, "./event.ffi.mjs", "readKey")
fn read_key_ffi(
  _native: Dynamic,
) -> #(String, String, Bool, Bool, Bool, Bool, Bool, Bool) {
  #("", "", False, False, False, False, False, False)
}

@external(javascript, "./event.ffi.mjs", "readMedia")
fn read_media_ffi(
  _native: Dynamic,
) -> #(Float, Float, Bool, Bool, Bool, Float, Float) {
  #(0.0, 0.0, True, False, False, 1.0, 1.0)
}

@external(javascript, "./event.ffi.mjs", "readPointer")
fn read_pointer_ffi(
  _native: Dynamic,
) -> #(Float, Float, Int, Int, String, Bool, Bool, Bool, Bool) {
  #(0.0, 0.0, 0, 1, "mouse", False, False, False, False)
}

@external(javascript, "./event.ffi.mjs", "readScroll")
fn read_scroll(_native: Dynamic) -> #(Int, Int) {
  #(0, 0)
}

@external(javascript, "./event.ffi.mjs", "readSize")
fn read_size(_native: Dynamic) -> #(Float, Float) {
  #(0.0, 0.0)
}

@external(javascript, "./event.ffi.mjs", "readTransfer")
fn read_transfer_ffi(
  _native: Dynamic,
) -> #(String, String, List(#(String, Int, String, Dynamic))) {
  #("", "", [])
}

@external(javascript, "./event.ffi.mjs", "readValue")
fn read_value(_native: Dynamic) -> String {
  ""
}

@external(javascript, "./event.ffi.mjs", "readVisible")
fn read_visible(_native: Dynamic) -> Bool {
  False
}

@external(javascript, "./event.ffi.mjs", "readWheel")
fn read_wheel_ffi(_native: Dynamic) -> #(Float, Float, Bool, Bool, Bool, Bool) {
  #(0.0, 0.0, False, False, False, False)
}

// passes `result` through
@external(javascript, "./event.ffi.mjs", "startDrag")
fn start_drag(_native: Dynamic, result: a) -> a {
  result
}
