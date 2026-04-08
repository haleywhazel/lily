// IMPORTS

import gleam/list
import lily/client
import lily/store.{type Store}

// PUBLIC TYPES

pub type Patch {
  RemoveAttribute(selector: String, name: String)
  SetAttribute(selector: String, name: String, value: String)
  SetStyle(selector: String, property: String, value: String)
  SetText(selector: String, value: String)
}

// PUBLIC FUNCTIONS

pub fn each(
  store: Store(model, msg),
  container container: String,
  items items: fn(model) -> List(key),
  create create: fn(key) -> #(fn(model) -> a, fn(a) -> String),
) -> Store(model, msg) {
  let handler =
    create_each_handler(container, items, create, client.reference_equal)

  let #(updated_store, _id) = store.subscribe(store, with: handler)
  updated_store
}

pub fn live(
  store: Store(model, msg),
  selector selector: String,
  slice slice: fn(model) -> a,
  patch patch: fn(a) -> List(Patch),
) -> Store(model, msg) {
  let handler =
    client.selective(selector, slice, client.reference_equal, fn(current) {
      let patches =
        patch(current)
        |> list.map(patch_to_tuple)

      client.apply_patches(selector, patches)
    })

  let #(updated_store, _id) = store.subscribe(store, with: handler)
  updated_store
}

pub fn mount(
  store: Store(model, msg),
  selector selector: String,
  html html: String,
) -> Store(model, msg) {
  let Nil = client.mount(selector:, html:)
  store
}

pub fn on_blur(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "blur", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_change(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(String) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_value_event(selector, "change", fn(value) {
      client.send_msg(handler(value))
    })
  store
}

pub fn on_click(
  store: Store(model, msg),
  selector selector: String,
  decoder decoder: fn(String) -> Result(msg, Nil),
) -> Store(model, msg) {
  let Nil =
    setup_click_event(selector, fn(msg_name) {
      case decoder(msg_name) {
        Ok(msg) -> client.send_msg(msg)
        Error(Nil) -> Nil
      }
    })
  store
}

pub fn on_context_menu(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "contextmenu", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_copy(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "copy", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_cut(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "cut", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_double_click(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "dblclick", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_drag(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "drag", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_drag_end(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "dragend", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_drag_over(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "dragover", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_drag_start(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "dragstart", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_drop(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "drop", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_focus(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "focus", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_input(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(String) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_value_event(selector, "input", fn(value) {
      client.send_msg(handler(value))
    })
  store
}

pub fn on_key_down(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(String) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_key_event(selector, "keydown", fn(key) {
      client.send_msg(handler(key))
    })
  store
}

pub fn on_key_up(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(String) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_key_event(selector, "keyup", fn(key) {
      client.send_msg(handler(key))
    })
  store
}

pub fn on_mouse_down(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "mousedown", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_mouse_enter(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "mouseenter", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_mouse_leave(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "mouseleave", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_mouse_move(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "mousemove", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_mouse_up(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "mouseup", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_paste(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "paste", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_pointer_down(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "pointerdown", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_pointer_move(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "pointermove", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_pointer_up(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "pointerup", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_resize(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "resize", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_scroll(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "scroll", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_submit(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "submit", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_touch_end(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn() -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_simple_event(selector, "touchend", fn() {
      client.send_msg(handler())
    })
  store
}

pub fn on_touch_move(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "touchmove", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_touch_start(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Int, Int) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_coordinate_event(selector, "touchstart", fn(x, y) {
      client.send_msg(handler(x, y))
    })
  store
}

pub fn on_wheel(
  store: Store(model, msg),
  selector selector: String,
  handler handler: fn(Float, Float) -> msg,
) -> Store(model, msg) {
  let Nil =
    setup_wheel_event(selector, fn(delta_x, delta_y) {
      client.send_msg(handler(delta_x, delta_y))
    })
  store
}

pub fn simple(
  store: Store(model, msg),
  selector selector: String,
  slice slice: fn(model) -> a,
  render render: fn(a) -> String,
) -> Store(model, msg) {
  let handler =
    client.selective(selector, slice, client.reference_equal, fn(current) {
      client.set_inner_html(selector, render(current))
    })

  let #(updated_store, _id) = store.subscribe(store, with: handler)
  updated_store
}

pub fn structural_compare(
  store: Store(model, msg),
  selector selector: String,
) -> Store(model, msg) {
  let Nil = client.set_compare_strategy(selector, client.structural_equal)
  store
}

// PRIVATE FUNCTIONS

fn patch_to_tuple(patch: Patch) -> #(String, String, String, String) {
  case patch {
    SetText(selector, value) -> #("text", selector, "", value)
    SetAttribute(selector, name, value) -> #("attribute", selector, name, value)
    SetStyle(selector, property, value) -> #("style", selector, property, value)
    RemoveAttribute(selector, name) -> #("remove_attribute", selector, name, "")
  }
}

// PRIVATE FFI — Each Handler

@external(javascript, "./component.ffi.mjs", "create_each_handler")
fn create_each_handler(
  _container: String,
  _items: fn(model) -> List(key),
  _create: fn(key) -> #(fn(model) -> a, fn(a) -> String),
  _compare: fn(a, a) -> Bool,
) -> fn(model) -> Nil {
  fn(_model) { Nil }
}

// PRIVATE FFI — Event Handlers

@external(javascript, "./component.ffi.mjs", "setup_click_event")
fn setup_click_event(
  _selector: String,
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@external(javascript, "./component.ffi.mjs", "setup_coordinate_event")
fn setup_coordinate_event(
  _selector: String,
  _event_name: String,
  _handler: fn(Int, Int) -> Nil,
) -> Nil {
  Nil
}

@external(javascript, "./component.ffi.mjs", "setup_key_event")
fn setup_key_event(
  _selector: String,
  _event_name: String,
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@external(javascript, "./component.ffi.mjs", "setup_simple_event")
fn setup_simple_event(
  _selector: String,
  _event_name: String,
  _handler: fn() -> Nil,
) -> Nil {
  Nil
}

@external(javascript, "./component.ffi.mjs", "setup_value_event")
fn setup_value_event(
  _selector: String,
  _event_name: String,
  _handler: fn(String) -> Nil,
) -> Nil {
  Nil
}

@external(javascript, "./component.ffi.mjs", "setup_wheel_event")
fn setup_wheel_event(
  _selector: String,
  _handler: fn(Float, Float) -> Nil,
) -> Nil {
  Nil
}
