#!/bin/bash
# Headless checks, compiled against the real sources - never against a copy.
# Not an Xcode target: each is a standalone main.swift, run with swiftc.
#
#   ./Checks/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC="PulsedPhotonsPro"
OUT=$(mktemp -d)
HDR="-import-objc-header $SRC/Rendering/BridgingHeader.h -I $SRC/Rendering"
fail=0

# Swift only allows top-level code in a file named main.swift, so each check is
# staged under that name before it is compiled.
run() {
  local name=$1; local check=$2; shift 2
  echo "=== $name ==="
  mkdir -p "$OUT/$name"
  cp "$check" "$OUT/$name/main.swift"
  if ! swiftc -O $HDR "$OUT/$name/main.swift" "$@" -o "$OUT/$name/bin" 2>&1 \
       | grep -E "error:" ; then
    "$OUT/$name/bin" || fail=1
  else
    echo "  BUILD FAILED"; fail=1
  fi
  echo
}

# Grid spacing is pure arithmetic and needs nothing from the app.
run grid Checks/grid.swift
# Units need the parser and its model.
run units Checks/units.swift "$SRC/Models/PointCloud.swift" "$SRC/Parsers/LASParser.swift"

# Writers round trip through the app's own parsers.
run writers Checks/writers.swift "$SRC/Models/PointCloud.swift" \
  "$SRC/Parsers/PointCloudWriter.swift" "$SRC/Parsers/LASParser.swift" \
  "$SRC/Parsers/PLYParser.swift" "$SRC/Parsers/XYZParser.swift"

# Refinement drives the real renderer offscreen. It needs the shader library
# beside the executable, because makeDefaultLibrary looks in the main bundle and
# a command-line tool's bundle is its own directory.
echo "=== refinement ==="
mkdir -p "$OUT/refinement"
cp Checks/refinement.swift "$OUT/refinement/main.swift"
APP_SOURCES="$SRC/Rendering/Renderer.swift $SRC/Rendering/Camera.swift \
$SRC/Rendering/GridRenderer.swift $SRC/Views/Theme.swift $SRC/Views/ContentView.swift \
$SRC/Views/Toolbar.swift $SRC/Views/MetalView.swift $SRC/Views/ExportOptions.swift \
$SRC/Models/PointCloud.swift $SRC/Models/VisualizationMode.swift $SRC/App/ViewModel.swift \
$SRC/Parsers/LASParser.swift $SRC/Parsers/PLYParser.swift $SRC/Parsers/XYZParser.swift \
$SRC/Parsers/PointCloudWriter.swift"
if xcrun -sdk macosx metal -I "$SRC/Rendering" -c "$SRC/Rendering/Shaders.metal" -o "$OUT/r.air" \
   && xcrun -sdk macosx metallib "$OUT/r.air" -o "$OUT/refinement/default.metallib" \
   && swiftc -O $HDR "$OUT/refinement/main.swift" $APP_SOURCES -o "$OUT/refinement/bin"; then
  "$OUT/refinement/bin" || fail=1
else
  echo "  BUILD FAILED"; fail=1
fi
echo

# Shaders are compiled from the project's own .metal and run offscreen.
echo "=== shaders ==="
mkdir -p "$OUT/shaders"
cp Checks/shaders.swift "$OUT/shaders/main.swift"
if xcrun -sdk macosx metal -I "$SRC/Rendering" -c "$SRC/Rendering/Shaders.metal" -o "$OUT/s.air" \
   && xcrun -sdk macosx metallib "$OUT/s.air" -o "$OUT/s.metallib" \
   && swiftc -O $HDR "$OUT/shaders/main.swift" -o "$OUT/shaders/bin"; then
  "$OUT/shaders/bin" "$OUT/s.metallib" || fail=1
else
  echo "  BUILD FAILED"; fail=1
fi

echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASS" || echo "SOME CHECKS FAILED"
exit $fail
