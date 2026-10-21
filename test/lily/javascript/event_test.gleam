// lily/event tests, scope, order, gates and typed helpers
// all @target(javascript), skipped on Erlang

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bool
@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/float
@target(javascript)
import gleam/int
@target(javascript)
import gleam/javascript/promise
@target(javascript)
import gleam/list
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
import lily/test_support.{type Message, Decrement, Increment, SetName}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
/// Every message the runtime applies, in order.
fn record(
  runtime: client.Runtime(test_support.Model, Message, store.Synced),
) -> test_support.Ref(List(Message)) {
  let messages = test_support.new([])
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.MessageApplied(message:, ..) ->
          test_support.set(messages, [message, ..test_support.get(messages)])
        _ -> Nil
      }
    })
  messages
}

@target(javascript)
fn seen(messages: test_support.Ref(List(Message))) -> List(Message) {
  list.reverse(test_support.get(messages))
}

@target(javascript)
fn setup() -> client.Runtime(test_support.Model, Message, store.Synced) {
  test_support.reset_dom()
  // a clicked data-lily-message decodes to a fixture type
  test_support.register_fixtures()
  test_support.new_runtime()
}

// =============================================================================
// SCOPE
// =============================================================================

@target(javascript)
pub fn event_a_listener_fires_for_events_inside_its_component_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<button id=\"inside\">x</button>",
    event.on_click(_, message: Increment),
  )

  test_support.click("#inside")

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_a_listener_ignores_events_outside_its_component_test() {
  let runtime = setup()
  let messages = record(runtime)
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_) {
        component.fragment([
          component.static(fn(_) { "<button id=\"mine\">x</button>" })
            |> event.on_click(message: Increment),
          component.static(fn(_) { "<button id=\"other\">x</button>" }),
        ])
      },
    )

  test_support.click("#other")
  seen(messages) |> should.equal([])

  test_support.click("#mine")
  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_a_selector_binds_to_elements_anywhere_test() {
  let runtime = setup()
  let messages = record(runtime)
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_) {
        component.fragment([
          component.static(fn(_) { "" })
            |> event.on_click(message: Increment)
            |> event.selector("#far"),
          component.static(fn(_) { "<button id=\"far\">x</button>" }),
        ])
      },
    )

  test_support.click("#far")

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_the_document_selector_hears_every_click_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<button id=\"anywhere\">x</button>",
    fn(component) {
      event.on_click(component, message: Decrement)
      |> event.selector("document")
    },
  )

  test_support.click("#anywhere")

  seen(messages) |> should.equal([Decrement])
}

@target(javascript)
pub fn event_a_component_with_only_selector_listeners_gets_no_wrapper_test() {
  let runtime = setup()
  test_support.mount_html(runtime, "<i id=\"bare\"></i>", fn(component) {
    event.on_click(component, message: Increment)
    |> event.selector("document")
  })

  test_support.inner_html("#app")
  |> string.contains("display: contents")
  |> should.be_false
}

@target(javascript)
pub fn event_a_single_root_static_marks_its_root_test() {
  let runtime = setup()
  test_support.mount_html(runtime, "<i id=\"bare\"></i>", event.on_click(
    _,
    message: Increment,
  ))

  test_support.inner_html("#app")
  |> string.contains("display: contents")
  |> should.be_false
  test_support.get_attribute("#bare", "data-lily-component")
  |> string.is_empty
  |> should.be_false
  test_support.click("#bare")
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn event_a_multi_root_static_keeps_the_wrapper_test() {
  let runtime = setup()
  test_support.mount_html(
    runtime,
    "<i id=\"first\"></i><i id=\"second\"></i>",
    event.on_click(_, message: Increment),
  )

  test_support.inner_html("#app")
  |> string.contains("style=\"display: contents\"")
  |> should.be_true
  test_support.click("#second")
  client.model(runtime).count |> should.equal(1)
}

// =============================================================================
// ORDER AND GATES
// =============================================================================

@target(javascript)
pub fn event_the_deepest_listener_runs_first_test() {
  let runtime = setup()
  let messages = record(runtime)
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_) {
        component.simple(slice: fn(_) { Nil }, render: fn(_, nest) {
          "<div>"
          <> nest(
            component.static(fn(_) { "<button id=\"deep\">x</button>" })
            |> event.on_click(message: Decrement),
          )
          <> "</div>"
        })
        |> event.on_click(message: Increment)
      },
    )

  test_support.click("#deep")

  seen(messages) |> should.equal([Decrement, Increment])
}

@target(javascript)
pub fn event_stop_propagation_ends_the_chain_test() {
  let runtime = setup()
  let messages = record(runtime)
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_) {
        component.simple(slice: fn(_) { Nil }, render: fn(_, nest) {
          "<div>"
          <> nest(
            component.static(fn(_) { "<button id=\"deep\">x</button>" })
            |> event.on_click(message: Decrement)
            |> event.stop_propagation,
          )
          <> "</div>"
        })
        |> event.on_click(message: Increment)
      },
    )

  test_support.click("#deep")

  seen(messages) |> should.equal([Decrement])
}

@target(javascript)
pub fn event_once_fires_only_the_first_event_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<button id=\"b\">x</button>", fn(component) {
    event.on_click(component, message: Increment)
    |> event.once
  })

  test_support.click("#b")
  test_support.click("#b")

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_prevent_default_cancels_the_event_test() {
  let runtime = setup()
  test_support.mount_html(
    runtime,
    "<a id=\"link\" href=\"/x\">x</a>",
    fn(component) {
      event.on_click(component, message: Increment)
      |> event.prevent_default
    },
  )

  test_support.click_prevented("#link") |> should.be_true
}

@target(javascript)
pub fn event_debounce_sends_one_message_with_the_last_value_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"search\" />", fn(component) {
    event.on_input(component, handler: SetName)
    |> event.debounce(milliseconds: 15)
  })

  test_support.input_event("#search", "a")
  test_support.input_event("#search", "ab")
  seen(messages) |> should.equal([])

  use _ <- promise.map(promise.wait(60))
  seen(messages) |> should.equal([SetName("ab")])
}

@target(javascript)
pub fn event_throttle_drops_events_inside_the_interval_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<button id=\"b\">x</button>", fn(component) {
    event.on_click(component, message: Increment)
    |> event.throttle(milliseconds: 1000)
  })

  test_support.click("#b")
  test_support.click("#b")

  seen(messages) |> should.equal([Increment])
}

// =============================================================================
// MODIFIERS
// =============================================================================

@target(javascript)
pub fn event_debounce_sends_again_after_a_pause_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"search\" />", fn(component) {
    event.on_input(component, handler: SetName)
    |> event.debounce(milliseconds: 10)
  })

  test_support.input_event("#search", "a")
  use _ <- promise.await(promise.wait(40))
  test_support.input_event("#search", "b")
  test_support.input_event("#search", "bc")

  use _ <- promise.map(promise.wait(40))
  seen(messages) |> should.equal([SetName("a"), SetName("bc")])
}

@target(javascript)
pub fn event_throttle_dispatches_again_after_the_interval_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<button id=\"b\">x</button>", fn(component) {
    event.on_click(component, message: Increment)
    |> event.throttle(milliseconds: 20)
  })

  test_support.click("#b")
  test_support.click("#b")
  use _ <- promise.map(promise.wait(40))
  test_support.click("#b")

  seen(messages) |> should.equal([Increment, Increment])
}

@target(javascript)
pub fn event_without_prevent_default_the_event_is_not_cancelled_test() {
  let runtime = setup()
  test_support.mount_html(
    runtime,
    "<button id=\"b\">x</button>",
    event.on_click(_, message: Increment),
  )

  test_support.click_prevented("#b") |> should.be_false
}

@target(javascript)
pub fn event_on_submit_prevents_the_submit_without_a_modifier_test() {
  let runtime = setup()
  test_support.mount_html(
    runtime,
    "<form id=\"form\"><input name=\"name\" value=\"Ada\" /></form>",
    event.on_submit(_, handler: fn(_) { Increment }),
  )

  test_support.submit_event("#form") |> should.be_true
}

@target(javascript)
pub fn event_once_still_prevents_a_later_submit_test() {
  let runtime = setup()
  test_support.mount_html(
    runtime,
    "<form id=\"form\"><input name=\"name\" value=\"Ada\" /></form>",
    fn(component) {
      event.on_submit(component, handler: fn(_) { Increment }) |> event.once
    },
  )

  test_support.submit_event("#form") |> should.be_true
  test_support.submit_event("#form") |> should.be_true
}

@target(javascript)
pub fn event_reset_form_resets_the_form_after_dispatching_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<form id=\"form\"><input id=\"name\" name=\"name\" value=\"Ada\" /></form>",
    fn(component) {
      event.on_submit(component, handler: fn(fields) {
        case fields {
          [#(_, value)] -> SetName(value)
          _ -> Decrement
        }
      })
      |> event.reset_form
    },
  )

  test_support.input_event("#name", "Grace")
  test_support.submit_event("#form") |> should.be_true

  seen(messages) |> should.equal([SetName("Grace")])
  test_support.get_value("#name") |> should.equal("Ada")
}

@target(javascript)
pub fn event_without_reset_form_the_form_keeps_its_values_test() {
  let runtime = setup()
  test_support.mount_html(
    runtime,
    "<form id=\"form\"><input id=\"name\" name=\"name\" value=\"Ada\" /></form>",
    event.on_submit(_, handler: fn(_) { Increment }),
  )

  test_support.input_event("#name", "Grace")
  test_support.submit_event("#form") |> should.be_true

  test_support.get_value("#name") |> should.equal("Grace")
}

@target(javascript)
pub fn event_selector_binds_to_matching_descendants_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<ul><li class=\"item\" data-card-id=\"7\"><span id=\"inner\">x</span></li>"
      <> "<li id=\"plain\">y</li></ul>",
    fn(component) {
      event.on(
        component,
        event: "click",
        decoder: event.data("card-id") |> decode.map(SetName),
      )
      |> event.selector(".item")
    },
  )

  test_support.click("#plain")
  test_support.click("#inner")

  seen(messages) |> should.equal([SetName("7")])
}

@target(javascript)
pub fn event_stop_propagation_stops_an_outer_selector_binding_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"outer\"><button id=\"inner\">x</button></div>",
    fn(component) {
      component
      |> event.on_click(message: Increment)
      |> event.selector("#outer")
      |> event.on_click(message: Decrement)
      |> event.selector("#inner")
      |> event.stop_propagation
    },
  )

  test_support.click("#inner")

  seen(messages) |> should.equal([Decrement])
}

@target(javascript)
pub fn event_a_modifier_changes_only_the_latest_listener_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<button id=\"b\">x</button>", fn(component) {
    component
    |> event.on_click(message: Increment)
    |> event.on_click(message: Decrement)
    |> event.once
  })

  test_support.click("#b")
  test_support.click("#b")

  seen(messages) |> should.equal([Increment, Decrement, Increment])
}

@target(javascript)
pub fn event_a_modifier_skips_a_transition_in_between_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<button id=\"b\">x</button>", fn(component) {
    component
    |> event.on_click(message: Increment)
    |> component.transition(enter: "fade-in", exit: "fade-out")
    |> component.duration(milliseconds: 10)
    |> event.once
  })

  test_support.click("#b")
  test_support.click("#b")

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_a_modifier_without_a_listener_does_nothing_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<button id=\"b\">x</button>", fn(component) {
    component
    |> event.once
    |> event.selector("#elsewhere")
    |> event.on_click(message: Increment)
  })

  test_support.click("#b")
  test_support.click("#b")

  seen(messages) |> should.equal([Increment, Increment])
}

// =============================================================================
// ISOLATION
// =============================================================================

@target(javascript)
pub fn event_two_runtimes_with_the_same_selector_both_hear_it_test() {
  test_support.reset_dom()
  let first = test_support.new_runtime()
  let second = test_support.new_runtime()
  let first_messages = record(first)
  let second_messages = record(second)
  let _ =
    component.mount(
      first,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_) {
        component.static(fn(_) { "<button id=\"shared\">x</button>" })
        |> event.on_click(message: Increment)
        |> event.selector("#shared")
      },
    )
  let _ =
    component.mount(
      second,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_) {
        component.static(fn(_) { "" })
        |> event.on_click(message: Decrement)
        |> event.selector("#shared")
      },
    )

  test_support.click("#shared")

  seen(first_messages) |> should.equal([Increment])
  seen(second_messages) |> should.equal([Decrement])
}

// =============================================================================
// TYPED HELPERS
// =============================================================================

@target(javascript)
pub fn event_on_input_reads_the_value_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"f\" />", event.on_input(
    _,
    handler: SetName,
  ))

  test_support.input_event("#f", "hello")

  seen(messages) |> should.equal([SetName("hello")])
}

@target(javascript)
pub fn event_on_change_reads_the_value_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"f\" />", event.on_change(
    _,
    handler: SetName,
  ))

  test_support.input_event("#f", "committed")

  seen(messages) |> should.equal([SetName("committed")])
}

@target(javascript)
pub fn event_on_check_reads_the_checked_state_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"box\" type=\"checkbox\" />",
    event.on_check(_, handler: fn(checked) {
      case checked {
        True -> Increment
        False -> Decrement
      }
    }),
  )

  test_support.check_event("#box", True)
  test_support.check_event("#box", False)

  seen(messages) |> should.equal([Increment, Decrement])
}

@target(javascript)
pub fn event_on_key_down_reads_the_key_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"f\" />",
    event.on_key_down(_, handler: fn(key: event.KeyEvent) {
      Ok(SetName(key.key))
    }),
  )

  test_support.key_event("#f", "keydown", "Enter")

  seen(messages) |> should.equal([SetName("Enter")])
}

@target(javascript)
fn search_shortcut(key: event.KeyEvent) -> Result(test_support.Message, Nil) {
  case key {
    event.KeyEvent(key: "k", meta: True, ..)
    | event.KeyEvent(key: "k", ctrl: True, ..) -> Ok(Increment)
    _ -> Error(Nil)
  }
}

@target(javascript)
pub fn event_on_key_down_skips_unhandled_keys_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"f\" />", fn(component) {
    event.on_key_down(component, handler: search_shortcut)
    |> event.selector("document")
  })

  test_support.key_event_prevented("#f", "keydown", "a", False, False)
  |> should.be_false
  test_support.key_event_prevented("#f", "keydown", "k", False, True)
  |> should.be_false

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_prevent_default_only_for_handled_keys_test() {
  let runtime = setup()
  test_support.mount_html(runtime, "<input id=\"f\" />", fn(component) {
    event.on_key_down(component, handler: search_shortcut)
    |> event.selector("document")
    |> event.prevent_default
  })

  test_support.key_event_prevented("#f", "keydown", "a", False, False)
  |> should.be_false
  test_support.key_event_prevented("#f", "keydown", "k", True, False)
  |> should.be_true
}

@target(javascript)
pub fn event_on_key_up_reads_the_key_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"f\" />",
    event.on_key_up(_, handler: fn(key: event.KeyEvent) { Ok(SetName(key.key)) }),
  )

  test_support.key_event("#f", "keyup", "a")

  seen(messages) |> should.equal([SetName("a")])
}

@target(javascript)
pub fn event_on_pointer_down_reads_the_pointer_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"pad\">x</div>",
    event.on_pointer_down(_, handler: fn(pointer: event.PointerEvent) {
      SetName(
        float.to_string(pointer.x)
        <> ","
        <> int.to_string(pointer.button)
        <> ","
        <> int.to_string(pointer.pointer_id)
        <> ","
        <> pointer.pointer_type,
      )
    }),
  )

  test_support.pointer_detail("#pad", "pointerdown", 2, "pen")

  seen(messages) |> should.equal([SetName("5.0,2,7,pen")])
}

@target(javascript)
pub fn event_on_submit_sends_the_fields_prevents_the_submit_and_can_reset_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<form id=\"form\"><input id=\"name\" name=\"name\" value=\"Ada\" />"
      <> "<input name=\"role\" value=\"admin\" /></form>",
    fn(component) {
      event.on_submit(component, handler: fn(fields) {
        SetName(string.join(
          list.map(fields, fn(pair) { pair.0 <> "=" <> pair.1 }),
          "&",
        ))
      })
      |> event.reset_form
    },
  )

  test_support.submit_event("#form") |> should.be_true

  seen(messages) |> should.equal([SetName("name=Ada&role=admin")])
}

@target(javascript)
pub fn event_on_focus_ignores_the_components_children_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"root\"><input id=\"top\" /></div>",
    event.on_focus(_, message: Increment),
  )

  // `focus` doesn't bubble, only the component's own element is heard
  test_support.fire_event("#root", "focus", False)
  seen(messages) |> should.equal([Increment])

  let runtime2 = setup()
  let messages2 = record(runtime2)
  test_support.mount_html(
    runtime2,
    "<div id=\"root\"><div id=\"mid\"><input id=\"deep\" /></div></div>",
    event.on_focus(_, message: Increment),
  )
  test_support.fire_event("#deep", "focus", False)
  seen(messages2) |> should.equal([])
}

@target(javascript)
pub fn event_on_focus_on_a_root_ignores_its_children_test() {
  // the root is the component's element, its child isn't
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"root\"><input id=\"child\" /></div>",
    event.on_focus(_, message: Increment),
  )

  test_support.fire_event("#child", "focus", False)
  seen(messages) |> should.equal([])
  test_support.fire_event("#root", "focus", False)
  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_focus_in_a_wrapper_hears_its_direct_children_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"first\" /><div><input id=\"nested\" /></div>",
    event.on_focus(_, message: Increment),
  )

  test_support.fire_event("#nested", "focus", False)
  seen(messages) |> should.equal([])
  test_support.fire_event("#first", "focus", False)
  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_message_dispatches_the_closest_data_message_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"row\" data-lily-message=\""
      <> event.encode_message(Increment)
      <> "\">"
      <> "<span id=\"label\">x</span></div>",
    event.on_message(_, event: "focusin"),
  )

  test_support.fire_event("#label", "focusin", True)

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_message_skips_a_target_without_one_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<span id=\"label\">x</span>",
    event.on_message(_, event: "focusin"),
  )

  test_support.fire_event("#label", "focusin", True)

  seen(messages) |> should.equal([])
}

@target(javascript)
pub fn event_on_key_down_reads_the_code_repeat_and_composing_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"f\" />",
    event.on_key_down(_, handler: fn(key: event.KeyEvent) {
      Ok(SetName(
        key.code
        <> ","
        <> bool.to_string(key.repeat)
        <> ","
        <> bool.to_string(key.is_composing),
      ))
    }),
  )

  test_support.key_detail("#f", "л", "KeyK", True, True)

  seen(messages) |> should.equal([SetName("KeyK,True,True")])
}

@target(javascript)
pub fn event_on_context_menu_can_replace_the_browser_menu_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<div id=\"pad\">x</div>", fn(component) {
    event.on_context_menu(component, handler: fn(pointer: event.PointerEvent) {
      SetName(int.to_string(pointer.button))
    })
    |> event.prevent_default
  })

  test_support.pointer_detail("#pad", "contextmenu", 2, "mouse")
  |> should.be_true
  seen(messages) |> should.equal([SetName("2")])
}

@target(javascript)
pub fn event_on_double_click_dispatches_its_message_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<p id=\"row\">x</p>", event.on_double_click(
    _,
    message: Increment,
  ))

  test_support.fire_event("#row", "dblclick", True)

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_focus_in_hears_focus_inside_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div><input id=\"inner\" /></div>",
    event.on_focus_in(_, message: Increment),
  )

  test_support.fire_event("#inner", "focusin", True)

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_copy_and_on_paste_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<p id=\"text\">x</p>", fn(component) {
    component
    |> event.on_copy(message: Increment)
    |> event.on_paste(handler: fn(transfer: event.DataTransfer) {
      SetName(transfer.text)
    })
  })

  test_support.transfer_event("#text", "copy", "") |> should.be_false
  test_support.transfer_event("#text", "paste", "pasted") |> should.be_false

  seen(messages) |> should.equal([Increment, SetName("pasted")])
}

@target(javascript)
pub fn event_on_drop_accepts_the_drop_and_reads_it_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"zone\">drop here</div>",
    event.on_drop(_, handler: fn(transfer: event.DataTransfer) {
      SetName(transfer.text)
    }),
  )

  test_support.transfer_event("#zone", "dragenter", "") |> should.be_true
  test_support.transfer_event("#zone", "dragover", "") |> should.be_true
  test_support.transfer_event("#zone", "drop", "card-1") |> should.be_true

  seen(messages) |> should.equal([SetName("card-1")])
}

@target(javascript)
pub fn event_on_files_reads_the_picked_files_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"upload\" type=\"file\" />",
    event.on_files(_, handler: fn(files: List(event.File)) {
      SetName(files |> list.map(fn(file) { file.name }) |> string.join(","))
    }),
  )

  test_support.set_files("#upload", ["a.txt", "b.txt"])

  seen(messages) |> should.equal([SetName("a.txt,b.txt")])
}

@target(javascript)
pub fn event_on_media_reads_the_players_state_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<video id=\"player\"></video>",
    event.on_media(_, event: "timeupdate", handler: fn(media: event.MediaState) {
      SetName(float.to_string(media.current_time))
    }),
  )

  test_support.media_event("#player", "timeupdate", 1.5)

  seen(messages) |> should.equal([SetName("1.5")])
}

@target(javascript)
pub fn event_on_pointer_enter_fires_for_its_own_element_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"card\">x</div>",
    event.on_pointer_enter(_, handler: fn(_pointer) { Increment }),
  )

  test_support.pointer_detail("#card", "pointerenter", 0, "mouse")

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_resize_reports_the_size_test() -> promise.Promise(Nil) {
  let runtime = setup()
  test_support.stub_observers()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<canvas id=\"chart\"></canvas>",
    event.on_resize(_, handler: fn(size) {
      let #(width, height) = size
      SetName(float.to_string(width) <> "x" <> float.to_string(height))
    }),
  )

  use _ <- promise.map(promise.wait(0))
  test_support.trigger_resize(200.0, 100.0)
  test_support.unstub_observers()
  seen(messages) |> should.equal([SetName("200.0x100.0")])
}

@target(javascript)
pub fn event_on_visible_reports_entering_and_leaving_test() -> promise.Promise(
  Nil,
) {
  let runtime = setup()
  test_support.stub_observers()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<p id=\"last-row\">loading</p>",
    event.on_visible(_, handler: fn(visible) {
      case visible {
        True -> Increment
        False -> Decrement
      }
    }),
  )

  use _ <- promise.map(promise.wait(0))
  test_support.trigger_visible(True)
  test_support.trigger_visible(False)
  test_support.unstub_observers()
  seen(messages) |> should.equal([Increment, Decrement])
}

@target(javascript)
pub fn event_fixed_message_binders_dispatch_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"field\" />", fn(component) {
    component
    |> event.on_blur(message: SetName("blur"))
    |> event.on_cut(message: SetName("cut"))
    |> event.on_drag_end(message: SetName("drag end"))
    |> event.on_drag_enter(message: SetName("drag enter"))
    |> event.on_drag_leave(message: SetName("drag leave"))
    |> event.on_drag_start(message: SetName("drag start"))
    |> event.on_focus_out(message: SetName("focus out"))
  })

  test_support.fire_event("#field", "blur", False)
  test_support.transfer_event("#field", "cut", "") |> should.be_false
  test_support.transfer_event("#field", "dragend", "") |> should.be_false
  test_support.transfer_event("#field", "dragenter", "") |> should.be_false
  test_support.transfer_event("#field", "dragleave", "") |> should.be_false
  test_support.transfer_event("#field", "dragstart", "") |> should.be_false
  test_support.fire_event("#field", "focusout", True)

  seen(messages)
  |> should.equal([
    SetName("blur"),
    SetName("cut"),
    SetName("drag end"),
    SetName("drag enter"),
    SetName("drag leave"),
    SetName("drag start"),
    SetName("focus out"),
  ])
}

@target(javascript)
pub fn event_on_drag_over_prevents_and_reads_the_pointer_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"zone\">x</div>",
    event.on_drag_over(_, handler: fn(pointer: event.PointerEvent) {
      SetName(pointer.pointer_type)
    }),
  )

  test_support.transfer_event("#zone", "dragover", "") |> should.be_true

  seen(messages) |> should.equal([SetName("mouse")])
}

@target(javascript)
pub fn event_pointer_move_up_and_leave_read_the_pointer_test() {
  let runtime = setup()
  let messages = record(runtime)
  let describe = fn(name) {
    fn(pointer: event.PointerEvent) {
      SetName(name <> ":" <> int.to_string(pointer.pointer_id))
    }
  }
  test_support.mount_html(runtime, "<div id=\"pad\">x</div>", fn(component) {
    component
    |> event.on_pointer_move(handler: describe("move"))
    |> event.on_pointer_up(handler: describe("up"))
    |> event.on_pointer_leave(handler: describe("leave"))
  })

  test_support.pointer_detail("#pad", "pointermove", 0, "touch")
  test_support.pointer_detail("#pad", "pointerup", 0, "touch")
  test_support.pointer_detail("#pad", "pointerleave", 0, "touch")

  seen(messages)
  |> should.equal([SetName("move:7"), SetName("up:7"), SetName("leave:7")])
}

@target(javascript)
pub fn event_on_scroll_reads_the_position_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"list\">x</div>",
    event.on_scroll(_, handler: fn(position) {
      let #(top, left) = position
      SetName(int.to_string(top) <> "," <> int.to_string(left))
    }),
  )

  test_support.scroll_to("#list", 40, 0)

  seen(messages) |> should.equal([SetName("40,0")])
}

@target(javascript)
pub fn event_on_wheel_reads_pixels_and_can_prevent_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<div id=\"map\">x</div>", fn(component) {
    event.on_wheel(component, handler: fn(wheel: event.WheelEvent) {
      SetName(float.to_string(wheel.delta_y))
    })
    |> event.prevent_default
  })

  // three lines
  test_support.wheel_event("#map", 3.0, 1) |> should.be_true

  seen(messages) |> should.equal([SetName("48.0")])
}

// =============================================================================
// ON AND THE DECODERS
// =============================================================================

@target(javascript)
pub fn event_on_reads_a_custom_event_with_a_decoder_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<div id=\"editor\">x</div>", event.on(
    _,
    event: "editor-change",
    decoder: decode.at(["detail", "value"], decode.string)
      |> decode.map(SetName),
  ))

  test_support.fire_custom_event("#editor", "editor-change", "text")

  seen(messages) |> should.equal([SetName("text")])
}

@target(javascript)
pub fn event_on_skips_an_event_it_cannot_decode_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<div id=\"editor\">x</div>", event.on(
    _,
    event: "editor-change",
    decoder: decode.at(["detail", "missing"], decode.string)
      |> decode.map(SetName),
  ))

  test_support.fire_custom_event("#editor", "editor-change", "text")

  seen(messages) |> should.equal([])
}

@target(javascript)
pub fn event_data_reads_an_attribute_of_the_matched_element_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<ul><li id=\"item\" data-card-id=\"7\">x</li></ul>",
    fn(component) {
      event.on(
        component,
        event: "click",
        decoder: event.data("card-id") |> decode.map(SetName),
      )
      |> event.selector("li")
    },
  )

  test_support.click("#item")

  seen(messages) |> should.equal([SetName("7")])
}

@target(javascript)
pub fn event_matched_runs_a_decoder_on_the_element_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<input id=\"f\" value=\"typed\" />",
    event.on(
      _,
      event: "input",
      decoder: event.matched(decode.at(["value"], decode.string))
        |> decode.map(SetName),
    ),
  )

  test_support.input_event("#f", "typed")

  seen(messages) |> should.equal([SetName("typed")])
}

@target(javascript)
pub fn event_form_fields_reads_the_form_around_the_target_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<form><input id=\"f\" name=\"q\" value=\"lily\" /></form>",
    event.on(
      _,
      event: "input",
      decoder: event.form_fields()
        |> decode.map(fn(fields) { SetName(string.inspect(fields)) }),
    ),
  )

  test_support.input_event("#f", "lily")

  seen(messages) |> should.equal([SetName("[#(\"q\", \"lily\")]")])
}

// =============================================================================
// DATA-MESSAGE CLICKS
// =============================================================================

@target(javascript)
pub fn event_a_data_message_click_dispatches_with_no_listener_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<button id=\"b\" data-lily-message=\""
      <> event.encode_message(SetName("hi"))
      <> "\"><span id=\"inner\">x</span></button>",
    fn(child) { child },
  )

  test_support.click("#inner")

  seen(messages) |> should.equal([SetName("hi")])
}

@target(javascript)
pub fn event_a_plain_data_message_is_ignored_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<button id=\"b\" data-lily-message=\"go\">x</button>",
    fn(child) { child },
  )

  test_support.click("#b")

  seen(messages) |> should.equal([])
}

@target(javascript)
pub fn event_mounting_twice_does_not_dispatch_a_click_twice_test() {
  let runtime = setup()
  let messages = record(runtime)
  let html =
    "<button id=\"b\" data-lily-message=\""
    <> event.encode_message(Increment)
    <> "\">x</button>"
  test_support.mount_html(runtime, html, fn(child) { child })
  test_support.mount_html(runtime, html, fn(child) { child })

  test_support.click("#b")

  seen(messages) |> should.equal([Increment])
}
