#!/bin/bash
# Step 2 (macOS): build libslic3r + ios/core and the test driver bbs-core-slice.
# Needs step 1 (mac_01_deps.sh) completed.
#
# Usage: ios/scripts/mac_02_core.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCH="arm64"
DEPS="$ROOT/deps/build/$ARCH/BambuStudio_deps"
BUILD="$ROOT/build-core/$ARCH"
LOG="$ROOT/ios/logs/mac_02_core.log"
mkdir -p "$BUILD" "$(dirname "$LOG")"

[ -d "$DEPS/usr/local" ] || { echo "Dipendenze non trovate: esegui prima ios/scripts/mac_01_deps.sh"; exit 1; }

GEN="Unix Makefiles"
command -v ninja >/dev/null && GEN="Ninja"

cd "$BUILD"
cmake "$ROOT" \
    -G "$GEN" \
    -DSLIC3R_CORE_ONLY=ON \
    -DBBL_RELEASE_TO_PUBLIC=1 \
    -DBBL_INTERNAL_TESTING=0 \
    -DCMAKE_PREFIX_PATH="$DEPS/usr/local" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 2>&1 | tee "$LOG"
cmake --build . --parallel "$(sysctl -n hw.ncpu)" --target bbs-core-slice 2>&1 | tee -a "$LOG"

echo
echo "OK: $(find "$BUILD" -name bbs-core-slice -type f | head -1)"
echo "Log completo: $LOG"
