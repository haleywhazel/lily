//// In Lily, the [`Store`](#Store) holds your model (application state) and
//// message update logic. The same store within your shared package should
//// be used on both frontend and backend. Each message updates the model, with
//// the standard case of the update function being
//// `update(model: Model, message: Message) -> Model` that uses pattern
//// matching over potential messages:
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
//// ```
////
//// // this should be in your client/frontend code
////
//// Within your client/frontend code, you can then add the following to
//// initialise the store:
////
//// ```
//// let store = store.new(init: Model(count: 0), update: update)
//// ```
////
//// This can then be passed onto [`client.start`](./client.html#start) to
//// begin a client-only app with a set store. To sync with a server, pipe it
//// through [`sync`](#sync), changing its type so that you can connect it on
//// the frontend with [`client.connect`](./client.html#connect) and
//// [`server.new`](./server.html#new) on the backend.
////
//// The `route` function says where each message goes, to this connection's
//// session, to a shared topic, or staying on the client that sent it
//// ([`Local`](#Route)).
////
//// Build one store in your `shared` package and hand the same value to both
//// the client and the server:
////
//// ```gleam
//// import lily/store
//// import lily/transport
////
//// pub fn store() -> store.Store(Model, Message, store.Synced) {
////   store.new(init: initial_model(), update: update)
////   |> store.sync(
////     route: fn(message) {
////       // wrap your messages within another type and pattern match on constructors
////       case message {
////         Chat(_) -> store.Topic("chat")
////         Profile(_) -> store.Session
////         Hover(_) -> store.Local
////       }
////     },
////     modules: [transport.module("shared")],
////   )
////   |> store.session(
////     get: fn(model) { model.session },
////     set: fn(model, session) { Model(..model, session:) },
////   )
////   |> store.topic(
////     prefix: "chat",
////     get: fn(model, _id) { model.chat },
////     set: fn(model, _id, chat) { Model(..model, chat:) },
////     access: store.Open,
////   )
//// }
//// ```
////
//// The server runs `update` against its own copy of the model, one per
//// connection and one per topic, and sends back only the slice that the
//// `get` and `set` pair describes. Every copy starts from the initial model.
//// A topic whose state lives somewhere else, like a database, can start from
//// its own model with [`server.topic_init`](./server.html#topic_init).
////
//// Topics are basically stores with shared prefixes with [`Access`](#Access)
//// rules for subscriptions. Because the longest matching prefix is used for
//// matching, end the prefix with a separator (e.g. a colon). The server
//// will start a topic the first time someone subscribes to it or sends a
//// message to it.
////
//// Which topics a client subscribes/listens to is a function of its model
//// under [`subscriptions`](#subscriptions). Lily compares it after every
//// update and subscribes and unsubscribes to match.
////
//// A server that renders the first page can embed the model the client starts
//// from with [`initial_snapshot`](#initial_snapshot) using the same
//// serialiser the store syncs with.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/string
import lily/internal/codec
import lily/transport.{type Serialiser, type Target}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Who can subscribe to a topic, passed to [`topic`](#topic).
///
/// `Allow` gets the client id, the topic id and that client's session model,
/// which holds whatever the server wrote into it. A client it refuses sees a
/// [`SubscriptionRejected`](./client.html#ClientEvent).
pub type Access(model) {
  /// Anyone can subscribe
  Open
  /// Only clients the function returns `True` for
  Allow(fn(String, String, model) -> Bool)
}

/// Where a message goes.
pub type Route {
  /// This client's own session on the server
  Session
  /// The shared topic with this id
  Topic(id: String)
  /// Stays on this client, never sent to the server
  Local
}

/// A store that doesn't sync, for a client-only app.
pub type Standalone

/// Your model and update logic, shared by the client
/// ([`client.start`](./client.html#start)) and the server
/// ([`server.new`](./server.html#new)).
///
/// Create one with [`new`](#new).
pub opaque type Store(model, message, mode) {
  Store(
    model: model,
    update: fn(model, message) -> model,
    sync: Sync(model, message),
    synced: Bool,
  )
}

/// A store that syncs with a server, from [`sync`](#sync).
/// [`client.connect`](./client.html#connect) and
/// [`server.new`](./server.html#new) need one.
pub type Synced

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Embeds `model` in a server-rendered page as a `<script>` tag, letting
/// [`client.start`](./client.html#start) start from it.
///
/// It only carries the model, rendering the page's HTML is up to you.
///
/// ```gleam
/// let body = "<!DOCTYPE html><html><body>"
///   <> "<div id=\"app\">" <> rendered_html <> "</div>"
///   <> store.initial_snapshot(shared.store(), model: initial_model)
///   <> "</body></html>"
/// ```
pub fn initial_snapshot(
  store: Store(model, message, Synced),
  model model: model,
) -> String {
  let frame =
    transport.Snapshot(target: transport.Session, sequence: 0, state: model)
  let serialiser = store.sync.serialiser
  let bytes =
    transport.encode_as(
      frame,
      serialiser:,
      format: transport.server_format(serialiser),
    )
  "<script type=\"application/octet-stream\" id=\"lily-snapshot\">"
  <> bit_array.base64_encode(bytes, True)
  <> "</script>"
}

/// Creates a store, with an `init` model (like Lustre's `init`) and a function
/// that updates the model for a given `message`.
///
/// ```gleam
/// store.new(init: Model(count: 0, user: "Someone"), update: update)
/// ```
pub fn new(
  init init: model,
  update update: fn(model, message) -> model,
) -> Store(model, message, Standalone) {
  Store(
    model: init,
    update:,
    // don't send anything for now until later pipe constructors
    sync: Sync(
      route: fn(_) { Local },
      serialiser: transport.automatic(
        format: transport.Json,
        max_decode_depth: codec.default_max_depth,
        modules: [],
      ),
      session: option.None,
      topics: [],
      subscriptions: fn(_) { [] },
    ),
    synced: False,
  )
}

/// Says which part of the model is this client's session, through a `get` and
/// `set` pair, making sure the server's copy of it lands in the right place.
///
/// Needed whenever `route` sends anything to `Session`. Without it the server
/// still applies those messages but its copy never reaches the client, which
/// warns once with a [`Diagnostic`](./client.html#ClientEvent).
///
/// ```gleam
/// store.session(
///   get: fn(model) { model.session },
///   set: fn(model, session) { Model(..model, session:) },
/// )
/// ```
pub fn session(
  store: Store(model, message, Synced),
  get get: fn(model) -> slice,
  set set: fn(model, slice) -> model,
) -> Store(model, message, Synced) {
  with_sync(store, fn(sync) {
    Sync(
      ..sync,
      session: option.Some(fn(current, snapshot) { set(current, get(snapshot)) }),
    )
  })
}

/// The topic ids this client wants to subscribe to, as a function of its
/// model.
///
/// Lily subscribes and unsubscribes after every update to match, sparing you
/// from doing it by hand.
///
/// ```gleam
/// store.subscriptions(fn(model) {
///   case model.joined_room {
///     option.Some(room) -> ["room:" <> room]
///     option.None -> []
///   }
/// })
/// ```
pub fn subscriptions(
  store: Store(model, message, Synced),
  subscriptions: fn(model) -> List(String),
) -> Store(model, message, Synced) {
  with_sync(store, fn(sync) { Sync(..sync, subscriptions:) })
}

/// Adds client-server synchronisation to the store.
///
/// `route` decides where each message goes (see [`Route`](#Route)) and
/// `modules` names the modules that define the types you send, letting Lily
/// serialise them for you.
///
/// ```gleam
/// store.new(init: initial_model(), update: update)
/// |> store.sync(route: route, modules: [transport.module("shared")])
/// ```
///
/// Messages travel as JSON on `localhost` and MessagePack everywhere else,
/// letting you read them in DevTools while developing. Use
/// [`sync_with`](#sync_with) to pick one.
pub fn sync(
  store: Store(model, message, Standalone),
  route route: fn(message) -> Route,
  modules modules: List(transport.Module),
) -> Store(model, message, Synced) {
  sync_with(
    store,
    route:,
    serialiser: transport.automatic(
      format: transport.ByHost,
      max_decode_depth: codec.default_max_depth,
      modules:,
    ),
  )
}

/// Syncs the store with a serialiser of your own, from
/// [`transport.automatic`](./transport.html#automatic) or
/// [`transport.serialiser`](./transport.html#serialiser).
pub fn sync_with(
  store: Store(model, message, Standalone),
  route route: fn(message) -> Route,
  serialiser serialiser: Serialiser(model, message),
) -> Store(model, message, Synced) {
  Store(..store, sync: Sync(..store.sync, route:, serialiser:), synced: True)
}

/// Declares a topic (or a collection of them) shared between clients.
///
/// Ids that start with `prefix` belong to it and the longest matching prefix
/// wins, meaning every prefix should end on a separator such as a colon.
///
/// `get` and `set` read and write one topic's part of the model, given the
/// rest of the id after the prefix (empty for a topic with a fixed name).
/// `access` says who can subscribe, see [`Access`](#Access).
///
/// A collection of topics uses the rest of the id:
///
/// ```gleam
/// store.topic(
///   prefix: "room:",
///   get: fn(model, id) {
///     dict.get(model.rooms, id) |> result.unwrap(new_room())
///   },
///   set: fn(model, id, room) {
///     Model(..model, rooms: dict.insert(model.rooms, id, room))
///   },
///   access: store.Open,
/// )
/// ```
///
/// A topic with a fixed name ignores it:
///
/// ```gleam
/// store.topic(
///   prefix: "chat",
///   get: fn(model, _) { model.chat },
///   set: fn(model, _, chat) { Model(..model, chat:) },
///   access: store.Open,
/// )
/// ```
pub fn topic(
  store: Store(model, message, Synced),
  prefix prefix: String,
  get get: fn(model, String) -> slice,
  set set: fn(model, String, slice) -> model,
  access access: Access(model),
) -> Store(model, message, Synced) {
  with_sync(store, fn(sync) {
    let entry =
      TopicEntry(prefix:, access:, merge: fn(current, key, snapshot) {
        set(current, key, get(snapshot, key))
      })
    let others = list.filter(sync.topics, fn(other) { other.prefix != prefix })
    Sync(..sync, topics: [entry, ..others])
  })
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@internal
pub fn access_for(
  store: Store(model, message, mode),
  topic_id: String,
) -> Result(Access(model), Nil) {
  case entry_for(store, topic_id) {
    Ok(entry) -> Ok(entry.access)
    Error(Nil) -> Error(Nil)
  }
}

@internal
pub fn get_model(store: Store(model, message, mode)) -> model {
  store.model
}

@internal
pub fn has_session(store: Store(model, message, mode)) -> Bool {
  option.is_some(store.sync.session)
}

@internal
pub fn longest_prefix(
  entries: List(entry),
  id: String,
  prefix_of: fn(entry) -> String,
) -> Result(entry, Nil) {
  list.fold(entries, Error(Nil), fn(best, entry) {
    let prefix = prefix_of(entry)
    case string.starts_with(id, prefix), best {
      False, _ -> best
      True, Error(Nil) -> Ok(entry)
      True, Ok(incumbent) ->
        case string.length(prefix) > string.length(prefix_of(incumbent)) {
          True -> Ok(entry)
          False -> best
        }
    }
  })
}

/// Replaces only the slice of `current` that belongs to `target`.
@internal
pub fn merge_snapshot(
  store: Store(model, message, mode),
  target: Target,
  current: model,
  snapshot: model,
) -> model {
  case target {
    transport.Session ->
      case store.sync.session {
        option.Some(merge) -> merge(current, snapshot)
        option.None -> current
      }
    transport.Topic(id) ->
      case entry_for(store, id) {
        Ok(entry) ->
          entry.merge(
            current,
            string.drop_start(id, string.length(entry.prefix)),
            snapshot,
          )
        Error(Nil) -> current
      }
  }
}

/// `Local` for a store that isn't synced.
@internal
pub fn route(store: Store(model, message, mode), message: message) -> Route {
  store.sync.route(message)
}

@internal
pub fn serialiser(
  store: Store(model, message, mode),
) -> Result(Serialiser(model, message), Nil) {
  case store.synced {
    True -> Ok(store.sync.serialiser)
    False -> Error(Nil)
  }
}

@internal
pub fn serialiser_of(
  store: Store(model, message, Synced),
) -> Serialiser(model, message) {
  store.sync.serialiser
}

@internal
pub fn subscriptions_of(
  store: Store(model, message, mode),
  model: model,
) -> List(String) {
  store.sync.subscriptions(model)
}

@internal
pub fn update_function(
  store: Store(model, message, mode),
) -> fn(model, message) -> model {
  store.update
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

type Sync(model, message) {
  Sync(
    route: fn(message) -> Route,
    serialiser: Serialiser(model, message),
    // merges a snapshot's session slice into the current model
    session: Option(fn(model, model) -> model),
    topics: List(TopicEntry(model)),
    subscriptions: fn(model) -> List(String),
  )
}

type TopicEntry(model) {
  TopicEntry(
    prefix: String,
    access: Access(model),
    // merges the slice for the rest of the id after the prefix
    merge: fn(model, String, model) -> model,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn entry_for(
  store: Store(model, message, mode),
  topic_id: String,
) -> Result(TopicEntry(model), Nil) {
  longest_prefix(store.sync.topics, topic_id, fn(entry) { entry.prefix })
}

fn with_sync(
  store: Store(model, message, mode),
  change: fn(Sync(model, message)) -> Sync(model, message),
) -> Store(model, message, mode) {
  Store(..store, sync: change(store.sync))
}
