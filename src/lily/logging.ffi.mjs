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
 * 6 (Info). setLevel() updates it, useful on JS servers where DevTools is
 * not available.
 *
 * Severity values (lower = more severe):
 *   0 Emergency, 1 Alert, 2 Critical, 3 Error,
 *   4 Warning, 5 Notice, 6 Info, 7 Debug
 */

let currentLevel = 6; // Info

function envvarEnabled(name) {
  const val = typeof process !== "undefined" ? process.env?.[name] : undefined;
  return val !== undefined && val !== "" && val !== "false";
}

const coloured =
  typeof process !== "undefined" &&
  process.stdout?.isTTY === true &&
  !envvarEnabled("NO_COLOR") &&
  !envvarEnabled("NO_COLOUR");

// Indexed by severity (0..7). One array of pre-rendered tags (with optional
// ANSI colours), one of console methods. Indexed lookup is cheaper than the
// previous string-keyed dictionaries and removes a hop through level codes.
const TAGS_BY_SEVERITY = coloured
  ? [
      "\x1b[1;41mEMRG\x1b[0m",
      "\x1b[1;41mALRT\x1b[0m",
      "\x1b[1;41mCRIT\x1b[0m",
      "\x1b[1;31mEROR\x1b[0m",
      "\x1b[1;33mWARN\x1b[0m",
      "\x1b[1;32mNTCE\x1b[0m",
      "\x1b[1;34mINFO\x1b[0m",
      "\x1b[1;36mDEBG\x1b[0m",
    ]
  : ["EMRG", "ALRT", "CRIT", "EROR", "WARN", "NTCE", "INFO", "DEBG"];

const METHOD_BY_SEVERITY = [
  "error", // Emergency
  "error", // Alert
  "error", // Critical
  "error", // Error
  "warn",  // Warning
  "info",  // Notice
  "info",  // Info
  "debug", // Debug
];

export function isEnabled(severity) {
  return severity <= currentLevel;
}

export function log(severity, message) {
  if (severity > currentLevel) return;
  console[METHOD_BY_SEVERITY[severity]](TAGS_BY_SEVERITY[severity] + " " + message);
}

export function setLevel(severity) {
  currentLevel = severity;
}
