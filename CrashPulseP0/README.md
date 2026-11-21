# CrashPulse P0

CrashPulse is a macOS menu bar app that keeps diagnostic reports of sustained CPU activity and its likely contributors. The two app targets share the sampler and interface. They differ in bundle identifier and sandbox entitlements.

## Build and run

Use Xcode 15 or later with a macOS SDK. The app targets macOS 14.0 and later. The paired experiment requires an interactive macOS login and an ordinary user account. Xcode signs both builds locally with an ad hoc signature, so local testing requires no Apple Developer team.

Open `CrashPulseP0.xcodeproj` in Xcode. Select **CrashPulse-Sandbox-Off**, choose **My Mac**, and press ⌘R. Click the waveform icon in the macOS menu bar. Monitoring starts automatically on first launch and the first CPU readings appear after two samples. **Events** opens first. Click an event to see a likely app, the before, during, and after timeline, the three leading processes, and suggested next steps. **Overview** shows the latest event, current measured CPU, and today's battery ranking. **Live** shows app groups ranked by CPU or power, an expandable process list, and the recent CPU trend.

Open **Settings…** from the panel to change the sample interval or export the latest process sample or the battery ranking and events. The default interval is 5 seconds. Changes restart the sampling baseline. Pause and resume from the panel or Settings. The app remembers the monitoring switch and interval. Closing the panel or Settings keeps the sampler running. Use **Quit CrashPulse** to exit the app. The **CrashPulse-Sandbox-On** scheme remains available for the permissions experiment.

From this directory on Apple Silicon:

```sh
xcodebuild -list -project CrashPulseP0.xcodeproj
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-On \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-Off \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build

open .build/xcode/Build/Products/Debug/CrashPulseOn.app
open .build/xcode/Build/Products/Debug/CrashPulseOff.app
```

On an Intel Mac, use `-destination 'platform=macOS,arch=x86_64'`. For an optimized build, use `-configuration Release` and the `Build/Products/Release` directory.

## Record and investigate CPU events with Sandbox Off

The menu bar monitoring switch also starts and stops the recorder in Sandbox Off. The command-line entry points work without opening a window. Build **CrashPulse-Sandbox-Off**, then run the executable inside the signed app bundle as your regular user:

```sh
runner=.build/xcode/Build/Products/Debug/CrashPulseOff.app/Contents/MacOS/CrashPulseOff
"$runner" --monitor
```

Use Ctrl+C to stop. Run these commands in another Terminal tab to read or export history while the recorder is running or after it exits:

```sh
runner=.build/xcode/Build/Products/Debug/CrashPulseOff.app/Contents/MacOS/CrashPulseOff
"$runner" --history
"$runner" --history > crashpulse-events.json
```

- The default interval is 5 seconds. `--monitor --interval 1|2|5|10` selects an interval. `--duration SECONDS` runs a bounded session. Both commands accept `--history-dir PATH` to use a separate history directory.
- A CPU event requires 30 seconds of adjacent valid windows for one app group or a standalone process. For an app, eligible helpers under the outermost bundle contribute their CPU usage over the shared sample interval. At least one verified member must link adjacent windows. Known missing member readings are flagged, and the measured sum can still trigger an event if it reaches the threshold. The cold-start threshold is 80% of one logical core. After 15 seconds of below-threshold readings, the trigger uses the largest of 45%, the learned baseline plus 35 percentage points, and 1.5 times the baseline. A candidate keeps its onset threshold. Wake resets, sampling gaps, or wall-clock jumps break continuity. Per-process windows longer than twice the configured interval are discarded.
- The recorder keeps up to three minutes of recent process windows in memory. When an event qualifies, it retains up to 30 seconds of context before onset, cumulative contributions for the entire event, and up to 15 seconds of follow-up scans at the default interval. With the 10 second setting it allows up to 30 seconds of follow-up. An early stop or missing data can leave a partial timeline. Older journal records are preserved with their original fields.
- The three leading processes are ranked by observed CPU core-seconds within the event. Their share uses all measured process CPU in that window. The likely app is ranked separately using the increase over its comparable pre-event CPU baseline or verified process starts near onset. With limited baseline evidence, the ranking uses observed CPU. The report shows estimated extra CPU energy only for comparable measured windows. It identifies likely contributors and foreground context. The original in-app task remains unknown when sampling cannot identify it.
- Live and event attribution group real executable paths under the outermost app bundle, so nested helpers roll up to their host app. Standalone executables are shown separately. Processes without an available path remain separate. Impact labels use duration, relative CPU increase, estimated excess CPU energy where available, and foreground context. Recurring background activity requires repeated observed events on separate days. The app offers suggestions and a reversible Ignore action. It does not stop or modify processes.
- The journal lives in `~/Library/Application Support/CrashPulse/cpu-history.json`. Data stays on the Mac. The store keeps at most 512 events whose last observation falls in the past seven days. Cleanup runs during monitoring and when the next reader or writer opens the history. The file is updated atomically, and one recorder owns a journal at a time. Concurrent `--history` readers can view the latest complete write. After an unexpected recorder exit, the next reader or writer closes active records as `monitorInterrupted` without adding elapsed time. If the journal or some of its records cannot be decoded, the next writer keeps the readable records, moves the original file aside as `cpu-history.damaged-<time>-<id>.json` in the same directory, and continues recording. A journal written by a newer schema version is left untouched and recording stops with an error.
- Ordinary event and battery updates share a 30-second checkpoint. Event detection, event end, completed follow-up, Ignore or Restore, and a normal stop save pending updates immediately. An unexpected exit can lose the ongoing updates since the last successful checkpoint. The menu panel shows a warning if history cannot be saved.

To run the end-to-end test, pass the signed app and a new output directory. It uses 44 seconds of bounded CPU load. It checks the process name and PID, event duration, measured CPU energy in Wh, contribution ranking, timeline coverage, and persistence after the fixture exits and the recorder restarts.

```sh
Scripts/test-history.zsh .build/xcode/Build/Products/Debug/CrashPulseOff.app ".build/history-test-$(date +%Y%m%d-%H%M%S)"
```

To verify app-level detection, run the four-helper fixture. It checks that each helper individually stays below the trigger floor while their combined load makes one persistent app event with helper evidence and a follow-up timeline.

```sh
Scripts/test-app-trigger.zsh .build/xcode/Build/Products/Debug/CrashPulseOff.app ".build/app-trigger-test-$(date +%Y%m%d-%H%M%S)"
```

To measure default-interval memory, CPU time, and logical journal writes, run the 220-second benchmark. Supply a raw `cpu-history.json` from the standalone history test as the seed. The benchmark copies one complete event into 500 test records, adds one malformed record, and verifies recovery and persistence of a new event after a 60-second load. It writes metrics and test history to its own directory.

```sh
xcrun python3 Scripts/benchmark-history.py .build/xcode/Build/Products/Release/CrashPulseOff.app \
  .build/history-test-example/history/cpu-history.json ".build/history-benchmark-$(date +%Y%m%d-%H%M%S)"
```

## Verify App Sandbox

In Activity Monitor, enable **View → Columns → Sandbox** and check **Yes** for `CrashPulseOn` and **No** for `CrashPulseOff`. The diagnostic JSON also includes the sandbox entitlement read from the running task via Security.framework. Launch from Xcode or Finder for the experiment so both apps start in the logged-in user’s environment. [Apple’s App Sandbox guide](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)

```sh
products=.build/xcode/Build/Products/Debug
for variant in On Off; do
  codesign --verify --strict "$products/CrashPulse$variant.app"
  codesign -d --xml --entitlements - "$products/CrashPulse$variant.app"
done
```

Sandbox On has `com.apple.security.app-sandbox` and user-selected read/write access for the save dialog. Sandbox Off has no App Sandbox entitlement. The app requires no special privileges or privacy permissions.

## Test and reproduce the comparison

Both schemes run the same application-independent XCTest bundle. In Xcode press ⌘U, or run:

```sh
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-On \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode test
```

The paired capture requires the bundled Xcode command-line tools, including `xcrun clang` and `xcrun python3`. Run it from Terminal while logged into the Mac desktop, after building both targets:

```sh
Scripts/compare.zsh .build/xcode/Build/Products/Debug ".build/comparison-$(date +%Y%m%d-%H%M%S)"
```

The script verifies the signatures and exact entitlements, then launches both app bundles through LaunchServices. Each checks its actual task entitlement and UID, then takes four scans at a 5-second interval. If the first scan finds the transient PID, it waits 9 seconds so a test-owned 7-second `sleep` exits before its row is read. The three following scans supply the comparison counts and record any enumeration failures.

The script also supplies known PIDs for each monitor itself, Finder, a two-thread CPU fixture, the fixture’s idle child, system-owned PID 1, and WindowServer when present. Both apps probe those PIDs with the same reads. This measures per-PID access even when listing is denied. The direct readings are in `knownPIDSnapshots`, outside the enumeration totals. Set `CRASHPULSE_GUI_PID` to test a different already-running user app.

If launch takes longer than the transient process lifetime, rerun into a new directory. Read `summary.txt` for the comparison and the two JSON files for the underlying exports. The runner leaves these files locally. They may contain private process names, PIDs, paths, and UIDs.

To generate a bounded load for the menu bar panel, enable monitoring at 1 or 5 seconds, then run:

```sh
mkdir -p .build
xcrun clang -O2 -Wall -Wextra -Werror Scripts/cpu-load.c -o .build/cpu-load
.build/cpu-load 20
```

The fixture prints its PID and its idle child’s PID. Search by PID in **All processes** or the export. It runs two busy threads, so an accessible fixture can exceed 100%. Both processes exit on their own. To check wake behavior, start monitoring, sleep and wake the Mac, then check that a fresh baseline precedes the next CPU reading.

## CPU power and energy

On Apple silicon, CrashPulse attempts to read the kernel's cumulative per-task CPU energy field, `ri_energy_nj`, through the SDK's `proc_pid_rusage(RUSAGE_INFO_V6)`. It uses the change in energy across two readings of the same verified process instance. **Wh** (watt-hours) is energy used in the measured interval. **W** (watts) is the interval's average power. The app uses the same counter on battery and when plugged in. The plug or battery label comes separately from IOKit. [Apple XNU resource fields](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) · [IOKit power source API](https://developer.apple.com/documentation/iokit/iopowersources_h/1810316-iopsgetprovidingpowersourcetype)

These readings cover CPU energy attributed to the process. GPU, the display, charging and other system hardware are outside this estimate. A power reading does not tell you what share of the battery a process used. Hardware with no usable counter and denied or invalid readings show a dash. CPU and memory can still be available independently. MacPow provided the reference for a power-focused ranking and uses a separate billed-energy field for its own process display. [MacPow implementation notes](https://github.com/k06a/macpow#power-measurements-vs-estimates)

The battery ranking in **Overview** uses the Mac's local date. It counts verified intervals between consecutive scans that both started and ended on battery, discarding observed supply transitions, long gaps, sleep discontinuities, and samples that cross midnight. Processes whose executable paths are inside the same outermost app bundle share a row, including nested helpers. Standalone executables have their own row. Processes without a usable path are grouped as unidentified. Percentages are shares of measured process CPU energy during tracked battery time. Brief supply changes between polls may go unobserved.

The panel updates from the current recorder while it is open. The ranking still shows that day's recorded battery use after reconnecting power or restarting CrashPulse. A new day starts a new total.

The history export (schema 4) includes `observedCPUEnergyWattHours`, time covered by energy readings, optional `forensics` evidence, `recurringBackgroundActivity`, and an optional `batteryToday` section. App events include `triggerApp` and may flag `incompleteAppSamples`. Earlier on-disk schema versions are upgraded automatically. Live diagnostics (schema 2) include power supply and per-process `cpuPower` with `watts` and `intervalWattHours`.

## Sampling rules and limits

- `proc_listpids(PROC_ALL_PIDS)` is the byte-count API behind `proc_listallpids`. The sampler grows the PID buffer when full and validates byte counts. Coverage counts unique, positive PIDs, excluding PID 0. A failed enumeration clears the baselines. [Apple libproc source](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)
- Identity is the PID and BSD start time in seconds and microseconds. The sampler checks identity before and after the other reads, then compares the resource record’s Mach start tick across consecutive scans as a second process-instance check. A new, reused, or missing PID, an identity failure, or a resource failure breaks continuity. A process which starts and exits entirely between scans can be missed.
- CPU is `100 × (delta user CPU + delta system CPU) / delta awake elapsed time`. The resource counters and `mach_absolute_time` are in Mach ticks. The sampler subtracts unsigned counters, checks regression and overflow, then converts both deltas to nanoseconds using `mach_timebase_info`. One fully occupied logical core is 100%. The result averages activity across the interval and can exceed 100%. Read timing and scheduler activity can add variation, especially at 1 second. [XNU resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) · [XNU task time units](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)
- Awake elapsed time excludes sleep. A wake notification or at least 5 ms of additional continuous-clock time resets the affected baseline. The tolerance accommodates skew between adjacent clock reads. Wake or registration changes can leave a row waiting for its next baseline. Wall time is used only for timestamps.
- `proc_pid_rusage` returns a success/failure status and no byte count. The sampler uses the exact SDK structure for its flavor and checks its required fields. A denial of identity or resources produces no CPU or memory fields. Name and path availability are reported separately. A row can have a valid CPU sample and a path error. Memory is instantaneous. Diagnostic JSON includes resident size and footprint in bytes.
- libproc entry points are supplied by the SDK. Cross-process visibility varies with ownership, OS policy, and sandbox configuration. Some libproc interfaces carry a stability warning in Apple’s header. Review the measured coverage in `P0_REPORT.md` before choosing a distribution strategy. [Apple libproc header](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)

## JSON format

Each diagnostic export contains `schemaVersion`, `run` with app version, build number, bundle ID, variant, live entitlement and UID, `intervalSeconds`, the Mach `timebase`, and `snapshots`. Settings exports one scan and any current history storage error. The experiment exports four scans and capture performance. Row timestamps use ISO 8601 UTC. Unavailable optional fields are omitted. Coverage separately counts rows with verified identity, resources, memory, a CPU delta, a waiting baseline, or a failed sample. Error counts are by affected row and category, with per-API detail in `issues`.

Example of an inaccessible row within `snapshots[].rows` (illustrative):

```json
{
  "pid": 123,
  "sampledAt": "2026-11-20T12:00:05Z",
  "state": "inaccessible",
  "issues": [
    {"stage": "identity", "category": "permissionDenied", "errorNumber": 1, "returnValue": 0},
    {"stage": "resources", "category": "permissionDenied", "errorNumber": 1, "returnValue": -1}
  ]
}
```
