#!/usr/bin/env bash
# Capture what an app actually does when it fails: its own log lines, the
# system's complaints about it, a screenshot, and the activity stack.
#
#   ./tools/app-trace.sh com.anthropic.claude            # launch and watch 25 s
#   ./tools/app-trace.sh com.anthropic.claude 60         # watch longer
#   ./tools/app-trace.sh com.anthropic.claude 30 --no-launch   # it is already open
#
# Writes ./app-trace/<pkg>-<timestamp>/ with logcat.txt, system.txt,
# screenshot.png, window.txt, props.txt and a summary.txt. Everything is plain
# text so it can be read (or handed to bugreport-scan.py) afterwards.
set -euo pipefail

pkg=${1:?usage: app-trace.sh <package> [seconds] [--no-launch]}
secs=${2:-25}
launch=1
[ "${3:-}" = "--no-launch" ] && launch=0

command -v adb >/dev/null || { echo "adb not in PATH" >&2; exit 1; }
[ "$(adb get-state 2>/dev/null)" = device ] || { echo "no device: connect it and allow USB debugging" >&2; exit 1; }

out=app-trace/$pkg-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"

adb shell pm path "$pkg" >/dev/null 2>&1 || { echo "$pkg is not installed" >&2; exit 1; }

# A fresh buffer, so the trace only holds this run.
adb logcat -c 2>/dev/null || true
if [ "$launch" = 1 ]; then
    adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 ||
        adb shell am start "$(adb shell cmd package resolve-activity --brief "$pkg" | tail -1)" >/dev/null
fi

sleep "$secs"

pid=$(adb shell pidof "$pkg" 2>/dev/null | tr -d '\r')
{
    echo "package: $pkg"
    echo "pid: ${pid:-<not running>}"
    echo "captured: $(date -u +%FT%TZ)"
    echo
    echo "activity stack:"; adb shell dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity|mResumedActivity|Hist #0" | head -5
    echo
    echo "process state:"; adb shell dumpsys activity processes 2>/dev/null | grep -A2 -E "ProcessRecord.*$pkg" | head -6
} > "$out/summary.txt"

adb logcat -d > "$out/logcat.txt" 2>/dev/null || true
# Everything the app itself logged, plus every system line that names it.
{
    [ -n "$pid" ] && adb logcat -d --pid="$pid" 2>/dev/null || true
    grep -a "$pkg" "$out/logcat.txt" || true
} | sort -u > "$out/system.txt"

adb exec-out screencap -p > "$out/screenshot.png" 2>/dev/null || rm -f "$out/screenshot.png"
adb shell dumpsys window 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" > "$out/window.txt" || true
adb shell getprop > "$out/props.txt" 2>/dev/null || true

echo "captured ${secs}s of $pkg into $out"
echo "  summary.txt     pid and activity state"
echo "  system.txt      the app's own log plus system lines naming it"
echo "  screenshot.png  what was on screen (if the app rendered)"
echo
echo "next: grep -iE 'fatal|exception|error|anr|integrity|webview|ssl' $out/system.txt | head -40"
