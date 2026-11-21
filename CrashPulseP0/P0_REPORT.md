# CrashPulse P0 feasibility report

**GO — Unsandboxed Developer ID distribution is more appropriate.** On the test Mac, the signed Sandbox On build received `EPERM` for every process enumeration. Direct reads succeeded for its own PID. The same build could read identity for Finder and the user-owned fixtures, but resource reads returned `EPERM`. Sandbox Off produced CPU percentages for **4,139 of 4,968 enumerated process observations (83.31%)**, including Finder and the CPU fixture. Both variants lacked CPU and memory for launchd and WindowServer.

## A. Build verification

Verified on November 20, 2026, on a MacBook Pro (`Mac16,7`, Apple M4 Pro, arm64) running macOS 26.7.1 (25G241). The toolchain was Xcode 27.2 (27B52) with macOS SDK 27.2. The effective UID was 501 throughout the captures. The apps were ad hoc signed using Xcode’s **Sign to Run Locally** identity. The built Info.plist reported a minimum OS version of 14.0. Runtime behavior was verified on macOS 26.7.1.

Successful verification commands from the project directory (build output redirection omitted):

```sh
xcodebuild -list -project CrashPulseP0.xcodeproj
for variant in On Off; do
  xcodebuild -project CrashPulseP0.xcodeproj -scheme "CrashPulse-Sandbox-$variant" \
    -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-verified build
done
xcodebuild -project CrashPulseP0.xcodeproj -scheme CrashPulse-Sandbox-On \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-verified \
  -resultBundlePath .build/verified-tests.xcresult test
Scripts/compare.zsh .build/xcode-verified/Build/Products/Debug .build/comparison-final
for variant in On Off; do
  xcodebuild -project CrashPulseP0.xcodeproj -scheme "CrashPulse-Sandbox-$variant" \
    -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-verified build
done
xcrun xcresulttool get test-results summary --path .build/verified-tests.xcresult
```

Xcode listed both shared schemes, built both variants in Debug and Release, and ran 19 tests with zero failures. The paired capture completed with exit status 0. Both Debug apps opened their SwiftUI windows as the logged-in user. Start, Stop, and Export JSON worked in both. Sandbox Off rendered a CPU-sorted table and exported 1,633 rows, including 1,361 CPU values from the stopped snapshot. Sandbox On rendered the enumeration error and exported that error. Both saved JSON files were parsed successfully.

The initial build under the execution host’s restricted shell could not run Xcode’s SwiftUI macro service. The successful builds used Xcode with access to its local compiler and test services, under the ordinary user. The preliminary test scheme let Xcode re-sign the Sandbox On app with test-only exceptions. That run was discarded. The final schemes test a standalone bundle, and the comparison script checks the exact app entitlements before launching either app.

## B. API compatibility

The installed SDK’s `usr/include/libproc.h`, `usr/include/sys/proc_info.h`, `usr/include/sys/resource.h`, and `usr/include/mach/mach_time.h` supplied declarations and layouts. The code uses the SDK’s `proc_bsdinfo` and `rusage_info_v0` directly. The C bridge adapts the resource call’s opaque pointer parameter.

| API | Verified behavior |
| --- | --- |
| `proc_listpids(PROC_ALL_PIDS)` | Returned byte counts and populated the table in Sandbox Off. Returned zero with `EPERM` in Sandbox On. `proc_listallpids` uses this call. |
| `proc_pidinfo(PROC_PIDTBSDINFO)` | Returned complete identity data for eligible user-owned PIDs, including Finder on both builds. Denied launchd and WindowServer in both. Verified with a second read after the resource query. |
| `proc_name` | Provided names for the eligible targets, including those the sandbox could identify but whose resource data it denied. Denied launchd and WindowServer. |
| `proc_pidpath` | Provided executable paths for Finder, the fixtures, launchd, and WindowServer in both variants when their PIDs were supplied. A path alone provides no verified identity. |
| `proc_pid_rusage(RUSAGE_INFO_V0)` | Provided cumulative CPU ticks, resident bytes, and physical footprint for self in both variants and for the user-owned comparison targets in Sandbox Off. Returned `EPERM` for the other direct targets in Sandbox On and for launchd and WindowServer in both. |
| `mach_timebase_info` and the Mach clocks | The live timebase was 125/3. Apple’s published XNU implementation assigns Mach-time counters to `ri_user_time` and `ri_system_time`. The absolute clock provides awake elapsed time and the continuous clock detects sleep discontinuities. |

The runtime results establish the behavior of these interfaces on the tested OS. The published libproc header describes interface stability limits. [Apple libproc declarations and wrappers](https://github.com/apple-oss-distributions/xnu/tree/main/libsyscall/wrappers/libproc) · [XNU resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) · [XNU Mach tick counters](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6387-L6392)

## C. Sandbox comparison

The paired Debug capture began at **20:53:36 China Standard Time**. LaunchServices started the actual signed bundles on the same logged-in Mac. The runner verified each signature with `codesign --verify --strict`. Sandbox On’s exact signed entitlements were App Sandbox and user-selected file read/write. Sandbox Off had an empty entitlement dictionary. The running tasks independently reported their respective entitlement states through `SecTaskCopyValueForEntitlement`.

The table covers the three follow-up scans at 5 seconds. The first scan established baselines and exercised a controlled exit. Each follow-up process row contributes one observation. Sandbox On had no denominator for per-row coverage.

| Metric | Sandbox On | Sandbox Off |
| --- | ---: | ---: |
| Successful enumeration scans | 0/3 | 3/3 |
| PIDs per scan | 0, 0, 0 | 1,653, 1,658, 1,657 |
| Verified process identity | n/a | 4,163/4,968 (83.80%) |
| Valid resource reading | n/a | 4,163/4,968 (83.80%) |
| CPU percentage | n/a | 4,139/4,968 (83.31%) |
| Resident bytes and footprint | n/a | 4,163/4,968 (83.80%) |
| Name | n/a | 4,163/4,968 (83.80%) |
| Executable path | n/a | 4,965/4,968 (99.94%) |
| Waiting for a baseline | n/a | 24 (0.48%) |
| Failed process samples | n/a | 805 (16.20%) |
| Issues | 3 enumeration denials (errno 1) | 805 rows with permission denied (errno 1), 3 rows with exit errors (errno 3), with overlap |
| Final row states among failures | n/a | 802 inaccessible, 3 exited |

The runner also passed the listed PIDs directly to both builds. These readings used the same per-process calls and CPU calculation with independent baselines. They are outside the enumeration totals.

| Process class | Sandbox On | Sandbox Off |
| --- | --- | --- |
| Monitor itself | Identity, CPU and memory in 3/3 follow-up reads | Identity, CPU and memory in 3/3 follow-up reads |
| Finder, UID 501 | Identity, name and path. Resources denied in 3/3. | Identity, CPU and memory in 3/3. |
| Idle child of CPU fixture, UID 501 | Identity, name and path. Resources denied in 3/3. | Identity, CPU and memory in 3/3. Measured 0.0% CPU. |
| `launchd`, PID 1, UID 0 | Path available. Name, identity, and resources denied in 3/3. | Same result. |
| WindowServer, PID 395, UID 88 | Path available. Name, identity, and resources denied in 3/3. | Same result. |
| Two-thread CPU fixture, UID 501 | Identity, name and path. Resources denied in 3/3. | Identity and memory in 3/3. CPU was 198.5%, 198.9%, and 198.6%. |
| Controlled short-lived process | Enumeration itself denied. The exit race could not be exercised. | PID 22194 was enumerated, then exited before its read. All four reads returned `ESRCH`. The row contained no CPU or memory, and the PID was absent from the next three scans. |

Sandbox materially reduced coverage on this host. It blocked process discovery and CPU or memory for every tested external PID, including same-user targets supplied explicitly. Unsandboxed monitoring had useful same-user coverage and retained restrictions for the tested system-owned processes.

## D. Correctness

**19 XCTest cases passed, zero failures.** Mocked coverage includes a missing first CPU sample, non-1:1 conversion, delta arithmetic for large counters, above-100% CPU, genuine idle, counter regression and overflow, zero and backwards elapsed time, PID reuse, new and disappearing processes, missing and mismatched identity, `EPERM` and `EACCES`, failed or partial reads, enumeration failure, invalid timebase, and wake reset.

The paired run confirmed no CPU or memory values on inaccessible or exited rows and showed a real two-thread workload above 100%. A successful sample represents an average over the actual per-PID monotonic interval. Baselines cover consecutive reads of one verified process instance. Short-lived processes can start and exit between scans. Physical sleep and wake, forced OS PID reuse, and live partial kernel reads were covered by simulation only. The SDK call surface supplies no byte count for the resource read.

## E. Performance

Approximate overhead for the headless Debug capture at 5 seconds, including the direct PID probes. Process CPU uses the change in `getrusage(RUSAGE_SELF)` CPU time over about 15 seconds of awake time. Peak RSS is the process-lifetime high-water mark reported by the end of that window. Scan times measure enumeration and per-process reads, excluding the synthetic first-scan delay.

| Metric | Sandbox On | Sandbox Off |
| --- | ---: | ---: |
| Mean CPU, percent of one logical core | 0.007% | 0.712% |
| Peak RSS | 11.05 MiB | 15.03 MiB |
| Median collection time over three follow-up scans | 0.022 ms | 26.357 ms |

Sandbox On only measured failed enumeration and the six direct probes. These are short headless measurements. SwiftUI rendering, idle baselines, other intervals, and sustained energy behavior were outside this measurement.

## F. Risk assessment

- **Reliable in this run.** The ordinary-user Sandbox Off build identified and sampled the controlled user processes. The two-sample algorithm correctly distinguished a true zero, a pending baseline, and unavailable measurements.
- **Partial coverage.** An executable path can survive an identity or resource denial. Sampling can miss short-lived processes and yields interval averages. Coverage and overhead on other macOS versions and under heavier workloads still need measurement.
- **Unavailable in the tested configurations.** The Sandbox On libproc path did not provide system-wide enumeration or external CPU and memory data for the sampled classes. Removing App Sandbox still left the tested system-owned processes inaccessible.

## G. Recommendation

**GO — Unsandboxed Developer ID distribution is more appropriate.** Proceed with a same-user monitoring utility that reports unavailable data explicitly. The next engineering step is to repeat this paired capture using a Developer ID-signed Release build on macOS 14 and a second macOS 26 machine, then profile the SwiftUI monitor over a sustained session. Broader system-owned process coverage remains an open product constraint.
