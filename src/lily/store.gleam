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

/// Unwrap a [`Local`](#Local) field to get the inner value.
pub fn unwrap_local(local: Local(a)) -> a {
  let Local(value) = local
  value
}

/// Create an empty wiring configuration. Pipe through [`session`](#session)
/// and [`topic`](#topic) to register stores. Pass the result to
/// [`client.start`](./client.html#start) and
/// [`server.new`](./server.html#new).
///
/// ```gleam
/// store.wiring()
/// |> store.session(extract:, update:, field_get:, field_set:)
/// |> store.topic(id: "chat", extract:, update:, field_get:, field_set:)
/// ```
pub fn wiring() -> Wiring(model, message) {
  Wiring(session: option.None, topics: dict.new())
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
  let config = case target {
    transport.Session -> wiring.session
    transport.Topic(id) ->
      case dict.get(wiring.topics, id) {
        Ok(c) -> option.Some(c)
        Error(_) -> option.None
      }
  }
  case config {
    option.None -> current
    option.Some(c) -> c.merge_snapshot(current, snapshot_state)
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
        False -> first_matching_topic(wiring, message)
      }
    option.None -> first_matching_topic(wiring, message)
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
  dict.get(wiring.topics, id)
  |> result.map(fn(config) { config.apply })
  |> option.from_result
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
    Error(_) -> model
  }
}

fn first_matching_topic(
  wiring: Wiring(model, message),
  message: message,
) -> Target {
  case
    dict.to_list(wiring.topics)
    |> list.find(fn(pair) { { pair.1 }.is_for_target(message) })
  {
    Ok(#(id, _)) -> transport.Topic(id)
    Error(_) -> transport.Session
  }
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
