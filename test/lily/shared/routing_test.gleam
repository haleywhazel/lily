// Tests for lily/store Wiring builder, route_message, apply_message,
// merge_snapshot.

import gleeunit/should
import lily/store
import lily/transport

// =============================================================================
// TYPES
// =============================================================================

type OuterModel {
  OuterModel(session: Int, chat: Int, news: Int, other: Int)
}

type Message {
  SessionMessage(Int)
  ChatMessage(Int)
  NewsMessage(Int)
  Unmatched
}

// =============================================================================
// HELPERS
// =============================================================================

fn initial_outer() -> OuterModel {
  OuterModel(session: 0, chat: 0, news: 0, other: 99)
}

fn with_session(
  r: store.Wiring(OuterModel, Message),
) -> store.Wiring(OuterModel, Message) {
  store.session(
    r,
    extract: fn(message) {
      case message {
        SessionMessage(n) -> Ok(n)
        ChatMessage(_) | NewsMessage(_) | Unmatched -> Error(Nil)
      }
    },
    update: fn(current: Int, delta: Int) -> Int { current + delta },
    field_get: fn(model: OuterModel) { model.session },
    field_set: fn(model, session) { OuterModel(..model, session:) },
  )
}

fn with_chat(
  r: store.Wiring(OuterModel, Message),
) -> store.Wiring(OuterModel, Message) {
  store.topic(
    r,
    id: "chat",
    extract: fn(message) {
      case message {
        ChatMessage(n) -> Ok(n)
        SessionMessage(_) | NewsMessage(_) | Unmatched -> Error(Nil)
      }
    },
    update: fn(current: Int, delta: Int) -> Int { current + delta },
    field_get: fn(model: OuterModel) { model.chat },
    field_set: fn(model, chat) { OuterModel(..model, chat:) },
  )
}

fn with_news(
  r: store.Wiring(OuterModel, Message),
) -> store.Wiring(OuterModel, Message) {
  store.topic(
    r,
    id: "news",
    extract: fn(message) {
      case message {
        NewsMessage(n) -> Ok(n)
        SessionMessage(_) | ChatMessage(_) | Unmatched -> Error(Nil)
      }
    },
    update: fn(current: Int, delta: Int) -> Int { current + delta },
    field_get: fn(model: OuterModel) { model.news },
    field_set: fn(model, news) { OuterModel(..model, news:) },
  )
}

// =============================================================================
// BUILDER
// =============================================================================

pub fn wiring_new_is_empty_test() {
  // An empty routing falls back to Session for any message.
  let r = store.wiring()
  store.route_message(r, Unmatched)
  |> should.equal(transport.Session)
}

pub fn wiring_session_registers_session_target_test() {
  let r = store.wiring() |> with_session
  store.route_message(r, SessionMessage(1))
  |> should.equal(transport.Session)
}

pub fn wiring_topic_registers_topic_target_test() {
  let r = store.wiring() |> with_chat
  store.route_message(r, ChatMessage(1))
  |> should.equal(transport.Topic("chat"))
}

pub fn wiring_multiple_topics_register_independently_test() {
  let r = store.wiring() |> with_chat |> with_news
  store.route_message(r, ChatMessage(1))
  |> should.equal(transport.Topic("chat"))
  store.route_message(r, NewsMessage(1))
  |> should.equal(transport.Topic("news"))
}

// =============================================================================
// ROUTE MESSAGE
// =============================================================================

pub fn route_message_no_match_falls_back_to_session_test() {
  // When no entry's extract accepts the message, route_message returns Session.
  // This is the documented safe fallback for unrecognised messages.
  let r = store.wiring() |> with_session |> with_chat
  store.route_message(r, Unmatched)
  |> should.equal(transport.Session)
}

pub fn route_message_session_wins_when_both_match_test() {
  // Session has priority over topic when both extracts accept the same message.
  // This pins the precedence so a future refactor cannot silently swap it.
  let r =
    store.wiring()
    |> store.session(
      extract: fn(_message) { Ok(0) },
      update: fn(current: Int, _n: Int) -> Int { current },
      field_get: fn(model: OuterModel) { model.session },
      field_set: fn(model, session) { OuterModel(..model, session:) },
    )
    |> store.topic(
      id: "chat",
      extract: fn(_message) { Ok(0) },
      update: fn(current: Int, _n: Int) -> Int { current },
      field_get: fn(model: OuterModel) { model.chat },
      field_set: fn(model, chat) { OuterModel(..model, chat:) },
    )
  store.route_message(r, SessionMessage(1))
  |> should.equal(transport.Session)
}

pub fn route_message_two_topics_both_match_returns_a_topic_test() {
  // When two topics both claim the message, the result is some Topic target,
  // which exact topic wins is unspecified (dict iteration order).
  // Invariant: extract functions across topics must be mutually exclusive.
  let r =
    store.wiring()
    |> store.topic(
      id: "chat",
      extract: fn(_message) { Ok(0) },
      update: fn(current: Int, _n: Int) -> Int { current },
      field_get: fn(model: OuterModel) { model.chat },
      field_set: fn(model, chat) { OuterModel(..model, chat:) },
    )
    |> store.topic(
      id: "news",
      extract: fn(_message) { Ok(0) },
      update: fn(current: Int, _n: Int) -> Int { current },
      field_get: fn(model: OuterModel) { model.news },
      field_set: fn(model, news) { OuterModel(..model, news:) },
    )
  case store.route_message(r, Unmatched) {
    transport.Topic(_) -> Nil
    transport.Session -> should.fail()
  }
}

// =============================================================================
// APPLY MESSAGE
// =============================================================================

pub fn apply_message_no_match_leaves_model_unchanged_test() {
  let r = store.wiring() |> with_session |> with_chat
  let model = initial_outer()
  store.apply_message(r, model, Unmatched)
  |> should.equal(model)
}

pub fn apply_message_session_updates_session_field_test() {
  let r = store.wiring() |> with_session
  let model = initial_outer()
  let updated = store.apply_message(r, model, SessionMessage(5))
  updated.session
  |> should.equal(5)
  updated.other
  |> should.equal(99)
}

pub fn apply_message_topic_updates_topic_field_test() {
  let r = store.wiring() |> with_chat
  let model = initial_outer()
  let updated = store.apply_message(r, model, ChatMessage(3))
  updated.chat
  |> should.equal(3)
  updated.session
  |> should.equal(0)
}

pub fn apply_message_only_updates_matching_topic_field_test() {
  let r = store.wiring() |> with_chat |> with_news
  let model = initial_outer()
  let updated = store.apply_message(r, model, ChatMessage(7))
  updated.chat
  |> should.equal(7)
  updated.news
  |> should.equal(0)
}

// =============================================================================
// MERGE SNAPSHOT
// =============================================================================

pub fn merge_snapshot_unknown_topic_returns_current_unchanged_test() {
  let r = store.wiring() |> with_session |> with_chat
  let current = initial_outer()
  let snapshot = OuterModel(session: 99, chat: 99, news: 99, other: 42)
  store.merge_snapshot(r, transport.Topic("missing"), current, snapshot)
  |> should.equal(current)
}

pub fn merge_snapshot_replaces_only_target_topic_slice_test() {
  let r = store.wiring() |> with_session |> with_chat
  let current = OuterModel(session: 1, chat: 2, news: 3, other: 99)
  let snapshot = OuterModel(session: 100, chat: 200, news: 300, other: 0)
  let merged =
    store.merge_snapshot(r, transport.Topic("chat"), current, snapshot)
  // chat takes the snapshot value
  merged.chat
  |> should.equal(200)
  // session stays at current, not touched by a chat snapshot
  merged.session
  |> should.equal(1)
  // news stays at current
  merged.news
  |> should.equal(3)
}

pub fn merge_snapshot_session_replaces_session_slice_test() {
  let r = store.wiring() |> with_session |> with_chat
  let current = OuterModel(session: 1, chat: 2, news: 3, other: 99)
  let snapshot = OuterModel(session: 100, chat: 200, news: 300, other: 0)
  let merged = store.merge_snapshot(r, transport.Session, current, snapshot)
  merged.session
  |> should.equal(100)
  merged.chat
  |> should.equal(2)
}
