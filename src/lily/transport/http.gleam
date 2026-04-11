//// HTTP/SSE transport for client-server communication. Uses Server-Sent
//// Events (SSE) for server→client and POST for client→server. Useful when
//// WebSocket connections are blocked by corporate firewalls.
////
//// The transport uses Server-Sent Events (SSE) via the EventSource API for
//// server→client messages and POST requests with JSON payloads for
//// client→server messages. Connection status is tracked via SSE `onopen` and
//// `onerror` events, and messages persist in localStorage while disconnected
////
//// ```gleam
//// import lily/client
//// import lily/transport
//// import lily/transport/http
////
//// pub fn main() {
////   let runtime = client.start(app_store)
////
////   runtime
////   |> client.connect(
////     with: http.config(
////       post_url: "http://localhost:8080/api/messages",
////       events_url: "http://localhost:8080/events",
////     )
////     |> http.connect,
////     serialiser: transport.automatic(),
////   )
//// }
//// ```
////
//// This is a client-side transport only. You still need a server library
//// like [`mist`](https://hexdocs.pm/mist/index.html) to handle the SSE
//// endpoint and POST requests.
////
//// HTTP transport is JavaScript-only (`@target(javascript)`).
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import lily/transport.{type Connector, type Handler}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Configuration for HTTP transport. Requires both a POST URL (for client to
/// server messages) and an SSE events URL (for server to client messages).
@target(javascript)
pub opaque type Config {
  Config(post_url: String, events_url: String)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create a new HTTP transport configuration. The `post_url` is used for
/// sending messages to the server (client to server), and the `events_url` is
/// used for receiving Server-Sent Events (server to client).
///
/// ## Example
///
/// ```gleam
/// http.config(
///   post_url: "/api/messages",
///   events_url: "/api/events",
/// )
/// ```
@target(javascript)
pub fn config(post_url post_url: String, events_url events_url: String) -> Config {
  Config(post_url: post_url, events_url: events_url)
}

/// Returns a connector function that establishes an HTTP/SSE connection. This
/// connector can be passed to `client.connect`.
///
/// ## Example
///
/// ```gleam
/// client.connect(
///   with: http.config(
///     post_url: "/api/messages",
///     events_url: "/api/events",
///   )
///     |> http.connect,
///   serialiser: my_serialiser,
/// )
/// ```
@target(javascript)
pub fn connect(config: Config) -> Connector {
  fn(handler: Handler) {
    let transport_handle = http_connect(config.post_url, config.events_url, handler)
    transport.new(
      send: fn(text) { http_send(transport_handle, text) },
      close: fn() { http_close(transport_handle) },
    )
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

// Check the .mjs files for documentation on these functions – the name should
// be fairly self-evident.

@target(javascript)
@external(javascript, "./http.ffi.mjs", "close")
fn http_close(_handle: HttpHandle) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./http.ffi.mjs", "connect")
fn http_connect(
  _post_url: String,
  _events_url: String,
  _handler: Handler,
) -> HttpHandle {
  // This will never run
  panic as "JavaScript only"
}

@target(javascript)
@external(javascript, "./http.ffi.mjs", "send")
fn http_send(_handle: HttpHandle, _text: String) -> Nil {
  Nil
}

/// Opaque handle to the HTTP/SSE connection state returned by the FFI.
@target(javascript)
type HttpHandle
