// IMPORTS

@target(erlang)
import gleam/dict.{type Dict}
@target(erlang)
import gleam/erlang/process.{type Subject}
@target(erlang)
import gleam/otp/actor
@target(erlang)
import gleam/result
@target(erlang)
import lily/protocol.{type Serialiser}
@target(erlang)
import lily/store.{type Store}

// PUBLIC TYPES

@target(erlang)
pub opaque type ServerEvent(msg) {
  ClientConnected(client_id: String, subject: Subject(String))
  ClientDisconnected(client_id: String)
  Incoming(client_id: String, text: String)
}

// PUBLIC FUNCTIONS

@target(erlang)
pub fn connect(
  server: Subject(ServerEvent(msg)),
  client_id client_id: String,
  subject subject: Subject(String),
) -> Nil {
  actor.send(server, ClientConnected(client_id:, subject:))
}

@target(erlang)
pub fn disconnect(
  server: Subject(ServerEvent(msg)),
  client_id client_id: String,
) -> Nil {
  actor.send(server, ClientDisconnected(client_id:))
}

@target(erlang)
pub fn incoming(
  server: Subject(ServerEvent(msg)),
  client_id client_id: String,
  text text: String,
) -> Nil {
  actor.send(server, Incoming(client_id:, text:))
}

@target(erlang)
pub fn start(
  store store: Store(model, msg),
  serialiser serialiser: Serialiser(model, msg),
) -> Result(Subject(ServerEvent(msg)), actor.StartError) {
  let initial_state =
    ServerState(store:, clients: dict.new(), sequence: 0, serialiser:)

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

// PRIVATE TYPES

@target(erlang)
type ServerState(model, msg) {
  ServerState(
    store: Store(model, msg),
    clients: Dict(String, Subject(String)),
    sequence: Int,
    serialiser: Serialiser(model, msg),
  )
}

// PRIVATE FUNCTIONS

@target(erlang)
fn broadcast_except(
  clients: Dict(String, Subject(String)),
  message: String,
  except excluded_id: String,
) -> Nil {
  dict.each(clients, fn(id, subject) {
    case id == excluded_id {
      True -> Nil
      False -> process.send(subject, message)
    }
  })
}

@target(erlang)
fn handle_client_connected(
  state: ServerState(model, msg),
  client_id: String,
  subject: Subject(String),
) -> actor.Next(ServerState(model, msg), ServerEvent(msg)) {
  let clients = dict.insert(state.clients, client_id, subject)
  actor.continue(ServerState(..state, clients:))
}

@target(erlang)
fn handle_client_disconnected(
  state: ServerState(model, msg),
  client_id: String,
) -> actor.Next(ServerState(model, msg), ServerEvent(msg)) {
  let clients = dict.delete(state.clients, client_id)
  actor.continue(ServerState(..state, clients:))
}

@target(erlang)
fn handle_client_message(
  state: ServerState(model, msg),
  client_id: String,
  payload: msg,
) -> actor.Next(ServerState(model, msg), ServerEvent(msg)) {
  let updated_store = store.apply(state.store, msg: payload)
  let new_sequence = state.sequence + 1

  let server_message =
    protocol.ServerMessage(sequence: new_sequence, payload:)
  let encoded = protocol.encode(server_message, serialiser: state.serialiser)
  broadcast_except(state.clients, encoded, except: client_id)

  let acknowledge = protocol.Acknowledge(sequence: new_sequence)
  let acknowledge_encoded =
    protocol.encode(acknowledge, serialiser: state.serialiser)
  case dict.get(state.clients, client_id) {
    Ok(subject) -> process.send(subject, acknowledge_encoded)
    Error(Nil) -> Nil
  }

  actor.continue(
    ServerState(..state, store: updated_store, sequence: new_sequence),
  )
}

@target(erlang)
fn handle_incoming(
  state: ServerState(model, msg),
  client_id: String,
  text: String,
) -> actor.Next(ServerState(model, msg), ServerEvent(msg)) {
  case protocol.decode(text, serialiser: state.serialiser) {
    Ok(protocol.ClientMessage(payload:)) ->
      handle_client_message(state, client_id, payload)

    Ok(protocol.Resync(after_sequence:)) ->
      handle_resync(state, client_id, after_sequence)

    _ -> actor.continue(state)
  }
}

@target(erlang)
fn handle_message(
  state: ServerState(model, msg),
  message: ServerEvent(msg),
) -> actor.Next(ServerState(model, msg), ServerEvent(msg)) {
  case message {
    ClientConnected(client_id:, subject:) ->
      handle_client_connected(state, client_id, subject)

    ClientDisconnected(client_id:) -> handle_client_disconnected(state, client_id)

    Incoming(client_id:, text:) -> handle_incoming(state, client_id, text)
  }
}

@target(erlang)
fn handle_resync(
  state: ServerState(model, msg),
  client_id: String,
  _after_sequence: Int,
) -> actor.Next(ServerState(model, msg), ServerEvent(msg)) {
  case dict.get(state.clients, client_id) {
    Error(Nil) -> actor.continue(state)
    Ok(subject) -> {
      let snapshot =
        protocol.Snapshot(
          sequence: state.sequence,
          state: store.get_model(state.store),
        )
      let encoded = protocol.encode(snapshot, serialiser: state.serialiser)
      process.send(subject, encoded)

      actor.continue(state)
    }
  }
}
