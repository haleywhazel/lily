// zero-field `Error`, clashes with the prelude's one-field `Error` in registry
// tests

@target(javascript)
pub type Verdict {
  Error
  Fine
}
