// IMPORTS

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/result

// PUBLIC TYPES

pub type Protocol(model, msg) {
  Acknowledge(sequence: Int)
  ClientMessage(payload: msg)
  Resync(after_sequence: Int)
  ServerMessage(sequence: Int, payload: msg)
  Snapshot(sequence: Int, state: model)
}

pub type Serialiser(model, msg) {
  Serialiser(
    encode_message: fn(msg) -> Json,
    message_decoder: decode.Decoder(msg),
    encode_state: fn(model) -> Json,
    state_decoder: decode.Decoder(model),
  )
}

// PUBLIC FUNCTIONS

pub fn decode(
  text: String,
  serialiser serialiser: Serialiser(model, msg),
) -> Result(Protocol(model, msg), Nil) {
  let decoder = protocol_decoder(serialiser)
  json.parse(from: text, using: decoder)
  |> result.replace_error(Nil)
}

pub fn encode(
  protocol: Protocol(model, msg),
  serialiser serialiser: Serialiser(model, msg),
) -> String {
  case protocol {
    ClientMessage(payload:) ->
      json.object([
        #("type", json.string("client_message")),
        #("payload", serialiser.encode_message(payload)),
      ])

    ServerMessage(sequence:, payload:) ->
      json.object([
        #("type", json.string("server_message")),
        #("sequence", json.int(sequence)),
        #("payload", serialiser.encode_message(payload)),
      ])

    Snapshot(sequence:, state:) ->
      json.object([
        #("type", json.string("snapshot")),
        #("sequence", json.int(sequence)),
        #("state", serialiser.encode_state(state)),
      ])

    Resync(after_sequence:) ->
      json.object([
        #("type", json.string("resync")),
        #("after_sequence", json.int(after_sequence)),
      ])

    Acknowledge(sequence:) ->
      json.object([
        #("type", json.string("acknowledge")),
        #("sequence", json.int(sequence)),
      ])
  }
  |> json.to_string
}

// PRIVATE FUNCTIONS

fn acknowledge_decoder() -> decode.Decoder(Protocol(model, msg)) {
  use sequence <- decode.field("sequence", decode.int)
  decode.success(Acknowledge(sequence:))
}

fn client_message_decoder(
  serialiser: Serialiser(model, msg),
) -> decode.Decoder(Protocol(model, msg)) {
  use payload <- decode.field("payload", serialiser.message_decoder)
  decode.success(ClientMessage(payload:))
}

fn protocol_decoder(
  serialiser: Serialiser(model, msg),
) -> decode.Decoder(Protocol(model, msg)) {
  use protocol_type <- decode.then(decode.at(["type"], decode.string))
  case protocol_type {
    "client_message" -> client_message_decoder(serialiser)
    "server_message" -> server_message_decoder(serialiser)
    "snapshot" -> snapshot_decoder(serialiser)
    "resync" -> resync_decoder()
    "acknowledge" -> acknowledge_decoder()
    _ -> decode.failure(Acknowledge(0), "Protocol")
  }
}

fn resync_decoder() -> decode.Decoder(Protocol(model, msg)) {
  use after_sequence <- decode.field("after_sequence", decode.int)
  decode.success(Resync(after_sequence:))
}

fn server_message_decoder(
  serialiser: Serialiser(model, msg),
) -> decode.Decoder(Protocol(model, msg)) {
  use sequence <- decode.field("sequence", decode.int)
  use payload <- decode.field("payload", serialiser.message_decoder)
  decode.success(ServerMessage(sequence:, payload:))
}

fn snapshot_decoder(
  serialiser: Serialiser(model, msg),
) -> decode.Decoder(Protocol(model, msg)) {
  use sequence <- decode.field("sequence", decode.int)
  use state <- decode.field("state", serialiser.state_decoder)
  decode.success(Snapshot(sequence:, state:))
}
