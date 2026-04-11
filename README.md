# Lily

Lily is a web framework that aims to both allow for live server updates
and offline interactivity that saves user actions until the connection is
restored. Think both collaborative and offline document editing.

As a Redux-style framework, Lily has a central store and components that
are able to react to changes to model changes within the central store.
The client and the server sync this central store through a persistent
connection, with client-side rendering for the user interface. Rendering
of individual components are owned by the components, not by the central
store.
