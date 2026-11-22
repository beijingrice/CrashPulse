# CrashPulse handoff

Last updated 2026-11-22. Read this file before editing and follow [AGENTS.md](AGENTS.md) for the project rules and UI design guide.

## Current notarized beta

- **Final ZIP** — [CrashPulse-0.1.0-beta.zip](CrashPulseP0/.build/notarization-20261122/CrashPulse-0.1.0-beta.zip). The ZIP is local to this Mac and lives under the git-ignored `.build` directory.
- **Build** — `0.1.0` (build `1`), source `75b67ed`, `CrashPulse-Sandbox-Off` Release, bundle ID `org.crashpulse.p0.off`. The executable contains `arm64` and `x86_64` and targets macOS 14 or later.
- **Apple notarization** — `Accepted` on 2026-11-22 for submission `5927dfd9-081b-4898-b1d9-3e5a66c11d74`. The Apple response is in `.build/notarization-20261122/result.json` under `CrashPulseP0/`.
- **Verified on the build Mac** — Developer ID Application signature with Hardened Runtime and a secure timestamp. After stapling the ticket to `CrashPulse.app`, the final ZIP was extracted into a separate directory. The extracted app passed strict signature verification for both architectures, `stapler validate`, and `syspolicy_check distribution`.
- **SHA-256** — `ad6376ed2bcecdb97f219b302858255f607e19f23a4bdec74edad9e39a62a47b`.

The remaining distribution check is a browser download on another Mac with Gatekeeper enabled. Extract the ZIP in Finder, move `CrashPulse.app` to Applications, and open it from Finder in a fresh test account. Check the welcome flow below, open Live and Events, and confirm events persist after relaunch. The ZIP has been verified locally and is still stored on the build Mac.

## Publish a new direct-download build

1. For a new release, update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `CrashPulseP0.xcodeproj` as appropriate. Record the source commit and keep the bundle ID `org.crashpulse.p0.off` for upgrades.
2. Run `security find-identity -v -p codesigning` in Terminal on the signing Mac. The identity used for this release was `Developer ID Application: Ning Gan (QHSG8V3GKU)`. The signing Mac needs the certificate and its matching private key in the Keychain.
3. Reuse the `crashpulse-notary` Keychain profile. To check it, run `xcrun notarytool history --keychain-profile crashpulse-notary`. If the profile is missing or its credentials expired, generate an app-specific password in the Apple Account and enter it at the secure prompt below. Substitute the team's Apple Account email. Keep the password in the local Keychain.

   ```sh
   xcrun notarytool store-credentials crashpulse-notary \
     --apple-id 'YOUR_APPLE_ACCOUNT_EMAIL' --team-id QHSG8V3GKU
   ```

4. From `CrashPulseP0/`, run the existing release script with a fresh output directory.

   ```sh
   release_dir=".build/beta-$(date +%Y%m%d-%H%M%S)"
   Scripts/prepare-beta.zsh "$release_dir" \
     'Developer ID Application: Ning Gan (QHSG8V3GKU)' crashpulse-notary
   ```

   The script builds the non-sandboxed Release with Hardened Runtime, signs with a secure timestamp, and stages it as `CrashPulse.app`. It submits `notary-submission.zip` to Apple and waits for `Accepted` in `notarization.json`. It then staples the ticket to the app, validates it, and creates `CrashPulse-<version>-beta.zip` from the stapled app. Share the `-beta.zip` produced by that last step.

5. Verify the final ZIP by extracting a fresh copy before the browser-download smoke test.

   ```sh
   version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
     "$release_dir/CrashPulse.app/Contents/Info.plist")
   zip="$release_dir/CrashPulse-$version-beta.zip"
   verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/crashpulse-release.XXXXXXXX")
   ditto -x -k "$zip" "$verification_dir" &&
     codesign --verify --strict --all-architectures "$verification_dir/CrashPulse.app" &&
     xcrun stapler validate "$verification_dir/CrashPulse.app" &&
     syspolicy_check distribution "$verification_dir/CrashPulse.app" &&
     shasum -a 256 "$zip"
   ```

   Record the final ZIP path, checksum, Apple submission ID and smoke-test result for the release.

If the script stops after submission, use the submission ID from `notarization.json` or find it with `xcrun notarytool history --keychain-profile crashpulse-notary`. Check its status with `xcrun notarytool info SUBMISSION_ID --keychain-profile crashpulse-notary`. For an `Invalid` result, get the issue details with `xcrun notarytool log SUBMISSION_ID --keychain-profile crashpulse-notary`. If Apple already accepted the staged app, resume with `xcrun stapler staple` and repack that same app using `ditto -c -k --sequesterRsrc --keepParent`. [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## Next task: finish verifying the welcome window

The first-launch welcome is implemented (see Recent work 9) but has only been checked through renders and window-level launch probes. Before calling it done:

- In a separate macOS test account (fresh preferences and history), launch the Release app and click through all three pages: Continue, Back, Return and Esc, Done, and Show Me. Show Me must close the window and open the menu bar panel anchored to the status item.
- Check the real window: the close button over the transparent title bar must not collide with the icon or titles, and the default button must be blue.
- Relaunch and confirm the welcome stays hidden. Open Settings › Show Welcome… and confirm it reappears.
- Do not test in the owner's account by deleting `welcomeCompleted`. `CFFIXED_USER_HOME` isolates the history directory but not preferences, so a probe there writes the owner's real `org.crashpulse.p0.off` domain.

## Current source and builds

- `master` contains the welcome window on top of `9bcc6d7`.
- The owner's day-to-day app at `CrashPulseP0/.build/xcode/Build/Products/Release/CrashPulseOff.app` was rebuilt on Nov 22 from the welcome commit, so it includes the attribution fix and the welcome. It is running. It skipped the welcome because the owner already has history, and wrote `welcomeCompleted = 1`.
- The Nov 21 ZIP in `CrashPulseP0/.build/beta-candidate/` was an ad hoc local test. The Nov 22 notarized ZIP above includes the welcome.
- The daily build and the notarized beta use `org.crashpulse.p0.off`. The daily journal is `~/Library/Application Support/CrashPulse/cpu-history.json`.
- Claude Design mirror of the panel (Events, Event detail, Live, with dark and severity switches): https://claude.ai/artifact/1VaNZyjmpBgS7zV1trhZqv. It is a hand-built mockup, private to the owner, not synced with code, and does not include the welcome.

## Build cache cleanup (2026-11-22)

Removed 77 regenerable Xcode and Swift cache directories and build intermediates from old builds and experiments. `CrashPulseP0/.build` went from 6,612,752 KiB (6.31 GiB) to 1,179,400 KiB (1.12 GiB), reclaiming **5.18 GiB**.

- Kept `CrashPulseP0/.build/xcode` in full, including the day-to-day `Build/Products/Release/CrashPulseOff.app`. The same process was running after cleanup.
- Kept the entire `CrashPulseP0/.build/notarization-20261122/` directory, including the final ZIP, submission archive, and Apple's `submission.json` and `result.json`. The copy at `~/Desktop/CrashPulse-0.1.0-beta.zip` was verified byte-for-byte against the final ZIP in the project.
- Kept performance measurements, logs, and stack samples in `.build/live-visibility-audit/`, `.build/self-spike-investigation/`, and `.build/status-power-audit/` under `CrashPulseP0/`. Historical benchmark results and `.xcresult` bundles were also retained.

## Build and verify from this checkout

Run these on the Mac. The checked toolchain is Xcode 27.2, and the app targets macOS 14 and later. **Reuse `CrashPulseP0/.build/xcode` for routine Debug, Release, test, and UI preview builds.** The release packaging script uses a separate output directory for each notarized distribution.

```sh
cd /Users/rice/Documents/ChatGPT/crashPulse/CrashPulseP0

xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode test

# Build the app explicitly. The test target builds the model and XCTest bundle.
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode build
.build/xcode/Build/Products/Debug/CrashPulseOff.app/Contents/MacOS/CrashPulseOff \
  --render-ui .build/ui-onboarding

xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode build
/usr/bin/codesign --verify --strict .build/xcode/Build/Products/Release/CrashPulseOff.app
```

`--render-ui` uses built-in samples by default. To render existing records, pass a scratch copy of the history directory as its second argument. To test the actual Release window, use `open .build/xcode/Build/Products/Release/CrashPulseOff.app` in the test login. If replacing an active instance, quit it normally first so the journal flushes. For a distribution ZIP, follow [Publish a new direct-download build](#publish-a-new-direct-download-build).

## Source map

| File | Role |
| --- | --- |
| `ProcessCollector.swift`, `Sampling.swift`, `LibprocBridge.c` | libproc scans, process identity checks, CPU and energy deltas |
| `HighCPUTracker.swift` | Event detection per process and per app group (helpers roll up to their app) |
| `EventForensics.swift` | 180 s rolling frames, before/during/after context, likely-app attribution, impact level |
| `CPUHistory.swift` | Journal storage: lock, atomic writes, 30 s checkpoints, recovery, damaged-file quarantine |
| `BatteryUsage.swift` | Per-day battery energy ranking (export only since Overview was removed) |
| `CrashPulseApp.swift` | App delegate (popover, Settings and welcome windows, first-launch check), sampling actor and `MonitorModel` |
| `MonitorViews.swift` | All panel UI, the first-launch `WelcomeView`, Settings window, and the Debug-only `UIPreviewRenderer` |
| `HistoryCommand.swift`, `Diagnostics.swift` | `--monitor`, `--history`, `--capture` command-line modes |
| `Design/AppIcon.svg`, `Design/AppIcon-small.svg`, `Scripts/make-icon.zsh` | App icon sources and the script that builds `CrashPulse/AppIcon.icns` |

## Recent work

1. Robustness: an unreadable history file or record is moved aside as `cpu-history.damaged-*.json` and recording continues. Per-window process names were moved into a shared label table, cutting memory at the 1 s interval from 139 MB to 58 MB.
2. Detection across app helpers: sustained load spread over several helpers of one app now triggers an event (`a1c4827`).
3. History writes are batched at 30 s checkpoints instead of every scan (`b4056c2`). App bundle classification is cached (`8d2498f`).
4. Panel redesign (`70744b5`): Overview removed. Events are grouped by day with severity dots and sparklines. Event detail follows the four tiers in `AGENTS.md`, with one continuous CPU trace. Live has a 3-minute trend and ranked apps with share bars. Debug builds have `--render-ui`.
5. Event detail gives the status and observed duration more weight, with exact timestamps and the end reason below. A process disappearing from samples is described as an observation. Verified the status in light and dark renders and the real Release popover.
6. App icon (`4b52c45`, `468470a`): a calm CPU trace rising into a sustained plateau inside a tinted event span, matching the event detail chart. The owner approved this version. Both targets bundle `AppIcon.icns` through `CFBundleIconFile`, and Finder shows it. To change the icon, edit the SVGs in `Design/` and run `Scripts/make-icon.zsh` (needs `rsvg-convert` from Homebrew). Never edit the `.icns` directly. The small SVG is a simplified variant for 16 and 32 px, so keep the two in step. The menu bar item still uses the `waveform.path.ecg` SF Symbol on purpose.
7. A hidden Live view stops grouping and charting while keeping its controls and background monitoring. In the same plugged-in Release process with 5-second sampling, 75-second samples measured 2.5 mW at startup with the panel closed, 56.8 mW in Live, and 4.9 mW after closing it. The previous closed-after-Live measurement was 56.6 mW. The new closed-state stack sample showed the sampling worker and did not capture Live grouping. Reopening Live showed the samples taken while hidden and retained its sort setting. Raw measurements and stack samples are in the local `.build/live-visibility-audit` directory.
8. Event details and rows distinguish the recorded CPU trigger from a different likely contributor. The trace and peak follow the trigger and the CPU energy estimate follows the contributor. Verified the split in light and dark previews and in the real popover of the unpacked Hardened Runtime build. `Scripts/prepare-beta.zsh` packages the local Release and supports Developer ID signing and notarization. The local ZIP is in `.build/beta-candidate`.
9. First-launch welcome: a 440×480 window with a transparent title bar and three pages. 1, what CrashPulse does, with the signature trace. 2, what it watches (sample interval, 30-second rule, explanations) plus the Mac's live CPU from `MonitorModel.activity`. 3, where it lives, with a menu bar and panel sketch and a note that the event list can start empty. Show Me closes the window and opens the real panel. It appears only on a true first launch of the Sandbox Off build: no `welcomeCompleted` default and no history journal. Existing users with a journal are marked done silently, and closing the window any way marks it seen. Settings has Show Welcome…, and launching with `-showWelcome YES` forces it. Verified: light and dark renders of all three pages (`--render-ui` scenes `8-welcome-*`); launch probes with an isolated history directory for fresh install (shown), existing journal (hidden), already seen (hidden) and forced (shown); a 440×480 window frame; 52 unit tests (the test target does not compile the app or view files). Not yet verified by clicking through a real window; see Next task.

## Other open work

1. **Investigate the earlier CrashPulseOff spike if it recurs.** The Nov 21 journal attributed 0.729 Wh of CPU energy to a 7m 50s event with a 99.8% peak. The macOS report put the sampled hot interval on the main thread in AppKit and SwiftUI layout and rendering. An eight-minute old-Release replay with Live open and the app's own row expanded did not reproduce the sustained spike. The trigger remains unverified. Local evidence is in `CrashPulseP0/.build/self-spike-investigation/`.
2. **Redesign the Settings window** (`MonitorSettingsView`) to match the panel. It is still a plain grouped form with a paragraph of explanation. Apply the AGENTS.md rules and add it to `UIPreviewRenderer`.
3. **System processes are invisible.** About 16% of processes (root and other-user daemons such as WindowServer, mds_stores, backupd) return `EPERM` for resource reads, so their spikes are never detected. The setuid `/bin/ps` can read them. Options: a low-frequency `ps` fallback for denied PIDs, or a privileged helper through `SMAppService`. Discuss the choice with the owner before building it.
4. **The command line has no foreground context.** `HistoryCommand.monitor` never sets `snapshot.foregroundPID`, so events recorded through `--monitor` can never be rated "busy in the background". Either read the frontmost app there too, or document the gap.
5. **Energy attribution.** CrashPulse uses `ri_energy_nj`, which excludes energy that daemons spend on an app's behalf. Consider also reading `ri_billed_energy` for a "billed" figure. It is Apple silicon only either way.
6. **Threshold tuning.** After a warm baseline, the trigger can fall to 45% of one core, which may be noisy on many-core Macs. Collect representative beta usage before changing it.
7. **Optional: adaptive icon appearances.** The `.icns` has a single light appearance. macOS 26 can show dark, clear and tinted variants for icons made in Icon Composer (`.icon` in an asset catalog). Only do this if the owner asks. Reuse the existing SVG artwork, keep the light version identical, and keep `make-icon.zsh` working for older systems.

## Handoff approval

- Read this file before making changes.
- When the work is ready, tell the owner what changed, where the build is, what was actually verified, and what is still open. Include screenshots for UI work.
- Wait for the owner's approval before updating this handoff. An explicit request to maintain the handoff authorizes that update.
