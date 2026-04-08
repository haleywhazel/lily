//// Lily: a component framework for Gleam with server-client state synchronisation.

// Re-export store
pub type Store(model, msg) =
  store.Store(model, msg)

import lily/store

pub const new_store = store.new

pub const apply = store.apply

pub const dispatch = store.dispatch

pub const get_model = store.get_model

pub const send = store.send

pub const subscribe = store.subscribe

pub const unsubscribe = store.unsubscribe

// Re-export component
pub type Patch =
  component.Patch

import lily/component

pub const mount = component.mount

pub const live = component.live

pub const simple = component.simple

// Re-export protocol
pub type Protocol(model, msg) =
  protocol.Protocol(model, msg)

pub type Serialiser(model, msg) =
  protocol.Serialiser(model, msg)

import lily/protocol

pub const encode = protocol.encode

pub const decode = protocol.decode

// Client-side exports
@target(javascript)
import lily/client

@target(javascript)
pub const connect = client.connect

@target(javascript)
pub const start = client.start

// Server-side exports
@target(erlang)
import lily/server

@target(erlang)
pub const server_start = server.start

@target(erlang)
pub const server_connect = server.connect

@target(erlang)
pub const disconnect = server.disconnect

@target(erlang)
pub const incoming = server.incoming
