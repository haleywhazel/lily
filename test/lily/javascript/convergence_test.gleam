// two real clients against an in-process server, frames held on a link until
// a test delivers them, letting concurrent edits cross on the wire

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{type Option, None, Some}

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/client
@target(javascript)
import lily/server
@target(javascript)
import lily/store
@target(javascript)
import lily/test_support.{
  type Message, type Model, type Ref, Claim, Increment, Model, Reset,
}
@target(javascript)
import lily/transport
@target(javascript)
import lily/wire_support

// =============================================================================
// HELPERS
// =============================================================================

@target(javascript)
/// One client and its end of the link.
type Peer {
  Peer(
    runtime: client.Runtime(Model, Message, store.Synced),
    handler: Ref(transport.ConnectorHandler),
    online: Ref(Bool),
    // sent by the client, not yet at the server
    outbox: Ref(List(BitArray)),
    // sent by the server, not yet at the client
    inbox: Ref(List(BitArray)),
    connection: Ref(Option(server.Connection(Model, Message))),
  )
}

@target(javascript)
fn chat_store(
  route: fn(Message) -> store.Route,
) -> store.Store(Model, Message, store.Synced) {
  store.new(init: test_support.initial_model(), update: test_support.update)
  |> store.sync_with(route:, serialiser: test_support.custom_serialiser())
  |> store.topic(
    id: "chat",
    get: fn(model) { model },
    set: fn(_, model) { model },
    access: store.Open,
  )
  |> store.subscriptions(fn(_) { ["chat"] })
}

@target(javascript)
fn deliver_down(peer: Peer) -> Nil {
  let frames = list.reverse(test_support.get(peer.inbox))
  test_support.set(peer.inbox, [])
  let handler = test_support.get(peer.handler)
  list.each(frames, handler.received)
}

@target(javascript)
fn deliver_up(peer: Peer) -> Nil {
  let frames = list.reverse(test_support.get(peer.outbox))
  test_support.set(peer.outbox, [])
  case test_support.get(peer.connection) {
    Some(connection) ->
      list.each(frames, fn(bytes) { server.incoming(connection, bytes:) })
    None -> Nil
  }
}

@target(javascript)
fn dispatch(peer: Peer, message: Message) -> Nil {
  client.dispatch(peer.runtime)(message)
}

@target(javascript)
fn go_offline(peer: Peer) -> Nil {
  case test_support.get(peer.connection) {
    Some(connection) -> server.disconnect(connection)
    None -> Nil
  }
  test_support.set(peer.connection, None)
  test_support.set(peer.online, False)
  test_support.set(peer.outbox, [])
  test_support.set(peer.inbox, [])
  let handler = test_support.get(peer.handler)
  handler.closed()
}

@target(javascript)
/// A fresh connection with a fresh id, like a reconnecting socket.
fn go_online(
  app: server.Server(Model, Message),
  peer: Peer,
  client_id: String,
) -> Nil {
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: None,
      send: fn(bytes) {
        test_support.set(peer.inbox, [bytes, ..test_support.get(peer.inbox)])
      },
      client_id:,
      seed: [],
      watch: server.Unwatched,
    )
  test_support.set(peer.connection, Some(connection))
  test_support.set(peer.online, True)
  let handler = test_support.get(peer.handler)
  handler.opened()
}

@target(javascript)
fn model(peer: Peer) -> Model {
  client.model(peer.runtime)
}

@target(javascript)
/// Behind an offline queue, like `transport.websocket`.
fn new_peer(
  store: store.Store(Model, Message, store.Synced),
  key: String,
) -> Peer {
  test_support.write_session_storage(key, "")
  let peer =
    Peer(
      runtime: client.start(store),
      handler: test_support.new(
        transport.ConnectorHandler(
          received: fn(_) { Nil },
          opened: fn() { Nil },
          closed: fn() { Nil },
        ),
      ),
      online: test_support.new(False),
      outbox: test_support.new([]),
      inbox: test_support.new([]),
      connection: test_support.new(None),
    )
  let connector =
    transport.connector(fn(handler) {
      test_support.set(peer.handler, handler)
      transport.Channel(
        send: fn(bytes) {
          case test_support.get(peer.online) {
            True -> {
              test_support.set(peer.outbox, [
                bytes,
                ..test_support.get(peer.outbox)
              ])
              Ok(Nil)
            }
            False -> Error(Nil)
          }
        },
        close: fn() { Nil },
      )
    })
    |> transport.with_offline_queue(storage_key: key)
  let _ = client.connect(peer.runtime, with: connector)
  peer
}

@target(javascript)
fn server_chat(app: server.Server(Model, Message), probe_id: String) -> Model {
  let #(probe, frames) = wire_support.open(app, probe_id)
  wire_support.subscribe(probe, "chat")
  let assert [transport.Snapshot(state:, ..)] = frames()
  server.disconnect(probe)
  state
}

@target(javascript)
/// Delivers both ways until nothing is in flight.
fn settle(peers: List(Peer)) -> Nil {
  settle_rounds(peers, 20)
}

@target(javascript)
fn settle_rounds(peers: List(Peer), rounds: Int) -> Nil {
  let idle =
    list.all(peers, fn(peer) {
      test_support.get(peer.outbox) == [] && test_support.get(peer.inbox) == []
    })
  case idle || rounds == 0 {
    True -> Nil
    False -> {
      list.each(peers, deliver_up)
      list.each(peers, deliver_down)
      settle_rounds(peers, rounds - 1)
    }
  }
}

@target(javascript)
fn setup() -> #(server.Server(Model, Message), Peer, Peer) {
  test_support.reset_dom()
  test_support.reset_mocks()
  let app =
    test_support.start_server(server.new(
      chat_store(test_support.topic_route),
      origins: server.AnyOrigin,
    ))
  let a = new_peer(chat_store(test_support.topic_route), "convergence_a")
  let b = new_peer(chat_store(test_support.topic_route), "convergence_b")
  go_online(app, a, "a1")
  go_online(app, b, "b1")
  settle([a, b])
  #(app, a, b)
}

// =============================================================================
// CONCURRENT EDITS
// =============================================================================

@target(javascript)
pub fn convergence_conflicting_claims_settle_on_the_server_state_test() {
  // the last item in stock, each client thinks it got it until told otherwise
  let #(app, a, b) = setup()
  dispatch(a, Claim("a"))
  dispatch(b, Claim("b"))
  model(b).name |> should.equal("b")

  // both cross on the wire, the server takes a's first
  deliver_up(a)
  deliver_up(b)
  settle([a, b])

  let truth = server_chat(app, "probe")
  truth.name |> should.equal("a")
  model(a) |> should.equal(truth)
  model(b) |> should.equal(truth)
}

@target(javascript)
pub fn convergence_concurrent_increments_reach_the_right_total_test() {
  let #(app, a, b) = setup()
  dispatch(a, Increment)
  dispatch(a, Increment)
  dispatch(b, Increment)
  dispatch(b, Increment)
  dispatch(b, Increment)

  deliver_up(a)
  deliver_up(b)
  list.each([a, b], deliver_down)
  // one more while b's snapshot is on its way, it stays on top of it
  dispatch(b, Increment)
  settle([a, b])

  model(a).count |> should.equal(6)
  model(b).count |> should.equal(6)
  server_chat(app, "probe").count |> should.equal(6)
}

@target(javascript)
pub fn convergence_offline_topic_edits_reach_the_other_subscribers_test() {
  let #(app, a, b) = setup()
  go_offline(a)
  dispatch(a, Increment)
  dispatch(a, Increment)
  model(a).count |> should.equal(2)

  go_online(app, a, "a2")
  settle([a, b])

  model(b).count |> should.equal(2)
  model(a).count |> should.equal(2)
  server_chat(app, "probe").count |> should.equal(2)
}

@target(javascript)
pub fn convergence_dropped_message_rolls_back_to_the_server_state_test() {
  // this client's route disagrees with the server's, `Reset` is local there
  test_support.reset_dom()
  test_support.reset_mocks()
  let app =
    test_support.start_server(server.new(
      chat_store(test_support.topic_route),
      origins: server.AnyOrigin,
    ))
  let misrouting =
    chat_store(fn(message) {
      case message {
        Reset -> store.Topic("chat")
        _ -> test_support.topic_route(message)
      }
    })
  let a = new_peer(misrouting, "convergence_misrouted")
  go_online(app, a, "a1")
  server.dispatch_topic(app, topic_id: "chat", message: Increment)
  settle([a])
  model(a).count |> should.equal(1)

  dispatch(a, Reset)
  model(a).count |> should.equal(0)
  settle([a])

  model(a) |> should.equal(Model(..test_support.initial_model(), count: 1))
}
