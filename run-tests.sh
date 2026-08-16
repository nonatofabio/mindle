#!/usr/bin/env bash
# Compiles the pure-logic sources + the swiftc assert harness and runs the
# checks. No XCTest: this project builds with Command Line Tools only, so
# tests are plain Swift compiled the same way build.sh compiles the app.
# Later tasks append their sources/checks to the swiftc line below.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O \
  Sources/mindle/SSHTarget.swift \
  Sources/mindle/SSHProfile.swift \
  Sources/mindle/RemoteMarkdownAssets.swift \
  Sources/mindle/SSHTransport.swift \
  Tests/harness/TestHarness.swift \
  Tests/harness/SSHTargetChecks.swift \
  Tests/harness/SSHProfileChecks.swift \
  Tests/harness/RemoteMarkdownAssetsChecks.swift \
  Tests/harness/SSHTransportChecks.swift \
  Tests/harness/main.swift \
  -o .build/run-tests
.build/run-tests

swiftc -O \
  -framework AppKit \
  -framework Foundation \
  -framework UniformTypeIdentifiers \
  -framework WebKit \
  Sources/mindle/ImageSchemeHandler.swift \
  Tests/web/ReaderImageHarness.swift \
  -o .build/run-reader-image-tests
.build/run-reader-image-tests
