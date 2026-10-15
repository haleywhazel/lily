// component.render_to_string, the pure SSR walker
// same view must give the same HTML on both targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/int
import gleeunit/should
import lily/component
import lily/test_support.{type Message, type Model}

// =============================================================================
// HELPERS
// =============================================================================

fn from_string(html: String) -> String {
  html
}

fn render(
  view: fn(Model) -> component.Component(Model, Message, String),
) -> String {
  component.render_to_string(
    view: view,
    model: test_support.initial_model(),
    to_html: test_support.to_html,
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
// EACH
// =============================================================================

pub fn render_each_renders_per_item_test() {
  // initial_model has 3 default cards
  render(fn(_) {
    component.each(
      slice: fn(_) { [1, 2, 3] },
      key: fn(number) { int.to_string(number) },
      render: fn(number, _) { "[" <> int.to_string(number) <> "]" },
    )
  })
  |> should.equal("[1][2][3]")
}

// =============================================================================
// LIVE
// =============================================================================

pub fn render_live_uses_initial_test() {
  render(fn(_) {
    component.live(
      slice: fn(_) { 0 },
      render: fn(_, _) { "<gauge>0</gauge>" },
      patch: fn(_) { [] },
    )
  })
  |> should.equal("<gauge>0</gauge>")
}

// =============================================================================
// NESTING
// =============================================================================

pub fn render_simple_nested_via_slot_test() {
  // slotter renders inner inline, from_string rewraps it as html (String)
  render(fn(_) {
    component.simple(slice: fn(_) { Nil }, render: fn(_, slot) {
      "<outer>" <> slot(component.static(fn(_) { "<inner/>" })) <> "</outer>"
    })
  })
  |> should.equal("<outer><inner/></outer>")
}

// =============================================================================
// DECORATIONS
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
