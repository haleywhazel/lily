//// Event handlers wire browser events onto DOM elements through CSS
//// selectors. Each one turns whatever the user does, a click, a keypress, a
//// form submission, into a `Message` that flows into your
//// [`Store`](./store.html#Store), so the rest of your app only ever deals in
//// tidy little message values.
////
//// Most events carry data you react to, a text input's value, a pressed key, a
//// submitted form etc, so you hand [`on()`](#on) (or a page-level or decoding
//// variant) a function that reads the event. The other type is a bare
//// element, like a button, that sends a fixed message on click without
//// becoming a component. It carries the message in a `data-message` attribute
////  with [`encode_message()`](#encode_message), and one root
//// [`on_global_decoded()`](#on_global_decoded) decodes it.
////
//// The core API is a pair of scoped binders, [`on()`](#on) and
//// [`on_decoded()`](#on_decoded), their page-level counterparts
//// [`on_global()`](#on_global) and
//// [`on_global_decoded()`](#on_global_decoded), and one constant per DOM event
//// (`event.click`, `event.mouse_down`, `event.key_down`, and so on). The
//// constant pins down the payload type, so the compiler makes sure your
//// handler actually matches the event. Bindings live on the
//// [`Component`](./component.html#Component) you pipe them onto and are
//// registered once at [`component.mount()`](./component.html#mount).
////
//// Locality is behavioural. [`on()`](#on) confines its listener to the
//// component's own subtree, matched against the component's scope selector
//// (its `id`, recorded with [`component.scoped`](./component.html#scoped)).
//// For listeners that belong to the page rather than any one component (a
//// `document` keydown, a `window` resize, a root `data-message` click
//// decoder), reach for [`on_global()`](#on_global) with an explicit
//// selector. Either way the listener delegates from `document`, so one
//// registration keeps working as you patch the DOM underneath it. As with
//// components, bindings declared inside [`each`](./component.html#each) item
//// bodies aren't collected, so put them on the each wrapper or any static
//// ancestor.
////
//// Here's an example where events are able to react to HTML inputs (more
//// reactively):
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
////       slice: fn(model: Model) { model.search },
////       render: fn(value, _) { html.input([attribute.value(value)]) },
////     )
////     |> component.scoped("#search")
////     |> event.on(
////       event: event.input,
////       handler: Search,
////       options: event.defaults,
////     ),
////   ])
////   |> event.on_global_decoded(
////     event: event.click,
////     selector: "#app",
////     decoder: parse_click,
////     options: event.defaults,
////   )
////   |> event.on_global(
////     event: event.key_down,
////     selector: "document",
////     handler: fn(ke) { KeyPressed(ke.key) },
////     options: event.defaults,
////   )
//// }
////
//// pub fn main() {
////   let runtime =
////     store.new(Model(count: 0), with: update)
////     |> client.start(store.wiring(), serialiser: serialiser())
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
//// And here's an example of implementing it on an element, note that this
//// requires an [`event.on_global_decoded`](#on_global_decoded) somewhere to
//// actually decode the message:
////
//// ```gleam
//// // A component (or your element) carries the message, no handler.
//// html.button(
////   [attribute.data("message", event.encode_message(SaveDraft))],
////   [html.text("Save")],
//// )
////
//// // One root binder recovers and sends every such message.
//// view
//// |> event.on_global_decoded(
////   event: event.click,
////   selector: ".lily-ui-root",
////   decoder: event.decode_message,
////   options: event.defaults,
//// )
//// ```
////
//// The `options` argument carries debouncing, throttling, or
//// `preventDefault`. Pass [`defaults`](#defaults) for no modifiers, or update
//// one field of it with a record update:
////
//// ```gleam
//// component.simple(slice: ..., render: ...)
//// |> component.scoped("#search")
//// |> event.on(
////   event: event.input,
////   handler: Search,
////   options: event.EventOptions(
////     ..event.defaults,
////     debounce_milliseconds: option.Some(200),
////   ),
//// )
//// ```
////
//// A handful of helpers cover keyboard accessibility. Because they act on the
//// live DOM imperatively, they are driven from a
//// [`client.on_message`](./client.html#on_message) hook rather than piped onto
//// a component. [`focus`](#focus) moves focus to a selector,
//// [`focus_trap`](#focus_trap) confines Tab cycling to an overlay
//// (stacked, so a dialog inside a drawer each keep their own scope), and
//// [`arrow_group`](#arrow_group) / [`arrow_grid`](#arrow_grid) turn a set of
//// elements into an arrow-navigable roving-tabindex group or grid. These scope
//// their items relative to the component like [`on()`](#on) does and re-query
//// on every keypress, so content that shows up later just works.
////
//// The binders and event values are dual-target. On the browser the binder
//// registers a delegated listener, on the server it is a no-op (events do not
//// fire during server render), so a `shared` view can pipe them directly and
//// still render server-side.
////
//// To validate a form submission with the
//// [`formal`](https://hexdocs.pm/formal/) library, pass
//// [`form_submit`](#form_submit) to [`on_decoded()`](#on_decoded) with a
//// decoder that builds the form, adds the submitted values, and calls
//// `form.run`. The error branch carries the whole `Form(model)` back so the
//// view can render field-level errors via `form.field_error_messages`:
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
//// |> component.scoped("#login-form")
//// |> event.on_decoded(
////   event: event.form_submit,
////   decoder: login_decoder,
////   options: event.defaults,
//// )
//// ```
////
//// Store the returned `Form(model)` in your model on the error branch, the
//// view calls `form.field_error_messages(invalid_form, "email")` to render
//// error text next to each field. Run the same schema inside your server-side
//// update function to re-validate untrusted input.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
@target(javascript)
import gleam/list
import gleam/option.{type Option}
import gleam/result

@target(javascript)
import lily/client.{type Runtime}
import lily/component.{type Component}
import lily/internal/auto_codec
import lily/internal/reflection

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// A document-level behaviour that Lily can install for you, passed to
/// [`watch`](#watch). Each one is driven by `data-*` attributes a component
/// library renders, so nothing needs wiring per component.
///
/// ```gleam
/// event.watch([event.EscapeDismiss, event.FocusTraps])
/// ```
pub type Behaviour {
  /// Manage native `<details>` popups carrying `data-lily-focus-on-open`,
  /// seeding focus on the selected option or the first focusable so an
  /// [`arrow_group`](#arrow_group) works with no manual tab in.
  DetailsOpen

  /// Escape clicks the target named by `data-lily-escape-dismiss`, so
  /// dismissal flows through ordinary `data-message` delegation. Does not trap
  /// focus, so it suits non-modal overlays.
  EscapeDismiss

  /// Drag-and-drop files onto a `data-lily-file-drop="<input selector>"` zone,
  /// which assigns them to that input and fires `change`.
  FileDrops

  /// Activate a focus trap for any element carrying `data-lily-focus-trap`,
  /// for as long as it is in the DOM. The hands-off counterpart to
  /// [`focus_trap`](#focus_trap).
  FocusTraps

  /// Click the trigger named by `data-lily-focusout-dismiss` when focus leaves
  /// the panel, so a tab never lands behind an open panel.
  FocusoutDismiss
}

/// Data from the DOM element that matched the handler's selector. `dataset`
/// holds all `data-*` attributes as name/value pairs in their original
/// kebab-case, so `data-card-id` becomes `'card-id'`.
pub type ElementData {
  ElementData(dataset: List(#(String, String)))
}

/// A typed handle for a DOM event. `payload` is fixed by each constant (e.g.
/// [`mouse_down`](#mouse_down) is `Event(#(Int, Int, ElementData))`), so the
/// handler signature is checked at compile time. Pass these to [`on()`](#on)
/// and friends.
pub opaque type Event(payload) {
  Event(name: String, event_type: EventType)
}

/// Modifiers for an event handler. `debounce_milliseconds` collapses a burst
/// into one dispatch fired after the gap, `throttle_milliseconds` caps
/// dispatches to one per interval, `once` fires only the first matching event,
/// and the last two call `stopPropagation` and `preventDefault` on every
/// matching event. Start from [`defaults`](#defaults) and update the one field
/// you need.
///
/// ```gleam
/// event.EventOptions(
///   ..event.defaults,
///   debounce_milliseconds: option.Some(200),
/// )
/// ```
pub type EventOptions {
  EventOptions(
    debounce_milliseconds: Option(Int),
    throttle_milliseconds: Option(Int),
    once: Bool,
    stop_propagation: Bool,
    prevent_default: Bool,
  )
}

/// Data from a keyboard event. `key` is the key name (e.g. `'Enter'`,
/// `'ArrowUp'`, `'a'`). The modifier flags match the browser event properties.
pub type KeyEvent {
  KeyEvent(key: String, ctrl: Bool, shift: Bool, alt: Bool, meta: Bool)
}

/// Axis an [`arrow_group`](#arrow_group) navigates. `Horizontal` for
/// Left/Right, `Vertical` for Up/Down, `Both` for all four.
pub type Orientation {
  Horizontal
  Vertical
  Both
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(erlang)
/// Erlang no-op twin.
pub fn arrow_grid(
  component: Component(model, message, html),
  items _items: String,
  columns _columns: Int,
  wrap _wrap: Bool,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// Make a set of elements an arrow-navigable grid of `columns` columns
/// (roving-tabindex in two dimensions). Left/right move by one cell, up/down by
/// a full row. `wrap` decides whether moving past an edge loops around.
///
/// Pipe-friendly and scoped like [`on`](#on): `items` is relative to the
/// component's scope (its `id`), so `'[role=gridcell]'` composes to
/// `#<id> [role=gridcell]`. Registers at
/// [`component.mount()`](./component.html#mount) and re-queries items on every
/// keypress, so items rendered later (an overlay opening) are picked up.
pub fn arrow_grid(
  component: Component(model, message, html),
  items items: String,
  columns columns: Int,
  wrap wrap: Bool,
) -> Component(model, message, html) {
  let selector = compose_items(component, items)
  component.attach_event(component, fn(_runtime) {
    setup_focus_grid(selector, columns, wrap)
  })
}

@target(erlang)
/// Erlang no-op twin.
pub fn arrow_group(
  component: Component(model, message, html),
  items _items: String,
  orientation _orientation: Orientation,
  wrap _wrap: Bool,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// Make a set of sibling elements one arrow-navigable group (the 'roving
/// tabindex' pattern). While focus is on one, the arrow keys allowed by
/// `orientation` (plus Home and End) move to the previous or next item. `wrap`
/// decides whether moving past either end loops around.
///
/// Pipe-friendly and scoped like [`on`](#on): `items` is relative to the
/// component's scope (its `id`), so `'[role=menuitem]'` composes to
/// `#<id> [role=menuitem]`. Registers at
/// [`component.mount()`](./component.html#mount) and re-queries items on every
/// keypress, so a transient overlay's items are handled the moment it opens.
///
/// Unlike [`focus_trap`](#focus_trap)'s one-active stack, several groups
/// coexist, the active one on a keypress is whichever contains the focused
/// element. Focus moves with `element.focus()`, so non-active items can carry
/// `tabindex="-1"` and still be reached by the arrows.
pub fn arrow_group(
  component: Component(model, message, html),
  items items: String,
  orientation orientation: Orientation,
  wrap wrap: Bool,
) -> Component(model, message, html) {
  let selector = compose_items(component, items)
  let orientation_value = case orientation {
    Horizontal -> "horizontal"
    Vertical -> "vertical"
    Both -> "both"
  }
  component.attach_event(component, fn(_runtime) {
    setup_focus_group(selector, orientation_value, wrap)
  })
}

/// Recover a message encoded by [`encode_message`](#encode_message). Returns
/// `Error(Nil)` for any string this module did not produce, so it drops into
/// [`on_decoded()`](#on_decoded) as the `decoder` and coexists with handlers
/// reading readable `data-message` tags (those decline here and are handled by
/// their own listeners).
///
/// ```gleam
/// root
/// |> event.on_decoded(
///   event: event.click,
///   selector: ".lily-ui-root",
///   decoder: event.decode_message,
/// )
/// ```
pub fn decode_message(encoded: String) -> Result(message, Nil) {
  case encoded {
    "lily-message:" <> payload -> {
      use bytes <- result.try(bit_array.base64_decode(payload))
      use value <- result.try(auto_codec.decode_message_pack(bytes))
      Ok(reflection.passthrough(value))
    }
    _ -> Error(Nil)
  }
}

/// Serialise `message` into an attribute-safe string for `data-message`, so a
/// stateless element can carry a typed message that
/// [`decode_message()`](#decode_message) recovers at the root. Round-trips
/// through Lily's reflection codec, the same one
/// [`transport`](./transport.html) uses, so no separate encoder is needed.
///
/// ```gleam
/// html.button(
///   [attribute.data("message", event.encode_message(SaveDraft))],
///   [html.text("Save")],
/// )
/// ```
pub fn encode_message(message: a) -> String {
  "lily-message:"
  <> bit_array.base64_encode(auto_codec.encode_message_pack(message), False)
}

@target(javascript)
/// Move focus to the first element matching `selector`. Runs after the next
/// paint so it's safe from a `client.on_message` hook whose dispatch may have
/// just rendered the target. No-op if nothing matches.
///
/// ```gleam
/// client.on_message(runtime, fn(message, _model) {
///   case message {
///     OpenDialog -> event.focus("#dialog-cancel")
///     CloseDialog -> event.focus("#dialog-trigger")
///     _ -> Nil
///   }
/// })
/// ```
pub fn focus(selector: String) -> Nil {
  setup_focus(selector)
}

@target(erlang)
/// Erlang no-op twin.
pub fn focus_on_mount(
  component: Component(model, message, html),
  selector _selector: String,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// Focus the first match of `selector` when the component renders in. The
/// non-modal counterpart to [`focus_trap`](#focus_trap), it fires from the
/// component's own render, not a DOM observer, so an overlay seeds focus as it
/// opens.
pub fn focus_on_mount(
  component: Component(model, message, html),
  selector selector: String,
) -> Component(model, message, html) {
  component.attach_event(component, fn(_runtime) { setup_focus(selector) })
}

@target(javascript)
/// Confine Tab and Shift+Tab cycling to focusable descendants of the element
/// matching `within`. Pushes onto a stack so nested overlays (a Combobox in a
/// Dialog in a Drawer) each keep their scope. Focusables are re-enumerated on
/// every Tab press, so dynamic content is handled.
///
/// While this trap is on top, `release_on` runs on every keydown, returning
/// `True` pops the trap and dispatches `on_exit`'s message. Opening another
/// trap suspends this one until it pops.
///
/// Pair with [`focus`](#focus) to seed focus inside the region, and
/// [`release_focus_trap`](#release_focus_trap) for imperative release.
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

@target(erlang)
/// Erlang no-op twin.
pub fn on(
  component: Component(model, message, html),
  event _event: Event(payload),
  handler _handler: fn(payload) -> message,
  options _options: EventOptions,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// Bind an event handler to a component. The handler dispatches a message, and
/// `event` fixes the payload type so it's checked at compile time. Registered
/// during [`component.mount()`](./component.html#mount).
///
/// Scoped to the component's own subtree, firing only for `event`s inside the
/// element matched by its scope selector (the `id`, via
/// [`component.scoped`](./component.html#scoped)). Attach to a narrower or
/// wider component to narrow or widen. For page-level listeners (`document`
/// keydown, `window` resize, a root `data-message` decoder) use
/// [`on_global`](#on_global).
///
/// A scopeless component still works, the binding falls back to a document-wide
/// listener and a dev warning nudges you to add an `id`. Bindings inside
/// [`each`](./component.html#each) item bodies are ignored, so attach them to
/// the wrapper or a static ancestor.
///
/// Pass `options: event.defaults` for no modifiers, or update one field of it
/// with a record update.
///
/// ```gleam
/// component.simple(slice: ..., render: ...)
/// |> component.scoped("#search")
/// |> event.on(
///   event: event.input,
///   handler: Search,
///   options: event.EventOptions(
///     ..event.defaults,
///     debounce_milliseconds: option.Some(200),
///   ),
/// )
/// ```
pub fn on(
  component: Component(model, message, html),
  event event: Event(payload),
  handler handler: fn(payload) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  let selector = resolve_scope(component)
  let binding = fn(runtime: Runtime(model, message)) {
    let dispatch = fn(payload: payload) {
      client.send_message(runtime, handler(payload))
    }
    register_event(event, selector, options, dispatch)
  }
  component.attach_event(component, binding)
}

@target(erlang)
/// Erlang no-op twin.
pub fn on_decoded(
  component: Component(model, message, html),
  event _event: Event(payload),
  decoder _decoder: fn(payload) -> Result(message, Nil),
  options _options: EventOptions,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// Bind an event handler whose decoder may decline by returning `Error(Nil)`.
/// Useful for [`click`](#click) (the `data-message` may not match a known
/// message) and form events (validation failure should skip dispatch).
///
/// ```gleam
/// component.fragment([...])
/// |> component.scoped("#todo-form")
/// |> event.on_decoded(
///   event: event.form_submit,
///   decoder: submit_todo,
///   options: event.defaults,
/// )
/// ```
pub fn on_decoded(
  component: Component(model, message, html),
  event event: Event(payload),
  decoder decoder: fn(payload) -> Result(message, Nil),
  options options: EventOptions,
) -> Component(model, message, html) {
  let selector = resolve_scope(component)
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

@target(erlang)
/// Erlang no-op twin.
pub fn on_global(
  component: Component(model, message, html),
  event _event: Event(payload),
  selector _selector: String,
  handler _handler: fn(payload) -> message,
  options _options: EventOptions,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// The page-level counterpart to [`on`](#on), binding with an explicit,
/// verbatim `selector` rather than scoping to the component's subtree. Use it
/// for listeners tied to the page rather than one component, a `document`
/// keydown, a `window` resize, or the app-root `data-message` click decoder.
///
/// Still takes a `component` first so it composes into the view tree the same
/// way, the scope is ignored and only the mount-time tree walk that collects
/// the binding matters. `selector` is used exactly as given, so the listener
/// survives arbitrary DOM churn.
///
/// ```gleam
/// root
/// |> event.on_global(
///   event: event.key_down,
///   selector: "document",
///   handler: fn(ke) { KeyPressed(ke.key) },
///   options: event.defaults,
/// )
/// ```
pub fn on_global(
  component: Component(model, message, html),
  event event: Event(payload),
  selector selector: String,
  handler handler: fn(payload) -> message,
  options options: EventOptions,
) -> Component(model, message, html) {
  let binding = fn(runtime: Runtime(model, message)) {
    let dispatch = fn(payload: payload) {
      client.send_message(runtime, handler(payload))
    }
    register_event(event, selector, options, dispatch)
  }
  component.attach_event(component, binding)
}

@target(erlang)
/// Erlang no-op twin.
pub fn on_global_decoded(
  component: Component(model, message, html),
  event _event: Event(payload),
  selector _selector: String,
  decoder _decoder: fn(payload) -> Result(message, Nil),
  options _options: EventOptions,
) -> Component(model, message, html) {
  component
}

@target(javascript)
/// The [`on_decoded`](#on_decoded) counterpart to [`on_global`](#on_global), a
/// page-level binding whose decoder may decline with `Error(Nil)`. Canonical
/// use is the app-root click decoder recovering every `data-message` dispatch.
///
/// ```gleam
/// root
/// |> event.on_global_decoded(
///   event: event.click,
///   selector: ".lily-ui-root",
///   decoder: event.decode_message,
///   options: event.defaults,
/// )
/// ```
pub fn on_global_decoded(
  component: Component(model, message, html),
  event event: Event(payload),
  selector selector: String,
  decoder decoder: fn(payload) -> Result(message, Nil),
  options options: EventOptions,
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
/// Pop the top focus trap from the stack, reactivating the one below if any.
/// No-op when empty. Does not dispatch the popped trap's `on_exit`, call this
/// when the caller runs its own close logic and just needs the trap unhooked
/// (a Cancel click that dispatches `CloseDialog` and restores focus
/// separately).
pub fn release_focus_trap() -> Nil {
  release_focus_trap_ffi()
}

@target(javascript)
/// Install the global document behaviours the components rely on, described on
/// [`Behaviour`](#Behaviour). Call once at startup. Each is idempotent, so a
/// repeated call still installs one handler.
///
/// ```gleam
/// event.watch([event.DetailsOpen, event.EscapeDismiss, event.FocusTraps])
/// ```
pub fn watch(behaviours behaviours: List(Behaviour)) -> Nil {
  list.each(behaviours, fn(behaviour) {
    case behaviour {
      DetailsOpen -> watch_details_open_ffi()
      EscapeDismiss -> watch_escape_dismiss_ffi()
      FileDrops -> watch_file_drops_ffi()
      FocusTraps -> watch_focus_traps_ffi()
      FocusoutDismiss -> watch_focusout_dismiss_ffi()
    }
  })
}

/// `blur` event, fires when an element loses focus.
pub const blur: Event(ElementData) = Event("blur", TypeElement)

/// `change` event, fires when an input value is committed (after blur).
/// For real-time updates, use [`input`](#input).
pub const change: Event(String) = Event("change", TypeValue)

/// `click` event, delegated against `data-message`. Payload is the matched
/// element's `data-message` value. Pair with [`on_decoded()`](#on_decoded) so
/// unknown messages can be skipped via `Error(Nil)`.
pub const click: Event(String) = Event("click", TypeClick)

/// `contextmenu` event, fires on right-click. Payload is `(x, y,
/// element)` relative to the viewport.
pub const context_menu: Event(#(Int, Int, ElementData)) = Event(
  "contextmenu",
  TypeCoordinatesElement,
)

/// `copy` event, fires when text is copied to the clipboard.
pub const copy: Event(Nil) = Event("copy", TypeEmpty)

/// `cut` event, fires when text is cut to the clipboard.
pub const cut: Event(Nil) = Event("cut", TypeEmpty)

/// Event options with nothing enabled, no debounce, no throttle, fires every
/// time, and neither `stopPropagation` nor `preventDefault`. Use a record
/// update to change one field,
/// `EventOptions(..event.defaults, debounce_milliseconds: option.Some(200))`.
pub const defaults: EventOptions = EventOptions(
  debounce_milliseconds: option.None,
  throttle_milliseconds: option.None,
  once: False,
  stop_propagation: False,
  prevent_default: False,
)

/// `dblclick` event, fires on a double click.
pub const double_click: Event(ElementData) = Event("dblclick", TypeElement)

/// `drag` event, fires repeatedly while an element is being dragged.
/// Consider throttling it via [`EventOptions`](#EventOptions).
pub const drag: Event(#(Int, Int)) = Event("drag", TypeCoordinates)

/// `dragend` event, fires once when a drag operation ends.
pub const drag_end: Event(ElementData) = Event("dragend", TypeElement)

/// `dragover` event, fires repeatedly while a dragged element is over a
/// valid drop target. Set `prevent_default` in the options to enable
/// dropping.
pub const drag_over: Event(#(Int, Int, ElementData)) = Event(
  "dragover",
  TypeCoordinatesElement,
)

/// `dragstart` event, fires once when a drag operation starts.
pub const drag_start: Event(#(Int, Int, ElementData)) = Event(
  "dragstart",
  TypeCoordinatesElement,
)

/// `drop` event, fires when a dragged element is dropped on a valid
/// target.
pub const drop: Event(#(Int, Int, ElementData)) = Event(
  "drop",
  TypeCoordinatesElement,
)

/// `focus` event, fires when an element receives focus. Named
/// `focus_event` to avoid collision with the [`focus()`](#focus) function.
pub const focus_event: Event(ElementData) = Event("focus", TypeElement)

/// `input` on a form, payload is the current `FormData` as name/value pairs.
/// The uncontrolled-form counterpart of [`input`](#input). Pair with
/// [`on_decoded()`](#on_decoded) to skip dispatch on validation failure.
pub const form_change: Event(List(#(String, String))) = Event(
  "input",
  TypeFormChange,
)

/// `submit` on a form, payload is the submitted `FormData` as name/value pairs.
/// Prevents the browser's default submission and resets the form after the
/// handler runs. Pair with [`on_decoded()`](#on_decoded) to skip dispatch on
/// validation failure.
pub const form_submit: Event(List(#(String, String))) = Event(
  "submit",
  TypeFormSubmit,
)

/// `input` event, fires immediately when an input value changes. Payload
/// is the current value. For delayed updates use [`change`](#change).
pub const input: Event(String) = Event("input", TypeValue)

/// `keydown` event, fires when a key is pressed.
pub const key_down: Event(KeyEvent) = Event("keydown", TypeKey)

/// `keyup` event, fires when a key is released.
pub const key_up: Event(KeyEvent) = Event("keyup", TypeKey)

/// `mousedown` event, fires when a mouse button is pressed. Payload is
/// `(x, y, element)`.
pub const mouse_down: Event(#(Int, Int, ElementData)) = Event(
  "mousedown",
  TypeCoordinatesElement,
)

/// `mouseenter` event, fires when the mouse enters an element's
/// boundary. Mapped to `mouseover` with a relatedTarget guard so
/// delegation works.
pub const mouse_enter: Event(ElementData) = Event("mouseenter", TypeElement)

/// `mouseleave` event, fires when the mouse leaves an element's
/// boundary. Mapped to `mouseout` with a relatedTarget guard so
/// delegation works.
pub const mouse_leave: Event(ElementData) = Event("mouseleave", TypeElement)

/// `mousemove` event, fires repeatedly while the mouse moves. Consider
/// throttling it via [`EventOptions`](#EventOptions).
pub const mouse_move: Event(#(Int, Int)) = Event("mousemove", TypeCoordinates)

/// `mouseup` event, fires when a mouse button is released.
pub const mouse_up: Event(#(Int, Int, ElementData)) = Event(
  "mouseup",
  TypeCoordinatesElement,
)

/// `offline` event (on `window`), fires when the browser loses connectivity.
pub const offline: Event(Nil) = Event("offline", TypeEmpty)

/// `online` event (on `window`), fires when the browser regains connectivity.
pub const online: Event(Nil) = Event("online", TypeEmpty)

/// `paste` event, fires when text is pasted from the clipboard.
pub const paste: Event(Nil) = Event("paste", TypeEmpty)

/// `pointerdown` event, unifies mouse, touch, and pen.
pub const pointer_down: Event(#(Int, Int)) = Event(
  "pointerdown",
  TypeCoordinates,
)

/// `pointermove` event, unifies mouse, touch, and pen.
pub const pointer_move: Event(#(Int, Int)) = Event(
  "pointermove",
  TypeCoordinates,
)

/// `pointerup` event, unifies mouse, touch, and pen.
pub const pointer_up: Event(#(Int, Int)) = Event("pointerup", TypeCoordinates)

/// `resize` event, fires when an element (or window) resizes.
/// Typically used with `selector: "window"`.
pub const resize: Event(Nil) = Event("resize", TypeEmpty)

/// `scroll` event, payload is `(scroll_top, scroll_left)`. Consider
/// throttling it via [`EventOptions`](#EventOptions).
pub const scroll: Event(#(Int, Int)) = Event("scroll", TypeScroll)

/// `submit` event, no payload. Prevents the browser's default submission. Use
/// for controlled forms (input state already in the model), for uncontrolled
/// forms use [`form_submit`](#form_submit).
pub const submit: Event(Nil) = Event("submit", TypeSubmit)

/// `touchend` event, fires when all touches are removed.
pub const touch_end: Event(ElementData) = Event("touchend", TypeElement)

/// `touchmove` event, fires repeatedly while a touch point moves.
/// Consider throttling it via [`EventOptions`](#EventOptions).
pub const touch_move: Event(#(Int, Int)) = Event("touchmove", TypeCoordinates)

/// `touchstart` event, fires when a touch point is placed.
pub const touch_start: Event(#(Int, Int)) = Event("touchstart", TypeCoordinates)

/// `wheel` event, payload is `(delta_x, delta_y)`. Useful for scroll
/// hijacking and zoom controls.
pub const wheel: Event(#(Float, Float)) = Event("wheel", TypeWheel)

// =============================================================================
// PRIVATE TYPES
// =============================================================================

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
fn compose_items(
  component: Component(model, message, html),
  items: String,
) -> String {
  // `items` is relative to the component's scope, so `[role=menuitem]`
  // resolves against `#<id>`. A scopeless component treats `items` as absolute.
  case component.scope(component) {
    option.Some(scope) -> scope <> " " <> items
    option.None -> items
  }
}

@target(javascript)
fn register_event(
  event: Event(payload),
  selector: String,
  options: EventOptions,
  dispatch: fn(payload) -> Nil,
) -> Nil {
  // Each Event constant pairs `event_type` with the phantom `payload` type at
  // its declaration, so the casts below are safe by construction, the handler
  // signature is already constrained to match.
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
      // Bake prevent-default in regardless of caller options
      let typed: fn(Nil) -> Nil = unsafe_cast(dispatch)
      let with_prevent_default =
        unpack_options(EventOptions(..options, prevent_default: True))
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
fn resolve_scope(component: Component(model, message, html)) -> String {
  // Scoped binders confine the listener to the component's own subtree. A
  // scopeless component falls back to document-wide, the old global footgun,
  // so warn to nudge an `id` / `component.scoped`.
  case component.scope(component) {
    option.Some(selector) -> selector
    option.None -> {
      warn_scopeless()
      "document"
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
@external(javascript, "./event.ffi.mjs", "setupFocusGrid")
fn setup_focus_grid(items: String, columns: Int, wrap: Bool) -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "setupFocusGroup")
fn setup_focus_group(items: String, orientation: String, wrap: Bool) -> Nil

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

@target(javascript)
@external(javascript, "./event.ffi.mjs", "identity")
fn unsafe_cast(value: a) -> b

@target(javascript)
@external(javascript, "./event.ffi.mjs", "warnScopeless")
fn warn_scopeless() -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "watchDetailsOpen")
fn watch_details_open_ffi() -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "watchEscapeDismiss")
fn watch_escape_dismiss_ffi() -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "watchFileDrops")
fn watch_file_drops_ffi() -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "watchFocusTraps")
fn watch_focus_traps_ffi() -> Nil

@target(javascript)
@external(javascript, "./event.ffi.mjs", "watchFocusoutDismiss")
fn watch_focusout_dismiss_ffi() -> Nil
