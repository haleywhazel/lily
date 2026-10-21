// store routing and snapshot merging into session or topic slices
// pure, target-agnostic

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict
import gleam/result

import gleeunit/should

import lily/store
import lily/transport

// =============================================================================
// HELPERS
// =============================================================================

type OuterModel {
  OuterModel(
    session: Int,
    chat: Int,
    news: Int,
    rooms: dict.Dict(String, Int),
    other: Int,
  )
}

type Message {
  SessionMessage(Int)
  ChatMessage(Int)
  NewsMessage(Int)
  RoomMessage(room: String, delta: Int)
  Unmatched
}

fn initial_outer() -> OuterModel {
  OuterModel(session: 0, chat: 0, news: 0, rooms: dict.new(), other: 99)
}

fn update(model: OuterModel, message: Message) -> OuterModel {
  case message {
    SessionMessage(amount) ->
      OuterModel(..model, session: model.session + amount)
    ChatMessage(amount) -> OuterModel(..model, chat: model.chat + amount)
    NewsMessage(amount) -> OuterModel(..model, news: model.news + amount)
    RoomMessage(room:, delta:) -> {
      let current = dict.get(model.rooms, room) |> result.unwrap(0)
      OuterModel(
        ..model,
        rooms: dict.insert(model.rooms, room, current + delta),
      )
    }
    Unmatched -> model
  }
}

fn route(message: Message) -> store.Route {
  case message {
    SessionMessage(_) -> store.Session
    ChatMessage(_) -> store.Topic("chat")
    NewsMessage(_) -> store.Topic("news")
    RoomMessage(room:, ..) -> store.Topic("room:" <> room)
    Unmatched -> store.Local
  }
}

fn base() -> store.Store(OuterModel, Message, store.Synced) {
  store.new(init: initial_outer(), update: update)
  |> store.sync(route: route, modules: [])
}

fn with_session(
  app_store: store.Store(OuterModel, Message, store.Synced),
) -> store.Store(OuterModel, Message, store.Synced) {
  store.session(
    app_store,
    get: fn(model: OuterModel) { model.session },
    set: fn(model, session) { OuterModel(..model, session:) },
  )
}

fn with_chat(
  app_store: store.Store(OuterModel, Message, store.Synced),
) -> store.Store(OuterModel, Message, store.Synced) {
  store.topic(
    app_store,
    id: "chat",
    get: fn(model: OuterModel) { model.chat },
    set: fn(model, chat) { OuterModel(..model, chat:) },
    access: store.Open,
  )
}

fn with_news(
  app_store: store.Store(OuterModel, Message, store.Synced),
) -> store.Store(OuterModel, Message, store.Synced) {
  store.topic(
    app_store,
    id: "news",
    get: fn(model: OuterModel) { model.news },
    set: fn(model, news) { OuterModel(..model, news:) },
    access: store.Open,
  )
}

fn with_rooms(
  app_store: store.Store(OuterModel, Message, store.Synced),
) -> store.Store(OuterModel, Message, store.Synced) {
  store.topics(
    app_store,
    prefix: "room:",
    get: fn(model: OuterModel, id) {
      dict.get(model.rooms, id) |> result.unwrap(0)
    },
    set: fn(model, id, value) {
      OuterModel(..model, rooms: dict.insert(model.rooms, id, value))
    },
    access: store.Open,
  )
}

// =============================================================================
// ROUTE
// =============================================================================

pub fn route_sends_a_session_message_to_the_session_test() {
  base()
  |> store.route(SessionMessage(1))
  |> should.equal(store.Session)
}

pub fn route_sends_a_topic_message_to_its_topic_test() {
  base()
  |> store.route(ChatMessage(1))
  |> should.equal(store.Topic("chat"))
}

pub fn route_can_name_a_topic_from_the_message_test() {
  base()
  |> store.route(RoomMessage("42", 1))
  |> should.equal(store.Topic("room:42"))
}

pub fn route_keeps_an_unmatched_message_local_test() {
  base()
  |> store.route(Unmatched)
  |> should.equal(store.Local)
}

pub fn route_does_not_depend_on_what_is_declared_test() {
  // route decides alone, a declared topic only adds access and slice
  let declared = base() |> with_session |> with_chat
  store.route(declared, NewsMessage(1))
  |> should.equal(store.Topic("news"))
}

// =============================================================================
// MERGE SNAPSHOT, SESSION
// =============================================================================

pub fn merge_snapshot_session_replaces_session_slice_test() {
  let app_store = base() |> with_session |> with_chat
  let current = OuterModel(..initial_outer(), session: 1, chat: 2, news: 3)
  let snapshot = OuterModel(..initial_outer(), session: 100, chat: 200)
  let merged =
    store.merge_snapshot(app_store, transport.Session, current, snapshot)

  merged.session
  |> should.equal(100)
  merged.chat
  |> should.equal(2)
  merged.news
  |> should.equal(3)
}

pub fn merge_snapshot_session_leaves_other_fields_alone_test() {
  let app_store = base() |> with_session
  let current = OuterModel(..initial_outer(), other: 7)
  let snapshot = OuterModel(..initial_outer(), session: 5, other: 0)

  store.merge_snapshot(app_store, transport.Session, current, snapshot).other
  |> should.equal(7)
}

pub fn merge_snapshot_session_without_a_declared_slice_is_a_no_op_test() {
  let app_store = base() |> with_chat
  let current = initial_outer()
  let snapshot = OuterModel(..initial_outer(), session: 5)

  store.merge_snapshot(app_store, transport.Session, current, snapshot)
  |> should.equal(current)
}

pub fn merge_snapshot_on_a_standalone_store_is_a_no_op_test() {
  let app_store = store.new(init: initial_outer(), update: update)
  let current = initial_outer()
  let snapshot = OuterModel(..initial_outer(), session: 5)

  store.merge_snapshot(app_store, transport.Session, current, snapshot)
  |> should.equal(current)
  store.merge_snapshot(app_store, transport.Topic("chat"), current, snapshot)
  |> should.equal(current)
}

// =============================================================================
// MERGE SNAPSHOT, TOPIC
// =============================================================================

pub fn merge_snapshot_unknown_topic_returns_current_unchanged_test() {
  let app_store = base() |> with_session |> with_chat
  let current = initial_outer()
  let snapshot = OuterModel(..initial_outer(), session: 99, chat: 99, news: 99)

  store.merge_snapshot(app_store, transport.Topic("missing"), current, snapshot)
  |> should.equal(current)
}

pub fn merge_snapshot_replaces_only_target_topic_slice_test() {
  let app_store = base() |> with_session |> with_chat |> with_news
  let current = OuterModel(..initial_outer(), session: 1, chat: 2, news: 3)
  let snapshot =
    OuterModel(..initial_outer(), session: 100, chat: 200, news: 300, other: 0)
  let merged =
    store.merge_snapshot(app_store, transport.Topic("chat"), current, snapshot)

  merged.chat
  |> should.equal(200)
  merged.session
  |> should.equal(1)
  merged.news
  |> should.equal(3)
  merged.other
  |> should.equal(99)
}

pub fn merge_snapshot_family_hands_the_rest_of_the_id_to_the_slice_test() {
  // `room:42` slice keyed by `42`, other held rooms untouched
  let app_store = base() |> with_rooms
  let current =
    OuterModel(
      ..initial_outer(),
      rooms: dict.from_list([#("42", 1), #("7", 2)]),
    )
  let snapshot =
    OuterModel(..initial_outer(), rooms: dict.from_list([#("42", 99)]))
  let merged =
    store.merge_snapshot(
      app_store,
      transport.Topic("room:42"),
      current,
      snapshot,
    )

  dict.get(merged.rooms, "42")
  |> should.equal(Ok(99))
  dict.get(merged.rooms, "7")
  |> should.equal(Ok(2))
}

pub fn merge_snapshot_family_matching_its_whole_prefix_gets_an_empty_rest_test() {
  let app_store =
    base()
    |> store.topics(
      prefix: "chat",
      get: fn(model: OuterModel, rest) {
        case rest {
          "" -> model.chat
          _ -> -1
        }
      },
      set: fn(model, _rest, chat) { OuterModel(..model, chat:) },
      access: store.Open,
    )
  let snapshot = OuterModel(..initial_outer(), chat: 8)

  store.merge_snapshot(
    app_store,
    transport.Topic("chat"),
    initial_outer(),
    snapshot,
  ).chat
  |> should.equal(8)
}

pub fn merge_snapshot_longest_prefix_picks_the_slice_test() {
  let app_store =
    base()
    |> with_rooms
    |> store.topics(
      prefix: "room:vip:",
      get: fn(model: OuterModel, _id) { model.news },
      set: fn(model, _id, news) { OuterModel(..model, news:) },
      access: store.Open,
    )
  let snapshot = OuterModel(..initial_outer(), news: 5)
  let merged =
    store.merge_snapshot(
      app_store,
      transport.Topic("room:vip:1"),
      initial_outer(),
      snapshot,
    )

  merged.news
  |> should.equal(5)
  merged.rooms
  |> should.equal(dict.new())
}

pub fn merge_snapshot_session_and_topic_do_not_cross_test() {
  let app_store = base() |> with_session |> with_chat
  let current = OuterModel(..initial_outer(), session: 1, chat: 2)
  let snapshot = OuterModel(..initial_outer(), session: 10, chat: 20)
  let after_topic =
    store.merge_snapshot(app_store, transport.Topic("chat"), current, snapshot)
  after_topic.session
  |> should.equal(1)
  let after_session =
    store.merge_snapshot(app_store, transport.Session, after_topic, snapshot)

  after_session.session
  |> should.equal(10)
  after_session.chat
  |> should.equal(20)
}
