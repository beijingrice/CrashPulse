# CrashPulse handoff

Last updated 2026-11-21. Read `AGENTS.md` first for build commands, working rules and the UI design guide. This file says where the work stands and what to do next.

## Where things are

- Code: `CrashPulseP0/` in this repository, branch `master`. The continuous-timeline redesign landed in `70744b5`.
- The owner runs the Release Sandbox Off build from `CrashPulseP0/.build/xcode/Build/Products/Release/CrashPulseOff.app` (bundle ID `org.crashpulse.p0.off`). It records to `~/Library/Application Support/CrashPulse/cpu-history.json`.
- 52 unit tests pass. Both schemes build in Release.

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

## Open work, in suggested order

1. **Investigate the earlier CrashPulseOff spike if it recurs.** The Nov 21 journal attributed 0.729 Wh of CPU energy to a 7m 50s CrashPulseOff event with a 99.8% peak. Its cause remains unverified.
2. **Redesign the Settings window** (`MonitorSettingsView`) to match the panel. It is still a plain grouped form with a paragraph of explanation. Apply the AGENTS.md rules and add it to `UIPreviewRenderer`.
3. **System processes are invisible.** About 16% of processes (root and other-user daemons such as WindowServer, mds_stores, backupd) return `EPERM` for resource reads, so their spikes are never detected. The setuid `/bin/ps` can read them. Options: a low-frequency `ps` fallback for denied PIDs, or a privileged helper through `SMAppService`. Discuss the choice with the owner before building it.
4. **The command line has no foreground context.** `HistoryCommand.monitor` never sets `snapshot.foregroundPID`, so events recorded through `--monitor` can never be rated "busy in the background". Either read the frontmost app there too, or document the gap.
5. **Energy attribution.** CrashPulse uses `ri_energy_nj`, which excludes energy that daemons spend on an app's behalf. Consider also reading `ri_billed_energy` for a "billed" figure. It is Apple silicon only either way.
6. **Threshold tuning.** After a warm baseline, the trigger can fall to 45% of one core, which may be noisy on many-core Macs. The owner's real history so far contains only test-fixture events, so collect a few days of real data before changing it.
7. **Optional: adaptive icon appearances.** The `.icns` has a single light appearance. macOS 26 can show dark, clear and tinted variants for icons made in Icon Composer (`.icon` in an asset catalog). Only do this if the owner asks. Reuse the existing SVG artwork, keep the light version identical, and keep `make-icon.zsh` working for older systems.

## Before you finish a session

- Run the tests. For UI changes, render and look at the screenshots.
- Commit with a clear message.
- Update this file: move finished items into Recent work, add anything new you found, and change the date.
