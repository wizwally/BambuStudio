#!/bin/bash
# Step 1 (macOS, Apple Silicon): build the C++ dependencies needed by libslic3r.
#
# Same superbuild as BuildMac.sh -d, but without the desktop-only libraries
# (wxWidgets, FFmpeg, GLFW, libharu). Output: deps/build/arm64/BambuStudio_deps
#
# Usage: ios/scripts/mac_01_deps.sh            (first run: 30-90 min)
#        ios/scripts/mac_01_deps.sh -b         (rebuild without reconfiguring)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCH="arm64"
DEPS_BUILD_DIR="$ROOT/deps/build/$ARCH"
DEPS="$DEPS_BUILD_DIR/BambuStudio_deps"
LOG="$ROOT/ios/logs/mac_01_deps.log"
mkdir -p "$DEPS" "$(dirname "$LOG")"

command -v cmake >/dev/null || { echo "cmake mancante: brew install cmake"; exit 1; }
xcode-select -p >/dev/null || { echo "Xcode command line tools mancanti: xcode-select --install"; exit 1; }

cd "$DEPS_BUILD_DIR"
if [ "${1:-}" != "-b" ]; then
    cmake "$ROOT/deps" \
        -G "Unix Makefiles" \
        -DDESTDIR="$DEPS" \
        -DOPENSSL_ARCH="darwin64-${ARCH}-cc" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
        -DDEP_BUILD_WXWIDGETS=OFF \
        -DDEP_BUILD_FFMPEG=OFF \
        -DDEP_BUILD_GLFW=OFF \
        -DDEP_BUILD_LIBHARU=OFF 2>&1 | tee "$LOG"
fi
cmake --build . --parallel "$(sysctl -n hw.ncpu)" --target deps 2>&1 | tee -a "$LOG"

echo
echo "OK: dipendenze in $DEPS/usr/local"
echo "Log completo: $LOG"
