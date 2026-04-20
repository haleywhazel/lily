// Tests for lily/client — JavaScript runtime lifecycle.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/string
@target(javascript)
import gleeunit/should
@target(javascript)
import lily
@target(javascript)
import lily/client
@target(javascript)
import lily/test_fixtures.{type Message, type Model, Increment, Noop, SetName}
@target(javascript)
import lily/test_ref
@target(javascript)
import lily/test_setup
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start
}

// =============================================================================
// RUNTIME LIFECYCLE
// =============================================================================

@target(javascript)
pub fn client_start_preserves_initial_model_test() {
  test_setup.reset_dom()
  let runtime =
    lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.start
  let model = client.get_current_model(runtime)
  model.count
  |> should.equal(0)
  model.name
  |> should.equal("")
  model.connected
  |> should.be_false
}

@target(javascript)
pub fn client_start_returns_runtime_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime =
    lily.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.start
  client.get_current_model(runtime)
  |> should.equal(test_fixtures.initial_model())
}

// =============================================================================
// DISPATCH
// =============================================================================

@target(javascript)
pub fn client_dispatch_multiple_messages_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let d = client.dispatch(runtime)
  d(Increment)
  d(Increment)
  d(Increment)
  client.get_current_model(runtime).count
  |> should.equal(3)
}

@target(javascript)
pub fn client_dispatch_returns_function_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let d = client.dispatch(runtime)
  d(Noop)
  True
  |> should.be_true
}

@target(javascript)
pub fn client_dispatch_set_name_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  client.dispatch(runtime)(SetName("Alice"))
  client.get_current_model(runtime).name
  |> should.equal("Alice")
}

@target(javascript)
pub fn client_dispatch_updates_model_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let d = client.dispatch(runtime)
  d(Increment)
  client.get_current_model(runtime).count
  |> should.equal(1)
}

// =============================================================================
// ON-MESSAGE HOOK
// =============================================================================

@target(javascript)
pub fn client_on_message_hook_fires_for_local_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let ref = test_ref.new(False)
  client.on_message(runtime, fn(message, _model) {
    case message {
      Increment -> test_ref.set(ref, True)
      _ -> Nil
    }
  })
  client.dispatch(runtime)(Increment)
  test_ref.get(ref)
  |> should.be_true
}

@target(javascript)
pub fn client_on_message_hook_receives_model_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let model_ref = test_ref.new(test_fixtures.initial_model())
  client.on_message(runtime, fn(_message, model) {
    test_ref.set(model_ref, model)
  })
  client.dispatch(runtime)(Increment)
  test_ref.get(model_ref).count
  |> should.equal(1)
}

// =============================================================================
// CONNECTION STATUS
// =============================================================================

@target(javascript)
pub fn client_connection_status_tracks_connect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let _runtime =
    client.connection_status(
      runtime,
      get: fn(model) { model.connected },
      set: fn(model, status) { test_fixtures.Model(..model, connected: status) },
    )

  let reconnect_ref = test_ref.new(False)
  let connector = fn(handler: transport.Handler) {
    handler.on_reconnect()
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  }
  let _runtime2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  client.get_current_model(runtime).connected
  |> should.be_true
  let _ = reconnect_ref
}

@target(javascript)
pub fn client_connection_status_tracks_disconnect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let _runtime =
    client.connection_status(
      runtime,
      get: fn(model) { model.connected },
      set: fn(model, status) { test_fixtures.Model(..model, connected: status) },
    )

  let connector = fn(handler: transport.Handler) {
    handler.on_reconnect()
    handler.on_disconnect()
    transport.new(send: fn(_) { Nil }, close: fn() { Nil })
  }
  let _runtime2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  client.get_current_model(runtime).connected
  |> should.be_false
}

// =============================================================================
// CONNECT — TRANSPORT INTEGRATION
// =============================================================================

@target(javascript)
pub fn client_connect_sends_client_message_on_dispatch_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let sent_ref: test_ref.Ref(List(BitArray)) = test_ref.new([])
  let connector = fn(_handler: transport.Handler) {
    transport.new(
      send: fn(bytes) {
        test_ref.set(sent_ref, [bytes, ..test_ref.get(sent_ref)])
      },
      close: fn() { Nil },
    )
  }

  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  client.dispatch(runtime)(Increment)

  let sent = test_ref.get(sent_ref)
  sent
  |> should.not_equal([])
  case sent {
    [msg, ..] ->
      case bit_array.to_string(msg) {
        Ok(text) -> text |> string.contains("client_message") |> should.be_true
        Error(_) -> should.fail()
      }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn client_connect_sends_resync_on_reconnect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let sent_ref: test_ref.Ref(List(BitArray)) = test_ref.new([])
  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )

  let connector = fn(handler: transport.Handler) {
    test_ref.set(handler_ref, handler)
    transport.new(
      send: fn(bytes) {
        test_ref.set(sent_ref, [bytes, ..test_ref.get(sent_ref)])
      },
      close: fn() { Nil },
    )
  }

  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  let handler = test_ref.get(handler_ref)
  handler.on_reconnect()

  let sent = test_ref.get(sent_ref)
  sent
  |> should.not_equal([])
  case sent {
    [msg, ..] ->
      case bit_array.to_string(msg) {
        Ok(text) -> text |> string.contains("resync") |> should.be_true
        Error(_) -> should.fail()
      }
    [] -> should.fail()
  }
}
