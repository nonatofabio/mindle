#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNT="${1:-1000}"
RUNS="${2:-5}"
GIT_FILES="${3:-5}"
FIXTURE="$ROOT_DIR/.build/file-browser-benchmark-fixture-$COUNT"
BENCHMARK="$ROOT_DIR/.build/file-browser-benchmark"

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || ((RUNS < 3)); then
  echo "runs must be an integer of at least 3" >&2
  exit 2
fi
if ! [[ "$GIT_FILES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Git file count must be a positive integer" >&2
  exit 2
fi

rm -rf "$FIXTURE"
mkdir -p "$ROOT_DIR/.build"
"$SCRIPT_DIR/generate-file-browser-fixture.sh" "$COUNT" "$FIXTURE" >/dev/null

cd "$ROOT_DIR"
swiftc -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  Sources/mindle/FileTree.swift \
  Sources/mindle/FileBrowserState.swift \
  Sources/mindle/GitFileMetadata.swift \
  Sources/mindle/PerformanceTrace.swift \
  Tests/performance/main.swift \
  -o "$BENCHMARK"

"$BENCHMARK" "$FIXTURE" "$RUNS" "$GIT_FILES"
