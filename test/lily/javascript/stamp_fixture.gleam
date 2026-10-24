// never registered anywhere, data-lily-message tests need a type only the
// page's own encodes can teach the decoder

@target(javascript)
pub type Stamp {
  Stamp(ink: Ink)
}

@target(javascript)
pub type Ink {
  Ink(colour: String)
}
