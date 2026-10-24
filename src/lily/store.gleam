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
//// Within your client/frontend code, you can then add the following to
//// initialise the store:
////
//// ```gleam
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
////       // match on your message type's constructors
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
////     id: "chat",
////     get: fn(model) { model.chat },
////     set: fn(model, chat) { Model(..model, chat:) },
////     access: store.Open,
////   )
//// }
//// ```
////
//// The server runs `update` against its own copy of the model, one per
//// connection and one per topic, and the client keeps only the slice that
//// the `get` and `set` pair describes. Every copy starts from the initial
//// model. A topic whose state lives somewhere else, like a database, can
//// start from its own model with
//// [`server.topic_init`](./server.html#topic_init).
////
//// A snapshot carries the server's whole copy though, not just the slice, so
//// every field of a session's model reaches that client and every field of a
//// topic's model reaches every subscriber. Keep what one client mustn't see
//// out of the copies the server holds for others.
////
//// Keep `update` pure. A client replays its own unconfirmed messages through
//// it on top of each fresh copy the server sends, which is how clients agree
//// again after concurrent edits (see [client](./client.html)).
////
//// Topics are basically shared stores with [`Access`](#Access) rules for
//// subscriptions. [`topic`](#topic) declares one with a fixed id and
//// [`topics`](#topics) a family of them whose ids share a prefix. An exact id
//// beats any prefix, and among families the longest matching prefix wins,
//// meaning a prefix should end with a separator (e.g. a colon). The server
//// will start a topic the first time someone subscribes to it or the server
//// dispatches to it with
//// [`server.dispatch_topic`](./server.html#dispatch_topic). A topic stopped
//// with [`server.stop_topic`](./server.html#stop_topic) starts the same way,
//// and the clients that held it are subscribed again when it does.
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
import gleam/result
import gleam/string

import lily/internal/actor
import lily/internal/codec
import lily/transport.{type Serialiser, type SyncTarget}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Who can subscribe to a topic, passed to [`topic`](#topic) and
/// [`topics`](#topics).
///
/// `Allow` gets the client id, the topic id and that client's session model,
/// which holds whatever the server wrote into it. A client it refuses sees a
/// [`SubscriptionRejected`](./client.html#ClientEvent).
///
/// A client can send any message routed to `Session`, so whatever `Allow`
/// reads, identity above all, must be written by a message routed `Local`.
/// The server drops a client's `Local` message but applies one it sends
/// itself, through a seed on [`server.connect_as`](./server.html#connect_as)
/// or [`server.open_as`](./server.html#open_as), or through
/// [`server.dispatch_to`](./server.html#dispatch_to).
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
  /// Stays on this client and doesn't go to the server
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
    sync: SyncSettings(model, message),
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
/// It only carries the model, rendering the page's HTML is up to you. A model
/// that has no wire form, an `Int` past what JavaScript holds say, embeds
/// nothing and logs why.
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
    // applied as it stands, never resynced against, so it names no epoch
    transport.Snapshot(
      target: transport.Session,
      epoch: 0,
      sequence: 0,
      state: model,
    )
  let serialiser = store.sync.serialiser
  let encoded =
    actor.rescue(fn() {
      transport.encode_as(
        frame,
        serialiser:,
        format: transport.server_format(serialiser),
      )
    })
  // a model with no wire form, an int out of range say, embeds nothing and the
  // page starts from the store's model
  case encoded {
    Ok(bytes) ->
      "<script type=\"application/octet-stream\" id=\"lily-snapshot\">"
      <> bit_array.base64_encode(bytes, True)
      <> "</script>"
    Error(reason) -> {
      actor.log(
        transport.Failure,
        "lily: initial_snapshot couldn't encode the model: " <> reason,
      )
      ""
    }
  }
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
    // local until `sync` sets a route
    sync: SyncSettings(
      route: fn(_) { Local },
      serialiser: transport.automatic(
        format: transport.Json,
        max_decode_depth: codec.default_max_depth,
        modules: [],
      ),
      session: option.None,
      topics: [],
      subscriptions: fn(_) { [] },
      schema: option.None,
    ),
    synced: False,
  )
}

/// Has the server drop a client message whose shape doesn't match `schema`,
/// generated by `gleam run -m lily/dev schema`.
///
/// ```gleam
/// store.sync(store, route:, modules: [transport.module("shared")])
/// |> store.schema(lily_schema.schema())
/// ```
pub fn schema(
  store: Store(model, message, Synced),
  schema: transport.Schema,
) -> Store(model, message, Synced) {
  with_sync(store, fn(sync) {
    SyncSettings(..sync, schema: option.Some(schema))
  })
}

/// Says which part of the model is this client's session, through a `get` and
/// `set` pair, making sure the server's copy of it lands in the right place.
///
/// Needed whenever `route` sends anything to `Session`. Without it the server
/// still applies those messages but its copy doesn't reach the client, which
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
    SyncSettings(
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
  with_sync(store, fn(sync) { SyncSettings(..sync, subscriptions:) })
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
  Store(
    ..store,
    sync: SyncSettings(..store.sync, route:, serialiser:),
    synced: True,
  )
}

/// Declares a single topic shared between clients, matched by its exact `id`.
///
/// `get` and `set` read and write its part of the model and `access` says who
/// can subscribe, see [`Access`](#Access). Declaring the same id again
/// replaces the earlier one.
///
/// ```gleam
/// store.topic(
///   id: "chat",
///   get: fn(model) { model.chat },
///   set: fn(model, chat) { Model(..model, chat:) },
///   access: store.Open,
/// )
/// ```
pub fn topic(
  store: Store(model, message, Synced),
  id id: String,
  get get: fn(model) -> slice,
  set set: fn(model, slice) -> model,
  access access: Access(model),
) -> Store(model, message, Synced) {
  add_topic(store, ExactId(id), access, fn(current, _, snapshot) {
    set(current, get(snapshot))
  })
}

/// Declares a family of topics, every id that starts with `prefix`. Pair with
/// [`subscriptions`](#subscriptions) to join one by its full id.
///
/// `get` and `set` receive the rest of the id after the prefix. An exact
/// [`topic`](#topic) id beats any family, and among families the longest
/// matching prefix wins, meaning a prefix should end with a separator.
///
/// ```gleam
/// store.topics(
///   prefix: "room:",
///   get: fn(model, room) {
///     dict.get(model.rooms, room) |> result.unwrap(new_room())
///   },
///   set: fn(model, room, state) {
///     Model(..model, rooms: dict.insert(model.rooms, room, state))
///   },
///   access: store.Open,
/// )
/// ```
pub fn topics(
  store: Store(model, message, Synced),
  prefix prefix: String,
  get get: fn(model, String) -> slice,
  set set: fn(model, String, slice) -> model,
  access access: Access(model),
) -> Store(model, message, Synced) {
  add_topic(store, IdPrefix(prefix), access, fn(current, rest, snapshot) {
    set(current, rest, get(snapshot, rest))
  })
}

// =============================================================================
// INTERNAL TYPES
// =============================================================================

@internal
pub type TopicMatch {
  ExactId(String)
  IdPrefix(String)
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
    Ok(#(entry, _)) -> Ok(entry.access)
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

/// Whether a snapshot for `target` lands in the model, see
/// [`merge_snapshot`](#merge_snapshot).
@internal
pub fn has_slice(
  store: Store(model, message, mode),
  target: SyncTarget,
) -> Bool {
  case target {
    transport.Session -> has_session(store)
    transport.Topic(id) -> result.is_ok(entry_for(store, id))
  }
}

/// An exact id beats any prefix, then the longest prefix in bytes wins. Gives
/// back the rest of the id after the prefix, empty for an exact id.
@internal
pub fn match_topic(
  entries: List(entry),
  id: String,
  match_of: fn(entry) -> TopicMatch,
) -> Result(#(entry, String), Nil) {
  let exact = list.find(entries, fn(entry) { match_of(entry) == ExactId(id) })
  case exact {
    Ok(entry) -> Ok(#(entry, ""))
    Error(Nil) ->
      list.fold(entries, Error(Nil), fn(best, entry) {
        case match_of(entry) {
          ExactId(_) -> best
          IdPrefix(prefix) -> {
            let longer = case best {
              Ok(#(_, incumbent)) ->
                string.byte_size(prefix) > string.byte_size(incumbent)
              Error(Nil) -> True
            }
            case longer && string.starts_with(id, prefix) {
              True -> Ok(#(entry, prefix))
              False -> best
            }
          }
        }
      })
      |> result.try(fn(found) {
        let #(entry, prefix) = found
        use rest <- result.map(drop_bytes(id, string.byte_size(prefix)))
        #(entry, rest)
      })
  }
}

/// Replaces only the slice of `current` that belongs to `target`.
@internal
pub fn merge_snapshot(
  store: Store(model, message, mode),
  target: SyncTarget,
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
        Ok(#(entry, rest)) -> entry.merge(current, rest, snapshot)
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
pub fn schema_of(
  store: Store(model, message, mode),
) -> Option(transport.Schema) {
  store.sync.schema
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

type SyncSettings(model, message) {
  SyncSettings(
    route: fn(message) -> Route,
    serialiser: Serialiser(model, message),
    // merges a snapshot's session slice into the current model
    session: Option(fn(model, model) -> model),
    topics: List(TopicEntry(model)),
    subscriptions: fn(model) -> List(String),
    schema: Option(transport.Schema),
  )
}

type TopicEntry(model) {
  TopicEntry(
    match: TopicMatch,
    access: Access(model),
    // merges the slice for the rest of the id after the prefix
    merge: fn(model, String, model) -> model,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn add_topic(
  store: Store(model, message, Synced),
  match: TopicMatch,
  access: Access(model),
  merge: fn(model, String, model) -> model,
) -> Store(model, message, Synced) {
  with_sync(store, fn(sync) {
    let others = list.filter(sync.topics, fn(other) { other.match != match })
    SyncSettings(..sync, topics: [TopicEntry(match:, access:, merge:), ..others])
  })
}

// matching is by bytes and so is the rest, by graphemes a combining mark after
// the prefix would hand two ids the same rest
fn drop_bytes(text: String, count: Int) -> Result(String, Nil) {
  let bytes = bit_array.from_string(text)
  bit_array.slice(bytes, count, bit_array.byte_size(bytes) - count)
  |> result.try(bit_array.to_string)
}

fn entry_for(
  store: Store(model, message, mode),
  topic_id: String,
) -> Result(#(TopicEntry(model), String), Nil) {
  match_topic(store.sync.topics, topic_id, fn(entry) { entry.match })
}

fn with_sync(
  store: Store(model, message, mode),
  change: fn(SyncSettings(model, message)) -> SyncSettings(model, message),
) -> Store(model, message, mode) {
  Store(..store, sync: change(store.sync))
}
