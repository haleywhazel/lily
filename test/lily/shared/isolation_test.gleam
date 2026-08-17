// Tests that one client's crashing callback cannot take down the actor every
// other client shares. Asserts through synchronous calls only, so it runs on
// both targets. Frames are checked in `erlang/isolation_erl_test`.

import gleam/option.{None}

import gleeunit/should

import lily/server
import lily/store
import lily/topic
import lily/transport

import lily/test_support.{type Message, type Model, Increment, SetName}

// =============================================================================
// HELPERS
// =============================================================================

/// Connect a client whose send closure raises on every frame, standing in for
/// a transport whose socket has gone.
fn connect_broken_client(
  srv: server.Server(Model, Message),
  client_id: String,
) -> Nil {
  let assert Ok(Nil) =
    server.connect(
      srv,
      client_id: client_id,
      origin: None,
      send: fn(_bytes) { panic as "send closure is gone" },
      session: [],
    )
  Nil
}

fn incoming(
  srv: server.Server(Model, Message),
  client_id: String,
  frame: transport.Protocol(Model, Message),
) -> Nil {
  server.incoming(
    srv,
    client_id:,
    bytes: transport.encode(frame, serialiser: test_support.custom_serialiser()),
  )
}

/// Force every queued message through before asserting. `client_count` is a
/// synchronous call and the actor's mailbox is ordered, so anything cast
/// before it has already been handled by the time it answers. A sleep would
/// work on Erlang only, and this file has to hold on both targets.
fn settle(srv: server.Server(Model, Message)) -> Nil {
  let _ = server.client_count(srv)
  Nil
}

/// The same, for a topic actor. Server-to-topic traffic crosses two mailboxes,
/// so settle the server first or the topic may not have been told yet.
fn settle_topic(topic: topic.Topic(Model, Message, kind)) -> Nil {
  let _ = topic.subscriber_count(topic)
  Nil
}

// =============================================================================
// SERVER HOOKS
// =============================================================================

pub fn crashing_on_connect_keeps_the_server_alive_test() {
  let srv = test_support.new_server()
  server.on_connect(srv, fn(_client_id) { panic as "on_connect blew up" })

  let _drain = test_support.connect_client(srv, "a")

  // Registered despite the hook, and still able to take another connection.
  server.client_count(srv)
  |> should.equal(1)
  let _second = test_support.connect_client(srv, "b")
  server.client_count(srv)
  |> should.equal(2)
}

pub fn crashing_on_disconnect_keeps_the_server_alive_test() {
  let srv = test_support.new_server()
  let _drain = test_support.connect_client(srv, "a")
  server.on_disconnect(srv, fn(_client_id) { panic as "on_disconnect blew up" })

  server.disconnect(srv, client_id: "a")

  // The cleanup either side of the hook still committed.
  server.client_count(srv)
  |> should.equal(0)
}

pub fn crashing_decoder_drops_the_frame_test() {
  let srv = test_support.new_server()
  let _drain = test_support.connect_client(srv, "a")

  server.incoming(srv, client_id: "a", bytes: <<"not a frame at all":utf8>>)
  settle(srv)

  // Dropped rather than fatal.
  server.client_count(srv)
  |> should.equal(1)
}

// =============================================================================
// EVICTION
// =============================================================================

pub fn crashing_send_drops_only_that_client_test() {
  let srv = test_support.new_server()
  connect_broken_client(srv, "broken")
  let _healthy = test_support.connect_client(srv, "healthy")

  server.dispatch_to_all(srv, message: Increment)
  settle(srv)

  // Only the broken one goes.
  server.client_count(srv)
  |> should.equal(1)
}

pub fn crashing_on_subscribe_still_admits_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat =
    chat
    |> topic.with_store
    |> topic.on_subscribe(fn(_client_id) { panic as "on_subscribe blew up" })
  let _drain = test_support.connect_client(srv, "a")

  incoming(srv, "a", transport.Subscribe(topic_id: "chat"))
  settle(srv)

  // Membership is committed before the hook runs, so the join stands.
  topic.subscriber_count(chat)
  |> should.equal(1)
}

pub fn crashing_on_unsubscribe_still_removes_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat =
    chat
    |> topic.with_store
    |> topic.on_unsubscribe(fn(_client_id) { panic as "on_unsubscribe blew up" })
  let _drain = test_support.connect_client(srv, "a")
  incoming(srv, "a", transport.Subscribe(topic_id: "chat"))

  incoming(srv, "a", transport.Unsubscribe(topic_id: "chat"))
  settle(srv)

  topic.subscriber_count(chat)
  |> should.equal(0)
}

// =============================================================================
// TOPIC FAN-OUT
// =============================================================================

pub fn crashing_subscriber_send_is_pruned_test() {
  let srv = test_support.new_server()
  let assert Ok(chat) = topic.new(srv, id: "chat")
  let chat = topic.with_store(chat)
  connect_broken_client(srv, "broken")
  let _healthy = test_support.connect_client(srv, "healthy")
  incoming(srv, "broken", transport.Subscribe(topic_id: "chat"))
  incoming(srv, "healthy", transport.Subscribe(topic_id: "chat"))
  settle(srv)
  settle_topic(chat)

  topic.broadcast(chat, SetName("hello"))
  settle_topic(chat)

  // The room loses the dead socket and keeps everybody else.
  topic.subscriber_count(chat)
  |> should.equal(1)
}

pub fn crashing_session_update_drops_the_message_test() {
  let assert Ok(srv) =
    server.start(
      initial: test_support.initial_model(),
      serialiser: test_support.custom_serialiser(),
      wiring: store.wiring()
        |> store.session(
          extract: fn(message) { Ok(message) },
          update: fn(_model, _message) { panic as "update blew up" },
          field_get: fn(model) { model },
          field_set: fn(_, model) { model },
        ),
      origins: server.AnyOrigin,
    )
  let _drain = test_support.connect_client(srv, "a")

  incoming(srv, "a", transport.SessionMessage(payload: Increment))
  settle(srv)

  // Already covered by `apply_session`, kept here so the whole policy reads in
  // one place.
  server.client_count(srv)
  |> should.equal(1)
}
