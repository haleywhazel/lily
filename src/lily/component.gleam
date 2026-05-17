//// Components subscribe to the [`Store`](./store.html#Store) and re-render
//// when their slice of the model changes. They're functions that return
//// renderable content, composable like React or Lustre components. That said,
//// it's closer to React than Lustre, with smaller, more modular components
//// being preferable as components themselves don't hold states.
////
//// Lily provides eight component types, each with different performance
//// characteristics:
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
//// 8. [`transition`](#transition) wraps a child with CSS classes timed to
////    a duration, with deferred DOM removal so exit animations finish
////    before the element is gone
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
////   slice: fn(m) { m.is_active },
////   initial: fn(slot) {
////     html.section([attribute.class("column")], [
////       html.h2([], [html.text("Title")]),
////       slot(component.each_live(
////         slice: fn(m) { cards_for(m) },
////         key: fn(c) { c.id },
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
////   slice: fn(m) { m.count },
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
////   to_html: fn(s) { s },
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
////   html.button([attribute.data("msg", "decrement")], [html.text("-")])
//// }
////
//// fn increment_button() {
////   html.button([attribute.data("msg", "increment")], [html.text("+")])
//// }
////
//// fn app(_model: Model) {
////   component.simple(
////     slice: fn(m: Model) { m.count },
////     render: fn(count, _) {
////       html.div([], [
////         decrement_button(),
////         html.p([], [html.text(int.to_string(count))]),
////         increment_button(),
////       ])
////     },
////   )
////   |> event.on_decoded(
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
//// All components are JavaScript-only (`@target(javascript)`).
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/dynamic.{type Dynamic}
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import lily/client.{type Runtime}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

@target(javascript)
/// A function that accepts a child `Component` and returns a placeholder
/// value of your `html` type marking where that child will be rendered.
/// Passed as the first parameter of every `static`, `simple`, and `live`
/// content function. Call it inline wherever you want the child to appear;
/// call order determines DOM position.
pub type Slotter(model, message, html) =
  fn(Component(model, message, html)) -> html

@target(javascript)
/// Component is the core type representing renderable content in Lily. The
/// constructors for Component is kept opaque, use the associated functions to
/// create components instead. The `html` type parameter is user-provided and
/// can be any type that represents HTML markup.
///
/// Each dynamic variant carries a `compare_structural` flag. `False` (the
/// default) means slice changes are detected by reference equality (`===`,
/// O(1)); `True` means structural equality (`==`, O(n)) and is set by
/// piping a component through [`structural`](#structural). Use structural
/// when the slice constructs new tuples, lists, or records on every call.
pub opaque type Component(model, message, html) {
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

  /// Wraps a component to disable it when the connection status is `False`.
  /// The `connected` function extracts connection status from the model.
  /// When disconnected, event handlers are disabled and accessibility
  /// attributes are added.
  RequireConnection(
    inner: Component(model, message, html),
    connected: fn(model) -> Bool,
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

  /// Wraps a child with enter/exit CSS classes timed to a duration. The
  /// enter class is applied on mount and removed after the duration; the
  /// exit class is applied when the surrounding `each` / `each_live` /
  /// `switch` removal path runs, and DOM removal is deferred by the same
  /// duration (with `animationend` taking precedence if the user's CSS
  /// fires it first).
  Transition(
    enter: String,
    exit: String,
    duration_milliseconds: Int,
    child: Component(model, message, html),
  )

  /// Wraps a component with a list of event bindings. Bindings are
  /// `fn(Runtime) -> Nil` closures that register their own DOM event when
  /// invoked. The walk in [`mount`](#mount) triggers them once per mount.
  WithEvents(
    inner: Component(model, message, html),
    bindings: List(EventBinding(model, message)),
  )
}

@target(javascript)
/// Patches are DOM updates to apply to a component, avoiding a full re-render
/// used for [`component.live`](#live) and
/// [`component.each_live`](#each_live). The `target` field is a CSS selector
/// relative to the component's root element, with an empty string provided
/// if the component's root element is itself. Patches are scoped to their
/// component, preventing cross-component interference.
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

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
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
  Each(
    slice: fn(model) { list_dynamic(slice(model)) },
    key: fn(item) { string.inspect(key(from_dynamic(item))) },
    render: fn(item) { render(from_dynamic(item)) },
    compare_structural: False,
  )
}

@target(javascript)
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
  EachLive(
    slice: fn(model) { list_dynamic(slice(model)) },
    key: fn(item) { string.inspect(key(from_dynamic(item))) },
    initial: fn(item) { initial(from_dynamic(item)) },
    patch: fn(item) { patch(from_dynamic(item)) },
    compare_structural: False,
  )
}

@target(javascript)
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
  Fragment(children)
}

@target(javascript)
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
  Live(
    slice: fn(model) { to_dynamic(slice(model)) },
    initial: initial,
    apply: fn(data) { patch(from_dynamic(data)) },
    compare_structural: False,
  )
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
  // side queues every WithEvents wrapper's bindings (including those
  // inside slot children, which the Gleam-side tree walk can't reach
  // because slot children are constructed via the slotter callback at
  // render time). render_tree drains the queue after innerHTML, so
  // element-scoped listeners find their target in the DOM.
  render_tree(runtime, selector, tree, model, to_html, to_slot)

  runtime
}

@target(javascript)
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
  RequireConnection(inner: component, connected: connected)
}

@target(javascript)
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
  Simple(
    slice: fn(model) { to_dynamic(slice(model)) },
    render: fn(data, slot) { render(from_dynamic(data), slot) },
    compare_structural: False,
  )
}

@target(javascript)
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
  Static(content)
}

@target(javascript)
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
///   on: fn(m: Model) { m.route },
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
  Switch(
    slice: fn(model) { to_dynamic(slice(model)) },
    build: fn(data) { build(from_dynamic(data)) },
    compare_structural: False,
  )
}

@target(javascript)
/// Switch a component's comparison strategy from reference to structural
/// equality. By default, components use reference equality (`===`) to detect
/// slice changes. This works well for primitives and unchanged references.
///
/// Use `structural()` when your slice function returns new tuples, lists, or
/// other constructed values on every call.
///
/// `Static` and `Fragment` components don't compare slices, so this returns
/// them unchanged. `RequireConnection`, `Transition`, and `WithEvents`
/// recurse into the wrapped inner component.
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
  case component {
    Simple(..) -> Simple(..component, compare_structural: True)
    Live(..) -> Live(..component, compare_structural: True)
    Each(..) -> Each(..component, compare_structural: True)
    EachLive(..) -> EachLive(..component, compare_structural: True)
    Switch(..) -> Switch(..component, compare_structural: True)
    RequireConnection(inner:, connected:) ->
      RequireConnection(inner: structural(inner), connected:)
    Transition(enter:, exit:, duration_milliseconds:, child:) ->
      Transition(
        enter:,
        exit:,
        duration_milliseconds:,
        child: structural(child),
      )
    WithEvents(inner:, bindings:) ->
      WithEvents(inner: structural(inner), bindings:)
    Static(..) | Fragment(..) -> component
  }
}

@target(javascript)
/// Wrap a child with enter and exit CSS classes timed to a duration. On
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
/// and `switch` child removal. Placing a Transition inside a `simple`'s
/// render does not run exits on parent re-render, since `simple`'s
/// innerHTML wipe is synchronous. Hoist the Transition to an `each_live`
/// item or a `switch` child if you need exits to fire.
///
/// ## Example
///
/// ```gleam
/// component.each_live(
///   slice: fn(m) { m.toasts },
///   key: fn(t) { int.to_string(t.id) },
///   initial: fn(toast) {
///     component.transition(
///       enter: "toast-enter",
///       exit: "toast-exit",
///       duration_milliseconds: 200,
///       child: component.static(fn(_) { render_toast(toast) }),
///     )
///   },
///   patch: fn(_) { [] },
/// )
/// ```
pub fn transition(
  enter enter: String,
  exit exit: String,
  duration_milliseconds duration_milliseconds: Int,
  child child: Component(model, message, html),
) -> Component(model, message, html) {
  Transition(enter:, exit:, duration_milliseconds:, child:)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@target(javascript)
@internal
/// Attach an event binding to a component. Wraps the component in a
/// `WithEvents` variant; if the component is already wrapped, appends to its
/// binding list instead. Intended to be called from `lily/event`, not by
/// users.
pub fn attach_event(
  component component: Component(model, message, html),
  binding binding: EventBinding(model, message),
) -> Component(model, message, html) {
  case component {
    WithEvents(inner:, bindings:) ->
      WithEvents(inner:, bindings: [binding, ..bindings])
    Each(..)
    | EachLive(..)
    | Fragment(..)
    | Live(..)
    | RequireConnection(..)
    | Simple(..)
    | Static(..)
    | Switch(..)
    | Transition(..) -> WithEvents(inner: component, bindings: [binding])
  }
}

@target(javascript)
@internal
/// Walk the component tree, invoking every event binding declared via
/// `event.on*`. Recurses through wrappers (WithEvents, RequireConnection)
/// and into Fragment children. Stops at Each/EachLive: their per-item
/// render bodies are not inspected, so events declared inside item
/// components are ignored by design (see the `each` / `each_live`
/// docstrings).
///
/// Called from [`mount`](#mount) before the FFI render pass. Exposed as
/// `@internal` so tests can register bindings without mounting (and thus
/// without wiping the DOM container).
pub fn register_bindings(
  runtime: Runtime(model, message),
  component: Component(model, message, html),
) -> Nil {
  case component {
    WithEvents(inner:, bindings:) -> {
      list.each(bindings, fn(binding) { binding(runtime) })
      register_bindings(runtime, inner)
    }
    Fragment(children:) ->
      list.each(children, fn(child) { register_bindings(runtime, child) })
    RequireConnection(inner:, connected: _) ->
      register_bindings(runtime, inner)
    Transition(child:, ..) -> register_bindings(runtime, child)
    Each(..) | EachLive(..) | Live(..) | Simple(..) | Static(..) | Switch(..) ->
      Nil
  }
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

@target(javascript)
/// Casts a Dynamic value back to the slice type. On JavaScript this is an
/// identity function, the value is already the correct type at runtime.
/// Used to pass the already-extracted slice result to render/patch functions
/// without calling the user's slice function a second time.
@external(javascript, "./component.ffi.mjs", "identity")
fn from_dynamic(value: Dynamic) -> a {
  // This will never run
  let _ = value
  panic as "This should never be called - JavaScript only"
}

@target(javascript)
/// Get the model from the runtime
@external(javascript, "./component.ffi.mjs", "getModel")
fn get_model(_runtime: Runtime(model, message)) -> model {
  // This will never run
  panic as "getModel is only available in JavaScript"
}

@target(javascript)
/// Type-erases a `List(item)` to `List(Dynamic)` without allocating. On
/// JavaScript this is an identity function, the same list reference is
/// returned. Used by [`each`](#each) and [`each_live`](#each_live) so the
/// FFI handler can short-circuit when the user's slice returns the same
/// list reference as last time.
@external(javascript, "./component.ffi.mjs", "identity")
fn list_dynamic(value: List(a)) -> List(Dynamic) {
  let _ = value
  panic as "This should never be called - JavaScript only"
}

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

@target(javascript)
/// Wraps any value as Dynamic for use as a comparison key. On JavaScript this
/// is an identity function, the runtime doesn't distinguish types. Necessary
/// because the slice type is not known at library compilation time.
@external(javascript, "./component.ffi.mjs", "identity")
fn to_dynamic(value: a) -> Dynamic {
  // This will never run
  let _ = value
  panic as "This should never be called - JavaScript only"
}
