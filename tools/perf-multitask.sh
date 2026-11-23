#!/usr/bin/env bash
# Multitask probe: can doha keep a working set resident, and how long does each
# app take to come back after being cycled out?
#
#   tools/perf-multitask.sh [--repeat N]
#
# Each cycle force-stops every app and measures a cold launch (am start -W
# TotalTime), then re-launches them in the same order: TotalTime 0 means it was
# still resident, anything else is a reload (the lag people actually notice).
# A sample is accepted only when am reports Status: ok, TotalTime is numeric,
# and the requested package is the first topResumedActivity. Failed launches are
# invalid, never zero-millisecond residents. Medians average the two middle
# values for an even sample count and p90 is nearest-rank; invalid samples are
# excluded from both. Read-only apart from force-stopping the listed apps; no
# settings are changed.
set -uo pipefail

PKGS=${PKGS:-"com.android.settings com.android.chrome com.whatsapp org.telegram.messenger com.google.android.gm com.google.android.apps.photos com.truecaller com.google.android.googlequicksearchbox"}
REPEAT=3

usage() {
  cat >&2 <<'EOF'
usage: tools/perf-multitask.sh [--repeat N]

  --repeat N   cold/warm cycles for every app (default 3, N must be > 0)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repeat)
      [ "$#" -ge 2 ] || { echo "--repeat needs a value" >&2; usage; exit 2; }
      REPEAT=$2
      shift 2
      ;;
    --repeat=*)
      REPEAT=${1#*=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$REPEAT" in
  ''|*[!0-9]*) echo "--repeat must be a positive integer" >&2; exit 2 ;;
esac
[ "$REPEAT" -gt 0 ] || { echo "--repeat must be greater than zero" >&2; exit 2; }

command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
ensure_device() { [ "$(adb devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')" -ge 1 ]; }
lost() { echo "$1 — device lost; re-run when it is back" >&2; exit 3; }
ensure_device || { echo "no device attached" >&2; exit 1; }

comp_of() {
  adb shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $1" 2>/dev/null \
    | tr -d '\r' | tail -1
}
valid_comp() { # requested-package component
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}
top_resumed() {
  adb shell "dumpsys activity activities" 2>/dev/null | tr -d '\r' \
    | awk '/topResumedActivity/{print; exit}'
}
mem_summary() {
  adb shell "cat /proc/meminfo" 2>/dev/null | tr -d '\r' | awk '
    /^MemAvailable:/{m=$2} /^SwapFree:/{s=$2} /^SwapTotal:/{t=$2}
    END{
      if (m == "" && s == "") { print "unavailable"; exit }
      printf "MemAvailable %d MB, SwapFree %d/%d MB", m/1024, s/1024, t/1024
    }'
}
kill_count() {
  adb logcat -b all -d -s am_kill 2>/dev/null | awk '/am_kill/{n++} END{print n+0}'
}

LOAD_TOTAL=
launch() { # pkg component -> 0 accepted, 1 invalid
  local p=$1 c=$2 out status total top
  ensure_device || lost "launch"
  out=$(adb shell "am start -W -n $c" 2>/dev/null | tr -d '\r')
  ensure_device || lost "launch"
  status=$(printf '%s\n' "$out" | awk '/^Status:/{print $2; exit}')
  total=$(printf '%s\n' "$out" | awk '/^TotalTime:/{print $2; exit}')
  top=$(top_resumed) || true
  [ "$status" = "ok" ] || return 1
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  case "$top" in *"$p/"*) ;; *) return 1 ;; esac
  LOAD_TOTAL=$total
  return 0
}

dist_stats() { # space-separated samples -> "median p90" (nearest rank)
  printf '%s\n' $1 | awk 'NF' | sort -n | awk '
    {a[NR]=$1}
    END{
      if (NR == 0) { print "- -"; exit }
      if (NR % 2) med=a[(NR+1)/2]
      else med=(a[NR/2]+a[NR/2+1])/2
      r=int((9*NR+9)/10)
      if (r < 1) r=1
      if (r > NR) r=NR
      printf "%.1f %d\n", med, a[r]
    }'
}

declare -A COLD WARM RES REL INVALID
kill_before=$(kill_count)
mem_before=$(mem_summary)

for ((cycle=1; cycle<=REPEAT; cycle++)); do
  printf '\ncycle %d/%d — cold start after force-stop\n' "$cycle" "$REPEAT"
  for p in $PKGS; do
    ensure_device || lost "cold pass cycle $cycle (last: $p)"
    c=$(comp_of "$p")
    if [ -z "$c" ] || ! valid_comp "$p" "$c"; then
      INVALID[$p]=$(( ${INVALID[$p]:-0} + 1 ))
      printf '%-42s %10s %s\n' "$p" "-" "invalid component: ${c:-none}"
      continue
    fi
    adb shell "am force-stop $p" >/dev/null 2>&1
    ensure_device || lost "cold pass cycle $cycle (last: $p)"
    if launch "$p" "$c"; then
      COLD[$p]="${COLD[$p]:-} $LOAD_TOTAL"
      printf '%-42s %10s %s\n' "$p" "$LOAD_TOTAL" "cold"
    else
      INVALID[$p]=$(( ${INVALID[$p]:-0} + 1 ))
      printf '%-42s %10s %s\n' "$p" "-" "invalid launch"
    fi
  done

  printf '\ncycle %d/%d — relaunch in the same order (0 = still resident)\n' "$cycle" "$REPEAT"
  for p in $PKGS; do
    ensure_device || lost "warm pass cycle $cycle (last: $p)"
    c=$(comp_of "$p")
    if [ -z "$c" ] || ! valid_comp "$p" "$c"; then
      INVALID[$p]=$(( ${INVALID[$p]:-0} + 1 ))
      printf '%-42s %10s %s\n' "$p" "-" "invalid component: ${c:-none}"
      continue
    fi
    if launch "$p" "$c"; then
      WARM[$p]="${WARM[$p]:-} $LOAD_TOTAL"
      if [ "$LOAD_TOTAL" -eq 0 ]; then
        RES[$p]=$(( ${RES[$p]:-0} + 1 ))
        printf '%-42s %10s %s\n' "$p" "$LOAD_TOTAL" "resident"
      else
        REL[$p]=$(( ${REL[$p]:-0} + 1 ))
        printf '%-42s %10s %s\n' "$p" "$LOAD_TOTAL" "RELOAD"
      fi
    else
      INVALID[$p]=$(( ${INVALID[$p]:-0} + 1 ))
      printf '%-42s %10s %s\n' "$p" "-" "invalid launch"
    fi
  done
done

ensure_device || lost "final summary"
kill_after=$(kill_count)
mem_after=$(mem_summary)

printf '\n%-42s %10s %9s %10s %9s %8s %6s %7s\n' \
  app cold_med cold_p90 warm_med warm_p90 resident reload invalid
TOT_RES=0 TOT_REL=0 TOT_INV=0
for p in $PKGS; do
  read -r cold_med cold_p90 <<< "$(dist_stats "${COLD[$p]:-}")"
  read -r warm_med warm_p90 <<< "$(dist_stats "${WARM[$p]:-}")"
  r=${RES[$p]:-0} rl=${REL[$p]:-0} iv=${INVALID[$p]:-0}
  TOT_RES=$((TOT_RES + r))
  TOT_REL=$((TOT_REL + rl))
  TOT_INV=$((TOT_INV + iv))
  printf '%-42s %10s %9s %10s %9s %8d %6d %7d\n' \
    "$p" "$cold_med" "$cold_p90" "$warm_med" "$warm_p90" "$r" "$rl" "$iv"
done

printf '\nresident %d, reloaded %d, invalid %d across %d warm cycles\n' \
  "$TOT_RES" "$TOT_REL" "$TOT_INV" "$REPEAT"
printf 'memory: before %s; after %s\n' "$mem_before" "$mem_after"
printf 'am_kill: before %d, after %d (%d during run)\n' \
  "$kill_before" "$kill_after" "$((kill_after - kill_before))"
