# Lily

Lily is designed to be a web framework for Gleam that allows for real-time updates while preserving full-offline functionality. Local actions and messages are queued and flushed to the server on reconnect to ensure syncing. This means that an offline first experience is retained, with a component-based rendering system where components (rather than a central store) owns their own rendering, while the state remains stored centrally (a Redux-like model).
