// client on the JSON envelope built with transport.serialiser

// =============================================================================
// IMPORTS
// =============================================================================

@target(javascript)
import gleeunit/should

@target(javascript)
import lily/client
@target(javascript)
import lily/test_support.{Increment}
@target(javascript)
import lily/transport

// =============================================================================
// CLIENT
// =============================================================================

@target(javascript)
pub fn open_serialiser_client_sends_json_frames_test() {
  test_support.reset_dom()
  let runtime = client.start(test_support.session_store())
  let #(_handler, sent) = test_support.connect_capturing(runtime)

  client.dispatch(runtime)(Increment)

  sent()
  |> should.equal([transport.SessionMessage(payload: Increment)])
}

@target(javascript)
pub fn open_serialiser_client_applies_a_snapshot_test() {
  test_support.reset_dom()
  let runtime = client.start(test_support.session_store())
  let #(handler, _sent) = test_support.connect_capturing(runtime)
  let state = test_support.Model(..test_support.initial_model(), count: 7)

  handler.received(transport.encode(
    transport.Snapshot(target: transport.Session, epoch: 0, sequence: 1, state:),
    serialiser: test_support.custom_serialiser(),
  ))

  client.model(runtime)
  |> should.equal(state)
}

@target(javascript)
pub fn open_serialiser_client_applies_a_session_update_test() {
  test_support.reset_dom()
  let runtime = client.start(test_support.session_store())
  let #(handler, _sent) = test_support.connect_capturing(runtime)

  handler.received(transport.encode(
    transport.SessionUpdate(sequence: 1, payload: Increment),
    serialiser: test_support.custom_serialiser(),
  ))

  client.model(runtime).count
  |> should.equal(1)
}

@target(javascript)
pub fn open_serialiser_client_reports_the_client_id_test() {
  test_support.reset_dom()
  let runtime = client.start(test_support.session_store())
  let seen = test_support.new("")
  let _ =
    client.observe(runtime, fn(event, _model) {
      case event {
        client.ClientIdAssigned(client_id:) -> test_support.set(seen, client_id)
        _ -> Nil
      }
    })
  let #(handler, _sent) = test_support.connect_capturing(runtime)

  handler.received(transport.encode(
    transport.Connected(client_id: "abc"),
    serialiser: test_support.custom_serialiser(),
  ))

  test_support.get(seen)
  |> should.equal("abc")
}
