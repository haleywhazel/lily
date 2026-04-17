//// WebSocket transport for real-time client-server communication. Provides
//// automatic reconnection with exponential backoff and localStorage-backed
//// offline message queueing.
////
//// The transport automatically reconnects using exponential backoff with
//// configurable timing, persists messages in localStorage while disconnected,
//// and flushes queued messages automatically when the connection restores
////
//// ```gleam
//// import lily/client
//// import lily/transport
//// import lily/transport/websocket
////
//// pub fn main() {
////   let runtime = client.start(app_store)
////
////   runtime
////   |> client.connect(
////     with: websocket.config(url: "ws://localhost:8080/ws")
////       |> websocket.reconnect_base_milliseconds(1000)
////       |> websocket.reconnect_max_milliseconds(30_000)
////       |> websocket.connect,
////     serialiser: transport.automatic(),
////   )
//// }
//// ```
////
//// WebSocket transport is JavaScript-only (`@target(javascript)`).
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import lily/transport.{type Connector, type Handler}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

@target(javascript)
/// Configuration for WebSocket connection. Use the builder functions to
/// customise reconnection behaviour.
pub opaque type Config {
  Config(
    url: String,
    reconnect_base_milliseconds: Int,
    reconnect_max_milliseconds: Int,
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
/// Create a new WebSocket configuration with the given URL. Default reconnect
/// settings are 1000ms base delay and 30000ms maximum delay (exponential
/// backoff).
pub fn config(url url: String) -> Config {
  Config(
    url: url,
    reconnect_base_milliseconds: 1000,
    reconnect_max_milliseconds: 30_000,
  )
}

@target(javascript)
/// Returns a connector function that establishes a WebSocket connection. This
/// connector can be passed to `client.connect`.
///
/// ## Example
///
/// ```gleam
/// client.connect(
///   with: websocket.config(url: "ws://localhost:8080/ws")
///     |> websocket.reconnect_base_milliseconds(2000)
///     |> websocket.connect,
///   serialiser: my_serialiser,
/// )
/// ```
pub fn connect(config: Config) -> Connector {
  fn(handler: Handler) {
    let transport_handle =
      ws_connect(
        config.url,
        config.reconnect_base_milliseconds,
        config.reconnect_max_milliseconds,
        handler,
      )
    transport.new(
      send: fn(text) { ws_send(transport_handle, text) },
      close: fn() { ws_close(transport_handle) },
    )
  }
}

@target(javascript)
/// Set the base delay in milliseconds for reconnection attempts. The actual
/// delay doubles on each failed attempt until reaching the maximum.
pub fn reconnect_base_milliseconds(config: Config, milliseconds: Int) -> Config {
  Config(..config, reconnect_base_milliseconds: milliseconds)
}

@target(javascript)
/// Set the maximum delay in milliseconds between reconnection attempts.
pub fn reconnect_max_milliseconds(config: Config, milliseconds: Int) -> Config {
  Config(..config, reconnect_max_milliseconds: milliseconds)
}

@target(javascript)
/// Derive a WebSocket URL from the browser's current location.
/// Automatically uses `wss:` for HTTPS pages and `ws:` for HTTP.
/// The `path` argument specifies the WebSocket endpoint path.
///
/// ## Example
///
/// ```gleam
/// // On https://example.com:3000/app
/// websocket.url_from_current_location("/ws")
/// // Returns "wss://example.com:3000/ws"
/// ```
pub fn url_from_current_location(path path: String) -> String {
  ffi_url_from_current_location(path)
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./websocket.ffi.mjs", "urlFromCurrentLocation")
fn ffi_url_from_current_location(_path: String) -> String {
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./websocket.ffi.mjs", "close")
fn ws_close(_handle: WsHandle) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./websocket.ffi.mjs", "connect")
fn ws_connect(
  _url: String,
  _reconnect_base_ms: Int,
  _reconnect_max_ms: Int,
  _handler: Handler,
) -> WsHandle {
  // This will never run
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./websocket.ffi.mjs", "send")
fn ws_send(_handle: WsHandle, _text: String) -> Nil {
  Nil
}

@target(javascript)
/// Opaque handle to the WebSocket connection state returned by the FFI.
type WsHandle
