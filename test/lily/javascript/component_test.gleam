// Tests for lily/component, DOM rendering.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/int
@target(javascript)
import gleam/javascript/promise
@target(javascript)
import gleam/option.{None, Some}
@target(javascript)
import gleam/string
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/component
@target(javascript)
import lily/event
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{
  type Model, AddTransitionItem, Increment, IncrementSecondary,
  RemoveTransitionItem, SetTab, TabA, TabB,
}
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn mount(runtime, view) {
  component.mount(
    runtime,
    selector: "#app",
    to_html: test_support.to_html,
    to_slot: test_support.to_slot,
    view: view,
  )
}

@target(javascript)
/// Converts the model's `Option(Int)` transition_item to a `List(Int)`
/// for each's slice. Using Option in the model keeps the wire
/// format consistent across JS/Erlang (lists serialise differently);
/// the slice constructs a list every call but each keys items by
/// id, so reconciliation is stable.
fn transition_items_list(model: Model) -> List(Int) {
  case model.transition_item {
    Some(id) -> [id]
    None -> []
  }
}

// =============================================================================
// STATIC
// =============================================================================

@target(javascript)
pub fn component_static_renders_content_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) { component.static(fn(_) { "<p>Hello</p>" }) })
  test_support.inner_html("#app")
  |> string.contains("Hello")
  |> should.be_true
}

// =============================================================================
// MOUNT
// =============================================================================

@target(javascript)
pub fn component_mount_clears_previous_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<span>first</span>" })
    })
  let first_html = test_support.inner_html("#app")
  first_html
  |> string.contains("first")
  |> should.be_true
  let _r2 =
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<span>second</span>" })
    })
  let second_html = test_support.inner_html("#app")
  second_html
  |> string.contains("second")
  |> should.be_true
}

@target(javascript)
pub fn component_mount_renders_to_dom_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        int.to_string(count)
      })
    })
  test_support.inner_html("#app")
  |> should.not_equal("")
}

// =============================================================================
// SIMPLE
// =============================================================================

@target(javascript)
pub fn component_simple_name_renders_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.name }, render: fn(name, _) {
        "name:" <> name
      })
    })
  test_support.inner_html("#app")
  |> string.contains("name:")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_renders_initial_slice_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "count:" <> int.to_string(count)
      })
    })
  test_support.inner_html("#app")
  |> string.contains("count:0")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_updates_on_model_change_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "count:" <> int.to_string(count)
      })
    })
  client.dispatch(runtime)(Increment)
  test_support.inner_html("#app")
  |> string.contains("count:1")
  |> should.be_true
}

// =============================================================================
// MORPH (simple preserves nodes across re-render)
// =============================================================================

@target(javascript)
pub fn component_simple_morph_keeps_focus_across_rerender_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "<input id=\"field\"><span>" <> int.to_string(count) <> "</span>"
      })
    })
  test_support.focus("#field")

  // Re-render the parent by changing its slice; morph must leave the input node
  // untouched so focus survives (innerHTML would drop it).
  client.dispatch(runtime)(Increment)

  test_support.active_element_id()
  |> should.equal("field")
}

@target(javascript)
pub fn component_simple_morph_preserves_nested_live_child_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  // A nested live child on a different slice (name) than the ancestor (count).
  let child =
    component.live(
      slice: fn(m: Model) { m.name },
      initial: fn(_) { "<input id=\"pill\">" },
      patch: fn(_) { [] },
    )
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { m.count },
        render: fn(_count, slot) { "<div>" <> slot(child) <> "</div>" },
      )
    })
  test_support.focus("#pill")

  // Re-render the ancestor (count changed, the child's slice did not). Morph
  // keeps the nested child's node, so focus inside it survives, this is the
  // pill-slide case where innerHTML would recreate the node and reset it.
  client.dispatch(runtime)(Increment)

  test_support.active_element_id()
  |> should.equal("pill")
}

@target(javascript)
pub fn component_simple_morph_defers_exit_transition_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { m.transition_item },
        render: fn(item, slot) {
          case item {
            Some(_) ->
              slot(
                component.static(fn(_) { "<div id=\"panel\">p</div>" })
                |> component.transition(
                  enter: "in",
                  exit: "out",
                  duration_milliseconds: 200,
                ),
              )
            None -> ""
          }
        },
      )
    })
  client.dispatch(runtime)(AddTransitionItem(1))
  test_support.inner_html("#app")
  |> string.contains("panel")
  |> should.be_true

  // Closing removes the slot. Morph must defer the removal through the exit
  // transition, so the panel is still in the DOM immediately after (mid-exit),
  // not dropped synchronously.
  client.dispatch(runtime)(RemoveTransitionItem(1))
  test_support.inner_html("#app")
  |> string.contains("panel")
  |> should.be_true
}

// =============================================================================
// LIVE
// =============================================================================

@target(javascript)
pub fn component_live_renders_initial_html_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(m: Model) { m.count },
        initial: fn(_) { "<div><span class=\"val\">0</span></div>" },
        patch: fn(count) { [component.SetText(".val", int.to_string(count))] },
      )
    })
  test_support.inner_html("#app")
  |> string.contains("val")
  |> should.be_true
}

@target(javascript)
pub fn component_live_applies_patches_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(m: Model) { m.count },
        initial: fn(_) { "<div><span class=\"val\">0</span></div>" },
        patch: fn(count) { [component.SetText(".val", int.to_string(count))] },
      )
    })
  client.dispatch(runtime)(Increment)
  test_support.get_text(".val")
  |> should.equal("1")
}

@target(javascript)
pub fn component_live_applies_set_attribute_patch_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(m: Model) { m.count },
        initial: fn(_) { "<div class=\"box\"></div>" },
        patch: fn(count) {
          [component.SetAttribute("", "data-count", int.to_string(count))]
        },
      )
    })
  client.dispatch(runtime)(Increment)
  test_support.get_attribute("[data-lily-component]", "data-count")
  |> should.equal("1")
}

@target(javascript)
pub fn component_live_refuses_unsafe_attribute_patch_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(m: Model) { m.count },
        initial: fn(_) { "<div class=\"box\"></div>" },
        patch: fn(_count) {
          [
            component.SetAttribute("", "onclick", "alert(1)"),
            component.SetAttribute("", "href", "javascript:alert(1)"),
            component.SetAttribute("", "data-safe", "ok"),
          ]
        },
      )
    })
  client.dispatch(runtime)(Increment)
  // The event-handler name and the script-URL are both refused.
  test_support.get_attribute("[data-lily-component]", "onclick")
  |> should.equal("")
  test_support.get_attribute("[data-lily-component]", "href")
  |> should.equal("")
  // An ordinary data attribute still goes through.
  test_support.get_attribute("[data-lily-component]", "data-safe")
  |> should.equal("ok")
}

@target(javascript)
pub fn live_root_keeps_nested_children_reactive_test() {
  // The generated app's nesting: a live root (tone) -> static body ->
  // simple (navbar, constant slice) -> static (nav actions) ->
  // simple reading a changing field (connection). The innermost simple must
  // update when its field changes even though no ancestor re-renders.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let inner = fn() {
    component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
      "count:" <> int.to_string(count)
    })
  }
  let nav_actions = fn() {
    component.static(fn(slot) {
      "<div class=\"actions\">" <> slot(inner()) <> "</div>"
    })
  }
  let navbar = fn() {
    component.simple(slice: fn(_m: Model) { "const" }, render: fn(_, slot) {
      "<nav>" <> slot(nav_actions()) <> "</nav>"
    })
  }
  let body = fn() {
    component.static(fn(slot) { "<main>" <> slot(navbar()) <> "</main>" })
  }
  let _r =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(_m: Model) { "system" },
        initial: fn(slot) { "<div class=\"root\">" <> slot(body()) <> "</div>" },
        patch: fn(_) { [] },
      )
    })
  test_support.inner_html("#app")
  |> string.contains("count:0")
  |> should.be_true
  client.dispatch(runtime)(Increment)
  test_support.inner_html("#app")
  |> string.contains("count:1")
  |> should.be_true
}

// =============================================================================
// FRAGMENT
// =============================================================================

@target(javascript)
pub fn component_fragment_renders_children_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<span>one</span>" }),
        component.static(fn(_) { "<span>two</span>" }),
      ])
    })
  let html = test_support.inner_html("#app")
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
  test_support.reset_dom()
  let runtime =
    store.new(
      test_support.WithList(items: [1, 2, 3]),
      with: fn(model, _message) { model },
    )
    |> client.start(store.wiring(), serialiser: transport.automatic())
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: test_support.WithList) { m.items },
        key: fn(i) { i },
        render: fn(i) {
          component.static(fn(_) { "<span>" <> int.to_string(i) <> "</span>" })
        },
      )
    })
  let html = test_support.inner_html("#app")
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
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        int.to_string(count)
      })
      |> component.require_connection(fn(m: Model) { m.connected })
    })
  test_support.has_attribute("[data-lily-component]", "data-lily-disabled")
  |> should.be_true
}

@target(javascript)
pub fn component_require_connection_removes_disabled_when_connected_test() {
  test_support.reset_dom()
  let runtime =
    store.new(
      test_support.Model(..test_support.initial_model(), connected: True),
      with: test_support.update,
    )
    |> client.start(
      store.wiring(),
      serialiser: test_support.custom_serialiser(),
    )
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        int.to_string(count)
      })
      |> component.require_connection(fn(m: Model) { m.connected })
    })
  test_support.has_attribute("[data-lily-component]", "data-lily-disabled")
  |> should.be_false
}

// =============================================================================
// STRUCTURAL COMPARISON
// =============================================================================

@target(javascript)
pub fn component_simple_tuple_slice_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { #(m.count, m.name) },
        render: fn(pair, _) {
          let #(count, name) = pair
          int.to_string(count) <> ":" <> name
        },
      )
    })
  test_support.inner_html("#app")
  |> string.contains("0:")
  |> should.be_true
}

// =============================================================================
// SIMPLE SWITCHING (migrated from the removed `switch` builder)
// =============================================================================

@target(javascript)
pub fn simple_switch_renders_initial_case_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.active_tab }, render: fn(tab, _) {
        case tab {
          TabA -> "<p>A</p>"
          TabB -> "<p>B</p>"
        }
      })
    })
  test_support.inner_html("#app")
  |> string.contains("<p>A</p>")
  |> should.be_true
}

@target(javascript)
pub fn simple_switch_replaces_on_slice_change_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.active_tab }, render: fn(tab, _) {
        case tab {
          TabA -> "<p>A</p>"
          TabB -> "<p>B</p>"
        }
      })
    })
  client.send_message(runtime, SetTab(TabB))
  let html = test_support.inner_html("#app")
  let has_b = string.contains(html, "<p>B</p>")
  let has_a = string.contains(html, "<p>A</p>")
  has_b
  |> should.be_true
  has_a
  |> should.be_false
}

@target(javascript)
pub fn focus_on_mount_seeds_slotted_child_on_open_test() {
  // Mirrors an overlay opening: a slotted child gated behind a slice, carrying
  // focus_on_mount, must grab focus when it renders in (the select's flow).
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { m.active_tab },
        render: fn(tab, slot) {
          case tab {
            TabA -> "<p>closed</p>"
            TabB ->
              slot(
                component.static(fn(_s) { "<button id=\"opt\">option</button>" })
                |> event.focus_on_mount("#opt")
                |> component.transition(
                  enter: "in",
                  exit: "out",
                  duration_milliseconds: 100,
                ),
              )
          }
        },
      )
    })
  client.send_message(runtime, SetTab(TabB))
  test_support.active_element_id()
  |> should.equal("opt")
}

@target(javascript)
pub fn simple_switch_preserves_identity_when_slice_unchanged_test() {
  // When the outer slice doesn't change but a different field does, the
  // nested component's own subscription updates without the outer re-running.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { m.active_tab },
        render: fn(_tab, slot) {
          slot(
            component.simple(
              slice: fn(m: Model) { m.count },
              render: fn(count, _) {
                "<span class=\"counter\">" <> int.to_string(count) <> "</span>"
              },
            ),
          )
        },
      )
    })
  client.send_message(runtime, Increment)
  client.send_message(runtime, Increment)
  test_support.inner_html("#app")
  |> string.contains("<span class=\"counter\">2</span>")
  |> should.be_true
}

@target(javascript)
pub fn simple_switch_cleans_up_old_child_handlers_test() {
  // After switching from A (a nested `simple` subscribing to count) to B
  // (plain text), dispatching messages that would have changed A's slice
  // must not error, and B remains rendered.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { m.active_tab },
        render: fn(tab, slot) {
          case tab {
            TabA ->
              slot(
                component.simple(
                  slice: fn(m: Model) { m.count },
                  render: fn(count, _) { int.to_string(count) },
                ),
              )
            TabB -> "static-b"
          }
        },
      )
    })
  client.send_message(runtime, SetTab(TabB))
  client.send_message(runtime, Increment)
  client.send_message(runtime, Increment)
  test_support.inner_html("#app")
  |> string.contains("static-b")
  |> should.be_true
}

@target(javascript)
pub fn simple_switch_with_structural_compares_by_value_test() {
  // Two consecutive renders that produce equal tuples should not trigger a
  // re-render under structural comparison. Instrument by mutating the wrapper
  // after the first render and confirming the mutation survives the second.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { #(m.active_tab, m.secondary_count > 100) },
        render: fn(_pair, slot) {
          slot(
            component.simple(
              slice: fn(m: Model) { m.count },
              render: fn(count, _) { int.to_string(count) },
            ),
          )
        },
      )
    })
  // Add a marker to the wrapper that would be wiped by a re-render.
  test_support.set_inner_html(
    "[data-lily-component=\"c0\"]",
    "<span id=\"marker\">survived</span>",
  )
  // Both messages change `count` and `secondary_count`, but the outer slice
  // tuple #(TabA, False) is identical, so the outer never re-runs.
  client.send_message(runtime, Increment)
  client.send_message(runtime, IncrementSecondary)
  test_support.inner_html("#app")
  |> string.contains("survived")
  |> should.be_true
}

@target(javascript)
pub fn simple_switch_inside_fragment_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<header>top</header>" }),
        component.simple(
          slice: fn(m: Model) { m.active_tab },
          render: fn(tab, _) {
            case tab {
              TabA -> "<p>A</p>"
              TabB -> "<p>B</p>"
            }
          },
        ),
        component.static(fn(_) { "<footer>bottom</footer>" }),
      ])
    })
  client.send_message(runtime, SetTab(TabB))
  let html = test_support.inner_html("#app")
  string.contains(html, "<header>top</header>")
  |> should.be_true
  string.contains(html, "<p>B</p>")
  |> should.be_true
  string.contains(html, "<footer>bottom</footer>")
  |> should.be_true
}

@target(javascript)
pub fn simple_switch_inside_require_connection_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { m.active_tab },
        render: fn(_tab, _) { "inner" },
      )
      |> component.require_connection(fn(m: Model) { m.connected })
    })
  // Default initial_model has connected: False, so the connection wrapper
  // should be marked disabled. Select by the marker attribute itself rather
  // than a fixed component id, so the assertion survives id-allocation order.
  test_support.has_attribute("[data-lily-disabled]", "data-lily-disabled")
  |> should.be_true
}

// =============================================================================
// EVENT CORNER CASES
// =============================================================================

@target(javascript)
pub fn event_on_fragment_root_test() {
  // Bindings attached to a Fragment get picked up by the walk, the walk
  // recurses into Fragment children too.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) {
          "<button id=\"frag\" data-message=\"go\">+</button>"
        }),
      ])
      |> event.on_global_decoded(
        event: event.click,
        selector: "#frag",
        decoder: fn(_) { Ok(Increment) },
        options: event.options(),
      )
    })
  test_support.click("#frag")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_pipe_order_event_then_require_connection_test() {
  // `simple |> event.on |> require_connection` produces
  // RequireConnection(WithEvents(Simple, [event])), the binding still
  // gets registered (register_bindings recurses through RequireConnection
  // into WithEvents).
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"pipe-a\" data-message=\"go\">+</button>"
      })
      |> event.on_global_decoded(
        event: event.click,
        selector: "#pipe-a",
        decoder: fn(_) { Ok(Increment) },
        options: event.options(),
      )
      |> component.require_connection(fn(_) { True })
    })
  test_support.click("#pipe-a")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_pipe_order_require_connection_then_event_test() {
  // The reverse pipe order: `simple |> require_connection |> event.on`.
  // Produces WithEvents(RequireConnection(Simple), [event]), registration
  // is at the WithEvents wrapper, so the binding is still attached.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"pipe-b\" data-message=\"go\">+</button>"
      })
      |> component.require_connection(fn(_) { True })
      |> event.on_global_decoded(
        event: event.click,
        selector: "#pipe-b",
        decoder: fn(_) { Ok(Increment) },
        options: event.options(),
      )
    })
  test_support.click("#pipe-b")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_on_slot_child_of_live_test() {
  // Slot children rendered inside a `live` initial template are NOT
  // reachable from the Component tree by a Gleam-side walk (slot
  // children are collected via the slotter callback at render time,
  // not stored on the parent). The JS-side render queues their
  // bindings during renderComponent, so this should still register.
  // Mirrors the bundled welcome example's chat_area pattern.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      let inner =
        component.static(fn(_) {
          "<button id=\"slotted\" data-message=\"go\">+</button>"
        })
        |> event.on_global_decoded(
          event: event.click,
          selector: "#slotted",
          decoder: fn(_) { Ok(Increment) },
          options: event.options(),
        )
      component.live(
        slice: fn(_m: Model) { 0 },
        initial: fn(slot) { "<div class=\"shell\">" <> slot(inner) <> "</div>" },
        patch: fn(_) { [] },
      )
    })
  test_support.click("#slotted")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_inside_each_render_ignored_test() {
  // Bindings declared inside an each's `render` function are not
  // collected. Clicking the inner button does not dispatch.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(_id) {
          component.static(fn(_) { "<button id=\"inner\">+</button>" })
          |> event.on_global(
            event: event.click,
            selector: "#inner",
            handler: fn(_) { Increment },
            options: event.options(),
          )
        },
      )
    })
  test_support.click("#inner")
  client.get_current_model(runtime).count
  |> should.equal(0)
}

// =============================================================================
// MULTI-MOUNT
// =============================================================================

@target(javascript)
pub fn multi_mount_appends_handlers_test() {
  // Mount one tree at #app subscribing to count, another at #overlays
  // subscribing to secondary_count. Both update on dispatch.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "main:" <> int.to_string(count)
      })
    })
  let _r2 =
    component.mount(
      runtime,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_slot: test_support.to_slot,
      view: fn(_model) {
        component.simple(
          slice: fn(m: Model) { m.secondary_count },
          render: fn(count, _) { "overlay:" <> int.to_string(count) },
        )
      },
    )
  client.send_message(runtime, Increment)
  client.send_message(runtime, IncrementSecondary)
  let app_html = test_support.inner_html("#app")
  let overlays_html = test_support.inner_html("#overlays")
  string.contains(app_html, "main:1")
  |> should.be_true
  string.contains(overlays_html, "overlay:1")
  |> should.be_true
}

@target(javascript)
pub fn multi_mount_remount_same_selector_replaces_test() {
  // Mounting A then B on the same selector replaces A. A's handlers
  // are torn down, B's content is visible.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "A:" <> int.to_string(count)
      })
    })
  let _r2 =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "B:" <> int.to_string(count)
      })
    })
  client.send_message(runtime, Increment)
  let html = test_support.inner_html("#app")
  string.contains(html, "B:1")
  |> should.be_true
  string.contains(html, "A:")
  |> should.be_false
}

@target(javascript)
pub fn multi_mount_events_globally_delegated_test() {
  // An event registered from the #overlays tree's binding fires when
  // its selector matches a DOM element anywhere in the document.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"global-btn\" data-message=\"go\">+</button>"
      })
    })
  let _r2 =
    component.mount(
      runtime,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_slot: test_support.to_slot,
      view: fn(_model) {
        component.static(fn(_) { "" })
        |> event.on_global_decoded(
          event: event.click,
          selector: "#global-btn",
          decoder: fn(_) { Ok(Increment) },
          options: event.options(),
        )
      },
    )
  test_support.click("#global-btn")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// TRANSITION
// =============================================================================

@target(javascript)
pub fn transition_enter_class_applied_on_mount_test() {
  // Immediately after mount, the wrapper has the enter class. JSDOM
  // doesn't run rAF reliably, so we check the synchronous initial state
  // before the scheduled removal runs.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id) {
          component.static(fn(_) {
            "<span>item " <> int.to_string(id) <> "</span>"
          })
          |> component.transition(
            enter: "fade-enter",
            exit: "fade-exit",
            duration_milliseconds: 10,
          )
        },
      )
    })
  test_support.inner_html("#app")
  |> string.contains("class=\"fade-enter\"")
  |> should.be_true
}

@target(javascript)
pub fn transition_exit_defers_removal_test() -> promise.Promise(Nil) {
  // Drop an item, the wrapper should still be present with the exit
  // class until the duration elapses. We sample synchronously (still
  // present) and after a delay (gone).
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id) {
          component.static(fn(_) {
            "<span class=\"item-" <> int.to_string(id) <> "\"></span>"
          })
          |> component.transition(
            enter: "tx-enter",
            exit: "tx-exit",
            duration_milliseconds: 20,
          )
        },
      )
    })
  client.send_message(runtime, RemoveTransitionItem(1))
  // Synchronously: the exit class is applied but the DOM hasn't been
  // removed yet.
  let mid_html = test_support.inner_html("#app")
  let mid_contains_item =
    string.contains(mid_html, "item-1") && string.contains(mid_html, "tx-exit")
  mid_contains_item
  |> should.be_true
  // After the duration timer fires, the element is gone.
  promise.wait(60)
  |> promise.map(fn(_) {
    let final_html = test_support.inner_html("#app")
    string.contains(final_html, "item-1")
    |> should.be_false
    Nil
  })
}

@target(javascript)
pub fn transition_re_add_mid_exit_cancels_test() -> promise.Promise(Nil) {
  // Drop, then re-add before the duration. The element should remain in
  // the DOM, the exit class should be stripped.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id) {
          component.static(fn(_) {
            "<span class=\"keep-" <> int.to_string(id) <> "\"></span>"
          })
          |> component.transition(
            enter: "tx2-enter",
            exit: "tx2-exit",
            duration_milliseconds: 50,
          )
        },
      )
    })
  client.send_message(runtime, RemoveTransitionItem(1))
  client.send_message(runtime, AddTransitionItem(1))
  // After cancellation: element still present, exit class stripped from
  // the class attribute. The data-lily-transition-exit attribute still
  // carries the class name (so the next exit can use it), so we check
  // the class attribute specifically.
  let html = test_support.inner_html("#app")
  let still_present = string.contains(html, "keep-1")
  let no_exit_class = !string.contains(html, "class=\"tx2-exit\"")
  still_present
  |> should.be_true
  no_exit_class
  |> should.be_true
  // Wait past the original duration just to make sure the deferred
  // removal didn't fire after cancellation.
  promise.wait(80)
  |> promise.map(fn(_) {
    test_support.inner_html("#app")
    |> string.contains("keep-1")
    |> should.be_true
    Nil
  })
}

@target(javascript)
pub fn transition_inside_each_keeps_item_attribute_test() {
  // Sanity check: the Transition wrapper sits inside the each key
  // wrapper, both attributes are present together.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.send_message(runtime, AddTransitionItem(42))
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id) {
          component.static(fn(_) {
            "<span>item " <> int.to_string(id) <> "</span>"
          })
          |> component.transition(
            enter: "in",
            exit: "out",
            duration_milliseconds: 10,
          )
        },
      )
    })
  let html = test_support.inner_html("#app")
  // Keys go through `string.inspect`, so the integer 42 becomes a
  // quoted string in the attribute value. Match on the substring only.
  string.contains(html, "data-lily-key")
  |> should.be_true
  string.contains(html, "data-lily-transition-exit=\"out\"")
  |> should.be_true
}

@target(javascript)
pub fn transition_events_on_outer_wrapper_test() {
  // event.on attached to a transitioned component is registered as a
  // Listener decoration alongside the transition, the binding fires while
  // the child is mounted.
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"tx-btn\" data-message=\"go\">+</button>"
      })
      |> component.transition(
        enter: "fade",
        exit: "fade-out",
        duration_milliseconds: 10,
      )
      |> event.on_global_decoded(
        event: event.click,
        selector: "#tx-btn",
        decoder: fn(_) { Ok(Increment) },
        options: event.options(),
      )
    })
  test_support.click("#tx-btn")
  client.get_current_model(runtime).count
  |> should.equal(1)
}
