// browser functions are no-ops on erlang

@target(erlang)
import gleam/dynamic/decode
@target(erlang)
import gleam/json

@target(erlang)
import gleeunit/should

@target(erlang)
import lily/browser
@target(erlang)
import lily/client
@target(erlang)
import lily/component
@target(erlang)
import lily/store
@target(erlang)
import lily/transport

@target(erlang)
type Message {
  Increment
}

@target(erlang)
fn update(model: Int, message: Message) -> Int {
  case message {
    Increment -> model + 1
  }
}

@target(erlang)
fn counter_field() -> browser.PersistedField(Int) {
  browser.persisted_field(
    key: "count",
    encode: json.int,
    decode: decode.int,
    get: fn(model) { model },
    set: fn(_model, count) { count },
  )
}

@target(erlang)
pub fn runtime_keeps_the_initial_model_test() {
  let runtime =
    store.new(init: 3, update:)
    |> store.sync(route: fn(_) { store.Session }, modules: [])
    |> client.start
    |> client.observe(fn(_event, _model) { should.fail() })
    |> browser.url(set: fn(_model, _uri) { 0 })
    |> browser.intercept_links
    |> browser.persist(fields: [counter_field()])
    |> browser.connection_status(set: fn(_model, _connected) { 0 })
    |> browser.reload_on_new_version
    |> browser.hot_reload
    |> browser.visibility(set: fn(_model, _visible) { 0 })
    |> browser.network(set: fn(_model, _online) { 0 })
    |> browser.viewport(set: fn(_model, _size) { 0 })
    |> browser.confirm_leaving(when: fn(_model) { True })
    |> component.mount(
      selector: "#app",
      to_html: fn(html) { html },
      to_placeholder: fn() { "<lily-nest></lily-nest>" },
      view: fn(_model) { component.static(fn(_nest) { "<p></p>" }) },
    )
    |> client.connect(with: transport.websocket("/ws"))

  client.dispatch(runtime)(Increment)
  client.update_model(runtime, with: fn(_model) { 0 }) |> should.equal(Nil)

  client.model(runtime) |> should.equal(3)
}

@target(erlang)
pub fn page_functions_do_nothing_test() {
  browser.navigate("/a") |> should.equal(Nil)
  browser.replace("/b") |> should.equal(Nil)
  browser.load("/c") |> should.equal(Nil)
  browser.load_external("https://example.com") |> should.equal(Nil)
  browser.reload() |> should.equal(Nil)
  browser.clear_persisted() |> should.equal(Nil)
  browser.recover_after_reload(7) |> should.equal(7)
}
