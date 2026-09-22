#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
OUT="$ROOT/GlassMetrics.app"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glassmetrics-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$BUILD_DIR/SwiftModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"
STAGED_APP="$BUILD_DIR/GlassMetrics.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/GlassMetricsIcon.icns"
xcrun clang -arch arm64 -mmacosx-version-min=15.0 -O2 -Wall -Wextra -Werror \
  -c "$ROOT/Native/SMC.c" -o "$BUILD_DIR/SMC.o"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  -warnings-as-errors \
  -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
  "$ROOT"/Sources/*.swift "$BUILD_DIR/SMC.o" \
  -o "$STAGED_APP/Contents/MacOS/GlassMetrics"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
rm -rf "$OUT"
ditto "$STAGED_APP" "$OUT"
echo "$OUT"
