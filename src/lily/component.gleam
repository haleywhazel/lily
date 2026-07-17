//// Components subscribe to the [`Store`](./store.html#Store) and re-render
//// when their slice of the model changes. They are stateless components and
//// focus more on rendering, so are fairly light (lighter than Lustre or
//// LiveView components, for example) and having a lot of components is not
//// an anti-pattern in Lily.
////
//// Each component is a [`ComponentType`](#ComponentType) plus zero or more
//// [`Decoration`](#Decoration)s (the things you pipe on, like a transition or
//// an event listener). You never reach for the constructors directly, you call
//// the builder function for the type you want.
////
//// There are seven types, each with its own performance profile:
////
//// 1. [`static`](#static) renders once and never updates
//// 2. [`simple`](#simple) re-renders via innerHTML when the slice changes
//// 3. [`live`](#live) applies targeted patches instead of full re-renders
//// 4. [`each`](#each) handles keyed lists with innerHTML rendering
//// 5. [`each_live`](#each_live) handles keyed lists with patch-based rendering
//// 6. [`fragment`](#fragment) groups other components into one slot
//// 7. [`switch`](#switch) renders one of several children by a discriminator,
////    keeping DOM identity while the discriminator is unchanged
////
//// `simple` swaps the component's entire DOM on every slice change, which
//// wipes focus, selection, and any half-typed input. `live` applies targeted
//// patches instead and leaves existing nodes untouched, so focus and typed
//// text survive the update. Anywhere there's an `<input>` or `<textarea>`,
//// `live` is almost certainly what you want, and the same rule carries to
//// lists, prefer `each_live` over `each` when items contain inputs or must not
//// lose focus.
////
//// On top of its type, a component carries decorations, each applied with a
//// pipe: [`transition`](#transition) adds CSS enter/exit classes timed to a
//// duration (with deferred DOM removal so the exit animation finishes before
//// the element leaves), [`event.on`](./event.html#on) and friends attach
//// listeners, [`scoped`](#scoped) fixes the subtree an event confines itself
//// to, and [`require_connection`](#require_connection) gates the subtree on
//// connection status.
////
//// `static`, `simple`, and `live` hand their content function a `slot`
//// function as its first argument. Call `slot(child_component)` wherever you
//// want a child to appear in the parent template, it returns a placeholder of
//// your `html` type that gets swapped for the rendered child once the parent
//// serialises. Nest as deep as you like:
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
//// `element.to_string` escapes text and attribute values, so the Lustre path
//// is safe. The raw-string `to_html: fn(html) { html }` above does not escape,
//// so interpolating model data (which on a synced app can carry other clients'
//// input) straight into that string is a stored-XSS vector. When using raw
//// strings, escape any untrusted text yourself. The `from_string` argument of
//// [`render_to_string`](#render_to_string) is the same, an `unsafe_raw_html`
//// style constructor inserts its string without escaping.
////
//// Every component declares a `slice` that pulls just the data it needs out of
//// the model. The runtime caches the last slice and skips rendering when it's
//// unchanged, using reference equality by default, or structural equality if
//// you pipe on [`structural`](#structural) (handy when the slice builds a new
//// tuple or record each time). Keep slices cheap and do the heavy lifting in
//// `render`, which the comparison gates. Here's the whole thing end to end:
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
//// Event handlers pipe onto the component they belong to via
//// [`event.on()`](./event.html#on), and the walk that [`mount`](#mount) does
//// registers each binding once at startup. Events declared inside
//// [`each`](#each) and [`each_live`](#each_live) item bodies are not
//// collected, so put them on the each/each_live wrapper or any static
//// ancestor instead (probably a div).
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
/// O(1)), `True` means structural equality (`==`, O(n)) and is set by
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
  /// listeners to this component's subtree, `None` means no scope was set.
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
/// patch-bearing variants on Erlang too, the patches themselves are only
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

/// A keyed dynamic list, reconciled by add/remove/reorder so only changed
/// items update. Like [`each_live`](#each_live) but each changed item is
/// re-rendered via `innerHTML` rather than patched.
///
/// Avoid `each` for items containing `<input>`, `<textarea>`, or `<select>`,
/// the `innerHTML` replace destroys focus and in-progress input. Use
/// [`each_live`](#each_live) there.
///
/// `slice` returns a `List`, and `render` returns a `Component` per item (wrap
/// plain HTML with [`static`](#static)). Keys can be any type, they are
/// stringified internally. Event bindings inside `render` aren't collected, so
/// put per-list events on this component or any ancestor.
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

/// A keyed dynamic list, reconciled by add/remove/reorder so only changed
/// items update. Like [`each`](#each) but items are patched instead of
/// re-rendered, which suits frequently-updated items.
///
/// `slice` returns a `List`. `initial` returns the first-render `Component`
/// per item (wrap plain HTML with [`static`](#static)), and `patch` returns
/// the patches for updates (the item's root must survive). Keys can be any
/// type, they are stringified internally. Event bindings inside `initial`
/// aren't collected, so put per-list events on this component or any ancestor.
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

/// Returns several components from one function. Children render in order and
/// concatenate into the parent's HTML, like Lustre's `element.fragment`.
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

/// Renders an initial HTML structure once, then applies targeted DOM patches
/// on update instead of the full `innerHTML` replace of [`simple`](#simple),
/// so existing nodes survive between updates.
///
/// Reach for `live` whenever the component holds `<input>`, `<textarea>`, or
/// `<select>`, since preserving nodes keeps focus, cursor, and in-progress
/// input intact. It also suits high-frequency updates like drag-and-drop,
/// animation, and real-time data.
///
/// `patch` returns `Patch` values, each targeting an element under the
/// component root by CSS selector. `initial`'s first parameter is a
/// [`Slotter`](#Slotter), call `slot(child)` where a nested component should
/// go, or ignore it with `_`.
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
/// The entry point for rendering. Mounts a component tree onto a DOM element,
/// subscribes it to the store, and registers every event binding attached via
/// [`event.on()`](./event.html#on) and friends.
///
/// - `selector`: the mount point, e.g. `"#app"`
/// - `to_html`: converts your `html` type to a `String`, `element.to_string`
///   for Lustre or `fn(html) { html }` for raw strings
/// - `to_slot`: returns an `html` placeholder that serialises to
///   `<lily-slot></lily-slot>`, used when nesting via [`Slotter`](#Slotter)
/// - `view`: takes the model and returns the root component tree
///
/// Call `mount` more than once on a shared runtime, with different selectors,
/// to drive several DOM roots from one model. This is how overlays and portals
/// work. Mounting the same selector again replaces the previous mount.
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
  // Render handles binding registration too. renderComponent on the JS
  // side queues every component's `Listener` decorations (including those
  // inside slot children, which the Gleam-side tree walk can't reach
  // because slot children are constructed via the slotter callback at
  // render time). render_tree drains the queue after innerHTML, so
  // element-scoped listeners find their target in the DOM.
  render_tree(runtime, selector, tree, model, to_html, to_slot)

  runtime
}

/// Render a view to an HTML string without touching the DOM, walking the
/// [`Component`](#Component) tree and piping each render through `to_html`. It
/// compiles on both targets, so you can produce the initial markup ahead of
/// time, at build time or from a plain request handler. Pair it with
/// [`transport.encode_initial_snapshot`](./transport.html#encode_initial_snapshot)
/// and [`client.hydrate`](./client.html#hydrate) so the client adopts the
/// pre-rendered DOM instead of re-rendering. This is static pre-rendering plus
/// hydration, not per-request server-side rendering.
///
/// Nested components placed via the [`Slotter`](#Slotter) callback render
/// inline, `from_string` wraps each child's string back into an `html` value.
/// For raw-HTML libraries it's the identity, for Lustre pass an
/// `unsafe_raw_html`-style constructor.
///
/// Event bindings, focus, and CSS transitions are skipped since they only make
/// sense on a live DOM. For [`live`](#live) and [`each_live`](#each_live) the
/// `initial` baseline renders, patches apply only at runtime via
/// [`mount`](#mount).
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

/// Disables a component while the transport is disconnected. `connected` reads
/// the connection status from the model, and when it returns `False` Lily adds
/// `data-lily-disabled="true"`, `aria-disabled="true"`, and a
/// `lily-disconnected` class to the root and stops event handlers firing.
/// Style the disconnected state however you like with CSS. Pipe it on after
/// building a component.
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

/// The most common component type. It subscribes to a slice of the model and
/// re-renders the whole component through `innerHTML` when that slice changes.
///
/// `render` receives the slice value and a [`Slotter`](#Slotter), call
/// `slot(child)` where a nested component should go, or ignore it with `_`.
///
/// Avoid `simple` for components holding `<input>`, `<textarea>`, or
/// `<select>`, the `innerHTML` replace destroys focus and in-progress input.
/// Use [`live`](#live) there.
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

/// Renders once and never updates. Good for headers, static text, or anything
/// that doesn't depend on the model.
///
/// `content` receives a [`Slotter`](#Slotter), call `slot(child)` where a
/// nested component should go, or ignore it with `_`.
///
/// ```gleam
/// component.static(fn(_) { html.h1([], [html.text("My App")]) })
/// ```
pub fn static(
  content content: fn(Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(Static(content))
}

/// Switch a component's comparison from reference to structural equality. By
/// default components use reference equality (`===`), which suits primitives
/// and unchanged references. Reach for `structural()` when your slice returns
/// new tuples, lists, or other constructed values each call.
///
/// `Static` and `Fragment` don't compare slices, so this returns them
/// unchanged.
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

/// Single-slot dynamic switching that preserves identity. `on` picks a
/// discriminator from the model and `case_of` turns it into a Component. While
/// the discriminator is unchanged the wrapper and child DOM are left alone, so
/// focus, selection, and input survive. When it changes, the old child's
/// handlers are unregistered and the new Component replaces the wrapper's
/// innerHTML.
///
/// Compares by reference by default, pipe through [`structural`](#structural)
/// when the slice builds new values each call. Bind events with
/// [`event.on()`](./event.html#on) on the switch itself, bindings inside the
/// built Component aren't collected and never fire.
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
/// The component comes first so it chains like the other decorators. On mount
/// the wrapper carries `enter` for `duration_milliseconds`, then drops it. On
/// unmount (when an enclosing `each`, `each_live`, or `switch` removes it)
/// `exit` is applied and DOM removal is deferred by the same duration, with
/// `animationend` winning if the CSS fires it first.
///
/// The CSS contract is keyframes-based.
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
/// **Placement rule**: transitions fire only when the framework's removal path
/// runs through them, which is `each`, `each_live`, and `switch` child
/// removal. A transition inside a `simple` render won't run exits on parent
/// re-render, since that innerHTML wipe is synchronous. Hoist it to an
/// `each_live` item or `switch` child if you need exits.
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
/// strategy, cross-cutting concerns live in [`Decoration`](#Decoration), not
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
  /// the slice is unchanged, on change, the old subtree is torn down and
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

  /// A single event binding, an opaque `fn(Dynamic) -> Nil` closure that
  /// receives the runtime (as `Dynamic` so the field compiles on Erlang) and
  /// registers its DOM listener when invoked at mount. On Erlang the closure
  /// is never invoked (mount is JavaScript-only).
  Listener(handler: fn(Dynamic) -> Nil)

  /// Gates the subtree on connection status. When `connected` returns `False`
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
  // Append so listeners register in the order they were attached, the
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
/// into every variant, slots are filled inline by walking the child and
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
/// (JavaScript has no runtime type tags, Erlang carries the original
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
/// components. Called once at mount time, subsequent updates flow through
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
