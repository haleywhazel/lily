// Tests for client session persistence, localStorage session persistence.
// All functions are @target(javascript), skipped on Erlang.

@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/json
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/client
@target(javascript)
import lily/test_support.{type Model}

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
/// Persistence that tracks the `name` field in localStorage.
fn name_persistence() -> client.Persistence(Model) {
  client.session_persistence()
  |> client.session_field(
    key: "name",
    get: fn(model: Model) { model.name },
    set: fn(model: Model, value) { test_support.Model(..model, name: value) },
    encode: json.string,
    decoder: decode.string,
  )
}

// =============================================================================
// ATTACH AND HYDRATE
// =============================================================================

@target(javascript)
pub fn session_attach_with_empty_localstorage_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _r =
    client.attach_session(
      runtime,
      persistence: name_persistence(),
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // No keys in localStorage, model unchanged
  client.get_current_model(runtime).name
  |> should.equal("")
}

@target(javascript)
pub fn session_attach_hydrates_from_localstorage_test() {
  test_support.reset_dom()
  // Pre-populate localStorage with a serialised name
  test_support.write_local_storage(
    "lily_session_name",
    json.to_string(json.string("Alice")),
  )
  let runtime = test_support.new_runtime()
  let _r =
    client.attach_session(
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
  test_support.reset_dom()
  // Corrupted data, should be gracefully ignored
  test_support.write_local_storage("lily_session_name", "not-valid-json{{")
  let runtime = test_support.new_runtime()
  let _r =
    client.attach_session(
      runtime,
      persistence: name_persistence(),
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // Invalid JSON ignored, name stays as initial ""
  client.get_current_model(runtime).name
  |> should.equal("")
}

// =============================================================================
// PER-FIELD DIFF
// =============================================================================

@target(javascript)
pub fn session_only_writes_changed_fields_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let persistence =
    client.session_persistence()
    |> client.session_field(
      key: "name",
      get: fn(m: Model) { m.name },
      set: fn(m: Model, v) { test_support.Model(..m, name: v) },
      encode: json.string,
      decoder: decode.string,
    )
    |> client.session_field(
      key: "count",
      get: fn(m: Model) { m.count },
      set: fn(m: Model, v) { test_support.Model(..m, count: v) },
      encode: json.int,
      decoder: decode.int,
    )
  let _r =
    client.attach_session(
      runtime,
      persistence: persistence,
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // Dispatch SetName, changes name, does NOT change count
  client.dispatch(runtime)(test_support.SetName("Alice"))
  // name was changed, so it should be persisted
  test_support.read_local_storage("lily_session_name")
  |> should.not_equal("")
  // count was unchanged, so it should NOT be written
  test_support.read_local_storage("lily_session_count")
  |> should.equal("")
}

@target(javascript)
pub fn session_skips_write_when_field_unchanged_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let persistence =
    client.session_persistence()
    |> client.session_field(
      key: "name",
      get: fn(m: Model) { m.name },
      set: fn(m: Model, v) { test_support.Model(..m, name: v) },
      encode: json.string,
      decoder: decode.string,
    )
  let _r =
    client.attach_session(
      runtime,
      persistence: persistence,
      get: fn(m) { m },
      set: fn(_model, session) { session },
    )
  // First dispatch writes the field
  client.dispatch(runtime)(test_support.SetName("Alice"))
  let after_first = test_support.read_local_storage("lily_session_name")
  // Second dispatch with same value, field unchanged, no re-write
  client.dispatch(runtime)(test_support.SetName("Alice"))
  let after_second = test_support.read_local_storage("lily_session_name")
  // Both reads should equal the same value ("Alice"), the key was set
  after_first
  |> should.equal(after_second)
}

// =============================================================================
// CLEAR
// =============================================================================

@target(javascript)
pub fn session_clear_removes_prefixed_keys_test() {
  test_support.reset_dom()
  // Write some session keys and a non-session key
  test_support.write_local_storage(
    "lily_session_name",
    json.to_string(json.string("Bob")),
  )
  test_support.write_local_storage(
    "lily_session_token",
    json.to_string(json.string("xyz")),
  )
  test_support.write_local_storage("other_key", "should-stay")
  // Clear lily_session_ keys
  client.clear_session()
  // Session keys should be gone
  test_support.read_local_storage("lily_session_name")
  |> should.equal("")
  test_support.read_local_storage("lily_session_token")
  |> should.equal("")
  // Non-session key should remain
  test_support.read_local_storage("other_key")
  |> should.not_equal("")
}

@target(javascript)
pub fn session_clear_leaves_non_session_keys_test() {
  test_support.reset_dom()
  test_support.write_local_storage(
    "lily_session_name",
    json.to_string(json.string("Eve")),
  )
  test_support.write_local_storage("unrelated", "keep-me")
  client.clear_session()
  // Non-session key preserved
  test_support.read_local_storage("unrelated")
  |> should.equal("keep-me")
}
// =============================================================================
// PRIVATE FFI HELPERS
// =============================================================================
