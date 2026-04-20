//// Lily is a web framework that aims to both allow for live server updates
//// and offline interactivity that saves user actions until the connection is
//// restored. Think both collaborative and offline document editing.
////
//// As a Redux-style framework, Lily has a central store and components that
//// are able to react to changes to model changes within the central store.
//// The client and the server sync this central store through a persistent
//// connection, with client-side rendering for the user interface. Rendering
//// of individual components are owned by the components, not by the central
//// store.
////
//// Lily is designed to be modular, with each part replaceable by your own
//// implementation. The current modules sit as follows:
////
//// 1. [`lily/client`](./lily/client.html): client runtime (JS target only)
//// 2. [`lily/component`](./lily/component.html): components for frontend
////    interactivity (JS target only)
//// 3. [`lily/event`](./lily/event.html): event handlers (JS target only)
//// 4. [`lily/server`](./lily/server.html): server runtime (different
////    implementation for JS and Erlang targets)
//// 5. [`lily/transport`](./lily/transport.html): transport abstraction and
////    wire protocol
////
//// Framework philosophy:
////
//// * A balance between a minimal public API and configurability. While some
////   individual functions are strictly internal, their usage should be able to
////   be set as desired by the user.
//// * Builder patterns through piping (over configuration types or `Nil`
////   returning functions).
//// * All public functions use labelled arguments for clarity.
//// * Compatibility with existing Gleam ecosystem where possible (especially
////   with Lustre templating).
////
//// Note that Lily is **experimental**, with breaking changes expected at this
//// stage.
////
//// ## The Store
////
//// The [`Store`](#Store) holds your application state and update logic. It is
//// the core of Lily's reactive system, used by both the client and server.
////
//// The store manages your model (immutable application state) and the update
//// function (how messages transform the model). It is pure Gleam with no
//// target-specific code — the same store runs on the client via
//// [`client.start`](./lily/client.html#start) and the server via
//// [`server.start`](./lily/server.html#start), meaning your `update` function
//// works identically on both sides.
////
//// ```gleam
//// import lily
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
////   let app_store = lily.new(Model(count: 0, user: "Guest"), with: update)
////   // Pass to client.start() or server.start()
//// }
//// ```
////
//// Messages are processed sequentially via [`lily.apply`](#apply). The
//// client runtime batches multiple `apply` calls between render frames,
//// so rapid bursts of messages (e.g., server updates arriving faster than
//// 60fps) are coalesced into a single DOM update.
////

// =============================================================================
// PUBLIC CONSTANTS
// =============================================================================

/// The current version of Lily.
pub const version: String = "0.2.0"

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// The store with your application state and update logic. The same store
/// runs on both the client (via [`client.start`](./lily/client.html#start))
/// and the server (via [`server.start`](./lily/server.html#start)).
pub type Store(model, message) {
  Store(model: model, update: fn(model, message) -> model)
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Create a new store, seeded with an `initial_model` and an update function
/// that transforms the model based on a given `message`.
///
/// ## Example
///
/// ```gleam
/// let app_store = lily.new(Model(count: 0, user: "Guest"), with: update)
/// ```
pub fn new(
  initial_model model: model,
  with update: fn(model, message) -> model,
) -> Store(model, message) {
  Store(model: model, update: update)
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

/// Apply a message to the store, returning the updated store. Used internally
/// for batch rendering — multiple messages are applied before a single render
/// frame so rapid bursts of updates coalesce into one DOM update.
@internal
pub fn apply(
  store: Store(model, message),
  message message: message,
) -> Store(model, message) {
  let new_model = store.update(store.model, message)
  Store(..store, model: new_model)
}
