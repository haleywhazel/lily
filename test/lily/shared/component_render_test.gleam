// Tests for component.render_to_string, the pure SSR walker. Runs on both
// targets, the same view function should produce the same HTML output on
// Erlang and JavaScript.

import gleam/int
import gleeunit/should
import lily/component
import lily/test_fixtures.{type Message, type Model}

// =============================================================================
// HELPERS
// =============================================================================

/// View library: `html` is the same type as `String`, so `to_html` and
/// `from_string` are both identity. This keeps the tests focused on the
/// walker's structural behaviour rather than any specific HTML library.
fn to_html(s: String) -> String {
  s
}

fn from_string(s: String) -> String {
  s
}

fn render(
  view: fn(Model) -> component.Component(Model, Message, String),
) -> String {
  component.render_to_string(
    view: view,
    model: test_fixtures.initial_model(),
    to_html: to_html,
    from_string: from_string,
  )
}

// =============================================================================
// STATIC
// =============================================================================

pub fn render_static_returns_content_test() {
  render(fn(_) { component.static(fn(_) { "<h1>Hello</h1>" }) })
  |> should.equal("<h1>Hello</h1>")
}

// =============================================================================
// SIMPLE
// =============================================================================

pub fn render_simple_passes_slice_to_renderer_test() {
  render(fn(_) {
    component.simple(
      slice: fn(model: Model) { model.count },
      render: fn(count, _) { "<span>" <> int.to_string(count) <> "</span>" },
    )
  })
  |> should.equal("<span>0</span>")
}

// =============================================================================
// FRAGMENT
// =============================================================================

pub fn render_fragment_concatenates_children_test() {
  render(fn(_) {
    component.fragment([
      component.static(fn(_) { "<a>" }),
      component.static(fn(_) { "<b>" }),
      component.static(fn(_) { "<c>" }),
    ])
  })
  |> should.equal("<a><b><c>")
}

// =============================================================================
// SWITCH
// =============================================================================

pub fn render_switch_uses_built_component_test() {
  render(fn(_) {
    component.switch(on: fn(model: Model) { model.count }, case_of: fn(_) {
      component.static(fn(_) { "<switched/>" })
    })
  })
  |> should.equal("<switched/>")
}

// =============================================================================
// EACH
// =============================================================================

pub fn render_each_renders_per_item_test() {
  // initial_model has 3 default cards, render each one
  render(fn(_) {
    component.each(
      slice: fn(_) { [1, 2, 3] },
      key: fn(n) { int.to_string(n) },
      render: fn(n) {
        component.static(fn(_) { "[" <> int.to_string(n) <> "]" })
      },
    )
  })
  |> should.equal("[1][2][3]")
}

// =============================================================================
// LIVE / EACH_LIVE (initial baseline only, patches are ignored)
// =============================================================================

pub fn render_live_uses_initial_test() {
  render(fn(_) {
    component.live(
      slice: fn(_) { 0 },
      initial: fn(_) { "<gauge>0</gauge>" },
      patch: fn(_) { [] },
    )
  })
  |> should.equal("<gauge>0</gauge>")
}

pub fn render_each_live_uses_initial_per_item_test() {
  render(fn(_) {
    component.each_live(
      slice: fn(_) { ["a", "b"] },
      key: fn(s) { s },
      initial: fn(s) { component.static(fn(_) { "<x>" <> s <> "</x>" }) },
      patch: fn(_) { [] },
    )
  })
  |> should.equal("<x>a</x><x>b</x>")
}

// =============================================================================
// NESTING via slot
// =============================================================================

pub fn render_simple_nested_via_slot_test() {
  // Outer wraps inner content. The slotter renders the inner Component
  // inline and from_string wraps it back as the html (String) type.
  render(fn(_) {
    component.simple(slice: fn(_) { Nil }, render: fn(_, slot) {
      "<outer>" <> slot(component.static(fn(_) { "<inner/>" })) <> "</outer>"
    })
  })
  |> should.equal("<outer><inner/></outer>")
}

// =============================================================================
// DECORATIONS (Transition, Connection, Listener)
// =============================================================================

pub fn render_transition_passes_through_test() {
  render(fn(_) {
    component.static(fn(_) { "<inner/>" })
    |> component.transition(
      enter: "fade-in",
      exit: "fade-out",
      duration_milliseconds: 200,
    )
  })
  |> should.equal("<inner/>")
}
