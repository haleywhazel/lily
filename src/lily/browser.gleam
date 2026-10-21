//// The browser module covers everything a Lily page does with the browser
//// around the [`Runtime`](./client.html#Runtime), the URL and history, links,
//// localStorage, deploys and the development reload. It sits beside
//// [`client`](./client.html) rather than inside it, and it is built on the
//// same public seams you have, [`client.observe`](./client.html#observe),
//// [`client.model`](./client.html#model),
//// [`client.update_model`](./client.html#update_model) and
//// [`client.dispatch`](./client.html#dispatch), meaning nothing here is out of
//// your reach. On Erlang it does nothing, letting shared code compile.
////
//// Every function that hooks into a runtime takes it and gives it back,
//// letting the pieces you want pipe on between
//// [`client.start`](./client.html#start) and
//// [`client.connect`](./client.html#connect):
////
//// ```gleam
//// import lily/browser
//// import lily/client
//// import lily/transport
////
//// pub fn main() {
////   shared.store()
////   |> client.start
////   |> browser.url(set: fn(model, uri) {
////     Model(..model, route: shared.parse_route(uri))
////   })
////   |> browser.intercept_links
////   |> browser.persist(fields: [theme_field()])
////   |> browser.connection_status(set: fn(model, connected) {
////     Model(..model, connected:)
////   })
////   |> browser.reload_on_new_version
////   |> client.connect(with: transport.websocket("/ws"))
//// }
//// ```
////
//// Lily does client-side routing, though it is opt-in and deliberately not a
//// router. [`url`](#url) mirrors the location into your model through a
//// setter, [`navigate`](#navigate) and [`replace`](#replace) move around, and
//// [`intercept_links`](#intercept_links) lets ordinary `<a href>` links do so
//// without a page reload. Use [`load`](#load) when the server has to handle
//// the path.
////
//// State that should outlive a reload is described with
//// [`persisted_field`](#persisted_field) and switched on with
//// [`persist`](#persist). Each field is hydrated from localStorage and
//// mirrored back whenever it changes, under the `lily_session_` key prefix.
//// [`clear_persisted`](#clear_persisted) wipes them, say on logout.
////
//// For deploys, [`reload_on_new_version`](#reload_on_new_version) reloads the
//// page when the server announces a new build. For development,
//// [`hot_reload`](#hot_reload) reloads on every rebuild and
//// [`recover_after_reload`](#recover_after_reload) carries simple fields of
//// the model across it.
////
//// Four page signals mirror the browser into your model the same way.
//// [`visibility`](#visibility) tracks whether the tab is showing,
//// [`network`](#network) whether the browser is online and
//// [`viewport`](#viewport) the window's size.
//// [`confirm_leaving`](#confirm_leaving) asks before the page is closed with
//// unsaved changes.

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri.{type Uri}

import lily/client.{type Runtime}
@target(javascript)
import lily/internal/actor.{type Box}
@target(javascript)
import lily/transport

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// One persisted piece of the model, built with
/// [`persisted_field`](#persisted_field) and handed to
/// [`persist`](#persist).
pub opaque type PersistedField(model) {
  PersistedField(
    key: String,
    read: fn(model, String) -> Result(model, Nil),
    serialise: fn(model) -> String,
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Removes every value [`persist`](#persist) stored, say on logout. Other
/// `localStorage` keys stay.
///
/// ```gleam
/// browser.clear_persisted()
/// browser.load("/login")
/// ```
pub fn clear_persisted() -> Nil {
  clear_stored(storage_prefix)
}

/// Asks the user to confirm before they close or leave the page while `when`
/// holds, for unsaved changes. The browser shows its own wording.
///
/// ```gleam
/// runtime |> browser.confirm_leaving(when: fn(model) { model.draft != "" })
/// ```
pub fn confirm_leaving(
  runtime: Runtime(model, message, mode),
  when when: fn(model) -> Bool,
) -> Runtime(model, message, mode) {
  confirm_leaving_in_page(runtime, when)
}

/// Tracks the connection in the model, for disabling elements while offline.
/// `set` is called with `True` when the connection opens and `False` when it
/// drops.
///
/// Pipe it before [`client.connect`](./client.html#connect) so the opening is
/// not missed.
///
/// ```gleam
/// runtime
/// |> browser.connection_status(set: fn(model, connected) {
///   Model(..model, connected:)
/// })
/// ```
pub fn connection_status(
  runtime: Runtime(model, message, mode),
  set set: fn(model, Bool) -> model,
) -> Runtime(model, message, mode) {
  client.observe(runtime, fn(event, _model) {
    case event {
      client.ConnectionOpened ->
        client.update_model(runtime, with: set(_, True))
      client.ConnectionClosed ->
        client.update_model(runtime, with: set(_, False))
      _ -> Nil
    }
  })
}

/// Reloads the page on every `lily_dev` rebuild while developing. Does nothing
/// unless the page is on `localhost` or `127.0.0.1`.
///
/// Pair with [`recover_after_reload`](#recover_after_reload) to keep simple
/// model fields across the reload.
///
/// ```gleam
/// runtime |> browser.hot_reload
/// ```
pub fn hot_reload(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  hot_reload_in_page(runtime)
}

/// Makes a left-click on a same-origin `<a href>` a [`navigate`](#navigate)
/// instead of a page load. Pipe once, after [`url`](#url).
///
/// Everything that is a real navigation falls through untouched, external
/// links, `target="_blank"`, `download`, `rel="external"`, `mailto:` and
/// `tel:`, modified clicks, in-page `#fragment` anchors and any link carrying
/// `data-lily-native`.
///
/// ```gleam
/// runtime |> browser.url(set: set_route) |> browser.intercept_links
/// ```
pub fn intercept_links(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  intercept_links_with(runtime, within: "document", opt_out_attribute: opt_out)
}

/// Like [`intercept_links`](#intercept_links) but limited to links inside a
/// CSS selector and opted out by an attribute of your choosing.
///
/// ```gleam
/// runtime
/// |> browser.intercept_links_with(
///   within: "#app",
///   opt_out_attribute: "data-external",
/// )
/// ```
pub fn intercept_links_with(
  runtime: Runtime(model, message, mode),
  within within: String,
  opt_out_attribute opt_out_attribute: String,
) -> Runtime(model, message, mode) {
  intercept_links_in_page(runtime, within, opt_out_attribute)
}

/// Full page navigation, leaving the app. Counterpart to
/// [`navigate`](#navigate).
///
/// Use it when the server has to handle the path, after a logout that clears a
/// cookie or when entering a server-rendered flow. The connection closes.
///
/// ```gleam
/// browser.load("/logout")
/// ```
pub fn load(path: String) -> Nil {
  ffi_load(path)
}

/// Pushes a history entry and tells the [`url`](#url) setter, letting the model
/// follow the new location without a page load.
///
/// ```gleam
/// browser.navigate("/projects/42")
/// ```
pub fn navigate(path: String) -> Nil {
  ffi_navigate(path)
}

/// Tracks whether the browser is online in the model, straight away and on
/// every change. It reports the browser's own view, see
/// [`connection_status`](#connection_status) for the server connection.
///
/// ```gleam
/// runtime
/// |> browser.network(set: fn(model, online) { Model(..model, online:) })
/// ```
pub fn network(
  runtime: Runtime(model, message, mode),
  set set: fn(model, Bool) -> model,
) -> Runtime(model, message, mode) {
  listen_network(runtime, fn(online) {
    client.update_model(runtime, with: set(_, online))
  })
}

/// Keeps parts of the model in `localStorage`. Each field is read back into the
/// model when this is piped on, then written again whenever it changes.
///
/// Fields that cannot be read, because they are missing or no longer decode,
/// keep the model's own value. Pipe it right after
/// [`client.start`](./client.html#start).
///
/// ```gleam
/// runtime |> browser.persist(fields: [theme_field(), token_field()])
/// ```
pub fn persist(
  runtime: Runtime(model, message, mode),
  fields fields: List(PersistedField(model)),
) -> Runtime(model, message, mode) {
  persist_in_page(runtime, fields)
}

/// Describes one persisted value, stored in `localStorage` as JSON under
/// `lily_session_` followed by the key.
///
/// `get` and `set` move the value in and out of the model, `encode` and
/// `decode` handle its JSON.
///
/// ```gleam
/// browser.persisted_field(
///   key: "theme",
///   encode: theme_to_json,
///   decode: theme_decoder(),
///   get: fn(model) { model.theme },
///   set: fn(model, theme) { Model(..model, theme:) },
/// )
/// ```
pub fn persisted_field(
  key key: String,
  encode encode: fn(value) -> Json,
  decode decoder: Decoder(value),
  get get: fn(model) -> value,
  set set: fn(model, value) -> model,
) -> PersistedField(model) {
  PersistedField(
    key:,
    read: fn(model, raw) {
      json.parse(raw, decoder)
      |> result.map(set(model, _))
      |> result.replace_error(Nil)
    },
    serialise: fn(model) { json.to_string(encode(get(model))) },
  )
}

/// Carries the model across a [`hot_reload`](#hot_reload), called on your
/// initial model.
///
/// Top level primitive fields (`Int`, `Float`, `String`, `Bool`) are merged
/// into `initial` by name. Anything else, a nested custom type, a list or an
/// option, keeps the fresh value.
///
/// ```gleam
/// let initial = browser.recover_after_reload(shared.initial_model())
/// ```
pub fn recover_after_reload(initial: model) -> model {
  ffi_recover_after_reload(initial)
}

/// Reloads the current page.
///
/// ```gleam
/// browser.reload()
/// ```
pub fn reload() -> Nil {
  ffi_reload()
}

/// Reloads the page when the server announces a different build than the first
/// one this runtime saw.
///
/// That means a new deploy or a restarted server. A `ProtocolMismatch`
/// reloads too, once per pair of protocols. The server and
/// [`persist`](#persist) bring most state back after the reload.
///
/// ```gleam
/// runtime |> browser.reload_on_new_version
/// ```
pub fn reload_on_new_version(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  reload_on_new_version_in_page(runtime)
}

/// Replaces the current history entry and tells the [`url`](#url) setter.
/// Companion to [`navigate`](#navigate) for changes that should not add a back
/// button stop, like a sort order or a filter.
///
/// ```gleam
/// browser.replace("/projects?sort=newest")
/// ```
pub fn replace(path: String) -> Nil {
  ffi_replace(path)
}

/// Tracks the browser location in the model. `set` receives the parsed
/// [`Uri`](https://hexdocs.pm/gleam_stdlib/gleam/uri.html) to map onto your own
/// route type. The initial location is applied straight away, then every back
/// or forward, [`navigate`](#navigate) and [`replace`](#replace) applies it
/// again.
///
/// ```gleam
/// runtime
/// |> browser.url(set: fn(model, uri) {
///   Model(..model, route: shared.parse_route(uri))
/// })
/// ```
pub fn url(
  runtime: Runtime(model, message, mode),
  set set: fn(model, Uri) -> model,
) -> Runtime(model, message, mode) {
  url_in_page(runtime, set)
}

/// Tracks the window's width and height in the model, straight away and at
/// most once a frame while it is resized.
///
/// ```gleam
/// runtime |> browser.viewport(set: fn(model, size) { Model(..model, size:) })
/// ```
pub fn viewport(
  runtime: Runtime(model, message, mode),
  set set: fn(model, #(Int, Int)) -> model,
) -> Runtime(model, message, mode) {
  listen_viewport(runtime, fn(size) {
    client.update_model(runtime, with: set(_, size))
  })
}

/// Tracks whether the tab is showing in the model, straight away and on every
/// change, for pausing work or marking a user as away.
///
/// ```gleam
/// runtime
/// |> browser.visibility(set: fn(model, visible) { Model(..model, visible:) })
/// ```
pub fn visibility(
  runtime: Runtime(model, message, mode),
  set set: fn(model, Bool) -> model,
) -> Runtime(model, message, mode) {
  listen_visibility(runtime, fn(visible) {
    client.update_model(runtime, with: set(_, visible))
  })
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(javascript)
type LeaveGuard

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

const opt_out = "data-lily-native"

// unchanged so existing stored data survives
const storage_prefix = "lily_session_"

@target(javascript)
fn confirm_leaving_in_page(
  runtime: Runtime(model, message, mode),
  when: fn(model) -> Bool,
) -> Runtime(model, message, mode) {
  let guard = new_leave_guard()
  hold_leave_guard(guard, when(client.model(runtime)))
  client.observe(runtime, fn(_event, model) {
    hold_leave_guard(guard, when(model))
  })
}

@target(erlang)
fn confirm_leaving_in_page(
  runtime: Runtime(model, message, mode),
  _when: fn(model) -> Bool,
) -> Runtime(model, message, mode) {
  runtime
}

@target(javascript)
fn hot_reload_in_page(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  case transport.is_local_page() {
    True ->
      install_hot_reload(
        fn() { client.model(runtime) },
        reconnect_milliseconds: 1000,
        // stops a bad signal reloading the page in a tight loop
        guard_milliseconds: 1500,
      )
    False -> Nil
  }
  runtime
}

@target(erlang)
fn hot_reload_in_page(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  runtime
}

@target(javascript)
fn hydrate_field(model: model, field: PersistedField(model)) -> model {
  read_stored(storage_prefix <> field.key)
  |> result.try(field.read(model, _))
  |> result.unwrap(model)
}

@target(javascript)
fn initial_encodings(
  fields: List(PersistedField(model)),
  model: model,
) -> Dict(String, String) {
  list.fold(fields, dict.new(), fn(seen, field) {
    dict.insert(seen, field.key, field.serialise(model))
  })
}

@target(javascript)
fn intercept_links_in_page(
  runtime: Runtime(model, message, mode),
  within: String,
  opt_out_attribute: String,
) -> Runtime(model, message, mode) {
  install_link_interception(runtime, navigate, within, opt_out_attribute)
  runtime
}

@target(erlang)
fn intercept_links_in_page(
  runtime: Runtime(model, message, mode),
  _within: String,
  _opt_out_attribute: String,
) -> Runtime(model, message, mode) {
  runtime
}

@target(javascript)
fn persist_in_page(
  runtime: Runtime(model, message, mode),
  fields: List(PersistedField(model)),
) -> Runtime(model, message, mode) {
  let hydrate = fn(model) { list.fold(fields, model, hydrate_field) }
  let remembered =
    actor.box_new(initial_encodings(fields, hydrate(client.model(runtime))))
  client.update_model(runtime, with: hydrate)
  client.observe(runtime, fn(_event, model) {
    let previous = actor.box_get(remembered)
    let #(next, changed) =
      list.fold(fields, #(previous, []), fn(state, field) {
        let #(seen, changed) = state
        let encoded = field.serialise(model)
        case dict.get(seen, field.key) == Ok(encoded) {
          True -> state
          False -> #(dict.insert(seen, field.key, encoded), [
            #(field.key, encoded),
            ..changed
          ])
        }
      })
    actor.box_set(remembered, next)
    list.each(changed, fn(entry) {
      write_stored(storage_prefix <> entry.0, entry.1)
    })
  })
}

@target(erlang)
fn persist_in_page(
  runtime: Runtime(model, message, mode),
  _fields: List(PersistedField(model)),
) -> Runtime(model, message, mode) {
  runtime
}

@target(javascript)
fn reload_on_new_version_in_page(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  let baseline: Box(Option(String)) = actor.box_new(None)
  client.observe(runtime, fn(event, _model) {
    case event {
      client.VersionAnnounced(hash:) -> {
        ffi_forget_protocol_reload()
        case actor.box_get(baseline) {
          None -> actor.box_set(baseline, Some(hash))
          Some(first) if first == hash -> Nil
          Some(_) -> ffi_reload()
        }
      }
      // a new build brings a client that speaks the server's protocol
      client.ProtocolMismatch(server:, client:) ->
        ffi_reload_for_protocol(server, client)
      _ -> Nil
    }
  })
}

@target(erlang)
fn reload_on_new_version_in_page(
  runtime: Runtime(model, message, mode),
) -> Runtime(model, message, mode) {
  runtime
}

@target(javascript)
fn url_in_page(
  runtime: Runtime(model, message, mode),
  set: fn(model, Uri) -> model,
) -> Runtime(model, message, mode) {
  let apply = fn() {
    case read_location() {
      Ok(uri) -> client.update_model(runtime, with: set(_, uri))
      Error(Nil) -> Nil
    }
  }
  listen_location(apply)
  apply()
  runtime
}

@target(erlang)
fn url_in_page(
  runtime: Runtime(model, message, mode),
  _set: fn(model, Uri) -> model,
) -> Runtime(model, message, mode) {
  runtime
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@external(javascript, "./browser.ffi.mjs", "clearStored")
fn clear_stored(_prefix: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "forgetProtocolReload")
fn ffi_forget_protocol_reload() -> Nil

@external(javascript, "./browser.ffi.mjs", "load")
fn ffi_load(_path: String) -> Nil {
  Nil
}

@external(javascript, "./browser.ffi.mjs", "navigate")
fn ffi_navigate(_path: String) -> Nil {
  Nil
}

@external(javascript, "./browser.ffi.mjs", "recoverAfterReload")
fn ffi_recover_after_reload(initial: model) -> model {
  initial
}

@external(javascript, "./browser.ffi.mjs", "reload")
fn ffi_reload() -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "reloadForProtocol")
fn ffi_reload_for_protocol(server: Int, client: Int) -> Nil

@external(javascript, "./browser.ffi.mjs", "replace")
fn ffi_replace(_path: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "holdLeaveGuard")
fn hold_leave_guard(guard: LeaveGuard, holds: Bool) -> Nil

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "installHotReload")
fn install_hot_reload(
  get_model: fn() -> model,
  reconnect_milliseconds reconnect_milliseconds: Int,
  guard_milliseconds guard_milliseconds: Int,
) -> Nil

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "installLinkInterception")
fn install_link_interception(
  owner: Runtime(model, message, mode),
  navigate: fn(String) -> Nil,
  within: String,
  opt_out: String,
) -> Nil

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "listenLocation")
fn listen_location(apply: fn() -> Nil) -> Nil

@external(javascript, "./browser.ffi.mjs", "listenNetwork")
fn listen_network(
  runtime: Runtime(model, message, mode),
  _apply: fn(Bool) -> Nil,
) -> Runtime(model, message, mode) {
  runtime
}

@external(javascript, "./browser.ffi.mjs", "listenViewport")
fn listen_viewport(
  runtime: Runtime(model, message, mode),
  _apply: fn(#(Int, Int)) -> Nil,
) -> Runtime(model, message, mode) {
  runtime
}

@external(javascript, "./browser.ffi.mjs", "listenVisibility")
fn listen_visibility(
  runtime: Runtime(model, message, mode),
  _apply: fn(Bool) -> Nil,
) -> Runtime(model, message, mode) {
  runtime
}

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "newLeaveGuard")
fn new_leave_guard() -> LeaveGuard

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "readLocation")
fn read_location() -> Result(Uri, Nil)

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "readStored")
fn read_stored(key: String) -> Result(String, Nil)

@target(javascript)
@external(javascript, "./browser.ffi.mjs", "writeStored")
fn write_stored(key: String, value: String) -> Nil
