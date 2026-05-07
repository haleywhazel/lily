import gleam/dynamic/decode
import gleam/json

import lily/store
import lily/transport

// =============================================================================
// MODEL
// =============================================================================

pub type Model {
  Model(session: Session, chat: Chat)
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
  )
}

pub type Chat {
  ChatState(history: List(ChatEntry), next_id: Int)
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
  Chat(ChatMessage)
}

pub type SessionMessage {
  AddPopup(body: String)
  ClearNotifications
  CloseClearDialog
  DismissPopup(id: Int)
  OpenClearDialog
  SetUsername(name: String)
  ToggleTheme
  UpdateDraft(text: String)
}

pub type ChatMessage {
  SendMessage(body: String, sender_id: String)
}

// =============================================================================
// UPDATE
// =============================================================================

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Session(inner) ->
      Model(..model, session: session_update(model.session, inner))
    Chat(inner) -> Model(..model, chat: chat_update(model.chat, inner))
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

    OpenClearDialog -> SessionState(..session, dialog_open: True)

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

pub fn chat_update(chat: Chat, message: ChatMessage) -> Chat {
  case message {
    SendMessage(body:, sender_id:) ->
      case body {
        "" -> chat
        _ -> {
          let id = chat.next_id
          ChatState(
            history: append(chat.history, ChatEntry(id:, body:, sender_id:)),
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
  Model(session: initial_session(), chat: initial_chat())
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
  )
}

pub fn initial_chat() -> Chat {
  ChatState(history: [], next_id: 1)
}

// =============================================================================
// WIRING
// =============================================================================

pub fn wiring() -> store.Wiring(Model, Message) {
  store.wiring()
  |> store.session(
    extract: fn(message) {
      case message {
        Session(m) -> Ok(m)
        Chat(_) -> Error(Nil)
      }
    },
    update: session_update,
    field_get: fn(model: Model) { model.session },
    field_set: fn(model, session) { Model(..model, session:) },
  )
  |> store.topic(
    id: "chat",
    extract: fn(message) {
      case message {
        Chat(m) -> Ok(m)
        Session(_) -> Error(Nil)
      }
    },
    update: chat_update,
    field_get: fn(model: Model) { model.chat },
    field_set: fn(model, chat) { Model(..model, chat:) },
  )
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

// =============================================================================
// SERIALISER
// =============================================================================

pub fn serialiser() -> transport.Serialiser(Model, Message) {
  let _ = register_types()
  transport.automatic()
}

@target(javascript)
@external(javascript, "./shared.ffi.mjs", "registerTypes")
fn register_types() -> Nil {
  Nil
}

@target(erlang)
fn register_types() -> Nil {
  Nil
}
