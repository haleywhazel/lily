# Lily

[![Package Version](https://img.shields.io/hexpm/v/lily)](https://hex.pm/packages/lily)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/lily/)

Lily is a web framework for Gleam that focuses specifically on having real-time sync with the server while keeping client interactions for offline capabilities, e.g. document editing, preventing your Phoenix LiveView app from crumbling as soon as the internet connection is lost.

In Lily, states are owned authoritatively by a single store that communicates with the server to prevent sprawling component states. Unlike Lustre, however, rendering is owned by each individual component and they can dictate exactly how they want rendering to occur.

Lily is designed to work with existing Gleam libraries – wisp/mist/ewe, Lustre HTML layouts. The plus side of Gleam is that this allows both your backend and frontend that (can and probably should) compile to different targets.

For most use cases, Lily is probably overkill, as there is additional boilerplate code to ensure the client/server sync while preserving offline interactivity. When *not* to use Lily (and use something like Lustre instead): static webpages, SPAs, SSR without needing offline interactivity. This covers the vast majority of common use cases. What Lily can do is also technically doable with Lustre, but Lily saves a bit of time by dealing with client-server connections on its own. There's also the Libero package which should give similar features to Lily when used with Lustre with less effort, although Lily doesn't use any codegen.

See the `/example` folder for a generic page landing.

Note: while I did decide to add a JS implementation to everything on the server-side for completeness's sake, I would recommend using the Erlang target instead to take advantage of the BEAM VM, otherwise it's probably a better idea to just use a more mature and battle-tested JS platform.
