//// The client owns the browser-side [`Runtime`](#Runtime), pretty much
//// everything that makes a Lily app tick in the page. The update loop,
//// component subscriptions, and (once a transport is connected) keeping your
//// model in sync with the server all live here. A connector can hold messages
//// while you're disconnected and replay them the moment the server is back,
//// see [`with_offline_queue`](./transport.html#with_offline_queue). On
//// Erlang it does nothing, letting shared code compile.
////
//// A frontend comes together as one pipeline, build a
//// [`Store`](./store.html#Store) with [`store.new`](./store.html#new) (and
//// [`store.sync`](./store.html#sync) if you have a server), start the runtime
//// with [`start`](#start), [`mount`](./component.html#mount) your components,
//// pipe on your event handlers, and [`connect`](#connect) to the server:
////
//// ```gleam
//// import lily/client
//// import lily/component
//// import lily/transport
////
//// pub fn main() {
////   shared.store()
////   |> client.start
////   |> component.mount(
////     selector: "#app",
////     to_html: element.to_string,
////     to_placeholder: fn() { element.element("lily-nest", [], []) },
////     view: app,
////   )
////   |> client.connect(with: transport.websocket("/ws"))
//// }
//// ```
////
//// If you aren't syncing with a server, stop after `mount`, the runtime is
//// perfectly happy on its own. When you are, the topics this client listens to
//// come from the store's `subscriptions` function, and Lily subscribes and
//// unsubscribes as your model changes (see [store](./store.html)).
////
//// To feed messages in from outside your components, a timer, a callback, an
//// FFI shim, grab a dispatch function with [`dispatch`](#dispatch):
////
//// ```gleam
//// let dispatch = client.dispatch(runtime)
//// dispatch(Increment)
//// ```
////
//// Everything you dispatch, plus every frame the server sends, runs through a
//// single message queue, meaning your update function is only ever called one
//// message at a time even when several land at once. That ordering is what
//// keeps optimistic client updates from racing the server's authoritative
//// snapshots.
////
//// For client-side reactions that don't belong in `update`, focus management,
//// analytics, kicking off a fetch, register an observer with
//// [`observe`](#observe). It sees every [`ClientEvent`](#ClientEvent) with
//// the full model, from an applied message to a connection opening or a
//// fresh server snapshot. Routing, persistence, connection status and hot
//// reload are built on that same seam and live in
//// [`lily/browser`](./browser.html).
////
//// Because the wire only ever carries messages, an offline client keeps
//// working and catches up on reconnect. A message the store routes to `Local`
//// stays on this client.
////
//// Your own messages apply straight away and stay applied until the server
//// answers them. If another client's update lands in between, or the server
//// refuses one of yours, you may have applied things in a different order
//// from the server. Once everything you sent to that topic (or the session)
//// is answered, the client fetches the server's copy and plays whatever you
//// sent since back on top of it through your `update`, meaning clients agree
//// again after concurrent edits. A reconnect does the same, edits made
//// offline included.
////
//// Lily doesn't need to know whether your messages commute. It only replays
//// your own messages through your own `update` on top of the server's state,
//// which suits CRDT style messages (they converge whatever the order) as well
//// as OT style ones (a message that transforms against the version it was
//// made on sees the newer one). Keep `update` free of side effects, it can
//// run more than once for the same message.
////
//// An update that crashes is logged and skipped, and whatever was queued
//// behind it still runs.
////
//// Each [`Runtime`](#Runtime) is fully isolated, letting several coexist on
//// one page, but we'd steer you towards one runtime per page. Splitting your
//// state across many runtimes gets hard to reason about fast (badly designed
//// React apps with state scattered everywhere come to mind). If you need
//// independent, self-contained stateful widgets, a different framework might
//// suit you better.

// =============================================================================
// IMPORTS
// =============================================================================

import gleam/bit_array
@target(javascript)
import gleam/bool
@target(javascript)
import gleam/dict.{type Dict}
@target(javascript)
import gleam/int
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{type Option, None, Some}
import gleam/result
@target(javascript)
import gleam/set.{type Set}
import gleam/string

@target(javascript)
import lily/internal/actor.{type Box}
import lily/internal/codec
import lily/store.{type Store, type Synced}
import lily/transport

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Something that happened to the runtime, given to every observer
/// registered with [`observe`](#observe).
///
/// Match the variants you care about and ignore the rest with a catch-all, new
/// variants are not a breaking change.
pub type ClientEvent(model, message) {
  /// The server gave this client an id, on every connect and reconnect
  ClientIdAssigned(client_id: String)
  /// The connection dropped
  ConnectionClosed
  /// The connection opened, including the first time
  ConnectionOpened
  /// A warning from Lily itself
  Diagnostic(level: transport.DiagnosticLevel, message: String)
  /// `update` ran for a message, from this client or from a server frame
  MessageApplied(message: message, origin: MessageOrigin)
  /// [`update_model`](#update_model) ran
  ModelUpdated
  /// The server speaks another wire protocol, the connection is closed for good
  ProtocolMismatch(server: Int, client: Int)
  /// The server replaced a slice of the model, `previous` is the model before
  SnapshotApplied(target: transport.SyncTarget, previous: model)
  /// A resync found the slice already current, nothing was replaced
  SnapshotUnchanged(target: transport.SyncTarget)
  /// The server refused a subscription
  SubscriptionRejected(topic_id: String, reason: transport.RejectionReason)
  /// The server's build version, on every connect and reconnect
  VersionAnnounced(hash: String)
}

/// Where an applied message came from.
pub type MessageOrigin {
  /// Dispatched on this client, through [`dispatch`](#dispatch) or a listener
  Dispatched
  /// Arrived from the server
  Received
}

/// A running Lily app, from [`start`](#start).
pub opaque type Runtime(model, message, mode) {
  Runtime(handle: RuntimeHandle, store: Store(model, message, mode))
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Connects the runtime to a server, usually the last step of your pipeline.
///
/// The connector comes from
/// [`transport.websocket`](./transport.html#websocket), or from
/// [`transport.connector`](./transport.html#connector) for a transport of your
/// own. Edits made offline before a reload show up in the model straight away.
///
/// ```gleam
/// import lily/transport
///
/// runtime
/// |> client.connect(with: transport.websocket("/ws"))
/// ```
pub fn connect(
  runtime: Runtime(model, message, Synced),
  with connector: transport.Connector,
) -> Runtime(model, message, Synced) {
  connect_with(runtime, store.serialiser_of(runtime.store), connector)
}

/// Gets a function that sends messages to the runtime, for updates from
/// outside your components like fetch callbacks and timers.
///
/// ```gleam
/// let runtime = client.start(shared.store())
/// let dispatch = client.dispatch(runtime)
///
/// fetch("/api/data", fn(response) {
///   dispatch(DataReceived(response))
/// })
/// ```
pub fn dispatch(runtime: Runtime(model, message, mode)) -> fn(message) -> Nil {
  fn(message) { apply_message(runtime, message, Dispatched) }
}

/// The current model.
///
/// ```gleam
/// let count = client.model(runtime).count
/// ```
pub fn model(runtime: Runtime(model, message, mode)) -> model {
  get_model(runtime.handle)
}

/// Calls a function with every [`ClientEvent`](#ClientEvent) and the model
/// after it, for side effects that don't belong in `update`. Observers add up.
///
/// A message it dispatches or a change it makes runs once the current event is
/// done. Calling [`update_model`](#update_model) on every `ModelUpdated` loops
/// forever.
///
/// ```gleam
/// runtime
/// |> client.observe(fn(event, model) {
///   case event {
///     client.ConnectionClosed -> show_offline_toast()
///     _ -> Nil
///   }
/// })
/// ```
pub fn observe(
  runtime: Runtime(model, message, mode),
  observer: fn(ClientEvent(model, message), model) -> Nil,
) -> Runtime(model, message, mode) {
  observing(runtime, observer)
}

/// Starts the client runtime from a store, the first step of your frontend.
///
/// Only a store passed through [`store.sync`](./store.html#sync) can
/// [`connect`](#connect) to a server. A page with an
/// [`initial_snapshot`](./store.html#initial_snapshot) starts from that model.
///
/// ```gleam
/// let runtime = client.start(shared.store())
///
/// runtime
/// |> component.mount(
///   selector: "#app",
///   to_html: element.to_string,
///   to_placeholder: fn() { element.element("lily-nest", [], []) },
///   view: app,
/// )
/// ```
pub fn start(
  store: Store(model, message, mode),
) -> Runtime(model, message, mode) {
  let handle = create_runtime(store.get_model(store))
  // embedded SSR snapshot else the store's model, a bad embed is ignored
  // waits for registration, a snapshot can't decode before its types exist
  case store.serialiser(store) {
    Error(Nil) -> initial_notify(handle)
    Ok(serialiser) -> hydrate(handle, serialiser)
  }
  Runtime(handle:, store:)
}

/// Changes the model without sending anything to the server.
///
/// Observers see it as `ModelUpdated`.
///
/// ```gleam
/// client.update_model(runtime, with: fn(model) {
///   Model(..model, menu_open: False)
/// })
/// ```
pub fn update_model(
  runtime: Runtime(model, message, mode),
  with change: fn(model) -> model,
) -> Nil {
  run(runtime.handle, fn(model) { #(change(model), ModelUpdated) })
}

// =============================================================================
// INTERNAL FUNCTIONS
// =============================================================================

@internal
pub fn store_of(
  runtime: Runtime(model, message, mode),
) -> Store(model, message, mode) {
  runtime.store
}

// =============================================================================
// PRIVATE TYPES
// =============================================================================

// the server's state a slice was last confirmed at, sent back in a `Resync`
@target(javascript)
type Confirmed {
  Confirmed(epoch: Int, sequence: Int)
}

@target(javascript)
type PendingMessage(message) {
  // sent on the current connection
  PendingMessage(message: message, delivered: Bool)
}

// `front` oldest first then `back` newest first, pushes and pops stay cheap
@target(javascript)
type PendingQueue(message) {
  PendingQueue(
    front: List(PendingMessage(message)),
    back: List(PendingMessage(message)),
  )
}

type RuntimeHandle

@target(javascript)
type Sending {
  // on the wire or in the channel's own queue
  SentOrQueued
  // the channel refused it, the offline queue holds it when there is one
  Unsent
  // it has no wire form, it went nowhere
  Unencodable
}

@target(javascript)
type SyncSession(model, message) {
  SyncSession(
    runtime: Runtime(model, message, Synced),
    serialiser: transport.Serialiser(model, message),
    queues: Bool,
    state: Box(SyncState(model, message)),
  )
}

// changed only through `update_state`, a change never runs a callback
@target(javascript)
type SyncState(model, message) {
  SyncState(
    channel: Option(transport.Channel),
    // sent before the channel exists
    waiting: List(BitArray),
    open: Bool,
    replaying: Bool,
    subscribed: List(String),
    // the model `subscribed` was worked out from
    subscribed_for: Option(model),
    // own unanswered messages per target, never an empty queue
    pending: Dict(transport.SyncTarget, PendingQueue(message)),
    // targets that may be out of step
    diverged: Set(transport.SyncTarget),
    // what each slice holds of the server's state, only while that's exactly
    // it plus the pending edits on top
    confirmed: Dict(transport.SyncTarget, Confirmed),
    // targets a `Resync` is out for, one at a time
    resyncing: Set(transport.SyncTarget),
    // topics the server refused, not asked again until they're wanted anew
    // or the server rejoins us with a snapshot
    rejected: Set(String),
    // another protocol, nothing is sent or read again
    stopped: Bool,
    warned_no_session: Bool,
  )
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

fn apply_message(
  runtime: Runtime(model, message, mode),
  message: message,
  origin: MessageOrigin,
) -> Nil {
  let update = store.update_function(runtime.store)
  run(runtime.handle, fn(model) {
    #(update(model, message), MessageApplied(message:, origin:))
  })
}

@target(javascript)
fn apply_remote(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  message: message,
  sequence: Int,
) -> Nil {
  let update = store.update_function(sync.runtime.store)
  run(sync.runtime.handle, fn(model) {
    // the server may order it before our unconfirmed edits
    case dict.has_key(sync_state(sync).pending, target) {
      True -> mark_diverged(sync, target)
      False -> confirm(sync, target, sequence)
    }
    #(update(model, message), MessageApplied(message:, origin: Received))
  })
}

// a later step of the state a slice was confirmed at
@target(javascript)
fn confirm(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  sequence: Int,
) -> Nil {
  update_state(sync, fn(state) {
    case dict.get(state.confirmed, target) {
      Ok(Confirmed(epoch:, ..)) ->
        SyncState(
          ..state,
          confirmed: dict.insert(
            state.confirmed,
            target,
            Confirmed(epoch:, sequence:),
          ),
        )
      Error(Nil) -> state
    }
  })
}

@target(javascript)
fn connect_with(
  runtime: Runtime(model, message, Synced),
  serialiser: transport.Serialiser(model, message),
  connector: transport.Connector,
) -> Runtime(model, message, Synced) {
  let handle = runtime.handle
  use <- bool.lazy_guard(when: mark_connected(handle), return: fn() {
    actor.log(
      transport.Warning,
      "lily: client.connect was called twice on one runtime, the second is ignored",
    )
    runtime
  })
  let sync =
    SyncSession(
      runtime:,
      // `ByHost` resolves once, decoding reads both
      serialiser: transport.resolve_for_page(serialiser),
      queues: transport.queues(connector),
      state: actor.box_new(SyncState(
        channel: None,
        waiting: [],
        open: False,
        replaying: False,
        subscribed: [],
        subscribed_for: None,
        pending: dict.new(),
        diverged: set.new(),
        confirmed: dict.new(),
        resyncing: set.new(),
        rejected: set.new(),
        stopped: False,
        warned_no_session: False,
      )),
    )

  // a plain observer, added before the connector so an instant open is heard
  add_observer(handle, fn(event, model) {
    case event {
      MessageApplied(message:, origin: Dispatched) ->
        send_message(sync, message)
      _ -> Nil
    }
    sync_subscriptions(sync, model)
  })

  // replay an earlier page's offline queue, sent once the connection opens
  codec.when_registered(fn() {
    update_state(sync, fn(state) { SyncState(..state, replaying: True) })
    list.each(transport.pending(connector), fn(bytes) {
      replay(runtime, transport.decode(bytes, serialiser: sync.serialiser))
    })
    update_state(sync, fn(state) { SyncState(..state, replaying: False) })
  })

  let handler =
    transport.ConnectorHandler(
      received: fn(bytes) {
        codec.when_registered(fn() {
          handle_incoming(
            sync,
            transport.decode(bytes, serialiser: sync.serialiser),
          )
        })
      },
      opened: fn() { handle_opened(sync) },
      closed: fn() { handle_closed(sync) },
    )
  let connected = transport.run_connector(connector, handler)
  update_state(sync, fn(state) { SyncState(..state, channel: Some(connected)) })
  // a mismatch heard while connecting had no channel to close
  let state = sync_state(sync)
  case state.stopped {
    True -> connected.close()
    False ->
      list.each(list.reverse(state.waiting), fn(bytes) {
        let _ = connected.send(bytes)
        Nil
      })
  }
  update_state(sync, fn(state) { SyncState(..state, waiting: []) })
  runtime
}

@target(erlang)
fn connect_with(
  runtime: Runtime(model, message, Synced),
  _serialiser: transport.Serialiser(model, message),
  _connector: transport.Connector,
) -> Runtime(model, message, Synced) {
  runtime
}

fn embedded_snapshot(
  serialiser: transport.Serialiser(model, message),
) -> Result(model, Nil) {
  use text <- result.try(read_embedded_snapshot())
  use bytes <- result.try(bit_array.base64_decode(string.trim(text)))
  case transport.decode(bytes, serialiser:) {
    Ok(transport.Snapshot(target: transport.Session, state:, ..)) -> Ok(state)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

@target(javascript)
fn emit(handle: RuntimeHandle, event: ClientEvent(model, message)) -> Nil {
  run(handle, fn(model) { #(model, event) })
}

@target(javascript)
fn handle_closed(sync: SyncSession(model, message)) -> Nil {
  // an edit sent but unanswered may or may not have landed, so its slice no
  // longer matches what was confirmed, and the reconnect snapshot decides
  update_state(sync, fn(state) {
    let unsure =
      dict.filter(state.pending, fn(_target, queue) {
        list.any(queue.front, fn(entry) { entry.delivered })
        || list.any(queue.back, fn(entry) { entry.delivered })
      })
    SyncState(
      ..state,
      open: False,
      confirmed: dict.drop(state.confirmed, dict.keys(unsure)),
    )
  })
  update_pending(sync, list.filter(_, fn(entry) { !entry.delivered }))
  emit(sync.runtime.handle, ConnectionClosed)
}

@target(javascript)
fn handle_incoming(
  sync: SyncSession(model, message),
  frame: Result(transport.Protocol(model, message), Nil),
) -> Nil {
  use <- bool.guard(when: sync_state(sync).stopped, return: Nil)
  let handle = sync.runtime.handle
  case frame {
    // in step order
    Ok(transport.Acknowledge(target:, sequence:)) ->
      run_effect(handle, fn() {
        confirm(sync, target, sequence)
        settle(sync, target, dropped: False)
      })

    Ok(transport.Dropped(target:)) ->
      run_effect(handle, fn() { settle(sync, target, dropped: True) })

    Ok(transport.Connected(client_id:)) ->
      emit(handle, ClientIdAssigned(client_id:))

    // a late one for a topic left is ignored
    Ok(transport.TopicUpdate(topic_id:, payload:, sequence:)) ->
      case list.contains(sync_state(sync).subscribed, topic_id) {
        True -> apply_remote(sync, transport.Topic(topic_id), payload, sequence)
        False -> Nil
      }

    Ok(transport.SessionUpdate(payload:, sequence:)) ->
      apply_remote(sync, transport.Session, payload, sequence)

    Ok(transport.Unchanged(target:)) ->
      run_effect(handle, fn() {
        update_state(sync, fn(state) {
          SyncState(..state, resyncing: set.delete(state.resyncing, target))
        })
        emit(handle, SnapshotUnchanged(target:))
      })

    Ok(transport.Snapshot(target:, epoch:, sequence:, state:)) ->
      case target {
        transport.Topic(topic_id) ->
          case list.contains(sync_state(sync).subscribed, topic_id) {
            True -> {
              // a refused topic that came back has rejoined us
              update_state(sync, fn(current) {
                SyncState(
                  ..current,
                  rejected: set.delete(current.rejected, topic_id),
                )
              })
              rebase(sync, target, state, Confirmed(epoch:, sequence:))
            }
            False -> Nil
          }
        transport.Session ->
          rebase(sync, target, state, Confirmed(epoch:, sequence:))
      }

    Ok(transport.Rejected(topic_id:, reason:)) -> {
      update_state(sync, fn(state) {
        SyncState(
          ..state,
          rejected: set.insert(state.rejected, topic_id),
          confirmed: dict.delete(state.confirmed, transport.Topic(topic_id)),
        )
      })
      emit(handle, SubscriptionRejected(topic_id:, reason:))
    }

    Ok(transport.Version(hash:, protocol:)) ->
      case protocol == transport.protocol_version {
        True -> emit(handle, VersionAnnounced(hash:))
        False -> stop(sync, protocol)
      }

    // client-to-server variants, never legitimately arrive here
    Ok(transport.Resync(_))
    | Ok(transport.SessionMessage(_))
    | Ok(transport.Subscribe(_))
    | Ok(transport.TopicMessage(_, _))
    | Ok(transport.Unsubscribe(_)) -> Nil

    Error(Nil) ->
      emit(
        handle,
        Diagnostic(
          level: transport.Warning,
          message: "dropped a frame that failed to decode",
        ),
      )
  }
}

@target(javascript)
fn handle_opened(sync: SyncSession(model, message)) -> Nil {
  use <- bool.guard(when: sync_state(sync).stopped, return: Nil)
  let model = get_model(sync.runtime.handle)
  let wanted = wanted_topics(sync.runtime.store, model)
  // a reconnect asks again for refused topics and outstanding resyncs
  update_state(sync, fn(state) {
    SyncState(
      ..state,
      open: True,
      subscribed: wanted,
      subscribed_for: Some(model),
      rejected: set.new(),
      resyncing: set.new(),
    )
  })
  // first frame after an open, the offline queue flushes right behind it, a
  // slice still at its confirmed state may be answered `Unchanged`
  let confirmed = sync_state(sync).confirmed
  let cursor = fn(target) {
    case dict.get(confirmed, target) {
      Ok(Confirmed(epoch:, sequence:)) ->
        transport.Known(target:, epoch:, sequence:)
      Error(Nil) -> transport.Unknown(target:)
    }
  }
  let _ =
    send(
      sync,
      transport.Resync(cursors: [
        cursor(transport.Session),
        ..list.map(wanted, fn(topic_id) { cursor(transport.Topic(topic_id)) })
      ]),
    )
  update_pending(
    sync,
    list.map(_, fn(entry) { PendingMessage(..entry, delivered: True) }),
  )
  emit(sync.runtime.handle, ConnectionOpened)
}

// updates made meanwhile, a route or persisted field, wait and land on top of
// the snapshot rather than under it
@target(javascript)
fn hydrate(
  handle: RuntimeHandle,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  hold_steps(handle)
  codec.when_registered(fn() {
    case embedded_snapshot(serialiser) {
      Ok(state) -> set_model(handle, state)
      Error(Nil) -> Nil
    }
    release_steps(handle)
    initial_notify(handle)
  })
}

@target(erlang)
fn hydrate(
  handle: RuntimeHandle,
  serialiser: transport.Serialiser(model, message),
) -> Nil {
  codec.when_registered(fn() {
    case embedded_snapshot(serialiser) {
      Ok(state) -> set_model(handle, state)
      Error(Nil) -> Nil
    }
    initial_notify(handle)
  })
}

// out of step, so no longer what was confirmed either
@target(javascript)
fn mark_diverged(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
) -> Nil {
  update_state(sync, fn(state) {
    SyncState(
      ..state,
      diverged: set.insert(state.diverged, target),
      confirmed: dict.delete(state.confirmed, target),
    )
  })
}

@target(javascript)
fn observing(
  runtime: Runtime(model, message, mode),
  observer: fn(ClientEvent(model, message), model) -> Nil,
) -> Runtime(model, message, mode) {
  add_observer(runtime.handle, observer)
  runtime
}

@target(erlang)
fn observing(
  runtime: Runtime(model, message, mode),
  _observer: fn(ClientEvent(model, message), model) -> Nil,
) -> Runtime(model, message, mode) {
  runtime
}

// oldest first
@target(javascript)
fn pending_messages(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
) -> List(message) {
  case dict.get(sync_state(sync).pending, target) {
    Ok(PendingQueue(front:, back:)) ->
      list.fold(back, [], fn(newer, entry) { [entry.message, ..newer] })
      |> list.append(list.map(front, fn(entry) { entry.message }), _)
    Error(Nil) -> []
  }
}

@target(javascript)
fn queue_is_empty(queue: PendingQueue(message)) -> Bool {
  queue.front == [] && queue.back == []
}

// the server's slice with our unconfirmed edits replayed on top
@target(javascript)
fn rebase(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  state: model,
  confirmed: Confirmed,
) -> Nil {
  let app_store = sync.runtime.store
  let update = store.update_function(app_store)
  run(sync.runtime.handle, fn(current) {
    // an edit that crashes on the new state is skipped, the rest still land
    let rebased = case store.has_slice(app_store, target) {
      True ->
        list.fold(
          pending_messages(sync, target),
          store.merge_snapshot(app_store, target, current, state),
          fn(model, message) {
            actor.rescue(fn() { update(model, message) })
            |> result.unwrap(model)
          },
        )
      False -> current
    }
    update_state(sync, fn(state) {
      SyncState(
        ..state,
        diverged: set.delete(state.diverged, target),
        resyncing: set.delete(state.resyncing, target),
        confirmed: dict.insert(state.confirmed, target, confirmed),
      )
    })
    #(rebased, SnapshotApplied(target:, previous: current))
  })
}

// only client-to-server message frames are queued
@target(javascript)
fn replay(
  runtime: Runtime(model, message, Synced),
  frame: Result(transport.Protocol(model, message), Nil),
) -> Nil {
  case frame {
    Ok(transport.SessionMessage(payload:))
    | Ok(transport.TopicMessage(payload:, ..)) ->
      apply_message(runtime, payload, Dispatched)

    Ok(transport.Acknowledge(..))
    | Ok(transport.Connected(..))
    | Ok(transport.Dropped(..))
    | Ok(transport.Rejected(..))
    | Ok(transport.Resync(..))
    | Ok(transport.SessionUpdate(..))
    | Ok(transport.Snapshot(..))
    | Ok(transport.Subscribe(..))
    | Ok(transport.TopicUpdate(..))
    | Ok(transport.Unchanged(..))
    | Ok(transport.Unsubscribe(..))
    | Ok(transport.Version(..)) -> Nil

    Error(Nil) ->
      emit(
        runtime.handle,
        Diagnostic(
          level: transport.Warning,
          message: "dropped an unreadable frame from the offline queue",
        ),
      )
  }
}

// waits until every edit is answered, an earlier snapshot would miss some
@target(javascript)
fn resync_if_settled(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
) -> Nil {
  let state = sync_state(sync)
  case
    dict.has_key(state.pending, target),
    set.contains(state.diverged, target),
    state.open
  {
    False, True, True -> {
      // a resync of a topic not joined, or refused, would join it, and one
      // already out covers this
      let joined = case target {
        transport.Session -> True
        transport.Topic(id) ->
          list.contains(state.subscribed, id)
          && !set.contains(state.rejected, id)
      }
      let asking = joined && !set.contains(state.resyncing, target)
      update_state(sync, fn(state) {
        let resyncing = case asking {
          True -> set.insert(state.resyncing, target)
          False -> state.resyncing
        }
        SyncState(
          ..state,
          diverged: set.delete(state.diverged, target),
          resyncing:,
        )
      })
      case asking {
        True -> {
          let _ =
            send(sync, transport.Resync(cursors: [transport.Unknown(target:)]))
          Nil
        }
        False -> Nil
      }
    }
    _, _, _ -> Nil
  }
}

// True if sent or queued
@target(javascript)
fn send(
  sync: SyncSession(model, message),
  frame: transport.Protocol(model, message),
) -> Bool {
  send_frame(sync, frame) == SentOrQueued
}

@target(javascript)
fn send_frame(
  sync: SyncSession(model, message),
  frame: transport.Protocol(model, message),
) -> Sending {
  use <- bool.guard(when: sync_state(sync).stopped, return: Unsent)
  case
    actor.rescue(fn() { transport.encode(frame, serialiser: sync.serialiser) })
  {
    Error(reason) -> {
      actor.log(transport.Failure, "lily: a frame failed to encode: " <> reason)
      Unencodable
    }
    Ok(bytes) ->
      case sync_state(sync).channel {
        Some(channel) ->
          // a custom channel's send can throw, that frame didn't go out
          case actor.rescue(fn() { channel.send(bytes) }) {
            Ok(Ok(Nil)) -> SentOrQueued
            Ok(Error(Nil)) | Error(_) -> Unsent
          }
        None -> {
          update_state(sync, fn(state) {
            SyncState(..state, waiting: [bytes, ..state.waiting])
          })
          SentOrQueued
        }
      }
  }
}

// `Local` messages stay on this client
@target(javascript)
fn send_message(sync: SyncSession(model, message), message: message) -> Nil {
  let target = case store.route(sync.runtime.store, message) {
    store.Local -> None
    store.Session -> Some(transport.Session)
    store.Topic(id) -> Some(transport.Topic(id))
  }
  let state = sync_state(sync)
  case target, state.replaying {
    None, _ -> Nil
    // already in the connector's queue
    Some(target), True -> track(sync, target, message, delivered: state.open)
    Some(transport.Session), False -> {
      warn_if_no_session(sync)
      sent(sync, transport.Session, message, transport.SessionMessage(message))
    }
    Some(transport.Topic(id) as target), False ->
      sent(sync, target, message, transport.TopicMessage(id, message))
  }
}

@target(javascript)
fn sent(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  message: message,
  frame: transport.Protocol(model, message),
) -> Nil {
  case send_frame(sync, frame), sync.queues {
    SentOrQueued, _ -> track(sync, target, message, delivered: True)
    Unsent, True -> track(sync, target, message, delivered: False)
    // lost, never queued either, needs a snapshot
    Unsent, False | Unencodable, _ -> {
      mark_diverged(sync, target)
      resync_if_settled(sync, target)
    }
  }
}

// a stopping topic's last `Acknowledge` may find nothing pending
@target(javascript)
fn settle(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  dropped dropped: Bool,
) -> Nil {
  update_target(sync, target, fn(queue) {
    case queue.front {
      [_, ..front] -> PendingQueue(..queue, front:)
      [] ->
        PendingQueue(front: list.drop(list.reverse(queue.back), 1), back: [])
    }
  })
  case dropped {
    True -> mark_diverged(sync, target)
    False -> Nil
  }
  resync_if_settled(sync, target)
}

// for good, the server may misread anything sent
@target(javascript)
fn stop(sync: SyncSession(model, message), server: Int) -> Nil {
  update_state(sync, fn(state) {
    SyncState(..state, stopped: True, open: False)
  })
  case sync_state(sync).channel {
    Some(channel) -> channel.close()
    None -> Nil
  }
  let client = transport.protocol_version
  let message =
    "lily: the server speaks wire protocol "
    <> int.to_string(server)
    <> " but this page speaks "
    <> int.to_string(client)
    <> ", the connection is closed until the page reloads"
  actor.log(transport.Failure, message)
  emit(sync.runtime.handle, ProtocolMismatch(server:, client:))
  emit(sync.runtime.handle, Diagnostic(level: transport.Failure, message:))
}

@target(javascript)
fn sync_state(sync: SyncSession(model, message)) -> SyncState(model, message) {
  actor.box_get(sync.state)
}

// subscriptions are worked out from the model, the same one wants the same
@target(javascript)
fn sync_subscriptions(sync: SyncSession(model, message), model: model) -> Nil {
  let state = sync_state(sync)
  let unchanged = case state.subscribed_for {
    Some(seen) -> is_same(seen, model)
    None -> False
  }
  use <- bool.guard(when: !state.open || unchanged, return: Nil)
  let wanted = wanted_topics(sync.runtime.store, model)
  let before = state.subscribed
  let left = case wanted == before {
    True -> []
    False -> {
      list.each(wanted, fn(topic_id) {
        case list.contains(before, topic_id) {
          True -> Nil
          False -> {
            let _ = send(sync, transport.Subscribe(topic_id:))
            Nil
          }
        }
      })
      list.filter(before, fn(topic_id) {
        case list.contains(wanted, topic_id) {
          True -> False
          // the server never held a refused one, and wanting it again asks
          // afresh
          False ->
            case set.contains(state.rejected, topic_id) {
              True -> True
              False -> {
                let _ = send(sync, transport.Unsubscribe(topic_id:))
                False
              }
            }
        }
      })
    }
  }
  // a topic left gets no updates, what it held stops being current
  let unwanted =
    list.filter(before, fn(topic_id) { !list.contains(wanted, topic_id) })
    |> list.map(transport.Topic)
  update_state(sync, fn(state) {
    SyncState(
      ..state,
      subscribed: wanted,
      subscribed_for: Some(model),
      rejected: set.drop(state.rejected, left),
      confirmed: dict.drop(state.confirmed, unwanted),
    )
  })
}

@target(javascript)
fn track(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  message: message,
  delivered delivered: Bool,
) -> Nil {
  update_target(sync, target, fn(queue) {
    PendingQueue(..queue, back: [
      PendingMessage(message:, delivered:),
      ..queue.back
    ])
  })
}

// `change` maps or filters, each half keeps its own order
@target(javascript)
fn update_pending(
  sync: SyncSession(model, message),
  change: fn(List(PendingMessage(message))) -> List(PendingMessage(message)),
) -> Nil {
  update_state(sync, fn(state) {
    let pending =
      state.pending
      |> dict.map_values(fn(_target, queue) {
        PendingQueue(front: change(queue.front), back: change(queue.back))
      })
      |> dict.filter(fn(_target, queue) { !queue_is_empty(queue) })
    SyncState(..state, pending:)
  })
}

@target(javascript)
fn update_state(
  sync: SyncSession(model, message),
  change: fn(SyncState(model, message)) -> SyncState(model, message),
) -> Nil {
  actor.box_set(sync.state, change(actor.box_get(sync.state)))
}

@target(javascript)
fn update_target(
  sync: SyncSession(model, message),
  target: transport.SyncTarget,
  change: fn(PendingQueue(message)) -> PendingQueue(message),
) -> Nil {
  update_state(sync, fn(state) {
    let queue =
      dict.get(state.pending, target)
      |> result.unwrap(PendingQueue(front: [], back: []))
      |> change
    let pending = case queue_is_empty(queue) {
      True -> dict.delete(state.pending, target)
      False -> dict.insert(state.pending, target, queue)
    }
    SyncState(..state, pending:)
  })
}

@target(javascript)
fn wanted_topics(
  app_store: Store(model, message, mode),
  model: model,
) -> List(String) {
  store.subscriptions_of(app_store, model) |> list.unique
}

// warns once, without `store.session` the server's copy never comes back
@target(javascript)
fn warn_if_no_session(sync: SyncSession(model, message)) -> Nil {
  case
    store.has_session(sync.runtime.store),
    sync_state(sync).warned_no_session
  {
    True, _ | False, True -> Nil
    False, False -> {
      update_state(sync, fn(state) {
        SyncState(..state, warned_no_session: True)
      })
      let message =
        "lily: a message was routed to store.Session but the store declares no "
        <> "store.session, meaning session snapshots from the server are "
        <> "dropped"
      actor.log(transport.Warning, message)
      emit(sync.runtime.handle, Diagnostic(level: transport.Warning, message:))
    }
  }
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

@target(javascript)
@external(javascript, "./client.ffi.mjs", "addObserver")
fn add_observer(
  handle: RuntimeHandle,
  observer: fn(ClientEvent(model, message), model) -> Nil,
) -> Nil

// on Erlang the handle is just the model
@external(erlang, "lily_codec_ffi", "passthrough")
@external(javascript, "./client.ffi.mjs", "createRuntime")
fn create_runtime(model: model) -> RuntimeHandle

@external(erlang, "lily_codec_ffi", "passthrough")
@external(javascript, "./client.ffi.mjs", "getModel")
fn get_model(handle: RuntimeHandle) -> model

// holds queued steps until `release_steps`
@target(javascript)
@external(javascript, "./client.ffi.mjs", "holdSteps")
fn hold_steps(handle: RuntimeHandle) -> Nil

@external(javascript, "./client.ffi.mjs", "initialNotify")
fn initial_notify(_handle: RuntimeHandle) -> Nil {
  Nil
}

// by reference, a deep compare would walk an equal model
@target(javascript)
@external(javascript, "./client.ffi.mjs", "isSame")
fn is_same(left: model, right: model) -> Bool

// `True` when it was connected already
@target(javascript)
@external(javascript, "./client.ffi.mjs", "markConnected")
fn mark_connected(handle: RuntimeHandle) -> Bool

@external(javascript, "./client.ffi.mjs", "readEmbeddedSnapshot")
fn read_embedded_snapshot() -> Result(String, Nil) {
  Error(Nil)
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "releaseSteps")
fn release_steps(handle: RuntimeHandle) -> Nil

@external(javascript, "./client.ffi.mjs", "run")
fn run(
  _handle: RuntimeHandle,
  _step: fn(model) -> #(model, ClientEvent(model, message)),
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./client.ffi.mjs", "runEffect")
fn run_effect(handle: RuntimeHandle, effect: fn() -> Nil) -> Nil

@external(javascript, "./client.ffi.mjs", "setModel")
fn set_model(_handle: RuntimeHandle, _model: model) -> Nil {
  Nil
}
