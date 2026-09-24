#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-}"
if [[ -z "$destination" ]]; then
    simulator_id="$(xcrun simctl list devices available --json | ruby -rjson -e '
        runtimes = JSON.parse(STDIN.read).fetch("devices")
        candidates = runtimes.select { |name, _| name.include?(".iOS-") }
        candidates = candidates.sort_by { |name, _| name.scan(/iOS-(\d+)-(\d+)/).flatten.map(&:to_i) }.reverse
        device = candidates.flat_map { |_, devices| devices }.find { |entry| entry["name"].start_with?("iPhone") }
        abort "No available iPhone simulator; pass an explicit destination." unless device
        puts device.fetch("udid")
    ')"
    destination="platform=iOS Simulator,id=$simulator_id"
fi

# Keep Xcode from selecting the example .xcodeproj instead of the package scheme.
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/ImageIOKit-package.XXXXXX")"
cp "$repo_dir/Package.swift" "$package_dir/Package.swift"
ln -s "$repo_dir/ImageIOKit" "$package_dir/ImageIOKit"
ln -s "$repo_dir/ImageIOKitTests" "$package_dir/ImageIOKitTests"
echo "Package test results: $package_dir/DerivedData/Logs/Test"
cd "$package_dir"
xcodebuild -scheme ImageIOKit -configuration Release -destination "$destination" \
    -derivedDataPath "$package_dir/DerivedData" -parallel-testing-enabled NO \
    ENABLE_TESTABILITY=YES test
