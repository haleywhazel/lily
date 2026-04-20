# Lily

Lily is a reactive web framework for Gleam. The same store runs on both the
server (Erlang/BEAM) and the client (JavaScript), synchronised over WebSocket
or HTTP/SSE. Both transports queue messages to localStorage when offline and
flush on reconnect.

## Example

A minimal synced counter split across three packages — the standard structure
for a full-stack Lily app.

### Project structure

```
counter/
  shared/    # Model, Msg, update, serialiser — no target
  frontend/  # JavaScript client app
  backend/   # Erlang server
```

### `shared/src/counter_shared.gleam`

Defines the model, messages, update function, and serialiser. Both frontend
and backend depend on this package.

```gleam
import lily/transport

pub type Model {
  Model(count: Int, connected: Bool)
}

pub type Message {
  Increment
  Decrement
}

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
  }
}

pub fn serialiser() -> transport.Serialiser(Model, Message) {
  transport.automatic()
}
```

### `frontend/src/counter_frontend.gleam`

Mounts components, binds events, and connects to the server.

```gleam
import counter_shared
import gleam/int
import lily
import lily/client
import lily/component
import lily/event
import lily/transport
import lustre/attribute
import lustre/element
import lustre/element/html

pub fn main() {
  let runtime =
    lily.new(
      counter_shared.Model(count: 0, connected: True),
      with: counter_shared.update,
    )
    |> client.start

  runtime
  |> component.mount(
    selector: "#app",
    to_html: element.to_string,
    view: app,
  )
  |> event.on_click(selector: "#app", decoder: parse_click)
  |> client.connect(
    with: transport.websocket(url: "ws://localhost:8080/ws")
      |> transport.websocket_connect,
    serialiser: counter_shared.serialiser(),
  )
  |> client.connection_status(
    get: fn(m) { m.connected },
    set: fn(m, status) { counter_shared.Model(..m, connected: status) },
  )
}

fn app(_model: counter_shared.Model) {
  component.fragment([
    component.simple(
      slice: fn(m: counter_shared.Model) { m.connected },
      render: fn(connected) {
        case connected {
          True -> html.p([], [html.text("● Online")])
          False -> html.p([], [html.text("● Offline")])
        }
      },
    ),
    component.simple(
      slice: fn(m: counter_shared.Model) { m.count },
      render: fn(count) {
        html.div([], [
          html.button([attribute.data("msg", "decrement")], [html.text("-")]),
          html.span([], [html.text(int.to_string(count))]),
          html.button([attribute.data("msg", "increment")], [html.text("+")]),
        ])
      },
    ),
  ])
}

fn parse_click(message_name: String) -> Result(counter_shared.Message, Nil) {
  case message_name {
    "increment" -> Ok(counter_shared.Increment)
    "decrement" -> Ok(counter_shared.Decrement)
    _ -> Error(Nil)
  }
}
```

### `backend/src/counter_backend.gleam`

Starts the Lily server actor and wires it into a mist WebSocket handler.

```gleam
import counter_shared
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import lily
import lily/server
import mist.{type Connection, type ResponseData}

pub fn main() {
  let app_store =
    lily.new(
      counter_shared.Model(count: 0, connected: True),
      with: counter_shared.update,
    )
  let assert Ok(srv) =
    server.start(store: app_store, serialiser: counter_shared.serialiser())

  let assert Ok(_) =
    mist.new(fn(request) { handle_request(request, srv) })
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn handle_request(
  request: request.Request(Connection),
  srv: server.Server(counter_shared.Model, counter_shared.Message),
) -> response.Response(ResponseData) {
  case request.path_segments(request) {
    ["ws"] -> handle_websocket(request, srv)
    _ -> mist.response(404)
  }
}

type OutgoingMessage {
  OutgoingMessage(text: String)
}

type WsState {
  WsState(
    client_id: String,
    server: server.Server(counter_shared.Model, counter_shared.Message),
  )
}

fn handle_websocket(
  request: request.Request(Connection),
  srv: server.Server(counter_shared.Model, counter_shared.Message),
) -> response.Response(ResponseData) {
  mist.websocket(
    request:,
    handler: handle_ws_message,
    on_init: fn(_connection) { ws_init(srv) },
    on_close: fn(state) { server.disconnect(state.server, client_id: state.client_id) },
  )
}

fn ws_init(
  srv: server.Server(counter_shared.Model, counter_shared.Message),
) -> #(WsState, option.Option(process.Selector(OutgoingMessage))) {
  let client_id = generate_client_id()
  let outgoing_subject = process.new_subject()

  server.connect(srv, client_id:, send: process.send(outgoing_subject, _))

  let selector =
    process.new_selector()
    |> process.select_map(outgoing_subject, OutgoingMessage)

  #(WsState(client_id:, server: srv), Some(selector))
}

fn handle_ws_message(
  state: WsState,
  message: mist.WebsocketMessage(OutgoingMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(WsState, OutgoingMessage) {
  case message {
    mist.Text(text) -> {
      server.incoming(state.server, client_id: state.client_id, text:)
      mist.continue(state)
    }
    mist.Custom(OutgoingMessage(text:)) -> {
      let _ = mist.send_text_frame(connection, text)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

@external(erlang, "crypto", "strong_rand_bytes")
fn crypto_strong_rand_bytes(count: Int) -> BitArray

@external(erlang, "binary", "encode_hex")
fn base16_encode(bytes: BitArray) -> String

fn generate_client_id() -> String {
  base16_encode(crypto_strong_rand_bytes(16))
}
```
