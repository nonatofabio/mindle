#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build

swiftc -O -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  Sources/mindle/Theme.swift \
  Sources/mindle/FileBrowserPresentation.swift \
  Sources/mindle/FileBrowserView.swift \
  Tests/snapshots/FileBrowserSnapshotTests.swift \
  -o .build/run-screenshot-tests

.build/run-screenshot-tests "$@"
