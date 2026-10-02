#!/bin/bash
# Build this project and run it.
#
#   ./run.sh            debug build
#   ./run.sh release    release build
#
# Launches the binary by full path rather than through `open`. There are other
# copies of PulsedPhotonsPro on this Mac sharing the same bundle identifier, and
# `open` asks LaunchServices which app that identifier means - which has
# resolved to a different copy, silently running a build hours older than the
# one just compiled. Executing the binary directly cannot pick the wrong one.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="Debug"
[ "${1:-}" = "release" ] && CONFIG="Release"

echo "building ($CONFIG)…"
if ! xcodebuild -project PulsedPhotonsPro.xcodeproj \
                -scheme PulsedPhotonsPro \
                -configuration "$CONFIG" build > /tmp/pp-build.log 2>&1; then
    echo "build failed:"
    grep -E "error:" /tmp/pp-build.log | head -20
    exit 1
fi

# Ask the build system where it put things, rather than guessing the path.
BUILD_DIR=$(xcodebuild -project PulsedPhotonsPro.xcodeproj \
                       -scheme PulsedPhotonsPro \
                       -configuration "$CONFIG" \
                       -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$BUILD_DIR/PulsedPhotonsPro.app"
BIN="$APP/Contents/MacOS/PulsedPhotonsPro"

if [ ! -x "$BIN" ]; then
    echo "no binary at $BIN"
    exit 1
fi

# Stop only instances of this build; another copy's window is not ours to close.
for pid in $(pgrep -x PulsedPhotonsPro 2>/dev/null || true); do
    if ps -o command= -p "$pid" | grep -qF "$BUILD_DIR"; then
        kill "$pid" 2>/dev/null || true
    fi
done
sleep 1

echo "running  $(stat -f '%Sm' -t '%d %b %H:%M:%S' "$BIN")"
echo "         $APP"
exec "$BIN"
