#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -parse-as-library \
  -module-cache-path .build/module-cache \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers \
  Sources/mindle/ReaderSecurity.swift \
  Sources/mindle/ImageSchemeHandler.swift \
  Tests/web/ReaderSecurityChecks.swift \
  -o .build/reader-security-tests
.build/reader-security-tests "$@"
