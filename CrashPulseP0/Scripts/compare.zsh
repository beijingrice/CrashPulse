#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

root=${0:A:h:h}
if (( $# != 2 )); then
    print -u2 "Usage: Scripts/compare.zsh BUILT_PRODUCTS_DIRECTORY NEW_OUTPUT_DIRECTORY"
    exit 64
fi
products=${1:A}
output=${2:A}
if (( EUID == 0 )); then
    print -u2 "Run as the logged-in Mac user."
    exit 64
fi

mkdir -p "${output:h}"
mkdir -m 700 "$output"
for variant in On Off; do
    app="$products/CrashPulse$variant.app"
    /usr/bin/codesign --verify --strict "$app"
    /usr/bin/codesign -d --xml --entitlements - "$app" > "$output/$variant.entitlements.plist" \
        2> "$output/$variant.signing.txt"
done
xcrun python3 "$root/Scripts/summarize.py" --verify-signatures "$output"

gui_pid=${CRASHPULSE_GUI_PID:-$(/usr/bin/pgrep -u "$EUID" -x Finder | /usr/bin/head -n 1)}
windowserver_pid=$(/usr/bin/pgrep -x WindowServer | /usr/bin/head -n 1 || true)
[[ "$gui_pid" == <-> && "$gui_pid" -gt 0 ]]
target_pids="1,$gui_pid"
probe_pids=(1 "$gui_pid")
if [[ -n "$windowserver_pid" ]]; then
    target_pids="$target_pids,$windowserver_pid"
    probe_pids+=("$windowserver_pid")
fi
/bin/ps -o pid,ppid,uid,comm -p "$target_pids" > "$output/targets.txt"
{
    /usr/bin/sw_vers
    /usr/bin/uname -m
    /usr/sbin/sysctl -n hw.model machdep.cpu.brand_string
} > "$output/host.txt"
xcrun clang -O2 -Wall -Wextra -Werror "$root/Scripts/cpu-load.c" -o "$output/cpu-load"
"$output/cpu-load" 29 > "$output/fixture.txt" &
load_job=$!
trap 'wait "$load_job" 2>/dev/null || true' EXIT
for attempt in {1..40}; do
    [[ -s "$output/fixture.txt" ]] && break
    /bin/sleep 0.05
done
read -r load_pid helper_pid < "$output/fixture.txt"
/bin/sleep 7 &
exit_pid=$!

# Launch the actual signed bundles from the user's LaunchServices session.
# Both enumerate the same transient PID before the first scan pauses.
for variant in On Off; do
    /usr/bin/open -gnjW --stdout "$output/$variant.json" --stderr "$output/$variant.stderr" \
        "$products/CrashPulse$variant.app" --args --capture 5 4 "$exit_pid" 9 \
        "${probe_pids[@]}" "$load_pid" "$helper_pid" &
    if [[ "$variant" == On ]]; then
        on_job=$!
    else
        off_job=$!
    fi
done
wait "$on_job"
wait "$off_job"
wait "$exit_pid"
wait "$load_job"
xcrun python3 "$root/Scripts/summarize.py" "$output" "$EUID" "$gui_pid" "$windowserver_pid" \
    "$load_pid" "$helper_pid" "$exit_pid" | /usr/bin/tee "$output/summary.txt"
