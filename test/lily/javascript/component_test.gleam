// lily/component tests, all @target(javascript), skipped on Erlang

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/int
@target(javascript)
import gleam/javascript/promise
@target(javascript)
import gleam/list
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
  type Model, AddTransitionItem, Decrement, Increment, IncrementSecondary,
  RemoveTransitionItem, SetName, SetTab, TabA, TabB,
}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn mount(
  runtime: client.Runtime(model, message, mode),
  view: fn(model) -> component.Component(model, message, String),
) -> client.Runtime(model, message, mode) {
  component.mount(
    runtime,
    selector: "#app",
    to_html: test_support.to_html,
    to_placeholder: test_support.to_placeholder,
    view: view,
  )
}

@target(javascript)
/// Option in the model, lists serialise differently on JS and Erlang.
fn transition_items_list(model: Model) -> List(Int) {
  case model.transition_item {
    Some(id) -> [id]
    None -> []
  }
}

@target(javascript)
/// Keyed by position, letting a row's text change under a stable key.
fn text_rows(model: Model) -> List(#(Int, String)) {
  case model.name {
    "" -> []
    names ->
      string.split(names, ",")
      |> list.index_map(fn(text, index) { #(index, text) })
  }
}

@target(javascript)
fn set_rows(
  runtime: client.Runtime(Model, message, mode),
  names: String,
) -> Nil {
  client.update_model(runtime, with: fn(model) {
    test_support.Model(..model, name: names)
  })
}

@target(javascript)
pub fn component_each_updates_a_changed_row_in_place_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b")
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, _) {
          "<input id=\"in-"
          <> int.to_string(row.0)
          <> "\" value=\"seed\"><span class=\"t\">"
          <> row.1
          <> "</span>"
        },
      )
    })
  test_support.input_event("#in-0", "typed")

  set_rows(runtime, "x,b")

  // the node survived the update, keeping what was typed into it
  test_support.get_value("#in-0") |> should.equal("typed")
  test_support.inner_html("#app")
  |> string.contains(">x</span>")
  |> should.be_true
}

@target(javascript)
pub fn component_each_skips_a_row_whose_record_is_unchanged_test() {
  test_support.reset_dom()
  let renders = test_support.new(0)
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b,c")
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, _) {
          test_support.set(renders, test_support.get(renders) + 1)
          "<i>" <> row.1 <> "</i>"
        },
      )
    })
  test_support.get(renders) |> should.equal(3)

  set_rows(runtime, "a,z,c")

  // only the middle row rendered again
  test_support.get(renders) |> should.equal(4)
}

@target(javascript)
pub fn component_each_live_patches_a_changed_row_instead_of_rendering_test() {
  test_support.reset_dom()
  let renders = test_support.new(0)
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b")
  let _ =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, _) {
          test_support.set(renders, test_support.get(renders) + 1)
          "<span class=\"t\">" <> row.1 <> "</span>"
        },
        patch: fn(row) { [component.SetText(".t", row.1)] },
      )
    })
  test_support.get(renders) |> should.equal(2)

  set_rows(runtime, "a,q")

  test_support.get(renders) |> should.equal(2)
  test_support.inner_html("#app")
  |> string.contains(">q</span>")
  |> should.be_true
  test_support.inner_html("#app")
  |> string.contains(">b</span>")
  |> should.be_false
}

@target(javascript)
pub fn component_each_row_nest_updates_on_its_own_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b")
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, nest) {
          "<p>"
          <> row.1
          <> nest(
            component.simple(
              slice: fn(model: Model) { model.count },
              render: fn(count, _) {
                "<b class=\"n\">" <> int.to_string(count) <> "</b>"
              },
            ),
          )
          <> "</p>"
        },
      )
    })

  // the row list is the same, only the model's count moved
  client.dispatch(runtime)(Increment)

  // each simple's lone root carries its id
  test_support.inner_html("#app")
  |> string.split("\">1</b>")
  |> list.length
  |> should.equal(3)
}

@target(javascript)
fn runtime_with_count(
  count: Int,
) -> client.Runtime(Model, test_support.Message, store.Standalone) {
  store.new(
    init: test_support.Model(..test_support.initial_model(), count:),
    update: test_support.update,
  )
  |> client.start
}

@target(javascript)
fn row_ids(model: Model) -> List(Int) {
  list.index_map(list.repeat(Nil, model.count), fn(_, index) { index })
}

@target(javascript)
fn row_view(_model: Model) -> component.Component(Model, message, String) {
  component.each(
    slice: row_ids,
    key: fn(id: Int) { int.to_string(id) },
    render: fn(id, nest) {
      nest(
        component.simple(slice: fn(_) { id }, render: fn(id, _nest) {
          "<span>" <> int.to_string(id) <> "</span>"
        }),
      )
    },
  )
}

// =============================================================================
// STATIC
// =============================================================================

@target(javascript)
pub fn component_static_renders_content_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) { component.static(fn(_) { "<p>Hello</p>" }) })

  test_support.inner_html("#app")
  |> string.contains("Hello")
  |> should.be_true
}

@target(javascript)
pub fn component_static_nested_simple_re_renders_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.static(fn(nest) {
        "<h1>Title</h1>"
        <> nest(
          component.simple(
            slice: fn(model: Model) { model.count },
            render: fn(count, _) {
              "<b class=\"n\">" <> int.to_string(count) <> "</b>"
            },
          ),
        )
      })
    })

  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Increment)

  test_support.get_text("b.n") |> should.equal("2")
  test_support.get_attribute("b.n", "data-lily-component")
  |> string.is_empty
  |> should.be_false
  test_support.inner_html("#app")
  |> string.contains("<h1>Title</h1>")
  |> should.be_true
}

// =============================================================================
// MOUNT
// =============================================================================

@target(javascript)
pub fn component_mount_clears_previous_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
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

// =============================================================================
// SIMPLE
// =============================================================================

@target(javascript)
pub fn component_simple_renders_initial_slice_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { "count:" <> int.to_string(count) },
      )
    })

  test_support.inner_html("#app")
  |> string.contains("count:0")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_updates_on_model_change_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { "count:" <> int.to_string(count) },
      )
    })
  client.dispatch(runtime)(Increment)

  test_support.inner_html("#app")
  |> string.contains("count:1")
  |> should.be_true
}

// =============================================================================
// MORPH
// =============================================================================

@target(javascript)
pub fn component_simple_morph_keeps_focus_across_rerender_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) {
          "<input id=\"field\"><span>" <> int.to_string(count) <> "</span>"
        },
      )
    })
  test_support.focus("#field")

  // parent re-renders, morph keeps the input so focus survives
  client.dispatch(runtime)(Increment)

  test_support.active_element_id()
  |> should.equal("field")
}

@target(javascript)
pub fn component_simple_morph_preserves_nested_live_child_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  // nested live child on name, ancestor on count
  let child =
    component.live(
      slice: fn(model: Model) { model.name },
      render: fn(_, _) { "<input id=\"pill\">" },
      patch: fn(_) { [] },
    )
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(_count, nest) { "<div>" <> nest(child) <> "</div>" },
      )
    })
  test_support.focus("#pill")

  // ancestor re-renders, morph keeps the child node (the pill-slide case)
  client.dispatch(runtime)(Increment)

  test_support.active_element_id()
  |> should.equal("pill")
}

@target(javascript)
pub fn component_simple_morph_defers_exit_transition_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.transition_item },
        render: fn(item, nest) {
          case item {
            Some(_) ->
              nest(
                component.static(fn(_) { "<div id=\"panel\">p</div>" })
                |> component.transition(enter: "in", exit: "out")
                |> component.duration(milliseconds: 200),
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

  // morph defers the removal through the exit, panel stays mid-exit
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
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.count },
        render: fn(_, _) { "<div><span class=\"val\">0</span></div>" },
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
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.count },
        render: fn(_, _) { "<div><span class=\"val\">0</span></div>" },
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
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.count },
        render: fn(_, _) { "<div class=\"box\"></div>" },
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
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.count },
        render: fn(_, _) { "<div class=\"box\"></div>" },
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

  // event-handler name and script url both refused
  test_support.get_attribute("[data-lily-component]", "onclick")
  |> should.equal("")
  test_support.get_attribute("[data-lily-component]", "href")
  |> should.equal("")
  // an ordinary data attribute still goes through
  test_support.get_attribute("[data-lily-component]", "data-safe")
  |> should.equal("ok")
}

@target(javascript)
pub fn component_live_refuses_patches_to_runtime_attributes_test() {
  // the patch reaches the component's own root, its marks must hold
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.count },
        render: fn(_, _) {
          "<div class=\"box\"><iframe></iframe><object></object></div>"
        },
        patch: fn(count) {
          [
            component.RemoveAttribute("", "data-lily-component"),
            component.SetAttribute("", "DATA-LILY-COMPONENT", "r0c99"),
            component.SetAttribute("", "data-lily-message", "forged"),
            component.SetAttribute("iframe", "srcdoc", "<script></script>"),
            component.SetAttribute("object", "data", " javascript:alert(1)"),
            component.SetAttribute("", "data-count", int.to_string(count)),
          ]
        },
      )
    })
  let id = test_support.get_attribute(".box", "data-lily-component")
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Increment)

  test_support.get_attribute(".box", "data-lily-component") |> should.equal(id)
  test_support.get_attribute(".box", "data-lily-message") |> should.equal("")
  test_support.get_attribute("iframe", "srcdoc") |> should.equal("")
  test_support.get_attribute("object", "data") |> should.equal("")
  // still found by its id, so still patched
  test_support.get_attribute(".box", "data-count") |> should.equal("2")
}

@target(javascript)
pub fn component_live_root_keeps_nested_children_reactive_test() {
  // generated app nesting, live > static > simple > static > simple
  // the innermost simple updates though no ancestor re-renders
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let inner = fn() {
    component.simple(
      slice: fn(model: Model) { model.count },
      render: fn(count, _) { "count:" <> int.to_string(count) },
    )
  }
  let nav_actions = fn() {
    component.static(fn(nest) {
      "<div class=\"actions\">" <> nest(inner()) <> "</div>"
    })
  }
  let navbar = fn() {
    component.simple(slice: fn(_model: Model) { "const" }, render: fn(_, nest) {
      "<nav>" <> nest(nav_actions()) <> "</nav>"
    })
  }
  let body = fn() {
    component.static(fn(nest) { "<main>" <> nest(navbar()) <> "</main>" })
  }
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(_model: Model) { "system" },
        render: fn(_, nest) {
          "<div class=\"root\">" <> nest(body()) <> "</div>"
        },
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
  let _runtime =
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
      init: test_support.WithList(items: [1, 2, 3]),
      update: fn(model, _message) { model },
    )
    |> client.start
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: test_support.WithList) { model.items },
        key: fn(item) { item },
        render: fn(item, _) { "<span>" <> int.to_string(item) <> "</span>" },
      )
    })
  let html = test_support.inner_html("#app")

  html
  |> string.contains("<span data-lily-key=\"1\">1</span>")
  |> should.be_true
  html
  |> string.contains("<div")
  |> should.be_false
}

@target(javascript)
pub fn component_each_rows_sit_directly_in_a_list_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b")
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(nest) {
        "<ul>"
        <> nest(
          component.each(
            slice: text_rows,
            key: fn(row: #(Int, String)) { row.0 },
            render: fn(row, _) { "<li>" <> row.1 <> "</li>" },
          ),
        )
        <> "</ul>"
      })
    })
  let html = test_support.inner_html("#app")

  html |> string.contains("<div") |> should.be_false
  html
  |> string.contains(
    "<li data-lily-key=\"0\">a</li><li data-lily-key=\"1\">b</li></ul>",
  )
  |> should.be_true
}

@target(javascript)
pub fn component_each_table_rows_stay_in_the_table_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b")
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(nest) {
        "<table><tbody>"
        <> nest(
          component.each(
            slice: text_rows,
            key: fn(row: #(Int, String)) { row.0 },
            render: fn(row, _) { "<tr><td>" <> row.1 <> "</td></tr>" },
          ),
        )
        <> "</tbody></table>"
      })
    })
  set_rows(runtime, "a,c")
  let html = test_support.inner_html("#app")

  html
  |> string.contains("<tr data-lily-key=\"1\"><td>c</td></tr></tbody>")
  |> should.be_true
}

@target(javascript)
pub fn component_each_row_with_several_roots_is_wrapped_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a")
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, _) { "<i>" <> row.1 <> "</i><i>!</i>" },
      )
    })

  test_support.inner_html("#app")
  |> string.contains(
    "<div style=\"display: contents\" data-lily-key=\"0\"><i>a</i><i>!</i></div>",
  )
  |> should.be_true
}

@target(javascript)
pub fn component_each_survives_its_parent_re_rendering_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a,b")
  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, nest) {
          "<p>"
          <> int.to_string(count)
          <> "</p><ul>"
          <> nest(
            component.each(
              slice: text_rows,
              key: fn(row: #(Int, String)) { row.0 },
              render: fn(row, _) { "<li>" <> row.1 <> "</li>" },
            ),
          )
          <> "</ul>"
        },
      )
    })
  client.dispatch(runtime)(Increment)
  set_rows(runtime, "a,b,c")
  let html = test_support.inner_html("#app")

  html |> string.contains("<p>1</p>") |> should.be_true
  html
  |> string.contains(
    "<li data-lily-key=\"0\">a</li><li data-lily-key=\"1\">b</li><li data-lily-key=\"2\">c</li></ul>",
  )
  |> should.be_true
}

@target(javascript)
pub fn component_each_live_patch_can_target_the_row_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a")
  let _ =
    mount(runtime, fn(_model) {
      component.each_live(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, _) { "<b class=\"n\">" <> row.1 <> "</b>" },
        patch: fn(row) { [component.SetText(target: ".n", value: row.1)] },
      )
    })
  set_rows(runtime, "z")

  test_support.inner_html("#app")
  |> string.contains("<b class=\"n\" data-lily-key=\"0\">z</b>")
  |> should.be_true
}

@target(javascript)
pub fn component_mount_renders_simple_once_test() {
  test_support.reset_dom()
  let renders = test_support.new(0)
  let runtime = test_support.new_runtime()

  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _nest) {
          test_support.set(renders, test_support.get(renders) + 1)
          "<p>" <> int.to_string(count) <> "</p>"
        },
      )
    })

  test_support.get(renders) |> should.equal(1)
}

@target(javascript)
pub fn component_mount_renders_live_once_and_patches_nothing_test() {
  test_support.reset_dom()
  let initials = test_support.new(0)
  let patches = test_support.new(0)
  let runtime = test_support.new_runtime()

  let _ =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.count },
        render: fn(_count, _nest) {
          test_support.set(initials, test_support.get(initials) + 1)
          "<p class=\"value\"></p>"
        },
        patch: fn(_count) {
          test_support.set(patches, test_support.get(patches) + 1)
          []
        },
      )
    })

  test_support.get(initials) |> should.equal(1)
  test_support.get(patches) |> should.equal(0)
}

@target(javascript)
pub fn component_each_creation_does_not_scan_the_page_per_row_test() {
  test_support.reset_dom()
  let few = runtime_with_count(20)
  let many = runtime_with_count(80)

  let #(few_queries, _) =
    test_support.count_dom_calls(fn() {
      let _ = mount(few, row_view)
      Nil
    })
  test_support.reset_dom()
  let #(many_queries, _) =
    test_support.count_dom_calls(fn() {
      let _ = mount(many, row_view)
      Nil
    })

  { many_queries <= few_queries + 2 } |> should.be_true
}

@target(javascript)
pub fn component_each_append_inserts_only_the_new_row_test() {
  test_support.reset_dom()
  let runtime = runtime_with_count(5)
  let _ = mount(runtime, row_view)

  let #(_, inserts) =
    test_support.count_dom_calls(fn() { client.dispatch(runtime)(Increment) })

  inserts |> should.equal(1)
  test_support.inner_html("#app")
  |> string.contains("\">5</span>")
  |> should.be_true
}

@target(javascript)
pub fn component_each_keeps_a_row_in_place_while_it_exits_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: transition_items_list,
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id, nest) {
          nest(
            component.static(fn(_) { "<b>row-" <> int.to_string(id) <> "</b>" })
            |> component.transition(enter: "tx-enter", exit: "tx-exit")
            |> component.duration(milliseconds: 200),
          )
        },
      )
    })

  client.dispatch(runtime)(RemoveTransitionItem(1))
  client.dispatch(runtime)(AddTransitionItem(2))

  let html = test_support.inner_html("#app")
  let assert Ok(#(before, _)) = string.split_once(html, "row-2")
  string.contains(before, "row-1") |> should.be_true
}

@target(javascript)
pub fn component_each_uses_a_string_key_as_it_is_test() {
  test_support.reset_dom()
  let runtime = runtime_with_count(2)

  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: row_ids,
        key: fn(id: Int) { "row-" <> int.to_string(id) },
        render: fn(id, _) { "<i>" <> int.to_string(id) <> "</i>" },
      )
    })

  let html = test_support.inner_html("#app")
  string.contains(html, "data-lily-key=\"row-0\"") |> should.be_true
  string.contains(html, "data-lily-key=\"row-1\"") |> should.be_true
}

@target(javascript)
pub fn component_simple_skips_a_rebuilt_slice_with_equal_fields_test() {
  test_support.reset_dom()
  let renders = test_support.new(0)
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { #(model.count, model.name) },
        render: fn(_slice, _nest) {
          test_support.set(renders, test_support.get(renders) + 1)
          "<p></p>"
        },
      )
    })

  // a fresh tuple holding equal fields, then one that really differs
  client.dispatch(runtime)(test_support.Noop)
  test_support.get(renders) |> should.equal(1)
  client.dispatch(runtime)(test_support.SetName("new"))
  test_support.get(renders) |> should.equal(2)
}

// =============================================================================
// STRUCTURAL COMPARISON
// =============================================================================

@target(javascript)
pub fn component_simple_tuple_slice_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { #(model.count, model.name) },
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
// SIMPLE SWITCHING
// =============================================================================

@target(javascript)
pub fn component_simple_switch_renders_initial_case_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.active_tab },
        render: fn(tab, _) {
          case tab {
            TabA -> "<p>A</p>"
            TabB -> "<p>B</p>"
          }
        },
      )
    })

  test_support.inner_html("#app")
  |> string.contains(">A</p>")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_switch_replaces_on_slice_change_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.active_tab },
        render: fn(tab, _) {
          case tab {
            TabA -> "<p>A</p>"
            TabB -> "<p>B</p>"
          }
        },
      )
    })
  client.dispatch(runtime)(SetTab(TabB))
  let html = test_support.inner_html("#app")
  let has_b = string.contains(html, ">B</p>")
  let has_a = string.contains(html, ">A</p>")

  has_b
  |> should.be_true
  has_a
  |> should.be_false
}

@target(javascript)
pub fn component_simple_switch_preserves_identity_when_slice_unchanged_test() {
  // outer slice unchanged, the nested subscription updates on its own
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.active_tab },
        render: fn(_tab, nest) {
          nest(
            component.simple(
              slice: fn(model: Model) { model.count },
              render: fn(count, _) {
                "<span class=\"counter\">" <> int.to_string(count) <> "</span>"
              },
            ),
          )
        },
      )
    })
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Increment)

  test_support.get_text("span.counter") |> should.equal("2")
}

@target(javascript)
pub fn component_simple_switch_cleans_up_old_child_handlers_test() {
  // after switching A to B, messages for A's stale slice must not error
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.active_tab },
        render: fn(tab, nest) {
          case tab {
            TabA ->
              nest(
                component.simple(
                  slice: fn(model: Model) { model.count },
                  render: fn(count, _) { int.to_string(count) },
                ),
              )
            TabB -> "static-b"
          }
        },
      )
    })
  client.dispatch(runtime)(SetTab(TabB))
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Increment)

  test_support.inner_html("#app")
  |> string.contains("static-b")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_switch_with_structural_compares_by_value_test() {
  // equal tuples skip the re-render, a wrapper mutation survives
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) {
          #(model.active_tab, model.secondary_count > 100)
        },
        render: fn(_pair, nest) {
          "<section>"
          <> nest(
            component.simple(
              slice: fn(model: Model) { model.count },
              render: fn(count, _) { int.to_string(count) },
            ),
          )
          <> "</section>"
        },
      )
    })
  // a re-render would wipe this marker
  test_support.set_inner_html(
    "#app > section",
    "<span id=\"marker\">survived</span>",
  )
  // outer slice #(TabA, False) stays equal, meaning the outer never re-runs
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(IncrementSecondary)

  test_support.inner_html("#app")
  |> string.contains("survived")
  |> should.be_true
}

@target(javascript)
pub fn component_simple_switch_inside_fragment_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<header>top</header>" }),
        component.simple(
          slice: fn(model: Model) { model.active_tab },
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
  client.dispatch(runtime)(SetTab(TabB))
  let html = test_support.inner_html("#app")

  string.contains(html, "<header>top</header>")
  |> should.be_true
  string.contains(html, ">B</p>")
  |> should.be_true
  string.contains(html, "<footer>bottom</footer>")
  |> should.be_true
}

// =============================================================================
// EVENT CORNER CASES
// =============================================================================

@target(javascript)
pub fn component_event_on_fragment_root_test() {
  // the walk recurses into Fragment children
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) {
          "<button id=\"frag\" data-lily-message=\"go\">+</button>"
        }),
      ])
      |> event.on_click(message: Increment)
      |> event.selector("#frag")
    })
  test_support.click("#frag")

  client.model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn component_event_on_nested_child_of_live_test() {
  // nested children aren't on the Gleam tree, renderComponent queues them
  // mirrors the welcome example's chat_area
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      let inner =
        component.static(fn(_) {
          "<button id=\"nested\" data-lily-message=\"go\">+</button>"
        })
        |> event.on_click(message: Increment)
        |> event.selector("#nested")
      component.live(
        slice: fn(_model: Model) { 0 },
        render: fn(_, nest) {
          "<div class=\"shell\">" <> nest(inner) <> "</div>"
        },
        patch: fn(_) { [] },
      )
    })
  test_support.click("#nested")

  client.model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn component_event_inside_each_row_fires_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(_id, nest) {
          nest(
            component.static(fn(_) { "<button id=\"inner\">+</button>" })
            |> event.on_click(message: Increment),
          )
        },
      )
    })
  test_support.click("#inner")

  client.model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn component_event_inside_each_row_registers_once_after_a_re_render_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a")
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, nest) {
          "<section>"
          <> row.1
          <> nest(
            component.static(fn(_) { "<button id=\"row-button\">+</button>" })
            |> event.on_click(message: Increment),
          )
          <> "</section>"
        },
      )
    })
  // same key, new text
  set_rows(runtime, "z")
  test_support.click("#row-button")

  client.model(runtime).count
  |> should.equal(1)
  test_support.inner_html("#app")
  |> string.contains("<section data-lily-key=\"0\">z<button")
  |> should.be_true
}

@target(javascript)
pub fn component_event_inside_a_removed_each_row_is_dropped_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a")
  let _runtime =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) {
          "<button class=\"go\" id=\"outside\">+</button>"
        }),
        component.each(
          slice: text_rows,
          key: fn(row: #(Int, String)) { row.0 },
          render: fn(_row, nest) {
            nest(
              component.static(fn(_) { "<i>row</i>" })
              |> event.on_click(message: Increment)
              |> event.selector(".go"),
            )
          },
        ),
      ])
    })
  test_support.click("#outside")
  set_rows(runtime, "")
  test_support.click("#outside")

  client.model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// MULTI-MOUNT
// =============================================================================

@target(javascript)
pub fn component_multi_mount_appends_handlers_test() {
  // #app on count, #overlays on secondary_count, both update
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { "main:" <> int.to_string(count) },
      )
    })
  let _r2 =
    component.mount(
      runtime,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_model) {
        component.simple(
          slice: fn(model: Model) { model.secondary_count },
          render: fn(count, _) { "overlay:" <> int.to_string(count) },
        )
      },
    )
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(IncrementSecondary)
  let app_html = test_support.inner_html("#app")
  let overlays_html = test_support.inner_html("#overlays")

  string.contains(app_html, "main:1")
  |> should.be_true
  string.contains(overlays_html, "overlay:1")
  |> should.be_true
}

@target(javascript)
pub fn component_multi_mount_remount_same_selector_replaces_test() {
  // B replaces A on the same selector, A's handlers torn down
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { "A:" <> int.to_string(count) },
      )
    })
  let _r2 =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { "B:" <> int.to_string(count) },
      )
    })
  client.dispatch(runtime)(Increment)
  let html = test_support.inner_html("#app")

  string.contains(html, "B:1")
  |> should.be_true
  string.contains(html, "A:")
  |> should.be_false
}

@target(javascript)
pub fn component_multi_mount_events_globally_delegated_test() {
  // an #overlays binding fires on a match anywhere in the document
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"global-btn\" data-lily-message=\"go\">+</button>"
      })
    })
  let _r2 =
    component.mount(
      runtime,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_model) {
        component.static(fn(_) { "" })
        |> event.on_click(message: Increment)
        |> event.selector("#global-btn")
      },
    )
  test_support.click("#global-btn")

  client.model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// TRANSITION
// =============================================================================

@target(javascript)
pub fn component_transition_enter_class_applied_on_mount_test() {
  // checked synchronously, JSDOM doesn't run rAF reliably
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id, nest) {
          nest(
            component.static(fn(_) {
              "<span>item " <> int.to_string(id) <> "</span>"
            })
            |> component.transition(enter: "fade-enter", exit: "fade-exit")
            |> component.duration(milliseconds: 10),
          )
        },
      )
    })

  test_support.inner_html("#app")
  |> string.contains("class=\"fade-enter\"")
  |> should.be_true
}

@target(javascript)
pub fn component_transition_exit_defers_removal_test() -> promise.Promise(Nil) {
  // wrapper stays with the exit class until the animation ends
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id, nest) {
          nest(
            component.static(fn(_) {
              "<span class=\"item-" <> int.to_string(id) <> "\"></span>"
            })
            |> component.transition(enter: "tx-enter", exit: "tx-exit")
            |> component.duration(milliseconds: 20),
          )
        },
      )
    })
  client.dispatch(runtime)(RemoveTransitionItem(1))
  // exit class applied, not yet removed
  let mid_html = test_support.inner_html("#app")
  let mid_contains_item =
    string.contains(mid_html, "item-1") && string.contains(mid_html, "tx-exit")

  mid_contains_item
  |> should.be_true
  promise.wait(150)
  |> promise.map(fn(_) {
    let final_html = test_support.inner_html("#app")
    string.contains(final_html, "item-1")
    |> should.be_false
    Nil
  })
}

@target(javascript)
pub fn component_transition_re_add_mid_exit_cancels_test() -> promise.Promise(
  Nil,
) {
  // re-added before the duration, stays with the exit class stripped
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id, nest) {
          nest(
            component.static(fn(_) {
              "<span class=\"keep-" <> int.to_string(id) <> "\"></span>"
            })
            |> component.transition(enter: "tx2-enter", exit: "tx2-exit")
            |> component.duration(milliseconds: 50),
          )
        },
      )
    })
  client.dispatch(runtime)(RemoveTransitionItem(1))
  client.dispatch(runtime)(AddTransitionItem(1))
  // the transition sits on the span itself, its class holds the state
  let html = test_support.inner_html("#app")

  test_support.get_attribute(".keep-1", "class") |> should.equal("keep-1")
  html |> string.contains("inert") |> should.be_false
  // past the original duration, the deferred removal must not fire
  promise.wait(80)
  |> promise.map(fn(_) {
    test_support.inner_html("#app")
    |> string.contains("keep-1")
    |> should.be_true
    Nil
  })
}

@target(javascript)
fn exiting_item_view(
  duration: fn(component.Component(Model, message, String)) ->
    component.Component(Model, message, String),
) -> fn(Model) -> component.Component(Model, message, String) {
  fn(_model) {
    component.each(
      slice: fn(model: Model) { transition_items_list(model) },
      key: fn(id: Int) { int.to_string(id) },
      render: fn(id, nest) {
        nest(
          component.static(fn(_) {
            "<span class=\"gone-" <> int.to_string(id) <> "\"></span>"
          })
          |> component.transition(enter: "tx3-enter", exit: "tx3-exit")
          |> duration,
        )
      },
    )
  }
}

@target(javascript)
pub fn component_transition_without_an_animation_removes_at_once_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime = mount(runtime, exiting_item_view(fn(component) { component }))
  client.dispatch(runtime)(RemoveTransitionItem(1))

  promise.wait(0)
  |> promise.map(fn(_) {
    test_support.inner_html("#app")
    |> string.contains("gone-1")
    |> should.be_false
    Nil
  })
}

@target(javascript)
fn animated_item_view(
  _model: Model,
) -> component.Component(Model, message, String) {
  component.each(
    slice: fn(model: Model) { transition_items_list(model) },
    key: fn(id: Int) { int.to_string(id) },
    render: fn(id, nest) {
      nest(
        // the animation runs inside the transition element
        component.static(fn(_) {
          "<div class=\"card\"><span class=\"panel\">"
          <> int.to_string(id)
          <> "</span></div>"
        })
        |> component.transition(enter: "tx5-enter", exit: "tx5-exit"),
      )
    },
  )
}

@target(javascript)
pub fn component_transition_waits_for_an_animation_inside_it_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  test_support.stub_animations("panel", 50)
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime = mount(runtime, animated_item_view)
  client.dispatch(runtime)(RemoveTransitionItem(1))

  use _ <- promise.await(promise.wait(20))
  test_support.inner_html("#app")
  |> string.contains("tx5-exit")
  |> should.be_true
  use _ <- promise.map(promise.wait(130))
  test_support.unstub_animations()
  test_support.inner_html("#app")
  |> string.contains("panel")
  |> should.be_false
}

@target(javascript)
pub fn component_transition_ignores_infinite_animations_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  test_support.stub_animations("nothing-matches", 50)
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime = mount(runtime, animated_item_view)
  client.dispatch(runtime)(RemoveTransitionItem(1))

  use _ <- promise.map(promise.wait(0))
  test_support.unstub_animations()
  test_support.inner_html("#app")
  |> string.contains("panel")
  |> should.be_false
}

@target(javascript)
pub fn component_transition_exit_drops_the_enter_class_test() {
  test_support.reset_dom()
  test_support.stub_animations("panel", 50)
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime = mount(runtime, animated_item_view)
  client.dispatch(runtime)(RemoveTransitionItem(1))
  let class = test_support.get_attribute(".card", "class")
  test_support.unstub_animations()

  class |> should.equal("card tx5-exit")
}

@target(javascript)
fn one_sided_view(
  enter: String,
  exit: String,
) -> fn(Model) -> component.Component(Model, message, String) {
  fn(_model) {
    component.each(
      slice: fn(model: Model) { transition_items_list(model) },
      key: fn(id: Int) { int.to_string(id) },
      render: fn(id, nest) {
        nest(
          component.static(fn(_) {
            "<span class=\"side\">" <> int.to_string(id) <> "</span>"
          })
          |> component.transition(enter:, exit:)
          |> component.duration(milliseconds: 50),
        )
      },
    )
  }
}

@target(javascript)
pub fn component_transition_exit_only_still_holds_removal_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime = mount(runtime, one_sided_view("", "side-out"))
  client.dispatch(runtime)(RemoveTransitionItem(1))

  test_support.inner_html("#app")
  |> string.contains("side-out")
  |> should.be_true
}

@target(javascript)
pub fn component_transition_enter_only_removes_at_once_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime = mount(runtime, one_sided_view("side-in", ""))
  client.dispatch(runtime)(RemoveTransitionItem(1))

  use _ <- promise.map(promise.wait(0))
  test_support.inner_html("#app")
  |> string.contains("side")
  |> should.be_false
}

@target(javascript)
pub fn component_transition_exiting_element_is_inert_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, exiting_item_view(component.duration(_, milliseconds: 50)))
  client.dispatch(runtime)(RemoveTransitionItem(1))
  let html = test_support.inner_html("#app")

  html |> string.contains("inert=\"\"") |> should.be_true
  html |> string.contains("aria-hidden=\"true\"") |> should.be_true
}

@target(javascript)
pub fn component_duration_sets_the_custom_property_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, exiting_item_view(component.duration(_, milliseconds: 400)))

  test_support.get_attribute(".gone-1", "style")
  |> should.equal("--lily-transition-duration: 400ms;")
}

@target(javascript)
pub fn component_transition_inside_each_keeps_item_attribute_test() {
  // the row root carries both the key and the transition
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(42))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { int.to_string(id) },
        render: fn(id, nest) {
          nest(
            component.static(fn(_) {
              "<span>item " <> int.to_string(id) <> "</span>"
            })
            |> component.transition(enter: "in", exit: "out")
            |> component.duration(milliseconds: 10),
          )
        },
      )
    })
  let html = test_support.inner_html("#app")

  // `string.inspect` quotes the key, meaning a substring match
  string.contains(html, "data-lily-key")
  |> should.be_true
  string.contains(html, "data-lily-transition-exit=\"out\"")
  |> should.be_true
}

@target(javascript)
pub fn component_transition_events_on_outer_wrapper_test() {
  // event.on sits alongside the transition as a Listener decoration
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.static(fn(_) {
        "<button id=\"tx-btn\" data-lily-message=\"go\">+</button>"
      })
      |> component.transition(enter: "fade", exit: "fade-out")
      |> component.duration(milliseconds: 10)
      |> event.on_click(message: Increment)
      |> event.selector("#tx-btn")
    })
  test_support.click("#tx-btn")

  client.model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// NESTED CHILDREN
// =============================================================================

@target(javascript)
pub fn component_simple_nested_child_added_later_renders_the_current_model_test() {
  // first appears on a re-render, must use that render's model
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.active_tab },
        render: fn(tab, nest) {
          case tab {
            TabA -> "<p>hidden</p>"
            TabB ->
              nest(
                component.simple(
                  slice: fn(model: Model) { model.count },
                  render: fn(count, _) {
                    "<b id=\"late\">" <> int.to_string(count) <> "</b>"
                  },
                ),
              )
          }
        },
      )
    })
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(SetTab(TabB))

  test_support.get_text("#late") |> should.equal("2")
}

@target(javascript)
pub fn component_each_removed_row_drops_children_added_after_it_rendered_test() {
  // nested child added after the row, removing the row still stops it
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let slices = test_support.new(0)
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { id },
        render: fn(_id, nest) {
          nest(
            component.simple(
              slice: fn(model: Model) { model.active_tab },
              render: fn(tab, nest) {
                case tab {
                  TabA -> ""
                  TabB ->
                    nest(
                      component.simple(
                        slice: fn(model: Model) {
                          test_support.set(slices, test_support.get(slices) + 1)
                          model.count
                        },
                        render: fn(count, _) { int.to_string(count) },
                      ),
                    )
                }
              },
            ),
          )
        },
      )
    })
  client.dispatch(runtime)(SetTab(TabB))
  client.dispatch(runtime)(RemoveTransitionItem(1))
  let before = test_support.get(slices)
  client.dispatch(runtime)(Increment)

  test_support.get(slices) |> should.equal(before)
}

// =============================================================================
// FORM PROPERTIES
// =============================================================================

@target(javascript)
pub fn component_simple_value_change_reaches_an_edited_input_test() {
  // after typing, the value attribute is dead, set the property
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(SetName("seed"))
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.name },
        render: fn(name, _) { "<input id=\"field\" value=\"" <> name <> "\">" },
      )
    })
  test_support.input_event("#field", "typed")
  client.dispatch(runtime)(SetName(""))

  test_support.get_value("#field") |> should.equal("")
}

@target(javascript)
pub fn component_simple_rerender_keeps_typing_when_the_value_did_not_change_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { #(model.name, model.count) },
        render: fn(slice, _) {
          "<input id=\"field\" value=\""
          <> slice.0
          <> "\"><i>"
          <> int.to_string(slice.1)
          <> "</i>"
        },
      )
    })
  test_support.input_event("#field", "typed")
  client.dispatch(runtime)(Increment)

  test_support.get_value("#field") |> should.equal("typed")
}

@target(javascript)
pub fn component_simple_checked_change_reaches_a_toggled_checkbox_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(Increment)
  let _runtime =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count > 0 },
        render: fn(on, _) {
          case on {
            True -> "<input id=\"box\" type=\"checkbox\" checked>"
            False -> "<input id=\"box\" type=\"checkbox\">"
          }
        },
      )
    })
  // user unticks, the model ticks it back on
  test_support.check_event("#box", False)
  client.dispatch(runtime)(Decrement)
  client.dispatch(runtime)(Increment)

  test_support.get_checked("#box") |> should.be_true
}

@target(javascript)
pub fn component_live_value_patch_reaches_an_edited_input_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(SetName("seed"))
  let _runtime =
    mount(runtime, fn(_model) {
      component.live(
        slice: fn(model: Model) { model.name },
        render: fn(name, _) { "<input id=\"field\" value=\"" <> name <> "\">" },
        patch: fn(name) { [component.SetAttribute("#field", "value", name)] },
      )
    })
  test_support.input_event("#field", "typed")
  client.dispatch(runtime)(SetName("reset"))

  test_support.get_value("#field") |> should.equal("reset")
}

// =============================================================================
// LISTENER OWNERS
// =============================================================================

@target(javascript)
pub fn component_selector_listener_stops_when_its_component_leaves_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<button id=\"far\">+</button>" }),
        component.simple(
          slice: fn(model: Model) { model.active_tab },
          render: fn(tab, nest) {
            case tab {
              TabA ->
                nest(
                  component.static(fn(_) { "<i>listening</i>" })
                  |> event.on_click(message: Increment)
                  |> event.selector("#far"),
                )
              TabB -> "<i>gone</i>"
            }
          },
        ),
      ])
    })
  test_support.click("#far")
  client.model(runtime).count |> should.equal(1)

  client.dispatch(runtime)(SetTab(TabB))
  test_support.click("#far")
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn component_selector_listener_fires_once_after_its_parent_rerenders_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime =
    mount(runtime, fn(_model) {
      component.fragment([
        component.static(fn(_) { "<button id=\"far\">+</button>" }),
        component.simple(
          slice: fn(model: Model) { model.secondary_count },
          render: fn(count, nest) {
            "<i>"
            <> int.to_string(count)
            <> "</i>"
            <> nest(
              component.static(fn(_) { "" })
              |> event.on_click(message: Increment)
              |> event.selector("#far"),
            )
          },
        ),
      ])
    })
  client.dispatch(runtime)(IncrementSecondary)
  client.dispatch(runtime)(IncrementSecondary)
  test_support.click("#far")

  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn component_remount_drops_selector_listeners_of_the_previous_mount_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  test_support.set_inner_html("#overlays", "<button id=\"far\">+</button>")
  let _runtime =
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<p>first</p>" })
      |> event.on_click(message: Increment)
      |> event.selector("#far")
    })
  let _runtime =
    mount(runtime, fn(_model) { component.static(fn(_) { "<p>second</p>" }) })
  test_support.click("#far")

  client.model(runtime).count |> should.equal(0)
}

// =============================================================================
// MOUNT ROOTS
// =============================================================================

@target(javascript)
pub fn component_mount_on_a_missing_selector_logs_and_renders_nothing_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let renders = test_support.new(0)
  let logs =
    test_support.capture_logs(fn() {
      let _runtime =
        component.mount(
          runtime,
          selector: "#nowhere",
          to_html: test_support.to_html,
          to_placeholder: test_support.to_placeholder,
          view: fn(_model) {
            component.simple(
              slice: fn(model: Model) { model.count },
              render: fn(_, _) {
                test_support.set(renders, test_support.get(renders) + 1)
                ""
              },
            )
          },
        )
      Nil
    })

  list.any(logs, string.contains(_, "#nowhere")) |> should.be_true
  test_support.get(renders) |> should.equal(0)
}

@target(javascript)
pub fn component_two_runtimes_keep_their_components_apart_test() {
  test_support.reset_dom()
  let first = test_support.new_runtime()
  let second = test_support.new_runtime()
  let _runtime =
    mount(first, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { "first:" <> int.to_string(count) },
      )
    })
  let _runtime =
    component.mount(
      second,
      selector: "#overlays",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_model) {
        component.simple(
          slice: fn(model: Model) { model.count },
          render: fn(count, _) { "second:" <> int.to_string(count) },
        )
      },
    )
  client.dispatch(second)(Increment)

  test_support.inner_html("#app")
  |> string.contains("first:0")
  |> should.be_true
  test_support.inner_html("#overlays")
  |> string.contains("second:1")
  |> should.be_true
}

@target(javascript)
pub fn component_each_renders_once_its_container_comes_back_test() {
  // list changed while its container was missing, renders on return
  // even though the list value is unchanged by then
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let memo = test_support.new(#("", []))
  set_rows(runtime, "a")
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) {
          // same list value for the same names, like a model field
          case test_support.get(memo) {
            #(names, rows) if names == model.name -> rows
            _ -> {
              let rows = text_rows(model)
              test_support.set(memo, #(model.name, rows))
              rows
            }
          }
        },
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(row, _) { "<i>" <> row.1 <> "</i>" },
      )
    })
  let id =
    test_support.get_attribute(
      "#app > [data-lily-component]",
      "data-lily-component",
    )
  test_support.set_inner_html("#app", "")
  set_rows(runtime, "a,later")
  test_support.set_inner_html(
    "#app",
    "<div data-lily-component=\"" <> id <> "\"></div>",
  )
  client.update_model(runtime, with: fn(model) { model })

  test_support.inner_html("#app") |> string.contains("later") |> should.be_true
}

// =============================================================================
// TRANSITION TIMING
// =============================================================================

@target(javascript)
pub fn component_transition_exit_ignores_a_child_animation_end_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _runtime =
    mount(runtime, fn(_model) {
      component.each(
        slice: fn(model: Model) { transition_items_list(model) },
        key: fn(id: Int) { id },
        render: fn(_id, nest) {
          nest(
            component.static(fn(_) { "<span class=\"spinner\"></span>" })
            |> component.transition(enter: "tx3-enter", exit: "tx3-exit")
            |> component.duration(milliseconds: 40),
          )
        },
      )
    })
  client.dispatch(runtime)(RemoveTransitionItem(1))
  // a child's animationend bubbles up, it is not the exit
  test_support.fire_animation_end(".spinner")

  promise.wait(5)
  |> promise.map(fn(_) {
    test_support.inner_html("#app")
    |> string.contains("spinner")
    |> should.be_true
    Nil
  })
}

// =============================================================================
// ROOT ELEMENTS
// =============================================================================

@target(javascript)
fn table_row_view(
  open: String,
  close: String,
) -> fn(Model) -> component.Component(Model, message, String) {
  fn(_model) {
    component.static(fn(nest) {
      open
      <> nest(
        component.live(
          slice: fn(model: Model) { model.count },
          render: fn(count, _) {
            "<tr class=\"r\"><td>" <> int.to_string(count) <> "</td></tr>"
          },
          patch: fn(count) {
            [component.SetText(target: "td", value: int.to_string(count))]
          },
        ),
      )
      <> close
    })
  }
}

@target(javascript)
pub fn component_live_row_in_a_tbody_is_its_own_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ = mount(runtime, table_row_view("<table><tbody>", "</tbody></table>"))
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("table > tbody > tr.r", "data-lily-component")
  |> string.is_empty
  |> should.be_false
  test_support.get_text("tr.r td") |> should.equal("1")
  let html = test_support.inner_html("#app")
  html |> string.contains("<div") |> should.be_false
  html |> string.contains("lily-root") |> should.be_false
}

@target(javascript)
pub fn component_live_row_in_a_table_without_tbody_is_its_own_root_test() {
  // the parser implies the tbody, splitting the marks across parents
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ = mount(runtime, table_row_view("<table>", "</table>"))
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("table > tbody > tr.r", "data-lily-component")
  |> string.is_empty
  |> should.be_false
  test_support.get_text("tr.r td") |> should.equal("1")
  let html = test_support.inner_html("#app")
  html |> string.contains("<div") |> should.be_false
  html |> string.contains("lily-root") |> should.be_false
}

@target(javascript)
pub fn component_live_item_in_a_list_is_its_own_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(nest) {
        "<ul>"
        <> nest(
          component.live(
            slice: fn(model: Model) { model.count },
            render: fn(count, _) { "<li>" <> int.to_string(count) <> "</li>" },
            patch: fn(count) {
              [component.SetText(target: "", value: int.to_string(count))]
            },
          ),
        )
        <> "</ul>"
      })
    })
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("ul > li", "data-lily-component")
  |> string.is_empty
  |> should.be_false
  test_support.get_text("ul > li") |> should.equal("1")
}

@target(javascript)
pub fn component_simple_with_several_roots_gets_a_contents_wrapper_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) {
          "<i class=\"a\">" <> int.to_string(count) <> "</i><i>!</i>"
        },
      )
    })
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("#app > div", "style")
  |> should.equal("display: contents")
  test_support.get_attribute("#app > div", "data-lily-component")
  |> string.is_empty
  |> should.be_false
  test_support.get_text("#app > div > i.a") |> should.equal("1")
}

@target(javascript)
pub fn component_simple_with_only_text_gets_a_contents_wrapper_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) { int.to_string(count) },
      )
    })
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("#app > div", "style")
  |> should.equal("display: contents")
  test_support.get_text("#app > div") |> should.equal("1")
}

@target(javascript)
pub fn component_simple_going_from_empty_to_one_root_takes_the_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) {
          case count {
            0 -> ""
            _ -> "<p>" <> int.to_string(count) <> "</p>"
          }
        },
      )
    })
  let id = test_support.get_attribute("#app > div", "data-lily-component")
  id |> string.is_empty |> should.be_false

  client.dispatch(runtime)(Increment)
  test_support.get_attribute("#app > p", "data-lily-component")
  |> should.equal(id)
  test_support.inner_html("#app") |> string.contains("<div") |> should.be_false

  // and back, still the same component
  client.dispatch(runtime)(Decrement)
  test_support.get_attribute("#app > div", "data-lily-component")
  |> should.equal(id)
}

@target(javascript)
fn nest_only_row(
  open: Bool,
) -> component.Component(Model, test_support.Message, String) {
  component.simple(
    slice: fn(model: Model) { model.active_tab },
    render: fn(tab, nest) {
      case tab, open {
        TabA, _ | TabB, True ->
          nest(
            component.simple(
              slice: fn(model: Model) { model.count },
              render: fn(count, _) {
                "<tr class=\"c\"><td>" <> int.to_string(count) <> "</td></tr>"
              },
            ),
          )
        TabB, False -> "<tr class=\"p\"><td>plain</td></tr>"
      }
    },
  )
}

@target(javascript)
pub fn component_nest_only_render_shares_its_childs_root_test() {
  // a <tr> stays in its tbody, the outer id rides on the child's root
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(nest) {
        "<table><tbody>" <> nest(nest_only_row(True)) <> "</tbody></table>"
      })
    })
  client.dispatch(runtime)(Increment)
  client.dispatch(runtime)(SetTab(TabB))
  client.dispatch(runtime)(Increment)

  let ids =
    test_support.get_attribute("tbody > tr.c", "data-lily-component")
    |> string.split(" ")
  list.length(ids) |> should.equal(2)
  test_support.get_text("tbody > tr.c") |> should.equal("2")
  test_support.inner_html("#app") |> string.contains("<div") |> should.be_false
}

@target(javascript)
pub fn component_nest_only_render_switching_to_markup_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(nest) {
        "<table><tbody>" <> nest(nest_only_row(False)) <> "</tbody></table>"
      })
    })
  let assert [_child, outer] =
    test_support.get_attribute("tbody > tr.c", "data-lily-component")
    |> string.split(" ")

  client.dispatch(runtime)(SetTab(TabB))
  test_support.get_attribute("tbody > tr.p", "data-lily-component")
  |> should.equal(outer)
  test_support.inner_html("#app")
  |> string.contains("tr class=\"c")
  |> should.be_false

  // and back, the child's root carries the outer id again
  client.dispatch(runtime)(SetTab(TabA))
  client.dispatch(runtime)(Increment)
  test_support.get_text("tbody > tr.c") |> should.equal("1")
  test_support.get_attribute("tbody > tr.c", "data-lily-component")
  |> string.ends_with(" " <> outer)
  |> should.be_true
}

@target(javascript)
fn toggled_panel_view(
  _model: Model,
) -> component.Component(Model, test_support.Message, String) {
  component.simple(
    slice: fn(model: Model) { model.transition_item },
    render: fn(item, nest) {
      case item {
        Some(_) ->
          nest(
            component.static(fn(_) { "<div id=\"panel\">p</div>" })
            |> component.transition(enter: "in", exit: "out")
            |> component.duration(milliseconds: 200),
          )
        None -> ""
      }
    },
  )
}

@target(javascript)
pub fn component_nest_only_child_reopened_mid_exit_comes_back_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ = mount(runtime, toggled_panel_view)
  client.dispatch(runtime)(AddTransitionItem(1))
  let ids = test_support.get_attribute("#panel", "data-lily-component")

  client.dispatch(runtime)(RemoveTransitionItem(1))
  test_support.get_attribute("#panel", "class") |> should.equal("out")
  client.dispatch(runtime)(AddTransitionItem(1))

  // the same element, interactive, with no second panel beside it
  test_support.inner_html("#app")
  |> string.split("id=\"panel\"")
  |> list.length
  |> should.equal(2)
  test_support.get_attribute("#panel", "data-lily-component")
  |> should.equal(ids)
  test_support.inner_html("#app") |> string.contains("inert") |> should.be_false
}

@target(javascript)
pub fn component_resize_listener_follows_a_replaced_root_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  test_support.stub_observers()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_) {
      tab_view()
      |> event.on_resize(handler: fn(_size) { Increment })
    })

  use _ <- promise.await(promise.wait(0))
  test_support.observed_tags("ResizeObserver") |> should.equal(["p"])
  client.dispatch(runtime)(SetTab(TabB))

  use _ <- promise.map(promise.wait(0))
  let tags = test_support.observed_tags("ResizeObserver")
  test_support.unstub_observers()
  tags |> should.equal(["section"])
}

@target(javascript)
fn tab_view() -> component.Component(Model, test_support.Message, String) {
  component.simple(
    slice: fn(model: Model) { model.active_tab },
    render: fn(tab, _) {
      case tab {
        TabA -> "<p class=\"t\">A</p>"
        TabB -> "<section class=\"t\">B</section>"
      }
    },
  )
  |> event.on_click(message: Increment)
}

@target(javascript)
pub fn component_simple_root_tag_change_replaces_the_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ = mount(runtime, fn(_) { tab_view() })
  let id = test_support.get_attribute(".t", "data-lily-component")

  client.dispatch(runtime)(SetTab(TabB))

  test_support.get_attribute("#app > section.t", "data-lily-component")
  |> should.equal(id)
  test_support.inner_html("#app") |> string.contains("<p") |> should.be_false
  // the listener moved with the id
  test_support.click(".t")
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn component_simple_root_tag_change_inside_an_each_row_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  set_rows(runtime, "a")
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: text_rows,
        key: fn(row: #(Int, String)) { row.0 },
        render: fn(_row, nest) { nest(tab_view()) },
      )
    })

  client.dispatch(runtime)(SetTab(TabB))

  // the row's key moved onto the new root, and the list still tracks it
  test_support.get_attribute("#app > section.t", "data-lily-key")
  |> should.equal("0")
  set_rows(runtime, "a,b")
  test_support.inner_html("#app")
  |> string.split("data-lily-key")
  |> list.length
  |> should.equal(3)
  test_support.get_attribute("#app > section.t + section.t", "data-lily-key")
  |> should.equal("1")
  set_rows(runtime, "")
  test_support.inner_html("#app")
  |> string.contains("section")
  |> should.be_false
}

@target(javascript)
pub fn component_simple_with_a_transition_keeps_its_id_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.simple(
        slice: fn(model: Model) { model.count },
        render: fn(count, _) {
          "<b class=\"c\">" <> int.to_string(count) <> "</b>"
        },
      )
      |> component.transition(enter: "in", exit: "out")
    })
  let id = test_support.get_attribute("b.c", "data-lily-component")

  client.dispatch(runtime)(Increment)

  test_support.get_text("b.c") |> should.equal("1")
  test_support.get_attribute("b.c", "data-lily-component") |> should.equal(id)
  test_support.get_attribute("b.c", "data-lily-transition-exit")
  |> should.equal("out")
  test_support.inner_html("#app") |> string.contains("<div") |> should.be_false
}

@target(javascript)
fn live_attribute_view(
  render: fn(Int) -> String,
) -> fn(Model) -> component.Component(Model, message, String) {
  fn(_model) {
    component.live(
      slice: fn(model: Model) { model.count },
      render: fn(count, _) { render(count) },
      patch: fn(count) {
        [
          component.SetAttribute(
            target: "",
            name: "data-n",
            value: int.to_string(count),
          ),
        ]
      },
    )
  }
}

@target(javascript)
pub fn component_live_empty_target_patches_the_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(
      runtime,
      live_attribute_view(fn(count) { "<b>" <> int.to_string(count) <> "</b>" }),
    )
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("#app > b", "data-n") |> should.equal("1")
}

@target(javascript)
pub fn component_live_empty_target_patches_the_wrapper_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(
      runtime,
      live_attribute_view(fn(count) {
        "<b>" <> int.to_string(count) <> "</b><i></i>"
      }),
    )
  client.dispatch(runtime)(Increment)

  test_support.get_attribute("#app > div", "data-n") |> should.equal("1")
  test_support.get_attribute("#app > div > b", "data-n") |> should.equal("")
}

@target(javascript)
pub fn component_transition_on_one_root_uses_the_root_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<span class=\"one\">x</span>" })
      |> component.transition(enter: "in", exit: "out")
    })

  test_support.get_attribute("#app > span.one", "data-lily-transition-exit")
  |> should.equal("out")
  test_support.get_attribute("#app > span.one", "class")
  |> should.equal("one in")
}

@target(javascript)
pub fn component_transition_on_several_roots_gets_a_block_div_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _ =
    mount(runtime, fn(_model) {
      component.static(fn(_) { "<i>a</i><i>b</i>" })
      |> component.transition(enter: "in out-too", exit: "out")
    })

  test_support.get_attribute("#app > div", "data-lily-transition-exit")
  |> should.equal("out")
  // a contents box can't animate, and both enter classes land
  test_support.get_attribute("#app > div", "style") |> should.equal("")
  test_support.get_attribute("#app > div", "class")
  |> should.equal("in out-too")
}

@target(javascript)
pub fn component_transition_exit_and_cancel_keep_a_roots_own_aria_hidden_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _ =
    mount(runtime, fn(_model) {
      component.each(
        slice: transition_items_list,
        key: fn(id: Int) { int.to_string(id) },
        render: fn(_id, nest) {
          nest(
            component.static(fn(_) {
              "<span class=\"own\" aria-hidden=\"true\">x</span>"
            })
            |> component.transition(enter: "in", exit: "out")
            |> component.duration(milliseconds: 50),
          )
        },
      )
    })

  client.dispatch(runtime)(RemoveTransitionItem(1))
  test_support.get_attribute(".own", "inert") |> should.equal("")
  test_support.get_attribute(".own", "data-lily-exiting")
  |> should.equal("inert")

  client.dispatch(runtime)(AddTransitionItem(1))
  test_support.get_attribute(".own", "aria-hidden") |> should.equal("true")
  test_support.inner_html("#app") |> string.contains("inert") |> should.be_false
}

// =============================================================================
// CANCELLED EXITS
// =============================================================================

@target(javascript)
pub fn component_cancelled_exit_eases_back_test() -> promise.Promise(Nil) {
  test_support.reset_dom()
  test_support.stub_animations("panel", 200)
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _ = mount(runtime, animated_item_view)
  client.dispatch(runtime)(RemoveTransitionItem(1))

  use _ <- promise.await(promise.wait(60))
  client.dispatch(runtime)(AddTransitionItem(1))

  // interactive at once, the class stays while the animation plays back
  test_support.inner_html("#app") |> string.contains("inert") |> should.be_false
  test_support.get_attribute(".card", "class") |> should.equal("card tx5-exit")
  test_support.animation_playback_rate(".card") |> should.equal(-1.0)

  use _ <- promise.map(promise.wait(150))
  test_support.unstub_animations()
  test_support.get_attribute(".card", "class") |> should.equal("card")
}

@target(javascript)
pub fn component_exit_during_a_reversal_turns_it_forward_test() -> promise.Promise(
  Nil,
) {
  test_support.reset_dom()
  test_support.stub_animations("panel", 200)
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(AddTransitionItem(1))
  let _ = mount(runtime, animated_item_view)
  client.dispatch(runtime)(RemoveTransitionItem(1))

  use _ <- promise.await(promise.wait(60))
  client.dispatch(runtime)(AddTransitionItem(1))
  use _ <- promise.await(promise.wait(20))
  client.dispatch(runtime)(RemoveTransitionItem(1))
  test_support.animation_playback_rate(".card") |> should.equal(1.0)

  // past where the reversal would have ended, the class never left
  use _ <- promise.await(promise.wait(80))
  test_support.get_attribute(".card", "class") |> should.equal("card tx5-exit")

  use _ <- promise.map(promise.wait(250))
  test_support.unstub_animations()
  test_support.inner_html("#app") |> string.contains("card") |> should.be_false
}
