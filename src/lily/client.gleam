//// The client owns the browser-side [`Runtime`](#Runtime), pretty much
//// everything that makes a Lily app tick in the page. The update loop,
//// component subscriptions, and (once a transport is connected) keeping your
//// model in sync with the server all live here. A connector can hold messages
//// while you're disconnected and replay them the moment the server is back,
//// see [`with_offline_queue`](./transport.html#with_offline_queue). This
//// module is browser-only, Erlang need not apply.
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
////     to_slot: fn() { element.element("lily-slot", [], []) },
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

@target(javascript)
import gleam/bit_array
@target(javascript)
import gleam/bool
@target(javascript)
import gleam/list
@target(javascript)
import gleam/option.{type Option, None, Some}
@target(javascript)
import gleam/result
@target(javascript)
import gleam/string
@target(javascript)
import lily/internal/actor.{type Box}
@target(javascript)
import lily/internal/codec
@target(javascript)
import lily/store.{type Store, type Synced}
@target(javascript)
import lily/transport

// =============================================================================
// PUBLIC TYPES
// =============================================================================

@target(javascript)
/// Something that happened to the runtime, given to every observer
/// registered with [`observe`](#observe).
///
/// Match the variants you care about and ignore the rest with a catch-all, new
/// variants are not a breaking change.
pub type ClientEvent(model, message) {
  /// `update` ran for a message, from this client or from a server frame
  MessageApplied(message: message, origin: Origin)
  /// The server replaced a slice of the model, `previous` is the model before
  SnapshotApplied(target: transport.Target, previous: model)
  /// [`update_model`](#update_model) ran
  ModelUpdated
  /// The connection opened, including the first time
  ConnectionOpened
  /// The connection dropped
  ConnectionClosed
  /// The server gave this client an id, on every connect and reconnect
  ClientIdAssigned(client_id: String)
  /// The server's build version, on every connect and reconnect
  VersionAnnounced(hash: String)
  /// The server refused a subscription
  SubscriptionRejected(topic_id: String, reason: String)
  /// A warning from Lily itself
  Diagnostic(level: transport.Level, message: String)
}

@target(javascript)
/// Where an applied message came from.
pub type Origin {
  /// Dispatched on this client, through [`dispatch`](#dispatch) or a listener
  Dispatched
  /// Arrived from the server
  Received
}

@target(javascript)
/// A running Lily app, from [`start`](#start).
pub opaque type Runtime(model, message, mode) {
  Runtime(handle: RuntimeHandle, store: Store(model, message, mode))
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

@target(javascript)
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
  runtime
}

@target(javascript)
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

@target(javascript)
/// The current model.
///
/// ```gleam
/// let count = client.model(runtime).count
/// ```
pub fn model(runtime: Runtime(model, message, mode)) -> model {
  get_model(runtime.handle)
}

@target(javascript)
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
  add_observer(runtime.handle, observer)
  runtime
}

@target(javascript)
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
///   to_slot: fn() { element.element("lily-slot", [], []) },
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
    Ok(serialiser) ->
      codec.when_registered(fn() {
        case embedded_snapshot(serialiser) {
          Ok(state) -> set_model(handle, state)
          Error(Nil) -> Nil
        }
        initial_notify(handle)
      })
  }
  Runtime(handle:, store:)
}

@target(javascript)
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
// PRIVATE TYPES
// =============================================================================

@target(javascript)
type RuntimeHandle

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

@target(javascript)
fn apply_message(
  runtime: Runtime(model, message, mode),
  message: message,
  origin: Origin,
) -> Nil {
  let update = store.update_function(runtime.store)
  run(runtime.handle, fn(model) {
    #(update(model, message), MessageApplied(message:, origin:))
  })
}

@target(javascript)
fn connect_with(
  runtime: Runtime(model, message, Synced),
  serialiser: transport.Serialiser(model, message),
  connector: transport.Connector,
) -> Nil {
  let app_store = runtime.store
  let handle = runtime.handle
  // `ByHost` settles here once, decoding reads either format
  let serialiser = transport.resolve_for_page(serialiser)

  // frames sent before `run_connector` returns the channel wait here
  let channel: Box(Option(transport.Channel)) = actor.box_new(None)
  let waiting = actor.box_new([])
  let send = fn(frame: transport.Protocol(model, message)) {
    let bytes = transport.encode(frame, serialiser:)
    case actor.box_get(channel) {
      Some(channel) -> {
        let _ = channel.send(bytes)
        Nil
      }
      None -> actor.box_set(waiting, [bytes, ..actor.box_get(waiting)])
    }
  }

  // a plain observer, added before the connector so an instant open is heard
  let replaying = actor.box_new(False)
  let warned_no_session = actor.box_new(False)
  let open = actor.box_new(False)
  let subscribed = actor.box_new([])
  add_observer(handle, fn(event, model) {
    case event {
      // `Local` messages stay on this client
      MessageApplied(message:, origin: Dispatched) ->
        case actor.box_get(replaying), store.route(app_store, message) {
          True, _ | _, store.Local -> Nil
          False, store.Session -> {
            warn_if_no_session(handle, app_store, warned_no_session)
            send(transport.SessionMessage(payload: message))
          }
          False, store.Topic(id) ->
            send(transport.TopicMessage(topic_id: id, payload: message))
        }
      ConnectionOpened -> {
        actor.box_set(open, True)
        // fresh client id, meaning the server hears all this client wants
        let wanted = wanted_topics(app_store, model)
        send(
          transport.Resync(cursors: [
            transport.Session,
            ..list.map(wanted, transport.Topic)
          ]),
        )
        actor.box_set(subscribed, wanted)
      }
      ConnectionClosed -> actor.box_set(open, False)
      _ -> Nil
    }
    case actor.box_get(open) {
      True -> sync_subscriptions(app_store, model, subscribed, send)
      False -> Nil
    }
  })

  // replay an earlier page's offline queue, sent once the connection opens
  codec.when_registered(fn() {
    actor.box_set(replaying, True)
    list.each(transport.pending(connector), fn(bytes) {
      replay(runtime, transport.decode(bytes, serialiser:))
    })
    actor.box_set(replaying, False)
  })

  let handler =
    transport.Handler(
      received: fn(bytes) {
        codec.when_registered(fn() {
          handle_incoming(runtime, transport.decode(bytes, serialiser:))
        })
      },
      opened: fn() { emit(handle, ConnectionOpened) },
      closed: fn() { emit(handle, ConnectionClosed) },
    )
  let connected = transport.run_connector(connector, handler)
  actor.box_set(channel, Some(connected))
  list.each(list.reverse(actor.box_get(waiting)), fn(bytes) {
    let _ = connected.send(bytes)
    Nil
  })
  actor.box_set(waiting, [])
}

@target(javascript)
fn embedded_snapshot(
  serialiser: transport.Serialiser(model, message),
) -> Result(model, Nil) {
  use text <- result.try(read_embedded_snapshot())
  use bytes <- result.try(bit_array.base64_decode(string.trim(text)))
  case transport.decode(bytes, serialiser:) {
    Ok(transport.Snapshot(target: transport.Session, sequence: _, state:)) ->
      Ok(state)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

@target(javascript)
fn emit(handle: RuntimeHandle, event: ClientEvent(model, message)) -> Nil {
  run(handle, fn(model) { #(model, event) })
}

@target(javascript)
fn handle_incoming(
  runtime: Runtime(model, message, Synced),
  frame: Result(transport.Protocol(model, message), Nil),
) -> Nil {
  let handle = runtime.handle
  case frame {
    // nothing waits on acks client-side
    Ok(transport.Acknowledge(..)) -> Nil

    Ok(transport.Connected(client_id:)) ->
      emit(handle, ClientIdAssigned(client_id:))

    Ok(transport.TopicUpdate(payload:, ..))
    | Ok(transport.SessionUpdate(payload:, ..)) ->
      apply_message(runtime, payload, Received)

    Ok(transport.Snapshot(target:, state:, ..)) ->
      run(handle, fn(current) {
        let merged = store.merge_snapshot(runtime.store, target, current, state)
        #(merged, SnapshotApplied(target:, previous: current))
      })

    Ok(transport.Rejected(topic_id:, reason:)) ->
      emit(handle, SubscriptionRejected(topic_id:, reason:))

    Ok(transport.Version(hash:)) -> emit(handle, VersionAnnounced(hash:))

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
    | Ok(transport.Rejected(..))
    | Ok(transport.Resync(..))
    | Ok(transport.SessionUpdate(..))
    | Ok(transport.Snapshot(..))
    | Ok(transport.Subscribe(..))
    | Ok(transport.TopicUpdate(..))
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

@target(javascript)
fn sync_subscriptions(
  app_store: Store(model, message, mode),
  model: model,
  subscribed: Box(List(String)),
  send: fn(transport.Protocol(model, message)) -> Nil,
) -> Nil {
  let wanted = wanted_topics(app_store, model)
  let before = actor.box_get(subscribed)
  use <- bool.guard(when: wanted == before, return: Nil)
  list.each(wanted, fn(topic_id) {
    case list.contains(before, topic_id) {
      True -> Nil
      False -> send(transport.Subscribe(topic_id:))
    }
  })
  list.each(before, fn(topic_id) {
    case list.contains(wanted, topic_id) {
      True -> Nil
      False -> send(transport.Unsubscribe(topic_id:))
    }
  })
  actor.box_set(subscribed, wanted)
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
fn warn_if_no_session(
  handle: RuntimeHandle,
  app_store: Store(model, message, Synced),
  warned: Box(Bool),
) -> Nil {
  case store.has_session(app_store), actor.box_get(warned) {
    True, _ | False, True -> Nil
    False, False -> {
      actor.box_set(warned, True)
      let message =
        "lily: a message was routed to store.Session but the store declares no "
        <> "store.session, so session snapshots from the server are dropped"
      actor.log(transport.Warning, message)
      emit(handle, Diagnostic(level: transport.Warning, message:))
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

@target(javascript)
@external(javascript, "./client.ffi.mjs", "createRuntime")
fn create_runtime(model: model) -> RuntimeHandle

@target(javascript)
@external(javascript, "./client.ffi.mjs", "getModel")
fn get_model(handle: RuntimeHandle) -> model

@target(javascript)
@external(javascript, "./client.ffi.mjs", "initialNotify")
fn initial_notify(handle: RuntimeHandle) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "readEmbeddedSnapshot")
fn read_embedded_snapshot() -> Result(String, Nil)

@target(javascript)
@external(javascript, "./client.ffi.mjs", "run")
fn run(
  handle: RuntimeHandle,
  step: fn(model) -> #(model, ClientEvent(model, message)),
) -> Nil

@target(javascript)
@external(javascript, "./client.ffi.mjs", "setModel")
fn set_model(handle: RuntimeHandle, model: model) -> Nil
