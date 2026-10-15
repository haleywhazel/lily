// lily/browser tests, all @target(javascript), skipped on Erlang

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/json
@target(javascript)
import gleam/list
@target(javascript)
import gleam/string
@target(javascript)
import gleam/uri.{type Uri}
@target(javascript)
import gleeunit/should
@target(javascript)
import lily/browser
@target(javascript)
import lily/client
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{type Message, type Model, Model}
@target(javascript)
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
fn dev_reload_message(changed: List(String)) -> String {
  let paths = list.map(changed, fn(path) { "\"" <> path <> "\"" })
  "{\"changed\":[" <> string.join(paths, ",") <> "]}"
}

@target(javascript)
/// Url setter records each path, newest first.
fn path_recording_runtime() -> #(
  client.Runtime(Model, Message, store.Synced),
  test_support.Ref(List(String)),
) {
  let captured: test_support.Ref(List(String)) = test_support.new([])
  let runtime =
    test_support.new_runtime()
    |> browser.url(set: fn(model, uri: Uri) {
      test_support.set(captured, [uri.path, ..test_support.get(captured)])
      model
    })
  #(runtime, captured)
}

@target(javascript)
fn name_field() -> browser.PersistedField(Model) {
  browser.persisted_field(
    key: "name",
    encode: json.string,
    decode: decode.string,
    get: fn(model: Model) { model.name },
    set: fn(model: Model, value) { Model(..model, name: value) },
  )
}

@target(javascript)
fn count_field() -> browser.PersistedField(Model) {
  browser.persisted_field(
    key: "count",
    encode: json.int,
    decode: decode.int,
    get: fn(model: Model) { model.count },
    set: fn(model: Model, value) { Model(..model, count: value) },
  )
}

@target(javascript)
fn send_version(handler: transport.Handler, hash: String) -> Nil {
  handler.received(transport.encode(
    transport.Version(hash:),
    serialiser: test_support.custom_serialiser(),
  ))
}

// =============================================================================
// URL, NAVIGATE AND REPLACE
// =============================================================================

@target(javascript)
pub fn browser_url_setter_fires_on_attach_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let #(_runtime, captured) = path_recording_runtime()

  test_support.get(captured) |> should.equal(["/"])
}

@target(javascript)
pub fn browser_url_setter_updates_the_model_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let runtime =
    test_support.new_runtime()
    |> browser.url(set: fn(model, uri: Uri) { Model(..model, name: uri.path) })

  client.model(runtime).name |> should.equal("/")
  browser.navigate("/projects/42")
  client.model(runtime).name |> should.equal("/projects/42")
}

@target(javascript)
pub fn browser_navigate_pushes_history_and_fires_setter_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let #(_runtime, captured) = path_recording_runtime()

  let history_before = test_support.history_length()
  browser.navigate("/projects/42")

  test_support.history_length() |> should.equal(history_before + 1)
  test_support.get(captured)
  |> list.reverse
  |> should.equal(["/", "/projects/42"])
}

@target(javascript)
pub fn browser_replace_does_not_push_history_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let #(_runtime, captured) = path_recording_runtime()

  let history_before = test_support.history_length()
  browser.replace("/projects?sort=newest")

  test_support.history_length() |> should.equal(history_before)
  test_support.get(captured)
  |> list.reverse
  |> should.equal(["/", "/projects"])
}

@target(javascript)
pub fn browser_url_setter_fires_on_popstate_test() {
  test_support.reset_dom()
  test_support.reset_url()
  let #(_runtime, captured) = path_recording_runtime()
  browser.navigate("/one")
  browser.navigate("/two")

  test_support.popstate_to("/one")

  test_support.get(captured)
  |> list.first
  |> should.equal(Ok("/one"))
}

@target(javascript)
pub fn browser_load_leaves_the_app_test() {
  test_support.reset_dom()
  let before = test_support.navigation_count()

  browser.load("/logout")

  test_support.navigation_count() |> should.equal(before + 1)
}

@target(javascript)
pub fn browser_reload_reloads_the_page_test() {
  test_support.reset_dom()
  let before = test_support.navigation_count()

  browser.reload()

  test_support.navigation_count() |> should.equal(before + 1)
}

// =============================================================================
// INTERCEPT LINKS
// =============================================================================

@target(javascript)
pub fn browser_intercept_links_navigates_internal_links_test() {
  test_support.reset_dom()
  test_support.drop_document_click_listeners()
  test_support.reset_url()
  test_support.set_inner_html(
    "#app",
    "<a id=\"link\" href=\"/docs/intro?x=1\">Docs</a>",
  )
  let #(runtime, captured) = path_recording_runtime()
  let _runtime = browser.intercept_links(runtime)

  test_support.click_prevented("#link") |> should.be_true

  test_support.get(captured)
  |> list.first
  |> should.equal(Ok("/docs/intro"))
}

@target(javascript)
pub fn browser_intercept_links_skips_the_opt_out_attribute_test() {
  test_support.reset_dom()
  test_support.drop_document_click_listeners()
  test_support.reset_url()
  test_support.set_inner_html(
    "#app",
    "<a id=\"link\" href=\"/docs\" data-lily-native>Docs</a>",
  )
  let #(runtime, captured) = path_recording_runtime()
  let _runtime = browser.intercept_links(runtime)

  test_support.click_prevented("#link") |> should.be_false

  test_support.get(captured) |> should.equal(["/"])
}

@target(javascript)
pub fn browser_intercept_links_with_uses_its_own_opt_out_test() {
  test_support.reset_dom()
  test_support.drop_document_click_listeners()
  test_support.reset_url()
  test_support.set_inner_html(
    "#app",
    "<a id=\"native\" href=\"/a\" data-external>A</a>"
      <> "<a id=\"warm\" href=\"/b\" data-lily-native>B</a>",
  )
  let #(runtime, _captured) = path_recording_runtime()
  let _runtime =
    browser.intercept_links_with(
      runtime,
      within: "#app",
      opt_out_attribute: "data-external",
    )

  test_support.click_prevented("#native") |> should.be_false
  test_support.click_prevented("#warm") |> should.be_true
}

@target(javascript)
pub fn browser_intercept_links_with_ignores_links_outside_scope_test() {
  test_support.reset_dom()
  test_support.drop_document_click_listeners()
  test_support.reset_url()
  test_support.set_inner_html("#app", "<a id=\"link\" href=\"/docs\">Docs</a>")
  let #(runtime, _captured) = path_recording_runtime()
  let _runtime =
    browser.intercept_links_with(
      runtime,
      within: "#overlays",
      opt_out_attribute: "data-lily-native",
    )

  test_support.click_prevented("#link") |> should.be_false
}

@target(javascript)
pub fn browser_intercept_links_ignores_modified_clicks_test() {
  test_support.reset_dom()
  test_support.drop_document_click_listeners()
  test_support.reset_url()
  test_support.set_inner_html("#app", "<a id=\"link\" href=\"/docs\">Docs</a>")
  let #(runtime, captured) = path_recording_runtime()
  let _runtime = browser.intercept_links(runtime)

  test_support.click_prevented_with_ctrl("#link") |> should.be_false

  test_support.get(captured) |> should.equal(["/"])
}

@target(javascript)
pub fn browser_intercept_links_ignores_external_and_special_links_test() {
  test_support.reset_dom()
  test_support.drop_document_click_listeners()
  test_support.reset_url()
  test_support.set_inner_html(
    "#app",
    "<a id=\"far\" href=\"https://example.com/x\" target=\"_blank\">Far</a>"
      <> "<a id=\"mail\" href=\"mailto:a@b.c\">Mail</a>"
      <> "<a id=\"ext\" href=\"/x\" rel=\"external\">Ext</a>"
      <> "<a id=\"dl\" href=\"/x\" download>Download</a>"
      <> "<a id=\"frag\" href=\"/#top\">Top</a>",
  )
  let #(runtime, captured) = path_recording_runtime()
  let _runtime = browser.intercept_links(runtime)

  test_support.click_prevented("#far") |> should.be_false
  test_support.click_prevented("#mail") |> should.be_false
  test_support.click_prevented("#ext") |> should.be_false
  test_support.click_prevented("#dl") |> should.be_false
  test_support.click_prevented("#frag") |> should.be_false
  test_support.get(captured) |> should.equal(["/"])
}

// =============================================================================
// PERSIST
// =============================================================================

@target(javascript)
pub fn browser_persist_with_empty_localstorage_keeps_the_model_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()

  let _runtime = browser.persist(runtime, fields: [name_field()])

  client.model(runtime).name |> should.equal("")
}

@target(javascript)
pub fn browser_persist_hydrates_from_localstorage_test() {
  test_support.reset_dom()
  test_support.write_local_storage(
    "lily_session_name",
    json.to_string(json.string("Alice")),
  )
  let runtime = test_support.new_runtime()

  let _runtime = browser.persist(runtime, fields: [name_field(), count_field()])

  client.model(runtime).name |> should.equal("Alice")
  client.model(runtime).count |> should.equal(0)
}

@target(javascript)
pub fn browser_persist_hydration_does_not_write_back_test() {
  test_support.reset_dom()
  test_support.write_local_storage("lily_session_name", "\"Alice\"")
  let runtime = test_support.new_runtime()
  let _runtime = browser.persist(runtime, fields: [name_field(), count_field()])

  client.dispatch(runtime)(test_support.Noop)

  test_support.read_local_storage("lily_session_count") |> should.equal("")
}

@target(javascript)
pub fn browser_persist_ignores_invalid_json_test() {
  test_support.reset_dom()
  test_support.write_local_storage("lily_session_name", "not-valid-json{{")
  let runtime = test_support.new_runtime()

  let _runtime = browser.persist(runtime, fields: [name_field()])

  client.model(runtime).name |> should.equal("")
}

@target(javascript)
pub fn browser_persist_ignores_a_value_of_the_wrong_type_test() {
  test_support.reset_dom()
  test_support.write_local_storage("lily_session_name", "42")
  let runtime = test_support.new_runtime()

  let _runtime = browser.persist(runtime, fields: [name_field()])

  client.model(runtime).name |> should.equal("")
}

@target(javascript)
pub fn browser_persist_writes_only_changed_fields_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime = browser.persist(runtime, fields: [name_field(), count_field()])

  client.dispatch(runtime)(test_support.SetName("Alice"))

  test_support.read_local_storage("lily_session_name")
  |> should.equal("\"Alice\"")
  test_support.read_local_storage("lily_session_count") |> should.equal("")
}

@target(javascript)
pub fn browser_persist_writes_again_when_a_field_changes_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime = browser.persist(runtime, fields: [name_field(), count_field()])

  client.dispatch(runtime)(test_support.SetName("Alice"))
  client.dispatch(runtime)(test_support.Increment)
  client.dispatch(runtime)(test_support.SetName("Bob"))

  test_support.read_local_storage("lily_session_name")
  |> should.equal("\"Bob\"")
  test_support.read_local_storage("lily_session_count") |> should.equal("1")
}

@target(javascript)
pub fn browser_persist_skips_a_write_when_the_field_is_unchanged_test() {
  test_support.reset_dom()
  let runtime = test_support.new_runtime()
  let _runtime = browser.persist(runtime, fields: [name_field()])
  client.dispatch(runtime)(test_support.SetName("Alice"))

  // rewriting the unchanged field would clobber a foreign write
  test_support.write_local_storage("lily_session_name", "\"Marker\"")
  client.dispatch(runtime)(test_support.SetName("Alice"))

  test_support.read_local_storage("lily_session_name")
  |> should.equal("\"Marker\"")
}

@target(javascript)
pub fn browser_persist_reads_a_value_already_in_local_storage_test() {
  test_support.reset_dom()
  test_support.write_local_storage("lily_session_name", "\"Legacy\"")

  let second = test_support.new_runtime()
  let _ = browser.persist(second, fields: [name_field()])

  client.model(second).name |> should.equal("Legacy")
}

@target(javascript)
pub fn browser_clear_persisted_removes_prefixed_keys_test() {
  test_support.reset_dom()
  test_support.write_local_storage("lily_session_name", "\"Bob\"")
  test_support.write_local_storage("lily_session_token", "\"xyz\"")
  test_support.write_local_storage("other_key", "keep-me")

  browser.clear_persisted()

  test_support.read_local_storage("lily_session_name") |> should.equal("")
  test_support.read_local_storage("lily_session_token") |> should.equal("")
  test_support.read_local_storage("other_key") |> should.equal("keep-me")
}

// =============================================================================
// CONNECTION STATUS
// =============================================================================

@target(javascript)
pub fn browser_connection_status_tracks_connect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime =
    test_support.new_runtime()
    |> browser.connection_status(set: fn(model, status) {
      Model(..model, connected: status)
    })

  let _ = client.connect(runtime, with: test_support.opened_connector())

  client.model(runtime).connected |> should.be_true
}

@target(javascript)
pub fn browser_connection_status_tracks_disconnect_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime =
    test_support.new_runtime()
    |> browser.connection_status(set: fn(model, status) {
      Model(..model, connected: status)
    })

  let #(handler, _sent) = test_support.connect_capturing(runtime)

  handler.opened()
  handler.closed()

  client.model(runtime).connected |> should.be_false
}

@target(javascript)
pub fn browser_connection_status_follows_a_websocket_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime =
    test_support.new_runtime()
    |> browser.connection_status(set: fn(model, status) {
      Model(..model, connected: status)
    })
  let _runtime = client.connect(runtime, with: transport.websocket("/ws"))
  let socket = test_support.get_last_websocket()

  client.model(runtime).connected |> should.be_false
  test_support.trigger_websocket_open(socket)
  client.model(runtime).connected |> should.be_true
  test_support.trigger_websocket_close(socket)
  client.model(runtime).connected |> should.be_false
}

// =============================================================================
// RELOAD ON NEW VERSION
// =============================================================================

@target(javascript)
pub fn browser_reload_on_new_version_ignores_the_first_announcement_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime() |> browser.reload_on_new_version
  let before = test_support.navigation_count()

  let #(handler, _sent) = test_support.connect_capturing(runtime)
  send_version(handler, "v1")

  test_support.navigation_count() |> should.equal(before)
}

@target(javascript)
pub fn browser_reload_on_new_version_reloads_when_the_hash_changes_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime() |> browser.reload_on_new_version
  let before = test_support.navigation_count()

  let #(handler, _sent) = test_support.connect_capturing(runtime)
  send_version(handler, "v1")
  send_version(handler, "v2")

  test_support.navigation_count() |> should.equal(before + 1)
}

@target(javascript)
pub fn browser_reload_on_new_version_ignores_an_unchanged_hash_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  let runtime = test_support.new_runtime() |> browser.reload_on_new_version
  let before = test_support.navigation_count()

  let #(handler, _sent) = test_support.connect_capturing(runtime)
  send_version(handler, "v1")
  send_version(handler, "v1")

  test_support.navigation_count() |> should.equal(before)
}

// =============================================================================
// HOT RELOAD
// =============================================================================

@target(javascript)
pub fn browser_hot_reload_stashes_and_reloads_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  test_support.reset_hot_reload_installed()
  let runtime = test_support.new_runtime()
  let before = test_support.navigation_count()

  let _runtime = browser.hot_reload(runtime)
  let socket = test_support.get_last_websocket()
  test_support.trigger_websocket_message(socket, dev_reload_message(["shared"]))

  test_support.read_session_storage("lily_dev_reload_state")
  |> string.contains("\"count\":0")
  |> should.be_true
  test_support.navigation_count() |> should.equal(before + 1)
}

@target(javascript)
pub fn browser_hot_reload_storm_guard_suppresses_a_second_reload_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  test_support.reset_hot_reload_installed()
  let runtime = test_support.new_runtime()
  let _runtime = browser.hot_reload(runtime)
  let socket = test_support.get_last_websocket()
  test_support.trigger_websocket_message(socket, dev_reload_message(["a"]))
  let after_first = test_support.navigation_count()

  test_support.trigger_websocket_message(socket, dev_reload_message(["b"]))

  test_support.navigation_count() |> should.equal(after_first)
}

@target(javascript)
pub fn browser_hot_reload_installs_once_test() {
  test_support.reset_dom()
  test_support.reset_mocks()
  test_support.reset_hot_reload_installed()
  let runtime = test_support.new_runtime()
  let _ = browser.hot_reload(runtime)
  let first = test_support.get_last_websocket()

  let _ = browser.hot_reload(runtime)

  test_support.get_last_websocket() |> should.equal(first)
}

// =============================================================================
// RECOVER AFTER RELOAD
// =============================================================================

@target(javascript)
pub fn browser_recover_after_reload_merges_matching_primitives_test() {
  test_support.reset_dom()
  test_support.write_session_storage(
    "lily_dev_reload_state",
    "{\"count\":99,\"name\":\"Stashed\",\"connected\":true,\"secondary_count\":7,\"active_tab\":{\"unexpected\":\"shape\"}}",
  )

  let recovered = browser.recover_after_reload(test_support.initial_model())

  recovered.count |> should.equal(99)
  recovered.name |> should.equal("Stashed")
  recovered.connected |> should.equal(True)
  recovered.secondary_count |> should.equal(7)
  recovered.active_tab |> should.equal(test_support.TabA)
}

@target(javascript)
pub fn browser_recover_after_reload_clears_the_stash_test() {
  test_support.reset_dom()
  test_support.write_session_storage("lily_dev_reload_state", "{\"count\":1}")

  let _runtime = browser.recover_after_reload(test_support.initial_model())

  test_support.read_session_storage("lily_dev_reload_state") |> should.equal("")
}

@target(javascript)
pub fn browser_recover_after_reload_is_noop_without_a_stash_test() {
  test_support.reset_dom()

  browser.recover_after_reload(test_support.initial_model())
  |> should.equal(test_support.initial_model())
}
