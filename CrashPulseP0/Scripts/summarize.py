"""Summarize the paired local capture without printing unrelated process details."""
import json
import plistlib
import statistics
import sys
from collections import Counter
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def describe(row):
    if row is None:
        return "not enumerated"
    cpu = row.get("cpuPercent")
    issues = ", ".join(
        f"{issue['stage']}/{issue['category']}"
        + (f"({issue['errorNumber']})" if "errorNumber" in issue else "")
        for issue in row["issues"]
    )
    readings = ", ".join(
        label for key, label in [
            ("identity", "identity"), ("footprintBytes", "memory"), ("path", "path")
        ] if key in row
    )
    cpu_text = f", {cpu:.1f}% CPU" if cpu is not None else ""
    return f"{row['state']}{cpu_text}; fields: {readings or 'none'}; issues: {issues or 'none'}"


def verify_signatures(directory):
    expected_on = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-write": True,
    }
    for variant in ("On", "Off"):
        content = (directory / f"{variant}.entitlements.plist").read_bytes()
        signed = plistlib.loads(content) if content else {}
        require(signed == (expected_on if variant == "On" else {}),
                f"Sandbox {variant}: unexpected signed entitlements. Run a fresh build action.")


def summarize(directory, variant, uid, targets, exit_pid):
    expected = variant == "On"
    report = json.loads((directory / f"{variant}.json").read_text())
    run = report["run"]
    require(run["sandboxEntitlement"] is expected and run["effectiveUID"] == uid,
            f"Sandbox {variant}: unexpected live entitlement or user")
    require(run["bundleIdentifier"] == f"org.crashpulse.p0.{variant.lower()}",
            f"Sandbox {variant}: unexpected bundle ID")
    scans = report["snapshots"]
    require(len(scans) == 4, f"Sandbox {variant}: missing scan")
    indexed = [{row["pid"]: row for row in scan["rows"]} for scan in scans]
    first = indexed[0]
    measured = indexed[1:]
    if "enumerationIssue" not in scans[0]:
        require(report["exitProbePID"] == exit_pid and report["exitProbeWasEnumerated"]
                and first.get(exit_pid, {}).get("state") == "exited"
                and all(exit_pid not in scan for scan in measured),
                f"Sandbox {variant}: the controlled PID did not exit between enumeration and read")
    if not expected:
        require(all("enumerationIssue" not in scan for scan in scans),
                "Sandbox Off: process enumeration failed")
    probes = [{row["pid"]: row for row in scan["rows"]} for scan in report["knownPIDSnapshots"]]
    own_pid = run["pid"]
    require(len(probes) == 4 and all(own_pid in scan for scan in probes),
            f"Sandbox {variant}: missing direct self probe")
    if not expected:
        require(all(scan[own_pid]["state"] == "sampled" for scan in probes[1:]),
                "Sandbox Off: failed to sample itself")
    for rows in indexed + probes:
        for row in rows.values():
            if row["state"] in ("inaccessible", "exited"):
                require("cpuPercent" not in row and "footprintBytes" not in row,
                        f"Sandbox {variant}: an unavailable process published a value")

    print(f"Sandbox {variant} | effective UID {uid} | verified signed and live entitlement {expected}")
    print(run["osVersion"], "Mach ratio", report["timebase"], "first scan", scans[0]["sampledAt"])
    counts = [scan["coverage"] for scan in scans[1:]]
    opportunities = sum(count["enumerated"] for count in counts)
    print("Enumerated by steady scan:", [count["enumerated"] for count in counts])
    for metric in ("identity", "resource", "cpu", "memory", "name", "path", "baseline", "failed"):
        total = sum(count[metric] for count in counts)
        rate = f"{100 * total / opportunities:.2f}%" if opportunities else "n/a"
        print(f"{metric:>10} {total}/{opportunities} ({rate})")
    issues = Counter()
    stages = Counter()
    for count, scan, rows in zip(counts, scans[1:], measured):
        issues.update(count["issueCounts"])
        enumeration = scan.get("enumerationIssue")
        if enumeration:
            stages.update([(enumeration["stage"], enumeration["category"], enumeration.get("errorNumber"))])
        for row in rows.values():
            stages.update((i["stage"], i["category"], i.get("errorNumber")) for i in row["issues"])
    print("Issues by row or enumeration attempt:", dict(issues))
    print("Issues by stage:", dict(stages))
    for label, pid in [("Self", own_pid), *targets]:
        print(f"{label} ({pid}), direct: " + " | ".join(describe(scan.get(pid)) for scan in probes[1:]))
    print(f"Exit probe ({exit_pid}), enumerated {report.get('exitProbeWasEnumerated')}:",
          describe(first.get(exit_pid)))
    print("Headless process overhead:", report.get("capturePerformance"))
    print("Steady scan milliseconds, median:",
          round(statistics.median(scan["scanMilliseconds"] for scan in scans[1:]), 3))
    print()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-signatures":
        verify_signatures(Path(sys.argv[2]))
        raise SystemExit(0)
    folder, uid, gui, protected, load, helper, transient = sys.argv[1:]
    verify_signatures(Path(folder))
    targets = [("User GUI app", int(gui)), ("System launchd", 1)]
    if protected:
        targets.append(("WindowServer", int(protected)))
    targets.extend([("CPU load", int(load)), ("CPU load's idle child", int(helper))])
    for variant in ("On", "Off"):
        summarize(Path(folder), variant, int(uid), targets, int(transient))
