# Lily

[![Package Version](https://img.shields.io/hexpm/v/lily)](https://hex.pm/packages/lily)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/lily/)

Lily is a web framework for Gleam that focuses specifically on having real-time sync with the server while keeping client interactions for offline capability!

## How Lily works

In Lily, states are owned authoritatively by a single store that communicates with the server to prevent sprawling component states. Unlike Lustre, however, rendering is owned by each individual component and they can dictate exactly how they want rendering to occur. At its core, you have a message and update loop that handles state changes (which syncs with the server), and individual components that listen to parts of the model and render as necessary.

Lily is designed to work with existing Gleam libraries (wisp/mist/ewe, Lustre HTML layouts) and delegates parts such as creating server and handling websocket connections to them.

## When should you use Lily?

For most use cases, Lily is probably overkill, as there is additional boilerplate code to ensure the client/server sync while preserving offline interactivity. When *not* to use Lily (and use something like Lustre instead): static webpages, SPAs, SSR without needing offline interactivity. This covers the vast majority of common use cases. What Lily can do is also technically doable with Lustre, but Lily saves a bit of time by dealing with client-server connections on its own. There's also the Libero package which should give similar features to Lily when used with Lustre with less effort, although Lily doesn't use any codegen.

## Example

See the `/example` folder within the repo for an example Lily application.

Note: while I did decide to add a JS implementation to everything on the server-side to get docs to compile for the server modules and functions, I would recommend using the Erlang target instead to take advantage of the BEAM VM, otherwise it's probably a better idea to just use a more mature JS platform.
