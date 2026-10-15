import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string

import lily/server
import logging

// Import shared types here
import shared

import mist.{type Connection, type ResponseData}
import wisp
import wisp/wisp_mist

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Supervised, so a crash restarts the server rather than taking the node
  // down. The rooms are declared in the shared store, so they come back with
  // it and there is nothing to register again.
  let assert Ok(#(_supervisor, server)) =
    server.new(
      shared.store(),
      // TODO: add your production origin here.
      origins: server.AllowedOrigins(["http://localhost:8080"]),
    )
    |> server.observe(log_events)
    |> server.start_supervised

  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    mist.new(fn(request) { handle_request(request, server, secret_key_base) })
    |> mist.port(8080)
    |> mist.start

  logging.log(
    logging.Info,
    "Lily example backend listening on http://localhost:8080",
  )

  process.sleep_forever()
}

fn log_events(
  event: server.ServerEvent(shared.Model, shared.Message),
  _server: server.Server(shared.Model, shared.Message),
) -> Nil {
  case event {
    server.SessionMessageApplied(message:, ..) ->
      logging.log(logging.Info, string.inspect(message))
    server.TopicMessageReceived(message:, ..) ->
      logging.log(logging.Info, string.inspect(message))
    _ -> Nil
  }
}

// =============================================================================
// HTTP ROUTING
// =============================================================================

fn handle_request(
  request: request.Request(Connection),
  server: server.Server(shared.Model, shared.Message),
  secret_key_base: String,
) -> response.Response(ResponseData) {
  case request.path_segments(request) {
    ["ws"] -> handle_websocket(request, server)
    _ -> handle_http(request, secret_key_base)
  }
}

// =============================================================================
// WEBSOCKET HANDLER
// =============================================================================

type Socket =
  server.Connection(shared.Model, shared.Message)

fn handle_websocket(
  request: request.Request(Connection),
  server: server.Server(shared.Model, shared.Message),
) -> response.Response(ResponseData) {
  // Refuse the upgrade outright when the origin is not allowed. A
  // WebSocket handshake is not subject to CORS and still carries
  // cookies, so this is what stops a cross-site socket.
  let origin = request.get_header(request, "origin") |> option.from_result
  case server.open(server, origin:) {
    Error(_) -> forbidden()
    Ok(opened) ->
      mist.websocket(
        request:,
        handler: handle_ws_message,
        // Attaching from the socket process ties the registration to it, so
        // one that dies without a close callback still leaves nothing behind.
        on_init: fn(_connection) {
          let #(connection, frames) = server.attach(opened)
          #(connection, Some(frames))
        },
        on_close: server.disconnect,
      )
  }
}

fn forbidden() -> response.Response(ResponseData) {
  response.new(403)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn handle_ws_message(
  connection: Socket,
  message: mist.WebsocketMessage(Result(BitArray, Nil)),
  socket: mist.WebsocketConnection,
) -> mist.Next(Socket, Result(BitArray, Nil)) {
  case message {
    mist.Binary(bits) -> {
      server.incoming(connection, bytes: bits)
      mist.continue(connection)
    }

    mist.Custom(Ok(bytes)) -> {
      let _ = mist.send_binary_frame(socket, bytes)
      mist.continue(connection)
    }
    // A supervised restart replaces the server, so close the socket and let
    // the client reconnect rather than leave it reading Online forever.
    mist.Custom(Error(Nil)) -> mist.stop()

    mist.Text(_) -> mist.continue(connection)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

// =============================================================================
// HTTP HANDLER
// =============================================================================

fn handle_http(
  request: request.Request(Connection),
  secret_key_base: String,
) -> response.Response(ResponseData) {
  let wisp_handler = fn(request: wisp.Request) -> wisp.Response {
    use <- wisp.log_request(request)
    use <- wisp.serve_static(
      request,
      under: "/static",
      from: "../frontend/build/dev/javascript",
    )
    case wisp.path_segments(request) {
      ["static", ..] -> wisp.not_found()
      _ ->
        wisp.response(200)
        |> wisp.set_header("content-type", "text/html; charset=utf-8")
        |> wisp.set_body(wisp.File(
          path: "../frontend/index.html",
          offset: 0,
          limit: None,
        ))
    }
  }

  let handler = wisp_mist.handler(wisp_handler, secret_key_base)
  handler(request)
}
