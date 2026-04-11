//// The [`Runtime`](#Runtime) is the core of every Lily application running
//// in the browser. It manages the update loop, component subscriptions, and
//// optional server synchronisation.
////
//// The runtime routes messages from events and the server to your update
//// function, notifies subscribed components when the model changes, and
//// optionally connects to a server to sync state across clients (see
//// [`client.connect`](#connect)). When connected, it monitors online/
//// offline status and queues messages in localStorage while disconnected.
////
//// The typical flow: create a store with [`store.new`](./store.html#new),
//// start the runtime with [`client.start`](#start), mount your UI using
//// [`component.mount`](./component.html#mount), attach event handlers with
//// [`event.on_click`](./event.html#on_click) and friends, then optionally
//// connect to a server with [`client.connect`](#connect)
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/event
//// import lily/store
//// import lily/transport/websocket
////
//// pub fn main() {
////   // 1. Create your store
////   let app_store = store.new(Model(count: 0), with: update)
////
////   // 2. Start the runtime
////   let runtime = client.start(app_store)
////
////   // 3. Mount your UI
////   runtime
////   |> component.mount(selector: "#app", to_html: element.to_string, view: app)
////
////   // 4. Attach events
////   |> event.on_click(selector: "#app", decoder: parse_msg)
////
////   // 5. Connect to server (optional)
////   |> client.connect(
////     with: websocket.config(url: "ws://localhost:8080/ws") |> websocket.connect,
////     serialiser: my_serialiser,
////   )
//// }
//// ```
////
//// Each [`Runtime`](#Runtime) is completely isolated, allowing multiple
//// independent Lily apps to coexist on the same page. However, we recommend
//// using one runtime per page to avoid splitting your application state.
//// If you need truly independent widget-style components, a different
//// framework may be more appropriate.
////
//// The runtime is pure JavaScript and works only on the
//// `@target(javascript)` platform. It uses a message queue to batch updates
//// and prevent race conditions, ensuring your update function is called
//// sequentially even when messages arrive from multiple sources (user
//// events, server messages, timers, etc.).
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import lily/transport
@target(javascript)
import lily/store.{type Store}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Opaque handle to a running Lily application instance. Each runtime is
/// isolated, allowing multiple independent apps on the same page.
@target(javascript)
pub opaque type Runtime(model, message) {
  Runtime(handle: RuntimeHandle)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Connect the runtime to a server using the provided transport. The
/// connector function is obtained from a transport implementation (e.g.,
/// `websocket.connect(config)` or `http.connect(config)`).
///
/// ## Example
///
/// ```gleam
/// import lily/transport/websocket
///
/// runtime
/// |> client.connect(
///   with: websocket.config(url: "ws://localhost:8080/ws")
///     |> websocket.reconnect_base_milliseconds(2000)
///     |> websocket.connect,
///   serialiser: my_serialiser,
/// )
/// ```
@target(javascript)
pub fn connect(
  runtime: Runtime(model, message),
  with connector: transport.Connector,
  serialiser serialiser: transport.Serialiser(model, message),
) -> Runtime(model, message) {
  let Runtime(handle) = runtime

  // Register model types for auto-serialiser (walks model recursively)
  let current_model = get_model(handle)
  ffi_register_model(current_model)

  // Build handler with protocol-level callbacks
  let handler =
    transport.Handler(
      on_receive: fn(text) { handle_incoming(handle, text, serialiser) },
      on_reconnect: fn() {
        set_connection_status(handle, True)
        send_resync(handle, serialiser)
      },
      on_disconnect: fn() { set_connection_status(handle, False) },
    )

  // Get transport from connector
  let client_transport = connector(handler)

  // Store transport for sending
  set_transport(handle, client_transport)

  // Set hook to serialise and send messages via transport
  set_on_message_hook(handle, fn(message) {
    let text =
      transport.encode(transport.ClientMessage(payload: message), serialiser:)
    send_via_transport(handle, text)
  })

  runtime
}

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
/// ## Example
///
/// ```gleam
/// runtime
/// |> client.connection_status(
///   get: fn(model) { model.connected },
///   set: fn(model, status) { Model(..model, connected: status) },
/// )
/// |> client.connect(
///   with: websocket.connect(config),
///   serialiser: my_serialiser,
/// )
/// ```
@target(javascript)
pub fn connection_status(
  runtime: Runtime(model, message),
  get get: fn(model) -> Bool,
  set set: fn(model, Bool) -> model,
) -> Runtime(model, message) {
  let Runtime(handle) = runtime
  set_connection_status_config(handle, get, set)
  runtime
}

/// Extract the runtime handle from the runtime wrapper. Used internally by
/// other lily modules (session, component) that need direct FFI access.
@target(javascript)
@internal
pub fn get_handle(runtime: Runtime(model, message)) -> RuntimeHandle {
  let Runtime(handle) = runtime
  handle
}

/// Get the current model from the runtime. Used internally by the session
/// module for hydrating persisted session data on startup.
@target(javascript)
@internal
pub fn get_current_model(runtime: Runtime(model, message)) -> model {
  let Runtime(handle) = runtime
  get_model(handle)
}

/// Set a new model in the runtime. Used internally by the session module to
/// apply hydrated session data. This bypasses the update function and does
/// not trigger a re-render cycle.
@target(javascript)
@internal
pub fn set_current_model(
  runtime: Runtime(model, message),
  model: model,
) -> Nil {
  let Runtime(handle) = runtime
  set_model(handle, model)
}

/// Get a dispatch function that sends messages into the runtime's update
/// loop. Use this for side effects that need to feed results back as messages
/// (fetch callbacks, timers, external listeners).
///
/// ## Example
///
/// ```gleam
/// let runtime = client.start(store)
/// let dispatch = client.dispatch(runtime)
///
/// fetch("/api/data", fn(response) {
///   dispatch(DataReceived(response))
/// })
/// ```
@target(javascript)
pub fn dispatch(
  runtime: Runtime(model, message),
) -> fn(message) -> Nil {
  let Runtime(handle) = runtime
  fn(message) { ffi_send_message(handle, message) }
}

/// Register a hook that runs after each locally-dispatched message. Does not
/// fire for remote messages from other clients.
///
/// ## Example
///
/// ```gleam
/// let dispatch = client.dispatch(runtime)
///
/// client.on_message(runtime, fn(message, model) {
///   case message {
///     FetchUsers -> fetch("/api/users", fn(users) {
///       dispatch(UsersLoaded(users))
///     })
///     _ -> Nil
///   }
/// })
/// ```
@target(javascript)
pub fn on_message(
  runtime: Runtime(model, message),
  hook: fn(message, model) -> Nil,
) -> Nil {
  let Runtime(handle) = runtime
  set_user_message_hook(handle, hook)
}

/// Start the client runtime. Returns a Runtime handle that should be used
/// with [`component.mount`](./component.html#mount), event handlers, and
/// optionally [`client.connect`](#connect).
///
/// ## Example
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
@target(javascript)
pub fn start(store: Store(model, message)) -> Runtime(model, message) {
  let handle =
    create_runtime(store, store.apply, store.notify, store.subscribe)
  store.notify(store)
  set_store(handle, store)
  Runtime(handle)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Internal wrapper for the clear component cache FFI
/// (used in component.gleam)
@internal
@target(javascript)
pub fn clear_component_cache(
  runtime: Runtime(model, message),
  selector: String,
) -> Nil {
  let Runtime(runtime_handle) = runtime
  ffi_clear_component_cache(runtime_handle, selector)
}

/// Internal wrapper for the send message FFI
/// (used in event.gleam)
@internal
@target(javascript)
pub fn send_message(runtime: Runtime(model, message), message: message) -> Nil {
  let Runtime(runtime_handle) = runtime
  ffi_send_message(runtime_handle, message)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

/// JavaScript doesn't have type parameters, so we can't pass Runtime directly.
/// The public `Runtime(model, message)` type wraps this for type safety:
///
/// - `Runtime(model, message)`: Public opaque type users interact with,
///   parameterized for compile-time type safety
/// - `RuntimeHandle`: Internal concrete type that matches the JavaScript
///   object returned by `createRuntime()`. Marked `@internal` for use by
///   other lily modules (session, component) that need FFI access.
@target(javascript)
@internal
pub type RuntimeHandle

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/// Handles incoming message from the server, decodes it, set local sequences
/// (if any), and takes any appropriate actions.
@target(javascript)
fn handle_incoming(
  handle: RuntimeHandle,
  text: String,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  case transport.decode(text, serialiser:) {
    Ok(transport.ServerMessage(sequence:, payload:)) -> {
      set_last_sequence(handle, sequence)
      apply_remote_message(handle, payload)
    }

    Ok(transport.Snapshot(sequence:, state:)) -> {
      set_last_sequence(handle, sequence)
      dispatch_model(handle, state)
    }

    Ok(transport.Acknowledge(sequence:)) -> {
      set_last_sequence(handle, sequence)
    }

    Ok(transport.ClientMessage(payload: _payload)) -> Nil
    Ok(transport.Resync(after_sequence: _after_sequence)) -> Nil

    Error(_error) -> Nil
  }
}

/// Send a resync request
@target(javascript)
fn send_resync(
  handle: RuntimeHandle,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  let last_sequence = get_last_sequence(handle)
  let text =
    transport.encode(transport.Resync(after_sequence: last_sequence), serialiser:)
  send_via_transport(handle, text)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

/// Applies server message to the current client runtime state
@target(javascript)
@external(javascript, "./client.ffi.mjs", "applyRemoteMessage")
fn apply_remote_message(_handle: RuntimeHandle, _message: message) -> Nil {
  Nil
}

/// Create a new runtime instance
@target(javascript)
@external(javascript, "./client.ffi.mjs", "createRuntime")
fn create_runtime(
  _store: Store(model, message),
  _apply: fn(Store(model, message), message) -> Store(model, message),
  _notify: fn(Store(model, message)) -> Nil,
  _subscribe: fn(Store(model, message), String, fn(model) -> Nil) ->
    Store(model, message),
) -> RuntimeHandle {
  // This will never run (RuntimeHandle is only a JavaScript type so we're
  // putting it here as a workaround)
  panic as "createRuntime is only available in JavaScript"
}

/// Dispatch the current model to listeners
@target(javascript)
@external(javascript, "./client.ffi.mjs", "dispatchModel")
fn dispatch_model(_handle: RuntimeHandle, _model: model) -> Nil {
  Nil
}

// The two FFI functions below are needed as our JavaScript code works with
// RuntimeHandle and our `@internal` Gleam functions work with Runtime.
// Conversion between the two is handled by the Gleam functions that wrap the
// FFI functions.

/// Clear the component cache
@target(javascript)
@external(javascript, "./client.ffi.mjs", "clearComponentCache")
fn ffi_clear_component_cache(_handle: RuntimeHandle, _selector: String) -> Nil {
  Nil
}

/// Send the FFI message
@target(javascript)
@external(javascript, "./client.ffi.mjs", "sendMessage")
fn ffi_send_message(_handle: RuntimeHandle, _message: message) -> Nil {
  Nil
}

/// Get the last key sequence for localStorage
@target(javascript)
@external(javascript, "./client.ffi.mjs", "getLastSequence")
fn get_last_sequence(_handle: RuntimeHandle) -> Int {
  0
}

/// Get the current model from the runtime
@target(javascript)
@external(javascript, "./client.ffi.mjs", "getModel")
fn get_model(_handle: RuntimeHandle) -> model {
  panic as "getModel is only available in JavaScript"
}

/// Set the current model in the runtime
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setModel")
fn set_model(_handle: RuntimeHandle, _model: model) -> Nil {
  Nil
}

/// Send via transport (WebSockets/HTTP)
@target(javascript)
@external(javascript, "./client.ffi.mjs", "sendViaTransport")
fn send_via_transport(_handle: RuntimeHandle, _text: String) -> Nil {
  Nil
}

/// Set connection status in the model
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setConnectionStatus")
fn set_connection_status(_handle: RuntimeHandle, _connected: Bool) -> Nil {
  Nil
}

/// Store connection status config on runtime
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setConnectionStatusConfig")
fn set_connection_status_config(
  _handle: RuntimeHandle,
  _get: fn(model) -> Bool,
  _set: fn(model, Bool) -> model,
) -> Nil {
  Nil
}

/// Set the last key sequence for local storage
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setLastSequence")
fn set_last_sequence(_handle: RuntimeHandle, _sequence: Int) -> Nil {
  Nil
}

/// Set the function that runs when a message happens (runs once)
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setOnMessageHook")
fn set_on_message_hook(
  _handle: RuntimeHandle,
  _hook: fn(message) -> Nil,
) -> Nil {
  Nil
}

/// Set the current store
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setStore")
fn set_store(_handle: RuntimeHandle, _store: Store(model, message)) -> Nil {
  Nil
}

/// Set the transport
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setTransport")
fn set_transport(
  _handle: RuntimeHandle,
  _transport: transport.Transport,
) -> Nil {
  Nil
}

/// Set the user message hook that runs after each locally-dispatched message
@target(javascript)
@external(javascript, "./client.ffi.mjs", "setUserMessageHook")
fn set_user_message_hook(
  _handle: RuntimeHandle,
  _hook: fn(message, model) -> Nil,
) -> Nil {
  Nil
}

/// Register model constructors for auto-serialiser
@target(javascript)
@external(javascript, "./transport.ffi.mjs", "registerModel")
fn ffi_register_model(_model: model) -> Nil {
  Nil
}
