/**
 * LOGGING (JAVASCRIPT)
 *
 * Writes log lines to the browser console in the same format used by the
 * `logging` hex package on Erlang: a four-character level code (`INFO`,
 * `EROR`, etc.), a space, then the message. Lines are routed to the console
 * method matching their severity so DevTools applies its own colouring.
 *
 * `console.debug` is hidden behind the "Verbose" verbosity filter in Chrome
 * and Firefox by default, which matches Erlang's default behaviour of
 * filtering `Debug` unless `set_level` is called.
 */

export function log(levelCode, message) {
  const line = levelCode + " " + message;
  switch (levelCode) {
    case "EMRG":
    case "ALRT":
    case "CRIT":
    case "EROR":
      console.error(line);
      return;
    case "WARN":
      console.warn(line);
      return;
    case "DEBG":
      console.debug(line);
      return;
    case "NTCE":
    case "INFO":
    default:
      console.info(line);
      return;
  }
}
