// docs/recipes/sse-transport.md, client half verbatim over the mocks
// recipe's ewe server half replaced by a real server stamping client ids

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/dynamic.{type Dynamic}
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{None}
@target(javascript)
import gleam/result
@target(javascript)
import gleam/string

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/client
@target(javascript)
import lily/server
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{type Message, type Model, Increment}
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
/// EventSource in, fetch out, binary frames as base64 text.
pub fn sse(
  events_url events_url: String,
  post_url post_url: String,
) -> transport.Connector {
  transport.connector(fn(handler: transport.ConnectorHandler) {
    let source =
      open_source(
        events_url,
        fn(text) {
          case bit_array.base64_decode(text) {
            Ok(bytes) -> handler.received(bytes)
            Error(_) -> Nil
          }
        },
        handler.opened,
        handler.closed,
      )
    transport.Channel(
      send: fn(bytes) {
        case source_client_id(source) {
          "" -> Error(Nil)
          client_id -> {
            post_text(
              post_url <> "?client=" <> client_id,
              bit_array.base64_encode(bytes, True),
            )
            Ok(Nil)
          }
        }
      },
      close: fn() { close_source(source) },
    )
  })
  |> transport.with_offline_queue(storage_key: "lily_sse_pending")
}

@target(javascript)
/// Recipe's stream handler, frames base64 with the client id as event id.
fn open_stream(
  app: server.Server(Model, Message),
  client_id client_id: String,
  source source: Dynamic,
) -> server.Connection(Model, Message) {
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: None,
      send: fn(bytes) {
        trigger_message_with_id(
          source,
          bit_array.base64_encode(bytes, True),
          client_id,
        )
      },
      client_id:,
      seed: [],
      watch: server.Unwatched,
    )
  connection
}

@target(javascript)
/// Recipe's POST handler, client id read from the URL.
fn receive_post(
  app: server.Server(Model, Message),
  url url: String,
  body body: String,
) -> Result(Nil, Nil) {
  use #(_, client_id) <- result.try(string.split_once(url, "?client="))
  use bytes <- result.map(bit_array.base64_decode(body))
  let _ =
    server.connection(app, client_id:)
    |> server.incoming(bytes:)
  Nil
}

@target(javascript)
fn binary_store() -> store.Store(Model, Message, store.Synced) {
  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.sync_with(
    route: fn(_) { store.Session },
    serialiser: transport.automatic(
      format: transport.MessagePack,
      max_decode_depth: 128,
      modules: [],
    ),
  )
  |> store.session(get: fn(model) { model }, set: fn(_, model) { model })
}

@target(javascript)
fn setup() -> client.Runtime(Model, Message, store.Synced) {
  test_support.reset_dom()
  test_support.reset_mocks()
  reset_fetch()
  test_support.register_fixtures()
  client.start(binary_store())
}

@target(javascript)
fn connect(runtime: client.Runtime(Model, Message, store.Synced)) -> Dynamic {
  let _ =
    client.connect(
      runtime,
      with: sse(events_url: "/events", post_url: "/messages"),
    )
  test_support.get_last_event_source()
}

@target(javascript)
/// Every POST in order as `#(url, body)`.
fn record_posts() -> test_support.Ref(List(#(String, String))) {
  let posted = test_support.new([])
  record_fetch(fn(url, body) {
    test_support.set(
      posted,
      list.append(test_support.get(posted), [#(url, body)]),
    )
  })
  posted
}

@target(javascript)
fn decode_post(body: String) -> transport.Protocol(Model, Message) {
  let assert Ok(bytes) = bit_array.base64_decode(body)
  let assert Ok(frame) =
    transport.decode(bytes, serialiser: test_support.message_pack_serialiser())
  frame
}

@target(javascript)
/// One frame as the recipe's server sends it.
fn push_frame(
  source: Dynamic,
  frame: transport.Protocol(Model, Message),
  client_id client_id: String,
) -> Nil {
  trigger_message_with_id(
    source,
    bit_array.base64_encode(
      transport.encode(
        frame,
        serialiser: test_support.message_pack_serialiser(),
      ),
      True,
    ),
    client_id,
  )
}

@target(javascript)
fn open_as(source: Dynamic, client_id: String) -> Nil {
  push_frame(source, transport.Connected(client_id:), client_id:)
}

// =============================================================================
// CLIENT
// =============================================================================

@target(javascript)
pub fn sse_recipe_opens_the_event_stream_test() {
  let runtime = setup()

  let source = connect(runtime)

  source
  |> dynamic_url
  |> should.equal("/events")
}

@target(javascript)
pub fn sse_recipe_delivers_server_frames_test() {
  let runtime = setup()
  let seen = test_support.new("")
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.ClientIdAssigned(client_id:) -> test_support.set(seen, client_id)
        _ -> Nil
      }
    })
  let source = connect(runtime)

  open_as(source, "c1")

  test_support.get(seen)
  |> should.equal("c1")
}

@target(javascript)
pub fn sse_recipe_ignores_text_that_is_not_base64_test() {
  let runtime = setup()
  let source = connect(runtime)

  trigger_message_with_id(source, "not base64!", "c1")

  client.model(runtime)
  |> should.equal(test_support.initial_model())
}

@target(javascript)
pub fn sse_recipe_posts_under_the_stamped_client_id_test() {
  let runtime = setup()
  let posted = record_posts()
  let source = connect(runtime)
  open_as(source, "c1")
  test_support.set(posted, [])

  client.dispatch(runtime)(Increment)

  test_support.get(posted)
  |> list.map(fn(post) { #(post.0, decode_post(post.1)) })
  |> should.equal([
    #("/messages?client=c1", transport.SessionMessage(payload: Increment)),
  ])
}

@target(javascript)
pub fn sse_recipe_queues_until_an_event_names_the_client_test() {
  let runtime = setup()
  let posted = record_posts()
  let source = connect(runtime)
  test_support.trigger_event_source_open(source)

  client.dispatch(runtime)(Increment)

  test_support.get(posted)
  |> should.equal([])
  test_support.read_session_storage("lily_sse_pending")
  |> string.is_empty
  |> should.be_false

  open_as(source, "c1")

  test_support.get(posted)
  |> list.map(fn(post) { decode_post(post.1) })
  |> list.contains(transport.SessionMessage(payload: Increment))
  |> should.be_true
}

@target(javascript)
pub fn sse_recipe_posts_under_the_new_id_after_a_reconnect_test() {
  let runtime = setup()
  let posted = record_posts()
  let source = connect(runtime)
  open_as(source, "c1")
  test_support.trigger_event_source_error(source)
  open_as(source, "c2")
  test_support.set(posted, [])

  client.dispatch(runtime)(Increment)

  test_support.get(posted)
  |> list.map(fn(post) { post.0 })
  |> should.equal(["/messages?client=c2"])
}

@target(javascript)
pub fn sse_recipe_reports_a_lost_stream_once_test() {
  let runtime = setup()
  let closes = test_support.new(0)
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.ConnectionClosed ->
          test_support.set(closes, test_support.get(closes) + 1)
        _ -> Nil
      }
    })
  let source = connect(runtime)
  open_as(source, "c1")

  test_support.trigger_event_source_error(source)
  test_support.trigger_event_source_error(source)

  test_support.get(closes)
  |> should.equal(1)
}

// =============================================================================
// THROUGH A SERVER
// =============================================================================

@target(javascript)
pub fn sse_recipe_round_trips_through_a_server_test() {
  let runtime = setup()
  let applied = test_support.new([])
  let assert Ok(app) =
    server.new(binary_store(), origins: server.AnyOrigin)
    |> server.observe(fn(event, _server) {
      case event {
        server.SessionMessageApplied(message:, ..) ->
          test_support.set(applied, [message, ..test_support.get(applied)])
        _ -> Nil
      }
    })
    |> server.start
  record_fetch(fn(url, body) {
    let _ = receive_post(app, url:, body:)
    Nil
  })
  let source = connect(runtime)
  let _ = open_stream(app, client_id: "c1", source:)

  client.dispatch(runtime)(Increment)
  server.dispatch_to(app, client_id: "c1", message: Increment)

  test_support.get(applied)
  |> should.equal([Increment])
  client.model(runtime).count
  |> should.equal(2)
}

@target(javascript)
pub fn sse_recipe_rejects_a_post_that_is_not_base64_test() {
  let assert Ok(app) =
    server.new(binary_store(), origins: server.AnyOrigin)
    |> server.start

  receive_post(app, url: "/messages?client=c1", body: "not base64!")
  |> should.equal(Error(Nil))
}

// =============================================================================
// CLOSE
// =============================================================================

@target(javascript)
pub fn sse_recipe_close_shuts_the_event_source_test() {
  test_support.reset_mocks()
  let channel =
    sse(events_url: "/events", post_url: "/messages")
    |> transport.run_connector(
      transport.ConnectorHandler(
        received: fn(_) { Nil },
        opened: fn() { Nil },
        closed: fn() { Nil },
      ),
    )

  channel.close()

  test_support.get_last_event_source()
  |> dynamic_ready_state
  |> should.equal(2)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./sse_recipe_test.ffi.mjs", "open_source")
fn open_source(
  url: String,
  received: fn(String) -> Nil,
  opened: fn() -> Nil,
  closed: fn() -> Nil,
) -> Dynamic

@target(javascript)
@external(javascript, "./sse_recipe_test.ffi.mjs", "source_client_id")
fn source_client_id(source: Dynamic) -> String

@target(javascript)
@external(javascript, "./sse_recipe_test.ffi.mjs", "close_source")
fn close_source(source: Dynamic) -> Nil

@target(javascript)
@external(javascript, "./sse_recipe_test.ffi.mjs", "post_text")
fn post_text(url: String, body: String) -> Nil

@target(javascript)
@external(javascript, "./sse_recipe_helpers.ffi.mjs", "recordFetch")
fn record_fetch(on_post: fn(String, String) -> Nil) -> Nil

@target(javascript)
@external(javascript, "./sse_recipe_helpers.ffi.mjs", "resetFetch")
fn reset_fetch() -> Nil

@target(javascript)
@external(javascript, "./sse_recipe_helpers.ffi.mjs", "triggerMessageWithId")
fn trigger_message_with_id(source: Dynamic, data: String, id: String) -> Nil

@target(javascript)
@external(javascript, "./sse_recipe_helpers.ffi.mjs", "urlOf")
fn dynamic_url(source: Dynamic) -> String

@target(javascript)
@external(javascript, "./sse_recipe_helpers.ffi.mjs", "eventSourceReadyState")
fn dynamic_ready_state(source: Dynamic) -> Int
