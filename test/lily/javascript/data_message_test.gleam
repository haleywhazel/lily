// data-lily-message decoding on a client-only page, types the page encoded
// decode without registration, frames still need it

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/json
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
import lily/javascript/stamp_fixture.{Ink, Stamp}
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{Increment, SetName}
@target(javascript)
import lily/transport

// =============================================================================
// DATA MESSAGES
// =============================================================================

@target(javascript)
pub fn data_message_client_only_click_dispatches_an_unregistered_type_test() {
  test_support.reset_dom()
  let runtime =
    store.new(init: [], update: fn(stamps, stamp) { [stamp, ..stamps] })
    |> client.start
  let html =
    "<button id=\"stamp\" data-lily-message=\""
    <> event.encode_message(Stamp(ink: Ink(colour: "teal")))
    <> "\">stamp</button>"
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_model) { component.static(fn(_nest) { html }) },
    )

  test_support.click("#stamp")

  client.model(runtime)
  |> should.equal([Stamp(ink: Ink(colour: "teal"))])
}

@target(javascript)
pub fn data_message_encoded_types_never_reach_wire_decoding_test() {
  // the page encoding it teaches only data-lily-message decoding
  event.encode_message(Stamp(ink: Ink(colour: "red")))
  |> event.decode_message
  |> should.equal(Ok(Stamp(ink: Ink(colour: "red"))))

  let payload =
    json.to_string(
      json.object([
        #("_", json.string("Stamp")),
        #(
          "0",
          json.object([
            #("_", json.string("Ink")),
            #("0", json.string("red")),
          ]),
        ),
      ]),
    )
  let decoded: Result(transport.Protocol(Nil, stamp_fixture.Stamp), Nil) =
    transport.decode(
      bit_array.from_string(
        "{\"type\":\"session_message\",\"payload\":" <> payload <> "}",
      ),
      serialiser: transport.automatic(
        format: transport.Json,
        max_decode_depth: 128,
        modules: [],
      ),
    )
  decoded |> should.equal(Error(Nil))
}

@target(javascript)
pub fn data_message_click_is_held_to_the_schema_test() {
  // markup from data can carry any registered constructor, the schema says
  // which a message may be
  test_support.reset_dom()
  let module = "lily/test_support"
  let schema =
    transport.schema(
      message: transport.Custom(module:, name: "Message", parameters: []),
      model: transport.Anything,
      types: [
        transport.custom(module:, name: "Message", constructors: [
          transport.constructor(name: "Increment", fields: []),
        ]),
      ],
    )
  let runtime =
    test_support.session_store() |> store.schema(schema) |> client.start
  let html =
    "<button id=\"ok\" data-lily-message=\""
    <> event.encode_message(Increment)
    <> "\">+</button><button id=\"bad\" data-lily-message=\""
    <> event.encode_message(SetName("forged"))
    <> "\">name</button>"
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_model) { component.static(fn(_nest) { html }) },
    )

  test_support.click("#bad")
  test_support.click("#ok")

  client.model(runtime).name |> should.equal("")
  client.model(runtime).count |> should.equal(1)
}

@target(javascript)
pub fn data_message_click_ignores_a_huge_attribute_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let html =
    "<button id=\"huge\" data-lily-message=\""
    <> event.encode_message(SetName(string.repeat("a", 20_000)))
    <> "\">+</button>"
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: test_support.to_html,
      to_placeholder: test_support.to_placeholder,
      view: fn(_model) { component.static(fn(_nest) { html }) },
    )

  test_support.click("#huge")

  client.model(runtime).name |> should.equal("")
}
