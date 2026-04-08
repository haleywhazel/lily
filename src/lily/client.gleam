// IMPORTS

import lily/protocol
import lily/store.{type Store}

// PUBLIC TYPES

pub type Serialiser(model, msg) =
  protocol.Serialiser(model, msg)

// PUBLIC FUNCTIONS

@target(javascript)
pub fn connect(
  url url: String,
  serialiser serialiser: Serialiser(model, msg),
) -> Nil {
  set_on_msg_hook(fn(message) {
    let text =
      protocol.encode(protocol.ClientMessage(payload: message), serialiser:)
    send_text(text)
  })

  ws_connect(
    url,
    fn(text) { handle_incoming(text, serialiser) },
    fn() { send_resync(serialiser) },
  )
}

pub fn mount(selector selector: String, html html: String) -> Nil {
  set_inner_html(selector, html)
}

@target(javascript)
pub fn set_reconnect_base_milliseconds(milliseconds: Int) -> Nil {
  ffi_set_reconnect_base_milliseconds(milliseconds)
}

@target(javascript)
pub fn set_reconnect_max_milliseconds(milliseconds: Int) -> Nil {
  ffi_set_reconnect_max_milliseconds(milliseconds)
}

pub fn start(store: Store(model, msg)) -> Nil {
  let Nil = initialise(store, store.apply, store.notify)
  let updated = store.dispatch(store, new_model: store.model)
  set_store_ref(updated)
}

// INTERNAL FUNCTIONS

@internal
pub fn apply_patches(
  selector: String,
  patches: List(#(String, String, String, String)),
) -> Nil {
  ffi_apply_patches(selector, patches)
}

@internal
pub fn reference_equal(a: a, b: a) -> Bool {
  ffi_reference_equal(a, b)
}

@internal
pub fn selective(
  selector: String,
  select: fn(model) -> slice,
  compare: fn(slice, slice) -> Bool,
  handler: fn(slice) -> Nil,
) -> fn(model) -> Nil {
  ffi_selective(selector, select, compare, handler)
}

@internal
pub fn send_msg(msg: msg) -> Nil {
  ffi_send_msg(msg)
}

@internal
pub fn set_compare_strategy(selector: String, compare: fn(a, a) -> Bool) -> Nil {
  ffi_set_compare_strategy(selector, compare)
}

@internal
pub fn set_inner_html(selector: String, html: String) -> Nil {
  ffi_set_inner_html(selector, html)
}

@internal
pub fn structural_equal(a: a, b: a) -> Bool {
  a == b
}

// PRIVATE FUNCTIONS

@target(javascript)
fn handle_incoming(
  text: String,
  serialiser: Serialiser(model, msg),
) -> Nil {
  case protocol.decode(text, serialiser:) {
    Ok(protocol.ServerMessage(sequence:, payload:)) -> {
      set_last_sequence(sequence)
      apply_remote_msg(payload)
    }

    Ok(protocol.Snapshot(sequence:, state:)) -> {
      set_last_sequence(sequence)
      dispatch_model(state)
    }

    Ok(protocol.Acknowledge(sequence:)) -> {
      set_last_sequence(sequence)
    }

    Ok(protocol.ClientMessage(payload: _payload)) -> Nil
    Ok(protocol.Resync(after_sequence: _after_sequence)) -> Nil

    Error(_error) -> Nil
  }
}

@target(javascript)
fn send_resync(serialiser: Serialiser(model, msg)) -> Nil {
  let last_sequence = get_last_sequence()
  let text =
    protocol.encode(protocol.Resync(after_sequence: last_sequence), serialiser:)
  send_text(text)
}

// PRIVATE FFI — App Initialization

@external(javascript, "./client.ffi.mjs", "initialise")
fn initialise(
  _store: Store(model, msg),
  _apply: fn(Store(model, msg), msg) -> Store(model, msg),
  _notify: fn(Store(model, msg)) -> Nil,
) -> Nil {
  Nil
}

@external(javascript, "./client.ffi.mjs", "set_store_ref")
fn set_store_ref(_store: Store(model, msg)) -> Nil {
  Nil
}

// PRIVATE FFI — DOM

@external(javascript, "./client.ffi.mjs", "apply_patches")
fn ffi_apply_patches(
  _selector: String,
  _patches: List(#(String, String, String, String)),
) -> Nil {
  Nil
}

@external(javascript, "./client.ffi.mjs", "set_inner_html")
fn ffi_set_inner_html(_selector: String, _html: String) -> Nil {
  Nil
}

// PRIVATE FFI — Selective Rendering

@external(javascript, "./client.ffi.mjs", "create_selective")
fn ffi_selective(
  _selector: String,
  _select: fn(model) -> slice,
  _compare: fn(slice, slice) -> Bool,
  _handler: fn(slice) -> Nil,
) -> fn(model) -> Nil {
  fn(_model) { Nil }
}

@external(javascript, "./client.ffi.mjs", "reference_equal")
fn ffi_reference_equal(_a: a, _b: a) -> Bool {
  False
}

@external(javascript, "./client.ffi.mjs", "set_compare_strategy")
fn ffi_set_compare_strategy(
  _selector: String,
  _compare: fn(a, a) -> Bool,
) -> Nil {
  Nil
}

// PRIVATE FFI — Sync Configuration

@target(javascript)
@external(javascript, "./client.ffi.mjs", "set_reconnect_base_milliseconds")
fn ffi_set_reconnect_base_milliseconds(_milliseconds: Int) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "set_reconnect_max_milliseconds")
fn ffi_set_reconnect_max_milliseconds(_milliseconds: Int) -> Nil {
  Nil
}

// PRIVATE FFI — Sync Hooks

@target(javascript)
@external(javascript, "./client.ffi.mjs", "apply_remote_msg")
fn apply_remote_msg(_msg: msg) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "dispatch_model")
fn dispatch_model(_model: model) -> Nil {
  Nil
}

@external(javascript, "./client.ffi.mjs", "send_msg")
fn ffi_send_msg(_msg: msg) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "set_on_msg_hook")
fn set_on_msg_hook(_hook: fn(msg) -> Nil) -> Nil {
  Nil
}

// PRIVATE FFI — WebSocket

@target(javascript)
@external(javascript, "./client.ffi.mjs", "connect")
fn ws_connect(
  _url: String,
  _on_message: fn(String) -> Nil,
  _on_reconnect: fn() -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "get_last_sequence")
fn get_last_sequence() -> Int {
  0
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "send_text")
fn send_text(_text: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "set_last_sequence")
fn set_last_sequence(_sequence: Int) -> Nil {
  Nil
}
