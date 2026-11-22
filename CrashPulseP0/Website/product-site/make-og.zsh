#!/bin/zsh
# Renders the share image. Needs rsvg-convert (Homebrew librsvg).
set -euo pipefail
here=${0:A:h}
rsvg-convert -w 1200 -h 630 "$here/og-image.svg" -o "$here/public/assets/og.png"
print "$here/public/assets/og.png"
