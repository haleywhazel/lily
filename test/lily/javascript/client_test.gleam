// Tests for lily/client, JavaScript runtime lifecycle.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import gleam/uri.{type Uri}
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/store
@target(javascript)
import lily/test_fixtures.{type Message, type Model, Increment, Noop, SetName}
@target(javascript)
import lily/test_ref
@target(javascript)
import lily/test_setup
@target(javascript)
import lily/transport

@target(javascript)
fn uri_path(u: Uri) -> String {
  u.path
}

@target(javascript)
fn history_length() -> Int {
  test_setup.history_length()
}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start(store.wiring())
}

// =============================================================================
// RUNTIME LIFECYCLE
// =============================================================================

@target(javascript)
pub fn client_start_preserves_initial_model_test() {
  test_setup.reset_dom()
  let runtime =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.start(store.wiring())
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
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.start(store.wiring())
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
pub fn client_on_message_returns_runtime_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let returned = client.on_message(runtime, fn(_message, _model) { Nil })
  client.get_current_model(returned).count
  |> should.equal(0)
}

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
    client.connection_status(runtime, set: fn(model, status) {
      test_fixtures.Model(..model, connected: status)
    })

  let reconnect_ref = test_ref.new(False)
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      handler.on_reconnect()
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
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
    client.connection_status(runtime, set: fn(model, status) {
      test_fixtures.Model(..model, connected: status)
    })

  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      handler.on_reconnect()
      handler.on_disconnect()
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
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
// URL / NAVIGATE / REPLACE
// =============================================================================

@target(javascript)
pub fn client_url_setter_fires_on_attach_test() {
  test_setup.reset_dom()
  test_setup.reset_url()
  let runtime = new_runtime()
  let captured: test_ref.Ref(List(String)) = test_ref.new([])

  let _r =
    client.url(runtime, set: fn(model, uri) {
      test_ref.set(captured, [
        uri |> uri_path,
        ..test_ref.get(captured)
      ])
      model
    })

  test_ref.get(captured) |> should.equal(["/"])
}

@target(javascript)
pub fn client_navigate_pushes_history_and_fires_setter_test() {
  test_setup.reset_dom()
  test_setup.reset_url()
  let runtime = new_runtime()
  let captured: test_ref.Ref(List(String)) = test_ref.new([])

  let _r =
    client.url(runtime, set: fn(model, uri) {
      test_ref.set(captured, [
        uri |> uri_path,
        ..test_ref.get(captured)
      ])
      model
    })

  client.navigate(runtime, "/projects/42")

  test_ref.get(captured)
  |> list.reverse
  |> should.equal(["/", "/projects/42"])
}

@target(javascript)
pub fn client_replace_does_not_push_history_test() {
  test_setup.reset_dom()
  test_setup.reset_url()
  let runtime = new_runtime()
  let captured: test_ref.Ref(List(String)) = test_ref.new([])

  let _r =
    client.url(runtime, set: fn(model, uri) {
      test_ref.set(captured, [
        uri |> uri_path,
        ..test_ref.get(captured)
      ])
      model
    })

  let history_before = history_length()
  client.replace(runtime, "/projects?sort=newest")
  let history_after = history_length()

  history_before |> should.equal(history_after)
  test_ref.get(captured)
  |> list.reverse
  |> should.equal(["/", "/projects"])
}

// =============================================================================
// HYDRATE
// =============================================================================

@target(javascript)
pub fn client_hydrate_uses_embedded_snapshot_test() {
  test_setup.reset_dom()
  // Build a snapshot whose model differs from the store's initial model
  // so we can prove hydrate read from the embed and not the store.
  let server_rendered_model =
    test_fixtures.Model(..test_fixtures.initial_model(), count: 7, name: "Hi")
  let frame_bytes =
    transport.encode(
      transport.Snapshot(
        target: transport.Session,
        sequence: 0,
        state: server_rendered_model,
      ),
      serialiser: test_fixtures.custom_serialiser(),
    )
  let assert Ok(json_text) = bit_array.to_string(frame_bytes)
  test_setup.inject_snapshot_script(json_text)

  let runtime =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.hydrate(
      wiring: store.wiring(),
      serialiser: test_fixtures.custom_serialiser(),
    )

  let model = client.get_current_model(runtime)
  model.count |> should.equal(7)
  model.name |> should.equal("Hi")
}

@target(javascript)
pub fn client_hydrate_falls_back_to_store_when_snapshot_missing_test() {
  test_setup.reset_dom()
  // No lily-snapshot script in the DOM; hydrate should silently use the
  // store's initial model.
  let runtime =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.hydrate(
      wiring: store.wiring(),
      serialiser: test_fixtures.custom_serialiser(),
    )

  let model = client.get_current_model(runtime)
  model.count |> should.equal(0)
  model.name |> should.equal("")
}

// =============================================================================
// INBOUND SESSION-UPDATE
// =============================================================================

@target(javascript)
pub fn client_session_update_applies_to_session_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  // Server dispatches Increment to this client's session
  let handler = test_ref.get(handler_ref)
  let frame =
    transport.encode(
      transport.SessionUpdate(sequence: 1, payload: Increment),
      serialiser: test_fixtures.custom_serialiser(),
    )
  handler.on_receive(frame)

  client.get_current_model(runtime).count |> should.equal(1)
}

// =============================================================================
// ON-LIFECYCLE HOOKS
// =============================================================================

@target(javascript)
pub fn client_on_connect_fires_on_first_connected_frame_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let captured: test_ref.Ref(List(String)) = test_ref.new([])
  let _r =
    client.on_connect(runtime, fn(client_id) {
      test_ref.set(captured, [client_id, ..test_ref.get(captured)])
    })

  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  // Simulate the server's Connected frame arriving on the transport
  let handler = test_ref.get(handler_ref)
  let connected_frame =
    transport.encode(
      transport.Connected(client_id: "c1"),
      serialiser: test_fixtures.custom_serialiser(),
    )
  handler.on_receive(connected_frame)

  test_ref.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn client_on_connect_does_not_fire_twice_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let captured: test_ref.Ref(List(String)) = test_ref.new([])
  let _r =
    client.on_connect(runtime, fn(client_id) {
      test_ref.set(captured, [client_id, ..test_ref.get(captured)])
    })

  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  let handler = test_ref.get(handler_ref)
  let connected_frame =
    transport.encode(
      transport.Connected(client_id: "c1"),
      serialiser: test_fixtures.custom_serialiser(),
    )
  handler.on_receive(connected_frame)
  handler.on_receive(connected_frame)

  test_ref.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn client_on_reconnect_does_not_fire_on_first_connect_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let fired: test_ref.Ref(Int) = test_ref.new(0)
  let _r =
    client.on_reconnect(runtime, fn() {
      test_ref.set(fired, test_ref.get(fired) + 1)
    })

  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      handler.on_reconnect()
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  test_ref.get(fired) |> should.equal(0)
}

@target(javascript)
pub fn client_on_reconnect_fires_after_first_connected_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let fired: test_ref.Ref(Int) = test_ref.new(0)
  let _r =
    client.on_reconnect(runtime, fn() {
      test_ref.set(fired, test_ref.get(fired) + 1)
    })

  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  // Deliver Connected so the runtime considers itself attached
  let handler = test_ref.get(handler_ref)
  let connected_frame =
    transport.encode(
      transport.Connected(client_id: "c1"),
      serialiser: test_fixtures.custom_serialiser(),
    )
  handler.on_receive(connected_frame)

  // Now a transport-level reconnect should fire the user hook
  handler.on_reconnect()
  handler.on_reconnect()

  test_ref.get(fired) |> should.equal(2)
}

@target(javascript)
pub fn client_on_disconnect_fires_on_every_drop_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let fired: test_ref.Ref(Int) = test_ref.new(0)
  let _r =
    client.on_disconnect(runtime, fn() {
      test_ref.set(fired, test_ref.get(fired) + 1)
    })

  let handler_ref: test_ref.Ref(transport.Handler) =
    test_ref.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  let handler = test_ref.get(handler_ref)
  handler.on_disconnect()
  handler.on_disconnect()

  test_ref.get(fired) |> should.equal(2)
}

// =============================================================================
// CONNECT, TRANSPORT INTEGRATION
// =============================================================================

@target(javascript)
pub fn client_connect_sends_client_message_on_dispatch_test() {
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let sent_ref: test_ref.Ref(List(BitArray)) = test_ref.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_ref.set(sent_ref, [bytes, ..test_ref.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

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
    [bytes, ..] ->
      case bit_array.to_string(bytes) {
        Ok(text) -> text |> string.contains("session_message") |> should.be_true
        Error(_) -> should.fail()
      }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn client_dispatch_with_topic_wiring_sends_topic_message_test() {
  // Regression for the welcome example: a message routed to a topic
  // via the wiring must be sent as a TopicMessage on the wire (not a
  // SessionMessage), so the server's topic actor can broadcast it.
  test_setup.reset_dom()
  test_setup.reset_mocks()

  // Wiring with a topic that catches every message.
  let wiring =
    store.wiring()
    |> store.topic(
      id: "chat",
      extract: fn(_message) { Ok(Nil) },
      update: fn(model: Model, _inner: Nil) { model },
      field_get: fn(model: Model) { model },
      field_set: fn(_model, m) { m },
    )

  let runtime =
    store.new(test_fixtures.initial_model(), with: test_fixtures.update)
    |> client.start(wiring)

  let sent_ref: test_ref.Ref(List(BitArray)) = test_ref.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_ref.set(sent_ref, [bytes, ..test_ref.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  client.dispatch(runtime)(Increment)

  // The most-recently-sent frame should be a topic_message (the chat
  // topic caught Increment), not a session_message.
  let sent = test_ref.get(sent_ref)
  case sent {
    [bytes, ..] ->
      case bit_array.to_string(bytes) {
        Ok(text) -> {
          text |> string.contains("topic_message") |> should.be_true
          text |> string.contains("\"topic_id\":\"chat\"") |> should.be_true
        }
        Error(_) -> should.fail()
      }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn client_subscribe_sends_subscribe_frame_test() {
  // Regression: the welcome example's chat broadcast relies on the
  // Subscribe frame reaching the server. If subscribe were silently
  // dropped (sendFrameFn null, or transport not yet set), Tab B would
  // never register for "chat" and miss broadcasts.
  test_setup.reset_dom()
  test_setup.reset_mocks()
  let runtime = new_runtime()

  let sent_ref: test_ref.Ref(List(BitArray)) = test_ref.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_ref.set(sent_ref, [bytes, ..test_ref.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r =
    client.connect(
      runtime,
      with: connector,
      serialiser: test_fixtures.custom_serialiser(),
    )

  let _r2 = client.subscribe(runtime, "chat")

  let sent = test_ref.get(sent_ref)
  sent
  |> should.not_equal([])
  case sent {
    [bytes, ..] ->
      case bit_array.to_string(bytes) {
        Ok(text) -> text |> string.contains("subscribe") |> should.be_true
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

  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_ref.set(handler_ref, handler)
      transport.new(
        send: fn(bytes) {
          test_ref.set(sent_ref, [bytes, ..test_ref.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

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
    [bytes, ..] ->
      case bit_array.to_string(bytes) {
        Ok(text) -> text |> string.contains("resync") |> should.be_true
        Error(_) -> should.fail()
      }
    [] -> should.fail()
  }
}
