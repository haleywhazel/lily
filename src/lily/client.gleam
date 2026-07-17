//// The client owns the browser-side [`Runtime`](#Runtime), pretty much
//// everything that makes a Lily app tick in the page. The update loop,
//// component subscriptions, local persistence, and (once a transport is
//// connected) keeping your model in sync with the server all live here. It
//// even watches online/offline status for you, tucking messages into
//// localStorage while you're disconnected and replaying them the moment the
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
////   |> client.start(shared.wiring())
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
////     serialiser: shared.serialiser(),
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
//// [`on_message`](#on_message); it runs after each dispatched message with the
//// full model. The connection lifecycle has its own hooks,
//// [`on_connect`](#on_connect) fires once on the first acknowledged
//// connection, [`on_disconnect`](#on_disconnect) and
//// [`on_reconnect`](#on_reconnect) track drops and recoveries (pair them with
//// [`connection_status`](#connection_status) for a "reconnecting…" banner),
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
//// pipe on [`intercept_links`](#intercept_links); and when a path must actually
//// be handled by the server, use [`load`](#load) for a full page navigation.
////
//// Because the wire only ever carries messages, an offline client keeps
//// working and catches up on reconnect. For state that should outlive a reload
//// or a navigation, describe it once with
//// [`session_persistence`](#session_persistence) plus
//// [`session_field`](#session_field) and switch it on with
//// [`attach_session`](#attach_session); each field is mirrored to
//// localStorage. Model fields wrapped in [`store.Local`](./store.html#Local)
//// stay client-only and are preserved when a reconnect snapshot lands.
////
//// Each [`Runtime`](#Runtime) is fully isolated, so several can coexist on one
//// page, but we'd steer you towards one runtime per page. Splitting your state
//// across many runtimes gets hard to reason about fast (badly designed React
//// apps with state scattered everywhere come to mind). If you genuinely need
//// independent, self-contained stateful widgets, a different framework might
//// suit you better.

// A good amount of the internal workings of the client lives within the .mjs
// file, so feel free to dig around there since the Gleam code is mostly just
// wrappers for a public API that hides all the messy JS away.

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
import gleam/string
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
/// An option for [`intercept_links`](#intercept_links). Build with
/// [`intercept_within`](#intercept_within) and
/// [`intercept_opt_out_attribute`](#intercept_opt_out_attribute).
pub opaque type InterceptOption {
  InterceptWithin(selector: String)
  InterceptOptOutAttribute(name: String)
}

@target(javascript)
/// Complete session persistence configuration. It's kept opaque so that users
/// avoid having to mess with the fields themselves which can look quite messy.
///
/// To interact with the session persistence:
///
/// - Build using [`client.session_persistence`](#session_persistence)
/// - Add fields with [`client.session_field`](#session_field)
/// - Attach to the runtime  with [`client.attach_session`](#attach_session)
pub opaque type Persistence(session) {
  Persistence(fields: List(Field(session)))
}

@target(javascript)
/// Opaque handle to a running Lily application instance. Each runtime is
/// isolated, allowing multiple independent apps on the same page.
pub opaque type Runtime(model, message) {
  Runtime(handle: RuntimeHandle)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
/// Attach session persistence to the runtime to allow for data to persist
/// across page navigation etc.. This allows for model hydration via local
/// storage, and also allows for local state to be updated by the model through
/// the provided `get` and `set` functions.
///
/// Pipe this in the chain after `client.start`.
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
/// Clear all Lily related session data from `localStorage` by removing all
/// keys with the `lily_session_` prefix.
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
/// Inject the server-assigned client identifier into the model when a
/// `Connected` frame arrives. The server sends this frame immediately after
/// a WebSocket connection is established, so the model is updated before
/// the first snapshot arrives.
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
/// Connect the runtime to a server using the provided transport method. The
/// connector function is obtained from a transport implementation, e.g.
/// [`websocket_connect(config)`](./transport.html#websocket_connect) or
/// [`http_connect(config)`](./transport.html#http_connect).
///
/// This also creates all the handlers for handling incoming messages, and
/// changes to connection status. Session messages are sent as `SessionMessage`
/// frames; topic messages are routed to the correct topic using the wiring
/// config passed to [`client.start`](#start).
///
/// ```gleam
/// import lily/transport
///
/// runtime
/// |> client.connect(
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.reconnect_base_milliseconds(2000)
///     |> transport.websocket_connect,
///   serialiser: shared.serialiser(),
/// )
/// ```
pub fn connect(
  runtime: Runtime(model, message),
  with connector: transport.Connector,
  serialiser serialiser: transport.Serialiser(model, message),
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  let wiring = get_wiring(handle)

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
/// Often times you want to be able to track the connection status (for
/// example, if you want to disable an element when there is no connection).
/// This sets up tracking for the connection status in the model: Lily calls
/// `set` with `True` when the transport connects and `False` when it
/// disconnects. Components can slice this field to react to connectivity
/// changes.
///
/// This should be called before [`client.connect`](#connect) to ensure the
/// initial connection state is captured.
///
/// Also note that while this call is optional, connection status is tracked
/// regardless internally, this mainly allows the status to be reflected within
/// the model.
///
/// ```gleam
/// runtime
/// |> client.connection_status(set: fn(model, status) {
///   Model(..model, connected: status)
/// })
/// |> client.connect(
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.websocket_connect,
///   serialiser: shared.serialiser(),
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
/// Get a dispatch function that sends messages into the runtime's update
/// loop. The [`Store`](./store.html#Store) is pure, so this is needed to
/// handle side-effects (fetch callbacks, timers, etc.). After generating
/// the dispatch function, you are able to use this to send updates whenever
/// some side-effect is called to update the store again.
///
/// ```gleam
/// let runtime = client.start(store, shared.wiring())
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
/// Generate a random 32-character hex string suitable for use as a
/// client-side session identifier. Each call returns a unique value derived
/// from `crypto.getRandomValues`, so it is safe to call at application
/// startup and store in the session model.
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
/// Variant of [`start`](#start) that adopts a pre-rendered DOM and
/// reads the embedded snapshot from `<script id="lily-snapshot">`. Pair
/// with [`transport.encode_initial_snapshot`](./transport.html#encode_initial_snapshot)
/// for the embedded state and
/// [`component.render_to_string`](./component.html#render_to_string) for the
/// surrounding HTML. This is hydration from a fixed initial snapshot (markup
/// rendered ahead of time), not per-request server-side rendering.
///
/// If the embedded snapshot is missing or fails to decode, hydrate
/// silently falls back to the model in the supplied store. No warning is
/// raised: in production the script tag may legitimately be absent (a CDN
/// stripping inline scripts, a CSP blocking inline content), and the
/// store's model is a valid initial state by definition. Detect missing
/// snapshots in dev by checking the embed yourself before calling hydrate.
///
/// Lenient hydration: components do not assert byte-equality with the
/// pre-rendered DOM. The first event after hydrate triggers a full
/// render, replacing any mismatched content.
///
/// ```gleam
/// pub fn main() {
///   store.new(shared.initial_model(), with: shared.update)
///   |> client.hydrate(shared.wiring(), shared.serialiser())
///   |> component.mount(
///     selector: "#app",
///     to_html: element.to_string,
///     to_slot: fn() { element.element("lily-slot", [], []) },
///     view: shared.view,
///   )
/// }
/// ```
pub fn hydrate(
  store: Store(model, message),
  wiring wiring: store.Wiring(model, message),
  serialiser serialiser: transport.Serialiser(model, message),
) -> Runtime(model, message) {
  let handle = create_runtime(store, store.apply)
  set_store(handle, store)
  set_wiring(handle, wiring)
  // Try to read and decode the embedded snapshot. If anything fails
  // (missing tag, malformed JSON, schema mismatch), fall back to the
  // store's current model silently.
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
/// Opt in to client-side navigation for ordinary `<a href>` links: after this,
/// a left-click on a *same-origin* internal link is turned into a warm
/// [`navigate`](#navigate) (history push + [`url`](#url) setter), with no full
/// page reload. Everything that should stay a real navigation falls through
/// untouched — external/cross-origin links, `target="_blank"`, `download`,
/// `rel="external"`, `mailto:`/`tel:` schemes, modified/middle clicks,
/// in-page `#fragment` anchors, and any link carrying the opt-out attribute
/// (default `data-lily-native`). Pipe it once, after [`url`](#url).
///
/// This is opt-in and deliberately minimal — Lily is not a router. Reach for it
/// only when navigation should preserve the live socket and offline state;
/// otherwise let links do full server navigations.
///
/// ```gleam
/// runtime
/// |> client.url(set: fn(model, uri) { Model(..model, route: parse(uri)) })
/// |> client.intercept_links(config: [])
/// ```
pub fn intercept_links(
  runtime: Runtime(model, message),
  config config: List(InterceptOption),
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  let InterceptConfig(within:, opt_out:) = intercept_config(config)
  install_link_interception(handle, within, opt_out)
  runtime
}

@target(javascript)
/// Override the attribute an anchor can carry to force a full page load instead
/// of warm navigation (default `"data-lily-native"`).
pub fn intercept_opt_out_attribute(name: String) -> InterceptOption {
  InterceptOptOutAttribute(name)
}

@target(javascript)
/// Only intercept anchors inside this selector's subtree (default `"document"`,
/// the whole page). Use it to let, say, a static marketing header do real page
/// loads while only the app shell navigates warmly.
pub fn intercept_within(selector: String) -> InterceptOption {
  InterceptWithin(selector)
}

@target(javascript)
/// Perform a full page navigation (`window.location.assign`), leaving the Lily
/// app entirely — the counterpart to [`navigate`](#navigate)'s in-app history
/// push. Use it when a path must be handled by the *server*, not the client
/// router: after a logout that clears a server cookie, entering a
/// server-rendered flow, or otherwise "actually going to the server". The socket
/// is torn down and the destination is loaded fresh.
///
/// ```gleam
/// client.load(runtime, "/logout")
/// ```
pub fn load(runtime: Runtime(model, message), path path: String) -> Nil {
  let Runtime(handle) = runtime
  ffi_load(handle, path)
}

@target(javascript)
/// A reconciliation helper for use inside [`on_snapshot`](#on_snapshot):
/// recursively walks the incoming model, preserving any field whose
/// current value is [`store.Local`](./store.html#Local) and otherwise
/// taking the incoming value. Compose this with custom per-field merge
/// logic when the default slice-merge isn't enough.
///
/// Note the argument order matches the [`on_snapshot`](#on_snapshot) hook
/// signature: `(incoming, current)`.
pub fn merge_locals(incoming: model, current: model) -> model {
  ffi_merge_locals(incoming, current)
}

@target(javascript)
/// Push a new history entry and update the URL. Fires the [`url`](#url)
/// setter so the model reflects the new location, which lets
/// [`component.switch`](./component.html#switch) re-render based on the
/// route field of your model.
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
/// connection. Receives the server-assigned client id. Use this for
/// per-session bootstrap work like registering with analytics or kicking
/// off a one-time fetch.
///
/// Attach before [`connect`](#connect) so the hook is in place by the time
/// the first `Connected` frame arrives.
///
/// ```gleam
/// runtime
/// |> client.on_connect(fn(client_id) {
///   logging.info("connected as " <> client_id)
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
/// Register a hook that fires every time the transport drops the
/// connection. Companion to [`on_reconnect`](#on_reconnect) and
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
/// Register a hook that runs after each locally-dispatched message. This hook
/// fires for both session and topic messages. The `model` argument is the full
/// outer model after the message has been applied locally.
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
/// Register a hook that fires every time the transport restores the
/// connection after a drop. Does not fire on the first connect, see
/// [`on_connect`](#on_connect) for that.
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
/// Register a hook that runs when a server snapshot arrives on reconnect.
/// The hook receives `(incoming, current)` and returns the merged model
/// to dispatch into the runtime.
///
/// Without a hook, the runtime uses the wiring config to merge only the
/// snapshotted target's slice into the current model, leaving all other
/// slices intact. Compose with [`merge_locals`](#merge_locals) to additionally
/// preserve `store.Local` fields.
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
/// Replace the current history entry and update the URL. Fires the
/// [`url`](#url) setter. Use for view-state-in-URL changes that should
/// not create a back-button stop, such as a sort-order or filter toggle.
///
/// ```gleam
/// client.replace(runtime, "/projects?sort=newest")
/// ```
pub fn replace(runtime: Runtime(model, message), path path: String) -> Nil {
  let Runtime(handle) = runtime
  ffi_replace(handle, path)
}

@target(javascript)
/// Add a field to the session persistence configuration. Each field represents
/// a single value stored in `localStorage` under `lily_session_{key}`.
///
/// The `get` and `set` functions extract and inject the field from the session
/// type. The `encode` and `decoder` handle JSON serialisation.
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
/// Create an empty session persistence configuration, ready to be used by
/// adding fields using [`client.session_field`](#session_field).
///
/// There's an example above in [`client.attach_session`](#attach_session)
pub fn session_persistence() -> Persistence(session) {
  Persistence(fields: [])
}

@target(javascript)
/// Start the client runtime with a store and a wiring configuration. The
/// wiring config tells the runtime how to dispatch messages to the correct
/// server-side target (session store or a named topic store) and how to merge
/// incoming snapshots into the outer model.
///
/// Build the wiring config in your `shared` package and import it here:
///
/// ```gleam
/// let runtime =
///   store.new(shared.initial_model(), with: shared.update)
///   |> client.start(shared.wiring())
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
) -> Runtime(model, message) {
  let handle = create_runtime(store, store.apply)
  set_store(handle, store)
  set_wiring(handle, wiring)
  initial_notify(handle)
  Runtime(handle)
}

@target(javascript)
/// Subscribe this connection to a topic. The runtime sends a `Subscribe`
/// frame to the server; on `Snapshot` arrival the topic's slice in the model
/// is hydrated and components re-render. Idempotent, no-op if already
/// subscribed. Must be called after [`client.connect`](#connect).
///
/// ```gleam
/// runtime
/// |> client.connect(with: connector, serialiser: shared.serialiser())
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
/// Unsubscribe from a topic: sends an unsubscribe frame so the server stops
/// pushing updates for it. Fire-and-forget, the server sends no confirmation
/// and the topic's last slice value is left as-is in the model. Re-subscribing
/// pulls a fresh snapshot that replaces it (for stateful topics); clear it
/// sooner with your own message if you need to. Must be called after
/// [`client.connect`](#connect).
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
/// Track the browser URL in the model. The `set` callback receives the
/// parsed [`uri.Uri`](https://hexdocs.pm/gleam_stdlib/gleam/uri.html); map
/// it to your own route ADT inside. The initial URL is read on attach,
/// and changes from `popstate`, [`navigate`](#navigate), and
/// [`replace`](#replace) all flow through the same setter.
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
/// Get the current model from the runtime. Used internally by the session
/// module for hydrating persisted session data on startup.
@internal
pub fn get_current_model(runtime: Runtime(model, message)) -> model {
  let Runtime(handle) = runtime
  get_model(handle)
}

@target(javascript)
/// Extract the runtime handle from the runtime wrapper. Used internally by
/// other Lily modules (session, component) that need direct FFI access.
@internal
pub fn get_handle(runtime: Runtime(model, message)) -> RuntimeHandle {
  let Runtime(handle) = runtime
  handle
}

@target(javascript)
/// Internal wrapper for the send message FFI
/// (used in event.gleam)
@internal
pub fn send_message(runtime: Runtime(model, message), message: message) -> Nil {
  let Runtime(runtime_handle) = runtime
  ffi_send_message(runtime_handle, message)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(javascript)
/// Basic field for local persistence
type Field(session) {
  Field(
    key: String,
    get: fn(session) -> Json,
    set: fn(session, Dynamic) -> Result(session, Nil),
  )
}

@target(javascript)
/// The resolved [`intercept_links`](#intercept_links) options, seeded with
/// defaults and folded from the `config` list.
type InterceptConfig {
  InterceptConfig(within: String, opt_out: String)
}

@target(javascript)
/// JavaScript doesn't have type parameters, so we can't pass Runtime directly.
/// The public `Runtime(model, message)` type wraps this.
///
/// Differences between the two types:
///
/// - `Runtime(model, message)`: Public opaque type users interact with
/// - `RuntimeHandle`: Internal concrete type that matches the JavaScript
///   object returned by `createRuntime()`. `@internal` for use by other Lily
///   modules (component) that need FFI access.
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
      set_last_sequence_for_target(handle, target_to_key(target), sequence)

    Ok(transport.Connected(client_id:)) -> handle_client_id(handle, client_id)

    Ok(transport.Push(topic_id: _, payload:)) ->
      apply_remote_message(handle, payload)

    Ok(transport.TopicUpdate(topic_id:, sequence:, payload:)) -> {
      set_last_sequence_for_target(
        handle,
        target_to_key(transport.Topic(topic_id)),
        sequence,
      )
      apply_remote_message(handle, payload)
    }

    Ok(transport.SessionUpdate(sequence:, payload:)) -> {
      set_last_sequence_for_target(
        handle,
        target_to_key(transport.Session),
        sequence,
      )
      apply_remote_message(handle, payload)
    }

    Ok(transport.Snapshot(target:, sequence:, state:)) -> {
      set_last_sequence_for_target(handle, target_to_key(target), sequence)
      handle_snapshot(handle, wiring, target, state)
    }

    Ok(transport.Rejected(topic_id: _, reason: _)) -> Nil

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
fn intercept_config(config: List(InterceptOption)) -> InterceptConfig {
  list.fold(
    config,
    InterceptConfig(within: "document", opt_out: "data-lily-native"),
    fn(resolved, entry) {
      case entry {
        InterceptWithin(selector) ->
          InterceptConfig(..resolved, within: selector)
        InterceptOptOutAttribute(name) ->
          InterceptConfig(..resolved, opt_out: name)
      }
    },
  )
}

@target(javascript)
fn key_to_target(key: String) -> Result(transport.Target, Nil) {
  case key {
    "session" -> Ok(transport.Session)
    _ ->
      case string.starts_with(key, "topic:") {
        True -> Ok(transport.Topic(string.drop_start(key, 6)))
        False -> Error(Nil)
      }
  }
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
      key_to_target(key)
    })
  let bytes = transport.encode(transport.Resync(cursors:), serialiser:)
  send_via_transport(handle, bytes)
}

@target(javascript)
fn session_storage_prefix() -> String {
  "lily_session_"
}

@target(javascript)
fn target_to_key(target: transport.Target) -> String {
  case target {
    transport.Session -> "session"
    transport.Topic(id) -> "topic:" <> id
  }
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
@external(javascript, "./client.ffi.mjs", "handleClientId")
fn handle_client_id(handle: RuntimeHandle, client_id: String) -> Nil

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
@external(javascript, "./client.ffi.mjs", "storeSendFrame")
fn store_send_frame(
  handle: RuntimeHandle,
  send: fn(transport.Protocol(model, message)) -> Nil,
) -> Nil
