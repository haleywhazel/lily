// transport.Schema, the server's check of client payloads, both targets

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/option
import gleam/set

import gleeunit/should

import lily/server
import lily/store
import lily/test_support.{AddTransitionItem, SetName, SetTab, TabB}
import lily/transport.{
  type WireType, Anything, BoolType, Custom, DictOf, FloatType, IntType, ListOf,
  NilType, SetOf, StringType, TupleOf, Variable,
}
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

fn checked(
  payload: String,
  schema: transport.Schema,
) -> Result(transport.Protocol(model, message), Nil) {
  transport.decode_checked(
    session_message(payload),
    serialiser: test_support.automatic_serialiser(transport.Json),
    schema: option.Some(schema),
  )
}

fn message_schema() -> transport.Schema {
  let module = "lily/test_support"
  transport.schema(
    message: Custom(module:, name: "Message", parameters: []),
    model: Anything,
    types: [
      transport.custom(module:, name: "Message", constructors: [
        transport.constructor(name: "AddTransitionItem", fields: [IntType]),
        transport.constructor(name: "Claim", fields: [StringType]),
        transport.constructor(name: "Decrement", fields: []),
        transport.constructor(name: "Increment", fields: []),
        transport.constructor(name: "IncrementSecondary", fields: []),
        transport.constructor(name: "Noop", fields: []),
        transport.constructor(name: "RemoveTransitionItem", fields: [IntType]),
        transport.constructor(name: "Reset", fields: []),
        transport.constructor(name: "SetName", fields: [StringType]),
        transport.constructor(name: "SetTab", fields: [
          Custom(module:, name: "Tab", parameters: []),
        ]),
      ]),
      transport.custom(module:, name: "Tab", constructors: [
        transport.constructor(name: "TabA", fields: []),
        transport.constructor(name: "TabB", fields: []),
      ]),
    ],
  )
}

fn option_schema(inner: WireType) -> transport.Schema {
  transport.schema(
    message: Custom(module: "gleam/option", name: "Option", parameters: [inner]),
    model: Anything,
    types: [
      transport.custom(module: "gleam/option", name: "Option", constructors: [
        transport.constructor(name: "None", fields: []),
        transport.constructor(name: "Some", fields: [Variable(0)]),
      ]),
    ],
  )
}

fn rooted(message: WireType) -> transport.Schema {
  transport.schema(message:, model: Anything, types: [])
}

fn session_message(payload: String) -> BitArray {
  bit_array.from_string(
    "{\"type\":\"session_message\",\"payload\":" <> payload <> "}",
  )
}

fn topic_message(topic_id: String, payload: String) -> BitArray {
  bit_array.from_string(
    "{\"type\":\"topic_message\",\"topic_id\":\""
    <> topic_id
    <> "\",\"payload\":"
    <> payload
    <> "}",
  )
}

// =============================================================================
// DECODING
// =============================================================================

pub fn schema_accepts_a_matching_payload_test() {
  test_support.register_fixtures()
  checked("{\"_\":\"SetName\",\"0\":\"a\"}", message_schema())
  |> should.equal(Ok(transport.SessionMessage(payload: SetName("a"))))
}

pub fn schema_rejects_an_int_in_a_string_field_test() {
  test_support.register_fixtures()
  checked("{\"_\":\"SetName\",\"0\":1}", message_schema())
  |> should.equal(Error(Nil))
}

pub fn schema_rejects_a_constructor_of_another_type_test() {
  test_support.register_fixtures()
  checked("{\"_\":\"Ok\",\"0\":1}", message_schema())
  |> should.equal(Error(Nil))
}

pub fn schema_rejects_a_wrong_field_count_test() {
  test_support.register_fixtures()
  checked("{\"_\":\"SetName\"}", message_schema())
  |> should.equal(Error(Nil))
  checked("{\"_\":\"Increment\",\"0\":1}", message_schema())
  |> should.equal(Error(Nil))
}

pub fn schema_checks_nested_custom_types_test() {
  test_support.register_fixtures()
  checked("{\"_\":\"SetTab\",\"0\":{\"_\":\"TabB\"}}", message_schema())
  |> should.equal(Ok(transport.SessionMessage(payload: SetTab(TabB))))
  checked(
    "{\"_\":\"SetTab\",\"0\":{\"_\":\"SetName\",\"0\":\"x\"}}",
    message_schema(),
  )
  |> should.equal(Error(Nil))
}

pub fn schema_substitutes_type_parameters_test() {
  checked("{\"_\":\"Some\",\"0\":\"x\"}", option_schema(StringType))
  |> should.equal(Ok(transport.SessionMessage(payload: option.Some("x"))))
  checked("{\"_\":\"Some\",\"0\":\"x\"}", option_schema(IntType))
  |> should.equal(Error(Nil))
  checked("{\"_\":\"None\"}", option_schema(IntType))
  |> should.equal(Ok(transport.SessionMessage(payload: option.None)))
}

pub fn schema_float_field_takes_a_whole_number_as_a_float_test() {
  checked("{\"_\":\"Some\",\"0\":2}", option_schema(FloatType))
  |> should.equal(Ok(transport.SessionMessage(payload: option.Some(2.0))))
  checked("{\"_\":\"Some\",\"0\":1.5}", option_schema(FloatType))
  |> should.equal(Ok(transport.SessionMessage(payload: option.Some(1.5))))
  checked("{\"_\":\"Some\",\"0\":1.5}", option_schema(IntType))
  |> should.equal(Error(Nil))
}

pub fn schema_checks_collections_test() {
  let schema =
    rooted(TupleOf([ListOf(IntType), DictOf(key: StringType, value: BoolType)]))
  checked("{\"0\":[1,2],\"1\":{\"_\":\"$dict\",\"0\":[[\"a\",true]]}}", schema)
  |> should.equal(
    Ok(
      transport.SessionMessage(payload: #(
        [1, 2],
        dict.from_list([#("a", True)]),
      )),
    ),
  )
  checked("{\"0\":[1,\"2\"],\"1\":{\"_\":\"$dict\",\"0\":[]}}", schema)
  |> should.equal(Error(Nil))
  checked("{\"0\":[1]}", schema)
  |> should.equal(Error(Nil))
}

pub fn schema_checks_set_members_test() {
  checked("{\"_\":\"$set\",\"0\":[null]}", rooted(SetOf(NilType)))
  |> should.equal(Ok(transport.SessionMessage(payload: set.from_list([Nil]))))
  checked("{\"_\":\"$set\",\"0\":[1]}", rooted(SetOf(NilType)))
  |> should.equal(Error(Nil))
}

pub fn schema_anything_and_unbound_variables_pass_test() {
  checked("{\"0\":1,\"1\":\"a\"}", rooted(Anything))
  |> should.equal(Ok(transport.SessionMessage(payload: #(1, "a"))))
  checked("{\"0\":1,\"1\":\"a\"}", rooted(Variable(0)))
  |> should.equal(Ok(transport.SessionMessage(payload: #(1, "a"))))
}

pub fn schema_checks_message_pack_payloads_test() {
  test_support.register_fixtures()
  let serialiser = test_support.message_pack_serialiser()
  let bytes =
    transport.encode(
      transport.SessionMessage(payload: AddTransitionItem(5)),
      serialiser:,
    )
  let module = "lily/test_support"
  let as_string =
    transport.schema(
      message: Custom(module:, name: "Message", parameters: []),
      model: Anything,
      types: [
        transport.custom(module:, name: "Message", constructors: [
          transport.constructor(name: "AddTransitionItem", fields: [StringType]),
        ]),
      ],
    )

  transport.decode_checked(
    bytes,
    serialiser:,
    schema: option.Some(message_schema()),
  )
  |> should.equal(Ok(transport.SessionMessage(payload: AddTransitionItem(5))))
  transport.decode_checked(bytes, serialiser:, schema: option.Some(as_string))
  |> should.equal(Error(Nil))
}

pub fn schema_leaves_server_frames_unchecked_test() {
  let model = test_support.initial_model()
  let bytes =
    transport.encode(
      transport.Snapshot(
        target: transport.Session,
        epoch: 0,
        sequence: 1,
        state: model,
      ),
      serialiser: test_support.automatic_serialiser(transport.Json),
    )
  transport.decode_checked(
    bytes,
    serialiser: test_support.automatic_serialiser(transport.Json),
    schema: option.Some(rooted(IntType)),
  )
  |> should.equal(
    Ok(transport.Snapshot(
      target: transport.Session,
      epoch: 0,
      sequence: 1,
      state: model,
    )),
  )
}

// =============================================================================
// SERVER
// =============================================================================

pub fn server_drops_a_session_message_that_fails_the_schema_test() {
  test_support.register_fixtures()
  let app =
    test_support.start_server(server.new(
      test_support.automatic_session_store(transport.Json)
        |> store.schema(message_schema()),
      origins: server.AnyOrigin,
    ))
  let #(c1, raw) = wire_support.open_raw(app, "c1", [])
  let _ = raw()

  server.incoming(c1, bytes: session_message("{\"_\":\"SetName\",\"0\":1}"))
  server.incoming(c1, bytes: session_message("{\"_\":\"Ok\",\"0\":1}"))
  server.incoming(c1, bytes: session_message("{\"_\":\"SetName\",\"0\":\"a\"}"))

  raw()
  |> list.map(wire_support.decode_automatic)
  |> should.equal([
    transport.Dropped(target: transport.Session),
    transport.Dropped(target: transport.Session),
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}

pub fn server_drops_a_topic_message_that_fails_the_schema_test() {
  test_support.register_fixtures()
  let #(builder, events) =
    wire_support.observed(server.new(
      test_support.automatic_topic_store() |> store.schema(message_schema()),
      origins: server.AnyOrigin,
    ))
  let app = test_support.start_server(builder)
  let #(c1, raw) = wire_support.open_raw(app, "c1", [])
  wire_support.send_in(
    c1,
    transport.Subscribe(topic_id: "chat"),
    transport.Json,
  )
  let _ = raw()
  let _ = events(app)

  server.incoming(
    c1,
    bytes: topic_message("chat", "{\"_\":\"Increment\",\"0\":\"x\"}"),
  )

  raw()
  |> list.map(wire_support.decode_automatic)
  |> should.equal([transport.Dropped(target: transport.Topic("chat"))])
  events(app)
  |> should.equal([
    server.Diagnostic(
      level: transport.Warning,
      message: "dropped a message from \"c1\" that fails the schema",
    ),
  ])
  test_support.subscriber_count(app, "chat")
  |> should.equal(1)
}

pub fn server_without_a_schema_accepts_any_shape_test() {
  test_support.register_fixtures()
  let app =
    test_support.start_server(server.new(
      test_support.automatic_session_store(transport.Json),
      origins: server.AnyOrigin,
    ))
  let #(c1, raw) = wire_support.open_raw(app, "c1", [])
  let _ = raw()

  server.incoming(c1, bytes: session_message("{\"_\":\"Noop\"}"))

  raw()
  |> list.map(wire_support.decode_automatic)
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1),
  ])
}
