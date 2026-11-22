# CrashPulse handoff

Last updated 2026-11-22. Read this file before editing and follow [AGENTS.md](AGENTS.md) for the project rules and UI design guide.

## Next task: first-launch experience

Build a first-launch interface for people opening CrashPulse for the first time. The current app has no onboarding state or welcome screen. `CrashPulseDelegate.applicationDidFinishLaunching` in `CrashPulseP0/CrashPulse/CrashPulseApp.swift` installs the menu bar item and starts monitoring. The app uses `LSUIElement`. `MonitorModel` reads `monitoringEnabled` and `monitoringInterval` from `UserDefaults`, with monitoring on and a 5-second interval by default. Opening the menu bar panel enters Events on the non-sandboxed build.

- Start with `CrashPulseApp.swift` for launch and window coordination and `MonitorViews.swift` for SwiftUI, `PanelMessage`, design tokens, and preview rendering. Sketch the flow and explain when it appears, how users reach the menu bar panel, and what happens on relaunch. Show the owner the sketch before implementing a substantial UI redesign.
- Explain what CrashPulse watches, where to find it, and that there may be no events yet. Preserve the menu bar workflow and the Events and Live tabs. Follow the current measurement copy for CPU energy and sampling coverage.
- Verify first launch and relaunch in a separate macOS test account or machine with fresh preferences and history. Add a first-launch scene to `UIPreviewRenderer` for light and dark screenshots and use the actual Release app to verify launch behavior. The CLI `--history-dir` option applies to `--monitor` and `--history`. Keep the owner's preferences and history in place.

## Current source and builds

- App baseline is commit `74fad09` on `master`. It includes the attribution fix and beta packaging script. There is no first-launch implementation yet.
- Latest verified Release app: `CrashPulseP0/.build/beta-candidate/CrashPulse.app`. Latest ZIP: `CrashPulseP0/.build/beta-candidate/CrashPulse-0.1.0-local-test.zip`. Both use Hardened Runtime and a local ad hoc signature. The unpacked ZIP was verified and used for the actual menu bar and four-Helper smoke tests on Nov 21.
- The separate day-to-day app at `CrashPulseP0/.build/xcode/Build/Products/Release/CrashPulseOff.app` predates that attribution fix. Both artifacts use `org.crashpulse.p0.off`. The daily journal is `~/Library/Application Support/CrashPulse/cpu-history.json`.
- The Nov 21 attribution build passed all 52 unit tests. Its Debug app is in `CrashPulseP0/.build/beta-debug/Build/Products/Debug/CrashPulseOff.app`, with light and dark renders in `CrashPulseP0/.build/ui-beta-attribution/`.

## Build and verify from this checkout

Run these on the Mac. The checked toolchain is Xcode 27.2, and the app targets macOS 14 and later. Use a dedicated derived-data directory for onboarding so the existing builds stay available.

```sh
cd /Users/rice/Documents/ChatGPT/crashPulse/CrashPulseP0

xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/onboarding-xcode test

# Build the app explicitly. The test target builds the model and XCTest bundle.
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/onboarding-xcode build
.build/onboarding-xcode/Build/Products/Debug/CrashPulseOff.app/Contents/MacOS/CrashPulseOff \
  --render-ui .build/ui-onboarding

xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/onboarding-xcode build
/usr/bin/codesign --verify --strict .build/onboarding-xcode/Build/Products/Release/CrashPulseOff.app
```

`--render-ui` uses built-in samples by default. To render existing records, pass a scratch copy of the history directory as its second argument. To test the actual Release window, use `open .build/onboarding-xcode/Build/Products/Release/CrashPulseOff.app` in the test login. If replacing an active instance, quit it normally first so the journal flushes. To rebuild the ZIP from current source, run `Scripts/prepare-beta.zsh` with a new output directory. [README](CrashPulseP0/README.md#prepare-a-direct-download-beta) has the Developer ID and notarization commands.

## Source map

| File | Role |
| --- | --- |
| `ProcessCollector.swift`, `Sampling.swift`, `LibprocBridge.c` | libproc scans, process identity checks, CPU and energy deltas |
| `HighCPUTracker.swift` | Event detection per process and per app group (helpers roll up to their app) |
| `EventForensics.swift` | 180 s rolling frames, before/during/after context, likely-app attribution, impact level |
| `CPUHistory.swift` | Journal storage: lock, atomic writes, 30 s checkpoints, recovery, damaged-file quarantine |
| `BatteryUsage.swift` | Per-day battery energy ranking (export only since Overview was removed) |
| `CrashPulseApp.swift` | App delegate, popover, sampling actor and `MonitorModel` |
| `MonitorViews.swift` | All panel UI, Settings window, and the Debug-only `UIPreviewRenderer` |
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

## Other open work

Before outside beta distribution, provide a Developer ID Application identity and a `notarytool` Keychain profile, then download and smoke-test the notarized ZIP on another Mac. This machine had no usable Developer ID Application identity during the local package check.

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
