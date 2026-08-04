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

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** True when messages at the given severity would be written. */
export function isEnabled(severity) {
  return normaliseSeverity(severity) <= currentLevel;
}

/** Write one console line at the given severity, gated by currentLevel. */
export function log(severity, message) {
  // A bad severity would index the tables with undefined and call
  // console[undefined], which throws. normaliseSeverity clamps any non-integer
  // or out-of-range value to 3 (Error) so a stray call never crashes.
  const level = normaliseSeverity(severity);
  if (level > currentLevel) return;
  console[METHOD_BY_SEVERITY[level]](
    TAGS_BY_SEVERITY[level] + " " + message,
  );
}

/** Set the gate below which messages are dropped. */
export function setLevel(severity) {
  currentLevel = severity;
}

// =============================================================================
// FUNCTIONS
// =============================================================================

function envvarEnabled(name) {
  const val = typeof process !== "undefined" ? process.env?.[name] : undefined;
  return val !== undefined && val !== "" && val !== "false";
}

// Clamp a severity to an integer in 0..7 so both entry points agree on bad
// input, falling back to 3 (Error).
function normaliseSeverity(severity) {
  return Number.isInteger(severity) && severity >= 0 && severity <= 7
    ? severity
    : 3;
}

// =============================================================================
// PRIVATE CONSTANTS
// =============================================================================

// Mutable module state, reassigned by setLevel.
let currentLevel = 6; // Info

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
