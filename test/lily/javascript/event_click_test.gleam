// Tests for lily/event click delegation, options, simple events and
// component scoping. All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/component
@target(javascript)
import lily/event
@target(javascript)
import lily/test_support.{type Model, Increment, SetName}

// =============================================================================
// CLICK DELEGATION
// =============================================================================

@target(javascript)
pub fn event_on_click_with_data_message_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<button data-message=\"increment\">+</button>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
      options: event.options(),
    )
  })
  test_support.click("[data-message=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_click_disabled_ignored_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div data-lily-disabled=\"true\"><button data-message=\"increment\">+</button></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(_name) { Ok(Increment) },
      options: event.options(),
    )
  })
  test_support.click("[data-message=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(0)
}

@target(javascript)
pub fn event_on_click_without_data_message_ignored_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<button id=\"no-msg\">+</button>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(_name) { Ok(Increment) },
      options: event.options(),
    )
  })
  test_support.click("#no-msg")
  client.get_current_model(runtime).count
  |> should.equal(0)
}

// =============================================================================
// CLICK WITH OPTIONS
// =============================================================================

@target(javascript)
pub fn event_on_click_with_once_fires_only_once_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<button data-message=\"increment\">+</button>",
  )
  test_support.mount_event(runtime, fn(component) {
    event.on_global_decoded(
      component,
      event: event.click,
      selector: "#app",
      options: event.options() |> event.once,
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
  })
  test_support.click("[data-message=\"increment\"]")
  test_support.click("[data-message=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_click_with_stop_propagation_blocks_parent_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"sp-outer\"><div id=\"sp-inner\"><button data-message=\"increment\">+</button></div></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    component
    |> event.on_global_decoded(
      event: event.click,
      selector: "#sp-inner",
      options: event.options() |> event.stop_propagation,
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
    )
    |> event.on_global_decoded(
      event: event.click,
      selector: "#sp-outer",
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
      options: event.options(),
    )
  })
  test_support.click("[data-message=\"increment\"]")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
/// Regression: `stop_propagation` must only suppress events that match its own
/// binding's selector. A click matching a different, unrelated binding must
/// still reach that binding rather than be swallowed by the stop_propagation
/// listener registered earlier on the shared document.
pub fn event_on_click_stop_propagation_scoped_to_selector_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"sp-a\"><button data-message=\"hit\">a</button></div>"
      <> "<div id=\"sp-b\"><button data-message=\"hit\">b</button></div>",
  )
  test_support.mount_event(runtime, fn(component) {
    component
    |> event.on_global_decoded(
      event: event.click,
      selector: "#sp-a",
      options: event.options() |> event.stop_propagation,
      decoder: fn(_name) { Ok(Increment) },
    )
    |> event.on_global_decoded(
      event: event.click,
      selector: "#sp-b",
      options: event.options(),
      decoder: fn(_name) { Ok(SetName("b")) },
    )
  })

  test_support.click("#sp-b button")

  // The #sp-b handler fired (not swallowed by #sp-a's stop_propagation), and
  // #sp-a never fired since the click did not match it.
  let model = client.get_current_model(runtime)
  model.name
  |> should.equal("b")
  model.count
  |> should.equal(0)
}

// =============================================================================
// SIMPLE EVENTS
// =============================================================================

@target(javascript)
pub fn event_on_blur_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<input id=\"blur-in\" />")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.blur,
      selector: "#blur-in",
      handler: fn(_element) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#blur-in", "blur")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_submit_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#app", "<form id=\"test-form\"></form>")
  test_support.mount_event(runtime, fn(component) {
    event.on_global(
      component,
      event: event.submit,
      selector: "#test-form",
      handler: fn(_) { Increment },
      options: event.options(),
    )
  })
  test_support.simple_event("#test-form", "submit")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// COMPONENT SCOPING
// =============================================================================

@target(javascript)
pub fn event_on_scoped_fires_only_within_scope_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<div id=\"scope-in\"><input id=\"inner-field\" /></div>"
      <> "<input id=\"outer-field\" />",
  )
  test_support.mount_event(runtime, fn(component) {
    component
    |> component.scoped("#scope-in")
    |> event.on(event: event.input, handler: SetName, options: event.options())
  })
  // An input inside the scope dispatches.
  test_support.input_event("#inner-field", "Inside")
  client.get_current_model(runtime).name
  |> should.equal("Inside")
  // An input outside the scope is ignored: the model keeps the last value.
  test_support.input_event("#outer-field", "Outside")
  client.get_current_model(runtime).name
  |> should.equal("Inside")
}

@target(javascript)
pub fn event_duplicate_registration_replaces_not_stacks_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html(
    "#app",
    "<button data-message=\"increment\">+</button>",
  )
  // Registering the same (event, selector) binding twice, as a re-render does,
  // must leave one live listener, not two.
  let attach = fn(component) {
    event.on_global_decoded(
      component,
      event: event.click,
      selector: "#app",
      decoder: fn(name) {
        case name {
          "increment" -> Ok(Increment)
          _ -> Error(Nil)
        }
      },
      options: event.options(),
    )
  }
  test_support.mount_event(runtime, attach)
  test_support.mount_event(runtime, attach)
  test_support.click("[data-message=\"increment\"]")
  // One listener, so one dispatch: count is 1, not 2.
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_binding_registers_when_it_appears_on_rerender_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  // The scoped field is absent at mount and only appears once `count` becomes
  // non-zero, so its binding must register on the re-render, not just at mount.
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: fn(html) { html },
      to_slot: fn() { "<lily-slot></lily-slot>" },
      view: fn(_model) {
        component.simple(
          slice: fn(m: Model) { m.count },
          render: fn(count, slot) {
            case count {
              0 -> "<div id=\"host\"></div>"
              _ ->
                "<div id=\"host\">"
                <> slot(
                  component.static(fn(_) { "<input id=\"late-field\" />" })
                  |> component.scoped("#late-field")
                  |> event.on(
                    event: event.input,
                    handler: SetName,
                    options: event.options(),
                  ),
                )
                <> "</div>"
            }
          },
        )
      },
    )
  // Force the re-render that first renders the scoped field.
  client.dispatch(runtime)(Increment)
  test_support.input_event("#late-field", "typed")
  client.get_current_model(runtime).name
  |> should.equal("typed")
}
