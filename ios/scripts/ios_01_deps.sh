#!/bin/bash
# iOS step 1 (on macOS): build the libslic3r dependencies for iPadOS arm64.
# Output: ios/build/deps/BambuStudio_deps/usr/local   Log: ios/logs/ios_01_deps.log
#
# Usage: ios/scripts/ios_01_deps.sh              (configure + build everything)
#        ios/scripts/ios_01_deps.sh dep_OpenCV   (rebuild a single dependency)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/ios/build/deps"
LOG="$ROOT/ios/logs/ios_01_deps.log"
TARGET="${1:-deps}"
mkdir -p "$BUILD" "$(dirname "$LOG")"

xcrun --sdk iphoneos --show-sdk-path >/dev/null || { echo "SDK iOS non trovato: apri Xcode una volta e accetta la licenza"; exit 1; }

cd "$BUILD"
{
    echo "=== $(date) target=$TARGET"
    cmake "$ROOT/ios/deps" -G "Unix Makefiles" -Wno-dev -DREPO_ROOT="$ROOT"
    # -k: keep building the other dependencies when one fails, to see all errors in one run
    cmake --build . --target "$TARGET" -- -k
} 2>&1 | tee "$LOG"

echo
echo "Log: $LOG"
