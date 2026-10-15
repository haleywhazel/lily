import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

import lily/store
import lily/transport

// =============================================================================
// MODEL
// =============================================================================

pub type Model {
  Model(session: Session, rooms: Dict(String, Room))
}

pub type Session {
  SessionState(
    theme: Theme,
    draft: String,
    dialog_open: Bool,
    popups: List(Popup),
    connected: Bool,
    next_popup_id: Int,
    session_id: String,
    username: String,
    joined_rooms: List(String),
    active_room: String,
  )
}

pub type Room {
  Room(history: List(ChatEntry), next_id: Int)
}

pub type ChatEntry {
  ChatEntry(id: Int, body: String, sender_id: String)
}

pub type Popup {
  Popup(id: Int, body: String)
}

pub type Theme {
  Light
  Dark
}

// =============================================================================
// MESSAGES
// =============================================================================

pub type Message {
  Session(SessionMessage)
  RoomMessage(room_id: String, message: RoomMessage)
}

pub type SessionMessage {
  AddPopup(body: String)
  ClearNotifications
  CloseClearDialog
  DismissPopup(id: Int)
  JoinRoom(room_id: String)
  OpenClearDialog
  SelectRoom(room_id: String)
  SetUsername(name: String)
  ToggleTheme
  UpdateDraft(text: String)
}

pub type RoomMessage {
  SendMessage(body: String, sender_id: String)
}

// =============================================================================
// UPDATE
// =============================================================================

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Session(inner) ->
      Model(..model, session: session_update(model.session, inner))
    RoomMessage(room_id:, message:) -> {
      let room = dict.get(model.rooms, room_id) |> result.unwrap(initial_room())
      Model(
        ..model,
        rooms: dict.insert(model.rooms, room_id, room_update(room, message)),
      )
    }
  }
}

pub fn session_update(session: Session, message: SessionMessage) -> Session {
  case message {
    AddPopup(body) -> {
      let id = session.next_popup_id
      SessionState(
        ..session,
        popups: [Popup(id:, body:), ..session.popups],
        next_popup_id: id + 1,
      )
    }

    ClearNotifications ->
      SessionState(..session, popups: [], dialog_open: False)

    CloseClearDialog -> SessionState(..session, dialog_open: False)

    DismissPopup(id) ->
      SessionState(..session, popups: filter_popup(session.popups, id))

    JoinRoom(room_id) -> {
      // Add to the joined list (once) and make it the active room. The room's
      // synced state arrives separately, as a snapshot after subscribing.
      let joined = case list.contains(session.joined_rooms, room_id) {
        True -> session.joined_rooms
        False -> append(session.joined_rooms, room_id)
      }
      SessionState(..session, joined_rooms: joined, active_room: room_id)
    }

    OpenClearDialog -> SessionState(..session, dialog_open: True)

    SelectRoom(room_id) -> SessionState(..session, active_room: room_id)

    ToggleTheme -> {
      let next = case session.theme {
        Light -> Dark
        Dark -> Light
      }
      SessionState(..session, theme: next)
    }

    SetUsername(name) -> SessionState(..session, username: name)

    UpdateDraft(text) -> SessionState(..session, draft: text)
  }
}

pub fn room_update(room: Room, message: RoomMessage) -> Room {
  case message {
    SendMessage(body:, sender_id:) ->
      case body {
        "" -> room
        _ -> {
          let id = room.next_id
          Room(
            history: append(room.history, ChatEntry(id:, body:, sender_id:)),
            next_id: id + 1,
          )
        }
      }
  }
}

fn append(items: List(a), item: a) -> List(a) {
  case items {
    [] -> [item]
    [head, ..rest] -> [head, ..append(rest, item)]
  }
}

fn filter_popup(popups: List(Popup), drop_id: Int) -> List(Popup) {
  case popups {
    [] -> []
    [Popup(id:, body: _) as popup, ..rest] ->
      case id == drop_id {
        True -> rest
        False -> [popup, ..filter_popup(rest, drop_id)]
      }
  }
}

// =============================================================================
// INITIAL STATE
// =============================================================================

pub fn initial_model() -> Model {
  Model(session: initial_session(), rooms: dict.new())
}

pub fn initial_session() -> Session {
  SessionState(
    theme: Dark,
    draft: "",
    dialog_open: False,
    popups: [],
    connected: True,
    next_popup_id: 1,
    session_id: "",
    username: "",
    joined_rooms: [],
    active_room: "",
  )
}

pub fn initial_room() -> Room {
  Room(history: [], next_id: 1)
}

// =============================================================================
// STORE
// =============================================================================

pub fn store() -> store.Store(Model, Message, store.Synced) {
  store.new(init: initial_model(), update: update)
  |> store.sync(
    route: fn(message) {
      case message {
        Session(_) -> store.Session
        RoomMessage(room_id:, ..) -> store.Topic("room:" <> room_id)
      }
    },
    modules: [transport.module("shared")],
  )
  |> store.session(
    get: fn(model: Model) { model.session },
    set: fn(model, session) { Model(..model, session:) },
  )
  |> store.topic(
    prefix: "room:",
    get: fn(model: Model, key) {
      dict.get(model.rooms, key) |> result.unwrap(initial_room())
    },
    set: fn(model: Model, key, room) {
      Model(..model, rooms: dict.insert(model.rooms, key, room))
    },
    access: store.Open,
  )
  |> store.subscriptions(fn(model: Model) {
    list.map(model.session.joined_rooms, fn(room_id) { "room:" <> room_id })
  })
}

// =============================================================================
// THEME ENCODING
// =============================================================================

pub fn theme_to_string(theme: Theme) -> String {
  case theme {
    Light -> "light"
    Dark -> "dark"
  }
}

pub fn theme_from_string(value: String) -> Result(Theme, Nil) {
  case value {
    "light" -> Ok(Light)
    "dark" -> Ok(Dark)
    _ -> Error(Nil)
  }
}

pub fn encode_theme(theme: Theme) -> json.Json {
  json.string(theme_to_string(theme))
}

pub fn decode_theme() -> decode.Decoder(Theme) {
  decode.string
  |> decode.then(fn(value) {
    case theme_from_string(value) {
      Ok(theme) -> decode.success(theme)
      Error(Nil) -> decode.failure(Dark, "Theme")
    }
  })
}
