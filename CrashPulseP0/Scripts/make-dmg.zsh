#!/bin/zsh
# Packages a built CrashPulse.app into a drag-to-install disk image with the
# Design/DMGBackground.svg window. Finder lays out the window, so run this in a
# logged-in session; the first run asks to let the terminal control Finder.
#
#   Scripts/make-dmg.zsh path/to/CrashPulse.app NEW.dmg [DEVELOPER_ID_APPLICATION NOTARY_KEYCHAIN_PROFILE]
#
# With an identity and profile the image is signed, notarized and stapled.
set -euo pipefail

if (( $# != 2 && $# != 4 )); then
    print -u2 'Usage: Scripts/make-dmg.zsh APP OUTPUT.dmg [DEVELOPER_ID_APPLICATION NOTARY_KEYCHAIN_PROFILE]'
    exit 64
fi

project=${0:A:h:h}
app=${1:A}
output=${2:A}
volume=CrashPulse
[[ -d "$app" ]] || { print -u2 "No app at $app"; exit 66; }
[[ ! -e "$output" ]] || { print -u2 "$output already exists"; exit 73; }
[[ ! -e "/Volumes/$volume" ]] || { print -u2 "Eject /Volumes/$volume first"; exit 75; }

work=$(mktemp -d)
trap 'hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/CrashPulse.app"
ln -s /Applications "$stage/Applications"
rsvg-convert -w 640 -h 400 "$project/Design/DMGBackground.svg" -o "$work/bg.png"
rsvg-convert -w 1280 -h 800 "$project/Design/DMGBackground.svg" -o "$work/bg@2x.png"
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$stage/.background/background.tiff" 2>/dev/null
cp "$project/CrashPulse/AppIcon.icns" "$stage/.VolumeIcon.icns"

hdiutil create -quiet -srcfolder "$stage" -volname "$volume" -fs HFS+ -format UDRW \
    -size 64m "$work/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$work/rw.dmg"
SetFile -a C "/Volumes/$volume"
SetFile -a V "/Volumes/$volume/.background" "/Volumes/$volume/.VolumeIcon.icns"

# The window is 640 x 400 pt of content plus a 32 pt title bar.
osascript <<EOF
tell application "Finder"
    tell disk "$volume"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 552}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "CrashPulse.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
hdiutil detach -quiet "/Volumes/$volume"
hdiutil convert -quiet "$work/rw.dmg" -format ULFO -o "$output"

if (( $# == 4 )); then
    codesign --sign "$3" --timestamp "$output"
    xcrun notarytool submit "$output" --keychain-profile "$4" --wait --output-format json \
        > "${output:r}-notarization.json"
    if [[ $(plutil -extract status raw -o - "${output:r}-notarization.json") != Accepted ]]; then
        print -u2 "Apple did not accept the disk image. See ${output:r}-notarization.json"
        exit 1
    fi
    xcrun stapler staple "$output"
    xcrun stapler validate "$output"
fi

hdiutil verify -quiet "$output"
print "$output"
