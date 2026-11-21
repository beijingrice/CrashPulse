#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

root=${0:A:h:h}
if (( $# != 2 || EUID == 0 )); then
    print -u2 "Usage: Scripts/test-app-trigger.zsh CRASHPULSEOFF_APP NEW_OUTPUT_DIRECTORY (ordinary user)"
    exit 64
fi
app=${1:A}
output=${2:A}
bin="$app/Contents/MacOS/CrashPulseOff"
history_dir="$output/history"
bundle="$output/Helper Fixture.app"
mkdir -p "${output:h}"
mkdir -m 700 "$output"
/usr/bin/codesign --verify --strict "$app"

xcrun clang -O2 -Wall -Wextra -Werror "$root/Scripts/cpu-load.c" -o "$output/cpu-load"
for number in {1..4}; do
    executable="$bundle/Contents/Frameworks/Worker$number.app/Contents/MacOS"
    mkdir -p "$executable"
    cp "$output/cpu-load" "$executable/worker-$number"
done

"$bin" --monitor --duration 77 --history-dir "$history_dir" 2> "$output/monitor.log" &
monitor_pid=$!
typeset -a helpers
helpers=()
cleanup() {
    if [[ -n "$monitor_pid" ]]; then
        kill -TERM "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
    fi
    for helper in "${helpers[@]}"; do wait "$helper" 2>/dev/null || true; done
}
trap cleanup EXIT

for attempt in {1..40}; do
    if /usr/bin/grep -q 'Recording CPU history' "$output/monitor.log"; then break; fi
    /bin/sleep 0.1
done
/usr/bin/grep -q 'Recording CPU history' "$output/monitor.log"
/bin/sleep 9

for number in {1..4}; do
    "$bundle/Contents/Frameworks/Worker$number.app/Contents/MacOS/worker-$number" 45 40 > "$output/worker-$number.txt" &
    helpers+=($!)
done
/bin/sleep 7
"$bin" --capture 5 2 > "$output/during.json"

for helper in "${helpers[@]}"; do wait "$helper"; done
helpers=()
/bin/sleep 19
kill -TERM "$monitor_pid"
wait "$monitor_pid"
monitor_pid=
"$bin" --history --history-dir "$history_dir" > "$output/reopened.json"

xcrun python3 - "$output" "$bundle" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
bundle = sys.argv[2]
pids = {int((directory / f"worker-{number}.txt").read_text()) for number in range(1, 5)}
assert len(pids) == 4
scan = json.loads((directory / "during.json").read_text())["snapshots"][-1]
readings = [row["cpuPercent"] for row in scan["rows"] if row["pid"] in pids]
assert len(readings) == 4 and all(20 <= cpu < 45 for cpu in readings), readings
report = json.loads((directory / "reopened.json").read_text())
matches = [event for event in report["events"]
           if event.get("triggerApp", {}).get("id") == bundle or event["identity"]["pid"] in pids]
event, = matches
assert event["triggerApp"]["name"] == "Helper Fixture"
assert event["observedDurationSeconds"] >= 30 and event["peakCPUPercent"] > 120
assert event["endReason"] == "processMissing"
evidence = event["forensics"]
assert evidence["suspectedApp"]["id"] == bundle
assert evidence["afterComplete"]
ranked = [item for item in evidence["topProcesses"] if item["identity"]["pid"] in pids]
assert len(ranked) >= 2 and all(item["app"]["id"] == bundle for item in ranked)
assert any(point["triggerCPUPercent"] > 120 for point in evidence["during"])
print(f"Four individually sub-threshold helpers: {[round(cpu, 1) for cpu in sorted(readings)]}")
print(f"One app event at {event['peakCPUPercent']:.1f}% peak for {event['observedDurationSeconds']:.1f} s, "
      f"with {len(ranked)} helper contributions and preserved follow-up.")
PY
