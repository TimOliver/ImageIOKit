#!/bin/bash
# Builds the macOS benchmark harness in a temporary directory from the current repo sources.
# Usage: bash docs/benchmarks/harness/setup-mac.sh [harness-dir]   (default /tmp/ImageIOKit-gpu-bench)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$REPO/docs/benchmarks/harness"
OUT="${1:-/tmp/ImageIOKit-gpu-bench}"
mkdir -p "$OUT/Sources" "$OUT/fixtures"
rm -rf "$OUT/Sources/ImageIOKit"
cp -R "$REPO/ImageIOKit" "$OUT/Sources/ImageIOKit"
cp "$HERE/mac/Package.swift" "$OUT/Package.swift"
mkdir -p "$OUT/Sources/GPUScaleBench"
cp "$REPO/docs/benchmarks/2026-11-06-gpu-scale-probe.swift" "$OUT/Sources/GPUScaleBench/main.swift"
for target in RealPages GrayCheck BoxCheck ICCCheck; do
    mkdir -p "$OUT/Sources/$target"
    cp "$HERE/mac/$target.swift" "$OUT/Sources/$target/main.swift"
done
cd "$OUT" && swift build -c release
echo "Harness ready in $OUT. Example: $OUT/.build/release/GPUScaleBench $OUT/fixtures"
