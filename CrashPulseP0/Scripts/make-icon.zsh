#!/bin/zsh
# Builds CrashPulse/AppIcon.icns from Design/AppIcon.svg (and the small variant for 16 and 32 px).
# Requires rsvg-convert (brew install librsvg) and Xcode's iconutil.
set -euo pipefail
root=${0:A:h:h}
large=$root/Design/AppIcon.svg
small=$root/Design/AppIcon-small.svg
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set=$work/AppIcon.iconset
mkdir "$set"

render() { rsvg-convert -w $2 -h $2 "$1" -o "$set/$3.png" }
render $small 16   icon_16x16
render $small 32   icon_16x16@2x
render $small 32   icon_32x32
render $large 64   icon_32x32@2x
render $large 128  icon_128x128
render $large 256  icon_128x128@2x
render $large 256  icon_256x256
render $large 512  icon_256x256@2x
render $large 512  icon_512x512
render $large 1024 icon_512x512@2x

iconutil -c icns "$set" -o "$root/CrashPulse/AppIcon.icns"
echo "$root/CrashPulse/AppIcon.icns"
