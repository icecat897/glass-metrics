#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glassmetrics-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$TEST_DIR/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$TEST_DIR/SwiftModuleCache"
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -O2 -c "$ROOT/Native/SMC.c" -o "$TEST_DIR/SMC.o"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 -warnings-as-errors \
  -framework IOKit "$ROOT/Sources/Samplers.swift" "$ROOT/Sources/CodexClient.swift" "$ROOT/Tests/SamplerTests.swift" \
  "$TEST_DIR/SMC.o" -o "$TEST_DIR/SamplerTests"
"$TEST_DIR/SamplerTests" "$@"
