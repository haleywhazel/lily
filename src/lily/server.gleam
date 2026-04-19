//// The [`Server`](#Server) holds authoritative state and broadcasts updates
//// to connected clients. It works on both Erlang and JavaScript targets,
//// though we recommend Erlang for production use.
////
//// On Erlang, the server uses an OTP actor with sequential message
//// processing. On JavaScript, it uses closure-scoped mutable state (JS is
//// single-threaded). Both expose identical APIs - the same
//// [`Server`](#Server) opaque type and public functions work on both
//// targets.
////
//// The server owns the canonical [`Store`](./store.html#Store), applies
//// client messages sequentially while assigning sequence numbers, broadcasts
//// updates to all clients except the originator, and sends full state
//// snapshots to clients that reconnect
////
//// ```gleam
//// import lily/server
//// import lily/store
//// import lily/transport
////
//// pub fn main() {
////   // Create your store
////   let app_store = store.new(initial_model, with: update)
////
////   // Start the server
////   let assert Ok(srv) = server.start(
////     store: app_store,
////     serialiser: transport.automatic(),
////   )
////
////   // Register side-effect hook (optional)
////   server.on_message(srv, fn(msg, model, client_id) {
////     case msg {
////       SaveDocument(doc) -> db.write(doc)
////       _ -> Nil
////     }
////   })
////
////   // Wire into your transport (mist/wisp WebSocket handler)
////   // See server/handler.gleam for examples
//// }
//// ```
////
//// The server is transport-agnostic. It doesn't depend on mist or wisp -
//// those are your backend dependencies. Use [`server.connect`](#connect),
//// [`server.disconnect`](#disconnect), and [`server.incoming`](#incoming)
//// to wire the server into your WebSocket or HTTP handlers. See
//// `lily/src/lily/server/handler.gleam` for a complete example with mist
//// and wisp.
////
//// Note: within this module, "message" often refers to internal events, not
//// your user-defined message type for model updates.
////

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/result
import lily/store.{type Store}
import lily/transport.{type Serialiser}

@target(erlang)
import gleam/erlang/process.{type Subject}
@target(erlang)
import gleam/otp/actor

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// This is a handle to a running Lily server instance. Wraps platform-specific
/// internals (OTP actor on Erlang, closure-scoped state on JavaScript).
pub opaque type Server(model, message) {
  Server(handle: ServerHandle(model, message))
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Register a client connection with the server. The `send` callback is how
/// the server pushes messages back to this specific client.
///
/// On Erlang, if you have a `Subject(BitArray)` from mist's WebSocket handler,
/// wrap it: `send: process.send(outgoing_subject, _)`.
///
/// ## Example
///
/// ```gleam
/// // Erlang with mist WebSocket
/// let outgoing_subject = process.new_subject()
/// server.connect(srv, client_id: "abc123", send: process.send(outgoing_subject, _))
///
/// // JavaScript with Node.js WebSocket
/// server.connect(srv, client_id: "abc123", send: fn(bytes) { ws.send(bytes) })
/// ```
pub fn connect(
  server: Server(model, message),
  client_id client_id: String,
  send send: fn(BitArray) -> Nil,
) -> Nil {
  platform_connect(server.handle, client_id, send)
}

/// Unregister a client connection from the server. Called when a client
/// disconnects.
pub fn disconnect(
  server: Server(model, message),
  client_id client_id: String,
) -> Nil {
  platform_disconnect(server.handle, client_id)
}

/// Process an incoming message from a client. The bytes should be a
/// serialised [`transport.Protocol`](./transport.html#Protocol) message.
pub fn incoming(
  server: Server(model, message),
  client_id client_id: String,
  bytes bytes: BitArray,
) -> Nil {
  platform_incoming(server.handle, client_id, bytes)
}

/// Register a hook that runs after each client message is processed on the
/// server. Receives the decoded message, updated model, and client id.
///
/// ## Example
///
/// ```gleam
/// server.on_message(server, fn(message, model, client_id) {
///   case message {
///     SaveDocument(doc) -> db.write(doc)
///     SendEmail(to, body) -> email.send(to, body)
///     _ -> Nil
///   }
/// })
/// ```
pub fn on_message(
  server: Server(model, message),
  hook: fn(message, model, String) -> Nil,
) -> Nil {
  platform_set_hook(server.handle, hook)
}

/// Start a new server instance with the given store and serialiser. Returns
/// `Ok(server)` on success, or `Error(Nil)` if the server fails to start
/// (Erlang actor init failure, though this is rare with simple init logic).
///
/// On JavaScript, this always returns `Ok`.
///
/// ## Example
///
/// ```gleam
/// import lily/server
/// import lily/store
///
/// let app_store = store.new(initial_model, with: update)
/// let assert Ok(srv) = server.start(store: app_store, serialiser: my_serialiser)
/// ```
pub fn start(
  store store: Store(model, message),
  serialiser serialiser: Serialiser(model, message),
) -> Result(Server(model, message), Nil) {
  let initial_state =
    ServerState(
      store:,
      clients: dict.new(),
      sequence: 0,
      serialiser:,
      on_message_hook: option.None,
    )

  platform_start(initial_state)
  |> result.map(Server)
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

@target(erlang)
/// Platform-specific server handle (Subject on Erlang, FFI handle on JavaScript)
type ServerHandle(model, message) =
  Subject(InternalEvent(model, message))

@target(javascript)
type ServerHandle(model, message)

@target(erlang)
/// Internal events for Erlang actor message passing
type InternalEvent(model, message) {
  ClientConnected(client_id: String, send: fn(BitArray) -> Nil)
  ClientDisconnected(client_id: String)
  Incoming(client_id: String, bytes: BitArray)
  SetHook(hook: fn(message, model, String) -> Nil)
}

/// Stores the current server state: model, clients, sequence, and serialiser
type ServerState(model, message) {
  ServerState(
    store: Store(model, message),
    clients: Dict(String, fn(BitArray) -> Nil),
    sequence: Int,
    serialiser: Serialiser(model, message),
    on_message_hook: Option(fn(message, model, String) -> Nil),
  )
}

// =============================================================================
// PRIVATE FUNCTIONS — SHARED LOGIC
// =============================================================================

/// Broadcast to all clients except the excluded one
fn broadcast_except(
  clients: Dict(String, fn(BitArray) -> Nil),
  bytes: BitArray,
  except excluded_id: String,
) -> Nil {
  dict.each(clients, fn(id, send) {
    case id == excluded_id {
      True -> Nil
      False -> send(bytes)
    }
  })
}

/// Handle a client connection by inserting into clients dict
fn handle_client_connected_logic(
  state: ServerState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> ServerState(model, message) {
  let clients = dict.insert(state.clients, client_id, send)
  ServerState(..state, clients:)
}

/// Handle a client disconnection by removing from clients dict
fn handle_client_disconnected_logic(
  state: ServerState(model, message),
  client_id: String,
) -> ServerState(model, message) {
  let clients = dict.delete(state.clients, client_id)
  ServerState(..state, clients:)
}

/// Handle an incoming ClientMessage
fn handle_client_message_logic(
  state: ServerState(model, message),
  client_id: String,
  payload: message,
) -> ServerState(model, message) {
  let updated_store = store.apply(state.store, message: payload)
  let new_sequence = state.sequence + 1

  let server_message = transport.ServerMessage(sequence: new_sequence, payload:)
  let encoded = transport.encode(server_message, serialiser: state.serialiser)
  broadcast_except(state.clients, encoded, except: client_id)

  let acknowledge = transport.Acknowledge(sequence: new_sequence)
  let acknowledge_encoded =
    transport.encode(acknowledge, serialiser: state.serialiser)
  case dict.get(state.clients, client_id) {
    Ok(send) -> send(acknowledge_encoded)
    Error(Nil) -> Nil
  }

  case state.on_message_hook {
    option.Some(hook) -> hook(payload, updated_store.model, client_id)
    option.None -> Nil
  }

  ServerState(..state, store: updated_store, sequence: new_sequence)
}

/// For an incoming payload, handle if it's a Resync or a ClientMessage
fn handle_incoming_logic(
  state: ServerState(model, message),
  client_id: String,
  bytes: BitArray,
) -> ServerState(model, message) {
  case transport.decode(bytes, serialiser: state.serialiser) {
    Ok(transport.ClientMessage(payload:)) ->
      handle_client_message_logic(state, client_id, payload)

    Ok(transport.Resync(after_sequence:)) ->
      handle_resync_logic(state, client_id, after_sequence)

    _ -> state
  }
}

/// Handle a resync request by sending a snapshot of the current model
fn handle_resync_logic(
  state: ServerState(model, message),
  client_id: String,
  _after_sequence: Int,
) -> ServerState(model, message) {
  case dict.get(state.clients, client_id) {
    Error(Nil) -> state
    Ok(send) -> {
      let snapshot =
        transport.Snapshot(sequence: state.sequence, state: state.store.model)
      let bytes = transport.encode(snapshot, serialiser: state.serialiser)
      send(bytes)
      state
    }
  }
}

// =============================================================================
// PRIVATE FUNCTIONS — ERLANG
// =============================================================================

@target(erlang)
/// Handle a client connection event (Erlang actor wrapper)
fn handle_client_connected(
  state: ServerState(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> actor.Next(ServerState(model, message), InternalEvent(model, message)) {
  handle_client_connected_logic(state, client_id, send)
  |> actor.continue
}

@target(erlang)
/// Handle a client disconnection event (Erlang actor wrapper)
fn handle_client_disconnected(
  state: ServerState(model, message),
  client_id: String,
) -> actor.Next(ServerState(model, message), InternalEvent(model, message)) {
  handle_client_disconnected_logic(state, client_id)
  |> actor.continue
}

@target(erlang)
/// Handle an incoming message event (Erlang actor wrapper)
fn handle_incoming(
  state: ServerState(model, message),
  client_id: String,
  bytes: BitArray,
) -> actor.Next(ServerState(model, message), InternalEvent(model, message)) {
  handle_incoming_logic(state, client_id, bytes)
  |> actor.continue
}

@target(erlang)
/// Actor message handler (Erlang)
fn handle_message(
  state: ServerState(model, message),
  message: InternalEvent(model, message),
) -> actor.Next(ServerState(model, message), InternalEvent(model, message)) {
  case message {
    ClientConnected(client_id:, send:) ->
      handle_client_connected(state, client_id, send)

    ClientDisconnected(client_id:) ->
      handle_client_disconnected(state, client_id)

    Incoming(client_id:, bytes:) -> handle_incoming(state, client_id, bytes)

    SetHook(hook:) ->
      ServerState(..state, on_message_hook: option.Some(hook))
      |> actor.continue
  }
}

@target(erlang)
/// Send a client connected event to the Erlang actor
fn platform_connect(
  handle: ServerHandle(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  actor.send(handle, ClientConnected(client_id:, send:))
}

@target(erlang)
/// Send a client disconnected event to the Erlang actor
fn platform_disconnect(
  handle: ServerHandle(model, message),
  client_id: String,
) -> Nil {
  actor.send(handle, ClientDisconnected(client_id:))
}

@target(erlang)
/// Send an incoming message event to the Erlang actor
fn platform_incoming(
  handle: ServerHandle(model, message),
  client_id: String,
  bytes: BitArray,
) -> Nil {
  actor.send(handle, Incoming(client_id:, bytes:))
}

@target(erlang)
/// Send a set hook event to the Erlang actor
fn platform_set_hook(
  handle: ServerHandle(model, message),
  hook: fn(message, model, String) -> Nil,
) -> Nil {
  actor.send(handle, SetHook(hook:))
}

@target(erlang)
/// Start the Erlang OTP actor
fn platform_start(
  initial_state: ServerState(model, message),
) -> Result(ServerHandle(model, message), Nil) {
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Nil)
}

// =============================================================================
// PRIVATE FUNCTIONS — JAVASCRIPT
// =============================================================================

@target(javascript)
/// Register a client connection (JavaScript)
fn platform_connect(
  handle: ServerHandle(model, message),
  client_id: String,
  send: fn(BitArray) -> Nil,
) -> Nil {
  ffi_connect(handle, client_id, send)
}

@target(javascript)
/// Unregister a client connection (JavaScript)
fn platform_disconnect(
  handle: ServerHandle(model, message),
  client_id: String,
) -> Nil {
  ffi_disconnect(handle, client_id)
}

@target(javascript)
/// Process an incoming message (JavaScript)
fn platform_incoming(
  handle: ServerHandle(model, message),
  client_id: String,
  bytes: BitArray,
) -> Nil {
  ffi_incoming(handle, client_id, bytes)
}

@target(javascript)
/// Set the message hook (JavaScript)
fn platform_set_hook(
  handle: ServerHandle(model, message),
  hook: fn(message, model, String) -> Nil,
) -> Nil {
  ffi_set_hook(handle, hook)
}

@target(javascript)
/// Start the JavaScript server (creates closure with mutable state)
fn platform_start(
  initial_state: ServerState(model, message),
) -> Result(ServerHandle(model, message), Nil) {
  Ok(ffi_create_server(
    initial_state,
    handle_client_connected_logic,
    handle_client_disconnected_logic,
    handle_incoming_logic,
  ))
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
/// Call the connect method on the server handle
@external(javascript, "./server.ffi.mjs", "connect")
fn ffi_connect(
  _handle: ServerHandle(model, message),
  _client_id: String,
  _send: fn(BitArray) -> Nil,
) -> Nil {
  Nil
}

@target(javascript)
/// Create server with closure-scoped mutable state
@external(javascript, "./server.ffi.mjs", "createServer")
fn ffi_create_server(
  _initial_state: ServerState(model, message),
  _handle_connect: fn(ServerState(model, message), String, fn(BitArray) -> Nil) ->
    ServerState(model, message),
  _handle_disconnect: fn(ServerState(model, message), String) ->
    ServerState(model, message),
  _handle_incoming: fn(ServerState(model, message), String, BitArray) ->
    ServerState(model, message),
) -> ServerHandle(model, message) {
  panic as "JavaScript only"
}

@target(javascript)
/// Call the disconnect method on the server handle
@external(javascript, "./server.ffi.mjs", "disconnect")
fn ffi_disconnect(
  _handle: ServerHandle(model, message),
  _client_id: String,
) -> Nil {
  Nil
}

@target(javascript)
/// Call the incoming method on the server handle
@external(javascript, "./server.ffi.mjs", "incoming")
fn ffi_incoming(
  _handle: ServerHandle(model, message),
  _client_id: String,
  _bytes: BitArray,
) -> Nil {
  Nil
}

@target(javascript)
/// Call the setHook method on the server handle
@external(javascript, "./server.ffi.mjs", "setHook")
fn ffi_set_hook(
  _handle: ServerHandle(model, message),
  _hook: fn(message, model, String) -> Nil,
) -> Nil {
  Nil
}
