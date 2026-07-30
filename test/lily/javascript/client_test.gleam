// Tests for lily/client, JavaScript runtime lifecycle.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/list
@target(javascript)
import gleam/result
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
import lily/test_support.{
  type Message, type Model, Increment, Model, Noop, SetName,
}
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn uri_path(u: Uri) -> String {
  u.path
}

@target(javascript)
fn history_length() -> Int {
  test_support.history_length()
}

@target(javascript)
fn connect_with_fake_transport(
  runtime: client.Runtime(Model, Message),
) -> transport.Handler {
  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r = client.connect(runtime, with: connector)
  test_support.get(handler_ref)
}

@target(javascript)
fn send_version(handler: transport.Handler, hash: String) -> Nil {
  handler.on_receive(transport.encode(
    transport.Version(hash:),
    serialiser: test_support.custom_serialiser(),
  ))
}

@target(javascript)
fn dev_reload_message(changed: List(String)) -> String {
  let paths = list.map(changed, fn(path) { "\"" <> path <> "\"" })
  "{\"changed\":[" <> string.join(paths, ",") <> "]}"
}

// =============================================================================
// RUNTIME LIFECYCLE
// =============================================================================

@target(javascript)
pub fn client_start_preserves_initial_model_test() {
  test_support.reset_dom()
  let runtime =
    store.new(test_support.initial_model(), with: test_support.update)
    |> client.start(
      store.wiring(),
      serialiser: test_support.custom_serialiser(),
    )
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
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime =
    store.new(test_support.initial_model(), with: test_support.update)
    |> client.start(
      store.wiring(),
      serialiser: test_support.custom_serialiser(),
    )
  client.get_current_model(runtime)
  |> should.equal(test_support.initial_model())
}

// =============================================================================
// DISPATCH
// =============================================================================

@target(javascript)
pub fn client_dispatch_multiple_messages_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let d = client.dispatch(runtime)
  d(Increment)
  d(Increment)
  d(Increment)
  client.get_current_model(runtime).count
  |> should.equal(3)
}

@target(javascript)
pub fn client_dispatch_returns_function_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let d = client.dispatch(runtime)
  d(Noop)
  True
  |> should.be_true
}

@target(javascript)
pub fn client_dispatch_set_name_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  client.dispatch(runtime)(SetName("Alice"))
  client.get_current_model(runtime).name
  |> should.equal("Alice")
}

@target(javascript)
pub fn client_dispatch_updates_model_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
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
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let returned = client.on_message(runtime, fn(_message, _model) { Nil })
  client.get_current_model(returned).count
  |> should.equal(0)
}

@target(javascript)
pub fn client_on_message_hook_fires_for_local_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let ref = test_support.new(False)
  client.on_message(runtime, fn(message, _model) {
    case message {
      Increment -> test_support.set(ref, True)
      _ -> Nil
    }
  })
  client.dispatch(runtime)(Increment)
  test_support.get(ref)
  |> should.be_true
}

@target(javascript)
pub fn client_on_message_hook_receives_model_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let model_ref = test_support.new(test_support.initial_model())
  client.on_message(runtime, fn(_message, model) {
    test_support.set(model_ref, model)
  })
  client.dispatch(runtime)(Increment)
  test_support.get(model_ref).count
  |> should.equal(1)
}

// =============================================================================
// CONNECTION STATUS
// =============================================================================

@target(javascript)
pub fn client_connection_status_tracks_connect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let _runtime =
    client.connection_status(runtime, set: fn(model, status) {
      test_support.Model(..model, connected: status)
    })

  let reconnect_ref = test_support.new(False)
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      handler.on_reconnect()
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _runtime2 = client.connect(runtime, with: connector)

  client.get_current_model(runtime).connected
  |> should.be_true
  let _ = reconnect_ref
}

@target(javascript)
pub fn client_connection_status_tracks_disconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let _runtime =
    client.connection_status(runtime, set: fn(model, status) {
      test_support.Model(..model, connected: status)
    })

  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      handler.on_reconnect()
      handler.on_disconnect()
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _runtime2 = client.connect(runtime, with: connector)

  client.get_current_model(runtime).connected
  |> should.be_false
}

// =============================================================================
// URL / NAVIGATE / REPLACE
// =============================================================================

@target(javascript)
pub fn client_url_setter_fires_on_attach_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let runtime = test_support.new_runtime()
  let captured: test_support.Ref(List(String)) = test_support.new([])

  let _r =
    client.url(runtime, set: fn(model, uri) {
      test_support.set(captured, [uri |> uri_path, ..test_support.get(captured)])
      model
    })

  test_support.get(captured) |> should.equal(["/"])
}

@target(javascript)
pub fn client_navigate_pushes_history_and_fires_setter_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let runtime = test_support.new_runtime()
  let captured: test_support.Ref(List(String)) = test_support.new([])

  let _r =
    client.url(runtime, set: fn(model, uri) {
      test_support.set(captured, [uri |> uri_path, ..test_support.get(captured)])
      model
    })

  client.navigate(runtime, "/projects/42")

  test_support.get(captured)
  |> list.reverse
  |> should.equal(["/", "/projects/42"])
}

@target(javascript)
pub fn client_replace_does_not_push_history_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let runtime = test_support.new_runtime()
  let captured: test_support.Ref(List(String)) = test_support.new([])

  let _r =
    client.url(runtime, set: fn(model, uri) {
      test_support.set(captured, [uri |> uri_path, ..test_support.get(captured)])
      model
    })

  let history_before = history_length()
  client.replace(runtime, "/projects?sort=newest")
  let history_after = history_length()

  history_before |> should.equal(history_after)
  test_support.get(captured)
  |> list.reverse
  |> should.equal(["/", "/projects"])
}

// =============================================================================
// HYDRATE
// =============================================================================

@target(javascript)
pub fn client_hydrate_uses_embedded_snapshot_test() {
  test_support.reset_dom()
  // Build a snapshot whose model differs from the store's initial model
  // so we can prove hydrate read from the embed and not the store.
  let server_rendered_model =
    test_support.Model(..test_support.initial_model(), count: 7, name: "Hi")
  let frame_bytes =
    transport.encode(
      transport.Snapshot(
        target: transport.Session,
        sequence: 0,
        state: server_rendered_model,
      ),
      serialiser: test_support.custom_serialiser(),
    )
  let assert Ok(json_text) = bit_array.to_string(frame_bytes)
  test_support.inject_snapshot_script(json_text)

  let runtime =
    store.new(test_support.initial_model(), with: test_support.update)
    |> client.start(
      wiring: store.wiring(),
      serialiser: test_support.custom_serialiser(),
    )

  let model = client.get_current_model(runtime)
  model.count |> should.equal(7)
  model.name |> should.equal("Hi")
}

@target(javascript)
pub fn client_hydrate_falls_back_to_store_when_snapshot_missing_test() {
  test_support.reset_dom()
  // No lily-snapshot script in the DOM, hydrate should silently use the
  // store's initial model.
  let runtime =
    store.new(test_support.initial_model(), with: test_support.update)
    |> client.start(
      wiring: store.wiring(),
      serialiser: test_support.custom_serialiser(),
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
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r = client.connect(runtime, with: connector)

  // Server dispatches Increment to this client's session
  let handler = test_support.get(handler_ref)
  let frame =
    transport.encode(
      transport.SessionUpdate(sequence: 1, payload: Increment),
      serialiser: test_support.custom_serialiser(),
    )
  handler.on_receive(frame)

  client.get_current_model(runtime).count |> should.equal(1)
}

// =============================================================================
// ON-LIFECYCLE HOOKS
// =============================================================================

@target(javascript)
pub fn client_on_connect_fires_on_first_connected_frame_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let captured: test_support.Ref(List(String)) = test_support.new([])
  let _r =
    client.on_connect(runtime, fn(client_id) {
      test_support.set(captured, [client_id, ..test_support.get(captured)])
    })

  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 = client.connect(runtime, with: connector)

  // Simulate the server's Connected frame arriving on the transport
  let handler = test_support.get(handler_ref)
  let connected_frame =
    transport.encode(
      transport.Connected(client_id: "c1"),
      serialiser: test_support.custom_serialiser(),
    )
  handler.on_receive(connected_frame)

  test_support.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn client_on_connect_does_not_fire_twice_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let captured: test_support.Ref(List(String)) = test_support.new([])
  let _r =
    client.on_connect(runtime, fn(client_id) {
      test_support.set(captured, [client_id, ..test_support.get(captured)])
    })

  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 = client.connect(runtime, with: connector)

  let handler = test_support.get(handler_ref)
  let connected_frame =
    transport.encode(
      transport.Connected(client_id: "c1"),
      serialiser: test_support.custom_serialiser(),
    )
  handler.on_receive(connected_frame)
  handler.on_receive(connected_frame)

  test_support.get(captured) |> should.equal(["c1"])
}

@target(javascript)
pub fn client_on_reconnect_does_not_fire_on_first_connect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let fired: test_support.Ref(Int) = test_support.new(0)
  let _r =
    client.on_reconnect(runtime, fn() {
      test_support.set(fired, test_support.get(fired) + 1)
    })

  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      handler.on_reconnect()
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 = client.connect(runtime, with: connector)

  test_support.get(fired) |> should.equal(0)
}

@target(javascript)
pub fn client_on_reconnect_fires_after_first_connected_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let fired: test_support.Ref(Int) = test_support.new(0)
  let _r =
    client.on_reconnect(runtime, fn() {
      test_support.set(fired, test_support.get(fired) + 1)
    })

  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 = client.connect(runtime, with: connector)

  // Deliver Connected so the runtime considers itself attached
  let handler = test_support.get(handler_ref)
  let connected_frame =
    transport.encode(
      transport.Connected(client_id: "c1"),
      serialiser: test_support.custom_serialiser(),
    )
  handler.on_receive(connected_frame)

  // Now a transport-level reconnect should fire the user hook
  handler.on_reconnect()
  handler.on_reconnect()

  test_support.get(fired) |> should.equal(2)
}

@target(javascript)
pub fn client_on_disconnect_fires_on_every_drop_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let fired: test_support.Ref(Int) = test_support.new(0)
  let _r =
    client.on_disconnect(runtime, fn() {
      test_support.set(fired, test_support.get(fired) + 1)
    })

  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )
  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(send: fn(_) { Nil }, close: fn() { Nil })
    })
  let _r2 = client.connect(runtime, with: connector)

  let handler = test_support.get(handler_ref)
  handler.on_disconnect()
  handler.on_disconnect()

  test_support.get(fired) |> should.equal(2)
}

// =============================================================================
// CONNECT, TRANSPORT INTEGRATION
// =============================================================================

@target(javascript)
pub fn client_connect_sends_client_message_on_dispatch_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let sent_ref: test_support.Ref(List(BitArray)) = test_support.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_support.set(sent_ref, [bytes, ..test_support.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r = client.connect(runtime, with: connector)

  client.dispatch(runtime)(Increment)

  let sent = test_support.get(sent_ref)
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
  test_support.reset_dom()
  test_support.reset_mocks()

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
    store.new(test_support.initial_model(), with: test_support.update)
    |> client.start(wiring, serialiser: test_support.custom_serialiser())

  let sent_ref: test_support.Ref(List(BitArray)) = test_support.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_support.set(sent_ref, [bytes, ..test_support.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r = client.connect(runtime, with: connector)

  client.dispatch(runtime)(Increment)

  // The most-recently-sent frame should be a topic_message (the chat
  // topic caught Increment), not a session_message.
  let sent = test_support.get(sent_ref)
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
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let sent_ref: test_support.Ref(List(BitArray)) = test_support.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_support.set(sent_ref, [bytes, ..test_support.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r = client.connect(runtime, with: connector)

  let _r2 = client.subscribe(runtime, "chat")

  let sent = test_support.get(sent_ref)
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
pub fn client_dispatch_topic_kind_sends_concrete_instance_id_test() {
  // A parametric topic_kind routes an outgoing message to the concrete
  // instance id (prefix plus the key carried in the message), so the server
  // can reach the right instance actor even with several joined at once.
  test_support.reset_dom()
  test_support.reset_mocks()

  let wiring =
    store.wiring()
    |> store.topic_kind(
      prefix: "room:",
      extract: fn(_message) { Ok(#("42", Nil)) },
      update: fn(model: Model, _inner: Nil) { model },
      field_get: fn(model: Model, _key) { model },
      field_set: fn(_model, _key, m) { m },
    )

  let runtime =
    store.new(test_support.initial_model(), with: test_support.update)
    |> client.start(wiring, serialiser: test_support.custom_serialiser())

  let sent_ref: test_support.Ref(List(BitArray)) = test_support.new([])
  let connector =
    transport.make_connector(fn(_handler: transport.Handler) {
      transport.new(
        send: fn(bytes) {
          test_support.set(sent_ref, [bytes, ..test_support.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r = client.connect(runtime, with: connector)

  client.dispatch(runtime)(Increment)

  let sent = test_support.get(sent_ref)
  case sent {
    [bytes, ..] ->
      case bit_array.to_string(bytes) {
        Ok(text) -> {
          text |> string.contains("topic_message") |> should.be_true
          text |> string.contains("\"topic_id\":\"room:42\"") |> should.be_true
        }
        Error(_) -> should.fail()
      }
    [] -> should.fail()
  }
}

@target(javascript)
pub fn client_connect_sends_resync_on_reconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let sent_ref: test_support.Ref(List(BitArray)) = test_support.new([])
  let handler_ref: test_support.Ref(transport.Handler) =
    test_support.new(
      transport.Handler(
        on_receive: fn(_) { Nil },
        on_reconnect: fn() { Nil },
        on_disconnect: fn() { Nil },
      ),
    )

  let connector =
    transport.make_connector(fn(handler: transport.Handler) {
      test_support.set(handler_ref, handler)
      transport.new(
        send: fn(bytes) {
          test_support.set(sent_ref, [bytes, ..test_support.get(sent_ref)])
        },
        close: fn() { Nil },
      )
    })

  let _r = client.connect(runtime, with: connector)

  let handler = test_support.get(handler_ref)
  handler.on_reconnect()

  let sent = test_support.get(sent_ref)
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

// =============================================================================
// ON VERSION MISMATCH
// =============================================================================

@target(javascript)
pub fn client_on_version_mismatch_ignores_first_frame_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let fired: test_support.Ref(Int) = test_support.new(0)
  let _r =
    client.on_version_mismatch(runtime, fn() {
      test_support.set(fired, test_support.get(fired) + 1)
    })

  let handler = connect_with_fake_transport(runtime)
  send_version(handler, "v1")

  test_support.get(fired) |> should.equal(0)
}

@target(javascript)
pub fn client_on_version_mismatch_fires_when_hash_changes_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let fired: test_support.Ref(Int) = test_support.new(0)
  let _r =
    client.on_version_mismatch(runtime, fn() {
      test_support.set(fired, test_support.get(fired) + 1)
    })

  let handler = connect_with_fake_transport(runtime)
  send_version(handler, "v1")
  send_version(handler, "v2")

  test_support.get(fired) |> should.equal(1)
}

@target(javascript)
pub fn client_on_version_mismatch_does_not_fire_when_hash_unchanged_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime()

  let fired: test_support.Ref(Int) = test_support.new(0)
  let _r =
    client.on_version_mismatch(runtime, fn() {
      test_support.set(fired, test_support.get(fired) + 1)
    })

  let handler = connect_with_fake_transport(runtime)
  send_version(handler, "v1")
  send_version(handler, "v1")

  test_support.get(fired) |> should.equal(0)
}

// =============================================================================
// ENABLE HOT RELOAD
// =============================================================================

@target(javascript)
pub fn client_enable_hot_reload_stashes_and_reloads_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  test_support.reset_hot_reload_installed()
  let runtime = test_support.new_runtime()

  let _r = client.enable_hot_reload(runtime)
  let ws = test_support.get_last_websocket()
  test_support.trigger_websocket_message(ws, dev_reload_message(["shared"]))

  // Every rebuild stashes the live model then reloads, the stash is the only
  // observable trace since jsdom's location.reload() is a silent no-op.
  test_support.read_session_storage("lily_dev_reload_state")
  |> string.contains("\"count\":0")
  |> should.be_true
}

// =============================================================================
// RECOVER AFTER RELOAD
// =============================================================================

@target(javascript)
pub fn client_recover_after_reload_merges_matching_primitives_test() {
  test_support.reset_dom()
  test_support.write_session_storage(
    "lily_dev_reload_state",
    "{\"count\":99,\"name\":\"Stashed\",\"connected\":true,\"secondary_count\":7,\"active_tab\":{\"unexpected\":\"shape\"}}",
  )

  let recovered = client.recover_after_reload(test_support.initial_model())

  recovered.count |> should.equal(99)
  recovered.name |> should.equal("Stashed")
  recovered.connected |> should.equal(True)
  recovered.secondary_count |> should.equal(7)
  // Not a primitive in the stash, so it falls back to the fresh model's value
  // rather than adopting an untyped plain object.
  recovered.active_tab |> should.equal(test_support.TabA)
}

@target(javascript)
pub fn client_recover_after_reload_clears_the_stash_test() {
  test_support.reset_dom()
  test_support.write_session_storage("lily_dev_reload_state", "{\"count\":1}")

  let _r = client.recover_after_reload(test_support.initial_model())

  test_support.read_session_storage("lily_dev_reload_state") |> should.equal("")
}

@target(javascript)
pub fn client_recover_after_reload_is_noop_without_a_stash_test() {
  test_support.reset_dom()

  client.recover_after_reload(test_support.initial_model())
  |> should.equal(test_support.initial_model())
}

@target(javascript)
pub fn client_recover_after_reload_migrate_hook_takes_over_test() {
  test_support.reset_dom()
  test_support.write_session_storage(
    "lily_dev_reload_state",
    "{\"renamed_count\":42,\"name\":\"Ignored\"}",
  )

  let migrate = fn(stashed, initial: Model) {
    let count =
      decode.run(stashed, decode.at(["renamed_count"], decode.int))
      |> result.unwrap(initial.count)
    Model(..initial, count:)
  }

  let recovered =
    client.recover_after_reload_migrate(test_support.initial_model(), migrate)

  // The hook decided everything, a renamed field it knows to look for
  // survives, and it never touched name, so that stays at the fresh value.
  recovered.count |> should.equal(42)
  recovered.name |> should.equal("")
}
