//// The [`Store`](#Store) holds your application state and update logic,
//// shared across client and server. The mental model is very simple, each
//// store holds a basic model type and an update function
//// `fn(model, message) -> model`. The store is agnostic to how your frontend
//// actually displays these components, with the view function or rendering
//// completely detached (unlike Lustre and closer to Redux).
////
//// Here's a minimal example of a counter:
////
//// ```gleam
//// pub type Model {
////   Model(count: Int)
//// }
////
//// pub type Message {
////   Increment
////   Decrement
//// }
////
//// pub fn update(model: Model, message: Message) -> Model {
////   case message {
////     Increment -> Model(count: model.count + 1)
////     Decrement -> Model(count: model.count - 1)
////   }
//// }
////
//// // this should be in your client/frontend code
//// let store = store.new(Model(count: 0), with: update)
//// ```
////
//// You wrap it with `store.new` on the client and pipe the result into
//// [`client.start`](./client.html#start).
////
//// The server is then set up separately via [`server.new`](./server.html#new),
//// where [`Wiring`](#Wiring) comes into play. Syncing your model with the
//// server splits your model into a per-connection `session` slice and then
//// shared `topic` slices (see the [topic](./topic.html) module for more info).
//// For each message, the wiring allows us to figure out which message belongs
//// where (through `extract`), how the slice should update (`update`), and how
//// to read and write the slice on the outer model (`field_get`/`field_set`).
//// It also merges server snapshots back into the right slice.
////
//// Build one `Wiring` in your `shared` package and hand the same value to
//// both the client (passed to [`client.start`](./client.html#start)) and the
//// server (passed to [`server.new`](./server.html#new)):
////
//// ```gleam
//// import lily/store
////
//// pub fn wiring() -> store.Wiring(Model, Message) {
////   store.wiring()
////   |> store.session(
////     extract: fn(message) {
////       case message {
////         Session(inner) -> Ok(inner)
////         _ -> Error(Nil)
////       }
////     },
////     update: session_update,
////     field_get: fn(model: Model) { model.session },
////     field_set: fn(model, session) { Model(..model, session:) },
////   )
////   |> store.topic(
////     id: "chat",
////     extract: fn(message) {
////       case message {
////         Chat(inner) -> Ok(inner)
////         _ -> Error(Nil)
////       }
////     },
////     update: chat_update,
////     field_get: fn(model: Model) { model.chat },
////     field_set: fn(model, chat) { Model(..model, chat:) },
////   )
////   // you can chain more topics by determining a different topic id
//// }
//// ```
////
//// Model fields that should not be synced to the server can be wrapped in
//// [`Local`](#Local). The server holds `Local` fields at their initial values
//// and the client runtime preserves them when the server sends a snapshot on
//// reconnect. Pair with
//// [`client.session_field`](./client.html#session_field) to persist them
//// across page navigations.
////
//// The same store runs on the client via
//// [`client.start`](./client.html#start) and the server via
//// [`server.start`](./server.html#start), meaning your `update` function
//// works identically on both sides.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import lily/transport.{type Target}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Wrap client-only model fields that shouldn't sync to the server. The server
/// holds them at their initial values and the client preserves them when
/// applying a snapshot on reconnect.
///
/// A single-variant type, so pattern matching gets the value back out.
///
/// ```gleam
/// pub type Model {
///   Model(count: Int, theme: store.Local(String))
/// }
///
/// let store.Local(theme) = model.theme
/// ```
pub type Local(a) {
  Local(a)
}

/// Your application state and update logic. Runs on both the client
/// ([`client.start`](./client.html#start)) and the server
/// ([`server.start`](./server.html#start)). Construct via [`new`](#new),
/// fields are opaque so the layout can evolve.
pub opaque type Store(model, message) {
  Store(model: model, update: fn(model, message) -> model)
}

/// Wiring configuration for multi-store Lily apps. Tells the client how to
/// dispatch messages to the session or a topic store, and how to merge incoming
/// snapshots back into the outer model. Build with [`wiring`](#wiring), then
/// pipe through [`session`](#session) and [`topic`](#topic).
pub opaque type Wiring(model, message) {
  Wiring(
    session: Option(TargetConfig(model, message)),
    topics: List(#(String, TargetConfig(model, message))),
    kinds: List(KindConfig(model, message)),
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create a store, seeded with an `initial_model` (like Lustre's `init`) and
/// an update function that transforms the model for a given `message`.
///
/// ```gleam
/// let app_store =
///   Model(count: 0, user: "Guest")
///   |> store.new(with: update)
/// ```
pub fn new(
  initial_model model: model,
  with update: fn(model, message) -> model,
) -> Store(model, message) {
  Store(model: model, update: update)
}

/// Register the session store entry in the wiring. `extract` identifies session
/// messages, `update` applies them to the session sub-model, `field_get`/
/// `field_set` map between the outer model and the session sub-model.
///
/// ```gleam
/// store.wiring()
/// |> store.session(
///   extract: fn(message) {
///     case message {
///       Session(inner) -> Ok(inner)
///       _ -> Error(Nil)
///     }
///   },
///   update: session_update,
///   field_get: fn(model: Model) { model.session },
///   field_set: fn(model, session) { Model(..model, session:) },
/// )
/// ```
pub fn session(
  wiring: Wiring(model, message),
  extract extract: fn(message) -> Result(session_message, Nil),
  update update: fn(session_model, session_message) -> session_model,
  field_get field_get: fn(model) -> session_model,
  field_set field_set: fn(model, session_model) -> model,
) -> Wiring(model, message) {
  let config = make_target_config(extract, update, field_get, field_set)
  Wiring(..wiring, session: option.Some(config))
}

/// Register a topic store entry in the wiring. `id` is the topic identifier
/// used in `client.subscribe`, other parameters match [`session`](#session).
///
/// ```gleam
/// store.wiring()
/// |> store.topic(
///   id: "chat",
///   extract: fn(message) {
///     case message {
///       Chat(inner) -> Ok(inner)
///       _ -> Error(Nil)
///     }
///   },
///   update: chat_update,
///   field_get: fn(model: Model) { model.chat },
///   field_set: fn(model, chat) { Model(..model, chat:) },
/// )
/// ```
pub fn topic(
  wiring: Wiring(model, message),
  id id: String,
  extract extract: fn(message) -> Result(topic_message, Nil),
  update update: fn(topic_model, topic_message) -> topic_model,
  field_get field_get: fn(model) -> topic_model,
  field_set field_set: fn(model, topic_model) -> model,
) -> Wiring(model, message) {
  let config = make_target_config(extract, update, field_get, field_set)
  Wiring(..wiring, topics: list.key_set(wiring.topics, id, config))
}

/// Register a parametric topic family in the wiring. Where [`topic`](#topic)
/// binds one id to one slice, `topic_kind` binds a family of dynamic ids
/// sharing `prefix` (`"room:1"`, `"room:2"`, ...) to a keyed slice, so a client
/// can subscribe to many instances at once.
///
/// `extract` returns the instance key plus the sub-message, and the wire id is
/// `prefix <> key`. `field_get`/`field_set` read and write one instance's
/// sub-model by key, so back them with a keyed collection like
/// `Dict(String, _)`. This one entry routes outgoing messages, incoming
/// updates, and snapshot merges to the right key.
///
/// ```gleam
/// store.wiring()
/// |> store.topic_kind(
///   prefix: "room:",
///   extract: fn(message) {
///     case message {
///       Room(id, inner) -> Ok(#(int.to_string(id), inner))
///       _ -> Error(Nil)
///     }
///   },
///   update: room_update,
///   field_get: fn(model: Model, key) {
///     dict.get(model.rooms, key) |> result.unwrap(new_room())
///   },
///   field_set: fn(model, key, room) {
///     Model(..model, rooms: dict.insert(model.rooms, key, room))
///   },
/// )
/// ```
pub fn topic_kind(
  wiring: Wiring(model, message),
  prefix prefix: String,
  extract extract: fn(message) -> Result(#(String, kind_message), Nil),
  update update: fn(kind_model, kind_message) -> kind_model,
  field_get field_get: fn(model, String) -> kind_model,
  field_set field_set: fn(model, String, kind_model) -> model,
) -> Wiring(model, message) {
  let config = make_kind_config(prefix, extract, update, field_get, field_set)
  Wiring(..wiring, kinds: [config, ..wiring.kinds])
}

/// Create an empty wiring. Pipe through [`session`](#session),
/// [`topic`](#topic), and [`topic_kind`](#topic_kind) to register stores, then
/// pass to [`client.start`](./client.html#start) and
/// [`server.new`](./server.html#new).
///
/// ```gleam
/// store.wiring()
/// |> store.session(extract:, update:, field_get:, field_set:)
/// |> store.topic(id: "chat", extract:, update:, field_get:, field_set:)
/// ```
pub fn wiring() -> Wiring(model, message) {
  Wiring(session: option.None, topics: [], kinds: [])
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Apply a message to the store, returning the updated store. Used for batch
/// rendering, several messages apply before one render frame so rapid bursts
/// coalesce into a single DOM update.
@internal
pub fn apply(
  store: Store(model, message),
  message message: message,
) -> Store(model, message) {
  let new_model = store.update(store.model, message)
  Store(..store, model: new_model)
}

/// Apply a message to the outer model using the appropriate wiring entry.
/// A no-op if no matching target is found.
@internal
pub fn apply_message(
  wiring: Wiring(model, message),
  model: model,
  message: message,
) -> model {
  on_session_else_topic(
    wiring,
    message,
    fn(config) { config.apply(model, message) },
    fn() { apply_to_topics(wiring, model, message) },
  )
}

/// Read the current model out of a [`Store`](#Store). Used by sibling modules
/// and tests that inspect the store's contents.
@internal
pub fn get_model(store: Store(model, message)) -> model {
  store.model
}

/// Merge a snapshot into the current outer model by replacing only the slice
/// belonging to `target` and leaving all other slices intact.
@internal
pub fn merge_snapshot(
  wiring: Wiring(model, message),
  target: Target,
  current: model,
  snapshot_state: model,
) -> model {
  case target {
    transport.Session ->
      case wiring.session {
        option.Some(c) -> c.merge_snapshot(current, snapshot_state)
        option.None -> current
      }
    transport.Topic(id) ->
      case list.key_find(wiring.topics, id) {
        Ok(c) -> c.merge_snapshot(current, snapshot_state)
        Error(_) ->
          case matching_kind(wiring, id) {
            option.Some(kind) -> {
              let key = string.drop_start(id, string.length(kind.prefix))
              kind.merge_snapshot(current, key, snapshot_state)
            }
            option.None -> current
          }
      }
  }
}

/// Determine which target a message routes to. Returns `Session` when no topic
/// extract accepts it, the safe fallback for unrecognised messages. Session
/// wins if both a session and a topic extract accept the same message, so
/// topic `extract` functions must be mutually exclusive.
@internal
pub fn route_message(
  wiring: Wiring(model, message),
  message: message,
) -> Target {
  on_session_else_topic(
    wiring,
    message,
    fn(_config) { transport.Session },
    fn() { topic_target(wiring, message) },
  )
}

/// The apply-message function for the session store entry, if any. Used by
/// `server.gleam` to build the session-message handler at start time.
@internal
pub fn session_apply(
  wiring: Wiring(model, message),
) -> Option(fn(model, message) -> model) {
  option.map(wiring.session, fn(config) { config.apply })
}

/// The apply-message function for a named topic entry, if any. Used by
/// `topic.gleam` to build the topic-store handler in `with_store`.
@internal
pub fn topic_apply(
  wiring: Wiring(model, message),
  id: String,
) -> Option(fn(model, message) -> model) {
  case list.key_find(wiring.topics, id) {
    Ok(config) -> option.Some(config.apply)
    Error(_) -> matching_kind(wiring, id) |> option.map(fn(kind) { kind.apply })
  }
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

/// Config for a parametric topic family (see [`topic_kind`](#topic_kind)).
/// Unlike `TargetConfig`, apply and merge are keyed by an instance id from the
/// message (`topic_id_of`) or the target id (`merge_snapshot` takes the key),
/// so one config serves every instance sharing `prefix`.
type KindConfig(model, message) {
  KindConfig(
    prefix: String,
    is_for_target: fn(message) -> Bool,
    topic_id_of: fn(message) -> Result(String, Nil),
    apply: fn(model, message) -> model,
    merge_snapshot: fn(model, String, model) -> model,
  )
}

/// Outcome of routing a non-session message, either a fixed topic entry, a
/// parametric kind, or nothing. Shared by `apply_to_topics` and `topic_target`
/// via `match_topic_route`.
type RouteMatch(model, message) {
  MatchedTopic(id: String, config: TargetConfig(model, message))
  MatchedKind(config: KindConfig(model, message))
  MatchedNone
}

type TargetConfig(model, message) {
  TargetConfig(
    is_for_target: fn(message) -> Bool,
    apply: fn(model, message) -> model,
    merge_snapshot: fn(model, model) -> model,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn apply_to_topics(
  wiring: Wiring(model, message),
  model: model,
  message: message,
) -> model {
  case match_topic_route(wiring, message) {
    MatchedTopic(_id, config) -> config.apply(model, message)
    MatchedKind(kind) -> kind.apply(model, message)
    MatchedNone -> model
  }
}

/// Find the exact topic entry whose extract accepts this message. Extracts are
/// mutually exclusive (per the `route_message` contract), so the first match
/// wins.
fn find_topic_entry(
  wiring: Wiring(model, message),
  message: message,
) -> Result(#(String, TargetConfig(model, message)), Nil) {
  list.find(wiring.topics, fn(pair) { { pair.1 }.is_for_target(message) })
}

fn make_kind_config(
  prefix: String,
  extract: fn(message) -> Result(#(String, kind_message), Nil),
  update: fn(kind_model, kind_message) -> kind_model,
  field_get: fn(model, String) -> kind_model,
  field_set: fn(model, String, kind_model) -> model,
) -> KindConfig(model, message) {
  KindConfig(
    prefix: prefix,
    is_for_target: fn(message) { result.is_ok(extract(message)) },
    topic_id_of: fn(message) {
      extract(message) |> result.map(fn(pair) { prefix <> pair.0 })
    },
    apply: fn(model, message) {
      case extract(message) {
        Ok(#(key, inner)) ->
          field_set(model, key, update(field_get(model, key), inner))
        Error(_) -> model
      }
    },
    merge_snapshot: fn(current, key, snapshot) {
      field_set(current, key, field_get(snapshot, key))
    },
  )
}

fn make_target_config(
  extract: fn(message) -> Result(sub_message, Nil),
  update: fn(sub_model, sub_message) -> sub_model,
  field_get: fn(model) -> sub_model,
  field_set: fn(model, sub_model) -> model,
) -> TargetConfig(model, message) {
  TargetConfig(
    is_for_target: fn(message) { result.is_ok(extract(message)) },
    apply: fn(model, message) {
      case extract(message) {
        Ok(inner) -> field_set(model, update(field_get(model), inner))
        Error(_) -> model
      }
    },
    merge_snapshot: fn(current, snapshot) {
      field_set(current, field_get(snapshot))
    },
  )
}

/// Route a non-session message to its topic target using the shared rule, the
/// exact topic entry first and then a parametric kind. Both `apply_to_topics`
/// and `topic_target` go through this so the routing lives in one place.
fn match_topic_route(
  wiring: Wiring(model, message),
  message: message,
) -> RouteMatch(model, message) {
  case find_topic_entry(wiring, message) {
    Ok(#(id, config)) -> MatchedTopic(id:, config:)
    Error(_) ->
      case list.find(wiring.kinds, fn(kind) { kind.is_for_target(message) }) {
        Ok(kind) -> MatchedKind(config: kind)
        Error(_) -> MatchedNone
      }
  }
}

/// Find the kind whose prefix matches `id`, longest prefix wins when several
/// match so the more specific family is chosen. A single fold keeps the best
/// match and its prefix length so neither the intermediate list nor the
/// incumbent's length are recomputed.
fn matching_kind(
  wiring: Wiring(model, message),
  id: String,
) -> Option(KindConfig(model, message)) {
  wiring.kinds
  |> list.fold(option.None, fn(best, kind) {
    case string.starts_with(id, kind.prefix) {
      False -> best
      True -> {
        let length = string.length(kind.prefix)
        case best {
          option.Some(#(_, best_length)) if best_length >= length -> best
          _ -> option.Some(#(kind, length))
        }
      }
    }
  })
  |> option.map(fn(pair) { pair.0 })
}

/// Run `on_session` with the session config when it exists and accepts the
/// message, otherwise fall back to `on_topic`. Shared by `apply_message` and
/// `route_message` so the session-first routing rule lives in one place.
fn on_session_else_topic(
  wiring: Wiring(model, message),
  message: message,
  on_session: fn(TargetConfig(model, message)) -> a,
  on_topic: fn() -> a,
) -> a {
  case wiring.session {
    option.Some(config) ->
      case config.is_for_target(message) {
        True -> on_session(config)
        False -> on_topic()
      }
    option.None -> on_topic()
  }
}

/// Route a non-session message: exact topic entry first, else a parametric kind
/// (concrete id `prefix <> key` from the message). Falls back to `Session` when
/// nothing matches, the safe default for unrecognised messages.
fn topic_target(wiring: Wiring(model, message), message: message) -> Target {
  case match_topic_route(wiring, message) {
    MatchedTopic(id, _) -> transport.Topic(id)
    MatchedKind(kind) ->
      case kind.topic_id_of(message) {
        Ok(id) -> transport.Topic(id)
        Error(_) -> transport.Session
      }
    MatchedNone -> transport.Session
  }
}
