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
for target in RealPages GrayCheck BoxCheck ICCCheck CutoffSweep; do
    mkdir -p "$OUT/Sources/$target"
    cp "$HERE/mac/$target.swift" "$OUT/Sources/$target/main.swift"
done
python3 -I - "$OUT" <<'PY'
import re, sys
out = sys.argv[1]
# Benchmark-only: make the Mac TurboJPEG routing cutoff adjustable so CutoffSweep can pin
# makeTexture to either route. The static's default carries the shipped constant, so the
# other probes keep the library's real routing.
path = out + '/Sources/ImageIOKit/Decoding/ImageSource+Texture.swift'
source = open(path).read()
# Lift the Apple Silicon gate in the copy so the sweep can still pin either route on arm64.
gate = '#if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)'
assert gate in source, 'arch gate anchor'
source = source.replace(gate, '#if os(macOS) || targetEnvironment(macCatalyst)', 1)
guard = re.compile(r'guard imageSize\.width \* imageSize\.height <= ([0-9_]+) else \{ return nil \}')
match = guard.search(source)
assert match, 'cutoff guard anchor'
source = guard.sub('guard imageSize.width * imageSize.height <= ImageSource.benchmarkTurboJPEGCutoff'
                   ' else { return nil }', source, count=1)
marker = 'extension ImageSource {'
assert marker in source, 'extension anchor'
source = source.replace(marker, marker + '''

    /// Benchmark-only: the Mac TurboJPEG routing cutoff in pixels, patched in by setup-mac.sh
    /// so CutoffSweep can pin makeTexture to either route. Not part of the library.
    nonisolated(unsafe) static var benchmarkTurboJPEGCutoff: CGFloat = ''' + match.group(1), 1)
open(path, 'w').write(source)
PY
cd "$OUT" && swift build -c release
echo "Harness ready in $OUT. Example: $OUT/.build/release/GPUScaleBench $OUT/fixtures"
