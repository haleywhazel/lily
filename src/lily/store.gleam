//// The [`Store`](#Store) holds your application state and update logic,
//// shared across client and server. The [`Wiring`](#Wiring) tells the
//// runtime how to dispatch messages to the right store slice and how to
//// merge incoming snapshots from the server.
////
//// Build a `Wiring` in your `shared` package and import it in both the
//// client (passed to [`client.start`](./client.html#start)) and the server
//// (passed to [`server.new`](./server.html#new)):
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

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import lily/transport.{type Target}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Model fields that are client-only and not synced to the server should be
/// wrapped using `Local(_)`. The server holds `Local` fields at their initial
/// values and the client runtime preserves them when applying a server
/// snapshot on reconnect.
///
/// ```gleam
/// pub type Model {
///   Model(count: Int, theme: store.Local(String))
/// }
/// ```
pub type Local(a) {
  Local(a)
}

/// The store with your application state and update logic. The same store
/// runs on both the client (via [`client.start`](./client.html#start))
/// and the server (via [`server.start`](./server.html#start)). Construct via
/// [`new`](#new); fields are not exposed to keep the internal layout free
/// to evolve.
pub opaque type Store(model, message) {
  Store(model: model, update: fn(model, message) -> model)
}

/// Wiring configuration for multi-store Lily apps. A `Wiring(model, message)`
/// value tells the client how to dispatch messages to the session store or to
/// a topic store, and how to merge incoming snapshots back into the outer
/// model. Build with [`wiring`](#wiring), then pipe through
/// [`session`](#session) and [`topic`](#topic).
pub opaque type Wiring(model, message) {
  Wiring(
    session: Option(TargetConfig(model, message)),
    topics: Dict(String, TargetConfig(model, message)),
    kinds: List(KindConfig(model, message)),
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create a new store, seeded with an `initial_model` (similar to Lustre's
/// `init`) and an update function that transforms the model based on a given
/// `message`.
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

/// Register the session store entry in the wiring. The `extract` function
/// identifies session messages; `update` applies them to the session
/// sub-model; `field_get` and `field_set` map between the outer model and
/// the session sub-model.
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

/// Register a topic store entry in the wiring. The `id` is the topic
/// identifier used in `client.subscribe`; the other parameters are the same
/// as for [`session`](#session).
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
  Wiring(..wiring, topics: dict.insert(wiring.topics, id, config))
}

/// Register a parametric topic family in the wiring. Where [`topic`](#topic)
/// binds one id to one model slice, `topic_kind` binds a whole family of
/// dynamic ids sharing `prefix` (`"room:1"`, `"room:2"`, and so on) to a
/// keyed slice, so a client can be subscribed to many instances at once.
///
/// `extract` returns the instance key together with the sub-message; the full
/// topic id on the wire is `prefix <> key`. `field_get` and `field_set` read
/// and write one instance's sub-model by key, so back them with a keyed
/// collection such as `Dict(String, _)` on your model. This one entry is what
/// lets an outgoing message route to the right instance, an incoming update
/// apply to the right key, and a snapshot merge into the right key.
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

/// Unwrap a [`Local`](#Local) field to get the inner value.
pub fn unwrap_local(local: Local(a)) -> a {
  let Local(value) = local
  value
}

/// Create an empty wiring configuration. Pipe through [`session`](#session),
/// [`topic`](#topic), and [`topic_kind`](#topic_kind) to register stores.
/// Pass the result to [`client.start`](./client.html#start) and
/// [`server.new`](./server.html#new).
///
/// ```gleam
/// store.wiring()
/// |> store.session(extract:, update:, field_get:, field_set:)
/// |> store.topic(id: "chat", extract:, update:, field_get:, field_set:)
/// ```
pub fn wiring() -> Wiring(model, message) {
  Wiring(session: option.None, topics: dict.new(), kinds: [])
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Apply a message to the store, returning the updated store. Used
/// internally for batch rendering: multiple messages are applied before a
/// single render frame so rapid bursts of updates are combined into one
/// DOM update.
@internal
pub fn apply(
  store: Store(model, message),
  message message: message,
) -> Store(model, message) {
  let new_model = store.update(store.model, message)
  Store(..store, model: new_model)
}

/// Read the current model out of a [`Store`](#Store). Used by sibling Lily
/// modules and by tests that need to inspect the store's contents.
@internal
pub fn get_model(store: Store(model, message)) -> model {
  store.model
}

/// Apply a message to the outer model using the appropriate wiring entry.
/// A no-op if no matching target is found.
@internal
pub fn apply_message(
  wiring: Wiring(model, message),
  model: model,
  message: message,
) -> model {
  case wiring.session {
    option.Some(config) ->
      case config.is_for_target(message) {
        True -> config.apply(model, message)
        False -> apply_to_topics(wiring, model, message)
      }
    option.None -> apply_to_topics(wiring, model, message)
  }
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
      case dict.get(wiring.topics, id) {
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

/// Determine which target a message should be routed to. Returns `Session`
/// when no topic extract function accepts the message; this is the safe
/// fallback for unrecognised messages. Session wins if both the session
/// and a topic extract accept the same message; topic `extract` functions
/// must be mutually exclusive.
@internal
pub fn route_message(wiring: Wiring(model, message), message: message) -> Target {
  case wiring.session {
    option.Some(config) ->
      case config.is_for_target(message) {
        True -> transport.Session
        False -> topic_target(wiring, message)
      }
    option.None -> topic_target(wiring, message)
  }
}

/// Return the apply-message function for the session store entry, if any.
/// Used by `server.gleam` to build the session-message handler at start time.
@internal
pub fn session_apply(
  wiring: Wiring(model, message),
) -> Option(fn(model, message) -> model) {
  option.map(wiring.session, fn(config) { config.apply })
}

/// Return the apply-message function for a named topic entry, if any.
/// Used by `topic.gleam` to build the topic-store handler in `with_store`.
@internal
pub fn topic_apply(
  wiring: Wiring(model, message),
  id: String,
) -> Option(fn(model, message) -> model) {
  case dict.get(wiring.topics, id) {
    Ok(config) -> option.Some(config.apply)
    Error(_) -> matching_kind(wiring, id) |> option.map(fn(kind) { kind.apply })
  }
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

type TargetConfig(model, message) {
  TargetConfig(
    is_for_target: fn(message) -> Bool,
    apply: fn(model, message) -> model,
    merge_snapshot: fn(model, model) -> model,
  )
}

/// Config for a parametric topic family (see [`topic_kind`](#topic_kind)).
/// Unlike `TargetConfig`, the apply and merge are keyed by an instance id
/// derived from the message (`topic_id_of`) or the target id (`merge_snapshot`
/// takes the key), so one config serves every instance sharing `prefix`.
type KindConfig(model, message) {
  KindConfig(
    prefix: String,
    is_for_target: fn(message) -> Bool,
    topic_id_of: fn(message) -> Result(String, Nil),
    apply: fn(model, message) -> model,
    merge_snapshot: fn(model, String, model) -> model,
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
  // Topic extracts are mutually exclusive (per route_message contract), so
  // the first match wins. No need to fold the entire dict.
  case
    dict.to_list(wiring.topics)
    |> list.find(fn(pair) { { pair.1 }.is_for_target(message) })
  {
    Ok(#(_id, config)) -> config.apply(model, message)
    Error(_) ->
      case list.find(wiring.kinds, fn(kind) { kind.is_for_target(message) }) {
        Ok(kind) -> kind.apply(model, message)
        Error(_) -> model
      }
  }
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

/// Find the kind whose prefix matches `id`, choosing the longest prefix when
/// several match so a more specific family wins.
fn matching_kind(
  wiring: Wiring(model, message),
  id: String,
) -> Option(KindConfig(model, message)) {
  wiring.kinds
  |> list.filter(fn(kind) { string.starts_with(id, kind.prefix) })
  |> list.fold(option.None, fn(best: Option(KindConfig(model, message)), kind) {
    case best {
      option.None -> option.Some(kind)
      option.Some(current) ->
        case string.length(kind.prefix) > string.length(current.prefix) {
          True -> option.Some(kind)
          False -> best
        }
    }
  })
}

/// Route a non-session message: an exact topic entry first, otherwise a
/// parametric kind (whose concrete id is `prefix <> key` from the message).
/// Falls back to `Session` when nothing matches, the safe default for
/// unrecognised messages.
fn topic_target(wiring: Wiring(model, message), message: message) -> Target {
  case
    dict.to_list(wiring.topics)
    |> list.find(fn(pair) { { pair.1 }.is_for_target(message) })
  {
    Ok(#(id, _)) -> transport.Topic(id)
    Error(_) ->
      case list.find(wiring.kinds, fn(kind) { kind.is_for_target(message) }) {
        Ok(kind) ->
          case kind.topic_id_of(message) {
            Ok(id) -> transport.Topic(id)
            Error(_) -> transport.Session
          }
        Error(_) -> transport.Session
      }
  }
}
