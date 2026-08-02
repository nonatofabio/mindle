#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build

swiftc -O -parse-as-library \
  -profile-generate \
  -profile-coverage-mapping \
  -framework AppKit \
  -framework SwiftUI \
  Sources/mindle/Theme.swift \
  Sources/mindle/BrowserDisplaySettings.swift \
  Sources/mindle/PerformanceTrace.swift \
  Sources/mindle/SSHTarget.swift \
  Sources/mindle/SSHProfile.swift \
  Sources/mindle/FileTree.swift \
  Sources/mindle/GitFileMetadata.swift \
  Sources/mindle/FileBrowserState.swift \
  Sources/mindle/FileBrowserView.swift \
  Tests/snapshots/FileBrowserSnapshotTests.swift \
  -o .build/run-screenshot-tests

LLVM_PROFILE_FILE=.build/screenshot-tests.profraw .build/run-screenshot-tests "$@"
if [[ "${1:-}" != "--record" ]]; then
  xcrun llvm-profdata merge -sparse \
    .build/screenshot-tests.profraw \
    -o .build/screenshot-tests.profdata
  xcrun llvm-cov report .build/run-screenshot-tests \
    -instr-profile=.build/screenshot-tests.profdata \
    -ignore-filename-regex='Tests/' \
    Sources/mindle/FileBrowserView.swift
fi
