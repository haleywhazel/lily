# Lily

[![Package Version](https://img.shields.io/hexpm/v/lily)](https://hex.pm/packages/lily)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/lily/)

Lily is a web framework for Gleam that focuses specifically on having real-time sync with the server while keeping client interactions for offline capability!

Features:

* Automatic client and server syncing
* Simple way to get shared multi-user states
* Offline-first by default
* Optimistic updates on the client while retaining an authoritative server
* Fine-grained control over rendering without needing to memoisation
* OTP supervision to handle crashes

## How Lily works

In Lily, states are owned by a store that is synced across the client and server to prevent states from being lost as the number of components grows, like in Lustre and Elm. Unlike Lustre, however, rendering is owned by each individual component, giving you a bit more control over how you want rendering to occur. At its core, you have a message and update loop that handles state changes (which syncs with the server), and individual components that listen to parts of the model and render as necessary.

Lily is designed to work with existing Gleam libraries (wisp/mist/ewe, Lustre HTML layouts) and delegates parts such as creating server and handling websocket connections to them.

## When should you (not) use Lily?

While Lily makes writing web applications that require both offline-functionality and syncing between server and client(s) easier, this also means that there is more boilerplate code that is required. For simple applications like static webpages, SPAs, SSR without needing offline interactivity, it's probably easier to use other frameworks like Phoenix LiveView and Lustre if you want to take advantage of the BEAM VM! However, that doesn't mean these applications aren't doable in Lily – feel free to do so anyway :) and have fun writing code with Lily!

## Tutorial

WIP NOT IN REPO YET

The sidebar should contain links to a tutorial that walks you through common use cases of Lily. Each page builds up to a single project that you can also find inside the `/examples` folder of the GitHub repo.
