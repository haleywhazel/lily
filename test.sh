#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# =============================================================================
# WARNING FILTER (yes I hate seeing these warnings)
# Filters these out:
#
# 1. empty-module  warning: Empty module
#                 [blank]
#                 Module '...' contains no public definitions.
#                 Hint: You can safely remove this module.
#                 [blank]
#
# 2. third-party   warning: Unused value
#                 ┌- .../build/packages/...
#                 [code block]
#                 [blank]
#                 This expression computes a value...
#                 [blank]
#
# All other warnings (from lily's own source) pass through unchanged.
#
# Add any other third-party warnings to this filter.
# =============================================================================

filter_warnings() {
  awk '
    BEGIN { state = "normal" }

    state == "normal" && /^warning: Empty module$/ {
      state = "empty_skip"; next
    }
    state == "normal" && /^warning:/ {
      pending = $0; state = "pkg_peek"; next
    }
    state == "normal" { print; next }

    state == "empty_skip" && /^$/ && !empty_blank_seen {
      empty_blank_seen = 1; next
    }
    state == "empty_skip" && /^$/ {
      state = "normal"; empty_blank_seen = 0; next
    }
    state == "empty_skip" { next }

    state == "pkg_peek" && /build\/packages\// {
      state = "pkg_code"; next
    }
    state == "pkg_peek" { print pending; print; state = "normal"; next }

    state == "pkg_code" && /^$/ { state = "pkg_hint"; next }
    state == "pkg_code" { next }

    state == "pkg_hint" && /^$/ { state = "normal"; next }
    state == "pkg_hint" { next }
  '
}

# =============================================================================
# DEPENDENCIES
# =============================================================================

echo "Checking dependencies..."

if ! command -v gleam &> /dev/null; then
  echo "Error: gleam is not installed. See https://gleam.run/getting-started/installing/"
  exit 1
fi

if ! command -v node &> /dev/null; then
  echo "Error: Node.js is not installed (required for JavaScript tests)."
  echo "  Install from https://nodejs.org or use: brew install node"
  exit 1
fi

if ! command -v npm &> /dev/null; then
  echo "Error: npm is not installed."
  exit 1
fi

# Install jsdom if node_modules not present
if [ ! -d "node_modules" ]; then
  echo "Installing JavaScript test dependencies..."
  npm install --silent
fi

# =============================================================================
# TESTS
# =============================================================================

# Clean build artefacts to avoid stale BEAM/JS cache issues
gleam clean

echo ""
echo "Running Erlang tests..."
echo ""
gleam test --target erlang 2> >(filter_warnings >&2)

echo ""
echo "Running JavaScript tests..."
echo ""
gleam test --target javascript 2> >(filter_warnings >&2)

echo ""
echo "All tests passed."
