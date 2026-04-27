//// Components subscribe to the [`Store`](./store.html#Store) and re-render
//// when their slice of the model changes. They're functions that return
//// renderable content, composable like React or Lustre components. That said,
//// it's closer to React than Lustre, with smaller, more modular components
//// being preferable as components themselves don't hold states.
////
//// Lily provides five component types with different performance
//// characteristics
////
//// 1. [`static`](#static) renders once and never updates
//// 2. [`simple`](#simple) uses innerHTML re-renders when the slice changes
//// 3. [`live`](#live) uses patch-based updates to prevent full re-renders
//// 4. [`each`](#each) handles keyed lists with innerHTML rendering
//// 5. [`each_live`](#each_live) handles keyed lists with patch-based rendering
//// 6. [`fragment`](#fragment) is essentially a collection of other components
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
//// To use nesting, also supply `to_slot` at mount — a zero-argument function
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
//// fn app(_model: Model) {
////   component.simple(
////     slice: fn(m: Model) { m.count },
////     render: fn(count, _) {
////       html.div([], [
////         html.button([attribute.data("msg", "decrement")], [html.text("-")]),
////         html.p([], [html.text(int.to_string(count))]),
////         html.button([attribute.data("msg", "increment")], [html.text("+")]),
////       ])
////     },
////   )
//// }
////
//// pub fn main() {
////   let runtime =
////     store.new(Model(count: 0), with: update)
////     |> client.start
////
////   runtime
////   |> component.mount(
////     selector: "#app",
////     to_html: element.to_string,
////     to_slot: fn() { element.element("lily-slot", [], []) },
////     view: app,
////   )
////   |> event.on_click(selector: "#app", decoder: parse_click)
//// }
//// ```
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
/// Comparison strategy for detecting slice changes. By default, the comparison
/// strategy uses reference equality which is more efficient. However,
/// reference equality can cause unnecessary re-renders for some data types if
/// the value remains the same but the reference changes, which means that
/// structural equality may be preferred. For a rule of thumb, use the default
/// behaviour unless the slice listened to is a `List`, `Tuple`, or a record.
/// See [`component.structural`](#structural) for specifying structural
/// reference.
pub type CompareStrategy {
  /// Reference equality (JavaScript `===`, O(1)), default
  ReferenceEqual
  /// Structural equality (Gleam `==`, O(n)), use for tuples/lists
  StructuralEqual
}

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
/// constructors for Component is kept opaque – use the associated functions to
/// create components instead. The `html` type parameter is user-provided and
/// can be any type that represents HTML markup.
pub opaque type Component(model, message, html) {
  /// Keyed list with innerHTML rendering for each child. Carries the primitive
  /// slice, key, and render functions directly so the FFI can evaluate only
  /// what it needs per item.
  Each(
    slice: fn(model) -> List(Dynamic),
    key: fn(Dynamic) -> String,
    render: fn(Dynamic) -> Component(model, message, html),
    compare: CompareStrategy,
  )

  /// Keyed list with patch-based rendering for each child. Carries the primitive
  /// slice, key, initial, and patch functions so the FFI calls `initial` only
  /// for items whose key first appears, not for the whole list.
  EachLive(
    slice: fn(model) -> List(Dynamic),
    key: fn(Dynamic) -> String,
    initial: fn(Dynamic) -> Component(model, message, html),
    patch: fn(Dynamic) -> List(Patch),
    compare: CompareStrategy,
  )

  /// Container for multiple components (no wrapper element created)
  Fragment(children: List(Component(model, message, html)))

  /// Live component with patch-based updates for 60fps performance
  Live(
    slice: fn(model) -> Dynamic,
    initial: fn(Slotter(model, message, html)) -> html,
    apply: fn(Dynamic) -> List(Patch),
    compare: CompareStrategy,
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
    compare: CompareStrategy,
  )

  /// Static content that renders once with no subscription to model changes
  Static(content: fn(Slotter(model, message, html)) -> html)
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
/// or `<select>` elements — each changed item replaces its DOM via
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
    slice: fn(model) { list.map(slice(model), to_dynamic) },
    key: fn(item) { string.inspect(key(from_dynamic(item))) },
    render: fn(item) { render(from_dynamic(item)) },
    compare: ReferenceEqual,
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
    slice: fn(model) { list.map(slice(model), to_dynamic) },
    key: fn(item) { string.inspect(key(from_dynamic(item))) },
    initial: fn(item) { initial(from_dynamic(item)) },
    patch: fn(item) { patch(from_dynamic(item)) },
    compare: ReferenceEqual,
  )
}

@target(javascript)
/// Fragments allow you to return multiple components from a single function.
/// The children are rendered in order and concatenated into the parent's HTML.
/// This is similar to Lustre's [`element.fragment`][https://hexdocs.pm/lustre/lustre/element.html#fragment].
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
/// The first parameter of `initial` is a [`Slotter`](#Slotter) — call
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
    compare: ReferenceEqual,
  )
}

@target(javascript)
/// This is the entry point for rendering, mounting a component tree to a
/// specific DOM element. It creates a subscription to the store and renders
/// the entire component tree whenever the model changes.
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
  // Initial render - this sets up all component subscriptions
  let model = get_model(runtime)
  let tree = view(model)
  render_tree(runtime, selector, tree, model, to_html, to_slot, runtime, 0)

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
/// or `<select>` elements — every slice change replaces the component's
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
pub fn simple(
  slice slice: fn(model) -> a,
  render render: fn(a, Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  Simple(
    slice: fn(model) { to_dynamic(slice(model)) },
    render: fn(data, slot) { render(from_dynamic(data), slot) },
    compare: ReferenceEqual,
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
/// Switch a component's comparison strategy from reference to structural
/// equality. By default, components use reference equality (`===`) to detect
/// slice changes. This works well for primitives and unchanged references.
///
/// Use `structural()` when your slice function returns new tuples, lists, or
/// other constructed values on every call.
///
/// Also see [`component.CompareStrategy`](#CompareStrategy).
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
    Static(content) -> Static(content)
    Simple(slice, render, _) ->
      Simple(slice: slice, render: render, compare: StructuralEqual)
    Live(slice, initial, apply, _) ->
      Live(
        slice: slice,
        initial: initial,
        apply: apply,
        compare: StructuralEqual,
      )
    Each(slice, key, render, _) ->
      Each(slice: slice, key: key, render: render, compare: StructuralEqual)
    EachLive(slice, key, initial, patch, _) ->
      EachLive(
        slice: slice,
        key: key,
        initial: initial,
        patch: patch,
        compare: StructuralEqual,
      )
    Fragment(children) -> Fragment(children)
    RequireConnection(inner, connected) ->
      RequireConnection(inner: structural(inner), connected: connected)
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
/// Casts a Dynamic value back to the slice type. On JavaScript this is an
/// identity function — the value is already the correct type at runtime.
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
/// Renders a component tree to HTML and creates subscriptions for dynamic
/// components. This is called on initial render and on every model update.
@external(javascript, "./component.ffi.mjs", "renderTree")
fn render_tree(
  _runtime: Runtime(model, message),
  _root_selector: String,
  _component: Component(model, message, html),
  _model: model,
  _to_html: fn(html) -> String,
  _to_slot: fn() -> html,
  _store: Runtime(model, message),
  _depth: Int,
) -> Nil {
  Nil
}

@target(javascript)
/// Wraps any value as Dynamic for use as a comparison key. On JavaScript this
/// is an identity function as the runtime doesn't distinguish types. This
/// replaces the old `dynamic.from` in gleam_stdlib. As much as I hate doing
/// this, this is necessary as the slice type is not known at library
/// compilation time.
@external(javascript, "./component.ffi.mjs", "identity")
fn to_dynamic(value: a) -> Dynamic {
  // This will never run
  let _ = value
  panic as "This should never be called - JavaScript only"
}
