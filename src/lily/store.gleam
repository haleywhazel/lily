// IMPORTS

import gleam/dict.{type Dict}
import gleam/list

// PUBLIC TYPES

pub type Store(model, msg) {
  Store(
    model: model,
    updater: fn(model, msg) -> model,
    handlers: Dict(Int, fn(model) -> Nil),
    next_id: Int,
  )
}

// PUBLIC FUNCTIONS

pub fn apply(store: Store(model, msg), msg msg: msg) -> Store(model, msg) {
  let new_model = store.updater(store.model, msg)
  Store(..store, model: new_model)
}

pub fn dispatch(
  store: Store(model, msg),
  new_model model: model,
) -> Store(model, msg) {
  let new_store = Store(..store, model: model)
  notify_handlers(new_store)

  new_store
}

pub fn get_model(store: Store(model, msg)) -> model {
  store.model
}

pub fn new(
  initial_model model: model,
  with updater: fn(model, msg) -> model,
) -> Store(model, msg) {
  Store(model: model, updater: updater, handlers: dict.new(), next_id: 0)
}

pub fn notify(store: Store(model, msg)) -> Nil {
  notify_handlers(store)
}

pub fn send(store: Store(model, msg), msg msg: msg) -> Store(model, msg) {
  let new_model = store.updater(store.model, msg)
  dispatch(store, new_model)
}

pub fn subscribe(
  store: Store(model, msg),
  with handler: fn(model) -> Nil,
) -> #(Store(model, msg), Int) {
  let id = store.next_id
  let updated_handlers = dict.insert(store.handlers, id, handler)
  let updated_next_id = store.next_id + 1
  let updated_store =
    Store(..store, handlers: updated_handlers, next_id: updated_next_id)

  #(updated_store, id)
}

pub fn unsubscribe(store: Store(model, msg), id: Int) -> Store(model, msg) {
  let updated_handlers = dict.delete(store.handlers, id)

  Store(..store, handlers: updated_handlers)
}

// PRIVATE FUNCTIONS

fn notify_handlers(store: Store(model, msg)) -> Nil {
  dict.values(store.handlers)
  |> list.each(fn(handler) { handler(store.model) })
}
