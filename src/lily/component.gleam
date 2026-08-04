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
//// There are five types, each with its own implementation details:
////
//// 1. [`static`](#static) renders once and never updates
//// 2. [`simple`](#simple) morphs the subtree in place when the slice changes
//// 3. [`live`](#live) applies targeted patches you hand-write
//// 4. [`each`](#each) handles keyed lists
//// 5. [`fragment`](#fragment) groups other components into one slot
////
//// `simple` is usually best for any dynamic component that you want to use
//// (that reacts to changes in the store), and `live` lets you hand-write
//// patches if you want smoother patching of dynamic components instead of
//// having to run through large DOM subtree at every frame. Lily doesn't use a
//// VDOM so these choices are entirely yours to make for your own performance
//// reqs.
////
//// (The main tradeoff of this design is that it slightly goes against only
//// one way to do things philosophy of Gleam and Lustre.)
////
//// On top of its type, a component carries decorations, each applied with a
//// pipe:
//// 1. [`transition`](#transition) adds CSS enter/exit classes timed to a
////    duration (with deferred DOM removal so the exit animation finishes
////    before the element leaves)
//// 2. [`event.on`](./event.html#on) and friends attach listeners
//// 3. [`scoped`](#scoped) fixes the subtree an event locks itself to
//// 4. [`require_connection`](#require_connection) gates the subtree on
////    connection status.
////
//// `static`, `simple`, and `live` hand their content function a `slot`
//// function as its first argument. Call `slot(child_component)` wherever you
//// want a child to appear in the parent template, it returns a placeholder of
//// your `html` type that gets swapped for the rendered child once the parent
//// serialises. Nest it as deep as you like:
////
//// ```gleam
//// component.live(
////   slice: fn(model) { model.is_active },
////   initial: fn(slot) {
////     html.section([attribute.class("column")], [
////       html.h2([], [html.text("Title")]),
////       slot(component.each(
////         slice: fn(model) { cards_for(model) },
////         key: fn(card) { card.id },
////         render: render_card,
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
//// unchanged, comparing structurally (deep equality), so a slice that builds a
//// new tuple or record each time still compares equal by value. Keep slices
//// cheap and do the heavy lifting in `render`, which the comparison gates.
//// Here's the whole thing end to end:
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
////     |> client.start(shared.wiring(), shared.serialiser())
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
//// [`each`](#each) item bodies are not collected, so put them on the each
//// wrapper or any static ancestor instead (probably a div).
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

/// The core type for renderable content. Opaque, use the builder functions to
/// create components. The `html` type parameter is user-provided, any type
/// representing HTML markup.
///
/// Each dynamic [`ComponentType`](#ComponentType) variant (all but `Static`
/// and `Fragment`) detects slice changes by structural equality (`==`, deep),
/// so a slice constructing new tuples, lists, or records each call still
/// compares equal by value.
///
/// Compiles on both targets. Builders and the pure walker
/// [`render_to_string`](#render_to_string) work on Erlang and JavaScript alike.
/// [`mount`](#mount) is JavaScript-only, it mutates the live DOM.
pub opaque type Component(model, message, html) {
  /// A `component_type` (how it renders) plus `decorations` (cross-cutting
  /// attributes layered on top: CSS transition, event listeners, connection
  /// gate). Applied innermost-first in list order, so the last wraps outermost.
  ///
  /// `scope` is the component's own CSS selector (usually `#<id>`), recorded by
  /// [`scoped`](#scoped). The `event.on*` binders read it to confine listeners
  /// to this subtree, `None` means no scope was set.
  Component(
    component_type: ComponentType(model, message, html),
    decorations: List(Decoration(model)),
    scope: Option(String),
  )
}

/// Targeted DOM updates for [`component.live`](#live), avoiding a full
/// re-render. `target` is a CSS selector relative to the component's root, an
/// empty string meaning the root itself. Patches are scoped to their component,
/// preventing cross-component interference. Compiles on both targets so it can
/// appear in [`Component`](#Component)'s patch-bearing variants on Erlang too,
/// but patches only apply via [`mount`](#mount), which is JavaScript-only.
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

/// Takes a child `Component` and returns an `html` placeholder marking where
/// it renders. Passed as the first parameter of every `static`, `simple`, and
/// `live` content function. Call inline where the child should appear, call
/// order determines DOM position.
pub type Slotter(model, message, html) =
  fn(Component(model, message, html)) -> html

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// A keyed dynamic list, reconciled by add/remove/reorder so only changed
/// items update.
///
/// `slice` returns a `List`, `render` returns a `Component` per item (wrap
/// plain HTML with [`static`](#static)). Keys can be any type, stringified
/// internally. Event bindings inside `render` aren't collected, so put per-list
/// events on this component or an ancestor.
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
  new_component(
    Each(
      slice: fn(model) { list_dynamic(slice(model)) },
      key: fn(item) { string.inspect(key(from_dynamic(item))) },
      render: fn(item) { render(from_dynamic(item)) },
    ),
  )
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

/// Renders initial HTML once, then applies the targeted patches you return on
/// update. A hand-written diff, the escape hatch for a profiled hot path where
/// [`simple`](#simple)'s morph walk is too costly (a large subtree updating at
/// high frequency where each change touches little).
///
/// [`simple`](#simple) already preserves nodes, so `live` isn't needed just to
/// keep focus or in-progress input, use it only for the hot-path case.
///
/// `patch` returns `Patch` values, each targeting an element under the
/// component root by CSS selector. `initial`'s first parameter is a
/// [`Slotter`](#Slotter), call `slot(child)` for a nested component or ignore
/// it with `_`.
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
  new_component(
    Live(
      slice: fn(model) { to_dynamic(slice(model)) },
      initial: initial,
      apply: fn(data) { patch(from_dynamic(data)) },
    ),
  )
}

@target(javascript)
/// The rendering entry point. Mounts a component tree onto a DOM element,
/// subscribes it to the store, and registers every event binding attached via
/// [`event.on()`](./event.html#on) and friends.
///
/// - `selector`: the mount point, e.g. `"#app"`
/// - `to_html`: converts your `html` type to `String`, `element.to_string` for
///   Lustre or `fn(html) { html }` for raw strings
/// - `to_slot`: returns an `html` placeholder serialising to
///   `<lily-slot></lily-slot>`, used when nesting via [`Slotter`](#Slotter)
/// - `view`: takes the model, returns the root component tree
///
/// Call `mount` more than once on a shared runtime, with different selectors,
/// to drive several DOM roots from one model (how overlays and portals work).
/// Mounting the same selector again replaces the previous mount.
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
  let model = client.get_current_model(runtime)
  let tree = view(model)
  // Render also registers bindings. renderComponent (JS) queues every
  // component's `Listener` decorations, including slot children the Gleam
  // tree walk can't reach (they're built via the slotter callback at render
  // time). render_tree drains the queue after innerHTML, so element-scoped
  // listeners find their target in the DOM.
  render_tree(runtime, selector, tree, model, to_html, to_slot)

  runtime
}

/// Render a view to an HTML string without touching the DOM, walking the
/// [`Component`](#Component) tree and piping each render through `to_html`.
/// Compiles on both targets, so you can produce initial markup ahead of time,
/// at build time or from a plain request handler. Pair with
/// [`transport.encode_initial_snapshot`](./transport.html#encode_initial_snapshot)
/// and [`client.hydrate`](./client.html#hydrate) so the client adopts the
/// pre-rendered DOM. This is static pre-rendering plus hydration, not
/// per-request SSR.
///
/// Nested components placed via the [`Slotter`](#Slotter) callback render
/// inline, `from_string` wraps each child's string back into an `html` value,
/// the identity for raw-HTML libraries, an `unsafe_raw_html`-style constructor
/// for Lustre.
///
/// Event bindings, focus, and CSS transitions are skipped, they only make sense
/// on a live DOM. For [`live`](#live) the `initial` baseline renders, patches
/// apply only at runtime via [`mount`](#mount).
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
/// connection status from the model, and when it returns `False` Lily adds
/// `data-lily-disabled="true"`, `aria-disabled="true"`, and a
/// `lily-disconnected` class to the root and stops event handlers firing.
/// Style the disconnected state with CSS. Pipe on after building a component.
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

/// The default component. Subscribes to a slice and re-renders on change,
/// morphing onto the live DOM so existing nodes survive (focus, cursor,
/// in-progress input, and nested reactive children all kept).
///
/// `render` receives the slice value and a [`Slotter`](#Slotter), call
/// `slot(child)` for a nested component or ignore it with `_`.
///
/// Reach for [`live`](#live) only when a large subtree updates so often that
/// the morph walk is measurably too costly.
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
/// Pipe through [`event.on()`](./event.html#on) and friends to attach DOM event
/// handlers to the rendered subtree, registered once at [`mount`](#mount).
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

/// Renders once and never updates. Good for headers, static text, anything not
/// depending on the model.
///
/// `content` receives a [`Slotter`](#Slotter), call `slot(child)` for a nested
/// component or ignore it with `_`.
///
/// ```gleam
/// component.static(fn(_) { html.h1([], [html.text("My App")]) })
/// ```
pub fn static(
  content content: fn(Slotter(model, message, html)) -> html,
) -> Component(model, message, html) {
  new_component(Static(content))
}

/// Decorate a component with enter and exit CSS classes timed to a duration.
/// The component comes first so it chains like the other decorators. On mount
/// the wrapper carries `enter` for `duration_milliseconds`, then drops it. On
/// unmount (an enclosing `each` or a `simple` morph removing it) `exit` is
/// applied and DOM removal is deferred by the same duration, with
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
/// `forwards` on exit keeps the final state visible while the framework holds
/// the element in the DOM, preventing a flicker before removal.
///
/// Placement rule, transitions fire when the framework's removal path runs
/// through them, `each` child removal and a `simple` morph dropping the
/// transitioned child (an open/close panel). The `simple` morph runs the exit
/// animation before the node leaves, and re-opening cancels a mid-exit.
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
  add_decoration(component, Transition(enter:, exit:, duration_milliseconds:))
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

/// What a [`Component`](#Component) renders as. One variant per rendering
/// strategy, cross-cutting concerns live in [`Decoration`](#Decoration).
@internal
pub type ComponentType(model, message, html) {
  /// Keyed list, innerHTML per child. Carries the primitive slice, key, and
  /// render functions directly so the FFI evaluates only what it needs per
  /// item.
  Each(
    slice: fn(model) -> List(Dynamic),
    key: fn(Dynamic) -> String,
    render: fn(Dynamic) -> Component(model, message, html),
  )

  /// Groups multiple components, no wrapper element
  Fragment(children: List(Component(model, message, html)))

  /// Patch-based updates for a 60fps hot path
  Live(
    slice: fn(model) -> Dynamic,
    initial: fn(Slotter(model, message, html)) -> html,
    apply: fn(Dynamic) -> List(Patch),
  )

  /// Morphs the subtree in place when the slice changes
  Simple(
    slice: fn(model) -> Dynamic,
    render: fn(Dynamic, Slotter(model, message, html)) -> html,
  )

  /// Renders once, no subscription to model changes
  Static(content: fn(Slotter(model, message, html)) -> html)
}

/// A cross-cutting attribute layered onto a [`Component`](#Component) via the
/// decoration list. Each appended by a constructor: [`transition`](#transition)
/// adds `Transition`, `event.on*` (via `attach_event`) adds `Listener`, and
/// [`require_connection`](#require_connection) adds `Connection`. Applied
/// innermost-first in list order.
@internal
pub type Decoration(model) {
  /// Duration-timed CSS enter/exit classes on a wrapper element (see
  /// [`transition`](#transition)).
  Transition(enter: String, exit: String, duration_milliseconds: Int)

  /// A single event binding, an opaque `fn(Dynamic) -> Nil` closure taking the
  /// runtime (as `Dynamic` so the field compiles on Erlang) and registering its
  /// DOM listener at mount. Never invoked on Erlang (mount is JavaScript-only).
  Listener(handler: fn(Dynamic) -> Nil)

  /// Gates the subtree on connection status. When `connected` returns `False`
  /// the wrapper is marked disabled (`data-lily-disabled`, `aria-disabled`,
  /// `lily-disconnected`).
  Connection(connected: fn(model) -> Bool)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@target(javascript)
/// Attach an event binding by appending a `Listener` decoration. Called from
/// `lily/event`, not by users.
///
/// The binding is wrapped in an opaque `fn(Dynamic) -> Nil` closure before
/// storing, since `Listener` holds opaque bindings to keep
/// [`Component`](#Component) cross-target. The closure casts the `Dynamic` back
/// to a typed `Runtime` on invocation.
@internal
pub fn attach_event(
  component component: Component(model, message, html),
  binding binding: EventBinding(model, message),
) -> Component(model, message, html) {
  let opaque_binding = fn(runtime_dynamic: Dynamic) {
    binding(from_dynamic(runtime_dynamic))
  }
  // Listeners register in attach order, the first-attached fires first at
  // dispatch. That lets a specific handler with `stop_propagation` (attached
  // before a broader ancestor-selector handler) block the broader one, since
  // all delegated listeners share one node and run in registration order.
  // `add_decoration` prepends, so `register_bindings` reverses at read time.
  add_decoration(component, Listener(opaque_binding))
}

@target(javascript)
/// Walk the tree invoking every `event.on*` binding (each a `Listener`
/// decoration) and recursing into Fragment children. Stops at Each, its
/// per-item render bodies aren't inspected, so events inside item components
/// are ignored by design (see the `each` docstring).
///
/// Called from [`mount`](#mount) before the FFI render pass. `@internal` so
/// tests can register bindings without mounting (and wiping the DOM container).
@internal
pub fn register_bindings(
  runtime: Runtime(model, message),
  component: Component(model, message, html),
) -> Nil {
  let runtime_dynamic = to_dynamic(runtime)
  // Reverse to fire in attach order (add_decoration prepends)
  list.each(list.reverse(component.decorations), fn(decoration) {
    case decoration {
      Listener(handler:) -> handler(runtime_dynamic)
      Transition(..) | Connection(..) -> Nil
    }
  })
  case component.component_type {
    Fragment(children:) ->
      list.each(children, fn(child) { register_bindings(runtime, child) })
    Each(..) | Live(..) | Simple(..) | Static(..) -> Nil
  }
}

/// Read a component's recorded scope selector (see [`scoped`](#scoped)),
/// `None` when unset. Consumed by `lily/event`'s binders to confine a listener
/// to the component's own subtree.
@internal
pub fn scope(component: Component(model, message, html)) -> Option(String) {
  component.scope
}

/// Record a component's own CSS selector (usually `#<id>`) as its scope, so the
/// scoped `event.on*` binders match only within its subtree. Pipe on after
/// giving the component an `id`, then pipe on `event.on` without a selector.
///
/// ```gleam
/// component.simple(slice: ..., render: ...)
/// |> component.scoped("#search")
/// |> event.on(event: event.input, handler: Search)
/// ```
pub fn scoped(
  component component: Component(model, message, html),
  selector selector: String,
) -> Component(model, message, html) {
  Component(..component, scope: option.Some(selector))
}

/// Pure walker for [`render_to_string`](#render_to_string). Recurses into every
/// variant, filling slots inline by walking the child and wrapping its string
/// via `from_string` before handing it back to the render function. Decorations
/// (listeners, connection gating, transitions) only matter on a live DOM, so
/// the walk delegates straight to the component type.
@internal
pub fn walk_to_string(
  component: Component(model, message, html),
  model: model,
  to_html: fn(html) -> String,
  from_string: fn(String) -> html,
) -> String {
  // Decorations only matter on a live DOM, so delegate to the component type.
  // The slot filler is identical for the three variants that use it, so build
  // it once. The Each and Fragment branches recurse without a slotter.
  let slotter = make_slotter(model, to_html, from_string)
  case component.component_type {
    Static(content:) -> to_html(content(slotter))

    Simple(slice:, render:) -> to_html(render(slice(model), slotter))

    Live(slice: _, initial:, apply: _) -> to_html(initial(slotter))

    Each(slice:, key: _, render:) -> {
      slice(model)
      |> list.map(fn(item) {
        walk_to_string(render(item), model, to_html, from_string)
      })
      |> string.concat
    }

    Fragment(children:) ->
      children
      |> list.map(walk_to_string(_, model, to_html, from_string))
      |> string.concat
  }
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn add_decoration(
  component: Component(model, message, html),
  decoration: Decoration(model),
) -> Component(model, message, html) {
  // O(1) prepend, consumers reverse to restore attach order.
  Component(..component, decorations: [decoration, ..component.decorations])
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
/// capture the event constant, selector, options, and handler in the closure.
/// Invoked with the runtime during `mount` to register the DOM listener.
type EventBinding(model, message) =
  fn(Runtime(model, message)) -> Nil

// =============================================================================
// PRIVATE FFI
// =============================================================================

/// Cast a Dynamic back to the slice type, identity passthrough on both targets.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./component.ffi.mjs", "identity")
fn from_dynamic(value: Dynamic) -> a

/// Type-erase a `List(item)` to `List(Dynamic)`, identity passthrough on both
/// targets.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./component.ffi.mjs", "identity")
fn list_dynamic(value: List(a)) -> List(Dynamic)

@target(javascript)
/// Render a component tree to HTML and create subscriptions for dynamic
/// components. Called once at mount, subsequent updates flow through the
/// registered per-component handlers.
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

/// Wrap any value as Dynamic for use as a comparison key, identity passthrough
/// on both targets.
@external(erlang, "lily_reflection_ffi", "passthrough")
@external(javascript, "./component.ffi.mjs", "identity")
fn to_dynamic(value: a) -> Dynamic
