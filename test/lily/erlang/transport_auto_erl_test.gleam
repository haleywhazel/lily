// automatic serialiser module list on Erlang, shared roundtrips live in
// test/lily/shared/transport_auto_test.gleam

// =============================================================================
// IMPORTS
// =============================================================================

@target(erlang)
import gleeunit/should

@target(erlang)
import lily/test_support.{type Message, type Model}
@target(erlang)
import lily/transport.{Acknowledge, Session}

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
