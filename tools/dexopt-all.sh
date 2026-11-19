#!/usr/bin/env bash
# Compile every installed package ahead of time, the way the Infamick script's
# "Boost Performance" entry does.
#
# What it runs: `cmd package compile -m speed-profile -a`. That is the same pass
# Android performs while charging+idle (bg-dexopt-job), so on a settled device it
# has nothing left to do; it earns its keep right after a flash or a big app update.
#
# Do not use `-m speed` here: measured on this phone, full AOT made warm reloads
# slower (2060/3123/2512/2769 ms -> 2655/2464/4359/5972 ms) and did not keep a
# single extra app resident. See docs/OPTIMIZATION.md.
#
# Usage: tools/dexopt-all.sh [-m speed-profile|verify] [--wait]
#   --wait   wait for the device to finish and keep printing progress every 30 s
set -euo pipefail

ADB=${ADB:-adb}
MODE=speed-profile
WAIT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--mode) MODE=${2:?missing mode}; shift 2 ;;
        --wait) WAIT=1; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) printf 'dexopt-all: unknown argument %s\n' "$1" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    speed-profile|verify|speed) ;;
    *) printf 'dexopt-all: unsupported mode %s\n' "$MODE" >&2; exit 1 ;;
esac
if [ "$MODE" = speed ]; then
    printf 'dexopt-all: -m speed is measured to regress warm reloads on this device; continuing anyway\n' >&2
fi

"$ADB" get-state >/dev/null 2>&1 || { printf 'dexopt-all: no device over adb\n' >&2; exit 1; }

printf 'compiling all packages with -m %s ...\n' "$MODE"
t0=$(date +%s)
if [ "$WAIT" = 1 ]; then
    "$ADB" shell "cmd package compile -m $MODE -a" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 30
        printf '  %ss elapsed, packages still compiling: %s\n' \
            "$(( $(date +%s) - t0 ))" \
            "$("$ADB" shell 'ps -A | grep -c dex2oat' 2>/dev/null | tr -d '\r' || echo '?')"
    done
    wait "$pid" || { printf 'dexopt-all: compile failed\n' >&2; exit 1; }
else
    "$ADB" shell "cmd package compile -m $MODE -a" || { printf 'dexopt-all: compile failed\n' >&2; exit 1; }
fi
printf 'done in %ss\n' "$(( $(date +%s) - t0 ))"
