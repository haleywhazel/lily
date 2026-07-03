//// Components subscribe to the [`Store`](./store.html#Store) and re-render
//// when their slice of the model changes. They're functions that return
//// renderable content, composable like React or Lustre components. That said,
//// it's closer to React than Lustre, with smaller, more modular components
//// being preferable as components themselves don't hold states.
////
//// Each component consists of its type [`ComponentType`](#ComponentType) and
//// optional [`Decoration`](#Decoration)s, which are things like attaching
//// transitions or events to them.
////
//// Lily provides seven component types, each with different performance
//// characteristics. We interact with functions that build the components
//// rather than the type constructors directly.
////
//// 1. [`static`](#static) renders once and never updates
//// 2. [`simple`](#simple) re-renders via innerHTML when the slice changes
//// 3. [`live`](#live) applies targeted patches instead of full re-renders
//// 4. [`each`](#each) handles keyed lists with innerHTML rendering
//// 5. [`each_live`](#each_live) handles keyed lists with patch-based rendering
//// 6. [`fragment`](#fragment) groups other components into one slot
//// 7. [`switch`](#switch) renders one of several children based on a
////    discriminator, preserving DOM identity when the discriminator is
////    unchanged
////
//// On top of its type, a component carries zero or more
//// [`Decoration`](#Decoration)s, each applied with a pipe:
////
//// - [`transition`](#transition) adds CSS enter/exit classes timed to a
////   duration, with deferred DOM removal so exit animations finish before
////   the element is gone
//// - [`event.on`](./event.html#on) and friends attach event listeners
//// - [`require_connection`](#require_connection) gates the subtree on
////   connection status
////
//// `simple` replaces the component's entire DOM on every slice change, which
//// destroys focus, selection, and any in-progress user input. `live` applies
//// targeted patches instead, leaving existing nodes untouched, so focus and
//// typed text are preserved across model updates. Whenever there are elements
//// like `<input>` and `<textarea>`, `live` is probably better.
////
//// The same rule applies to list components, use `each_live` instead of
//// `each` when list items contain inputs or must not lose focus on update.
////
//// ## Nesting components
////
//// `static`, `simple`, and `live` accept a `slot` function as the first
//// parameter of their content function. Call `slot(child_component)` wherever
//// you want a child component to appear in the parent template. The call
//// returns a placeholder value of your `html` type that is substituted with
//// the rendered child after the parent template is serialised.
////
//// ```gleam
//// component.live(
////   slice: fn(model) { model.is_active },
////   initial: fn(slot) {
////     html.section([attribute.class("column")], [
////       html.h2([], [html.text("Title")]),
////       slot(component.each_live(
////         slice: fn(model) { cards_for(model) },
////         key: fn(card) { card.id },
////         initial: render_card,
////         patch: card_patches,
////       )),
////     ])
////   },
////   patch: column_patches,
//// )
//// ```
////
//// If no children are needed, ignore the parameter:
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
//// Components work with any HTML library - Lustre or raw strings. The
//// `to_html` function provided at [`component.mount`](#mount) converts
//// your chosen library's types to strings. We recommend
//// [Lustre elements](https://hexdocs.pm/lustre/lustre/element/html.html).
////
//// To use nesting, also supply `to_slot` at mount, a zero-argument function
//// that returns an `html` placeholder value that serialises to
//// `<lily-slot></lily-slot>`. For Lustre:
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
//// For raw HTML strings:
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
//// Each component declares a `slice` function that extracts relevant data
//// from the model. The runtime caches the previous slice and skips rendering
//// when unchanged (using reference equality by default, structural equality
//// opt-in via [`component.structural`](#structural)).
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
//// fn decrement_button() {
////   html.button([attribute.data("message", "decrement")], [html.text("-")])
//// }
////
//// fn increment_button() {
////   html.button([attribute.data("message", "increment")], [html.text("+")])
//// }
////
//// fn app(_model: Model) {
////   component.simple(
////     slice: fn(model: Model) { model.count },
////     render: fn(count, _) {
////       html.div([], [
////         decrement_button(),
////         html.p([], [html.text(int.to_string(count))]),
////         increment_button(),
////       ])
////     },
////   )
////   |> event.on_global_decoded(
////     event: event.click,
////     selector: "#app",
////     decoder: parse_click,
////   )
//// }
////
//// pub fn main() {
////   let runtime =
////     store.new(Model(count: 0), with: update)
////     |> client.start(shared.wiring())
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
//// Event handlers are pipelined onto the component they relate to via
//// [`event.on()`](./event.html#on) and friends. The walk in
//// [`mount`](#mount) registers each binding once at startup. Events
//// declared inside [`each`](#each) and [`each_live`](#each_live) item
//// bodies are not collected, place them on the each/each_live wrapper or
//// any static ancestor instead.
////
//// Building components and rendering them to a string
//// ([`render_to_string`](#render_to_string)) compile on both targets;
//// [`mount`](#mount) and event handling are JavaScript-only
//// (`@target(javascript)`), since they drive a live DOM.
////

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option}
import gleam/string

@target(javascript)
import lily/client.{type Runtime}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Component is the core type representing renderable content in Lily. The
/// constructors for Component is kept opaque, use the associated functions to
/// create components instead. The `html` type parameter is user-provided and
/// can be any type that represents HTML markup.
///
/// Each dynamic [`ComponentType`](#ComponentType) variant (all but `Static`
/// and `Fragment`) carries a `compare_structural` flag. `False` (the
/// default) means slice changes are detected by reference equality (`===`,
/// O(1)); `True` means structural equality (`==`, O(n)) and is set by
/// piping a component through [`structural`](#structural). Use structural
/// when the slice constructs new tuples, lists, or records on every call.
///
/// Components compile on both targets. The constructor functions and the
/// pure walker [`render_to_string`](#render_to_string) work on Erlang and
/// JavaScript alike. [`mount`](#mount) is JavaScript-only because it
/// mutates the live DOM.
pub opaque type Component(model, message, html) {
  /// A component is a `component_type` (how it renders) plus a list of
  /// `decorations` (cross-cutting attributes layered on top: a CSS
  /// transition, event listeners, a connection gate). Decorations are
  /// applied innermost-first in list order, so the last one wraps outermost.
  ///
  /// `scope` is the component's own CSS selector (usually `#<id>`), recorded
  /// by [`scoped`](#scoped). The `event.on*` binders read it to confine their
  /// listeners to this component's subtree; `None` means no scope was set.
  Component(
    component_type: ComponentType(model, message, html),
    decorations: List(Decoration(model)),
    scope: Option(String),
  )
}

/// Patches are DOM updates to apply to a component, avoiding a full re-render
/// used for [`component.live`](#live) and
/// [`component.each_live`](#each_live). The `target` field is a CSS selector
/// relative to the component's root element, with an empty string provided
/// if the component's root element is itself. Patches are scoped to their
/// component, preventing cross-component interference. The type compiles
/// on both targets so it can appear in the [`Component`](#Component)'s
/// patch-bearing variants on Erlang too; the patches themselves are only
/// applied by [`mount`](#mount), which is JavaScript-only.
pub type Patch {
  /// Remove an HTML attribute
  RemoveAttribute(target: String, name: String)
  /// Set an HTML attribute
  SetAttribute(target: String, name: String, value: String)
  /// Set a CSS style property
  SetStyle(target: String, property: String, value: String)
  /// Set the textContent of an element (wipes children)
  SetText(target: String, value: String)
}

/// A function that accepts a child `Component` and returns a placeholder
/// value of your `html` type marking where that child will be rendered.
/// Passed as the first parameter of every `static`, `simple`, and `live`
/// content function. Call it inline wherever you want the child to appear;
/// call order determines DOM position.
pub type Slotter(model, message, html) =
  fn(Component(model, message, html)) -> html

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Manages a dynamic list of items with add/remove/reorder reconciliation.
/// Each item is identified by a unique key. When the list changes, only
/// the changed items are updated. [`component.each`](#each) differs from
/// [`component.each_live`](#each_live) in that it does a full re-render of
/// the HTML element instead of patches.
///
/// Avoid using `each` for list items that contain `<input>`, `<textarea>`,
/// or `<select>` elements, each changed item replaces its DOM via
/// `innerHTML`, destroying focus and in-progress user input. Use
/// [`each_live`](#each_live) with targeted patches instead.
///
/// `slice` must return a `List` rather than a single element, unlike
/// [`component.simple`](#simple).
///
/// While the type for key can be defined by the user, internally, these are
/// converted to `String`.
///
/// The `render` function is called for each item and returns a `Component`.
/// For plain HTML items, wrap with [`component.static`](#static).
///
/// Event bindings declared inside `render` are not collected. Attach
/// per-list events to this `each` component or any ancestor (selectors are
/// global, so one handler on `.card` covers every card).
///
/// ```gleam
/// component.each(
///   slice: fn(model) { model.counters },
///   key: fn(counter) { counter.id },
///   render: fn(counter) {
///     component.static(fn(_) {
///       html.div([class("counter")], [
///         html.text(int.to_string(counter.value))
///       ])
///     })
///   }
/// )
/// ```
pub fn each(
  slice slice: fn(model) -> List(item),
  key key: fn(item) -> key,
  render render: fn(item) -> Component(model, message, html),
) -> Component(model, message, html) {
  new_component(Each(
    slice: fn(model) { list_dynamic(slice(model)) },
    key: fn(item) { string.inspect(key(from_dynamic(item))) },
    render: fn(item) { render(from_dynamic(item)) },
    compare_structural: False,
  ))
}

/// Manages a dynamic list of items with add/remove/reorder reconciliation.
/// Each item is identified by a unique key. When the list changes, only
/// the changed items are updated. [`component.each_live`](#each_live) differs
/// from [`component.each`](#each) in that patches to the DOM element are
/// applied instead of a full re-render. This is useful when list items are
/// updated frequently.
///
/// `slice` must return a `List` rather than a single element, unlike
/// [`component.live`](#live).
///
/// While the type for key can be defined by the user, internally, these are
/// converted to `String`.
///
/// The `initial` function returns a `Component` for each item's first render.
/// Wrap plain HTML with [`component.static`](#static). The `patch`
/// function returns patches applied on updates (the item's root must remain).
///
/// Event bindings declared inside `initial` are not collected. Attach
/// per-list events to this `each_live` component or any ancestor (selectors
/// are global, so one handler covers every item).
///
/// ```gleam
/// component.each_live(
///   slice: fn(model) { model.series },
///   key: fn(series) { series.id },
///   initial: fn(series) {
///     component.static(fn(_) {
///       html.div([class("display-data")], [
///         html.span([class("value")], [html.text("0")])
///       ])
///     })
///   },
///   patch: fn(series) {
///     [SetText(".value", int.to_string(series.value))]
///   },
/// )
/// ```
pub fn each_live(
  slice slice: fn(model) -> List(item),
  key key: fn(item) -> key,
  initial initial: fn(item) -> Component(model, message, html),
  patch patch: fn(item) -> List(Patch),
) -> Component(model, message, html) {
  new_component(EachLive(
    slice: fn(model) { list_dynamic(slice(model)) },
    key: fn(item) { string.inspect(key(from_dynamic(item))) },
    initial: fn(item) { initial(from_dynamic(item)) },
    patch: fn(item) { patch(from_dynamic(item)) },
    compare_structural: False,
  ))
}

/// Fragments allow you to return multiple components from a single
/// function. The children are rendered in order and concatenated into the
/// parent's HTML. Similar to Lustre's `element.fragment`.
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

/// Live components render an initial HTML structure once, then apply DOM
/// patches on subsequent updates. This avoids the full innerHTML replacement
/// of [`simple`](#simple), which means existing nodes are never destroyed
/// between updates.
///
/// Use `live` whenever the component contains `<input>`, `<textarea>`, or
/// `<select>` elements. Because the DOM nodes are preserved, focus,
/// cursor position, and any in-progress user input survive model updates.
/// This also makes `live` the right choice for high-frequency updates such
/// as drag-and-drop, animations, and real-time data (60fps rendering).
///
/// The `patch` function returns a list of `Patch` values. Each patch targets
/// an element relative to the component's root using a CSS selector.
///
/// The first parameter of `initial` is a [`Slotter`](#Slotter), call
/// `slot(child_component)` wherever you want a nested component to appear.
/// Ignore it with `_` if no children are needed.
///
/// ## Example
///
/// ```gleam
/// component.live(
///   slice: fn(model) { model.data },
///   initial: fn(_) {
///     html.div([], [
///       html.span([class("value")], [html.text("0")]),
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
  initial initial: fn(Slotter(model, message, html)) -> html,
  patch patch: fn(a) -> List(Patch),
) -> Component(model, message, html) {
  new_component(Live(
    slice: fn(model) { to_dynamic(slice(model)) },
    initial: initial,
    apply: fn(data) { patch(from_dynamic(data)) },
    compare_structural: False,
  ))
}

@target(javascript)
/// This is the entry point for rendering, mounting a component tree to a
/// specific DOM element. It creates a subscription to the store, renders
/// the entire component tree, and walks the tree to register every event
/// binding attached via [`event.on()`](./event.html#on) and friends.
///
/// - `selector`: CSS selector for the mount point (e.g., `"#app"`)
/// - `to_html`: Function to convert `html` type to `String` (e.g.,
///   `element.to_string` for Lustre or `fn(html) {html}` for raw HTML strings)
/// - `to_slot`: Zero-argument function returning an `html` placeholder value
///   that serialises to `<lily-slot></lily-slot>`. Used when nesting components
///   via [`Slotter`](#Slotter). For Lustre:
///   `fn() { element.element("lily-slot", [], []) }`. For raw HTML strings:
///   `fn() { "<lily-slot></lily-slot>" }`.
/// - `view`: Function that takes the model and returns the root component tree
///
/// `mount` can be called more than once on a shared runtime, with
/// different selectors, to drive multiple DOM roots from one model. This
/// is how overlays / portals work: mount your main view at `#app` and a
/// secondary overlays view at `#overlays`. Both views subscribe to the
/// same model and update on every dispatch. Calling `mount` twice on the
/// same selector tears down the previous mount and replaces it.
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
  runtime: Runtime(model, message),
  selector selector: String,
  to_html to_html: fn(html) -> String,
  to_slot to_slot: fn() -> html,
  view view: fn(model) -> Component(model, message, html),
) -> Runtime(model, message) {
  let model = get_model(runtime)
  let tree = view(model)
  // Render handles binding registration too: renderComponent on the JS
  // side queues every component's `Listener` decorations (including those
  // inside slot children, which the Gleam-side tree walk can't reach
  // because slot children are constructed via the slotter callback at
  // render time). render_tree drains the queue after innerHTML, so
  // element-scoped listeners find their target in the DOM.
  render_tree(runtime, selector, tree, model, to_html, to_slot)

  runtime
}

/// Render a view to an HTML string without touching the DOM. Walks the
/// [`Component`](#Component) tree, calling each `render` / `initial` /
/// `content` function and piping through `to_html`. Compiles on both
/// targets, so it can produce the initial page markup ahead of time (at
/// build time, or from a plain request handler) rather than on a live DOM.
/// Pair with
/// [`transport.encode_initial_snapshot`](./transport.html#encode_initial_snapshot)
/// to embed the matching initial state and
/// [`client.hydrate`](./client.html#hydrate) so the client adopts the
/// pre-rendered DOM instead of re-rendering it on load. This is static
/// pre-rendering plus hydration from a fixed snapshot, not per-request
/// server-side rendering.
///
/// Nested components placed via the [`Slotter`](#Slotter) callback are
/// rendered inline: the walker renders each child to a string and uses
/// `from_string` to wrap that string back as an `html` value the user
/// composes into the parent. For raw-HTML libraries where `html` is just
/// `String`, `from_string` is the identity. For Lustre, pass an
/// `unsafe_raw_html`-style constructor that inserts the string verbatim.
///
/// Event bindings, focus management, and CSS transitions are skipped:
/// they only make sense on a live DOM. For [`live`](#live) and
/// [`each_live`](#each_live), the `initial` baseline is rendered; patches
/// only apply at runtime via [`mount`](#mount).
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

/// When you want to disable a component when the transport is disconnected,
/// this allows you to do that. The `connected` function extracts the
/// connection status from the model. When it returns `False`, Lily adds
/// `data-lily-disabled="true"` and `aria-disabled="true"` attributes plus a
/// `lily-disconnected` CSS class to the component's root element, and prevents
/// all event handlers from firing. Custom styling, such as greying the
/// component out or changing opacity, can be achieved with simple CSS styling.
///
/// Pipe this after creating a component.
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { model.transfer_amount },
///   render: fn(amount, _) {
///     html.button([], [html.text("Transfer $" <> int.to_string(amount))])
///   },
/// )
/// |> component.require_connection(fn(model) { model.connected })
/// ```
pub fn require_connection(
  component: Component(model, message, html),
  connected connected: fn(model) -> Bool,
) -> Component(model, message, html) {
  add_decoration(component, Connection(connected))
}

/// This is the most common component type. It subscribes to a slice of the
/// model and re-renders the entire component when that slice changes.
///
/// The `render` function receives the slice value and a [`Slotter`](#Slotter).
/// Call `slot(child_component)` wherever you want a nested component to appear,
/// or ignore the slot parameter with `_` if no children are needed.
///
/// Avoid using `simple` for components that contain `<input>`, `<textarea>`,
/// or `<select>` elements, every slice change replaces the component's
/// entire DOM via `innerHTML`, which destroys focus and any in-progress user
/// input. Use [`live`](#live) with targeted patches instead.
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { model.count },
///   render: fn(count, _) {
///     html.div([], [html.text("Count: " <> int.to_string(count))])
///   }
/// )
/// ```
///
/// Pipe through [`event.on()`](./event.html#on) and friends to attach DOM
/// event handlers to the rendered subtree, registered once at
/// [`mount`](#mount).
pub fn simple(
  slice slice: fn(model) -> a,
  render render: fn(a, Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(Simple(
    slice: fn(model) { to_dynamic(slice(model)) },
    render: fn(data, slot) { render(from_dynamic(data), slot) },
    compare_structural: False,
  ))
}

/// Static components render once and never update. Useful for headers, static
/// text, or any content that doesn't depend on the model.
///
/// The `content` function receives a [`Slotter`](#Slotter). Call
/// `slot(child_component)` wherever you want a nested component to appear,
/// or ignore the slot parameter with `_` if no children are needed.
///
/// ```gleam
/// component.static(fn(_) { html.h1([], [html.text("My App")]) })
/// ```
pub fn static(
  content content: fn(Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(Static(content))
}

/// Switch a component's comparison strategy from reference to structural
/// equality. By default, components use reference equality (`===`) to detect
/// slice changes. This works well for primitives and unchanged references.
///
/// Use `structural()` when your slice function returns new tuples, lists, or
/// other constructed values on every call.
///
/// `Static` and `Fragment` components don't compare slices, so this returns
/// them unchanged; decorations are left untouched.
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { #(model.x, model.y) },  // Returns new tuple each time
///   render: fn(pos, _) { ... }
/// )
/// |> component.structural  // Enable deep equality check
/// ```
pub fn structural(
  component: Component(model, message, html),
) -> Component(model, message, html) {
  let component_type = case component.component_type {
    Simple(..) as t -> Simple(..t, compare_structural: True)
    Live(..) as t -> Live(..t, compare_structural: True)
    Each(..) as t -> Each(..t, compare_structural: True)
    EachLive(..) as t -> EachLive(..t, compare_structural: True)
    Switch(..) as t -> Switch(..t, compare_structural: True)
    Static(..) as t | Fragment(..) as t -> t
  }
  Component(..component, component_type:)
}

/// Single-slot dynamic switching with identity preservation. `slice` picks a
/// discriminator from the model; `build` turns that discriminator into a
/// Component. When the slice value is unchanged across renders, the wrapper
/// and child DOM are not touched, so focus, selection, and in-progress
/// input survive. When the slice changes, the old child's handlers are
/// unregistered, the new Component is built and rendered, and the wrapper's
/// innerHTML is replaced.
///
/// Switch compares by reference equality by default, pipe through
/// [`structural`](#structural) when the slice constructs new values on
/// every call (tuples, records). Pair with
/// [`event.on()`](./event.html#on) on the Switch itself to bind events:
/// bindings declared inside `build`'s returned Component are not collected
/// at mount and never fire. Selectors are global, so one handler on
/// `.panel-close` covers every panel rendered by the switch.
///
/// ## Example
///
/// ```gleam
/// component.switch(
///   on: fn(model: Model) { model.route },
///   case_of: fn(route) {
///     case route {
///       Home -> home_page()
///       Profile -> profile_page()
///       Settings -> settings_page()
///     }
///   },
/// )
/// ```
pub fn switch(
  on slice: fn(model) -> a,
  case_of build: fn(a) -> Component(model, message, html),
) -> Component(model, message, html) {
  new_component(Switch(
    slice: fn(model) { to_dynamic(slice(model)) },
    build: fn(data) { build(from_dynamic(data)) },
    compare_structural: False,
  ))
}

/// Decorate a component with enter and exit CSS classes timed to a duration.
/// Pipe-friendly: the component comes first, so it chains like the other
/// decorators (`event.on*`, [`require_connection`](#require_connection)). On
/// mount, the wrapper carries `enter` for `duration_milliseconds`, then
/// the class is removed. On unmount (when an enclosing `each`, `each_live`,
/// or `switch` removes the wrapper), `exit` is applied and DOM removal is
/// deferred by the same duration, with `animationend` taking precedence if
/// the CSS fires it first.
///
/// The CSS contract is keyframes-based:
///
/// ```css
/// .dialog-enter { animation: dialog-enter 200ms; }
/// .dialog-exit  { animation: dialog-exit 200ms forwards; }
/// @keyframes dialog-enter { from { opacity: 0 } to { opacity: 1 } }
/// @keyframes dialog-exit  { from { opacity: 1 } to { opacity: 0 } }
/// ```
///
/// `forwards` on exit keeps the final state visible while the framework
/// holds the element in the DOM, preventing a flicker before removal.
///
/// **Placement rule**: transitions fire only when the framework's
/// removal path runs through them. That happens for `each`, `each_live`,
/// and `switch` child removal. Placing a transition inside a `simple`'s
/// render does not run exits on parent re-render, since `simple`'s
/// innerHTML wipe is synchronous. Hoist the transition to an `each_live`
/// item or a `switch` child if you need exits to fire.
///
/// ## Example
///
/// ```gleam
/// component.each_live(
///   slice: fn(model) { model.toasts },
///   key: fn(toast) { int.to_string(toast.id) },
///   initial: fn(toast) {
///     component.static(fn(_) { render_toast(toast) })
///     |> component.transition(
///       enter: "toast-enter",
///       exit: "toast-exit",
///       duration_milliseconds: 200,
///     )
///   },
///   patch: fn(_) { [] },
/// )
/// ```
pub fn transition(
  component: Component(model, message, html),
  enter enter: String,
  exit exit: String,
  duration_milliseconds duration_milliseconds: Int,
) -> Component(model, message, html) {
  add_decoration(component, Transition(enter:, exit:, duration_milliseconds:))
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

/// What a [`Component`](#Component) renders as. One variant per rendering
/// strategy; cross-cutting concerns live in [`Decoration`](#Decoration), not
/// here.
@internal
pub type ComponentType(model, message, html) {
  /// Keyed list with innerHTML rendering for each child. Carries the primitive
  /// slice, key, and render functions directly so the FFI can evaluate only
  /// what it needs per item.
  Each(
    slice: fn(model) -> List(Dynamic),
    key: fn(Dynamic) -> String,
    render: fn(Dynamic) -> Component(model, message, html),
    compare_structural: Bool,
  )

  /// Keyed list with patch-based rendering for each child. Carries the
  /// primitive slice, key, initial, and patch functions so the FFI calls
  /// `initial` only for items whose key first appears, not for the whole
  /// list.
  EachLive(
    slice: fn(model) -> List(Dynamic),
    key: fn(Dynamic) -> String,
    initial: fn(Dynamic) -> Component(model, message, html),
    patch: fn(Dynamic) -> List(Patch),
    compare_structural: Bool,
  )

  /// Container for multiple components (no wrapper element created)
  Fragment(children: List(Component(model, message, html)))

  /// Live component with patch-based updates for 60fps performance
  Live(
    slice: fn(model) -> Dynamic,
    initial: fn(Slotter(model, message, html)) -> html,
    apply: fn(Dynamic) -> List(Patch),
    compare_structural: Bool,
  )

  /// Simple dynamic component that re-renders via innerHTML when slice changes
  Simple(
    slice: fn(model) -> Dynamic,
    render: fn(Dynamic, Slotter(model, message, html)) -> html,
    compare_structural: Bool,
  )

  /// Static content that renders once with no subscription to model changes
  Static(content: fn(Slotter(model, message, html)) -> html)

  /// Single-slot dynamic switching. The slice picks a discriminator and
  /// `build` produces the Component to render. Identity is preserved when
  /// the slice is unchanged; on change, the old subtree is torn down and
  /// the new one rendered. Event bindings inside `build`'s result are not
  /// collected by [`mount`](#mount), attach switch-related events to the
  /// `Switch` itself or any ancestor.
  Switch(
    slice: fn(model) -> Dynamic,
    build: fn(Dynamic) -> Component(model, message, html),
    compare_structural: Bool,
  )
}

/// A cross-cutting attribute layered onto a [`Component`](#Component) via the
/// decoration list. Each is built by a constructor that appends it:
/// [`transition`](#transition) adds a `Transition`, `event.on*` (through
/// `attach_event`) adds a `Listener`, and [`require_connection`](#require_connection)
/// adds a `Connection`. Applied innermost-first in list order.
@internal
pub type Decoration(model) {
  /// CSS enter/exit classes timed to a duration, applied to a wrapper element
  /// around the component (see [`transition`](#transition)).
  Transition(enter: String, exit: String, duration_milliseconds: Int)

  /// A single event binding: an opaque `fn(Dynamic) -> Nil` closure that
  /// receives the runtime (as `Dynamic` so the field compiles on Erlang) and
  /// registers its DOM listener when invoked at mount. On Erlang the closure
  /// is never invoked (mount is JavaScript-only).
  Listener(handler: fn(Dynamic) -> Nil)

  /// Gates the subtree on connection status: when `connected` returns `False`,
  /// the wrapper element is marked disabled (`data-lily-disabled`,
  /// `aria-disabled`, `lily-disconnected`).
  Connection(connected: fn(model) -> Bool)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@target(javascript)
/// Attach an event binding to a component by appending a `Listener`
/// decoration. Intended to be called from `lily/event`, not by users.
///
/// The binding is wrapped in an opaque `fn(Dynamic) -> Nil` closure
/// before being stored, since `Listener` holds opaque bindings to keep
/// the [`Component`](#Component) type cross-target. The closure casts the
/// supplied `Dynamic` back to a typed `Runtime` on invocation.
@internal
pub fn attach_event(
  component component: Component(model, message, html),
  binding binding: EventBinding(model, message),
) -> Component(model, message, html) {
  let opaque_binding = fn(runtime_dynamic: Dynamic) {
    binding(from_dynamic(runtime_dynamic))
  }
  // Append so listeners register in the order they were attached: the
  // first-attached handler fires first at dispatch. That ordering is what
  // lets a more specific handler with `stop_propagation` (attached before a
  // broader ancestor-selector handler) block the broader one, since all
  // delegated listeners share one node and run in registration order.
  add_decoration(component, Listener(opaque_binding))
}

@target(javascript)
/// Walk the component tree, invoking every event binding declared via
/// `event.on*` (each a `Listener` decoration) and recursing into Fragment
/// children. Stops at Each/EachLive: their per-item render bodies are not
/// inspected, so events declared inside item components are ignored by
/// design (see the `each` / `each_live` docstrings).
///
/// Called from [`mount`](#mount) before the FFI render pass. Exposed as
/// `@internal` so tests can register bindings without mounting (and thus
/// without wiping the DOM container).
@internal
pub fn register_bindings(
  runtime: Runtime(model, message),
  component: Component(model, message, html),
) -> Nil {
  let runtime_dynamic = to_dynamic(runtime)
  list.each(component.decorations, fn(decoration) {
    case decoration {
      Listener(handler:) -> handler(runtime_dynamic)
      Transition(..) | Connection(..) -> Nil
    }
  })
  case component.component_type {
    Fragment(children:) ->
      list.each(children, fn(child) { register_bindings(runtime, child) })
    Each(..) | EachLive(..) | Live(..) | Simple(..) | Static(..) | Switch(..) ->
      Nil
  }
}

/// Read a component's recorded scope selector (see [`scoped`](#scoped)).
/// Returns `None` when no scope was set. Consumed by `lily/event`'s binders
/// to confine a listener to the component's own subtree.
@internal
pub fn scope(component: Component(model, message, html)) -> Option(String) {
  component.scope
}

/// Record a component's own CSS selector (usually `#<id>`) as its scope, so
/// the `event.on*` binders match only within its subtree. Intended to be
/// called from component-library builders that already render `id=<id>` on
/// their root, not by application code directly.
@internal
pub fn scoped(
  component component: Component(model, message, html),
  selector selector: String,
) -> Component(model, message, html) {
  Component(..component, scope: option.Some(selector))
}

/// Pure walker used by [`render_to_string`](#render_to_string). Recurses
/// into every variant; slots are filled inline by walking the child and
/// wrapping the resulting string via `from_string` before handing it back
/// to the user's render function. Decorations (event listeners, connection
/// gating, and CSS transitions) only matter on a live DOM, so the walk
/// delegates straight to the component type.
@internal
pub fn walk_to_string(
  component: Component(model, message, html),
  model: model,
  to_html: fn(html) -> String,
  from_string: fn(String) -> html,
) -> String {
  // Decorations (transitions, listeners, connection gating) only matter on
  // a live DOM, so the string-render walk delegates straight to the
  // component type.
  case component.component_type {
    Static(content:) -> {
      let slotter = make_slotter(model, to_html, from_string)
      to_html(content(slotter))
    }

    Simple(slice:, render:, compare_structural: _) -> {
      let slotter = make_slotter(model, to_html, from_string)
      to_html(render(slice(model), slotter))
    }

    Live(slice: _, initial:, apply: _, compare_structural: _) -> {
      let slotter = make_slotter(model, to_html, from_string)
      to_html(initial(slotter))
    }

    Each(slice:, key: _, render:, compare_structural: _) -> {
      slice(model)
      |> list.map(fn(item) {
        walk_to_string(render(item), model, to_html, from_string)
      })
      |> string.concat
    }

    EachLive(slice:, key: _, initial:, patch: _, compare_structural: _) -> {
      slice(model)
      |> list.map(fn(item) {
        walk_to_string(initial(item), model, to_html, from_string)
      })
      |> string.concat
    }

    Fragment(children:) ->
      children
      |> list.map(walk_to_string(_, model, to_html, from_string))
      |> string.concat

    Switch(slice:, build:, compare_structural: _) ->
      walk_to_string(build(slice(model)), model, to_html, from_string)
  }
}

fn add_decoration(
  component: Component(model, message, html),
  decoration: Decoration(model),
) -> Component(model, message, html) {
  Component(
    ..component,
    decorations: list.append(component.decorations, [decoration]),
  )
}

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
  Component(component_type:, decorations: [], scope: option.None)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(javascript)
/// A self-contained event binding. Built by the `event.on*` functions, which
/// capture the event constant, selector, options, and handler inside the
/// closure. Invoked with the runtime during `mount` to register the
/// underlying DOM listener.
type EventBinding(model, message) =
  fn(Runtime(model, message)) -> Nil

// =============================================================================
// PRIVATE FFI
// =============================================================================

/// Casts a Dynamic value back to the slice type. On both targets this is
/// an identity function, the value is already the correct type at runtime
/// (JavaScript has no runtime type tags; Erlang carries the original
/// runtime value). Used to pass the already-extracted slice result to
/// render/patch functions without calling the user's slice function a
/// second time.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./component.ffi.mjs", "identity")
fn from_dynamic(value: Dynamic) -> a

@target(javascript)
/// Get the model from the runtime
@external(javascript, "./component.ffi.mjs", "getModel")
fn get_model(_runtime: Runtime(model, message)) -> model {
  // This will never run
  panic as "getModel is only available in JavaScript"
}

/// Type-erases a `List(item)` to `List(Dynamic)` without allocating. On
/// both targets this is an identity function, the same list reference is
/// returned. Used by [`each`](#each) and [`each_live`](#each_live) so the
/// FFI handler can short-circuit when the user's slice returns the same
/// list reference as last time.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./component.ffi.mjs", "identity")
fn list_dynamic(value: List(a)) -> List(Dynamic)

@target(javascript)
/// Renders a component tree to HTML and creates subscriptions for dynamic
/// components. Called once at mount time; subsequent updates flow through
/// the registered per-component handlers.
@external(javascript, "./component.ffi.mjs", "renderTree")
fn render_tree(
  _runtime: Runtime(model, message),
  _root_selector: String,
  _component: Component(model, message, html),
  _model: model,
  _to_html: fn(html) -> String,
  _to_slot: fn() -> html,
) -> Nil {
  Nil
}

/// Wraps any value as Dynamic for use as a comparison key. On both targets
/// this is an identity function: JavaScript doesn't distinguish types at
/// runtime, and Erlang carries the original runtime value through. Necessary
/// because the slice type is not known at library compilation time.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./component.ffi.mjs", "identity")
fn to_dynamic(value: a) -> Dynamic
