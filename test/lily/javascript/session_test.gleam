// Tests for lily/session — localStorage session persistence.
// All functions are @target(javascript) — skipped on Erlang.

@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/json
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/session
@target(javascript)
import lily/store
@target(javascript)
import lily/test_fixtures.{type Model, type Message}
@target(javascript)
import lily/test_setup

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn new_runtime() -> client.Runtime(Model, Message) {
  store.new(test_fixtures.initial_model(), with: test_fixtures.update)
  |> client.start
}

/// Persistence that tracks the `name` field in localStorage.
@target(javascript)
fn name_persistence() -> session.Persistence(Model) {
  session.persistence()
  |> session.field(
    key: "name",
    get: fn(model: Model) { model.name },
    set: fn(model: Model, value) { test_fixtures.Model(..model, name: value) },
    encode: json.string,
    decoder: decode.string,
  )
}

// =============================================================================
// PERSISTENCE BUILDER
// =============================================================================

@target(javascript)
pub fn session_persistence_creates_empty_test() {
  test_setup.reset_dom()
  // Should not crash
  let p = session.persistence()
  let _ = p
  True
  |> should.be_true
}

@target(javascript)
pub fn session_field_adds_field_test() {
  test_setup.reset_dom()
  // Adding a field to a Persistence should not crash
  let p =
    session.persistence()
    |> session.field(
      key: "name",
      get: fn(model: Model) { model.name },
      set: fn(model, value) { test_fixtures.Model(..model, name: value) },
      encode: json.string,
      decoder: decode.string,
    )
  let _ = p
  True
  |> should.be_true
}

// =============================================================================
// ATTACH AND HYDRATE
// =============================================================================

@target(javascript)
pub fn session_attach_with_empty_localstorage_test() {
  test_setup.reset_dom()
  let runtime = new_runtime()
  let _r =
    session.attach(
      runtime,
      persistence: name_persistence(),
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // No keys in localStorage — model unchanged
  client.get_current_model(runtime).name
  |> should.equal("")
}

@target(javascript)
pub fn session_attach_hydrates_from_localstorage_test() {
  test_setup.reset_dom()
  // Pre-populate localStorage with a serialised name
  write_local_storage("lily_session_name", json.to_string(json.string("Alice")))
  let runtime = new_runtime()
  let _r =
    session.attach(
      runtime,
      persistence: name_persistence(),
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // Should have hydrated "Alice" from localStorage
  client.get_current_model(runtime).name
  |> should.equal("Alice")
}

@target(javascript)
pub fn session_attach_with_invalid_json_test() {
  test_setup.reset_dom()
  // Corrupted data — should be gracefully ignored
  write_local_storage("lily_session_name", "not-valid-json{{")
  let runtime = new_runtime()
  let _r =
    session.attach(
      runtime,
      persistence: name_persistence(),
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // Invalid JSON ignored — name stays as initial ""
  client.get_current_model(runtime).name
  |> should.equal("")
}

// =============================================================================
// CLEAR
// =============================================================================

@target(javascript)
pub fn session_clear_removes_prefixed_keys_test() {
  test_setup.reset_dom()
  // Write some session keys and a non-session key
  write_local_storage("lily_session_name", json.to_string(json.string("Bob")))
  write_local_storage("lily_session_token", json.to_string(json.string("xyz")))
  write_local_storage("other_key", "should-stay")
  // Clear lily_session_ keys
  session.clear()
  // Session keys should be gone
  read_local_storage("lily_session_name")
  |> should.equal("")
  read_local_storage("lily_session_token")
  |> should.equal("")
  // Non-session key should remain
  read_local_storage("other_key")
  |> should.not_equal("")
}

@target(javascript)
pub fn session_clear_leaves_non_session_keys_test() {
  test_setup.reset_dom()
  write_local_storage("lily_session_name", json.to_string(json.string("Eve")))
  write_local_storage("unrelated", "keep-me")
  session.clear()
  // Non-session key preserved
  read_local_storage("unrelated")
  |> should.equal("keep-me")
}

// =============================================================================
// PRIVATE FFI HELPERS
// =============================================================================

@target(javascript)
@external(javascript, "./session_test.ffi.mjs", "writeLocalStorage")
fn write_local_storage(_key: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./session_test.ffi.mjs", "readLocalStorage")
fn read_local_storage(_key: String) -> String {
  ""
}
