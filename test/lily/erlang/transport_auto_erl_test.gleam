// automatic serialiser module list on Erlang, shared roundtrips live in
// test/lily/shared/transport_auto_test.gleam

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleam/string

@target(erlang)
import gleeunit/should

@target(erlang)
import lily/test_support.{type Message, type Model, SetName}
@target(erlang)
import lily/transport.{Acknowledge, Session, SessionMessage, Subscribe}

// =============================================================================
// MODULES
// =============================================================================

@target(erlang)
pub fn auto_erl_modules_do_not_change_the_wire_on_the_server_test() {
  // modules are for the browser, the server already has every type compiled in
  let with_modules: transport.Serialiser(Model, Message) =
    transport.automatic(format: transport.Json, max_decode_depth: 128, modules: [
      transport.module("shared"),
      transport.module_in(package: "lily_ui", path: "lily/ui/theme"),
    ])
  let plain =
    transport.automatic(
      format: transport.Json,
      max_decode_depth: 128,
      modules: [],
    )
  let frame = Acknowledge(target: Session, sequence: 4)

  transport.encode(frame, serialiser: with_modules)
  |> should.equal(transport.encode(frame, serialiser: plain))
  transport.encode(frame, serialiser: with_modules)
  |> transport.decode(serialiser: plain)
  |> should.equal(Ok(frame))
}

// =============================================================================
// RETENTION
// =============================================================================

@target(erlang)
pub fn auto_erl_decoded_strings_do_not_retain_the_frame_test() {
  let serialiser: transport.Serialiser(Model, Message) =
    transport.automatic(
      format: transport.MessagePack,
      max_decode_depth: 128,
      modules: [],
    )
  let long = string.repeat("x", 200)

  let assert Ok(Subscribe(topic_id:)) =
    transport.encode(Subscribe(topic_id: long), serialiser:)
    |> transport.decode(serialiser:)
  referenced_byte_size(topic_id)
  |> should.equal(200)

  let assert Ok(SessionMessage(payload: SetName(name))) =
    transport.encode(SessionMessage(payload: SetName(long)), serialiser:)
    |> transport.decode(serialiser:)
  referenced_byte_size(name)
  |> should.equal(200)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(erlang)
@external(erlang, "binary", "referenced_byte_size")
fn referenced_byte_size(text: String) -> Int
