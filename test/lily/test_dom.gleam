// DOM inspection and event dispatch helpers for JavaScript tests.
// All functions are @target(javascript) since they interact with the browser DOM
// provided by jsdom (set up in test_setup.ffi.mjs).

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "getInnerHtml")
pub fn inner_html(_selector: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "setInnerHtml")
pub fn set_inner_html(_selector: String, _html: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "click")
pub fn click(_selector: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "dispatchMouseEvent")
pub fn mouse_event(
  _selector: String,
  _event_name: String,
  _client_x: Int,
  _client_y: Int,
) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "dispatchKeyEvent")
pub fn key_event(_selector: String, _event_name: String, _key: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "dispatchInputEvent")
pub fn input_event(_selector: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "dispatchWheelEvent")
pub fn wheel_event(_selector: String, _delta_x: Float, _delta_y: Float) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "getAttribute")
pub fn get_attribute(_selector: String, _name: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "hasAttribute")
pub fn has_attribute(_selector: String, _name: String) -> Bool {
  False
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "getText")
pub fn get_text(_selector: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "setLocalStorageItem")
pub fn set_local_storage_item(_key: String, _value: String) -> Nil {
  Nil
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "getLocalStorageItem")
pub fn get_local_storage_item(_key: String) -> String {
  ""
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "hasLocalStorageItem")
pub fn has_local_storage_item(_key: String) -> Bool {
  False
}

@target(javascript)
@external(javascript, "./test_dom.ffi.mjs", "dispatchSimpleEvent")
pub fn simple_event(_selector: String, _event_name: String) -> Nil {
  Nil
}
