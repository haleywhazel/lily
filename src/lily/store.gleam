//// In Lily, the [`Store`](#Store) holds your main application state and update
//// logic, sitting across both the client and the server. The store works by
//// having a model and an associated update logic (that takes the model and a
//// message and returns a new model). The mental model for the data within the
//// store is similar to the TEA/MVU model that Elm/Lustre uses without the
//// actual rendering/view part, which is owned by the individual components.
////
//// Model fields that should not be synced to the server can be wrapped in
//// [`Local`](#Local). These fields are client-only: the server holds them at
//// their initial values, and the client runtime preserves them when the server
//// sends a snapshot on reconnect. Pair with
//// [`client.session_field`](./client.html#session_field) to persist them
//// across page navigations.
////
//// The same store runs on the client via
//// [`client.start`](./client.html#start) and the server via
//// [`server.start`](./server.html#start), meaning your `update` function
//// works identically on both sides.
////
//// Here's a very basic example of the idea behind how the store works.
////
//// ```gleam
//// import lily/store
////
//// pub type Model {
////   Model(count: Int, user: String)
//// }
////
//// pub type Message {
////   Increment
////   Decrement
////   SetUser(String)
//// }
////
//// pub fn update(model: Model, message: Message) -> Model {
////   case message {
////     Increment -> Model(..model, count: model.count + 1)
////     Decrement -> Model(..model, count: model.count - 1)
////     SetUser(name) -> Model(..model, user: name)
////   }
//// }
////
//// pub fn main() {
////   let app_store = store.new(Model(count: 0, user: "Guest"), with: update)
////   // Pass to client.start() or server.start()
//// }
//// ```
////
//// Internally, messages are processed sequentially within the client runtime,
//// which batches multiple `apply` calls between render frames, so rapid
//// bursts of messages don't lead to unnecessary computation of what should be
//// rendered much faster than the DOM is able to update.
////

// Internal notes: currently, the store module is quite small. I'm not entirely
// sure whether or not to merge this within another module but I've kept it like
// this for now so we can keep the `store.new()` logic which looks quite nice
// for the public API.

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Model fields that are client-only and not synced to the server should be
/// wrapped using Local(_). The server holds `Local` fields at their initial
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
/// and the server (via [`server.start`](./server.html#start)).
pub type Store(model, message) {
  Store(model: model, update: fn(model, message) -> model)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create a new store, seeded with an `initial_model` (similar to Lustre's
/// `init`) and an update function that transforms the model based on a given
/// `message`. This is essentially a wrapper around the [`Store`](#Store)
/// constructor that reads slightly nicer.
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

/// Unwrap a [`Local`](#Local) field to get the inner value.
pub fn unwrap_local(local: Local(a)) -> a {
  let Local(value) = local
  value
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Apply a message to the store, returning the updated store. Used internally
/// for batch rendering — multiple messages are applied before a single render
/// frame so rapid bursts of updates are combined into one DOM update.
@internal
pub fn apply(
  store: Store(model, message),
  message message: message,
) -> Store(model, message) {
  let new_model = store.update(store.model, message)
  Store(..store, model: new_model)
}
