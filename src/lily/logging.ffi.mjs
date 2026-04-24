/**
 * LOGGING (JAVASCRIPT)
 *
 * Writes log lines to the console in the same format used by the `logging`
 * hex package on Erlang: a four-character level code (`INFO`, `EROR`, etc.),
 * a space, then the message. Lines are routed to the console method matching
 * their severity so DevTools applies its own colouring.
 *
 * Works identically in browsers, Node, Bun, and Deno.
 *
 * A module-level currentLevel threshold gates messages below it. Default is
 * 6 (Info). setLevel() updates it — useful on JS servers where DevTools is
 * not available.
 *
 * Severity values (lower = more severe):
 *   0 Emergency, 1 Alert, 2 Critical, 3 Error, 4 Warning, 5 Notice, 6 Info, 7 Debug
 */

let currentLevel = 6; // Info

function envvarEnabled(name) {
  const val = typeof process !== "undefined" ? process.env?.[name] : undefined;
  return val !== undefined && val !== "" && val !== "false";
}

const colored =
  typeof process !== "undefined" &&
  process.stdout?.isTTY === true &&
  !envvarEnabled("NO_COLOR") &&
  !envvarEnabled("NO_COLOUR");

const LEVEL_CODES = {
  EMRG: colored ? "\x1b[1;41mEMRG\x1b[0m" : "EMRG",
  ALRT: colored ? "\x1b[1;41mALRT\x1b[0m" : "ALRT",
  CRIT: colored ? "\x1b[1;41mCRIT\x1b[0m" : "CRIT",
  EROR: colored ? "\x1b[1;31mEROR\x1b[0m" : "EROR",
  WARN: colored ? "\x1b[1;33mWARN\x1b[0m" : "WARN",
  NTCE: colored ? "\x1b[1;32mNTCE\x1b[0m" : "NTCE",
  INFO: colored ? "\x1b[1;34mINFO\x1b[0m" : "INFO",
  DEBG: colored ? "\x1b[1;36mDEBG\x1b[0m" : "DEBG",
};

const CONSOLE_METHOD = {
  EMRG: "error",
  ALRT: "error",
  CRIT: "error",
  EROR: "error",
  WARN: "warn",
  NTCE: "info",
  INFO: "info",
  DEBG: "debug",
};

export function log(levelCode, levelSeverity, message) {
  if (levelSeverity > currentLevel) return;
  const line = LEVEL_CODES[levelCode] + " " + message;
  console[CONSOLE_METHOD[levelCode] ?? "info"](line);
}

export function setLevel(severity) {
  currentLevel = severity;
}
