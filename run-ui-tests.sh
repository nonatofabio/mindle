#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build

swiftc -O -parse-as-library \
  -framework AppKit \
  -framework Combine \
  -framework SwiftUI \
  Sources/mindle/Theme.swift \
  Sources/mindle/FileTree.swift \
  Sources/mindle/GitFileMetadata.swift \
  Sources/mindle/PerformanceTrace.swift \
  Sources/mindle/FileBrowserState.swift \
  Sources/mindle/FileBrowserView.swift \
  Tests/ui/FileBrowserScrollStabilityTests.swift \
  -o .build/run-ui-tests

.build/run-ui-tests
