//// Session persistence allows certain model fields to survive page navigations
//// via `localStorage`. This lets users carry authentication tokens,
//// preferences, shopping cart data, and other session state across page loads
//// without cookies. In Phoenix LiveView, the socket holds this persistence,
//// and in some other frameworks, this may be purely server-side.
////
//// Session data is stored as individual fields in `localStorage` with the
//// prefix `lily_session_`. Each field has its own encoder/decoder for
//// type-safe serialisation.
////
//// Unlike the page store (which tears down on navigation), session data
//// persists until explicitly cleared or expired.
////

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleam/dynamic/decode
@target(javascript)
import gleam/json.{type Json}
@target(javascript)
import gleam/list
@target(javascript)
import lily/client.{type Runtime}

// =============================================================================
// PUBLIC TYPES
// =============================================================================

/// Configuration for a single persisted field within the session.
@target(javascript)
pub opaque type Field(session) {
  Field(
    key: String,
    get: fn(session) -> Json,
    set: fn(session, Json) -> Result(session, Nil),
  )
}

/// Complete session persistence configuration. Build using
/// [`session.persistence`](#persistence) and add fields with
/// [`session.field`](#field).
@target(javascript)
pub opaque type Persistence(session) {
  Persistence(fields: List(Field(session)))
}

// =============================================================================
// PUBLIC FUNCTIONS
// =============================================================================

/// Attach session persistence to the runtime. Reads `localStorage` on start to
/// hydrate the initial model, then writes changes to `localStorage` after each
/// update. The `get` and `set` functions extract and inject the session slice
/// from the model. The session data can be stored within your model for access.
/// How you choose to do this is completely up to you, as `session.attach` only
/// needs `get` and `set` functions as parameters.
///
/// Call this after creating the store but before `client.start`, or in the
/// pipe chain after `client.start`.
///
/// ## Example
///
/// ```gleam
/// let persistence =
///   session.persistence()
///   |> session.field(
///     key: "token",
///     get: fn(session) { session.token },
///     set: fn(session, value) { SessionData(..session, token: value) },
///     encode: json.nullable(json.string),
///     decoder: decode.optional(decode.string),
///   )
///
/// store.new(Model(session: empty_session, ..), with: update)
/// |> session.attach(
///   persistence:,
///   get: fn(model) { model.session },
///   set: fn(model, session) { Model(..model, session: session) },
/// )
/// |> client.start
/// ```
@target(javascript)
pub fn attach(
  runtime: Runtime(model, message),
  persistence persistence: Persistence(session),
  get get: fn(model) -> session,
  set set: fn(model, session) -> model,
) -> Runtime(model, message) {
  // Hydrate session from localStorage
  let current_model = client.get_current_model(runtime)
  let hydrated_session = hydrate_session(persistence, get(current_model))
  let hydrated_model = set(current_model, hydrated_session)
  client.set_current_model(runtime, hydrated_model)

  // Store persistence config on runtime for post-update hooks
  let handle = client.get_handle(runtime)
  set_session_config(handle, persistence, get, set)

  runtime
}

/// Clear all session data from `localStorage`. Removes all keys with the
/// `lily_session_` prefix.
///
/// ## Example
///
/// ```gleam
/// // On logout
/// fn update(model, msg) {
///   case msg {
///     Logout -> {
///       session.clear()
///       // Navigate to login page or clear session in model
///       model
///     }
///     _ -> model
///   }
/// }
/// ```
@target(javascript)
pub fn clear() -> Nil {
  clear_session(storage_prefix())
}

/// Add a field to the session persistence configuration. Each field represents
/// a single value stored in `localStorage` under `lily_session_{key}`.
///
/// The `get` and `set` functions extract and inject the field from the session
/// type. The `encode` and `decoder` handle JSON serialisation.
///
/// ## Example
///
/// ```gleam
/// session.persistence()
/// |> session.field(
///   key: "theme",
///   get: fn(session) { session.theme },
///   set: fn(session, theme) { SessionData(..session, theme: theme) },
///   encode: theme_to_json,
///   decoder: theme_decoder,
/// )
/// ```
@target(javascript)
pub fn field(
  persistence: Persistence(session),
  key key: String,
  get get: fn(session) -> a,
  set set: fn(session, a) -> session,
  encode encode: fn(a) -> Json,
  decoder decoder: decode.Decoder(a),
) -> Persistence(session) {
  let Persistence(fields) = persistence

  let field =
    Field(
      key: key,
      get: fn(session) { encode(get(session)) },
      set: fn(session, json_value) {
        case json.parse(from: json.to_string(json_value), using: decoder) {
          Ok(value) -> Ok(set(session, value))
          Error(_) -> Error(Nil)
        }
      },
    )

  Persistence(fields: [field, ..fields])
}

/// Create an empty session persistence configuration. Add fields using
/// [`session.field`](#field).
///
/// ## Example
///
/// ```gleam
/// let persistence = session.persistence()
/// ```
@target(javascript)
pub fn persistence() -> Persistence(session) {
  Persistence(fields: [])
}

// =============================================================================
// PRIVATE FUNCTIONS
// =============================================================================

/// Hydrate session from localStorage
@target(javascript)
fn hydrate_session(
  persistence: Persistence(session),
  initial: session,
) -> session {
  let Persistence(fields) = persistence

  // Read each field from localStorage and apply to session
  list.fold(fields, initial, fn(session, field) {
    let Field(key, _get, set) = field
    case read_field(storage_prefix(), key) {
      Ok(json_value) ->
        case set(session, json_value) {
          Ok(updated) -> updated
          Error(_) -> session
        }
      Error(_) -> session
    }
  })
}

/// Get the storage key prefix
@target(javascript)
fn storage_prefix() -> String {
  "lily_session_"
}

// =============================================================================
// PRIVATE FFI
// =============================================================================

/// Clear session from localStorage
@target(javascript)
@external(javascript, "./session.ffi.mjs", "clearSession")
fn clear_session(_prefix: String) -> Nil {
  Nil
}

/// Read a field from localStorage
@target(javascript)
@external(javascript, "./session.ffi.mjs", "readField")
fn read_field(_prefix: String, _key: String) -> Result(Json, Nil) {
  Error(Nil)
}

/// Store session config on runtime
@target(javascript)
@external(javascript, "./session.ffi.mjs", "setSessionConfig")
fn set_session_config(
  _handle: client.RuntimeHandle,
  _persistence: Persistence(session),
  _get: fn(model) -> session,
  _set: fn(model, session) -> model,
) -> Nil {
  Nil
}
