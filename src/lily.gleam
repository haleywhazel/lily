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
//// 5. [`lily/store`](./lily/store.html): central store, with updates
////    dispatched to components
//// 6. [`lily/transport`](./lily/transport.html): transport abstraction and
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

/// The current version of Lily.
pub const version: String = "0.2.0"
