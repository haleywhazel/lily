//// The client owns the browser-side [`Runtime`](#Runtime), pretty much
//// everything that makes a Lily app tick in the page. The update loop,
//// component subscriptions, local persistence, and (once a transport is
//// connected) keeping your model in sync with the server all live here. It
//// even watches online/offline status for you, saving messages into
//// sessionStorage while you're disconnected and replaying them the moment the
//// server is back. This module is browser-only, Erlang need not apply.
////
//// A frontend comes together as one pipeline, build a
//// [`Store`](./store.html#Store) with [`store.new`](./store.html#new), start
//// the runtime with [`start`](#start) (handing it the shared
//// [`Wiring`](./store.html#Wiring)), [`mount`](./component.html#mount) your
//// components, pipe on your event handlers, and [`connect`](#connect) to a
//// server if you have one:
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/event
//// import lily/store
//// import lily/transport
////
//// pub fn main() {
////   store.new(shared.initial_model(), with: shared.update)
////   |> client.start(shared.wiring(), shared.serialiser())
////   |> component.mount(
////     selector: "#app",
////     to_html: element.to_string,
////     to_slot: fn() { element.element("lily-slot", [], []) },
////     view: app,
////   )
////   |> event.on_decoded(
////     event: event.click,
////     selector: "#app",
////     decoder: parse_message,
////   )
////   |> client.connect(
////     with: transport.websocket(url: "ws://localhost:8080/ws")
////       |> transport.websocket_connect,
////   )
////   |> client.subscribe("chat")
//// }
//// ```
////
//// If you aren't syncing with a server, stop after `mount`, the runtime is
//// perfectly happy on its own. When you are, [`subscribe`](#subscribe) to the
//// topics this client cares about (see [topic](./topic.html)) and
//// [`unsubscribe`](#unsubscribe) when it stops caring.
////
//// To feed messages in from outside your components, a timer, a callback, an
//// FFI shim, grab a dispatch function with [`dispatch`](#dispatch):
////
//// ```gleam
//// let dispatch = client.dispatch(runtime)
//// dispatch(Increment)
//// ```
////
//// Everything you dispatch, plus every frame the server sends, runs through a
//// single message queue, so your update function is only ever called one
//// message at a time even when several land at once. That ordering is what
//// keeps optimistic client updates from racing the server's authoritative
//// snapshots.
////
//// For client-side reactions that don't belong in `update`, focus management,
//// analytics, kicking off a fetch, register a hook with
//// [`on_message`](#on_message), it runs after each dispatched message with the
//// full model. The connection lifecycle has its own hooks,
//// [`on_connect`](#on_connect) fires once on the first acknowledged
//// connection, [`on_disconnect`](#on_disconnect) and
//// [`on_reconnect`](#on_reconnect) track drops and recoveries (pair them with
//// [`connection_status`](#connection_status) for a "reconnecting..." banner),
//// and [`on_snapshot`](#on_snapshot) lets you decide how a fresh server
//// snapshot merges into what the client already has.
////
//// Lily does client-side routing too, though it is opt-in and deliberately not
//// a router, Lily is for connection-preserving apps, not for turning every site
//// into an SPA. Mirror the location into your model with [`url`](#url), whose
//// `set` callback hands you the parsed `Uri` to map onto your own route type,
//// then move around with [`navigate`](#navigate) to push a new history entry or
//// [`replace`](#replace) to swap the current one without leaving a back-button
//// stop. To make ordinary `<a href>` links navigate warmly (no page reload),
//// pipe on [`intercept_links`](#intercept_links), and when a path must actually
//// be handled by the server, use [`load`](#load) for a full page navigation.
////
//// Because the wire only ever carries messages, an offline client keeps
//// working and catches up on reconnect. For state that should outlive a reload
//// or a navigation, describe it once with
//// [`session_persistence`](#session_persistence) plus
//// [`session_field`](#session_field) and switch it on with
//// [`attach_session`](#attach_session), each field is mirrored to
//// localStorage. Model fields wrapped in [`store.Local`](./store.html#Local)
//// stay client-only and are preserved when a reconnect snapshot lands.
////
//// Each [`Runtime`](#Runtime) is fully isolated, so several can coexist on one
//// page, but we'd steer you towards one runtime per page. Splitting your state
//// across many runtimes gets hard to reason about fast (badly designed React
//// apps with state scattered everywhere come to mind). If you genuinely need
//// independent, self-contained stateful widgets, a different framework might
//// suit you better.

// Much of the client's internals live in the .mjs file. The Gleam code is
// mostly wrappers over a public API that hides the JS away.

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/dynamic.{type Dynamic}
@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/json.{type Json}
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option
@target(javascript)
import gleam/result
@target(javascript)
import gleam/uri.{type Uri}
@target(javascript)
import lily/store.{type Store}
@target(javascript)
import lily/transport

// =============================================================================
// PUBLIC TYPES
// =============================================================================

@target(javascript)
/// Session persistence configuration, opaque.
///
/// - Build using [`client.session_persistence`](#session_persistence)
/// - Add fields with [`client.session_field`](#session_field)
/// - Attach to the runtime with [`client.attach_session`](#attach_session)
pub opaque type Persistence(session) {
  Persistence(fields: List(Field(session)))
}

@target(javascript)
/// Opaque handle to a running Lily app. Runtimes are isolated, so multiple
/// independent apps can share a page.
pub opaque type Runtime(model, message) {
  Runtime(handle: RuntimeHandle)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
/// Attach session persistence so data survives page navigation. Hydrates the
/// model from localStorage and mirrors local state via `get` and `set`. Pipe
/// it after `client.start`.
///
/// ```gleam
/// let persistence =
///   client.session_persistence()
///   |> client.session_field(
///     key: "token",
///     get: fn(session) { session.token },
///     set: fn(session, value) { SessionData(..session, token: value) },
///     encode: json.nullable(json.string),
///     decoder: decode.optional(decode.string),
///   )
///
/// client.start(app_store, shared.wiring())
/// |> client.attach_session(
///   persistence:,
///   get: fn(model) { model.session },
///   set: fn(model, session) { Model(..model, session: session) },
/// )
/// ```
pub fn attach_session(
  runtime: Runtime(model, message),
  persistence persistence: Persistence(session),
  get get: fn(model) -> session,
  set set: fn(model, session) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  let current_model = get_model(handle)
  let hydrated_session = hydrate_session(persistence, get(current_model))
  let hydrated_model = set(current_model, hydrated_session)
  set_model(handle, hydrated_model)
  set_session_config(handle, persistence, session_storage_prefix(), get, set)
  runtime
}

@target(javascript)
/// Clear all Lily session data from `localStorage` (keys with the
/// `lily_session_` prefix).
///
/// ```gleam
/// fn update(model, message) {
///   case message {
///     Logout -> {
///       client.clear_session()
///       model
///     }
///     _ -> model
///   }
/// }
/// ```
pub fn clear_session() -> Nil {
  ffi_clear_session(session_storage_prefix())
}

@target(javascript)
/// Inject the server-assigned client id into the model when a `Connected`
/// frame arrives. That frame lands right after connect, so the model updates
/// before the first snapshot.
///
/// ```gleam
/// runtime
/// |> client.client_id(set: fn(model, id) {
///   shared.Model(
///     ..model,
///     session: shared.SessionState(..model.session, session_id: id),
///   )
/// })
/// ```
pub fn client_id(
  runtime: Runtime(model, message),
  set set: fn(model, String) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_client_id_setter(handle, set)
  runtime
}

@target(javascript)
/// Connect the runtime to a server over the given transport. The connector
/// comes from a transport implementation, e.g.
/// [`websocket_connect(config)`](./transport.html#websocket_connect) or
/// [`http_connect(config)`](./transport.html#http_connect). Wires up the
/// incoming-message and connection-status handlers, sending session messages
/// as `SessionMessage` frames and routing topic messages by the wiring from
/// [`client.start`](#start).
///
/// ```gleam
/// import lily/transport
///
/// runtime
/// |> client.connect(
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.reconnect_base_milliseconds(2000)
///     |> transport.websocket_connect,
/// )
/// ```
pub fn connect(
  runtime: Runtime(model, message),
  with connector: transport.Connector,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  let wiring = get_wiring(handle)
  let serialiser = get_serialiser(handle)

  let send_any_frame = fn(frame: transport.Protocol(model, message)) {
    let bytes = transport.encode(frame, serialiser:)
    send_via_transport(handle, bytes)
  }
  store_send_frame(handle, send_any_frame)

  let handler =
    transport.Handler(
      on_receive: fn(bytes) {
        handle_incoming(handle, bytes, serialiser, wiring)
      },
      on_reconnect: fn() {
        set_connection_status(handle, True)
        send_resync(handle, serialiser)
        fire_reconnect_hook(handle)
      },
      on_disconnect: fn() {
        set_connection_status(handle, False)
        fire_disconnect_hook(handle)
      },
    )

  let client_transport = transport.run_connector(connector, handler)
  set_transport(handle, client_transport)

  set_on_message_hook(handle, fn(message) {
    let target = store.route_message(wiring, message)
    let frame = case target {
      transport.Session -> transport.SessionMessage(payload: message)
      transport.Topic(id) ->
        transport.TopicMessage(topic_id: id, payload: message)
    }
    let bytes = transport.encode(frame, serialiser:)
    send_via_transport(handle, bytes)
  })

  runtime
}

@target(javascript)
/// Track connection status in the model, handy for disabling elements while
/// offline. Lily calls `set` with `True` on connect and `False` on
/// disconnect, and components can slice the field to react. Call before
/// [`client.connect`](#connect) to capture the initial state. Optional, status
/// is tracked internally either way.
///
/// ```gleam
/// runtime
/// |> client.connection_status(set: fn(model, status) {
///   Model(..model, connected: status)
/// })
/// |> client.connect(
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.websocket_connect,
/// )
/// ```
pub fn connection_status(
  runtime: Runtime(model, message),
  set set: fn(model, Bool) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_connection_status_config(handle, set)
  runtime
}

@target(javascript)
/// Get a dispatch function that feeds messages into the runtime's update loop.
/// The [`Store`](./store.html#Store) is pure, so this is how side-effects like
/// fetch callbacks and timers update the store.
///
/// ```gleam
/// let runtime = client.start(store, shared.wiring(), shared.serialiser())
/// let dispatch = client.dispatch(runtime)
///
/// fetch("/api/data", fn(response) {
///   dispatch(DataReceived(response))
/// })
/// ```
pub fn dispatch(runtime: Runtime(model, message)) -> fn(message) -> Nil {
  let Runtime(handle) = runtime
  fn(message) { ffi_send_message(handle, message) }
}

@target(javascript)
/// Opt in to dev hot reload. Connects to the dev-reload socket (page origin,
/// port one above the page's, where `lily_dev` hosts it) and reloads on every
/// rebuild, with a storm guard against reload loops. Development only, guard
/// behind a dev flag. State survives via reconnect resync and session
/// persistence.
///
/// ```gleam
/// runtime |> client.enable_hot_reload
/// ```
pub fn enable_hot_reload(
  runtime: Runtime(model, message),
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  install_hot_reload(handle, "", 1000, 1500)
  runtime
}

@target(javascript)
/// Generate a random 32-character hex string for a client-side session id.
/// Each call returns a unique value from `crypto.getRandomValues`, safe to
/// call at startup and store in the session model.
///
/// ```gleam
/// let session_id = client.generate_session_id()
/// let initial = shared.Model(
///   session: shared.SessionState(..shared.initial_session(), session_id:),
///   chat: shared.initial_chat(),
/// )
/// ```
pub fn generate_session_id() -> String {
  ffi_generate_session_id()
}

@target(javascript)
/// Opt in to client-side navigation for `<a href>` links: a left-click on a
/// same-origin internal link becomes a warm [`navigate`](#navigate) (history
/// push + [`url`](#url) setter), no page reload. Real navigations fall through
/// untouched, external/cross-origin links, `target="_blank"`, `download`,
/// `rel="external"`, `mailto:`/`tel:` schemes, modified/middle clicks, in-page
/// `#fragment` anchors, and any link with the opt-out attribute (default
/// `data-lily-native`). Pipe once, after [`url`](#url).
///
/// Opt-in and deliberately minimal, Lily is not a router. Use it only when
/// navigation should preserve the live socket and offline state.
///
/// ```gleam
/// runtime
/// |> client.url(set: fn(model, uri) { Model(..model, route: parse(uri)) })
/// |> client.intercept_links
/// ```
///
/// All page anchors are intercepted, any carrying `data-lily-native` opts out
/// into a full page load.
pub fn intercept_links(
  runtime: Runtime(model, message),
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  install_link_interception(handle, "document", "data-lily-native")
  runtime
}

@target(javascript)
/// Full page navigation (`window.location.assign`), leaving the Lily app
/// entirely, the counterpart to [`navigate`](#navigate)'s in-app history push.
/// Use when a path must be handled by the server, after a logout that clears a
/// cookie, entering a server-rendered flow. The socket is torn down and the
/// destination loads fresh.
///
/// ```gleam
/// client.load(runtime, "/logout")
/// ```
pub fn load(runtime: Runtime(model, message), path path: String) -> Nil {
  let Runtime(handle) = runtime
  ffi_load(handle, path)
}

@target(javascript)
/// Reconciliation helper for [`on_snapshot`](#on_snapshot): walks the incoming
/// model, keeping any field whose current value is
/// [`store.Local`](./store.html#Local) and taking the incoming value
/// otherwise. Compose with custom per-field merge logic when the default
/// slice-merge isn't enough.
///
/// Argument order matches the [`on_snapshot`](#on_snapshot) hook,
/// `(incoming, current)`.
pub fn merge_locals(incoming: model, current: model) -> model {
  ffi_merge_locals(incoming, current)
}

@target(javascript)
/// Push a new history entry and update the URL. Fires the [`url`](#url) setter
/// so the model reflects the new location, letting
/// [`component.simple`](./component.html#simple) re-render on the route field.
///
/// ```gleam
/// client.navigate(runtime, "/projects/42")
/// ```
pub fn navigate(runtime: Runtime(model, message), path path: String) -> Nil {
  let Runtime(handle) = runtime
  ffi_navigate(handle, path)
}

@target(javascript)
/// Register a hook that fires once after the first server-acknowledged
/// connection, receiving the client id. For per-session bootstrap work like
/// registering with analytics or a one-time fetch.
///
/// Attach before [`connect`](#connect) so it's in place when the first
/// `Connected` frame arrives.
///
/// ```gleam
/// runtime
/// |> client.on_connect(fn(client_id) {
///   logging.log(logging.Info, "connected as " <> client_id)
/// })
/// ```
pub fn on_connect(
  runtime: Runtime(model, message),
  hook: fn(String) -> Nil,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_on_connect_hook(handle, hook)
  runtime
}

@target(javascript)
/// Register a hook that fires whenever the transport drops the connection.
/// Companion to [`on_reconnect`](#on_reconnect) and
/// [`connection_status`](#connection_status).
///
/// ```gleam
/// runtime
/// |> client.on_disconnect(fn() { show_offline_toast() })
/// ```
pub fn on_disconnect(
  runtime: Runtime(model, message),
  hook: fn() -> Nil,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_on_disconnect_hook(handle, hook)
  runtime
}

@target(javascript)
/// Register a hook that runs after each locally-dispatched message, session
/// and topic alike. `model` is the full outer model after the message is
/// applied.
///
/// ```gleam
/// runtime
/// |> client.on_message(fn(message, model) {
///   case message {
///     Chat(NewChatMessage(body, _)) ->
///       dispatch(Session(AddPopup(body)))
///     _ -> Nil
///   }
/// })
/// ```
pub fn on_message(
  runtime: Runtime(model, message),
  hook: fn(message, model) -> Nil,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_user_message_hook(handle, hook)
  runtime
}

@target(javascript)
/// Register a hook that fires whenever the transport restores the connection
/// after a drop. Not on the first connect, see [`on_connect`](#on_connect).
///
/// ```gleam
/// runtime
/// |> client.on_reconnect(fn() { show_reconnected_toast() })
/// ```
pub fn on_reconnect(
  runtime: Runtime(model, message),
  hook: fn() -> Nil,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_on_reconnect_hook(handle, hook)
  runtime
}

@target(javascript)
/// Register a hook that runs when a server snapshot arrives on reconnect. It
/// receives `(incoming, current)` and returns the merged model to dispatch.
///
/// Without a hook, the wiring merges only the snapshotted target's slice into
/// the current model, leaving other slices intact. Compose with
/// [`merge_locals`](#merge_locals) to also preserve `store.Local` fields.
///
/// ```gleam
/// runtime
/// |> client.on_snapshot(fn(incoming, current) {
///   let merged = client.merge_locals(incoming, current)
///   Model(..merged, doc: crdt.merge(incoming.doc, current.doc))
/// })
/// ```
pub fn on_snapshot(
  runtime: Runtime(model, message),
  hook: fn(model, model) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_snapshot_hook(handle, hook)
  runtime
}

@target(javascript)
/// Register a hook that fires when a `Version` frame's hash differs from the
/// first this runtime saw. The server sends one on connect and every
/// reconnect, so a changed value means a new build is live. Pair with
/// [`reload`](#reload), resync then recovers the model.
///
/// ```gleam
/// runtime |> client.on_version_mismatch(client.reload)
/// ```
pub fn on_version_mismatch(
  runtime: Runtime(model, message),
  hook: fn() -> Nil,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_version_mismatch_hook(handle, hook)
  runtime
}

@target(javascript)
/// Recover state a dev-reload stashed just before firing, clearing the stash
/// either way. Merges top-level primitive fields (`Int`, `Float`, `String`,
/// `Bool`) into `initial` by field name, anything else (nested custom type,
/// `List`, `Option`) falls back to `initial`. Use
/// [`recover_after_reload_migrate`](#recover_after_reload_migrate) to take over
/// the merge entirely.
///
/// ```gleam
/// let initial = client.recover_after_reload(shared.initial_model())
/// ```
pub fn recover_after_reload(initial: model) -> model {
  ffi_recover_after_reload(initial, option.None)
}

@target(javascript)
/// Like [`recover_after_reload`](#recover_after_reload) but takes over the
/// merge entirely. `migrate` receives the raw stashed value and the fresh
/// `initial` model and returns the model to boot with, for renamed fields,
/// type changes, or a nested slice.
///
/// ```gleam
/// let initial =
///   client.recover_after_reload_migrate(shared.initial_model(), fn(stashed, initial) {
///     let count =
///       decode.run(stashed, decode.at(["count"], decode.int))
///       |> result.unwrap(initial.count)
///     Model(..initial, count:)
///   })
/// ```
pub fn recover_after_reload_migrate(
  initial: model,
  migrate: fn(Dynamic, model) -> model,
) -> model {
  ffi_recover_after_reload(initial, option.Some(migrate))
}

@target(javascript)
/// Reload the current page. A graceful default for
/// [`on_version_mismatch`](#on_version_mismatch), cheap since resync and
/// session persistence recover most state on the other side.
pub fn reload() -> Nil {
  ffi_reload()
}

@target(javascript)
/// Replace the current history entry and update the URL. Fires the
/// [`url`](#url) setter. Use for view-state-in-URL changes that shouldn't
/// create a back-button stop, like a sort-order or filter toggle.
///
/// ```gleam
/// client.replace(runtime, "/projects?sort=newest")
/// ```
pub fn replace(runtime: Runtime(model, message), path path: String) -> Nil {
  let Runtime(handle) = runtime
  ffi_replace(handle, path)
}

@target(javascript)
/// Add a field to the session persistence config. Each is one value stored in
/// `localStorage` under `lily_session_{key}`. `get`/`set` move it in and out of
/// the session type, `encode`/`decoder` handle its JSON.
///
/// ```gleam
/// client.session_persistence()
/// |> client.session_field(
///   key: "theme",
///   get: fn(session) { session.theme },
///   set: fn(session, theme) { SessionData(..session, theme: theme) },
///   encode: theme_to_json,
///   decoder: theme_decoder,
/// )
/// ```
pub fn session_field(
  persistence: Persistence(session),
  key key: String,
  get get: fn(session) -> a,
  set set: fn(session, a) -> session,
  encode encode: fn(a) -> Json,
  decoder decoder: decode.Decoder(a),
) -> Persistence(session) {
  let Persistence(fields) = persistence
  let field =
    Field(
      key: key,
      get: fn(session) { encode(get(session)) },
      set: fn(session, dynamic_value) {
        decode.run(dynamic_value, decoder)
        |> result.map(set(session, _))
        |> result.replace_error(Nil)
      },
    )
  Persistence(fields: [field, ..fields])
}

@target(javascript)
/// Create an empty session persistence config, ready for fields via
/// [`client.session_field`](#session_field).
///
/// See the example in [`client.attach_session`](#attach_session).
pub fn session_persistence() -> Persistence(session) {
  Persistence(fields: [])
}

@target(javascript)
/// Start the client runtime with a store and a wiring config. The wiring tells
/// the runtime how to route messages to the correct server-side target
/// (session or a named topic store) and how to merge incoming snapshots into
/// the outer model.
///
/// Build the wiring in your `shared` package and import it here:
///
/// ```gleam
/// let runtime =
///   store.new(shared.initial_model(), with: shared.update)
///   |> client.start(shared.wiring(), shared.serialiser())
///
/// runtime
/// |> component.mount(
///   selector: "#app",
///   to_html: element.to_string,
///   to_slot: fn() { element.element("lily-slot", [], []) },
///   view: app,
/// )
/// |> event.on_decoded(
///   event: event.click,
///   selector: "#app",
///   decoder: parse_message,
/// )
/// ```
pub fn start(
  store: Store(model, message),
  wiring wiring: store.Wiring(model, message),
  serialiser serialiser: transport.Serialiser(model, message),
) -> Runtime(model, message) {
  let handle = create_runtime(store, store.apply)
  set_store(handle, store)
  set_wiring(handle, wiring)
  set_serialiser(handle, serialiser)
  // Hydrate from an embedded server-rendered snapshot if present, else fall
  // back to the store's model. Lenient, a missing or malformed embed is
  // ignored and the first render replaces any mismatch.
  case read_embedded_snapshot() {
    Ok(bytes) ->
      case transport.decode(bytes, serialiser:) {
        Ok(transport.Snapshot(target: transport.Session, sequence: _, state:)) ->
          set_model(handle, state)
        _ -> Nil
      }
    Error(_) -> Nil
  }
  initial_notify(handle)
  Runtime(handle)
}

@target(javascript)
/// Subscribe this connection to a topic. Sends a `Subscribe` frame, on
/// `Snapshot` arrival the topic's slice is hydrated and components re-render.
/// Idempotent, no-op if already subscribed. Call after
/// [`client.connect`](#connect).
///
/// ```gleam
/// runtime
/// |> client.connect(with: connector)
/// |> client.subscribe("chat")
/// ```
pub fn subscribe(
  runtime: Runtime(model, message),
  topic_id: String,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  call_stored_send_frame(handle, transport.Subscribe(topic_id:))
  runtime
}

@target(javascript)
/// Unsubscribe from a topic, sends a frame so the server stops pushing
/// updates. Fire-and-forget, no confirmation and the topic's last slice is
/// left as-is. Re-subscribing pulls a fresh snapshot that replaces it (for
/// stateful topics), clear it sooner with your own message if needed. Call
/// after [`client.connect`](#connect).
///
/// ```gleam
/// runtime
/// |> client.unsubscribe("chat")
/// ```
pub fn unsubscribe(
  runtime: Runtime(model, message),
  topic_id: String,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  call_stored_send_frame(handle, transport.Unsubscribe(topic_id:))
  runtime
}

@target(javascript)
/// Track the browser URL in the model. The `set` callback receives the parsed
/// [`uri.Uri`](https://hexdocs.pm/gleam_stdlib/gleam/uri.html) to map onto your
/// own route ADT. The initial URL is read on attach, and changes from
/// `popstate`, [`navigate`](#navigate), and [`replace`](#replace) all flow
/// through the same setter.
///
/// Mirrors [`client_id`](#client_id) and
/// [`connection_status`](#connection_status).
///
/// ```gleam
/// runtime
/// |> client.url(set: fn(model, uri) {
///   Model(..model, route: shared.parse_route(uri))
/// })
/// ```
pub fn url(
  runtime: Runtime(model, message),
  set set: fn(model, Uri) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_url_setter(handle, set)
  runtime
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@target(javascript)
/// Get the current model. Used by the session module to hydrate persisted
/// session data on startup.
@internal
pub fn get_current_model(runtime: Runtime(model, message)) -> model {
  let Runtime(handle) = runtime
  get_model(handle)
}

@target(javascript)
/// Extract the runtime handle from the wrapper. Used by other Lily modules
/// (session, component) needing direct FFI access.
@internal
pub fn get_handle(runtime: Runtime(model, message)) -> RuntimeHandle {
  let Runtime(handle) = runtime
  handle
}

@target(javascript)
/// Wrapper for the send-message FFI, used in event.gleam.
@internal
pub fn send_message(runtime: Runtime(model, message), message: message) -> Nil {
  let Runtime(runtime_handle) = runtime
  ffi_send_message(runtime_handle, message)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(javascript)
/// One local-persistence field
type Field(session) {
  Field(
    key: String,
    get: fn(session) -> Json,
    set: fn(session, Dynamic) -> Result(session, Nil),
  )
}

@target(javascript)
/// The concrete JS object from `createRuntime()`. JavaScript has no type
/// parameters, so `Runtime(model, message)` (the public opaque type) wraps
/// this. `@internal` for other Lily modules (component) needing FFI access.
@internal
pub type RuntimeHandle

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(javascript)
fn handle_incoming(
  handle: RuntimeHandle,
  bytes: BitArray,
  serialiser: transport.Serialiser(model, message),
  wiring: store.Wiring(model, message),
) -> Nil {
  case transport.decode(bytes, serialiser:) {
    Ok(transport.Acknowledge(target:, sequence:)) ->
      set_last_sequence_for_target(
        handle,
        transport.target_key(target),
        sequence,
      )

    Ok(transport.Connected(client_id:)) -> handle_client_id(handle, client_id)

    Ok(transport.Push(topic_id: _, payload:)) ->
      apply_remote_message(handle, payload)

    Ok(transport.TopicUpdate(topic_id:, sequence:, payload:)) -> {
      set_last_sequence_for_target(
        handle,
        transport.target_key(transport.Topic(topic_id)),
        sequence,
      )
      apply_remote_message(handle, payload)
    }

    Ok(transport.SessionUpdate(sequence:, payload:)) -> {
      set_last_sequence_for_target(
        handle,
        transport.target_key(transport.Session),
        sequence,
      )
      apply_remote_message(handle, payload)
    }

    Ok(transport.Snapshot(target:, sequence:, state:)) -> {
      set_last_sequence_for_target(
        handle,
        transport.target_key(target),
        sequence,
      )
      handle_snapshot(handle, wiring, target, state)
    }

    Ok(transport.Rejected(topic_id: _, reason: _)) -> Nil

    Ok(transport.Version(hash:)) -> handle_version(handle, hash)

    _ -> Nil
  }
}

@target(javascript)
fn handle_snapshot(
  handle: RuntimeHandle,
  wiring: store.Wiring(model, message),
  target: transport.Target,
  incoming: model,
) -> Nil {
  let current = get_model(handle)
  let merged = store.merge_snapshot(wiring, target, current, incoming)
  let final_model = case get_snapshot_hook(handle) {
    option.None -> merged
    option.Some(hook) -> hook(incoming, current)
  }
  dispatch_model(handle, final_model)
}

@target(javascript)
fn hydrate_session(
  persistence: Persistence(session),
  initial: session,
) -> session {
  let Persistence(fields) = persistence
  list.fold(fields, initial, fn(session, f) {
    let Field(key, _get, set) = f
    read_field(session_storage_prefix(), key)
    |> result.try(set(session, _))
    |> result.unwrap(session)
  })
}

@target(javascript)
fn send_resync(
  handle: RuntimeHandle,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  let raw_seqs = get_all_sequences(handle)
  let cursors =
    list.filter_map(raw_seqs, fn(pair) {
      let #(key, _seq) = pair
      transport.target_from_key(key)
    })
  let bytes = transport.encode(transport.Resync(cursors:), serialiser:)
  send_via_transport(handle, bytes)
}

@target(javascript)
fn session_storage_prefix() -> String {
  "lily_session_"
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./client.ffi.mjs", "applyRemoteMessage")
fn apply_remote_message(handle: RuntimeHandle, message: message) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "callStoredSendFrame")
fn call_stored_send_frame(
  handle: RuntimeHandle,
  frame: transport.Protocol(model, message),
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "createRuntime")
fn create_runtime(
  store: Store(model, message),
  apply: fn(Store(model, message), message) -> Store(model, message),
) -> RuntimeHandle

@target(javascript)
@external(javascript, "./client.ffi.mjs", "dispatchModel")
fn dispatch_model(handle: RuntimeHandle, model: model) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "fireDisconnectHook")
fn fire_disconnect_hook(handle: RuntimeHandle) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "fireReconnectHook")
fn fire_reconnect_hook(handle: RuntimeHandle) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "clearSession")
fn ffi_clear_session(prefix: String) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "generateSessionId")
fn ffi_generate_session_id() -> String

@target(javascript)
@external(javascript, "./client.ffi.mjs", "mergeLocals")
fn ffi_merge_locals(incoming: model, current: model) -> model

@target(javascript)
@external(javascript, "./client.ffi.mjs", "navigate")
fn ffi_navigate(handle: RuntimeHandle, path: String) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "recoverAfterReload")
fn ffi_recover_after_reload(
  initial: model,
  migrate: option.Option(fn(Dynamic, model) -> model),
) -> model

@target(javascript)
@external(javascript, "./client.ffi.mjs", "reload")
fn ffi_reload() -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "replace")
fn ffi_replace(handle: RuntimeHandle, path: String) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "load")
fn ffi_load(handle: RuntimeHandle, path: String) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "installLinkInterception")
fn install_link_interception(
  handle: RuntimeHandle,
  within: String,
  opt_out: String,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "sendMessage")
fn ffi_send_message(handle: RuntimeHandle, message: message) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "getAllSequences")
fn get_all_sequences(handle: RuntimeHandle) -> List(#(String, Int))

@target(javascript)
@external(javascript, "./client.ffi.mjs", "getModel")
fn get_model(handle: RuntimeHandle) -> model

@target(javascript)
@external(javascript, "./client.ffi.mjs", "getSnapshotHook")
fn get_snapshot_hook(
  handle: RuntimeHandle,
) -> option.Option(fn(model, model) -> model)

@target(javascript)
@external(javascript, "./client.ffi.mjs", "getWiring")
fn get_wiring(handle: RuntimeHandle) -> store.Wiring(model, message)

@target(javascript)
@external(javascript, "./client.ffi.mjs", "getSerialiser")
fn get_serialiser(handle: RuntimeHandle) -> transport.Serialiser(model, message)

@target(javascript)
@external(javascript, "./client.ffi.mjs", "handleClientId")
fn handle_client_id(handle: RuntimeHandle, client_id: String) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "handleVersion")
fn handle_version(handle: RuntimeHandle, hash: String) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "installHotReload")
fn install_hot_reload(
  handle: RuntimeHandle,
  url: String,
  reconnect_milliseconds: Int,
  guard_milliseconds: Int,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "initialNotify")
fn initial_notify(handle: RuntimeHandle) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "readEmbeddedSnapshot")
fn read_embedded_snapshot() -> Result(BitArray, Nil)

@target(javascript)
@external(javascript, "./client.ffi.mjs", "readField")
fn read_field(prefix: String, key: String) -> Result(Dynamic, Nil)

@target(javascript)
@external(javascript, "./client.ffi.mjs", "sendViaTransport")
fn send_via_transport(handle: RuntimeHandle, bytes: BitArray) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setClientIdSetter")
fn set_client_id_setter(
  handle: RuntimeHandle,
  set: fn(model, String) -> model,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setConnectionStatus")
fn set_connection_status(handle: RuntimeHandle, connected: Bool) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setConnectionStatusConfig")
fn set_connection_status_config(
  handle: RuntimeHandle,
  set: fn(model, Bool) -> model,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setLastSequenceForTarget")
fn set_last_sequence_for_target(
  handle: RuntimeHandle,
  target_key: String,
  sequence: Int,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setModel")
fn set_model(handle: RuntimeHandle, model: model) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setOnConnectHook")
fn set_on_connect_hook(handle: RuntimeHandle, hook: fn(String) -> Nil) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setOnDisconnectHook")
fn set_on_disconnect_hook(handle: RuntimeHandle, hook: fn() -> Nil) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setOnMessageHook")
fn set_on_message_hook(handle: RuntimeHandle, hook: fn(message) -> Nil) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setOnReconnectHook")
fn set_on_reconnect_hook(handle: RuntimeHandle, hook: fn() -> Nil) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setSessionConfig")
fn set_session_config(
  handle: RuntimeHandle,
  persistence: Persistence(session),
  prefix: String,
  get: fn(model) -> session,
  set: fn(model, session) -> model,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setSnapshotHook")
fn set_snapshot_hook(
  handle: RuntimeHandle,
  hook: fn(model, model) -> model,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setVersionMismatchHook")
fn set_version_mismatch_hook(handle: RuntimeHandle, hook: fn() -> Nil) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setUrlSetter")
fn set_url_setter(handle: RuntimeHandle, set: fn(model, Uri) -> model) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setStore")
fn set_store(handle: RuntimeHandle, store: Store(model, message)) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setTransport")
fn set_transport(handle: RuntimeHandle, transport: transport.Transport) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setUserMessageHook")
fn set_user_message_hook(
  handle: RuntimeHandle,
  hook: fn(message, model) -> Nil,
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setWiring")
fn set_wiring(
  handle: RuntimeHandle,
  wiring: store.Wiring(model, message),
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setSerialiser")
fn set_serialiser(
  handle: RuntimeHandle,
  serialiser: transport.Serialiser(model, message),
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "storeSendFrame")
fn store_send_frame(
  handle: RuntimeHandle,
  send: fn(transport.Protocol(model, message)) -> Nil,
) -> Nil
