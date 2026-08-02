#!/usr/bin/env bash
# Compiles the pure-logic sources + the swiftc assert harness and runs the
# checks. No XCTest: this project builds with Command Line Tools only, so
# tests are plain Swift compiled the same way build.sh compiles the app.
# Later tasks append their sources/checks to the swiftc line below.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O \
  -profile-generate \
  -profile-coverage-mapping \
  -framework AppKit \
  Sources/mindle/FileTree.swift \
  Sources/mindle/BrowserDisplaySettings.swift \
  Sources/mindle/FileBrowserState.swift \
  Sources/mindle/GitFileMetadata.swift \
  Sources/mindle/PerformanceTrace.swift \
  Sources/mindle/SSHTarget.swift \
  Sources/mindle/SSHProfile.swift \
  Sources/mindle/RemoteMarkdownAssets.swift \
  Sources/mindle/SSHTransport.swift \
  Sources/mindle/TitleBarDoubleClick.swift \
  Tests/harness/TestHarness.swift \
  Tests/harness/FileTreeChecks.swift \
  Tests/harness/FileBrowserStateChecks.swift \
  Tests/harness/GitFileMetadataChecks.swift \
  Tests/harness/SSHTargetChecks.swift \
  Tests/harness/SSHProfileChecks.swift \
  Tests/harness/RemoteMarkdownAssetsChecks.swift \
  Tests/harness/SSHTransportChecks.swift \
  Tests/harness/TitleBarDoubleClickChecks.swift \
  Tests/harness/main.swift \
  -o .build/run-tests
LLVM_PROFILE_FILE=.build/logic-tests.profraw .build/run-tests
xcrun llvm-profdata merge -sparse .build/logic-tests.profraw -o .build/logic-tests.profdata
xcrun llvm-cov report .build/run-tests \
  -instr-profile=.build/logic-tests.profdata \
  -ignore-filename-regex='Tests/' \
  Sources/mindle/BrowserDisplaySettings.swift \
  Sources/mindle/FileBrowserState.swift \
  Sources/mindle/FileTree.swift \
  Sources/mindle/GitFileMetadata.swift \
  Sources/mindle/RemoteMarkdownAssets.swift \
  Sources/mindle/SSHProfile.swift \
  Sources/mindle/SSHTarget.swift \
  Sources/mindle/SSHTransport.swift \
  Sources/mindle/TitleBarDoubleClick.swift
