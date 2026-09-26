#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/ImageIOKitTests/SampleImages/WebP"
for tool in cwebp webpmux; do
    [[ "$("$tool" -version | head -1)" == "1.6.0" ]] || { echo "$tool 1.6.0 required" >&2; exit 1; }
done
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$output"

# Deliberate one-pixel transitions reveal crop-origin shifts; alpha includes zero.
ruby - "$temporary" <<'RUBY'
directory = ARGV.fetch(0)
%w[opaque alpha].each do |name|
  pixels = 32.times.flat_map do |y|
    64.times.flat_map { |x| [20 + (x % 4) * 64, 20 + (y % 4) * 64, 80, name == 'alpha' ? ((x + y) % 4) * 64 : 255] }
  end
  header = "P7\nWIDTH 64\nHEIGHT 32\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"
  File.binwrite("#{directory}/#{name}.pam", header + pixels.pack('C*'))
end
RUBY
for name in opaque alpha; do
    cwebp -quiet -lossless -exact "$temporary/$name.pam" -o "$output/$name-lossless.webp"
    cwebp -quiet -q 90 "$temporary/$name.pam" -o "$output/$name-lossy.webp"
done
webpmux -frame "$output/opaque-lossless.webp" +100+0+0+0-b \
    -frame "$output/alpha-lossless.webp" +100+0+0+0-b -loop 0 -o "$output/animated.webp"
