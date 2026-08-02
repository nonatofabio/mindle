#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNT="${1:-1000}"
TRACE_DIR="${2:-${TMPDIR:-/tmp}/mindle-profile-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$TRACE_DIR"
FIXTURE="$("$SCRIPT_DIR/generate-file-browser-fixture.sh" "$COUNT")"

cd "$ROOT_DIR"
./build.sh

APP_BIN="$ROOT_DIR/build/Mindle.app/Contents/MacOS/mindle"
"$APP_BIN" "$FIXTURE" > "$TRACE_DIR/app.log" 2>&1 &
APP_PID=$!

cleanup() {
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID"
  fi
}
trap cleanup EXIT

sleep 2
echo "Fixture: $FIXTURE"
echo "Trace output: $TRACE_DIR"
echo "During the capture: scroll the file tree end-to-end, resize the left divider repeatedly, and open several files."

if xcrun xctrace list templates >/dev/null 2>&1; then
  echo "Recording a 30-second Time Profiler trace..."
  xcrun xctrace record \
    --template "Time Profiler" \
    --attach "$APP_PID" \
    --time-limit 30s \
    --output "$TRACE_DIR/file-browser.trace"
else
  echo "Full Xcode is not selected; capturing a 30-second sample instead."
  echo "Select Xcode with xcode-select to enable Instruments Time Profiler and SwiftUI traces."
  sample "$APP_PID" 30 -file "$TRACE_DIR/file-browser.sample.txt"
fi

echo "Capture complete: $TRACE_DIR"
