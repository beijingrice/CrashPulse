#!/bin/zsh
set -euo pipefail

if (( $# != 1 && $# != 3 )); then
    print -u2 'Usage: Scripts/prepare-beta.zsh NEW_OUTPUT_DIRECTORY [DEVELOPER_ID_APPLICATION NOTARY_KEYCHAIN_PROFILE]'
    exit 64
fi

project=${0:A:h:h}
output=${1:A}
identity=-
typeset -a signing_flags
signing_flags=()

if (( $# == 3 )); then
    identity=$2
    profile=$3
    if [[ "$identity" != 'Developer ID Application: '* || -z "$profile" ]]; then
        print -u2 'Supply a Developer ID Application identity and a notarytool Keychain profile.'
        exit 64
    fi
    if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F -- "\"$identity\"" > /dev/null; then
        print -u2 'The Developer ID Application identity is unavailable in the Keychain.'
        exit 1
    fi
    signing_flags+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

mkdir -p "${output:h}"
mkdir "$output"

if ! xcodebuild -project "$project/CrashPulseP0.xcodeproj" -scheme CrashPulse-Sandbox-Off \
    -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$output/build" \
    ENABLE_HARDENED_RUNTIME=YES "CODE_SIGN_IDENTITY=$identity" "${signing_flags[@]}" \
    build > "$output/build.log" 2>&1; then
    print -u2 "Build failed. See $output/build.log"
    exit 1
fi

app="$output/CrashPulse.app"
/usr/bin/ditto "$output/build/Build/Products/Release/CrashPulseOff.app" "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign -d --verbose=4 "$app" 2> "$output/signature.txt"
/usr/bin/grep -E '^CodeDirectory .*flags=.*runtime' "$output/signature.txt" > /dev/null
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")

if [[ "$identity" == '-' ]]; then
    archive="$output/CrashPulse-$version-local-test.zip"
    print 'This build has a local ad hoc signature.'
else
    submission="$output/notary-submission.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$submission"
    xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait --output-format json \
        > "$output/notarization.json"
    if [[ $(/usr/bin/plutil -extract status raw -o - "$output/notarization.json") != Accepted ]]; then
        print -u2 "Apple did not accept the submission. See $output/notarization.json"
        exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    /usr/bin/codesign --verify --strict "$app"
    archive="$output/CrashPulse-$version-beta.zip"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
print "$archive"
