// Shared test types, update function, and serialisers used across all
// test files.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lily/transport.{type Serialiser}

// =============================================================================
// TYPES
// =============================================================================

pub type Model {
  Model(
    count: Int,
    name: String,
    connected: Bool,
    // Switch tests subscribe to active_tab, secondary_count and
    // transition_item give disjoint slices for multi-mount and
    // each_live transition tests. `transition_item` is `Option(Int)`
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
