// Shared test types, update function, and serialisers used across all test files.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import lily/transport.{type Serialiser}

// =============================================================================
// TYPES
// =============================================================================

pub type Model {
  Model(count: Int, name: String, connected: Bool)
}

pub type Message {
  Increment
  Decrement
  SetName(String)
  Reset
  Noop
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
  Model(count: 0, name: "", connected: False)
}

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
    SetName(name) -> Model(..model, name: name)
    Reset -> initial_model()
    Noop -> model
  }
}

// =============================================================================
// CUSTOM SERIALISER (explicit encode/decode — no FFI, works on both targets)
// =============================================================================

pub fn custom_serialiser() -> Serialiser(Model, Message) {
  transport.custom(
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
      json.object([#("tag", json.string("SetName")), #("name", json.string(name))])
    Reset -> json.object([#("tag", json.string("Reset"))])
    Noop -> json.object([#("tag", json.string("Noop"))])
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
    _ -> decode.failure(Noop, "Message")
  }
}

pub fn encode_model(model: Model) -> Json {
  json.object([
    #("count", json.int(model.count)),
    #("name", json.string(model.name)),
    #("connected", json.bool(model.connected)),
  ])
}

pub fn model_decoder() -> Decoder(Model) {
  use count <- decode.field("count", decode.int)
  use name <- decode.field("name", decode.string)
  use connected <- decode.field("connected", decode.bool)
  decode.success(Model(count:, name:, connected:))
}
