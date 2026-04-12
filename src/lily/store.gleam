//// The [`Store`](#Store) holds your application state and update logic.
//// It's the core of Lily's reactive system, used by both client and server.
////
//// The store manages your model (immutable application state), the update
//// function (how messages transform the model), and handlers (functions
//// that run when the model changes, keyed by CSS selector). It's pure
//// Gleam with no target-specific code - the same store runs on the client
//// via [`client.start`](./client.html#start) and the server via
//// [`server.start`](./server.html#start), meaning your `update` function
//// works identically on both sides.
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
//// Components subscribe to the store via [`store.subscribe`](#subscribe)
//// using CSS selector strings as keys. If a new component uses the same
//// selector, it replaces the previous handler.
////

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/dict.{type Dict}
import gleam/list

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// The store with the model of your application state, update logic, and
/// handlers that are attached to each component that is subscribed to the
/// model. These handlers are keyed by a selector using CSS selector strings.
pub type Store(model, message) {
  Store(
    model: model,
    update: fn(model, message) -> model,
    handlers: Dict(String, fn(model) -> Nil),
  )
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create a new store, seeded with an `initial_model` and an update function
/// that can update a model based on a given `message`. See [Lustre
/// documentation](https://hexdocs.pm/lustre/lustre.html) for an explanation on
/// the Model / Message format, although note that the runtime and rendering are
/// owned by components within Lily.
pub fn new(
  initial_model model: model,
  with update: fn(model, message) -> model,
) -> Store(model, message) {
  Store(model: model, update: update, handlers: dict.new())
}

/// Allows a (frontend) component to subscribe to a specific store. Handlers are
/// the functions that each component runs on receiving the updated model. If a
/// handler is already registered for the given selector, it will be replaced.
/// No cleanup is performed on override – for most use cases, use functions
/// within the [`component`](./component.html) module.
pub fn subscribe(
  store: Store(model, message),
  selector selector: String,
  with handler: fn(model) -> Nil,
) -> Store(model, message) {
  Store(..store, handlers: dict.insert(store.handlers, selector, handler))
}

/// Removes a handler for the given selector, effectively unsubscribing that
/// component from model updates. As with [`subscribe`](#subscribe), no cleanup
/// is performed by store – for most use cases, use functions within the
/// [`component`](./component.html) module.
pub fn unsubscribe(
  store: Store(model, message),
  selector: String,
) -> Store(model, message) {
  let updated_handlers = dict.delete(store.handlers, selector)
  Store(..store, handlers: updated_handlers)
}

// =============================================================================
// INTERNAL PUBLIC FUNCTIONS
// =============================================================================

/// Apply an update to the store without notifying subscribers. This is used
/// for batch rendering, when messages and updates occur much faster than the
/// render refresh rate.
@internal
pub fn apply(store: Store(model, message), message message: message) -> Store(model, message) {
  let new_model = store.update(store.model, message)
  Store(..store, model: new_model)
}

/// Notify all subscribers of current state of the store.
@internal
pub fn notify(store: Store(model, message)) -> Nil {
  dict.values(store.handlers)
  |> list.each(fn(handler) { handler(store.model) })
}
