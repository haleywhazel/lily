// JS auto-serialiser constructor registry and `ByHost` on the jsdom page
// (localhost), shared roundtrips in test/lily/shared/transport_auto_test.gleam

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/javascript/promise
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{None, Some}
@target(javascript)
import gleam/string

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/internal/codec
@target(javascript)
import lily/javascript/verdict_fixture
@target(javascript)
import lily/test_support.{SetName}
@target(javascript)
import lily/transport.{SessionMessage}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
/// Decode handwritten JSON, leaving no prior encode to register the type.
fn decode_payload(
  json: String,
) -> Result(transport.Protocol(Nil, message), Nil) {
  transport.decode(
    bit_array.from_string(
      "{\"type\":\"session_message\",\"payload\":" <> json <> "}",
    ),
    serialiser: transport.automatic(
      format: transport.Json,
      max_decode_depth: 128,
      modules: [],
    ),
  )
}

// =============================================================================
// DECODING
// =============================================================================

@target(javascript)
pub fn auto_js_json_decodes_a_registered_constructor_test() {
  test_support.register_fixtures()

  decode_payload("{\"_\":\"SetName\",\"0\":\"JsonPath\"}")
  |> should.equal(Ok(SessionMessage(payload: SetName("JsonPath"))))
}

@target(javascript)
pub fn auto_js_decodes_option_without_registration_test() {
  decode_payload("{\"_\":\"Some\",\"0\":1}")
  |> should.equal(Ok(SessionMessage(payload: Some(1))))
  decode_payload("{\"_\":\"None\"}")
  |> should.equal(Ok(SessionMessage(payload: None)))
}

@target(javascript)
pub fn auto_js_decodes_prelude_result_without_registration_test() {
  decode_payload("{\"_\":\"Ok\",\"0\":1}")
  |> should.equal(Ok(SessionMessage(payload: Ok(1))))
  decode_payload("{\"_\":\"Error\",\"0\":1}")
  |> should.equal(Ok(SessionMessage(payload: Error(1))))
}

// =============================================================================
// REGISTRY
// =============================================================================

@target(javascript)
pub fn auto_js_registry_tells_same_name_apart_by_arity_test() {
  register_this_module()

  decode_payload("{\"_\":\"Error\"}")
  |> should.equal(Ok(SessionMessage(payload: verdict_fixture.Error)))
  decode_payload("{\"_\":\"Error\",\"0\":1}")
  |> should.equal(Ok(SessionMessage(payload: Error(1))))
}

@target(javascript)
pub fn auto_js_a_crashing_registration_callback_spares_the_rest_test() -> promise.Promise(
  Nil,
) {
  let ran = test_support.new(False)

  codec.request_module("lily", "lily/javascript/verdict_fixture")
  codec.when_registered(fn() { panic as "registration callback blew up" })
  codec.when_registered(fn() { test_support.set(ran, True) })

  promise.wait(50)
  |> promise.map(fn(_) {
    test_support.get(ran) |> should.be_true
    Nil
  })
}

@target(javascript)
pub fn auto_js_unknown_constructor_logs_once_test() {
  let lines =
    test_support.capture_logs(fn() {
      let _ = decode_payload("{\"_\":\"NeverRegistered\",\"0\":1}")
      let _ = decode_payload("{\"_\":\"NeverRegistered\",\"0\":2}")
      Nil
    })

  lines
  |> list.filter(string.contains(_, "NeverRegistered/1"))
  |> list.length
  |> should.equal(1)
}

@target(javascript)
pub fn auto_js_registering_a_clashing_constructor_warns_once_test() {
  test_support.capture_logs(fn() { register_twins() })
  |> list.filter(string.contains(_, "Twin/1"))
  |> list.length
  |> should.equal(1)
}

@target(javascript)
pub fn auto_js_replacing_a_built_in_constructor_warns_test() {
  test_support.capture_logs(fn() { register_impostor_some() })
  |> list.filter(string.contains(_, "built-in constructor Some/1"))
  |> list.length
  |> should.equal(1)
}

// =============================================================================
// BY HOST
// =============================================================================

@target(javascript)
pub fn auto_js_jsdom_page_is_local_test() {
  transport.is_local_page() |> should.be_true
}

@target(javascript)
pub fn auto_js_by_host_writes_json_on_a_local_page_test() {
  let serialiser: transport.Serialiser(Nil, Nil) =
    transport.automatic(
      format: transport.ByHost,
      max_decode_depth: 128,
      modules: [],
    )

  transport.encode(transport.Connected(client_id: "c1"), serialiser:)
  |> transport.frame_format(serialiser:)
  |> should.equal(Ok(transport.Json))
}

@target(javascript)
pub fn auto_js_resolve_for_page_settles_by_host_to_json_test() {
  let serialiser: transport.Serialiser(Nil, Nil) =
    transport.automatic(
      format: transport.ByHost,
      max_decode_depth: 128,
      modules: [],
    )
    |> transport.resolve_for_page

  transport.encode_as(
    transport.Connected(client_id: "c1"),
    serialiser:,
    format: transport.server_format(serialiser),
  )
  |> transport.frame_format(serialiser:)
  |> should.equal(Ok(transport.Json))
}

// =============================================================================
// INPUT HYGIENE
// =============================================================================

@target(javascript)
pub fn auto_js_refuses_a_lone_surrogate_topic_id_test() {
  let serialiser =
    transport.automatic(
      format: transport.Json,
      max_decode_depth: 128,
      modules: [],
    )

  transport.decode(
    <<"{\"type\":\"subscribe\",\"topic_id\":\"room:\\ud800\"}">>,
    serialiser:,
  )
  |> should.equal(Error(Nil))
  transport.decode(
    <<"{\"type\":\"subscribe\",\"topic_id\":\"room:\\ud83d\\ude00\"}">>,
    serialiser:,
  )
  |> should.equal(Ok(transport.Subscribe(topic_id: "room:😀")))
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./transport_auto_js_test.ffi.mjs", "registerImpostorSome")
fn register_impostor_some() -> Nil

@target(javascript)
@external(javascript, "./transport_auto_js_test.ffi.mjs", "registerThisModule")
fn register_this_module() -> Nil

@target(javascript)
@external(javascript, "./transport_auto_js_test.ffi.mjs", "registerTwins")
fn register_twins() -> Nil
