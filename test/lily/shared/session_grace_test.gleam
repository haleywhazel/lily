// session grace via wire_support on both targets, a closed connection parks
// its session for the client to resume

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list
import gleam/option

import gleeunit/should

import lily/server.{type Connection, type Server, type ServerEvent}
import lily/test_support.{type Message, type Model, Increment, SetName}
import lily/transport
import lily/wire_support.{type Frame}

// =============================================================================
// HELPERS
// =============================================================================

// the topic store under a grace period, its events read back
fn grace_server(
  milliseconds: Int,
) -> #(Server(Model, Message), fn() -> List(ServerEvent(Model, Message))) {
  grace_server_with(milliseconds, fn(builder) { builder })
}

fn grace_server_with(
  milliseconds: Int,
  change: fn(server.Builder(Model, Message)) -> server.Builder(Model, Message),
) -> #(Server(Model, Message), fn() -> List(ServerEvent(Model, Message))) {
  let #(builder, events) =
    server.new(test_support.topic_store(), origins: server.AnyOrigin)
    |> server.session_grace(milliseconds:)
    |> change
    |> wire_support.observed
  let assert Ok(app) = server.start(builder)
  #(app, fn() { events(app) })
}

// a client that has connected but sent nothing, its frames read with their
// tokens and epochs
fn connect(
  app: Server(Model, Message),
  client_id: String,
  seed: List(Message),
) -> #(Connection(Model, Message), fn() -> List(Frame)) {
  let #(record, recorded) = wire_support.recorder()
  let assert Ok(connection) =
    server.connect_as(
      app,
      origin: option.None,
      send: record,
      client_id:,
      seed:,
      watch: server.Unwatched,
    )
  #(connection, fn() {
    wire_support.settle(app)
    list.map(recorded(), wire_support.decode_exact)
  })
}

// a client whose first frame is `first`
fn arrive(
  app: Server(Model, Message),
  client_id: String,
  seed: List(Message),
  first: Frame,
) -> #(Connection(Model, Message), fn() -> List(Frame)) {
  let #(connection, frames) = connect(app, client_id, seed)
  wire_support.send(connection, first)
  #(connection, frames)
}

fn resuming(token: String, cursors: List(transport.Cursor)) -> Frame {
  transport.Resync(cursors:, resume: option.Some(token), delivered: 0)
}

// the token from the last `Connected`
fn resume_token(frames: List(Frame)) -> String {
  let assert Ok(token) =
    list.fold(frames, Error(Nil), fn(found, frame) {
      case frame {
        transport.Connected(resume:, ..) -> Ok(resume)
        _ -> found
      }
    })
  token
}

// the session's state as of its last snapshot
fn session_cursor(frames: List(Frame)) -> transport.Cursor {
  let assert Ok(cursor) =
    list.fold(frames, Error(Nil), fn(found, frame) {
      case frame {
        transport.Snapshot(target: transport.Session, epoch:, sequence:, ..) ->
          Ok(transport.Known(target: transport.Session, epoch:, sequence:))
        _ -> found
      }
    })
  cursor
}

fn session_snapshots(frames: List(Frame)) -> List(Model) {
  list.filter_map(frames, fn(frame) {
    case frame {
      transport.Snapshot(target: transport.Session, state:, ..) -> Ok(state)
      _ -> Error(Nil)
    }
  })
}

fn connected_ids(frames: List(Frame)) -> List(String) {
  list.filter_map(frames, fn(frame) {
    case frame {
      transport.Connected(client_id:, ..) -> Ok(client_id)
      _ -> Error(Nil)
    }
  })
}

const session = transport.Unknown(transport.Session)

const chat = transport.Unknown(transport.Topic("chat"))

// =============================================================================
// REGISTRATION
// =============================================================================

pub fn session_grace_client_connected_waits_for_the_first_frame_test() {
  let #(app, events) = grace_server(30_000)
  let #(connection, _frames) = connect(app, "c1", [])
  events() |> should.equal([])

  wire_support.send(connection, wire_support.resync([]))

  events() |> should.equal([server.ClientConnected("c1")])
}

pub fn session_grace_a_dispatch_before_the_first_frame_lands_in_a_fresh_session_test() {
  let #(app, _events) = grace_server(30_000)
  let #(connection, frames) = connect(app, "c1", [])
  server.dispatch_to(app, client_id: "c1", message: Increment)

  wire_support.send(connection, wire_support.resync([session]))

  session_snapshots(frames())
  |> should.equal([test_support.Model(..test_support.initial_model(), count: 1)])
}

// =============================================================================
// RESUME
// =============================================================================

pub fn session_grace_resume_keeps_the_model_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([]))
  wire_support.session_message(first, test_support.IncrementSecondary)
  let token = resume_token(frames())
  server.disconnect(first)

  let #(_second, again) =
    arrive(
      app,
      "c2",
      [],
      resuming(token, [transport.Unknown(transport.Session)]),
    )

  session_snapshots(again())
  |> should.equal([
    test_support.Model(..test_support.initial_model(), secondary_count: 1),
  ])
}

pub fn session_grace_resume_names_the_session_before_an_unchanged_answer_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([session]))
  let seen = frames()
  server.disconnect(first)

  let #(_second, again) =
    arrive(app, "c2", [], resuming(resume_token(seen), [session_cursor(seen)]))

  case again() {
    [
      transport.Version(..),
      transport.Connected(client_id: "c2", ..),
      transport.Connected(client_id: "c1", ..),
      transport.Unchanged(transport.Session),
    ] -> Nil
    _ -> should.fail()
  }
}

pub fn session_grace_resume_fires_no_events_test() {
  let #(app, events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([chat]))
  let token = resume_token(frames())
  let _ = events()

  server.disconnect(first)
  let _ = arrive(app, "c2", [], resuming(token, [chat]))

  events() |> should.equal([])
}

pub fn session_grace_resume_rejoins_a_topic_it_held_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([chat]))
  let token = resume_token(frames())
  server.disconnect(first)
  let #(_second, again) = arrive(app, "c2", [], resuming(token, [chat]))
  let _ = again()

  server.dispatch_topic(app, topic_id: "chat", message: Increment)

  again()
  |> should.equal([
    transport.TopicUpdate(topic_id: "chat", sequence: 1, payload: Increment),
  ])
}

pub fn session_grace_a_dispatch_while_parked_is_a_snapshot_on_resume_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([session]))
  let seen = frames()
  server.disconnect(first)

  server.dispatch_to(app, client_id: "c1", message: Increment)
  let #(_second, again) =
    arrive(app, "c2", [], resuming(resume_token(seen), [session_cursor(seen)]))

  session_snapshots(again())
  |> should.equal([test_support.Model(..test_support.initial_model(), count: 1)])
}

pub fn session_grace_a_half_open_session_is_resumed_test() {
  let #(app, events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([]))
  let token = resume_token(frames())
  let _ = events()

  let #(_second, again) = arrive(app, "c2", [], resuming(token, []))

  connected_ids(again()) |> should.equal(["c2", "c1"])
  server.incoming(first, bytes: wire_support.encode(wire_support.resync([])))
  |> should.equal(server.Closed)
  events() |> should.equal([])
}

pub fn session_grace_a_frame_on_the_resumed_link_reaches_the_session_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([]))
  let token = resume_token(frames())
  server.disconnect(first)
  let #(second, again) = arrive(app, "c2", [], resuming(token, []))
  let _ = again()

  wire_support.session_message(second, test_support.IncrementSecondary)

  case again() {
    [transport.Acknowledge(target: transport.Session, sequence: 1, ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn session_grace_a_seed_mismatch_starts_a_fresh_session_test() {
  let #(app, events) = grace_server(30_000)
  let #(first, frames) =
    arrive(app, "c1", [SetName("alice")], wire_support.resync([]))
  let token = resume_token(frames())
  server.disconnect(first)
  let _ = events()

  let #(_second, again) =
    arrive(app, "c2", [SetName("mallory")], resuming(token, []))

  connected_ids(again()) |> should.equal(["c2"])
  events() |> should.equal([server.ClientConnected("c2")])
}

pub fn session_grace_a_token_resumes_only_once_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([]))
  let token = resume_token(frames())
  server.disconnect(first)
  let #(second, _again) = arrive(app, "c2", [], resuming(token, []))
  server.disconnect(second)

  let #(_third, latest) = arrive(app, "c3", [], resuming(token, []))

  connected_ids(latest()) |> should.equal(["c3"])
}

// =============================================================================
// MESSAGE IDS
// =============================================================================

pub fn session_grace_resume_says_which_messages_were_answered_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([]))
  let id = wire_support.unique_id()
  wire_support.send(
    first,
    transport.SessionMessage(id:, payload: test_support.IncrementSecondary),
  )
  let token = resume_token(frames())
  server.disconnect(first)

  let #(_second, again) = arrive(app, "c2", [], resuming(token, []))

  list.filter_map(again(), fn(frame) {
    case frame {
      transport.Connected(client_id: "c1", answered:, ..) -> Ok(answered)
      _ -> Error(Nil)
    }
  })
  |> should.equal([id])
}

pub fn session_grace_a_fresh_session_drops_what_the_page_sent_before_test() {
  let #(app, _events) = grace_server(30_000)
  let #(first, frames) =
    arrive(
      app,
      "c1",
      [],
      transport.Resync(cursors: [], resume: option.None, delivered: 7),
    )
  let _ = frames()

  wire_support.send(
    first,
    transport.SessionMessage(id: 7, payload: test_support.IncrementSecondary),
  )

  frames()
  |> should.equal([transport.Dropped(target: transport.Session, id: 7)])
}

pub fn session_grace_a_held_message_lost_with_its_link_runs_when_sent_again_test() {
  let clock = test_support.new_shared(0)
  let #(app, _events) =
    grace_server_with(30_000, fn(builder) {
      builder
      |> server.rate_limit(per_second: 1, burst: 1)
      |> server.clock(now: fn() { test_support.get_shared(clock) })
    })
  let #(first, frames) = arrive(app, "c1", [], wire_support.resync([]))
  let id = wire_support.unique_id()
  // the resync spent the allowance, so this one waits
  let held =
    transport.SessionMessage(id:, payload: test_support.IncrementSecondary)
  wire_support.send(first, held)
  let token = resume_token(frames())
  server.disconnect(first)
  test_support.set_shared(clock, 10_000)
  let #(second, again) = arrive(app, "c2", [], resuming(token, []))
  let _ = again()
  test_support.set_shared(clock, 20_000)

  wire_support.send(second, held)

  again()
  |> should.equal([
    transport.Acknowledge(target: transport.Session, sequence: 1, id:),
  ])
}

// =============================================================================
// EXPIRY AND LIMITS
// =============================================================================

pub fn session_grace_expiry_reports_unsubscribed_then_disconnected_test() -> wire_support.Later {
  let #(app, events) = grace_server(40)
  let #(first, _frames) = arrive(app, "c1", [], wire_support.resync([chat]))
  wire_support.settle(app)
  let _ = events()

  server.disconnect(first)
  events() |> should.equal([])

  use <- wire_support.after(200)
  events()
  |> should.equal([
    server.Unsubscribed(client_id: "c1", topic_id: "chat"),
    server.ClientDisconnected("c1"),
  ])
}

pub fn session_grace_a_new_session_past_max_clients_ends_the_oldest_parked_test() {
  let #(app, events) =
    grace_server_with(30_000, server.max_clients(_, count: 2))
  let #(first, _) = arrive(app, "c1", [], wire_support.resync([]))
  let #(second, _) = arrive(app, "c2", [], wire_support.resync([]))
  server.disconnect(first)
  server.disconnect(second)
  let _ = events()

  let _ = arrive(app, "c3", [], wire_support.resync([]))

  events()
  |> should.equal([
    server.ClientDisconnected("c1"),
    server.ClientConnected("c3"),
  ])
}

pub fn session_grace_an_eviction_ends_the_session_test() {
  let #(app, events) = grace_server(30_000)
  let _ = arrive(app, "c1", [], wire_support.resync([]))
  let _ = events()

  let _ = arrive(app, "c1", [], wire_support.resync([]))

  events()
  |> should.equal([
    server.ClientEvicted(client_id: "c1", reason: server.Superseded),
    server.ClientDisconnected("c1"),
    server.ClientConnected("c1"),
  ])
}

pub fn session_grace_of_zero_ends_a_session_when_its_connection_closes_test() {
  let #(app, events) = grace_server(0)
  let #(first, _frames) = connect(app, "c1", [])
  let _ = events()

  server.disconnect(first)

  events() |> should.equal([server.ClientDisconnected("c1")])
}
