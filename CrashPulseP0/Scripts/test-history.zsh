#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

root=${0:A:h:h}
if (( $# != 2 || EUID == 0 )); then
    print -u2 "Usage: Scripts/test-history.zsh CRASHPULSEOFF_APP NEW_OUTPUT_DIRECTORY (ordinary user)"
    exit 64
fi
app=${1:A}
output=${2:A}
bin="$app/Contents/MacOS/CrashPulseOff"
history_dir="$output/history"
mkdir -p "${output:h}"
mkdir -m 700 "$output"
/usr/bin/codesign --verify --strict "$app"
xcrun clang -O2 -Wall -Wextra -Werror "$root/Scripts/cpu-load.c" -o "$output/cpu-load"

"$bin" --monitor --duration 83 --history-dir "$history_dir" 2> "$output/monitor.log" &
monitor_pid=$!
load_job=
cleanup() {
    if [[ -n "$monitor_pid" ]]; then
        kill -TERM "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
    fi
    if [[ -n "$load_job" ]]; then
        wait "$load_job" 2>/dev/null || true
    fi
}
trap cleanup EXIT

for attempt in {1..40}; do
    if /usr/bin/grep -q 'Recording CPU history' "$output/monitor.log"; then break; fi
    /bin/sleep 0.1
done
/usr/bin/grep -q 'Recording CPU history' "$output/monitor.log"
if "$bin" --monitor --duration 1 --history-dir "$history_dir" 2> "$output/second-writer.log"; then
    print -u2 "A second monitor wrote to the same history directory."
    exit 1
fi
/usr/bin/grep -q 'already recording' "$output/second-writer.log"

# Build pre-event context before introducing the workload.
/bin/sleep 13
"$output/cpu-load" 44 > "$output/fixture.txt" &
load_job=$!
for attempt in {1..40}; do
    [[ -s "$output/fixture.txt" ]] && break
    /bin/sleep 0.05
done
read -r load_pid helper_pid < "$output/fixture.txt"

# Let the first two or three 5-second scans see load without reaching 30 seconds.
/bin/sleep 12
"$bin" --history --history-dir "$history_dir" > "$output/early.json"
# Poll the live export for an active event while the fixture is still on the CPU.
xcrun python3 - "$bin" "$history_dir" "$load_pid" "$output/active.json" <<'PY'
import json
import subprocess
import sys
import time
from pathlib import Path

binary, history, pid, destination = sys.argv[1:]
deadline = time.monotonic() + 28
while time.monotonic() < deadline:
    data = subprocess.check_output([binary, "--history", "--history-dir", history])
    events = json.loads(data)["events"]
    if any(event["identity"]["pid"] == int(pid) and "endReason" not in event for event in events):
        Path(destination).write_bytes(data)
        break
    time.sleep(0.4)
else:
    sys.exit("The fixture did not produce an active event.")
PY

wait "$load_job"
load_job=
/bin/sleep 21
kill -TERM "$monitor_pid"
wait "$monitor_pid"
monitor_pid=
"$bin" --history --history-dir "$history_dir" > "$output/finished.json"
"$bin" --monitor --duration 2 --interval 1 --history-dir "$history_dir" 2> "$output/restart.log"
"$bin" --history --history-dir "$history_dir" > "$output/reopened.json"

xcrun python3 - "$output" "$load_pid" "$helper_pid" <<'PY'
import json
import sys
from pathlib import Path

folder, pid, idle_pid = sys.argv[1:]
folder = Path(folder)

def fixture_events(name):
    report = json.loads((folder / (name + ".json")).read_bytes())
    assert report["schemaVersion"] == 3
    assert report["policy"]["minimumDurationSeconds"] == 30
    assert all(e["identity"]["pid"] != int(idle_pid) for e in report["events"])
    return [e for e in report["events"] if e["identity"]["pid"] == int(pid)]

assert fixture_events("early") == [], "CPU spike qualified before 30 seconds"
active, = fixture_events("active")
finished, = fixture_events("finished")
reopened, = fixture_events("reopened")
assert finished == reopened and active["id"] == finished["id"]
assert finished["path"] == str(folder / "cpu-load")
assert finished["endReason"] in ("processMissing", "processExited", "belowThreshold"), finished
assert 30 <= finished["observedDurationSeconds"] < 50, finished
assert finished["peakCPUPercent"] > 100, finished
assert finished["lastObservedAt"] >= active["lastObservedAt"]
assert finished["startedAt"] < finished["lastObservedAt"]
evidence = finished["forensics"]
assert evidence["suspectedApp"]["name"] == "cpu-load", evidence["suspectedApp"]
assert evidence["afterComplete"], evidence["after"]
assert all(any("measuredCPUPercent" in point for point in evidence[phase])
           for phase in ("before", "during", "after"))
assert sum("measuredCPUPercent" in point for point in evidence["after"]) >= 2
top = evidence["topProcesses"]
assert 1 < len(top) <= 3
assert top[0]["identity"]["pid"] == int(pid)
assert top[0]["name"] == "cpu-load" and top[0]["path"] == str(folder / "cpu-load")
assert top[0]["cpuEnergyWattHours"] > 0
assert 0 < top[0]["cpuShare"] <= 1
assert top[0]["cpuCoreSeconds"] > top[1]["cpuCoreSeconds"]
assert all(top[i]["cpuCoreSeconds"] >= top[i + 1]["cpuCoreSeconds"] for i in range(len(top) - 1))
print("Passed: early spike ignored, one active event, same event after exit and recorder restart.")
print(f"Fixture PID {pid}, observed {finished['observedDurationSeconds']:.2f} s, "
      f"peak {finished['peakCPUPercent']:.2f}%, ended as {finished['endReason']}.")
print(f"Likely contributor {evidence['suspectedApp']['name']} used {top[0]['cpuEnergyWattHours']:.4f} Wh "
      f"and accounted for {100 * top[0]['cpuShare']:.1f}% of measured event CPU; "
      f"context points before/during/after: {[len(evidence[p]) for p in ('before', 'during', 'after')]}.")
PY
