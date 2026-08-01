/**
 * LOGGING (JAVASCRIPT)
 *
 * Writes console lines matching the `logging` hex package format on Erlang, a
 * four-character level code (`INFO`, `EROR`, etc.), a space, then the message.
 * Lines route to the console method matching their severity so DevTools
 * colours them. Works in browsers, Node, Bun, and Deno.
 *
 * currentLevel gates messages below it, default 6 (Info). setLevel() updates
 * it, useful on JS servers with no DevTools.
 *
 * Severity (lower = more severe):
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

// Indexed by severity (0..7), one array of pre-rendered tags (with optional
// ANSI colours), one of console methods. Indexed lookup is cheaper than a
// string-keyed dictionary.
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
