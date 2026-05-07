#!/bin/bash
set -e

cd "$(dirname "$0")"

# Path-dep edits (in shared/, lily/, or even just backend itself) leave stale
# beam copies and stale Gleam type-metadata in the consumer's build dir, which
# in turn causes Erlang boot crashes (`badmatch`/`undef`) when `gleam run`
# loads code generated against an older version of a dep. A full `gleam clean`
# fixes it but also wipes every hex dep. This selectively wipes just the
# path-dep parts and the consumer's own emitted modules — the slow
# hex-dep rebuilds stay cached.
invalidate_path_deps() {
  rm -rf backend/build/dev/erlang/shared \
         backend/build/dev/erlang/lily \
         backend/build/dev/erlang/backend
  rm -rf frontend/build/dev/javascript/shared \
         frontend/build/dev/javascript/lily \
         frontend/build/dev/javascript/frontend
}

clean_all() {
  echo "Cleaning all packages..."
  (cd shared && gleam clean)
  (cd frontend && gleam clean)
  (cd backend && gleam clean)
}

build_shared()   { echo "Building shared..."   ; (cd shared   && gleam build); }
build_frontend() { echo "Building frontend..." ; (cd frontend && gleam build); }
build_backend()  { echo "Building backend..."  ; (cd backend  && gleam build); }

start_server() {
  echo "Server running on http://localhost:8080"
  (cd backend && gleam run) &
  SERVER_PID=$!
}

stop_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

watch_loop() {
  if ! command -v fswatch >/dev/null; then
    echo "error: --watch requires fswatch (install with: brew install fswatch)" >&2
    exit 1
  fi

  trap 'stop_server; exit 0' INT TERM EXIT

  echo "Watching for changes (shared/, ../src/, backend/src/, frontend/src/, frontend/index.html)..."
  echo "Press Ctrl-C to stop."

  local needs_server=false
  local needs_frontend=false

  while IFS= read -r path; do
    if [[ "$path" == "__END_BATCH__" ]]; then
      if $needs_frontend; then
        echo "[change] rebuilding frontend"
        if (cd frontend && gleam build); then
          echo "  ✓ frontend rebuilt — reload browser"
        else
          echo "  ✗ frontend build failed"
        fi
      fi
      if $needs_server; then
        echo "[change] rebuilding backend & restarting server"
        stop_server
        invalidate_path_deps
        if build_shared && build_backend; then
          start_server
        else
          echo "  ✗ backend build failed — server not started"
        fi
      fi
      needs_server=false
      needs_frontend=false
      continue
    fi

    case "$path" in
      */shared/src/*)        needs_server=true; needs_frontend=true ;;
      */lily/src/*)          needs_server=true; needs_frontend=true ;;
      */backend/src/*)       needs_server=true ;;
      */frontend/src/*)      needs_frontend=true ;;
      */frontend/index.html) echo "[change] index.html — served live, no rebuild needed" ;;
    esac
  done < <(fswatch -r -l 0.3 --batch-marker=__END_BATCH__ \
             shared/src \
             ../src \
             backend/src \
             frontend/src \
             frontend/index.html)
}

case "${1:-}" in
  --clean)
    clean_all
    ;;
  --watch)
    invalidate_path_deps
    build_shared
    build_frontend
    build_backend
    start_server
    watch_loop
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: $0 [--clean | --watch]" >&2
    exit 1
    ;;
esac

invalidate_path_deps
build_shared
build_frontend
build_backend
echo "Server running on http://localhost:8080"
cd backend
exec gleam run
