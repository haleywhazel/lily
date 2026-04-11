/**
 * SESSION PERSISTENCE
 *
 * This module handles localStorage-backed session persistence. Fields are
 * stored individually with a prefix, allowing type-safe serialisation per field.
 */

// =============================================================================
// IMPORTS
// =============================================================================

import { Ok, Error } from "../gleam.mjs";

// =============================================================================
// EXPORT FUNCTIONS
// =============================================================================

/** Clear all session keys from localStorage */
export function clearSession(prefix) {
  const keysToRemove = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key && key.startsWith(prefix)) {
      keysToRemove.push(key);
    }
  }
  for (const key of keysToRemove) {
    localStorage.removeItem(key);
  }
}

/** Read a field from localStorage and parse as JSON */
export function readField(prefix, key) {
  try {
    const fullKey = prefix + key;
    const raw = localStorage.getItem(fullKey);
    if (raw === null) return new Error(undefined);

    const parsed = JSON.parse(raw);
    return new Ok(parsed);
  } catch (_error) {
    return new Error(undefined);
  }
}

/** Store session configuration on runtime and hook into update cycle */
export function setSessionConfig(runtime, persistence, get, set) {
  const fields = persistence.fields.toArray();

  // Store config on runtime
  runtime.setSessionConfig({
    persistence,
    get,
    set,
    fields,
  });
}

/** Write a field to localStorage */
export function writeField(prefix, key, jsonValue) {
  try {
    const fullKey = prefix + key;
    const serialised = JSON.stringify(jsonValue);
    localStorage.setItem(fullKey, serialised);
  } catch (error) {
    console.error(`Failed to persist session field "${key}":`, error);
  }
}
