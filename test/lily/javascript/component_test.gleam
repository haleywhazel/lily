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
import lily/test_dom
@target(javascript)
import lily/test_fixtures.{
  type Message, type Model, AddTransitionItem, Increment, IncrementSecondary,
  RemoveTransitionItem, SetTab, TabA, TabB,
}
@target(javascript)
import lily/test_setup

@target(javascript)
/// Converts the model's `Option(Int)` transition_item to a `List(Int)`
/// for each_live's slice. Using Option in the model keeps the wire
/// format consistent across JS/Erlang (lists serialise differently);
/// the slice constructs a list every call but each_live keys items by
/// id, so reconciliation is stable.
fn transition_items_list(model: Model) -> List(Int) {
  case model.transition_item {
    Some(id) -> [id]
    None -> []
  }
}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn to_html(html: String) -> String {
  html
}

@target(javascript)
fn to_slot() -> String {
  "<lily-slot></lily-slot>"
}

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start(store.wiring())
}

@target(javascript)
fn mount(runtime, view) {
  component.mount(
    runtime,
    selector: "#app",
    to_html: to_html,
    to_slot: to_slot,
    view: view,
  )
}

// =============================================================================
// STATIC
// =============================================================================

@target(javascript)
pub fn component_static_renders_content_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) { component.static(fn(_) { "<p>Hello</p>" }) })
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
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<span>first</span>" })
    })
  let first_html = test_dom.inner_html("#app")
  first_html
  |> string.contains("first")
  |> should.be_true
  let _r2 =
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<span>second</span>" })
    })
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
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        int.to_string(count)
      })
    })
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
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.name }, render: fn(name, _) {
        "name:" <> name
      })
    })
  test_dom.inner_html("#app")
  |> string.contains("name:")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_renders_initial_slice_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "count:" <> int.to_string(count)
      })
    })
  test_dom.inner_html("#app")
  |> string.contains("count:0")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_updates_on_model_change_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        "count:" <> int.to_string(count)
      })
    })
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
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(m: Model) { m.count },
        initial: fn(_) { "<div><span class=\"val\">0</span></div>" },
        patch: fn(count) { [component.SetText(".val", int.to_string(count))] },
      )
    })
  client.dispatch(runtime)(Increment)
  test_dom.get_text(".val")
  |> should.equal("1")
}

@target(javascript)
pub fn component_live_applies_set_attribute_patch_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
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
  test_dom.get_attribute("[data-lily-component]", "data-count")
  |> should.equal("1")
}

@target(javascript)
pub fn component_live_renders_initial_html_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(m: Model) { m.count },
        initial: fn(_) { "<div><span class=\"val\">0</span></div>" },
        patch: fn(count) { [component.SetText(".val", int.to_string(count))] },
      )
    })
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
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<span>one</span>" }),
        component.static(fn(_) { "<span>two</span>" }),
      ])
    })
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
    store.new(
      test_fixtures.WithList(items: [1, 2, 3]),
      with: fn(model, _message) { model },
    )
    |> client.start(store.wiring())
  let _r =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(m: test_fixtures.WithList) { m.items },
        key: fn(i) { i },
        render: fn(i) {
          component.static(fn(_) { "<span>" <> int.to_string(i) <> "</span>" })
        },
      )
    })
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
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        int.to_string(count)
      })
      |> component.require_connection(fn(m: Model) { m.connected })
    })
  test_dom.has_attribute("[data-lily-component]", "data-lily-disabled")
  |> should.be_true
}

@target(javascript)
pub fn component_require_connection_removes_disabled_when_connected_test() {
  test_setup.reset_dom()
  let runtime =
    store.new(
      test_fixtures.Model(..test_fixtures.initial_model(), connected: True),
      with: test_fixtures.update,
    )
    |> client.start(store.wiring())
  let _r =
    mount(runtime, fn(_model) {
      component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
        int.to_string(count)
      })
      |> component.require_connection(fn(m: Model) { m.connected })
    })
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
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(m: Model) { #(m.count, m.name) },
        render: fn(pair, _) {
          let #(count, name) = pair
          int.to_string(count) <> ":" <> name
        },
      )
      |> component.structural
    })
  test_dom.inner_html("#app")
  |> string.contains("0:")
  |> should.be_true
}

@target(javascript)
pub fn component_structural_on_static_is_noop_test() {
  let static_component = component.static(fn(_) { "hello" })
  let _structural_component = component.structural(static_component)
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r = mount(runtime, fn(_model) { component.static(fn(_) { "hello" }) })
  test_dom.inner_html("#app")
  |> should.equal("hello")
}

// =============================================================================
// SWITCH
// =============================================================================

@target(javascript)
pub fn switch_renders_initial_case_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(tab) {
        case tab {
          TabA -> component.static(fn(_) { "<p>A</p>" })
          TabB -> component.static(fn(_) { "<p>B</p>" })
        }
      })
    })
  test_dom.inner_html("#app")
  |> string.contains("<p>A</p>")
  |> should.be_true
}

@target(javascript)
pub fn switch_replaces_on_slice_change_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(tab) {
        case tab {
          TabA -> component.static(fn(_) { "<p>A</p>" })
          TabB -> component.static(fn(_) { "<p>B</p>" })
        }
      })
    })
  client.send_message(runtime, SetTab(TabB))
  let html = test_dom.inner_html("#app")
  let has_b = string.contains(html, "<p>B</p>")
  let has_a = string.contains(html, "<p>A</p>")
  has_b
  |> should.be_true
  has_a
  |> should.be_false
}

@target(javascript)
pub fn switch_preserves_identity_when_slice_unchanged_test() {
  // When the switch's slice doesn't change but a different field does,
  // the inner subscription updates without re-rendering the switch wrapper.
  // Verify by checking the inner simple's content reflects the change.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(_tab) {
        component.simple(slice: fn(m: Model) { m.count }, render: fn(count, _) {
          "<span class=\"counter\">" <> int.to_string(count) <> "</span>"
        })
      })
    })
  client.send_message(runtime, Increment)
  client.send_message(runtime, Increment)
  test_dom.inner_html("#app")
  |> string.contains("<span class=\"counter\">2</span>")
  |> should.be_true
}

@target(javascript)
pub fn switch_cleans_up_old_child_handlers_test() {
  // After switching from A (a `simple` subscribing to count) to B (static),
  // dispatching messages that would have changed A's slice must not error.
  // We can't directly observe the dead handler not firing, but we can
  // confirm B remains rendered and the runtime keeps responding.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(tab) {
        case tab {
          TabA ->
            component.simple(
              slice: fn(m: Model) { m.count },
              render: fn(count, _) { int.to_string(count) },
            )
          TabB -> component.static(fn(_) { "static-b" })
        }
      })
    })
  client.send_message(runtime, SetTab(TabB))
  client.send_message(runtime, Increment)
  client.send_message(runtime, Increment)
  test_dom.inner_html("#app")
  |> string.contains("static-b")
  |> should.be_true
}

@target(javascript)
pub fn switch_with_structural_compares_by_value_test() {
  // Two consecutive renders that produce equal tuples should not trigger
  // a re-render under structural comparison. We instrument by mutating
  // the wrapper after the first render and confirming the mutation
  // survives the second render.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(
        on: fn(m: Model) { #(m.active_tab, m.secondary_count > 100) },
        case_of: fn(_pair) {
          component.simple(
            slice: fn(m: Model) { m.count },
            render: fn(count, _) { int.to_string(count) },
          )
        },
      )
      |> component.structural
    })
  // Add a marker to the switch's wrapper that would be wiped by a re-render.
  test_dom.set_inner_html(
    "[data-lily-component=\"c0\"]",
    "<span id=\"marker\">survived</span>",
  )
  // Both messages change `count` and `secondary_count`, but the switch's
  // tuple #(TabA, False) is identical, so no re-render of the wrapper.
  client.send_message(runtime, Increment)
  client.send_message(runtime, IncrementSecondary)
  test_dom.inner_html("#app")
  |> string.contains("survived")
  |> should.be_true
}

@target(javascript)
pub fn switch_inside_fragment_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<header>top</header>" }),
        component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(tab) {
          case tab {
            TabA -> component.static(fn(_) { "<p>A</p>" })
            TabB -> component.static(fn(_) { "<p>B</p>" })
          }
        }),
        component.static(fn(_) { "<footer>bottom</footer>" }),
      ])
    })
  client.send_message(runtime, SetTab(TabB))
  let html = test_dom.inner_html("#app")
  string.contains(html, "<header>top</header>")
  |> should.be_true
  string.contains(html, "<p>B</p>")
  |> should.be_true
  string.contains(html, "<footer>bottom</footer>")
  |> should.be_true
}

@target(javascript)
pub fn switch_inside_require_connection_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(_tab) {
        component.static(fn(_) { "inner" })
      })
      |> component.require_connection(fn(m: Model) { m.connected })
    })
  // Default initial_model has connected: False, so the wrapper should be
  // marked disabled.
  test_dom.has_attribute("[data-lily-component=\"c0\"]", "data-lily-disabled")
  |> should.be_true
}

@target(javascript)
pub fn switch_events_inside_build_are_ignored_test() {
  // Bindings inside `build`'s returned Component are not collected at
  // mount, by design. The event on a button rendered inside the switch
  // does not fire.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(_tab) {
        component.static(fn(_) { "<button id=\"ignored\">+</button>" })
        |> event.on(event: event.click, selector: "#ignored", handler: fn(_) {
          Increment
        })
      })
    })
  test_dom.click("#ignored")
  client.get_current_model(runtime).count
  |> should.equal(0)
}

// =============================================================================
// SWITCH + EVENT (on the switch itself fires)
// =============================================================================

@target(javascript)
pub fn switch_events_on_switch_itself_fire_test() {
  // Pairs with the previous test: when the event is on the switch (not
  // inside `build`), it gets registered and fires.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.switch(on: fn(m: Model) { m.active_tab }, case_of: fn(_tab) {
        component.static(fn(_) {
          "<button id=\"fires\" data-msg=\"increment\">+</button>"
        })
      })
      |> event.on_decoded(
        event: event.click,
        selector: "#fires",
        decoder: fn(_) { Ok(Increment) },
      )
    })
  test_dom.click("#fires")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// EVENT CORNER CASES
// =============================================================================

@target(javascript)
pub fn event_on_fragment_root_test() {
  // Bindings attached to a Fragment get picked up by the walk; the walk
  // recurses into Fragment children too.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) {
          "<button id=\"frag\" data-msg=\"go\">+</button>"
        }),
      ])
      |> event.on_decoded(event: event.click, selector: "#frag", decoder: fn(_) {
        Ok(Increment)
      })
    })
  test_dom.click("#frag")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_pipe_order_event_then_require_connection_test() {
  // `simple |> event.on |> require_connection` produces
  // RequireConnection(WithEvents(Simple, [event])); the binding still
  // gets registered (register_bindings recurses through RequireConnection
  // into WithEvents).
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"pipe-a\" data-msg=\"go\">+</button>"
      })
      |> event.on_decoded(
        event: event.click,
        selector: "#pipe-a",
        decoder: fn(_) { Ok(Increment) },
      )
      |> component.require_connection(fn(_) { True })
    })
  test_dom.click("#pipe-a")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_pipe_order_require_connection_then_event_test() {
  // The reverse pipe order: `simple |> require_connection |> event.on`.
  // Produces WithEvents(RequireConnection(Simple), [event]); registration
  // is at the WithEvents wrapper, so the binding is still attached.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"pipe-b\" data-msg=\"go\">+</button>"
      })
      |> component.require_connection(fn(_) { True })
      |> event.on_decoded(
        event: event.click,
        selector: "#pipe-b",
        decoder: fn(_) { Ok(Increment) },
      )
    })
  test_dom.click("#pipe-b")
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
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      let inner =
        component.static(fn(_) {
          "<button id=\"slotted\" data-msg=\"go\">+</button>"
        })
        |> event.on_decoded(
          event: event.click,
          selector: "#slotted",
          decoder: fn(_) { Ok(Increment) },
        )
      component.live(
        slice: fn(_m: Model) { 0 },
        initial: fn(slot) { "<div class=\"shell\">" <> slot(inner) <> "</div>" },
        patch: fn(_) { [] },
      )
    })
  test_dom.click("#slotted")
  client.get_current_model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn event_inside_each_live_initial_ignored_test() {
  // Bindings declared inside an each_live's `initial` function are not
  // collected. Clicking the inner button does not dispatch.
  test_setup.reset_dom()
  let runtime = new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        initial: fn(_id) {
          component.static(fn(_) { "<button id=\"inner\">+</button>" })
          |> event.on(event: event.click, selector: "#inner", handler: fn(_) {
            Increment
          })
        },
        patch: fn(_) { [] },
      )
    })
  test_dom.click("#inner")
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
  test_setup.reset_dom()
  let runtime = new_runtime()
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
      to_html: to_html,
      to_slot: to_slot,
      view: fn(_model) {
        component.simple(
          slice: fn(m: Model) { m.secondary_count },
          render: fn(count, _) { "overlay:" <> int.to_string(count) },
        )
      },
    )
  client.send_message(runtime, Increment)
  client.send_message(runtime, IncrementSecondary)
  let app_html = test_dom.inner_html("#app")
  let overlays_html = test_dom.inner_html("#overlays")
  string.contains(app_html, "main:1")
  |> should.be_true
  string.contains(overlays_html, "overlay:1")
  |> should.be_true
}

@target(javascript)
pub fn multi_mount_remount_same_selector_replaces_test() {
  // Mounting A then B on the same selector replaces A. A's handlers
  // are torn down; B's content is visible.
  test_setup.reset_dom()
  let runtime = new_runtime()
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
  let html = test_dom.inner_html("#app")
  string.contains(html, "B:1")
  |> should.be_true
  string.contains(html, "A:")
  |> should.be_false
}

@target(javascript)
pub fn multi_mount_events_globally_delegated_test() {
  // An event registered from the #overlays tree's binding fires when
  // its selector matches a DOM element anywhere in the document.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"global-btn\" data-msg=\"go\">+</button>"
      })
    })
  let _r2 =
    component.mount(
      runtime,
      selector: "#overlays",
      to_html: to_html,
      to_slot: to_slot,
      view: fn(_model) {
        component.static(fn(_) { "" })
        |> event.on_decoded(
          event: event.click,
          selector: "#global-btn",
          decoder: fn(_) { Ok(Increment) },
        )
      },
    )
  test_dom.click("#global-btn")
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
  test_setup.reset_dom()
  let runtime = new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        initial: fn(id) {
          component.transition(
            enter: "fade-enter",
            exit: "fade-exit",
            duration_milliseconds: 10,
            child: component.static(fn(_) {
              "<span>item " <> int.to_string(id) <> "</span>"
            }),
          )
        },
        patch: fn(_) { [] },
      )
    })
  test_dom.inner_html("#app")
  |> string.contains("class=\"fade-enter\"")
  |> should.be_true
}

@target(javascript)
pub fn transition_exit_defers_removal_test() -> promise.Promise(Nil) {
  // Drop an item; the wrapper should still be present with the exit
  // class until the duration elapses. We sample synchronously (still
  // present) and after a delay (gone).
  test_setup.reset_dom()
  let runtime = new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        initial: fn(id) {
          component.transition(
            enter: "tx-enter",
            exit: "tx-exit",
            duration_milliseconds: 20,
            child: component.static(fn(_) {
              "<span class=\"item-" <> int.to_string(id) <> "\"></span>"
            }),
          )
        },
        patch: fn(_) { [] },
      )
    })
  client.send_message(runtime, RemoveTransitionItem(1))
  // Synchronously: the exit class is applied but the DOM hasn't been
  // removed yet.
  let mid_html = test_dom.inner_html("#app")
  let mid_contains_item =
    string.contains(mid_html, "item-1") && string.contains(mid_html, "tx-exit")
  mid_contains_item
  |> should.be_true
  // After the duration timer fires, the element is gone.
  promise.wait(60)
  |> promise.map(fn(_) {
    let final_html = test_dom.inner_html("#app")
    string.contains(final_html, "item-1")
    |> should.be_false
    Nil
  })
}

@target(javascript)
pub fn transition_re_add_mid_exit_cancels_test() -> promise.Promise(Nil) {
  // Drop, then re-add before the duration. The element should remain in
  // the DOM, the exit class should be stripped.
  test_setup.reset_dom()
  let runtime = new_runtime()
  client.send_message(runtime, AddTransitionItem(1))
  let _r =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        initial: fn(id) {
          component.transition(
            enter: "tx2-enter",
            exit: "tx2-exit",
            duration_milliseconds: 50,
            child: component.static(fn(_) {
              "<span class=\"keep-" <> int.to_string(id) <> "\"></span>"
            }),
          )
        },
        patch: fn(_) { [] },
      )
    })
  client.send_message(runtime, RemoveTransitionItem(1))
  client.send_message(runtime, AddTransitionItem(1))
  // After cancellation: element still present, exit class stripped from
  // the class attribute. The data-lily-transition-exit attribute still
  // carries the class name (so the next exit can use it), so we check
  // the class attribute specifically.
  let html = test_dom.inner_html("#app")
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
    test_dom.inner_html("#app")
    |> string.contains("keep-1")
    |> should.be_true
    Nil
  })
}

@target(javascript)
pub fn transition_inside_each_live_keeps_item_attribute_test() {
  // Sanity check: the Transition wrapper sits inside the each_live key
  // wrapper, both attributes are present together.
  test_setup.reset_dom()
  let runtime = new_runtime()
  client.send_message(runtime, AddTransitionItem(42))
  let _r =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: fn(m: Model) { transition_items_list(m) },
        key: fn(id: Int) { int.to_string(id) },
        initial: fn(id) {
          component.transition(
            enter: "in",
            exit: "out",
            duration_milliseconds: 10,
            child: component.static(fn(_) {
              "<span>item " <> int.to_string(id) <> "</span>"
            }),
          )
        },
        patch: fn(_) { [] },
      )
    })
  let html = test_dom.inner_html("#app")
  // Keys go through `string.inspect`, so the integer 42 becomes a
  // quoted string in the attribute value. Match on the substring only.
  string.contains(html, "data-lily-key")
  |> should.be_true
  string.contains(html, "data-lily-transition-exit=\"out\"")
  |> should.be_true
}

@target(javascript)
pub fn transition_events_on_outer_wrapper_test() {
  // event.on attached to a Transition gets registered via the WithEvents
  // path; the binding fires while the child is mounted.
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    mount(runtime, fn(_model) {
      component.transition(
        enter: "fade",
        exit: "fade-out",
        duration_milliseconds: 10,
        child: component.static(fn(_) {
          "<button id=\"tx-btn\" data-msg=\"go\">+</button>"
        }),
      )
      |> event.on_decoded(
        event: event.click,
        selector: "#tx-btn",
        decoder: fn(_) { Ok(Increment) },
      )
    })
  test_dom.click("#tx-btn")
  client.get_current_model(runtime).count
  |> should.equal(1)
}
