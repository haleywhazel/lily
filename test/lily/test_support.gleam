//// Consolidated test-support module for the lily suite: shared fixtures
//// (types, update, serialisers), a dual-target mutable reference cell,
//// runtime/server builders, and JavaScript DOM/environment helpers. Mixed
//// targets are fine here because each JavaScript-only function carries its
//// own `@target(javascript)`, so Erlang compilation stays clean.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lily/server
import lily/store
import lily/transport.{type Serialiser}

@target(javascript)
import gleam/dynamic.{type Dynamic}
@target(javascript)
import lily/client
@target(javascript)
import lily/component

// =============================================================================
// FIXTURE TYPES
// =============================================================================

pub type Model {
  Model(
    count: Int,
    name: String,
    connected: Bool,
    // Switch tests subscribe to active_tab, secondary_count and
    // transition_item give disjoint slices for multi-mount and
    // each transition tests. `transition_item` is `Option(Int)`
    // (None or Some(id)) rather than `List(Int)` because the JS and
    // Erlang auto-serialisers encode empty Gleam lists differently
    // (JS uses the `Empty` constructor wrapper, Erlang uses
    // MessagePack array length 0), so a `List` field here would break
    // the cross-target wire-format snapshot tests. Each_live tests
    // map this Option to a list inside the slice, which is fine since
    // slice return values are not serialised.
    active_tab: Tab,
    secondary_count: Int,
    transition_item: Option(Int),
  )
}

pub type Tab {
  TabA
  TabB
}

pub type Message {
  Increment
  Decrement
  SetName(String)
  Reset
  Noop
  SetTab(Tab)
  IncrementSecondary
  AddTransitionItem(Int)
  RemoveTransitionItem(Int)
}

// Additional types for auto-serialiser edge-case tests
pub type Nested {
  Nested(inner: Model)
}

pub type WithList {
  WithList(items: List(Int))
}

pub type WithBool {
  WithBool(flag: Bool)
}

pub type WithFloat {
  WithFloat(value: Float)
}

pub type WithTuple {
  WithTuple(pair: #(Int, String))
}

pub type WithDict {
  WithDict(entries: Dict(String, Int))
}

pub type WithSet {
  WithSet(members: Set(Int))
}

// =============================================================================
// STORE HELPERS
// =============================================================================

pub fn initial_model() -> Model {
  Model(
    count: 0,
    name: "",
    connected: False,
    active_tab: TabA,
    secondary_count: 0,
    transition_item: None,
  )
}

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
    SetName(name) -> Model(..model, name: name)
    Reset -> initial_model()
    Noop -> model
    SetTab(tab) -> Model(..model, active_tab: tab)
    IncrementSecondary ->
      Model(..model, secondary_count: model.secondary_count + 1)
    AddTransitionItem(id) -> Model(..model, transition_item: Some(id))
    RemoveTransitionItem(id) ->
      case model.transition_item {
        Some(current) if current == id -> Model(..model, transition_item: None)
        _ -> model
      }
  }
}

// =============================================================================
// CUSTOM SERIALISER (explicit encode/decode, no FFI, works on both targets)
// =============================================================================

pub fn custom_serialiser() -> Serialiser(Model, Message) {
  transport.custom_json(
    encode_message: encode_message,
    decode_message: message_decoder(),
    encode_model: encode_model,
    decode_model: model_decoder(),
  )
}

pub fn encode_message(message: Message) -> Json {
  case message {
    Increment -> json.object([#("tag", json.string("Increment"))])
    Decrement -> json.object([#("tag", json.string("Decrement"))])
    SetName(name) ->
      json.object([
        #("tag", json.string("SetName")),
        #("name", json.string(name)),
      ])
    Reset -> json.object([#("tag", json.string("Reset"))])
    Noop -> json.object([#("tag", json.string("Noop"))])
    SetTab(tab) ->
      json.object([
        #("tag", json.string("SetTab")),
        #("tab", json.string(tab_to_string(tab))),
      ])
    IncrementSecondary ->
      json.object([#("tag", json.string("IncrementSecondary"))])
    AddTransitionItem(id) ->
      json.object([
        #("tag", json.string("AddTransitionItem")),
        #("id", json.int(id)),
      ])
    RemoveTransitionItem(id) ->
      json.object([
        #("tag", json.string("RemoveTransitionItem")),
        #("id", json.int(id)),
      ])
  }
}

pub fn message_decoder() -> Decoder(Message) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Increment" -> decode.success(Increment)
    "Decrement" -> decode.success(Decrement)
    "SetName" -> {
      use name <- decode.field("name", decode.string)
      decode.success(SetName(name))
    }
    "Reset" -> decode.success(Reset)
    "Noop" -> decode.success(Noop)
    "SetTab" -> {
      use tab <- decode.field("tab", decode.string)
      decode.success(SetTab(tab_from_string(tab)))
    }
    "IncrementSecondary" -> decode.success(IncrementSecondary)
    "AddTransitionItem" -> {
      use id <- decode.field("id", decode.int)
      decode.success(AddTransitionItem(id))
    }
    "RemoveTransitionItem" -> {
      use id <- decode.field("id", decode.int)
      decode.success(RemoveTransitionItem(id))
    }
    _ -> decode.failure(Noop, "Message")
  }
}

pub fn encode_model(model: Model) -> Json {
  let transition_item = case model.transition_item {
    Some(id) -> json.int(id)
    None -> json.null()
  }
  json.object([
    #("count", json.int(model.count)),
    #("name", json.string(model.name)),
    #("connected", json.bool(model.connected)),
    #("active_tab", json.string(tab_to_string(model.active_tab))),
    #("secondary_count", json.int(model.secondary_count)),
    #("transition_item", transition_item),
  ])
}

pub fn model_decoder() -> Decoder(Model) {
  use count <- decode.field("count", decode.int)
  use name <- decode.field("name", decode.string)
  use connected <- decode.field("connected", decode.bool)
  use active_tab <- decode.field("active_tab", decode.string)
  use secondary_count <- decode.field("secondary_count", decode.int)
  use transition_item <- decode.field(
    "transition_item",
    decode.optional(decode.int),
  )
  decode.success(Model(
    count:,
    name:,
    connected:,
    active_tab: tab_from_string(active_tab),
    secondary_count:,
    transition_item:,
  ))
}

fn tab_to_string(tab: Tab) -> String {
  case tab {
    TabA -> "TabA"
    TabB -> "TabB"
  }
}

fn tab_from_string(name: String) -> Tab {
  case name {
    "TabB" -> TabB
    _ -> TabA
  }
}

// =============================================================================
// REFERENCE CELL (dual-target)
// =============================================================================

pub type Ref(value)

@external(erlang, "lily_test_support_ffi", "new_ref")
@external(javascript, "./test_support.ffi.mjs", "newRef")
pub fn new(value: value) -> Ref(value)

@external(erlang, "lily_test_support_ffi", "get_ref")
@external(javascript, "./test_support.ffi.mjs", "getRef")
pub fn get(ref: Ref(value)) -> value

@external(erlang, "lily_test_support_ffi", "set_ref")
@external(javascript, "./test_support.ffi.mjs", "setRef")
pub fn set(ref: Ref(value), value: value) -> Nil

// =============================================================================
// RUNTIME / SERVER BUILDERS
// =============================================================================

@target(javascript)
pub fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(initial_model(), with: update)
  |> client.start(store.wiring(), serialiser: custom_serialiser())
}

pub fn new_server() -> server.Server(Model, Message) {
  let assert Ok(srv) =
    server.new(
      initial: initial_model(),
      serialiser: custom_serialiser(),
      wiring: store.wiring()
        |> store.session(
          extract: fn(message) { Ok(message) },
          update: update,
          field_get: fn(model) { model },
          field_set: fn(_, model) { model },
        ),
    )
    |> server.start
  srv
}

/// Connect a mock client that appends received messages to a ref list.
/// Returns a drain fn that returns and clears the captured messages.
/// Drains the `Connected` frame sent immediately on connect so tests
/// that check for other frames don't have to skip it.
pub fn connect_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> fn() -> List(BitArray) {
  let ref = new([])
  server.connect(srv, client_id: client_id, send: fn(bytes) {
    set(ref, [bytes, ..get(ref)])
  })
  set(ref, [])
  fn() {
    let msgs = list.reverse(get(ref))
    set(ref, [])
    msgs
  }
}

pub fn to_html(s: String) -> String {
  s
}

// =============================================================================
// EVENT HELPERS
// =============================================================================

@target(javascript)
/// Wraps an empty static component in the caller's event attachments and
/// registers the bindings without mounting. Bypassing `component.mount`
/// means the DOM container is left untouched, which matters for the events
/// that attach listeners directly to a queried element (resize, scroll,
/// copy/cut/paste, value events) rather than via document delegation.
pub fn mount_event(
  runtime: client.Runtime(Model, Message),
  attach: fn(component.Component(Model, Message, String)) ->
    component.Component(Model, Message, String),
) -> Nil {
  let tree = attach(component.static(fn(_slot) { "" }))
  component.register_bindings(runtime, tree)
}

@target(javascript)
pub fn to_slot() -> String {
  "<lily-slot></lily-slot>"
}

// =============================================================================
// DOM + ENVIRONMENT (JavaScript only)
// =============================================================================

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setup")
pub fn setup() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetDom")
pub fn reset_dom() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetHotReloadInstalled")
pub fn reset_hot_reload_installed() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getLastWebSocket")
pub fn get_last_websocket() -> Dynamic {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getLastEventSource")
pub fn get_last_event_source() -> Dynamic {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetMocks")
pub fn reset_mocks() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerWebSocketOpen")
pub fn trigger_websocket_open(_websocket: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerWebSocketMessage")
pub fn trigger_websocket_message(_websocket: Dynamic, _data: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerWebSocketClose")
pub fn trigger_websocket_close(_websocket: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getWebSocketSent")
pub fn get_websocket_sent(_websocket: Dynamic) -> List(String) {
  []
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerEventSourceOpen")
pub fn trigger_event_source_open(_event_source: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerEventSourceMessage")
pub fn trigger_event_source_message(
  _event_source: Dynamic,
  _data: String,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerEventSourceError")
pub fn trigger_event_source_error(_event_source: Dynamic) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "historyLength")
pub fn history_length() -> Int {
  0
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetUrl")
pub fn reset_url() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "injectSnapshotScript")
pub fn inject_snapshot_script(_json: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getInnerHtml")
pub fn inner_html(_selector: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setInnerHtml")
pub fn set_inner_html(_selector: String, _html: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "click")
pub fn click(_selector: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchMouseEvent")
pub fn mouse_event(
  _selector: String,
  _event_name: String,
  _client_x: Int,
  _client_y: Int,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchKeyEvent")
pub fn key_event(_selector: String, _event_name: String, _key: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchKeyEventDefaultPrevented")
pub fn key_event_default_prevented(
  _selector: String,
  _event_name: String,
  _key: String,
) -> Bool {
  False
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "focus")
pub fn focus(_selector: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "activeElementId")
pub fn active_element_id() -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchInputEvent")
pub fn input_event(_selector: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchWheelEvent")
pub fn wheel_event(_selector: String, _delta_x: Float, _delta_y: Float) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getAttribute")
pub fn get_attribute(_selector: String, _name: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "hasAttribute")
pub fn has_attribute(_selector: String, _name: String) -> Bool {
  False
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getText")
pub fn get_text(_selector: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setLocalStorageItem")
pub fn set_local_storage_item(_key: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getLocalStorageItem")
pub fn get_local_storage_item(_key: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "hasLocalStorageItem")
pub fn has_local_storage_item(_key: String) -> Bool {
  False
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchSimpleEvent")
pub fn simple_event(_selector: String, _event_name: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "writeLocalStorage")
pub fn write_local_storage(_key: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "readLocalStorage")
pub fn read_local_storage(_key: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "writeSessionStorage")
pub fn write_session_storage(_key: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "readSessionStorage")
pub fn read_session_storage(_key: String) -> String {
  ""
}
