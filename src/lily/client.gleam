//// The client within Lily manages the [`Runtime`](#Runtime) within Lily,
//// managing the update loop, component subscriptions, local persistence,
//// and server synchronisation. When connected, it also monitors online/
//// offline status and queues messages in localStorage while disconnected. The
//// client is meant to be used on the browser-side, so the Erlang compilation
//// target is not supported by this module.
////
//// The typical frontend setup would look like:
////
//// 1. Creating a store with [`store.new`](./store.html#new)
//// 2. Starting the runtime with [`client.start`](#start)
//// 3. Mounting your components using
////    [`component.mount`](./component.html#mount)
//// 4. Attaching event handlers
//// 5. Connecting to a server with [`client.connect`](#connect)
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/event
//// import lily/store
//// import lily/transport
////
//// pub fn main() {
////   // 1. Create your store
////   let app_store = store.new(Model(count: 0), with: update)
////
////   // 2. Start the runtime
////   let runtime = client.start(app_store)
////
////   // 3. Mount UI
////   |> component.mount(selector: "#app", to_html: element.to_string, view: app)
////   // 4. Attach events
////   |> event.on_click(selector: "#app", decoder: parse_msg)
////
////   // 5. Connect to server
////   |> client.connect(
////     with: transport.websocket(url: "ws://localhost:8080/ws")
////       |> transport.websocket_connect,
////     serialiser: my_serialiser, // see transport module for more information
////   )
//// }
//// ```
////
//// Each [`Runtime`](#Runtime) is completely isolated, allowing multiple
//// independent Lily runtimes to coexist on the same page. However, we
//// recommend using one runtime per page to avoid splitting your application
//// state (which can become hard to manage à la badly designed React apps
//// with states everywhere). If you need truly stateful, independent
//// widget-style components, a different framework may be more appropriate.
////
//// The client runtime uses a message queue to batch updates and prevent race
//// conditions, ensuring your update function is called sequentially even when
//// messages arrive from multiple sources (user events, server messages,
//// timers, etc.).
////

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
import gleam/result
@target(javascript)
import lily/store.{type Store}
@target(javascript)
import lily/transport

// =============================================================================
// PUBLIC TYPES
// =============================================================================

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
/// client.start(app_store)
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
  let current_model = get_current_model(runtime)
  let hydrated_session = hydrate_session(persistence, get(current_model))
  let hydrated_model = set(current_model, hydrated_session)
  set_current_model(runtime, hydrated_model)
  let Runtime(handle) = runtime
  ffi_set_session_config(handle, persistence, get, set)
  runtime
}

@target(javascript)
/// Clear all Lily related session data from `localStorage` by removing all
/// keys with the `lily_session_` prefix.
///
/// ## Example
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
/// Connect the runtime to a server using the provided transport method. The
/// connector function is obtained from a transport implementation, e.g.
/// [`websocket_connect(config)`](./transport.html#websocket_connect) or
/// [`http_connect(config)`](./transport.html#http_connect).
///
/// This also creates all the handlers for handling incoming messages, and
/// changes to connection status.
///
/// ```gleam
/// import lily/transport
///
/// runtime
/// |> client.connect(
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.reconnect_base_milliseconds(2000)
///     |> transport.websocket_connect,
///   serialiser: my_serialiser,
/// )
/// ```
pub fn connect(
  runtime: Runtime(model, message),
  with connector: transport.Connector,
  serialiser serialiser: transport.Serialiser(model, message),
) -> Runtime(model, message) {
  let Runtime(handle) = runtime

  let handler =
    transport.Handler(
      on_receive: fn(bytes) { handle_incoming(handle, bytes, serialiser) },
      on_reconnect: fn() {
        set_connection_status(handle, True)
        send_resync(handle, serialiser)
      },
      on_disconnect: fn() { set_connection_status(handle, False) },
    )

  let client_transport = connector(handler)

  set_transport(handle, client_transport)

  set_on_message_hook(handle, fn(message) {
    let bytes =
      transport.encode(transport.ClientMessage(payload: message), serialiser:)
    send_via_transport(handle, bytes)
  })

  runtime
}

@target(javascript)
/// Often times you want to be able to track the connection status (for
/// example, if you want to disable an element when there is no connection).
/// This sets up tracking for the connection status in the model, with Lily
/// calling `set` with `True` when the transport connects and `False` when it
/// disconnects. Components can slice this field to react to connectivity
/// changes.
///
/// `get` provides the way to read the connection status from the model (the
/// user-defined model type should then have a way to save this status) and
/// `set` provides a way to write into the model.
///
/// This should be called before [`client.connect`](#connect) to ensure the
/// initial connection state is captured.
///
/// Also note that while this call is optional, connection status is tracked
/// regardless internally, this mainly allows the status to be reflected within
/// the model.
///
/// ## Example
///
/// ```gleam
/// runtime
/// |> client.connection_status(
///   get: fn(model) { model.connected },
///   set: fn(model, status) { Model(..model, connected: status) },
/// )
/// |> client.connect(
///   with: transport.websocket(url: "ws://localhost:8080/ws")
///     |> transport.websocket_connect,
///   serialiser: my_serialiser,
/// )
/// ```
pub fn connection_status(
  runtime: Runtime(model, message),
  get get: fn(model) -> Bool,
  set set: fn(model, Bool) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_connection_status_config(handle, get, set)
  runtime
}

@target(javascript)
/// Get a dispatch function that sends messages into the runtime's update
/// loop. Since the [`Store`](./store.html#Store), this is needed to handle
/// side-effects (like fetch callbacks or timers). After generating the dispatch
/// function, you are able to use this to send updates whenever some side-effect
/// is called to update the store again.
///
/// ```gleam
/// let runtime = client.start(store)
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
/// The default snapshot reconciliation: recursively walk the incoming
/// model, preserving any field whose current value is
/// [`store.Local`](./store.html#Local) and otherwise taking the incoming
/// value. Compose with [`on_snapshot`](#on_snapshot) when you want the
/// default plus per-field overrides.
///
/// Note the argument order matches the [`on_snapshot`](#on_snapshot) hook
/// signature: `(incoming, current)`.
pub fn merge_locals(incoming: model, current: model) -> model {
  ffi_merge_locals(incoming, current)
}

@target(javascript)
/// Register a hook that runs after each locally-dispatched message. Does not
/// fire for remote messages from other clients.
///
/// ## Example
///
/// ```gleam
/// runtime
/// |> client.connect(with: connector, serialiser: my_serialiser)
/// |> client.on_message(fn(message, model) {
///   case message {
///     FetchUsers -> fetch("/api/users", fn(users) {
///       dispatch(UsersLoaded(users))
///     })
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
/// Register a hook that runs when a server snapshot arrives on reconnect.
/// The hook receives `(incoming, current)` and returns the merged model
/// to dispatch into the runtime.
///
/// Without a hook, the runtime preserves any field whose current value is
/// wrapped in [`store.Local`](./store.html#Local) and otherwise adopts the
/// incoming snapshot. Compose with [`merge_locals`](#merge_locals) to keep
/// that behaviour and add per-field overrides on top.
///
/// ## Example
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
/// Add a field to the session persistence configuration. Each field represents
/// a single value stored in `localStorage` under `lily_session_{key}`.
///
/// The `get` and `set` functions extract and inject the field from the session
/// type. The `encode` and `decoder` handle JSON serialisation.
///
/// ## Example
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
/// Start the client runtime. Returns a Runtime handle that should be used
/// with [`component.mount`](./component.html#mount), event handlers, and
/// [`client.connect`](#connect).
///
/// ```gleam
/// let runtime =
///   store.new(Model(count: 0), with: update)
///   |> client.start
///
/// runtime
/// |> component.mount(selector: "#app", to_html: element.to_string, view: app)
/// |> event.on_click(selector: "#app", decoder: parse_msg)
/// ```
pub fn start(store: Store(model, message)) -> Runtime(model, message) {
  let handle = create_runtime(store, store.apply)
  set_store(handle, store)
  initial_notify(handle)
  Runtime(handle)
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

@target(javascript)
/// Set a new model in the runtime. Used internally by the session module to
/// apply hydrated session data. This bypasses the update function and does
/// not trigger a re-render cycle.
@internal
pub fn set_current_model(runtime: Runtime(model, message), model: model) -> Nil {
  let Runtime(handle) = runtime
  set_model(handle, model)
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
/// JavaScript doesn't have type parameters, so we can't pass Runtime directly.
/// The public `Runtime(model, message)` type wraps this.
///
/// Differences between the two types:
///
/// - `Runtime(model, message)`: Public opaque type users interact with
/// - `RuntimeHandle`: Internal concrete type that matches the JavaScript
///   object returned by `createRuntime()`. `@internal` for use by other Lily /////   modules (component) that need FFI access.
@internal
pub type RuntimeHandle

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(javascript)
/// Hydrates the model from local persistence
fn hydrate_session(
  persistence: Persistence(session),
  initial: session,
) -> session {
  let Persistence(fields) = persistence
  list.fold(fields, initial, fn(session, f) {
    let Field(key, _get, set) = f
    ffi_read_field(session_storage_prefix(), key)
    |> result.try(set(session, _))
    |> result.unwrap(session)
  })
}

@target(javascript)
/// Prefix for session storage; hopefully doesn't clash with most fields. Still
/// debating whether or not this should be configurable or if that would be
/// overkill for a public API.
fn session_storage_prefix() -> String {
  "lily_session_"
}

@target(javascript)
/// Handles incoming message from the server, decodes it, set local sequences
/// (if any), and takes any appropriate actions.
fn handle_incoming(
  handle: RuntimeHandle,
  bytes: BitArray,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  case transport.decode(bytes, serialiser:) {
    Ok(transport.Acknowledge(sequence:)) -> {
      set_last_sequence(handle, sequence)
    }

    Ok(transport.ClientMessage(payload: _payload)) -> Nil

    Ok(transport.Push(payload:)) -> apply_remote_message(handle, payload)

    Ok(transport.ServerMessage(sequence:, payload:)) -> {
      set_last_sequence(handle, sequence)
      apply_remote_message(handle, payload)
    }

    Ok(transport.Snapshot(sequence:, state:)) -> {
      set_last_sequence(handle, sequence)
      merge_local_and_dispatch(handle, state)
    }

    Ok(transport.Resync(after_sequence: _after_sequence)) -> Nil

    Error(_error) -> Nil
  }
}

@target(javascript)
/// Send a resync request
fn send_resync(
  handle: RuntimeHandle,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  let last_sequence = get_last_sequence(handle)
  let bytes =
    transport.encode(
      transport.Resync(after_sequence: last_sequence),
      serialiser:,
    )
  send_via_transport(handle, bytes)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
/// Applies server message to the current client runtime state
@external(javascript, "./client.ffi.mjs", "applyRemoteMessage")
fn apply_remote_message(_handle: RuntimeHandle, _message: message) -> Nil {
  Nil
}

@target(javascript)
/// Create a new runtime instance
@external(javascript, "./client.ffi.mjs", "createRuntime")
fn create_runtime(
  _store: Store(model, message),
  _apply: fn(Store(model, message), message) -> Store(model, message),
) -> RuntimeHandle {
  // This will never run (RuntimeHandle is only a JavaScript type so we're
  // putting it here as a workaround)
  panic as "createRuntime is only available in JavaScript"
}

@target(javascript)
/// Send the FFI message
@external(javascript, "./client.ffi.mjs", "sendMessage")
fn ffi_send_message(_handle: RuntimeHandle, _message: message) -> Nil {
  Nil
}

@target(javascript)
/// Get the last key sequence for localStorage
@external(javascript, "./client.ffi.mjs", "getLastSequence")
fn get_last_sequence(_handle: RuntimeHandle) -> Int {
  0
}

@target(javascript)
/// Get the current model from the runtime
@external(javascript, "./client.ffi.mjs", "getModel")
fn get_model(_handle: RuntimeHandle) -> model {
  panic as "getModel is only available in JavaScript"
}

@target(javascript)
/// Notify all subscribers with the current state — called once during start to
/// trigger the initial render
@external(javascript, "./client.ffi.mjs", "initialNotify")
fn initial_notify(_handle: RuntimeHandle) -> Nil {
  Nil
}

@target(javascript)
/// Apply a server snapshot to the runtime, preserving any Local fields from
/// the current client model
@external(javascript, "./client.ffi.mjs", "mergeLocalAndDispatch")
fn merge_local_and_dispatch(_handle: RuntimeHandle, _state: model) -> Nil {
  Nil
}

@target(javascript)
/// Send via transport (WebSockets/HTTP)
@external(javascript, "./client.ffi.mjs", "sendViaTransport")
fn send_via_transport(_handle: RuntimeHandle, _bytes: BitArray) -> Nil {
  Nil
}

@target(javascript)
/// Set connection status in the model
@external(javascript, "./client.ffi.mjs", "setConnectionStatus")
fn set_connection_status(_handle: RuntimeHandle, _connected: Bool) -> Nil {
  Nil
}

@target(javascript)
/// Store connection status config on runtime
@external(javascript, "./client.ffi.mjs", "setConnectionStatusConfig")
fn set_connection_status_config(
  _handle: RuntimeHandle,
  _get: fn(model) -> Bool,
  _set: fn(model, Bool) -> model,
) -> Nil {
  Nil
}

@target(javascript)
/// Set the last key sequence for local storage
@external(javascript, "./client.ffi.mjs", "setLastSequence")
fn set_last_sequence(_handle: RuntimeHandle, _sequence: Int) -> Nil {
  Nil
}

@target(javascript)
/// Set the current model in the runtime
@external(javascript, "./client.ffi.mjs", "setModel")
fn set_model(_handle: RuntimeHandle, _model: model) -> Nil {
  Nil
}

@target(javascript)
/// Set the function that runs when a message happens (runs once)
@external(javascript, "./client.ffi.mjs", "setOnMessageHook")
fn set_on_message_hook(_handle: RuntimeHandle, _hook: fn(message) -> Nil) -> Nil {
  Nil
}

@target(javascript)
/// Set the current store
@external(javascript, "./client.ffi.mjs", "setStore")
fn set_store(_handle: RuntimeHandle, _store: Store(model, message)) -> Nil {
  Nil
}

@target(javascript)
/// Set the transport
@external(javascript, "./client.ffi.mjs", "setTransport")
fn set_transport(_handle: RuntimeHandle, _transport: transport.Transport) -> Nil {
  Nil
}

@target(javascript)
/// Set the user message hook that runs after each locally-dispatched message
@external(javascript, "./client.ffi.mjs", "setUserMessageHook")
fn set_user_message_hook(
  _handle: RuntimeHandle,
  _hook: fn(message, model) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
/// Set the user snapshot hook that runs when a server snapshot arrives on
/// reconnect, replacing the default `Local`-preserving merge
@external(javascript, "./client.ffi.mjs", "setSnapshotHook")
fn set_snapshot_hook(
  _handle: RuntimeHandle,
  _hook: fn(model, model) -> model,
) -> Nil {
  Nil
}

@target(javascript)
/// Clear all session keys from localStorage
@external(javascript, "./client.ffi.mjs", "clearSession")
fn ffi_clear_session(_prefix: String) -> Nil {
  Nil
}

@target(javascript)
/// Read a field from localStorage as a raw dynamic value for direct decoding
@external(javascript, "./client.ffi.mjs", "readField")
fn ffi_read_field(_prefix: String, _key: String) -> Result(Dynamic, Nil) {
  Error(Nil)
}

@target(javascript)
/// Public binding for the default reconciliation merge. Flips argument
/// order to match the `on_snapshot` hook signature.
@external(javascript, "./client.ffi.mjs", "mergeLocals")
fn ffi_merge_locals(_incoming: model, _current: model) -> model {
  panic as "mergeLocals is only available in JavaScript"
}

@target(javascript)
/// Store session config on runtime
@external(javascript, "./client.ffi.mjs", "setSessionConfig")
fn ffi_set_session_config(
  _handle: RuntimeHandle,
  _persistence: Persistence(session),
  _get: fn(model) -> session,
  _set: fn(model, session) -> model,
) -> Nil {
  Nil
}
