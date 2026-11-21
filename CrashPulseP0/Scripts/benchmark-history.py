"""Measure a signed Release recorder against an isolated near-full journal."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

DURATION = 220
WARMUP = 20
LOAD_DURATION = 60
SEEDED_RECORDS = 500
FOUNDATION_EPOCH = 978_307_200


def cpu_seconds(value):
    result = 0.0
    for field in value.split(":"):
        result = result * 60 + float(field)
    return result


def run(app, seed, output):
    if os.geteuid() == 0:
        raise SystemExit("Run the benchmark as an ordinary user.")
    output.mkdir(mode=0o700, parents=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
    executable = app / "Contents/MacOS/CrashPulseOff"
    load = output / "cpu-load"
    source = Path(__file__).with_name("cpu-load.c")
    subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
                    str(source), "-o", str(load)], check=True)
    history = output / "history"
    history.mkdir(mode=0o700)
    journal = history / "cpu-history.json"
    seed_event = next(event for event in json.loads(seed.read_text())["events"] if event.get("forensics"))
    now = time.time() - FOUNDATION_EPOCH
    records = []
    for number in range(SEEDED_RECORDS):
        event = copy.deepcopy(seed_event)
        event["id"] = str(uuid.uuid4()).upper()
        event["startedAt"] = now - 600 - number
        event["lastObservedAt"] = event["startedAt"] + 40
        event["endReason"] = "processMissing"
        records.append(event)
    original = json.dumps({"schemaVersion": 3, "events": [*records, {"unreadable": True}]}).encode()
    journal.write_bytes(original)
    prior = journal.stat()

    rss_sample = []
    writes = []
    workload = None
    workload_output = None
    with (output / "monitor.log").open("w") as log:
        start = time.monotonic()
        monitor = subprocess.Popen([str(executable), "--monitor", "--duration", str(DURATION),
                                    "--history-dir", str(history)], stderr=log)
        try:
            next_rss = 0
            while monitor.poll() is None:
                elapsed = time.monotonic() - start
                if workload is None and elapsed >= WARMUP:
                    workload_output = (output / "fixture.txt").open("w")
                    workload = subprocess.Popen([str(load), str(LOAD_DURATION)], stdout=workload_output)
                try:
                    current = journal.stat()
                    if (current.st_ino, current.st_mtime_ns) != (prior.st_ino, prior.st_mtime_ns):
                        writes.append({"atSeconds": round(elapsed, 2), "bytes": current.st_size})
                        prior = current
                except FileNotFoundError:
                    pass  # Recovery moves the original aside before the first commit.
                if elapsed >= next_rss:
                    result = subprocess.run(["/bin/ps", "-p", str(monitor.pid), "-o", "rss=,time="],
                                            capture_output=True, text=True)
                    if result.returncode == 0:
                        rss, cpu = result.stdout.split()
                        rss_sample.append({"atSeconds": round(elapsed, 2), "rssKiB": int(rss),
                                           "cpuSeconds": cpu_seconds(cpu)})
                    next_rss = elapsed + 1
                time.sleep(0.15)
        finally:
            if monitor.poll() is None:
                monitor.terminate()
                monitor.wait()
            if workload is not None:
                workload.wait()
            if workload_output is not None:
                workload_output.close()
    if monitor.returncode != 0 or workload is None or workload.returncode != 0:
        raise RuntimeError("Monitor or fixture did not complete")

    current = journal.stat()
    if (current.st_ino, current.st_mtime_ns) != (prior.st_ino, prior.st_mtime_ns):
        writes.append({"atSeconds": round(time.monotonic() - start, 2), "bytes": current.st_size})
    damaged, = history.glob("cpu-history.damaged-*.json")
    assert damaged.read_bytes() == original
    report = json.loads(subprocess.check_output([str(executable), "--history", "--history-dir", str(history)]))
    (output / "reopened.json").write_text(json.dumps(report, indent=2))
    preserved = {event["id"] for event in report["events"]}
    seeded_ids = {event["id"] for event in records}
    assert seeded_ids <= preserved
    pid = int((output / "fixture.txt").read_text().split()[0])
    loaded = [event for event in report["events"] if event["identity"]["pid"] == pid
              and event["id"] not in seeded_ids]
    event, = loaded
    assert event["endReason"] and event["forensics"]["suspectedApp"]["name"] == "cpu-load"
    assert event["forensics"]["afterComplete"]
    steady = sorted(sample["rssKiB"] / 1024 for sample in rss_sample if sample["atSeconds"] >= 180)
    assert steady
    metrics = {
        "durationSeconds": DURATION,
        "intervalSeconds": 5,
        "seededRecords": len(records),
        "steadyRSSMedianMiB": round(steady[len(steady) // 2], 2),
        "steadyRSSPeakMiB": round(max(steady), 2),
        "cpuSeconds": rss_sample[-1]["cpuSeconds"],
        "atomicReplacementsObserved": len(writes),
        "logicalJournalBytesObserved": sum(item["bytes"] for item in writes),
        "newEventID": event["id"],
        "newEventPID": pid,
        "samples": rss_sample,
        "writes": writes,
    }
    (output / "metrics.json").write_text(json.dumps(metrics, indent=2))
    print(json.dumps({k: v for k, v in metrics.items() if k not in ("samples", "writes")}, indent=2), flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: benchmark-history.py CRASHPULSEOFF_APP SEED_JOURNAL NEW_OUTPUT_DIRECTORY")
    run(*(Path(arg).resolve() for arg in sys.argv[1:]))
