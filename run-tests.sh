#!/usr/bin/env bash
# Compiles the pure-logic sources + the swiftc assert harness and runs the
# checks. No XCTest: this project builds with Command Line Tools only, so
# tests are plain Swift compiled the same way build.sh compiles the app.
# Later tasks append their sources/checks to the swiftc line below.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O \
  -framework Combine \
  Sources/mindle/FileTree.swift \
  Sources/mindle/FileBrowserState.swift \
  Sources/mindle/GitFileMetadata.swift \
  Sources/mindle/PerformanceTrace.swift \
  Sources/mindle/SSHTarget.swift \
  Sources/mindle/SSHTransport.swift \
  Tests/harness/TestHarness.swift \
  Tests/harness/FileTreeChecks.swift \
  Tests/harness/FileBrowserStateChecks.swift \
  Tests/harness/GitFileMetadataChecks.swift \
  Tests/harness/SSHTargetChecks.swift \
  Tests/harness/SSHTransportChecks.swift \
  Tests/harness/main.swift \
  -o .build/run-tests
.build/run-tests
