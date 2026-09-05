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
  Sources/mindle/SSHTransport.swift \
  Tests/harness/TestHarness.swift \
  Tests/harness/SSHTargetChecks.swift \
  Tests/harness/SSHTransportChecks.swift \
  Tests/harness/main.swift \
  -o .build/run-tests
.build/run-tests
bash ./run-reader-security-tests.sh
