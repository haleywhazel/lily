// Shared test types, update function, and serialisers used across all
// test files.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import lily/transport.{type Serialiser}

// =============================================================================
// TYPES
// =============================================================================

pub type Model {
  Model(
    count: Int,
    name: String,
    connected: Bool,
    // Switch tests subscribe to active_tab; secondary_count and
    // transition_items give disjoint slices for multi-mount and
    // each_live transition tests.
    active_tab: Tab,
    secondary_count: Int,
    transition_items: List(Int),
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
    transition_items: [],
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
    AddTransitionItem(id) ->
      Model(..model, transition_items: [id, ..model.transition_items])
    RemoveTransitionItem(id) ->
      Model(
        ..model,
        transition_items: list_filter(model.transition_items, fn(other) {
          other != id
        }),
      )
  }
}

fn list_filter(items: List(a), keep: fn(a) -> Bool) -> List(a) {
  case items {
    [] -> []
    [first, ..rest] ->
      case keep(first) {
        True -> [first, ..list_filter(rest, keep)]
        False -> list_filter(rest, keep)
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
  json.object([
    #("count", json.int(model.count)),
    #("name", json.string(model.name)),
    #("connected", json.bool(model.connected)),
    #("active_tab", json.string(tab_to_string(model.active_tab))),
    #("secondary_count", json.int(model.secondary_count)),
    #(
      "transition_items",
      json.array(model.transition_items, of: json.int),
    ),
  ])
}

pub fn model_decoder() -> Decoder(Model) {
  use count <- decode.field("count", decode.int)
  use name <- decode.field("name", decode.string)
  use connected <- decode.field("connected", decode.bool)
  use active_tab <- decode.field("active_tab", decode.string)
  use secondary_count <- decode.field("secondary_count", decode.int)
  use transition_items <- decode.field(
    "transition_items",
    decode.list(decode.int),
  )
  decode.success(Model(
    count:,
    name:,
    connected:,
    active_tab: tab_from_string(active_tab),
    secondary_count:,
    transition_items:,
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
