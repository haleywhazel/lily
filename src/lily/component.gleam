//// Components subscribe to the [`Store`](./store.html#Store) and re-render
//// when their slice of the model changes. Being stateless and focused on
//// rendering keeps them light (lighter than Lustre or LiveView components, for
//// example), and having a lot of components is not an anti-pattern in Lily.
////
//// Each component is a [`ComponentType`](#ComponentType) plus zero or more
//// [`Decoration`](#Decoration)s (the things you pipe on, like a transition or
//// an event listener). You never reach for the constructors directly, you call
//// the builder function for the type you want.
////
//// There are five kinds, and every one takes a `render` function that returns
//// your `html` type:
////
//// 1. [`static`](#static) renders once and never updates
//// 2. [`simple`](#simple) morphs the subtree in place when the slice changes
//// 3. [`live`](#live) applies targeted patches you hand-write
//// 4. [`each`](#each) is a keyed list of rows, and
////    [`each_live`](#each_live) is the same list patched in place
//// 5. [`fragment`](#fragment) groups other components into one slot
////
//// `simple` is usually best for any dynamic component that you want to use
//// (that reacts to changes in the store), and `live` lets you hand-write
//// patches if you want smoother patching of dynamic components instead of
//// having to run through a large DOM subtree at every frame. Lily doesn't use
//// a VDOM so these choices are yours to make for your own performance
//// requirements.
////
//// A `live` component's `render` must carry the state, not just the layout.
//// It builds the first paint, and it is also what renders on the server and
//// when the component mounts late, meaning a `render` that ignores the slice
//// shows stale state until the first patch. The `patch` function only changes
//// what is already there, and it reads the same slice as `render`.
////
//// On top of its kind, a component carries decorations, each applied with a
//// pipe:
//// 1. [`transition`](#transition) adds CSS enter/exit classes timed to a
////    duration (with deferred DOM removal so the exit animation finishes
////    before the element leaves)
//// 2. [`event.on`](./event.html#on) and the typed helpers such as
////    [`event.on_click`](./event.html#on_click) attach listeners, scoped to
////    the component they are piped onto
////
//// A listener wraps the component's DOM so it knows where its scope starts.
//// Having no element of its own, a `static` or `fragment` with a listener is
//// rendered inside a `display: contents` wrapper that doesn't change the
//// layout.
////
//// Every `render` function is handed a `slot` function as its last argument.
//// Call `slot(child_component)` wherever you want a child to appear in the
//// parent template, it returns a placeholder of your `html` type that gets
//// swapped for the rendered child once the parent serialises. Nest it as deep
//// as you like:
////
//// ```gleam
//// component.live(
////   slice: fn(model) { model.is_active },
////   render: fn(_, slot) {
////     html.section([attribute.class("column")], [
////       html.h2([], [html.text("Title")]),
////       slot(component.each(
////         slice: fn(model) { cards_for(model) },
////         key: fn(card) { card.id },
////         render: fn(card, _) { card_html(card) },
////       )),
////     ])
////   },
////   patch: column_patches,
//// )
//// ```
////
//// When a component has no children, just ignore the parameter:
////
//// ```gleam
//// component.simple(
////   slice: fn(model) { model.count },
////   render: fn(count, _) {
////     html.div([], [html.text(int.to_string(count))])
////   },
//// )
//// ```
////
//// A list's rows are plain markup. The list compares its slice once per update
//// and each row against its previous version by reference, letting an update
//// that leaves a row alone cost almost nothing as long as the rows are kept as
//// records in the model. Row-specific state, like a selection, lives in the
//// rows, and list-wide presentation is CSS on the container. A row that needs
//// a reactive part of its own calls `slot` for it.
////
//// Components work with any HTML library, Lustre or raw strings, whatever you
//// like. The `to_html` function you pass at [`mount`](#mount) converts your
//// chosen library's types into strings, we'd recommend
//// [Lustre elements](https://hexdocs.pm/lustre/lustre/element/html.html). If
//// you use nesting, also pass `to_slot`, a zero-argument function returning an
//// `html` placeholder that serialises to `<lily-slot></lily-slot>`. For
//// Lustre:
////
//// ```gleam
//// component.mount(
////   runtime,
////   selector: "#app",
////   to_html: element.to_string,
////   to_slot: fn() { element.element("lily-slot", [], []) },
////   view: app,
//// )
//// ```
////
//// Or with raw HTML strings:
////
//// ```gleam
//// component.mount(
////   runtime,
////   selector: "#app",
////   to_html: fn(html) { html },
////   to_slot: fn() { "<lily-slot></lily-slot>" },
////   view: app,
//// )
//// ```
////
//// Escaping is the `to_html` function's job, not Lily's. The rendered string
//// is written to the DOM verbatim through `innerHTML`. Lustre's
//// `element.to_string` escaping text and attribute values keeps the Lustre
//// path safe. The raw-string `to_html: fn(html) { html }` above does not
//// escape, making model data (which on a synced app can carry other clients'
//// input) interpolated straight into that string a stored-XSS vector. When
//// using raw strings, escape any untrusted text yourself. The `from_string`
//// argument of [`render_to_string`](#render_to_string) is the same, an
//// `unsafe_raw_html` style constructor inserts its string without escaping.
////
//// Every component declares a `slice` that pulls just the data it needs out of
//// the model. The runtime caches the last slice and skips rendering when it's
//// unchanged, comparing structurally (deep equality), meaning a slice that
//// builds a new tuple or record each time still compares equal by value. Keep
//// slices cheap and do the heavy lifting in `render`, which the comparison
//// gates. Here's the whole thing end to end:
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/event
//// import lily/store
//// import lustre/attribute
//// import lustre/element
//// import lustre/element/html
////
//// fn app(_model: Model) {
////   component.simple(
////     slice: fn(model: Model) { model.count },
////     render: fn(count, _) {
////       html.div([], [
////         html.button(
////           [attribute.data("message", event.encode_message(Decrement))],
////           [html.text("-")],
////         ),
////         html.p([], [html.text(int.to_string(count))]),
////         html.button(
////           [attribute.data("message", event.encode_message(Increment))],
////           [html.text("+")],
////         ),
////       ])
////     },
////   )
//// }
////
//// pub fn main() {
////   let runtime =
////     store.new(init: Model(count: 0), update: update)
////     |> client.start
////
////   runtime
////   |> component.mount(
////     selector: "#app",
////     to_html: element.to_string,
////     to_slot: fn() { element.element("lily-slot", [], []) },
////     view: app,
////   )
//// }
//// ```
////
//// With [`mount`](#mount) itself picking up clicks on an element carrying
//// `data-message`, the buttons above need no handler. For
//// anything else, pipe [`event.on`](./event.html#on) or one of its helpers
//// onto the component. A listener fires for events inside that component, and
//// the ones piped onto a list's rows are not collected, meaning they belong
//// on the list or an ancestor instead.
////
//// Building components and rendering them to a string with
//// [`render_to_string`](#render_to_string) work on both targets so that the
//// server can render initial components.
////
//// [`mount`](#mount) and event handling are JavaScript-only, since they drive
//// a live DOM.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option}
import gleam/string

@target(javascript)
import lily/client.{type Runtime}
@target(javascript)
import lily/internal/codec

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// A piece of UI that renders part of the model, built with
/// [`simple`](#simple), [`live`](#live), [`each`](#each), [`static`](#static)
/// or [`fragment`](#fragment).
///
/// `html` is whatever type your HTML library uses for markup.
pub opaque type Component(model, message, html) {
  Component(
    component_type: ComponentType(model, message, html),
    decorations: List(Decoration(message)),
  )
}

/// A targeted DOM update, returned by the `patch` function of [`live`](#live)
/// and [`each_live`](#each_live).
///
/// `target` is a CSS selector under the component's root, and an empty string
/// means the root itself.
pub type Patch {
  /// Remove an HTML attribute
  RemoveAttribute(target: String, name: String)
  /// Set an HTML attribute
  SetAttribute(target: String, name: String, value: String)
  /// Set a CSS style property
  SetStyle(target: String, property: String, value: String)
  /// Set an element's textContent (wipes children)
  SetText(target: String, value: String)
}

/// The `slot` function every `render` receives as its last argument. Call it
/// with a child component where the child should appear.
pub type Slotter(model, message, html) =
  fn(Component(model, message, html)) -> html

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// A keyed list of rows where only the rows that changed update.
///
/// `slice` returns the list, `key` identifies a row and `render` returns its
/// markup. Keep the rows as records in the model so an untouched row is
/// skipped, and call `slot` in a row for a part that reacts on its own.
///
/// Listeners piped onto anything inside a row are ignored, meaning they belong
/// on the list or an ancestor.
///
/// ```gleam
/// component.each(
///   slice: fn(model) { model.counters },
///   key: fn(counter) { counter.id },
///   render: fn(counter, _) {
///     html.div([class("counter")], [
///       html.text(int.to_string(counter.value))
///     ])
///   }
/// )
/// ```
pub fn each(
  slice slice: fn(model) -> List(item),
  key key: fn(item) -> key,
  render render: fn(item, Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(Each(
    slice: fn(model) { list_dynamic(slice(model)) },
    key: fn(item) { key_to_string(key(from_dynamic(item))) },
    render: fn(item, slotter) { render(from_dynamic(item), slotter) },
    patch: option.None,
  ))
}

/// A keyed list whose changed rows are patched in place, the list version of
/// [`live`](#live).
///
/// `render` builds a row when it first appears, and `patch` returns the
/// updates for a row that changed.
///
/// ```gleam
/// component.each_live(
///   slice: fn(model) { model.boxes },
///   key: fn(box) { box.id },
///   render: fn(box, _) { box_html(box) },
///   patch: fn(box) {
///     [SetStyle(".box", "transform", transform(box))]
///   },
/// )
/// ```
pub fn each_live(
  slice slice: fn(model) -> List(item),
  key key: fn(item) -> key,
  render render: fn(item, Slotter(model, message, html)) -> html,
  patch patch: fn(item) -> List(Patch),
) -> Component(model, message, html) {
  new_component(Each(
    slice: fn(model) { list_dynamic(slice(model)) },
    key: fn(item) { key_to_string(key(from_dynamic(item))) },
    render: fn(item, slotter) { render(from_dynamic(item), slotter) },
    patch: option.Some(fn(item) { patch(from_dynamic(item)) }),
  ))
}

/// Groups several components into one, rendered in order, like Lustre's
/// `element.fragment`.
///
/// ```gleam
/// fn app(_model: Model) -> Component(Model, Message, Element(Message)) {
///   component.fragment([
///     component.static(fn(_) { html.h1([], [html.text("My App")]) }),
///     component.simple(...),
///     component.each(...),
///   ])
/// }
/// ```
pub fn fragment(
  children: List(Component(model, message, html)),
) -> Component(model, message, html) {
  new_component(Fragment(children))
}

/// Renders once, then applies the [`Patch`](#Patch)es you return when its
/// slice changes.
///
/// Use it for a hot path where [`simple`](#simple) is measurably too slow, not
/// just to keep focus or input, which `simple` already does.
///
/// `render` must draw the slice's current state, not only the layout.
///
/// ```gleam
/// component.live(
///   slice: fn(model) { model.data },
///   render: fn(data, _) {
///     html.div([], [
///       html.span([class("value")], [html.text(int.to_string(data))]),
///       html.div([class("bar")], [])
///     ])
///   },
///   patch: fn(data) {
///     [
///       SetText(".value", int.to_string(data)),
///       SetStyle(".bar", "width", int.to_string(data) <> "%"),
///     ]
///   }
/// )
/// ```
pub fn live(
  slice slice: fn(model) -> a,
  render render: fn(a, Slotter(model, message, html)) -> html,
  patch patch: fn(a) -> List(Patch),
) -> Component(model, message, html) {
  new_component(
    Live(
      slice: fn(model) { to_dynamic(slice(model)) },
      render: fn(data, slotter) { render(from_dynamic(data), slotter) },
      patch: fn(data) { patch(from_dynamic(data)) },
    ),
  )
}

@target(javascript)
/// Renders a view into the element matching `selector` and keeps it up to date
/// with the store. JavaScript only.
///
/// `to_html` turns your `html` type into a string, and `to_slot` returns a
/// placeholder that serialises to `<lily-slot></lily-slot>`.
///
/// Clicks on an element whose `data-message` comes from
/// [`event.encode_message`](./event.html#encode_message) are dispatched for
/// you.
///
/// Mount other selectors on the same runtime to drive several roots from one
/// model. Mounting the same selector again replaces it.
///
/// ```gleam
/// runtime
/// |> component.mount(
///   selector: "#app",
///   to_html: element.to_string,
///   to_slot: fn() { element.element("lily-slot", [], []) },
///   view: app,
/// )
/// ```
pub fn mount(
  runtime: Runtime(model, message, mode),
  selector selector: String,
  to_html to_html: fn(html) -> String,
  to_slot to_slot: fn() -> html,
  view view: fn(model) -> Component(model, message, html),
) -> Runtime(model, message, mode) {
  // wait for registration so decoded values render with their types
  codec.when_registered(fn() {
    let model = client.model(runtime)
    let tree = view(model)
    render_tree(
      runtime,
      selector,
      tree,
      model,
      to_html,
      to_slot,
      client.dispatch(runtime),
      codec.decode_data_message,
    )
  })
  runtime
}

/// Renders a view to an HTML string without a DOM, for a server or a build
/// step to produce the first paint. Pair with
/// [`store.initial_snapshot`](./store.html#initial_snapshot).
///
/// `from_string` wraps a child's string back into your `html` type, such as an
/// `unsafe_raw_html` constructor for Lustre. Listeners and transitions are
/// skipped.
///
/// ```gleam
/// let html = component.render_to_string(
///   view: shared.view,
///   model: shared.initial_model(),
///   to_html: element.to_string,
///   from_string: element.unsafe_raw_html(_, "div", [], _),
/// )
/// ```
pub fn render_to_string(
  view view: fn(model) -> Component(model, message, html),
  model model: model,
  to_html to_html: fn(html) -> String,
  from_string from_string: fn(String) -> html,
) -> String {
  walk_to_string(view(model), model, to_html, from_string)
}

/// The default component, re-rendered when its slice changes while keeping
/// focus, cursor and in-progress input.
///
/// Reach for [`live`](#live) only when a large subtree updates so often that
/// this is measurably too slow.
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { model.count },
///   render: fn(count, _) {
///     html.div([], [html.text("Count: " <> int.to_string(count))])
///   }
/// )
/// ```
pub fn simple(
  slice slice: fn(model) -> a,
  render render: fn(a, Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(
    Simple(
      slice: fn(model) { to_dynamic(slice(model)) },
      render: fn(data, slot) { render(from_dynamic(data), slot) },
    ),
  )
}

/// Renders once and never updates, for anything that doesn't depend on the
/// model.
///
/// ```gleam
/// component.static(fn(_) { html.h1([], [html.text("My App")]) })
/// ```
pub fn static(
  render render: fn(Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(Static(render))
}

/// Adds CSS enter and exit classes to a component, timed to a duration.
///
/// `enter` is applied when it appears, and `exit` when a list or a `simple`
/// re-render removes it, with the removal held back until the animation ends.
/// Use `forwards` on the exit animation so it doesn't flicker before removal.
///
/// ```css
/// .dialog-enter { animation: dialog-enter 200ms; }
/// .dialog-exit  { animation: dialog-exit 200ms forwards; }
/// @keyframes dialog-enter { from { opacity: 0 } to { opacity: 1 } }
/// @keyframes dialog-exit  { from { opacity: 1 } to { opacity: 0 } }
/// ```
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { model.open },
///   render: fn(open, slot) {
///     case open {
///       True ->
///         slot(
///           component.static(fn(_) { render_panel() })
///           |> component.transition(
///             enter: "panel-enter",
///             exit: "panel-exit",
///             duration_milliseconds: 200,
///           ),
///         )
///       False -> html.text("")
///     }
///   },
/// )
/// ```
pub fn transition(
  component: Component(model, message, html),
  enter enter: String,
  exit exit: String,
  duration_milliseconds duration_milliseconds: Int,
) -> Component(model, message, html) {
  decorate(component, Transition(enter:, exit:, duration_milliseconds:))
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@internal
pub type ComponentType(model, message, html) {
  Each(
    slice: fn(model) -> List(Dynamic),
    key: fn(Dynamic) -> String,
    render: fn(Dynamic, Slotter(model, message, html)) -> html,
    patch: Option(fn(Dynamic) -> List(Patch)),
  )

  Fragment(children: List(Component(model, message, html)))

  Live(
    slice: fn(model) -> Dynamic,
    render: fn(Dynamic, Slotter(model, message, html)) -> html,
    patch: fn(Dynamic) -> List(Patch),
  )

  Simple(
    slice: fn(model) -> Dynamic,
    render: fn(Dynamic, Slotter(model, message, html)) -> html,
  )

  Static(render: fn(Slotter(model, message, html)) -> html)
}

@internal
pub type Decoration(message) {
  Transition(enter: String, exit: String, duration_milliseconds: Int)

  /// `run` returns `Error` to skip the event, a non-empty reason is logged
  /// once.
  Listener(
    event: String,
    run: fn(Dynamic) -> Result(message, String),
    selector: Option(String),
    debounce_milliseconds: Option(Int),
    throttle_milliseconds: Option(Int),
    once: Bool,
    prevent_default: Bool,
    stop_propagation: Bool,
    reset_form: Bool,
  )
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@internal
pub fn decorate(
  component component: Component(model, message, html),
  decoration decoration: Decoration(message),
) -> Component(model, message, html) {
  // O(1) prepend, consumers reverse for attach order
  Component(..component, decorations: [decoration, ..component.decorations])
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn make_slotter(
  model: model,
  to_html: fn(html) -> String,
  from_string: fn(String) -> html,
) -> Slotter(model, message, html) {
  fn(child: Component(model, message, html)) {
    let child_string = walk_to_string(child, model, to_html, from_string)
    from_string(child_string)
  }
}

fn new_component(
  component_type: ComponentType(model, message, html),
) -> Component(model, message, html) {
  Component(component_type:, decorations: [])
}

// decorations skipped, they need a live DOM
fn walk_to_string(
  component: Component(model, message, html),
  model: model,
  to_html: fn(html) -> String,
  from_string: fn(String) -> html,
) -> String {
  let slotter = make_slotter(model, to_html, from_string)
  case component.component_type {
    Static(render:) -> to_html(render(slotter))

    Simple(slice:, render:) -> to_html(render(slice(model), slotter))

    Live(slice:, render:, patch: _) -> to_html(render(slice(model), slotter))

    Each(slice:, key: _, render:, patch: _) -> {
      slice(model)
      |> list.map(fn(item) { to_html(render(item, slotter)) })
      |> string.concat
    }

    Fragment(children:) ->
      children
      |> list.map(walk_to_string(_, model, to_html, from_string))
      |> string.concat
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@external(erlang, "lily_codec_ffi", "passthrough")
@external(javascript, "./internal/codec.ffi.mjs", "passthrough")
fn from_dynamic(value: Dynamic) -> a

// JavaScript keeps string and number keys as is
@external(javascript, "./component.ffi.mjs", "keyToString")
fn key_to_string(key: a) -> String {
  string.inspect(key)
}

@external(erlang, "lily_codec_ffi", "passthrough")
@external(javascript, "./internal/codec.ffi.mjs", "passthrough")
fn list_dynamic(value: List(a)) -> List(Dynamic)

@target(javascript)
@external(javascript, "./component.ffi.mjs", "renderTree")
fn render_tree(
  runtime: Runtime(model, message, mode),
  root_selector: String,
  component: Component(model, message, html),
  model: model,
  to_html: fn(html) -> String,
  to_slot: fn() -> html,
  dispatch: fn(message) -> Nil,
  decode_message: fn(String) -> Result(message, Nil),
) -> Nil

@external(erlang, "lily_codec_ffi", "passthrough")
@external(javascript, "./internal/codec.ffi.mjs", "passthrough")
fn to_dynamic(value: a) -> Dynamic
