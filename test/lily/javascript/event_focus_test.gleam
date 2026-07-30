// Tests for lily/event focus groups, escape dismissal and file drops.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/component
@target(javascript)
import lily/event
@target(javascript)
import lily/test_support

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn mount_focus_group_dom() -> Nil {
  test_support.set_inner_html(
    "#app",
    "<div id=\"g\">"
      <> "<button id=\"i1\">1</button>"
      <> "<button id=\"i2\">2</button>"
      <> "<button id=\"i3\">3</button>"
      <> "</div>",
  )
}

// =============================================================================
// FOCUS GROUP
// =============================================================================

@target(javascript)
pub fn event_focus_group_arrow_moves_focus_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  test_support.mount_event(runtime, fn(c) {
    event.arrow_group(
      c,
      items: "#g button",
      orientation: event.Vertical,
      wrap: True,
    )
  })
  test_support.focus("#i1")
  test_support.key_event("#g", "keydown", "ArrowDown")
  test_support.active_element_id()
  |> should.equal("i2")
  test_support.key_event("#g", "keydown", "ArrowDown")
  test_support.active_element_id()
  |> should.equal("i3")
  event.release_arrow_group(runtime, "#g button")
}

@target(javascript)
pub fn event_focus_group_wraps_past_the_ends_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  test_support.mount_event(runtime, fn(c) {
    event.arrow_group(
      c,
      items: "#g button",
      orientation: event.Vertical,
      wrap: True,
    )
  })
  test_support.focus("#i3")
  test_support.key_event("#g", "keydown", "ArrowDown")
  test_support.active_element_id()
  |> should.equal("i1")
  test_support.key_event("#g", "keydown", "ArrowUp")
  test_support.active_element_id()
  |> should.equal("i3")
  event.release_arrow_group(runtime, "#g button")
}

@target(javascript)
pub fn event_focus_group_clamps_without_wrap_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  test_support.mount_event(runtime, fn(c) {
    event.arrow_group(
      c,
      items: "#g button",
      orientation: event.Vertical,
      wrap: False,
    )
  })
  test_support.focus("#i1")
  test_support.key_event("#g", "keydown", "ArrowUp")
  test_support.active_element_id()
  |> should.equal("i1")
  event.release_arrow_group(runtime, "#g button")
}

@target(javascript)
pub fn event_focus_group_home_end_jump_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  test_support.mount_event(runtime, fn(c) {
    event.arrow_group(
      c,
      items: "#g button",
      orientation: event.Vertical,
      wrap: False,
    )
  })
  test_support.focus("#i2")
  test_support.key_event("#g", "keydown", "End")
  test_support.active_element_id()
  |> should.equal("i3")
  test_support.key_event("#g", "keydown", "Home")
  test_support.active_element_id()
  |> should.equal("i1")
  event.release_arrow_group(runtime, "#g button")
}

@target(javascript)
pub fn event_focus_group_respects_orientation_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  test_support.mount_event(runtime, fn(c) {
    event.arrow_group(
      c,
      items: "#g button",
      orientation: event.Vertical,
      wrap: True,
    )
  })
  test_support.focus("#i1")
  // A vertical group ignores horizontal arrows.
  test_support.key_event("#g", "keydown", "ArrowRight")
  test_support.active_element_id()
  |> should.equal("i1")
  event.release_arrow_group(runtime, "#g button")
}

@target(javascript)
pub fn event_focus_group_release_stops_navigation_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  test_support.mount_event(runtime, fn(c) {
    event.arrow_group(
      c,
      items: "#g button",
      orientation: event.Vertical,
      wrap: True,
    )
  })
  event.release_arrow_group(runtime, "#g button")
  test_support.focus("#i1")
  test_support.key_event("#g", "keydown", "ArrowDown")
  test_support.active_element_id()
  |> should.equal("i1")
}

@target(javascript)
pub fn event_arrow_group_scopes_items_to_component_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  mount_focus_group_dom()
  // Relative items compose against the component's scope: `button` under
  // `#g` becomes `#g button`.
  test_support.mount_event(runtime, fn(component) {
    component
    |> component.scoped("#g")
    |> event.arrow_group(
      items: "button",
      orientation: event.Vertical,
      wrap: True,
    )
  })
  test_support.focus("#i1")
  test_support.key_event("#g", "keydown", "ArrowDown")
  test_support.active_element_id()
  |> should.equal("i2")
  event.release_arrow_group(runtime, "#g button")
}

// =============================================================================
// ESCAPE DISMISS
// =============================================================================

// Note: these assert the handler consumed the key (defaultPrevented) rather
// than the resulting message, because document-delegated click listeners
// persist across gleeunit tests, and a stop-propagation listener from another
// test would swallow the dispatched click. Consuming the key is the handler's
// own, isolation-safe signal that it found an open overlay and dismissed it.

@target(javascript)
pub fn watch_escape_dismiss_dismisses_open_overlay_on_escape_test() {
  test_support.reset_dom()
  // A trigger carrying a dismiss message, and an overlay panel that names it.
  test_support.set_inner_html(
    "#app",
    "<button id=\"esc-trigger\" data-message=\"toggle\">x</button>"
      <> "<div id=\"esc-panel\" data-lily-escape-dismiss=\"#esc-trigger\"></div>",
  )
  event.watch_escape_dismiss()
  // Escape finds the open overlay and consumes the key to dismiss it.
  test_support.key_event_default_prevented("#esc-panel", "keydown", "Escape")
  |> should.be_true
}

@target(javascript)
pub fn watch_escape_dismiss_ignores_other_keys_test() {
  test_support.reset_dom()
  test_support.set_inner_html(
    "#app",
    "<button id=\"esc-trigger\" data-message=\"toggle\">x</button>"
      <> "<div id=\"esc-panel\" data-lily-escape-dismiss=\"#esc-trigger\"></div>",
  )
  event.watch_escape_dismiss()
  // A non-Escape key leaves the overlay alone.
  test_support.key_event_default_prevented("#esc-panel", "keydown", "Enter")
  |> should.be_false
}

@target(javascript)
pub fn watch_escape_dismiss_inert_without_open_overlay_test() {
  test_support.reset_dom()
  // No element opts into dismissal, so Escape is left untouched.
  test_support.set_inner_html("#app", "<button id=\"plain\">x</button>")
  event.watch_escape_dismiss()
  test_support.key_event_default_prevented("#plain", "keydown", "Escape")
  |> should.be_false
}

// =============================================================================
// FILE DROPS
// =============================================================================

@target(javascript)
pub fn watch_file_drops_marks_dragover_test() {
  test_support.reset_dom()
  // A dropzone opting in, and the input it targets.
  test_support.set_inner_html(
    "#app",
    "<div id=\"dz\" data-lily-file-drop=\"#inp\"></div>"
      <> "<input id=\"inp\" type=\"file\" />",
  )
  event.watch_file_drops()
  test_support.has_attribute("#dz", "data-lily-file-dragover")
  |> should.be_false
  // Dragging over the zone marks it for styling. (Assigning dropped files needs
  // a real DataTransfer, which jsdom lacks, so that path is verified manually.)
  test_support.simple_event("#dz", "dragover")
  test_support.has_attribute("#dz", "data-lily-file-dragover")
  |> should.be_true
}
