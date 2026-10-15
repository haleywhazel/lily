// lily/event tests, scope, order, gates and typed helpers
// all @target(javascript), skipped on Erlang

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/javascript/promise
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{Some}
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
  // a clicked data-message decodes to a fixture type
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
    event.on_click(_, message: Increment, options: event.defaults),
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
      to_slot: test_support.to_slot,
      view: fn(_) {
        component.fragment([
          component.static(fn(_) { "<button id=\"mine\">x</button>" })
            |> event.on_click(message: Increment, options: event.defaults),
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
      to_slot: test_support.to_slot,
      view: fn(_) {
        component.fragment([
          component.static(fn(_) { "" })
            |> event.on_click(
              message: Increment,
              options: test_support.on_selector("#far"),
            ),
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
    event.on_click(
      _,
      message: Decrement,
      options: test_support.on_selector("document"),
    ),
  )

  test_support.click("#anywhere")

  seen(messages) |> should.equal([Decrement])
}

@target(javascript)
pub fn event_a_component_with_only_selector_listeners_gets_no_wrapper_test() {
  let runtime = setup()
  test_support.mount_html(runtime, "<i id=\"bare\"></i>", event.on_click(
    _,
    message: Increment,
    options: test_support.on_selector("document"),
  ))

  test_support.inner_html("#app")
  |> string.contains("display: contents")
  |> should.be_false
}

@target(javascript)
pub fn event_a_scoped_listener_on_a_static_component_wraps_it_neutrally_test() {
  let runtime = setup()
  test_support.mount_html(runtime, "<i id=\"bare\"></i>", event.on_click(
    _,
    message: Increment,
    options: event.defaults,
  ))

  test_support.inner_html("#app")
  |> string.contains("style=\"display: contents\"")
  |> should.be_true
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
      to_slot: test_support.to_slot,
      view: fn(_) {
        component.simple(slice: fn(_) { Nil }, render: fn(_, slot) {
          "<div>"
          <> slot(
            component.static(fn(_) { "<button id=\"deep\">x</button>" })
            |> event.on_click(message: Decrement, options: event.defaults),
          )
          <> "</div>"
        })
        |> event.on_click(message: Increment, options: event.defaults)
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
      to_slot: test_support.to_slot,
      view: fn(_) {
        component.simple(slice: fn(_) { Nil }, render: fn(_, slot) {
          "<div>"
          <> slot(
            component.static(fn(_) { "<button id=\"deep\">x</button>" })
            |> event.on_click(
              message: Decrement,
              options: event.EventOptions(
                ..event.defaults,
                stop_propagation: True,
              ),
            ),
          )
          <> "</div>"
        })
        |> event.on_click(message: Increment, options: event.defaults)
      },
    )

  test_support.click("#deep")

  seen(messages) |> should.equal([Decrement])
}

@target(javascript)
pub fn event_once_fires_only_the_first_event_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<button id=\"b\">x</button>",
    event.on_click(
      _,
      message: Increment,
      options: event.EventOptions(..event.defaults, once: True),
    ),
  )

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
    event.on_click(
      _,
      message: Increment,
      options: event.EventOptions(..event.defaults, prevent_default: True),
    ),
  )

  test_support.click_prevented("#link") |> should.be_true
}

@target(javascript)
pub fn event_debounce_sends_one_message_with_the_last_value_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"search\" />", event.on_input(
    _,
    handler: SetName,
    options: event.EventOptions(
      ..event.defaults,
      debounce_milliseconds: Some(15),
    ),
  ))

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
  test_support.mount_html(
    runtime,
    "<button id=\"b\">x</button>",
    event.on_click(
      _,
      message: Increment,
      options: event.EventOptions(
        ..event.defaults,
        throttle_milliseconds: Some(1000),
      ),
    ),
  )

  test_support.click("#b")
  test_support.click("#b")

  seen(messages) |> should.equal([Increment])
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
      to_slot: test_support.to_slot,
      view: fn(_) {
        component.static(fn(_) { "<button id=\"shared\">x</button>" })
        |> event.on_click(
          message: Increment,
          options: test_support.on_selector("#shared"),
        )
      },
    )
  let _ =
    component.mount(
      second,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_slot: test_support.to_slot,
      view: fn(_) {
        component.static(fn(_) { "" })
        |> event.on_click(
          message: Decrement,
          options: test_support.on_selector("#shared"),
        )
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
    options: event.defaults,
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
    options: event.defaults,
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
    event.on_check(
      _,
      handler: fn(checked) {
        case checked {
          True -> Increment
          False -> Decrement
        }
      },
      options: event.defaults,
    ),
  )

  test_support.check_event("#box", True)
  test_support.check_event("#box", False)

  seen(messages) |> should.equal([Increment, Decrement])
}

@target(javascript)
pub fn event_on_key_down_reads_the_key_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"f\" />", event.on_key_down(
    _,
    handler: fn(key: event.KeyEvent) { SetName(key.key) },
    options: event.defaults,
  ))

  test_support.key_event("#f", "keydown", "Enter")

  seen(messages) |> should.equal([SetName("Enter")])
}

@target(javascript)
pub fn event_on_key_up_reads_the_key_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(runtime, "<input id=\"f\" />", event.on_key_up(
    _,
    handler: fn(key: event.KeyEvent) { SetName(key.key) },
    options: event.defaults,
  ))

  test_support.key_event("#f", "keyup", "a")

  seen(messages) |> should.equal([SetName("a")])
}

@target(javascript)
pub fn event_on_pointer_down_reads_the_position_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"pad\">x</div>",
    event.on_pointer_down(
      _,
      handler: fn(position) {
        let #(x_position, y_position) = position
        case x_position == 12.0 && y_position == 34.0 {
          True -> Increment
          False -> Decrement
        }
      },
      options: event.defaults,
    ),
  )

  test_support.mouse_event("#pad", "pointerdown", 12, 34)

  seen(messages) |> should.equal([Increment])
}

@target(javascript)
pub fn event_on_submit_sends_the_fields_prevents_the_submit_and_can_reset_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<form id=\"form\"><input id=\"name\" name=\"name\" value=\"Ada\" />"
      <> "<input name=\"role\" value=\"admin\" /></form>",
    event.on_submit(
      _,
      handler: fn(fields) {
        SetName(string.join(
          list.map(fields, fn(pair) { pair.0 <> "=" <> pair.1 }),
          "&",
        ))
      },
      options: event.EventOptions(..event.defaults, reset_form: True),
    ),
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
    event.on_focus(_, message: Increment, options: event.defaults),
  )

  // `focus` doesn't bubble, only the component's own element is heard
  test_support.fire_event("#root", "focus", False)
  seen(messages) |> should.equal([Increment])

  let runtime2 = setup()
  let messages2 = record(runtime2)
  test_support.mount_html(
    runtime2,
    "<div id=\"root\"><div id=\"mid\"><input id=\"deep\" /></div></div>",
    event.on_focus(_, message: Increment, options: event.defaults),
  )
  test_support.fire_event("#deep", "focus", False)
  seen(messages2) |> should.equal([])
}

@target(javascript)
pub fn event_on_message_dispatches_the_closest_data_message_test() {
  let runtime = setup()
  let messages = record(runtime)
  test_support.mount_html(
    runtime,
    "<div id=\"row\" data-message=\""
      <> event.encode_message(Increment)
      <> "\">"
      <> "<span id=\"label\">x</span></div>",
    event.on_message(_, event: "focusin", options: event.defaults),
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
    event.on_message(_, event: "focusin", options: event.defaults),
  )

  test_support.fire_event("#label", "focusin", True)

  seen(messages) |> should.equal([])
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
    options: event.defaults,
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
    options: event.defaults,
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
    event.on(
      _,
      event: "click",
      decoder: event.data("card-id") |> decode.map(SetName),
      options: test_support.on_selector("li"),
    ),
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
      options: event.defaults,
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
      options: event.defaults,
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
    "<button id=\"b\" data-message=\""
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
    "<button id=\"b\" data-message=\"go\">x</button>",
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
    "<button id=\"b\" data-message=\""
    <> event.encode_message(Increment)
    <> "\">x</button>"
  test_support.mount_html(runtime, html, fn(child) { child })
  test_support.mount_html(runtime, html, fn(child) { child })

  test_support.click("#b")

  seen(messages) |> should.equal([Increment])
}
