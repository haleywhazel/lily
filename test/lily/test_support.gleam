//// Shared fixtures and helpers for the lily suite.
////
//// `json_envelope` and its private codecs mirror
//// docs/recipes/custom-serialiser.md. Keep the two identical.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/dict.{type Dict}
@target(javascript)
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

@target(javascript)
import lily/client
@target(javascript)
import lily/component
import lily/internal/actor
import lily/server
import lily/store
import lily/transport.{type Serialiser}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

pub type Message {
  Increment
  Decrement
  SetName(String)
  Reset
  Noop
  SetTab(Tab)
  IncrementSecondary
  AddTransitionItem(Int)
  RemoveTransitionItem(Int)
  // the last item in stock, only the first claim gets it
  Claim(String)
}

pub type Model {
  Model(
    count: Int,
    name: String,
    connected: Bool,
    // disjoint slices for switch, multi-mount and each transition tests
    // `transition_item` is an Option, empty lists encode differently per
    // target and would break the cross-target wire snapshots
    active_tab: Tab,
    secondary_count: Int,
    transition_item: Option(Int),
  )
}

/// An automatic serialiser edge case, as are the `With` types.
pub type Nested {
  Nested(inner: Model)
}

pub type Ref(value)

/// Like [`Ref`](#Ref) but readable from the server and topic processes.
pub type Shared(value)

pub type Tab {
  TabA
  TabB
}

pub type WithDict {
  WithDict(entries: Dict(String, Int))
}

pub type WithList {
  WithList(items: List(Int))
}

pub type WithSet {
  WithSet(members: Set(Int))
}

pub type WithTuple {
  WithTuple(pair: #(Int, String))
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "activeElementId")
pub fn active_element_id() -> String

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "addThrowingRenderer")
pub fn add_throwing_renderer(
  _runtime: client.Runtime(model, message, mode),
) -> Nil

@target(javascript)
/// The first stubbed animation's playback rate under `selector`, 0 when none.
@external(javascript, "./test_support.ffi.mjs", "animationPlaybackRate")
pub fn animation_playback_rate(_selector: String) -> Float

/// Default depth cap, no modules. Reads both formats whatever `format` is.
pub fn automatic_serialiser(
  format: transport.Format,
) -> Serialiser(model, message) {
  transport.automatic(format:, max_decode_depth: 128, modules: [])
}

/// [`session_store`](#session_store) writing `format`.
pub fn automatic_session_store(
  format: transport.Format,
) -> store.Store(Model, Message, store.Synced) {
  store.new(init: initial_model(), update: update)
  |> store.sync_with(
    route: fn(_) { store.Session },
    serialiser: automatic_serialiser(format),
  )
  |> store.session(get: fn(model) { model }, set: fn(_, model) { model })
}

/// [`topic_store`](#topic_store) via `store.sync`, default `ByHost` format.
pub fn automatic_topic_store() -> store.Store(Model, Message, store.Synced) {
  store.new(init: initial_model(), update: update)
  |> store.sync(route: topic_route, modules: [])
  |> declare_topics([#("chat", store.Open), #("room:", store.Open)])
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "beforeUnloadPrevented")
pub fn before_unload_prevented() -> Bool

pub fn boot_id(app: server.Server(Model, Message)) -> String {
  inspect(app).boot_id
}

/// `#(level, text)` per log line, level is the logger level or console method.
@external(erlang, "lily_test_support_ffi", "capture_log_levels")
@external(javascript, "./test_support.ffi.mjs", "captureLogLevels")
pub fn capture_log_levels(thunk: fn() -> Nil) -> List(#(String, String))

@target(javascript)
/// Console error and warn lines.
@external(javascript, "./test_support.ffi.mjs", "captureLogs")
pub fn capture_logs(_thunk: fn() -> Nil) -> List(String)

@target(javascript)
/// Sets checked, then fires `change`.
@external(javascript, "./test_support.ffi.mjs", "dispatchCheckEvent")
pub fn check_event(_selector: String, _checked: Bool) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "click")
pub fn click(_selector: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "clickPrevented")
pub fn click_prevented(_selector: String) -> Bool

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "clickPreventedWithCtrl")
pub fn click_prevented_with_ctrl(_selector: String) -> Bool

/// -1 when the server isn't running.
pub fn client_count(app: server.Server(Model, Message)) -> Int {
  case server.inspect(app) {
    Ok(inspection) -> inspection.client_count
    Error(Nil) -> -1
  }
}

@target(javascript)
/// Handler to play the server, plus a drain of decoded frames sent since the
/// last call.
pub fn connect_capturing(
  runtime: client.Runtime(Model, Message, store.Synced),
) -> #(
  transport.ConnectorHandler,
  fn() -> List(transport.Protocol(Model, Message)),
) {
  let #(handler, sent) = connect_raw(runtime)
  #(handler, fn() {
    list.map(sent(), fn(bytes) {
      let assert Ok(frame) =
        transport.decode(bytes, serialiser: custom_serialiser())
      frame
    })
  })
}

@target(javascript)
/// [`connect_capturing`](#connect_capturing) with raw bytes.
pub fn connect_raw(
  runtime: client.Runtime(Model, Message, store.Synced),
) -> #(transport.ConnectorHandler, fn() -> List(BitArray)) {
  let sent = new([])
  let handler =
    new(
      transport.ConnectorHandler(
        received: fn(_) { Nil },
        opened: fn() { Nil },
        closed: fn() { Nil },
      ),
    )
  let connector =
    transport.connector(fn(connected) {
      set(handler, connected)
      transport.Channel(
        send: fn(bytes) {
          set(sent, [bytes, ..get(sent)])
          Ok(Nil)
        },
        close: fn() { Nil },
      )
    })
  let _ = client.connect(runtime, with: connector)
  #(get(handler), fn() {
    let frames = list.reverse(get(sent))
    set(sent, [])
    frames
  })
}

@target(javascript)
/// `#(querySelector calls, insertBefore calls)` made by `thunk`.
@external(javascript, "./test_support.ffi.mjs", "countDomCalls")
pub fn count_dom_calls(_thunk: fn() -> Nil) -> #(Int, Int)

/// The fixtures' own codecs behind the recipe's envelope.
pub fn custom_serialiser() -> Serialiser(Model, Message) {
  json_envelope(
    encode_message: encode_message,
    message_decoder: message_decoder(),
    encode_model: encode_model,
    model_decoder: model_decoder(),
  )
}

@target(javascript)
/// Stops listeners left by earlier tests from claiming a click.
@external(javascript, "./test_support.ffi.mjs", "dropDocumentClickListeners")
pub fn drop_document_click_listeners() -> Nil

pub fn encode_message(message: Message) -> Json {
  case message {
    Increment -> json.object([#("tag", json.string("Increment"))])
    Decrement -> json.object([#("tag", json.string("Decrement"))])
    SetName(name) ->
      json.object([
        #("tag", json.string("SetName")),
        #("name", json.string(name)),
      ])
    Reset -> json.object([#("tag", json.string("Reset"))])
    Noop -> json.object([#("tag", json.string("Noop"))])
    SetTab(tab) ->
      json.object([
        #("tag", json.string("SetTab")),
        #("tab", json.string(tab_to_string(tab))),
      ])
    IncrementSecondary ->
      json.object([#("tag", json.string("IncrementSecondary"))])
    AddTransitionItem(id) ->
      json.object([
        #("tag", json.string("AddTransitionItem")),
        #("id", json.int(id)),
      ])
    RemoveTransitionItem(id) ->
      json.object([
        #("tag", json.string("RemoveTransitionItem")),
        #("id", json.int(id)),
      ])
    Claim(who) ->
      json.object([#("tag", json.string("Claim")), #("who", json.string(who))])
  }
}

pub fn encode_model(model: Model) -> Json {
  let transition_item = case model.transition_item {
    Some(id) -> json.int(id)
    None -> json.null()
  }
  json.object([
    #("count", json.int(model.count)),
    #("name", json.string(model.name)),
    #("connected", json.bool(model.connected)),
    #("active_tab", json.string(tab_to_string(model.active_tab))),
    #("secondary_count", json.int(model.secondary_count)),
    #("transition_item", transition_item),
  ])
}

@target(javascript)
/// Bubbling, at the first match.
@external(javascript, "./test_support.ffi.mjs", "fireAnimationEnd")
pub fn fire_animation_end(_selector: String) -> Nil

@target(javascript)
/// Bubbling, with `detail.value`.
@external(javascript, "./test_support.ffi.mjs", "fireCustomEvent")
pub fn fire_custom_event(
  _selector: String,
  _event_name: String,
  _value: String,
) -> Nil

@target(javascript)
/// Plain event at the first match.
@external(javascript, "./test_support.ffi.mjs", "fireEvent")
pub fn fire_event(_selector: String, _event_name: String, _bubbles: Bool) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "focus")
pub fn focus(_selector: String) -> Nil

@external(erlang, "lily_test_support_ffi", "get_ref")
@external(javascript, "./test_support.ffi.mjs", "getRef")
pub fn get(cell: Ref(value)) -> value

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getAttribute")
pub fn get_attribute(_selector: String, _name: String) -> String

@target(javascript)
/// `False` when absent.
@external(javascript, "./test_support.ffi.mjs", "getChecked")
pub fn get_checked(_selector: String) -> Bool

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getLastEventSource")
pub fn get_last_event_source() -> Dynamic

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getLastWebSocket")
pub fn get_last_websocket() -> Dynamic

@external(erlang, "lily_test_support_ffi", "get_shared")
@external(javascript, "./test_support.ffi.mjs", "getRef")
pub fn get_shared(cell: Shared(value)) -> value

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getText")
pub fn get_text(_selector: String) -> String

@target(javascript)
/// Empty when absent.
@external(javascript, "./test_support.ffi.mjs", "getValue")
pub fn get_value(_selector: String) -> String

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "historyLength")
pub fn history_length() -> Int

pub fn initial_model() -> Model {
  Model(
    count: 0,
    name: "",
    connected: False,
    active_tab: TabA,
    secondary_count: 0,
    transition_item: None,
  )
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "injectSnapshotScript")
pub fn inject_snapshot_script(_base64: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "getInnerHtml")
pub fn inner_html(_selector: String) -> String

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchInputEvent")
pub fn input_event(_selector: String, _value: String) -> Nil

/// Fails when not running. Doubles as a round trip barrier.
pub fn inspect(app: server.Server(Model, Message)) -> server.Inspection {
  let assert Ok(inspection) = server.inspect(app)
  inspection
}

/// A whole-frame JSON codec built on `transport.serialiser`.
pub fn json_envelope(
  encode_message encode_message: fn(message) -> Json,
  message_decoder message_decoder: Decoder(message),
  encode_model encode_model: fn(model) -> Json,
  model_decoder model_decoder: Decoder(model),
) -> Serialiser(model, message) {
  transport.serialiser(
    encode: fn(frame) {
      frame
      |> frame_json(encode_message, encode_model)
      |> json.to_string
      |> bit_array.from_string
    },
    decode: fn(bytes) {
      use text <- result.try(bit_array.to_string(bytes))
      json.parse(text, frame_decoder(message_decoder, model_decoder))
      |> result.replace_error(Nil)
    },
  )
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchKeyDetail")
pub fn key_detail(
  _selector: String,
  _key: String,
  _code: String,
  _repeat: Bool,
  _composing: Bool,
) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchKeyEvent")
pub fn key_event(_selector: String, _event_name: String, _key: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "keyEventPrevented")
pub fn key_event_prevented(
  _selector: String,
  _event_name: String,
  _key: String,
  _ctrl: Bool,
  _meta: Bool,
) -> Bool

pub fn local_store() -> store.Store(Model, Message, store.Synced) {
  store.new(init: initial_model(), update: update)
  |> store.sync_with(
    route: fn(_) { store.Local },
    serialiser: custom_serialiser(),
  )
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchMedia")
pub fn media_event(
  _selector: String,
  _event_name: String,
  _current_time: Float,
) -> Nil

pub fn message_decoder() -> Decoder(Message) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Increment" -> decode.success(Increment)
    "Decrement" -> decode.success(Decrement)
    "SetName" -> {
      use name <- decode.field("name", decode.string)
      decode.success(SetName(name))
    }
    "Reset" -> decode.success(Reset)
    "Noop" -> decode.success(Noop)
    "SetTab" -> {
      use tab <- decode.field("tab", decode.string)
      decode.success(SetTab(tab_from_string(tab)))
    }
    "IncrementSecondary" -> decode.success(IncrementSecondary)
    "AddTransitionItem" -> {
      use id <- decode.field("id", decode.int)
      decode.success(AddTransitionItem(id))
    }
    "RemoveTransitionItem" -> {
      use id <- decode.field("id", decode.int)
      decode.success(RemoveTransitionItem(id))
    }
    "Claim" -> {
      use who <- decode.field("who", decode.string)
      decode.success(Claim(who))
    }
    _ -> decode.failure(Noop, "Message")
  }
}

pub fn message_pack_serialiser() -> Serialiser(model, message) {
  transport.automatic(
    format: transport.MessagePack,
    max_decode_depth: 128,
    modules: [],
  )
}

pub fn model_decoder() -> Decoder(Model) {
  use count <- decode.field("count", decode.int)
  use name <- decode.field("name", decode.string)
  use connected <- decode.field("connected", decode.bool)
  use active_tab <- decode.field("active_tab", decode.string)
  use secondary_count <- decode.field("secondary_count", decode.int)
  use transition_item <- decode.field(
    "transition_item",
    decode.optional(decode.int),
  )
  decode.success(Model(
    count:,
    name:,
    connected:,
    active_tab: tab_from_string(active_tab),
    secondary_count:,
    transition_item:,
  ))
}

@target(javascript)
/// Static component, its wrapper scopes listeners without a selector.
pub fn mount_html(
  runtime: client.Runtime(Model, Message, mode),
  html: String,
  attach: fn(component.Component(Model, Message, String)) ->
    component.Component(Model, Message, String),
) -> Nil {
  let _ =
    component.mount(
      runtime,
      selector: "#app",
      to_html: to_html,
      to_placeholder: to_placeholder,
      view: fn(_model) { attach(component.static(fn(_nest) { html })) },
    )
  Nil
}

@target(javascript)
/// Reloads and assigns jsdom was asked for.
@external(javascript, "./test_support.ffi.mjs", "navigationCount")
pub fn navigation_count() -> Int

@external(erlang, "lily_test_support_ffi", "new_ref")
@external(javascript, "./test_support.ffi.mjs", "newRef")
pub fn new(value: value) -> Ref(value)

@target(javascript)
pub fn new_runtime() -> client.Runtime(Model, Message, store.Synced) {
  client.start(local_store())
}

pub fn new_server() -> server.Server(Model, Message) {
  new_server_with_origins(server.AnyOrigin)
}

pub fn new_server_with_origins(
  origins: server.Origins,
) -> server.Server(Model, Message) {
  start_server(server.new(session_store(), origins: origins))
}

@external(erlang, "lily_test_support_ffi", "new_shared")
@external(javascript, "./test_support.ffi.mjs", "newRef")
pub fn new_shared(value: value) -> Shared(value)

@target(javascript)
pub fn new_synced_runtime() -> client.Runtime(Model, Message, store.Synced) {
  client.start(session_store())
}

pub fn new_topic_server() -> server.Server(Model, Message) {
  start_server(topic_builder())
}

/// `chat` and `room:` both use `access`.
pub fn new_topic_server_with_access(
  access: store.Access(Model),
) -> server.Server(Model, Message) {
  start_server(server.new(
    topic_store_with([#("chat", access), #("room:", access)]),
    origins: server.AnyOrigin,
  ))
}

@target(javascript)
/// Tags of the connected elements a stubbed `kind` observer watches.
@external(javascript, "./test_support.ffi.mjs", "observedTags")
pub fn observed_tags(_kind: String) -> List(String)

@target(javascript)
/// Open before `connect` returns, drops everything sent.
pub fn opened_connector() -> transport.Connector {
  transport.connector(fn(handler) {
    handler.opened()
    transport.Channel(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
  })
}

@target(javascript)
/// Window and document listeners for `name` added and not removed.
@external(javascript, "./test_support.ffi.mjs", "pageListenerCount")
pub fn page_listener_count(_name: String) -> Int

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchPointerDetail")
pub fn pointer_detail(
  _selector: String,
  _event_name: String,
  _button: Int,
  _pointer_type: String,
) -> Bool

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "popstateTo")
pub fn popstate_to(_path: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "readLocalStorage")
pub fn read_local_storage(_key: String) -> String

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "readSessionStorage")
pub fn read_session_storage(_key: String) -> String

/// JS decoder class registry, no-op on Erlang.
@external(erlang, "lily_test_support_ffi", "register_fixtures")
@external(javascript, "./fixtures.ffi.mjs", "registerFixtures")
pub fn register_fixtures() -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetDom")
pub fn reset_dom() -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetHotReloadInstalled")
pub fn reset_hot_reload_installed() -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetMocks")
pub fn reset_mocks() -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resetUrl")
pub fn reset_url() -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "resizeWindow")
pub fn resize_window(_width: Int, _height: Int) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "restoreChildren")
pub fn restore_children(_selector: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "scrollTo")
pub fn scroll_to(_selector: String, _top: Int, _left: Int) -> Nil

pub fn session_builder() -> server.Builder(Model, Message) {
  server.new(session_store(), origins: server.AnyOrigin)
}

pub fn session_store() -> store.Store(Model, Message, store.Synced) {
  store.new(init: initial_model(), update: update)
  |> store.sync_with(
    route: fn(_) { store.Session },
    serialiser: custom_serialiser(),
  )
  |> store.session(get: fn(model) { model }, set: fn(_, model) { model })
}

@external(erlang, "lily_test_support_ffi", "set_ref")
@external(javascript, "./test_support.ffi.mjs", "setRef")
pub fn set(cell: Ref(value), value: value) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setFiles")
pub fn set_files(_selector: String, _names: List(String)) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setInnerHtml")
pub fn set_inner_html(_selector: String, _html: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setOnline")
pub fn set_online(_online: Bool) -> Nil

@external(erlang, "lily_test_support_ffi", "set_shared")
@external(javascript, "./test_support.ffi.mjs", "setRef")
pub fn set_shared(cell: Shared(value), value: value) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "setVisibility")
pub fn set_visibility(_visible: Bool) -> Nil

pub fn start_server(
  builder: server.Builder(Model, Message),
) -> server.Server(Model, Message) {
  let assert Ok(app) = server.start(builder)
  app
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "stashChildren")
pub fn stash_children(_selector: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "stubAnimations")
pub fn stub_animations(_class_name: String, _milliseconds: Int) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "stubObservers")
pub fn stub_observers() -> Nil

@target(javascript)
/// Whether a handler prevented the default.
@external(javascript, "./test_support.ffi.mjs", "dispatchSubmit")
pub fn submit_event(_selector: String) -> Bool

/// -1 when not running. Asks the topic, also waiting for it to catch up.
pub fn subscriber_count(
  app: server.Server(Model, Message),
  topic_id: String,
) -> Int {
  case server.inspect(app) {
    Error(Nil) -> -1
    Ok(inspection) ->
      case dict.get(inspection.topics, topic_id) {
        Error(Nil) -> -1
        // topic may have died since the server answered
        Ok(topic) ->
          actor.rescue(topic.subscriber_count)
          |> result.unwrap(-1)
      }
  }
}

pub fn to_html(html: String) -> String {
  html
}

@target(javascript)
pub fn to_placeholder() -> String {
  "<lily-nest></lily-nest>"
}

pub fn topic_builder() -> server.Builder(Model, Message) {
  server.new(topic_store(), origins: server.AnyOrigin)
}

/// Counters and claims to `chat`, `SetName(id)` to `id`, `IncrementSecondary`
/// and `Noop` to the session, the rest local.
pub fn topic_route(message: Message) -> store.Route {
  case message {
    Increment | Decrement | Claim(_) -> store.Topic("chat")
    SetName(id) -> store.Topic(id)
    IncrementSecondary | Noop -> store.Session
    Reset | SetTab(_) | AddTransitionItem(_) | RemoveTransitionItem(_) ->
      store.Local
  }
}

/// `chat` and `room:`, both open.
pub fn topic_store() -> store.Store(Model, Message, store.Synced) {
  topic_store_with([#("chat", store.Open), #("room:", store.Open)])
}

/// Each topic with its access rule, every slice the whole model. An id ending
/// in ':' declares a family with `store.topics`, anything else an exact id.
pub fn topic_store_with(
  topics: List(#(String, store.Access(Model))),
) -> store.Store(Model, Message, store.Synced) {
  store.new(init: initial_model(), update: update)
  |> store.sync_with(route: topic_route, serialiser: custom_serialiser())
  |> declare_topics(topics)
}

pub fn topic_watched(
  app: server.Server(Model, Message),
  topic_id: String,
) -> Option(actor.Watched) {
  dict.get(inspect(app).topics, topic_id)
  |> result.map(fn(topic) { topic.watched })
  |> option.from_result
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchTransfer")
pub fn transfer_event(
  _selector: String,
  _event_name: String,
  _text: String,
) -> Bool

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerEventSourceError")
pub fn trigger_event_source_error(_event_source: Dynamic) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerEventSourceOpen")
pub fn trigger_event_source_open(_event_source: Dynamic) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerResize")
pub fn trigger_resize(_width: Float, _height: Float) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerVisible")
pub fn trigger_visible(_visible: Bool) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerWebSocketClose")
pub fn trigger_websocket_close(_websocket: Dynamic) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerWebSocketMessage")
pub fn trigger_websocket_message(_websocket: Dynamic, _data: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "triggerWebSocketOpen")
pub fn trigger_websocket_open(_websocket: Dynamic) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "unstubAnimations")
pub fn unstub_animations() -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "unstubObservers")
pub fn unstub_observers() -> Nil

pub fn update(model: Model, message: Message) -> Model {
  case message {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
    SetName(name) -> Model(..model, name: name)
    Reset -> initial_model()
    Noop -> model
    SetTab(tab) -> Model(..model, active_tab: tab)
    IncrementSecondary ->
      Model(..model, secondary_count: model.secondary_count + 1)
    AddTransitionItem(id) -> Model(..model, transition_item: Some(id))
    RemoveTransitionItem(id) ->
      case model.transition_item {
        Some(current) if current == id -> Model(..model, transition_item: None)
        Some(_) | None -> model
      }
    Claim(who) ->
      case model.name {
        "" -> Model(..model, name: who)
        _ -> model
      }
  }
}

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "websocketUrl")
pub fn websocket_url(_websocket: Dynamic) -> String

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "dispatchWheel")
pub fn wheel_event(_selector: String, _delta_y: Float, _delta_mode: Int) -> Bool

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "writeLocalStorage")
pub fn write_local_storage(_key: String, _value: String) -> Nil

@target(javascript)
@external(javascript, "./test_support.ffi.mjs", "writeSessionStorage")
pub fn write_session_storage(_key: String, _value: String) -> Nil

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn cursor_decoder() -> Decoder(transport.Cursor) {
  use target <- decode.field("target", target_decoder())
  let number = decode.map(decode.int, option.Some)
  use epoch <- decode.optional_field("epoch", option.None, number)
  use sequence <- decode.optional_field("sequence", option.None, number)
  case epoch, sequence {
    option.Some(epoch), option.Some(sequence) ->
      decode.success(transport.Known(target:, epoch:, sequence:))
    _, _ -> decode.success(transport.Unknown(target:))
  }
}

fn cursor_json(cursor: transport.Cursor) -> Json {
  case cursor {
    transport.Unknown(target:) ->
      json.object([#("target", target_json(target))])
    transport.Known(target:, epoch:, sequence:) ->
      json.object([
        #("target", target_json(target)),
        #("epoch", json.int(epoch)),
        #("sequence", json.int(sequence)),
      ])
  }
}

// session and every topic hold the whole model
fn declare_topics(
  base: store.Store(Model, Message, store.Synced),
  topics: List(#(String, store.Access(Model))),
) -> store.Store(Model, Message, store.Synced) {
  let base =
    store.session(base, get: fn(model) { model }, set: fn(_, model) { model })
  list.fold(topics, base, fn(app_store, topic) {
    case string.ends_with(topic.0, ":") {
      True ->
        store.topics(
          app_store,
          prefix: topic.0,
          get: fn(model, _rest) { model },
          set: fn(_, _rest, model) { model },
          access: topic.1,
        )
      False ->
        store.topic(
          app_store,
          id: topic.0,
          get: fn(model) { model },
          set: fn(_, model) { model },
          access: topic.1,
        )
    }
  })
}

fn frame_decoder(
  message_decoder: Decoder(message),
  model_decoder: Decoder(model),
) -> Decoder(transport.Protocol(model, message)) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "acknowledge" -> {
      use target <- decode.field("target", target_decoder())
      use sequence <- decode.field("sequence", decode.int)
      decode.success(transport.Acknowledge(target:, sequence:))
    }
    "connected" -> {
      use client_id <- decode.field("client_id", decode.string)
      decode.success(transport.Connected(client_id:))
    }
    "dropped" -> {
      use target <- decode.field("target", target_decoder())
      decode.success(transport.Dropped(target:))
    }
    "rejected" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      use reason <- decode.field("reason", reason_decoder())
      decode.success(transport.Rejected(topic_id:, reason:))
    }
    "resync" -> {
      use cursors <- decode.field("cursors", decode.list(cursor_decoder()))
      decode.success(transport.Resync(cursors:))
    }
    "session_message" -> {
      use payload <- decode.field("payload", message_decoder)
      decode.success(transport.SessionMessage(payload:))
    }
    "session_update" -> {
      use sequence <- decode.field("sequence", decode.int)
      use payload <- decode.field("payload", message_decoder)
      decode.success(transport.SessionUpdate(sequence:, payload:))
    }
    "snapshot" -> {
      use target <- decode.field("target", target_decoder())
      use epoch <- decode.field("epoch", decode.int)
      use sequence <- decode.field("sequence", decode.int)
      use state <- decode.field("state", model_decoder)
      decode.success(transport.Snapshot(target:, epoch:, sequence:, state:))
    }
    "subscribe" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      decode.success(transport.Subscribe(topic_id:))
    }
    "topic_message" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      use payload <- decode.field("payload", message_decoder)
      decode.success(transport.TopicMessage(topic_id:, payload:))
    }
    "topic_update" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      use sequence <- decode.field("sequence", decode.int)
      use payload <- decode.field("payload", message_decoder)
      decode.success(transport.TopicUpdate(topic_id:, sequence:, payload:))
    }
    "unchanged" -> {
      use target <- decode.field("target", target_decoder())
      decode.success(transport.Unchanged(target:))
    }
    "unsubscribe" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      decode.success(transport.Unsubscribe(topic_id:))
    }
    "version" -> {
      use hash <- decode.field("hash", decode.string)
      use protocol <- decode.field("protocol", decode.int)
      decode.success(transport.Version(hash:, protocol:))
    }
    _ -> decode.failure(transport.Version("", 0), "Protocol")
  }
}

fn frame_json(
  frame: transport.Protocol(model, message),
  encode_message: fn(message) -> Json,
  encode_model: fn(model) -> Json,
) -> Json {
  case frame {
    transport.Acknowledge(target:, sequence:) ->
      tagged("acknowledge", [
        #("target", target_json(target)),
        #("sequence", json.int(sequence)),
      ])
    transport.Connected(client_id:) ->
      tagged("connected", [#("client_id", json.string(client_id))])
    transport.Dropped(target:) ->
      tagged("dropped", [#("target", target_json(target))])
    transport.Rejected(topic_id:, reason:) ->
      tagged("rejected", [
        #("topic_id", json.string(topic_id)),
        #("reason", reason_json(reason)),
      ])
    transport.Resync(cursors:) ->
      tagged("resync", [#("cursors", json.array(cursors, cursor_json))])
    transport.SessionMessage(payload:) ->
      tagged("session_message", [#("payload", encode_message(payload))])
    transport.SessionUpdate(sequence:, payload:) ->
      tagged("session_update", [
        #("sequence", json.int(sequence)),
        #("payload", encode_message(payload)),
      ])
    transport.Snapshot(target:, epoch:, sequence:, state:) ->
      tagged("snapshot", [
        #("target", target_json(target)),
        #("epoch", json.int(epoch)),
        #("sequence", json.int(sequence)),
        #("state", encode_model(state)),
      ])
    transport.Subscribe(topic_id:) ->
      tagged("subscribe", [#("topic_id", json.string(topic_id))])
    transport.TopicMessage(topic_id:, payload:) ->
      tagged("topic_message", [
        #("topic_id", json.string(topic_id)),
        #("payload", encode_message(payload)),
      ])
    transport.TopicUpdate(topic_id:, sequence:, payload:) ->
      tagged("topic_update", [
        #("topic_id", json.string(topic_id)),
        #("sequence", json.int(sequence)),
        #("payload", encode_message(payload)),
      ])
    transport.Unchanged(target:) ->
      tagged("unchanged", [#("target", target_json(target))])
    transport.Unsubscribe(topic_id:) ->
      tagged("unsubscribe", [#("topic_id", json.string(topic_id))])
    transport.Version(hash:, protocol:) ->
      tagged("version", [
        #("hash", json.string(hash)),
        #("protocol", json.int(protocol)),
      ])
  }
}

fn reason_decoder() -> Decoder(transport.RejectionReason) {
  use reason <- decode.then(decode.string)
  case reason {
    "denied" -> decode.success(transport.AccessDenied)
    "limit" -> decode.success(transport.OverLimit)
    "not found" -> decode.success(transport.NotFound)
    _ -> decode.failure(transport.NotFound, "RejectionReason")
  }
}

fn reason_json(reason: transport.RejectionReason) -> Json {
  json.string(case reason {
    transport.AccessDenied -> "denied"
    transport.NotFound -> "not found"
    transport.OverLimit -> "limit"
  })
}

fn tab_from_string(name: String) -> Tab {
  case name {
    "TabB" -> TabB
    _ -> TabA
  }
}

fn tab_to_string(tab: Tab) -> String {
  case tab {
    TabA -> "TabA"
    TabB -> "TabB"
  }
}

fn tagged(kind: String, fields: List(#(String, Json))) -> Json {
  json.object([#("type", json.string(kind)), ..fields])
}

fn target_decoder() -> Decoder(transport.SyncTarget) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "session" -> decode.success(transport.Session)
    "topic" -> {
      use id <- decode.field("id", decode.string)
      decode.success(transport.Topic(id:))
    }
    _ -> decode.failure(transport.Session, "SyncTarget")
  }
}

fn target_json(target: transport.SyncTarget) -> Json {
  case target {
    transport.Session -> json.object([#("kind", json.string("session"))])
    transport.Topic(id:) ->
      json.object([
        #("kind", json.string("topic")),
        #("id", json.string(id)),
      ])
  }
}
