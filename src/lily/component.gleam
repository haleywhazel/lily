//// Components subscribe to the [`Store`](./store.html#Store) and re-render
//// when their slice of the model changes. They're functions that return
//// renderable content, composable like React or Lustre components.
////
//// Lily provides five component types with different performance
//// characteristics: [`static`](#static) renders once and never updates,
//// [`simple`](#simple) uses innerHTML re-renders when the slice changes
//// (most common), [`live`](#live) uses patch-based updates for 60fps
//// performance, [`each`](#each) handles keyed lists with innerHTML
//// rendering, and [`each_live`](#each_live) handles keyed lists with
//// patch-based rendering.
////
//// Components work with any HTML library - Lustre, Nakai, or raw strings.
//// The `to_html` function provided at [`component.mount`](#mount) converts
//// your chosen library's types to strings. We recommend
//// [Lustre elements](https://hexdocs.pm/lustre/lustre/element/html.html)
////
//// ```gleam
//// import lily/component
//// import lustre/element.{type Element}
//// import lustre/element/html
////
//// // View function
//// fn counter_view(count: Int) -> Element(Msg) {
////   html.div([], [
////     html.p([], [element.text("Count: " <> int.to_string(count))]),
////     html.button([event.on_click(Increment)], [element.text("+")]),
////   ])
//// }
////
//// pub fn main() {
////   store.new(Model(count: 0), with: update)
////   |> component.mount("#app", to_html: element.to_string, view: counter_view)
////   |> component.simple(
////     selector: "#counter",
////     slice: fn(m) { m.count },
////     render: fn(count) { html.p([], [element.text(int.to_string(count))]) },
////   )
////   |> client.start
//// }
//// ```
////
//// Each component declares a `slice` function that extracts relevant data
//// from the model. The runtime caches the previous slice and skips rendering
//// when unchanged (using reference equality by default, structural equality
//// opt-in via [`component.structural`](#structural)).
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

/// Comparison strategy for detecting slice changes. By default, the comparison
/// strategy uses reference equality which is more efficient. However,
/// reference equality can cause unnecessary re-renders for some data types if
/// the value remains the same but the reference changes, which means that
/// structural equality may be preferred. For a rule of thumb, use the default
/// behaviour unless the slice listened to is a `List`, `Tuple`, or a record.
/// See [`component.structural`](#structural) for specifying structural
/// reference.
@target(javascript)
pub type CompareStrategy {
  /// Reference equality (JavaScript `===`, O(1)), default
  ReferenceEqual
  /// Structural equality (Gleam `==`, O(n)), use for tuples/lists
  StructuralEqual
}

/// Component is the core type representing renderable content in Lily. The
/// constructors for Component is kept opaque – use the associated functions to
/// create components instead. The `html` type parameter is user-provided and
/// can be any type that represents HTML markup.
@target(javascript)
pub opaque type Component(model, msg, html) {
  /// Static content that renders once with no subscription to model changes
  Static(content: html)

  /// Simple dynamic component that re-renders via innerHTML when slice changes
  Simple(
    slice: fn(model) -> Dynamic,
    view: fn(model) -> html,
    compare: CompareStrategy,
  )

  /// Live component with patch-based updates for 60fps performance
  Live(
    slice: fn(model) -> Dynamic,
    initial: html,
    apply: fn(model) -> List(Patch),
    compare: CompareStrategy,
  )

  /// Keyed list with innerHTML rendering for each child
  ///
  /// The produce function combines slicing, key, and rendering into a single
  /// function to use within the JavaScript module when calling `component.each`
  /// constructor. The function returns a list of the key and the render
  /// result.
  ///
  /// ## Example
  ///
  /// ```gleam
  /// produce: fn(model) {
  ///   list.map(slice(model), fn(item) {
  ///     #(string.inspect(key(item)), render(item))
  ///   })
  /// }
  /// ```
  Each(
    produce: fn(model) -> List(#(String, html)),
    compare: CompareStrategy,
  )

  /// Keyed list with patch-based rendering for each child
  ///
  /// Just like the produce function within Each, the apply function combines
  /// both the slicing and the patching into a single function that generates
  /// a list of keys and patch strategies.
  ///
  /// ## Example
  ///
  /// ```gleam
  /// fn(model) {
  ///   list.map(slice(model), fn(item) {
  ///     #(string.inspect(key(item)), patch(item))
  ///   })
  /// }
  /// ```
  EachLive(
    keys: fn(model) -> List(String),
    initial: fn(model) -> List(#(String, html)),
    apply: fn(model) -> List(#(String, List(Patch))),
    compare: CompareStrategy,
  )

  /// Container for multiple components (no wrapper element created)
  Fragment(children: List(Component(model, msg, html)))

  /// Wraps a component to disable it when the connection status is `False`.
  /// The `connected` function extracts connection status from the model.
  /// When disconnected, event handlers are disabled and accessibility
  /// attributes are added.
  RequireConnection(
    inner: Component(model, msg, html),
    connected: fn(model) -> Bool,
  )
}

/// Patches are DOM updates to apply to a component, avoiding a full
/// re-render used for [`component.live`](#live) and
/// [`component.each_live`](#each_live).The `target` field is a CSS selector
/// relative to the component's root element, with an empty string provided
/// if the component's root element is itself. Patches are scoped to their
/// component, preventing cross-component interference.
@target(javascript)
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

/// Manages a dynamic list of items with add/remove/reorder reconciliation.
/// Each item is identified by a unique key. When the list changes, only
/// the changed items are updated. [`component.each`](#each) differs from
/// [`component.each_live`](#each_live) in that it does a full re-render of
/// the HTML element instead of patches.
///
/// `slice` must return a `List` rather than a single element, unlike
/// [`component.simple`](#simple).
///
/// While the type for key can be defined by the user, internally, these are
/// converted to `String`.
///
/// The `render` function is called for each item and should return HTML (in
/// whatever type is defined on [`component.mount`](#mount)).
///
/// ## Example
///
/// ```gleam
/// component.each(
///   slice: fn(model) { model.counters },
///   key: fn(counter) { counter.id },
///   render: fn(counter) {
///     html.div([class("counter")], [
///       html.text(int.to_string(counter.value))
///     ])
///   }
/// )
/// ```
@target(javascript)
pub fn each(
  slice slice: fn(model) -> List(item),
  key key: fn(item) -> key,
  render render: fn(item) -> html,
) -> Component(model, msg, html) {
  Each(
    produce: fn(model) {
      list.map(slice(model), fn(item) {
        #(string.inspect(key(item)), render(item))
      })
    },
    compare: ReferenceEqual,
  )
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
/// The `initial` function renders the initial HTML for each item.
/// The `patch` function returns patches to apply on updates.
///
/// ## Example
///
/// ```gleam
/// component.each_live(
///   items: fn(model) { model.series },
///   key: fn(series) { series.data.id },
///   initial: fn(data) {
///     html.div([class("display-data")], [
///       html.span([class("value")], [html.text("0")])
///     ])
///   },
///   patch: fn(series) {
///     [SetText(".value", int.to_string(series.data.value))]
///   }
/// )
/// ```
@target(javascript)
pub fn each_live(
  slice slice: fn(model) -> List(item),
  key key: fn(item) -> key,
  initial initial: fn(item) -> html,
  patch patch: fn(item) -> List(Patch),
) -> Component(model, msg, html) {
  EachLive(
    keys: fn(model) {
      list.map(slice(model), fn(item) { string.inspect(key(item)) })
    },
    initial: fn(model) {
      list.map(slice(model), fn(item) {
        #(string.inspect(key(item)), initial(item))
      })
    },
    apply: fn(model) {
      list.map(slice(model), fn(item) {
        #(string.inspect(key(item)), patch(item))
      })
    },
    compare: ReferenceEqual,
  )
}

/// Fragments allow you to return multiple components from a single function.
/// The children are rendered in order and concatenated into the parent's HTML.
/// This is similar to Lustre's [`element.fragment`][https://hexdocs.pm/lustre/lustre/element.html#fragment].
///
/// ## Example
///
/// ```gleam
/// fn app() -> Component(Model, Msg, Element(Msg)) {
///   component.fragment([
///     component.static(html.h1([], [html.text("My App")])),
///     component.simple(...),
///     component.each(...),
///   ])
/// }
/// ```
@target(javascript)
pub fn fragment(
  children: List(Component(model, msg, html)),
) -> Component(model, msg, html) {
  Fragment(children)
}

/// Live components render an initial HTML structure once, then apply DOM
/// patches on subsequent updates. This is much faster than innerHTML,
/// replacement for frequent updates (e.g., drag-and-drop, animations,
/// real-time data) for 60fps rendering.
///
/// The `patch` function returns a list of `Patch` values. Each patch targets
/// an element relative to the component's root using a CSS selector.
///
/// ## Example
///
/// ```gleam
/// component.live(
///   slice: fn(model) { model.data },
///   initial: html.div([], [
///     html.span([class("value")], [html.text("0")]),
///     html.div([class("bar")], [])
///   ]),
///   patch: fn(data) {
///     [
///       SetText(".value", int.to_string(data)),
///       SetStyle(".bar", "width", int.to_string(data) <> "%"),
///     ]
///   }
/// )
/// ```
@target(javascript)
pub fn live(
  slice slice: fn(model) -> a,
  initial initial: html,
  patch patch: fn(a) -> List(Patch),
) -> Component(model, msg, html) {
  Live(
    slice: fn(model) { to_dynamic(slice(model)) },
    initial: initial,
    apply: fn(model) { patch(slice(model)) },
    compare: ReferenceEqual,
  )
}

/// This is the entry point for rendering, mounting a component tree to a
/// specific DOM element.. It creates a subscription to the store and renders
/// the entire component tree whenever the model changes.
///
/// ## Parameters
///
/// - `store`: The application store
/// - `selector`: CSS selector for the mount point (e.g., `"#app"`)
/// - `to_html`: Function to convert `html` type to `String` (e.g.,
///   `element.to_string` for Lustre or `fn(html) {html}` for raw HTML strings)
/// - `view`: Function that takes the model and returns the root component tree
///
/// ## Example
///
/// ```gleam
/// runtime
/// |> component.mount(selector: "#app", to_html: element.to_string, view: app)
/// ```
@target(javascript)
pub fn mount(
  runtime: Runtime(model, msg),
  selector selector: String,
  to_html to_html: fn(html) -> String,
  view view: fn(model) -> Component(model, msg, html),
) -> Runtime(model, msg) {
  // Clear any previous mount at this selector
  client.clear_component_cache(runtime, selector)

  // Initial render - this sets up all component subscriptions
  let model = get_model(runtime)
  let tree = view(model)
  render_tree(runtime, selector, tree, model, to_html, runtime, 0)

  runtime
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
/// ## Example
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { model.transfer_amount },
///   render: fn(amount) {
///     html.button([], [html.text("Transfer $" <> int.to_string(amount))])
///   },
/// )
/// |> component.require_connection(fn(model) { model.connected })
/// ```
@target(javascript)
pub fn require_connection(
  component: Component(model, msg, html),
  connected connected: fn(model) -> Bool,
) -> Component(model, msg, html) {
  RequireConnection(inner: component, connected: connected)
}

/// This is the most common component type. It subscribes to a slice of the
/// model and re-renders the entire component when that slice changes.
///
/// The `render` function should return HTML (in whatever type is defined on
/// [`component.mount`](#mount)).
///
/// ## Example
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { model.count },
///   render: fn(count) {
///     html.div([], [html.text("Count: " <> int.to_string(count))])
///   }
/// )
/// ```
@target(javascript)
pub fn simple(
  slice slice: fn(model) -> a,
  render render: fn(a) -> html,
) -> Component(model, msg, html) {
  Simple(
    slice: fn(model) { to_dynamic(slice(model)) },
    view: fn(model) { render(slice(model)) },
    compare: ReferenceEqual,
  )
}

/// Static components render once and never update. Useful for headers, static
/// text, or any content that doesn't depend on the model.
///
/// ## Example
///
/// ```gleam
/// component.static(html.h1([], [html.text("My App")]))
/// ```
@target(javascript)
pub fn static(content: html) -> Component(model, msg, html) {
  Static(content)
}

/// Switch a component's comparison strategy from reference to structural
/// equality. By default, components use reference equality (`===`) to detect
/// slice changes. This works well for primitives and unchanged references.
///
/// Use `structural()` when your slice function returns new tuples, lists, or
/// other constructed values on every call.
///
/// Also see [`component.CompareStrategy`](#CompareStrategy).
///
/// ## Example
///
/// ```gleam
/// component.simple(
///   slice: fn(model) { #(model.x, model.y) },  // Returns new tuple each time
///   render: fn(pos) { ... }
/// )
/// |> component.structural  // Enable deep equality check
/// ```
@target(javascript)
pub fn structural(
  component: Component(model, msg, html),
) -> Component(model, msg, html) {
  case component {
    Static(content) -> Static(content)
    Simple(slice, view, _) ->
      Simple(slice: slice, view: view, compare: StructuralEqual)
    Live(slice, initial, apply, _) ->
      Live(
        slice: slice,
        initial: initial,
        apply: apply,
        compare: StructuralEqual,
      )
    Each(produce, _) ->
      Each(produce: produce, compare: StructuralEqual)
    EachLive(keys, initial, apply, _) ->
      EachLive(
        keys: keys,
        initial: initial,
        apply: apply,
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

/// Get the model from the runtime
@target(javascript)
@external(javascript, "./component.ffi.mjs", "getModel")
fn get_model(_runtime: Runtime(model, msg)) -> model {
  // This will never run
  panic as "getModel is only available in JavaScript"
}

/// Renders a component tree to HTML and creates subscriptions for dynamic
/// components. This is called on initial render and on every model update.
@target(javascript)
@external(javascript, "./component.ffi.mjs", "renderTree")
fn render_tree(
  _runtime: Runtime(model, msg),
  _root_selector: String,
  _component: Component(model, msg, html),
  _model: model,
  _to_html: fn(html) -> String,
  _store: Runtime(model, msg),
  _depth: Int,
) -> Nil {
  Nil
}

/// Wraps any value as Dynamic for use as a comparison key. On JavaScript this
/// is an identity function as the runtime doesn't distinguish types. This
/// replaces the old `dynamic.from` in gleam_stdlib. As much as I hate doing
/// this, this is necessary as the slice type is not known at library
/// compilation time.
@target(javascript)
@external(javascript, "./component.ffi.mjs", "identity")
fn to_dynamic(value: a) -> Dynamic {
  // This will never run
  let _ = value
  panic as "This should never be called - JavaScript only"
}
