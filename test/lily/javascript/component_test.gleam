// Tests for lily/component — DOM rendering.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/int
@target(javascript)
import gleam/string
@target(javascript)
import gleeunit/should
@target(javascript)
import lily
@target(javascript)
import lily/client
@target(javascript)
import lily/component
@target(javascript)
import lily/test_dom
@target(javascript)
import lily/test_fixtures.{type Message, type Model, Increment}
@target(javascript)
import lily/test_setup

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn to_html(html: String) -> String {
  html
}

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start
}

// =============================================================================
// STATIC
// =============================================================================

@target(javascript)
pub fn component_static_renders_content_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) { component.static("<p>Hello</p>") },
    )
  test_dom.inner_html("#app")
  |> string.contains("Hello")
  |> should.be_true
}

// =============================================================================
// MOUNT
// =============================================================================

@target(javascript)
pub fn component_mount_clears_previous_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) { component.static("<span>first</span>") },
    )
  let first_html = test_dom.inner_html("#app")
  first_html
  |> string.contains("first")
  |> should.be_true
  let _r2 =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) { component.static("<span>second</span>") },
    )
  let second_html = test_dom.inner_html("#app")
  second_html
  |> string.contains("second")
  |> should.be_true
}

@target(javascript)
pub fn component_mount_renders_to_dom_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(slice: fn(m: Model) { m.count }, render: fn(count) {
          int.to_string(count)
        })
      },
    )
  test_dom.inner_html("#app")
  |> should.not_equal("")
}

// =============================================================================
// SIMPLE
// =============================================================================

@target(javascript)
pub fn component_simple_name_renders_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(slice: fn(m: Model) { m.name }, render: fn(name) {
          "name:" <> name
        })
      },
    )
  test_dom.inner_html("#app")
  |> string.contains("name:")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_renders_initial_slice_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(slice: fn(m: Model) { m.count }, render: fn(count) {
          "count:" <> int.to_string(count)
        })
      },
    )
  test_dom.inner_html("#app")
  |> string.contains("count:0")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_updates_on_model_change_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(slice: fn(m: Model) { m.count }, render: fn(count) {
          "count:" <> int.to_string(count)
        })
      },
    )
  client.dispatch(runtime)(Increment)
  test_dom.inner_html("#app")
  |> string.contains("count:1")
  |> should.be_true
}

// =============================================================================
// LIVE
// =============================================================================

@target(javascript)
pub fn component_live_applies_patches_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.live(
          slice: fn(m: Model) { m.count },
          initial: "<div><span class=\"val\">0</span></div>",
          patch: fn(count) { [component.SetText(".val", int.to_string(count))] },
        )
      },
    )
  client.dispatch(runtime)(Increment)
  test_dom.get_text(".val")
  |> should.equal("1")
}

@target(javascript)
pub fn component_live_applies_set_attribute_patch_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.live(
          slice: fn(m: Model) { m.count },
          initial: "<div class=\"box\"></div>",
          patch: fn(count) {
            [component.SetAttribute("", "data-count", int.to_string(count))]
          },
        )
      },
    )
  client.dispatch(runtime)(Increment)
  test_dom.get_attribute("[data-lily-component]", "data-count")
  |> should.equal("1")
}

@target(javascript)
pub fn component_live_renders_initial_html_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.live(
          slice: fn(m: Model) { m.count },
          initial: "<div><span class=\"val\">0</span></div>",
          patch: fn(count) { [component.SetText(".val", int.to_string(count))] },
        )
      },
    )
  test_dom.inner_html("#app")
  |> string.contains("val")
  |> should.be_true
}

// =============================================================================
// FRAGMENT
// =============================================================================

@target(javascript)
pub fn component_fragment_renders_children_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.fragment([
          component.static("<span>one</span>"),
          component.static("<span>two</span>"),
        ])
      },
    )
  let html = test_dom.inner_html("#app")
  html
  |> string.contains("one")
  |> should.be_true
  html
  |> string.contains("two")
  |> should.be_true
}

// =============================================================================
// EACH
// =============================================================================

@target(javascript)
pub fn component_each_renders_keyed_list_test() {
  test_setup.reset_dom()
  let runtime =
    lily.new(test_fixtures.WithList(items: [1, 2, 3]), with: fn(model, _msg) {
      model
    })
    |> client.start
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.each(
          slice: fn(m: test_fixtures.WithList) { m.items },
          key: fn(i) { i },
          render: fn(i) { "<span>" <> int.to_string(i) <> "</span>" },
        )
      },
    )
  let html = test_dom.inner_html("#app")
  html
  |> string.contains("data-lily-key")
  |> should.be_true
  html
  |> string.contains("<span>1</span>")
  |> should.be_true
}

// =============================================================================
// REQUIRE_CONNECTION
// =============================================================================

@target(javascript)
pub fn component_require_connection_adds_disabled_when_disconnected_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(slice: fn(m: Model) { m.count }, render: fn(count) {
          int.to_string(count)
        })
        |> component.require_connection(fn(m: Model) { m.connected })
      },
    )
  test_dom.has_attribute("[data-lily-component]", "data-lily-disabled")
  |> should.be_true
}

@target(javascript)
pub fn component_require_connection_removes_disabled_when_connected_test() {
  test_setup.reset_dom()
  let runtime =
    lily.new(
      test_fixtures.Model(count: 0, name: "", connected: True),
      with: test_fixtures.update,
    )
    |> client.start
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(slice: fn(m: Model) { m.count }, render: fn(count) {
          int.to_string(count)
        })
        |> component.require_connection(fn(m: Model) { m.connected })
      },
    )
  test_dom.has_attribute("[data-lily-component]", "data-lily-disabled")
  |> should.be_false
}

// =============================================================================
// STRUCTURAL
// =============================================================================

@target(javascript)
pub fn component_structural_on_simple_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) {
        component.simple(
          slice: fn(m: Model) { #(m.count, m.name) },
          render: fn(pair) {
            let #(count, name) = pair
            int.to_string(count) <> ":" <> name
          },
        )
        |> component.structural
      },
    )
  test_dom.inner_html("#app")
  |> string.contains("0:")
  |> should.be_true
}

@target(javascript)
pub fn component_structural_on_static_is_noop_test() {
  let static_component = component.static("hello")
  let structural_component = component.structural(static_component)
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      view: fn(_model) { structural_component },
    )
  test_dom.inner_html("#app")
  |> should.equal("hello")
}
