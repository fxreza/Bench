#!/bin/bash
set -euo pipefail

# =============================================================================
# Runs the locally built build.noindex/Bench.app.
#
#   scripts/run_app.sh [--data-dir <dir>] [--kill]
#
# Debug hooks (only with BENCH_DEBUG=1, which this script passes):
#   notifyutil -p com.fxreza.bench.debug.settings   - open Settings
#   notifyutil -p com.fxreza.bench.debug.quit       - quit the app
#
# Screenshot:  screencapture -x file.png
# =============================================================================

APP_NAME="Bench"
BUNDLE_ID="com.fxreza.bench"

DATA_DIR=""
KILL_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --kill) KILL_ONLY=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

REPO_PATH="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${REPO_PATH}/build.noindex/${APP_NAME}.app"
BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
INSTALLED="/Applications/${APP_NAME}.app"
INSTALLED_BINARY="${INSTALLED}/Contents/MacOS/${APP_NAME}"

if [[ -z "$DATA_DIR" ]]; then
    DATA_DIR="${REPO_PATH}/build.noindex/test-data"
fi

kill_local_instance() {
    # Only ever the locally built copy, never the installed one.
    if pgrep -f "${BINARY}" >/dev/null 2>&1; then
        echo "Killing the local ${APP_NAME}..."
        pkill -f "${BINARY}" || true
        sleep 0.5
    else
        echo "No local ${APP_NAME} instance running."
    fi
}

if [[ "$KILL_ONLY" == true ]]; then
    kill_local_instance
    exit 0
fi

kill_local_instance

# Never two live copies of one bundle identifier. macOS 26's ControlCenter
# tracks menu bar items per identifier, and two live copies of
# com.fxreza.bench wedge that state badly enough that the status item stops
# being laid out at all. The local build deliberately keeps the production
# identifier (SMAppService and TCC both key off it), so the installed copy has
# to be quit rather than run alongside. See AGENTS.md > "Menu-bar app launch
# trap".
if pgrep -f "${INSTALLED_BINARY}" >/dev/null 2>&1; then
    echo "Refusing to launch: ${INSTALLED} is running and shares the bundle id"
    echo "(${BUNDLE_ID}). Quit it first:"
    echo "  osascript -e 'tell application \"${APP_NAME}\" to quit'"
    exit 1
fi

if [[ ! -f "$BINARY" ]]; then
    echo "Binary not found at ${BINARY}"
    echo "Run: scripts/build-app.sh"
    exit 1
fi

mkdir -p "$DATA_DIR"
LOG_FILE="${REPO_PATH}/build.noindex/run.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Launched via `open` on the registered .app bundle rather than by executing
# the binary. A binary launched straight from a Terminal or Claude Code session
# is "responsible" (in macOS 26 ControlCenter's sense) to that launcher, not to
# itself - and if the launcher's own menu bar icon is hidden, every status item
# sharing this bundle id becomes invisible system-wide: registered, clickable
# through accessibility, but never laid out. See AGENTS.md and
# /Users/sam/Claude/CLAUDE.md. `-n` forces a fresh instance; `--env` passes the
# data dir and debug flag the way direct env vars would.
echo "Launching ${APP_NAME}..."
echo "Data directory: ${DATA_DIR}"
echo "Log: ${LOG_FILE}"

open -n \
    --env BENCH_DATA_DIR="$DATA_DIR" \
    --env BENCH_DEBUG=1 \
    --stdout "$LOG_FILE" \
    --stderr "$LOG_FILE" \
    -a "$APP_BUNDLE"

sleep 0.5

if ! pgrep -f "${BINARY}" >/dev/null 2>&1; then
    echo "Failed to start. Last 20 lines of the log:"
    tail -20 "$LOG_FILE" >&2
    exit 1
fi

echo "Started with PID: $(pgrep -f "${BINARY}" | head -1)"
echo "Settings:   notifyutil -p com.fxreza.bench.debug.settings"
echo "Quit:       notifyutil -p com.fxreza.bench.debug.quit"
echo "Screenshot: screencapture -x file.png"
echo "Kill:       scripts/run_app.sh --kill"
