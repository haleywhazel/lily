import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option.{type Option, None, Some}

import lily/logging
import lily/server
import lily/topic

// Import shared types here
import shared

import mist.{type Connection, type ResponseData}
import wisp
import wisp/wisp_mist

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(server) =
    server.new(
      initial: shared.initial_model(),
      serialiser: shared.serialiser(),
      wiring: shared.wiring(),
    )
    |> server.start

  server.on_message(server, fn(message, _model, _client_id) {
    logging.auto_log(logging.Info, message)
  })
  server.on_topic_message(server, fn(message, _topic_id, _client_id) {
    logging.auto_log(logging.Info, message)
  })

  let assert Ok(_) =
    topic.kind(
      server,
      prefix: "room:",
      parse_id: fn(name) {
        case name {
          "" -> Error(Nil)
          _ -> Ok(name)
        }
      },
      configure: fn(_room_name, room) { topic.with_store(room) },
    )

  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    mist.new(fn(request) { handle_request(request, server, secret_key_base) })
    |> mist.port(8080)
    |> mist.start

  logging.info("Lily example backend listening on http://localhost:8080")

  process.sleep_forever()
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

type OutgoingMessage {
  OutgoingMessage(bytes: BitArray)
}

type WsState {
  WsState(
    client_id: String,
    server: server.Server(shared.Model, shared.Message),
  )
}

fn handle_websocket(
  request: request.Request(Connection),
  server: server.Server(shared.Model, shared.Message),
) -> response.Response(ResponseData) {
  mist.websocket(
    request:,
    handler: handle_ws_message,
    on_init: fn(_connection) { ws_init(server) },
    on_close: fn(state) { ws_close(state) },
  )
}

fn ws_init(
  server: server.Server(shared.Model, shared.Message),
) -> #(WsState, Option(process.Selector(OutgoingMessage))) {
  let client_id = server.generate_client_id()
  let outgoing_subject = process.new_subject()
  let send = fn(bytes: BitArray) {
    process.send(outgoing_subject, OutgoingMessage(bytes:))
  }

  server.connect(server, client_id:, send:)

  let selector =
    process.new_selector()
    |> process.select(outgoing_subject)

  #(WsState(client_id:, server: server), Some(selector))
}

fn handle_ws_message(
  state: WsState,
  message: mist.WebsocketMessage(OutgoingMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(WsState, OutgoingMessage) {
  case message {
    mist.Binary(bits) -> {
      server.incoming(state.server, client_id: state.client_id, bytes: bits)
      mist.continue(state)
    }

    mist.Custom(OutgoingMessage(bytes:)) -> {
      let _ = mist.send_binary_frame(connection, bytes)
      mist.continue(state)
    }

    mist.Text(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn ws_close(state: WsState) -> Nil {
  server.disconnect(state.server, client_id: state.client_id)
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
