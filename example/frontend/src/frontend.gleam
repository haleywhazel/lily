import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

import lily/client
import lily/component.{type Patch, SetAttribute, SetText}
import lily/event
import lily/store
import lily/transport

import shared

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

// =============================================================================
// ENTRY POINT
// =============================================================================

pub fn main() {
  let runtime =
    store.new(shared.initial_model(), with: shared.update)
    |> client.start(shared.wiring())

  let dispatch = client.dispatch(runtime)

  runtime
  |> client.attach_session(
    persistence: theme_persistence(),
    get: fn(model: shared.Model) { model.session.theme },
    set: fn(model, theme) {
      shared.Model(
        ..model,
        session: shared.SessionState(..model.session, theme:),
      )
    },
  )
  |> client.attach_session(
    persistence: username_persistence(),
    get: fn(model: shared.Model) { model.session.username },
    set: fn(model, username) {
      shared.Model(
        ..model,
        session: shared.SessionState(..model.session, username:),
      )
    },
  )
  |> component.mount(
    selector: "#app",
    to_html: element.to_string,
    to_slot: fn() { element.element("lily-slot", [], []) },
    view: app,
  )
  |> client.connection_status(set: fn(model: shared.Model, status) {
    shared.Model(
      ..model,
      session: shared.SessionState(..model.session, connected: status),
    )
  })
  |> client.on_message(fn(message, model) {
    case message {
      // A room message from someone else pops a notification; our own echoes
      // back to the input so typing keeps flowing.
      shared.RoomMessage(room_id:, message: shared.SendMessage(body:, sender_id:)) ->
        case sender_id == model.session.username {
          True -> event.focus(runtime, "#room-input")
          False ->
            dispatch(
              shared.Session(shared.AddPopup(
                sender_id <> " in " <> room_id <> ": " <> body,
              )),
            )
        }
      shared.Session(shared.JoinRoom(room_id:)) -> {
        let _ = client.subscribe(runtime, "room:" <> room_id)
        event.focus(runtime, "#room-input")
      }
      _ -> handle_focus(runtime, message)
    }
  })
  |> client.client_id(set: fn(model, id) {
    shared.Model(
      ..model,
      session: shared.SessionState(..model.session, session_id: id),
    )
  })
  |> client.connect(
    with: transport.websocket(url: transport.url_from_current_location(
      path: "/ws",
    ))
      |> transport.reconnect_base_milliseconds(250)
      |> transport.reconnect_max_milliseconds(5000)
      |> transport.websocket_connect,
    serialiser: shared.serialiser(),
  )

  Nil
}

// =============================================================================
// SESSION PERSISTENCE
// =============================================================================

fn theme_persistence() -> client.Persistence(shared.Theme) {
  client.session_persistence()
  |> client.session_field(
    key: "theme",
    get: fn(theme: shared.Theme) { theme },
    set: fn(_theme, value) { value },
    encode: shared.encode_theme,
    decoder: shared.decode_theme(),
  )
}

fn username_persistence() -> client.Persistence(String) {
  client.session_persistence()
  |> client.session_field(
    key: "username",
    get: fn(name: String) { name },
    set: fn(_old, new) { new },
    encode: json.string,
    decoder: decode.string,
  )
}

// =============================================================================
// EVENT DECODING
// =============================================================================

fn parse_click(message_name: String) -> Result(shared.Message, Nil) {
  case message_name {
    "toggle-theme" -> Ok(shared.Session(shared.ToggleTheme))
    "open-clear" -> Ok(shared.Session(shared.OpenClearDialog))
    "close-clear" -> Ok(shared.Session(shared.CloseClearDialog))
    "confirm-clear" -> Ok(shared.Session(shared.ClearNotifications))
    other ->
      case string.split_once(other, on: ":") {
        Ok(#("dismiss-popup", id_string)) ->
          case int.parse(id_string) {
            Ok(id) -> Ok(shared.Session(shared.DismissPopup(id)))
            Error(Nil) -> Error(Nil)
          }
        Ok(#("select-room", room_id)) ->
          Ok(shared.Session(shared.SelectRoom(room_id)))
        _ -> Error(Nil)
      }
  }
}

fn parse_join_room(
  fields: List(#(String, String)),
) -> Result(shared.Message, Nil) {
  case list.key_find(fields, "room") {
    Ok(name) ->
      case string.trim(name) {
        "" -> Error(Nil)
        trimmed -> Ok(shared.Session(shared.JoinRoom(trimmed)))
      }
    Error(Nil) -> Error(Nil)
  }
}

fn parse_room_submit(
  fields: List(#(String, String)),
) -> Result(shared.Message, Nil) {
  case
    list.key_find(fields, "body"),
    list.key_find(fields, "sender_id"),
    list.key_find(fields, "room_id")
  {
    Ok(body), Ok(sender_id), Ok(room_id) ->
      case string.trim(body), room_id {
        "", _ -> Error(Nil)
        _, "" -> Error(Nil)
        trimmed, _ ->
          Ok(shared.RoomMessage(
            room_id:,
            message: shared.SendMessage(body: trimmed, sender_id:),
          ))
      }
    _, _, _ -> Error(Nil)
  }
}

fn parse_username_submit(
  fields: List(#(String, String)),
) -> Result(shared.Message, Nil) {
  case list.key_find(fields, "name") {
    Ok(name) ->
      case string.trim(name) {
        "" -> Error(Nil)
        trimmed -> Ok(shared.Session(shared.SetUsername(trimmed)))
      }
    Error(Nil) -> Error(Nil)
  }
}

// =============================================================================
// FOCUS SIDE EFFECTS
// =============================================================================

fn handle_focus(
  runtime: client.Runtime(shared.Model, shared.Message),
  message: shared.Message,
) -> Nil {
  case message {
    shared.Session(shared.OpenClearDialog) -> {
      event.focus(runtime, "#clear-dialog-cancel")
      event.focus_trap(
        runtime,
        within: "#clear-dialog",
        release_on: fn(key) { key == "Escape" },
        on_exit: fn() { shared.Session(shared.CloseClearDialog) },
      )
    }
    shared.Session(shared.ClearNotifications) -> {
      event.release_focus_trap(runtime)
      event.focus(runtime, "#clear-button")
    }
    shared.Session(shared.CloseClearDialog) -> {
      event.release_focus_trap(runtime)
      event.focus(runtime, "#clear-button")
    }
    shared.Session(shared.SelectRoom(_)) -> event.focus(runtime, "#room-input")
    shared.Session(shared.SetUsername(_)) ->
      event.focus(runtime, "#room-name-input")
    shared.Session(shared.JoinRoom(_)) -> Nil
    shared.Session(shared.DismissPopup(_id)) -> Nil
    shared.Session(shared.ToggleTheme) -> Nil
    shared.Session(shared.UpdateDraft(_text)) -> Nil
    shared.Session(shared.AddPopup(_body)) -> Nil
    shared.RoomMessage(..) -> Nil
  }
}

// =============================================================================
// VIEW
// =============================================================================

fn app(
  model: shared.Model,
) -> component.Component(shared.Model, shared.Message, Element(shared.Message)) {
  let initial_theme_string = shared.theme_to_string(model.session.theme)
  component.live(
    slice: fn(model: shared.Model) {
      shared.theme_to_string(model.session.theme)
    },
    initial: fn(slot) {
      html.div(
        [
          attribute.class("app-root"),
          attribute.attribute("data-theme", initial_theme_string),
        ],
        [
          html.header([], [
            html.a(
              [
                attribute.class("skip-link"),
                attribute.attribute("href", "#main"),
              ],
              [html.text("Skip to main content")],
            ),
            slot(navbar()),
          ]),
          slot(popup_stack()),
          html.main(
            [
              attribute.id("main"),
              attribute.attribute("tabindex", "-1"),
              attribute.class("page"),
            ],
            [
              html.h1([attribute.class("page-title")], [html.text("Rooms")]),
              slot(room_tabs()),
              html.div(
                [
                  attribute.role("log"),
                  attribute.attribute("aria-live", "polite"),
                  attribute.attribute("aria-label", "Room history"),
                ],
                [slot(room_history())],
              ),
              slot(room_composer()),
            ],
          ),
          slot(clear_dialog()),
        ],
      )
    },
    patch: fn(theme: String) {
      [SetAttribute(".app-root", "data-theme", theme)]
    },
  )
  |> event.on_decoded(
    event: event.click,
    selector: "#app",
    decoder: parse_click,
  )
}

// =============================================================================
// NAVBAR
// =============================================================================

fn navbar() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.static(fn(slot) {
    html.nav(
      [
        attribute.class("navbar"),
        attribute.attribute("aria-label", "Primary"),
      ],
      [
        html.div([attribute.class("brand")], [
          html.div([attribute.class("brand-mark")], []),
          html.span([attribute.class("brand-name")], [html.text("Lily")]),
        ]),
        html.ul([attribute.class("nav-links")], [
          html.li([], [
            html.a(
              [
                attribute.attribute("href", "#main"),
                attribute.attribute("aria-current", "page"),
              ],
              [html.text("Rooms")],
            ),
          ]),
          html.li([], [
            html.a(
              [
                attribute.attribute("href", "https://hexdocs.pm/lily/"),
                attribute.attribute("target", "_blank"),
                attribute.attribute("rel", "noreferrer"),
              ],
              [
                html.text("Docs"),
                html.span([attribute.class("visually-hidden")], [
                  html.text(" (opens in new window)"),
                ]),
              ],
            ),
          ]),
          html.li([], [
            html.a(
              [
                attribute.attribute(
                  "href",
                  "https://github.com/haleywhazel/lily",
                ),
                attribute.attribute("target", "_blank"),
                attribute.attribute("rel", "noreferrer"),
              ],
              [
                html.text("GitHub"),
                html.span([attribute.class("visually-hidden")], [
                  html.text(" (opens in new window)"),
                ]),
              ],
            ),
          ]),
        ]),
        html.div([attribute.class("navbar-controls")], [
          slot(connection_status()),
          slot(theme_toggle()),
        ]),
      ],
    )
  })
}

fn connection_status() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.live(
    slice: fn(model: shared.Model) { model.session.connected },
    initial: fn(_slot) {
      html.span([attribute.class("status")], [
        html.span([attribute.class("dot")], []),
        html.span(
          [
            attribute.class("status-label"),
            attribute.role("status"),
            attribute.attribute("aria-live", "polite"),
          ],
          [html.text("Online")],
        ),
      ])
    },
    patch: status_patches,
  )
}

fn status_patches(connected: Bool) -> List(Patch) {
  let status_class = case connected {
    True -> "status"
    False -> "status offline"
  }
  let label = case connected {
    True -> "Online"
    False -> "Reconnecting…"
  }
  [
    SetAttribute(".status", "class", status_class),
    SetText(".status-label", label),
  ]
}

fn theme_toggle() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.live(
    slice: fn(model: shared.Model) { model.session.theme == shared.Light },
    initial: fn(_slot) {
      html.button(
        [
          attribute.class("theme-toggle"),
          attribute.attribute("type", "button"),
          attribute.attribute("data-message", "toggle-theme"),
          attribute.attribute("aria-pressed", "false"),
          attribute.attribute("aria-label", "Toggle light theme"),
        ],
        [html.text("Theme")],
      )
    },
    patch: fn(is_light: Bool) {
      let pressed = case is_light {
        True -> "true"
        False -> "false"
      }
      [SetAttribute(".theme-toggle", "aria-pressed", pressed)]
    },
  )
}

// =============================================================================
// POPUPS/NOTIFS
// =============================================================================

fn popup_stack() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.static(fn(slot) {
    html.aside(
      [
        attribute.class("popup-stack"),
        attribute.role("region"),
        attribute.attribute("aria-label", "Notifications"),
        attribute.attribute("aria-live", "polite"),
        attribute.attribute("aria-atomic", "false"),
      ],
      [slot(clear_button()), slot(popups_list())],
    )
  })
}

fn clear_button() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.simple(
    slice: fn(model: shared.Model) { model.session.popups },
    render: fn(popups, _slot) {
      case popups {
        [] -> html.div([], [])
        _ ->
          html.button(
            [
              attribute.id("clear-button"),
              attribute.class("clear-button"),
              attribute.attribute("type", "button"),
              attribute.attribute("data-message", "open-clear"),
            ],
            [html.text("Clear notifications")],
          )
      }
    },
  )
}

fn popups_list() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.each_live(
    slice: fn(model: shared.Model) { model.session.popups },
    key: fn(popup: shared.Popup) { int.to_string(popup.id) },
    initial: render_popup,
    patch: fn(_popup: shared.Popup) { [] },
  )
  |> component.structural
}

fn render_popup(
  popup: shared.Popup,
) -> component.Component(shared.Model, shared.Message, Element(shared.Message)) {
  component.static(fn(_slot) {
    html.div([attribute.class("popup"), attribute.role("status")], [
      html.p([attribute.class("popup-body")], [html.text(popup.body)]),
      html.button(
        [
          attribute.class("popup-dismiss"),
          attribute.attribute("type", "button"),
          attribute.attribute(
            "data-message",
            "dismiss-popup:" <> int.to_string(popup.id),
          ),
          attribute.attribute("aria-label", "Dismiss notification"),
        ],
        [html.text("×")],
      ),
    ])
  })
}

// =============================================================================
// ROOM TABS
// =============================================================================

fn room_tabs() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.simple(
    slice: fn(model: shared.Model) {
      #(model.session.joined_rooms, model.session.active_room)
    },
    render: fn(state, _slot) {
      let #(rooms, active) = state
      case rooms {
        [] -> html.div([], [])
        _ ->
          html.ul(
            [attribute.class("room-list"), attribute.role("tablist")],
            list.map(rooms, fn(room_id) { room_tab(room_id, active) }),
          )
      }
    },
  )
  |> component.structural
}

fn room_tab(room_id: String, active: String) -> Element(shared.Message) {
  let class = case room_id == active {
    True -> "room-tab active"
    False -> "room-tab"
  }
  let selected = case room_id == active {
    True -> "true"
    False -> "false"
  }
  html.li([], [
    html.button(
      [
        attribute.class(class),
        attribute.role("tab"),
        attribute.attribute("type", "button"),
        attribute.attribute("aria-selected", selected),
        attribute.attribute("data-message", "select-room:" <> room_id),
      ],
      [html.text(room_id)],
    ),
  ])
}

// =============================================================================
// ROOM HISTORY
// =============================================================================

fn room_history() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.simple(
    slice: fn(model: shared.Model) {
      let history =
        dict.get(model.rooms, model.session.active_room)
        |> result.map(fn(room: shared.Room) { room.history })
        |> result.unwrap([])
      #(model.session.active_room, history)
    },
    render: fn(state, _slot) {
      let #(active, history) = state
      case active {
        "" -> html.div([], [])
        _ ->
          html.div(
            [attribute.class("chat-history")],
            list.map(history, render_chat_entry),
          )
      }
    },
  )
  |> component.structural
}

fn render_chat_entry(entry: shared.ChatEntry) -> Element(shared.Message) {
  html.div([attribute.class("chat-message")], [
    html.span([attribute.class("chat-message-sender")], [
      html.span([attribute.class("sender-id")], [html.text(entry.sender_id)]),
      html.text(": "),
    ]),
    html.span([attribute.class("chat-message-body")], [html.text(entry.body)]),
  ])
}

// =============================================================================
// ROOM COMPOSER
// =============================================================================

fn room_composer() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.simple(
    slice: fn(model: shared.Model) {
      #(model.session.username, model.session.active_room)
    },
    render: fn(state, _slot) {
      let #(username, active) = state
      case username {
        "" -> html.div([attribute.class("chat-area")], [username_form()])
        _ ->
          html.div([attribute.class("chat-area")], [
            case active {
              "" ->
                html.p([attribute.class("room-empty")], [
                  html.text("Create or join a room below to start chatting."),
                ])
              room_id -> message_form(room_id, username)
            },
            join_room_form(),
          ])
      }
    },
  )
  |> component.structural
  |> event.on(event: event.input, selector: "#room-input", handler: fn(text) {
    shared.Session(shared.UpdateDraft(text))
  })
  |> event.on_decoded(
    event: event.form_submit,
    selector: "#username-form",
    decoder: parse_username_submit,
  )
  |> event.on_decoded(
    event: event.form_submit,
    selector: "#join-room-form",
    decoder: parse_join_room,
  )
  |> event.on_decoded(
    event: event.form_submit,
    selector: "#room-form",
    decoder: parse_room_submit,
  )
}

fn username_form() -> Element(shared.Message) {
  html.form([attribute.id("username-form"), attribute.class("chat-form")], [
    html.label(
      [
        attribute.attribute("for", "username-input"),
        attribute.class("visually-hidden"),
      ],
      [html.text("Display name")],
    ),
    html.input([
      attribute.id("username-input"),
      attribute.attribute("name", "name"),
      attribute.attribute("type", "text"),
      attribute.attribute("autocomplete", "nickname"),
      attribute.attribute("placeholder", "Pick a display name…"),
      attribute.attribute("maxlength", "32"),
    ]),
    html.button(
      [attribute.class("send-button"), attribute.attribute("type", "submit")],
      [html.text("Join")],
    ),
  ])
}

fn join_room_form() -> Element(shared.Message) {
  html.form([attribute.id("join-room-form"), attribute.class("join-form")], [
    html.label(
      [
        attribute.attribute("for", "room-name-input"),
        attribute.class("visually-hidden"),
      ],
      [html.text("Room name")],
    ),
    html.input([
      attribute.id("room-name-input"),
      attribute.attribute("name", "room"),
      attribute.attribute("type", "text"),
      attribute.attribute("autocomplete", "off"),
      attribute.attribute("placeholder", "Create or join a room…"),
      attribute.attribute("maxlength", "32"),
    ]),
    html.button(
      [attribute.class("send-button"), attribute.attribute("type", "submit")],
      [html.text("Go")],
    ),
  ])
}

fn message_form(room_id: String, username: String) -> Element(shared.Message) {
  html.form([attribute.id("room-form"), attribute.class("chat-form")], [
    html.label(
      [
        attribute.attribute("for", "room-input"),
        attribute.class("visually-hidden"),
      ],
      [html.text("Message")],
    ),
    html.input([
      attribute.attribute("type", "hidden"),
      attribute.attribute("name", "room_id"),
      attribute.attribute("value", room_id),
    ]),
    html.input([
      attribute.attribute("type", "hidden"),
      attribute.attribute("name", "sender_id"),
      attribute.attribute("value", username),
    ]),
    html.input([
      attribute.id("room-input"),
      attribute.attribute("name", "body"),
      attribute.attribute("type", "text"),
      attribute.attribute("autocomplete", "off"),
      attribute.attribute("placeholder", "Message #" <> room_id <> "…"),
    ]),
    html.button(
      [attribute.class("send-button"), attribute.attribute("type", "submit")],
      [html.text("Send")],
    ),
  ])
}

// =============================================================================
// CLEAR DIALOG
// =============================================================================

fn clear_dialog() -> component.Component(
  shared.Model,
  shared.Message,
  Element(shared.Message),
) {
  component.simple(
    slice: fn(model: shared.Model) {
      #(model.session.dialog_open, list.length(model.session.popups))
    },
    render: fn(state, _slot) {
      let #(open, popup_count) = state
      case open {
        False -> html.div([attribute.class("clear-dialog__hidden")], [])
        True -> render_dialog(popup_count)
      }
    },
  )
}

fn render_dialog(popup_count: Int) -> Element(shared.Message) {
  let summary = case popup_count {
    0 -> "There are no notifications to clear."
    count ->
      "Clears "
      <> int.to_string(count)
      <> " notification(s). This only affects your view."
  }
  html.div(
    [
      attribute.class("clear-dialog__overlay"),
      attribute.attribute("data-message", "close-clear"),
    ],
    [
      html.div(
        [
          attribute.id("clear-dialog"),
          attribute.class("clear-dialog"),
          attribute.role("dialog"),
          attribute.attribute("aria-modal", "true"),
          attribute.attribute("aria-labelledby", "clear-dialog-title"),
          attribute.attribute("aria-describedby", "clear-dialog-desc"),
        ],
        [
          html.h2([attribute.id("clear-dialog-title")], [
            html.text("Clear notifications?"),
          ]),
          html.p([attribute.id("clear-dialog-desc")], [html.text(summary)]),
          html.div([attribute.class("clear-dialog__actions")], [
            html.button(
              [
                attribute.id("clear-dialog-cancel"),
                attribute.attribute("type", "button"),
                attribute.attribute("data-message", "close-clear"),
              ],
              [html.text("Cancel")],
            ),
            html.button(
              [
                attribute.id("clear-dialog-confirm"),
                attribute.class("destructive"),
                attribute.attribute("type", "button"),
                attribute.attribute("data-message", "confirm-clear"),
              ],
              [html.text("Clear")],
            ),
          ]),
        ],
      ),
    ],
  )
}
