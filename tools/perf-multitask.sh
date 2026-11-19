#!/usr/bin/env bash
# Multitask probe: can doha keep a working set resident, and how long does each
# app take to come back after being cycled out?
#
#   tools/perf-multitask.sh [count]
#
# Pass 1 force-stops each app and measures a cold launch (TotalTime), then pass 2
# re-launches them in the same order: TotalTime 0 means it was still resident,
# anything else is a reload (the lag people actually notice). Read-only apart
# from force-stopping the listed apps; no settings are changed.
set -uo pipefail

PKGS=${PKGS:-"com.android.settings com.android.chrome com.whatsapp org.telegram.messenger com.google.android.gm com.google.android.apps.photos com.truecaller com.google.android.googlequicksearchbox"}

ADB="adb"
command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
[ "$(adb devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')" -ge 1 ] || {
  echo "no device attached" >&2; exit 1; }

comp_of() {
  adb shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $1" 2>/dev/null \
    | tr -d '\r' | tail -1
}
field() { # TotalTime from am start -W
  adb shell "am start -W -n $1" 2>/dev/null | tr -d '\r' | awk '/TotalTime:/{print $2}'
}
swap() { adb shell cat /proc/meminfo | tr -d '\r' | awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d/%d MB", (t-f)/1024, t/1024}'; }

printf '%s\n' "pass 1 — cold start after force-stop (ms)"
printf '%-42s %10s %s\n' app cold swap
for p in $PKGS; do
  c=$(comp_of "$p"); [ -n "$c" ] || { printf '%-42s %10s %s\n' "$p" "-" "not installed"; continue; }
  adb shell "am force-stop $p" >/dev/null 2>&1
  t=$(field "$c")
  printf '%-42s %10s %s\n' "$p" "${t:--}" "$(swap)"
done

printf '\n%s\n' "pass 2 — relaunch in the same order (0 = still resident)"
printf '%-42s %10s %s\n' app warm result
reload=0 resident=0
for p in $PKGS; do
  c=$(comp_of "$p"); [ -n "$c" ] || continue
  t=$(field "$c")
  if [ "${t:-x}" = "0" ]; then
    res="resident"; resident=$((resident+1))
  else
    res="RELOAD"; reload=$((reload+1))
  fi
  printf '%-42s %10s %s\n' "$p" "${t:--}" "$res"
done
printf '\nresident %d, reloaded %d of %d apps; swap %s\n' \
  "$resident" "$reload" "$((resident+reload))" "$(swap)"
