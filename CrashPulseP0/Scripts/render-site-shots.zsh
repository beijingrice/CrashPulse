#!/bin/zsh
# Regenerates the product site's example screenshots in Website/product-site/public/assets/shots.
# Events and event detail come from the Debug --render-ui sample scenes. Live comes from
# Scripts/site-live-sample.swift, which compiles the app sources with a fixed sample snapshot,
# because the --render-ui Live scene shows this Mac's real processes.
# Needs Xcode, cwebp (Homebrew webp). Does not change the app.
set -euo pipefail

project=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
shots="$project/Website/product-site/public/assets/shots"
mkdir -p "$shots"

xcodebuild -project "$project/CrashPulseP0.xcodeproj" -scheme CrashPulse-Sandbox-Off -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$project/.build/xcode" build > "$work/build.log"
"$project/.build/xcode/Build/Products/Debug/CrashPulseOff.app/Contents/MacOS/CrashPulseOff" --render-ui "$work/ui" > /dev/null

cd "$project/CrashPulse"
# Top-level code must live in a file named main.swift.
cp "$project/Scripts/site-live-sample.swift" "$work/main.swift"
xcrun clang -c LibprocBridge.c -o "$work/libproc.o"
xcrun swiftc -O -swift-version 5 -import-objc-header LibprocBridge.h -module-name CrashPulseShots \
    ${(f)"$(ls *.swift | grep -v '^main.swift$')"} "$work/main.swift" "$work/libproc.o" \
    -o "$work/live-sample"
"$work/live-sample" "$work/live"

for mode in light dark; do
    cwebp -quiet -q 90 "$work/ui/1-events-$mode.png" -o "$shots/events-$mode.webp"
    cwebp -quiet -q 90 "$work/ui/2-detail-$mode.png" -o "$shots/detail-$mode.webp"
    cwebp -quiet -q 90 "$work/live/live-$mode.png" -o "$shots/live-$mode.webp"
done
print "$shots"
