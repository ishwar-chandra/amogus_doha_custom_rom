#!/usr/bin/env bash
# Read-only audit of the runtime tuning doha actually ends up with.
#
# The build writes the same knobs from three places (init.amogus.rc,
# qcom-post-boot's init.qcom.post_boot.sh, and device/qcom/common's
# init.aospa.perf.common.rc), so the intended value and the effective value can
# differ. This prints PASS / WARN / FAIL / SKIP per knob against what build.sh
# and the patches ask for, then a summary. Exit status is the number of FAILs
# (capped at 99), so it can gate a release.
#
#   tools/perf-audit.sh                     # audit the attached phone
#   READAHEAD_KB=512 tools/perf-audit.sh    # audit a build made with that knob
#   SKIN_THROTTLE_C=45 tools/perf-audit.sh  # same for the thermal threshold
#
# Expected values, all from the pinned trees:
#   governor        schedutil        post_boot.legacy.sh trinket block (soc_id 394/467/468)
#   read_ahead_kb   $READAHEAD_KB     patches/device/qcom/common.patch (single owner)
#   nr_requests     128              init.amogus.rc, kernel default
#   SwapTotal       ~4096 MB         patches/device/motorola/amogus.patch (fstab zramsize)
#                                    override with ZRAM_MB=<n> when the kit value changes
#   swappiness      100              post_boot.legacy.sh configure_memory_parameters
#   page-cluster    0                init.aospa.perf.common.rc on post-fs-data
set -uo pipefail

READAHEAD_KB=${READAHEAD_KB:-128}
ZRAM_MB=${ZRAM_MB:-4096}
SKIN_THROTTLE_C=${SKIN_THROTTLE_C:-40}
# Internal: run against a fake sysfs tree instead of a phone (used to test this
# script without hardware). Paths are read as $PERF_AUDIT_ROOT/<path>.
FAKE_ROOT=${PERF_AUDIT_ROOT:-}

PASS=0 WARN=0 FAIL=0 SKIP=0
fails=()

if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; N=$'\033[0m'
else
  G= Y= R= D= B= N=
fi

pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$N" "$*"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s %s\n' "$Y" "$N" "$*"; }
fail() { FAIL=$((FAIL+1)); fails+=("$*"); printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$D" "$N" "$*"; }
info() { printf '  %sinfo%s %s\n' "$D" "$N" "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Value of a sysfs/proc file, with \r stripped. Empty means "not present".
val() {
  if [ -n "$FAKE_ROOT" ]; then
    cat "$FAKE_ROOT$1" 2>/dev/null | tr -d '\r'
  else
    adb shell cat "$1" 2>/dev/null | tr -d '\r'
  fi
}

# exist PATH -> 0 if the node can be read
exist() { [ -n "$(val "$1")" ]; }

# blocked PATH -> 0 if the node exists but this shell cannot read it (root-only)
blocked() {
  [ -z "$FAKE_ROOT" ] || return 1
  case "$(adb shell "[ -e $1 ] && echo e; [ -r $1 ] || echo d" 2>/dev/null | tr -d '\r')" in
    *d*) return 0 ;;
  esac
  return 1
}

# expect PATH WANT LABEL [tolerance-style: exact]
expect() {
  local path=$1 want=$2 label=$3 got
  got=$(val "$path")
  if [ -z "$got" ]; then
    if blocked "$path"; then
      skip "$label (needs root: $path exists, shell cannot read it)"
    else
      skip "$label (node $path not present)"
    fi
  elif [ "$got" = "$want" ]; then
    pass "$label = $got"
  else
    fail "$label = $got, want $want"
  fi
}

if [ -z "$FAKE_ROOT" ]; then
  command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
  STATE=$(adb devices | awk 'NR>1 && $2!=""{print $2; exit}')
  [ "$STATE" = device ] || {
    echo "no device in 'device' state (adb sees: ${STATE:-nothing})" >&2
    exit 1
  }
  SERIAL=$(adb get-serialno)
  printf '%sdoha performance audit%s  serial %s\n' "$B" "$N" "$SERIAL"
else
  printf '%sdoha performance audit%s  fake root %s\n' "$B" "$N" "$FAKE_ROOT"
fi
printf '%s%s%s\n' "$D" "$(printf '─%.0s' $(seq 1 64))" "$N"

# --------------------------------------------------------------------- cpu
head2 "cpu"
# 4.14 exposes per-cpu cpufreq nodes, 5.x+ uses policyN. Check both.
POL0=/sys/devices/system/cpu/cpufreq/policy0
POL4=/sys/devices/system/cpu/cpufreq/policy4
exist "$POL0/scaling_governor" || POL0=/sys/devices/system/cpu/cpu0/cpufreq
exist "$POL4/scaling_governor" || POL4=/sys/devices/system/cpu/cpu4/cpufreq
expect "$POL0/scaling_governor" schedutil "little cluster governor"
expect "$POL4/scaling_governor" schedutil "big cluster governor"
for p in "$POL0" "$POL4"; do
  g=$(val "$p/scaling_governor")
  [ -n "$g" ] || continue
  info "$(basename "$(dirname "$p")") governor=$g min=$(val "$p/scaling_min_freq") max=$(val "$p/scaling_max_freq")" \
       "hispeed=$(val "$p/schedutil/hispeed_freq") hispeed_load=$(val "$p/schedutil/hispeed_load")"
done
if [ -n "$(val /sys/module/sched_walt)" ]; then
  warn "sched_walt module present; WALT is not compiled in this kernel"
else
  skip "walt/core_ctl tuning paths absent (CONFIG_SCHED_WALT/CORE_CTL are off)"
fi

# ---------------------------------------------------------------------- io
head2 "io"
expect /sys/block/mmcblk0/queue/nr_requests 128 "mmcblk0 nr_requests"
expect /sys/block/mmcblk0/queue/read_ahead_kb "$READAHEAD_KB" "mmcblk0 read_ahead_kb"
if [ -n "$(val /sys/block/mmcblk0/queue/scheduler)" ]; then
  info "mmcblk0 scheduler=$(val /sys/block/mmcblk0/queue/scheduler)" \
       "rotational=$(val /sys/block/mmcblk0/queue/rotational)" \
       "iostats=$(val /sys/block/mmcblk0/queue/iostats)"
fi
if [ -n "$FAKE_ROOT" ]; then
  DM_LIST=$(ls -d "$FAKE_ROOT"/sys/block/dm-* 2>/dev/null | sed "s|$FAKE_ROOT||")
else
  DM_LIST=$(adb shell 'ls -d /sys/block/dm-* 2>/dev/null' | tr -d '\r')
fi
DM_OK=0 DM_BAD=()
for d in $DM_LIST; do
  ra=$(val "$d/queue/read_ahead_kb")
  [ -n "$ra" ] || continue
  if [ "$ra" = "$READAHEAD_KB" ]; then DM_OK=$((DM_OK+1)); else DM_BAD+=("$d=$ra"); fi
done
if [ ${#DM_BAD[@]} -eq 0 ]; then
  [ "$DM_OK" -gt 0 ] && pass "all $DM_OK mapped devices read_ahead_kb=$READAHEAD_KB" \
                     || skip "no dm-* queue nodes visible"
else
  fail "dm-* read_ahead_kb mismatch: ${DM_BAD[*]} (want $READAHEAD_KB)"
fi

# ------------------------------------------------------------------ memory
head2 "memory"
MT=$(val /proc/meminfo | awk '/^MemTotal:/{print $2}')
ST=$(val /proc/meminfo | awk '/^SwapTotal:/{print $2}')
[ -n "$MT" ] && info "MemTotal $((MT/1024)) MB" || warn "cannot read MemTotal"
if [ -n "$ST" ]; then
  ST_MB=$((ST/1024))
  # ZRAM_MB is what the fstab asks for; allow 15% slack for kernel rounding.
  if [ "$ST_MB" -ge $((ZRAM_MB * 85 / 100)) ] && [ "$ST_MB" -le $((ZRAM_MB * 115 / 100)) ]; then
    pass "SwapTotal ${ST_MB} MB (${ZRAM_MB} MB zram from fstab)"
  elif [ "$ST_MB" -lt $((ZRAM_MB * 85 / 100)) ]; then
    fail "SwapTotal ${ST_MB} MB — fstab zramsize did not grow (stale fstab?)"
  else
    warn "SwapTotal ${ST_MB} MB above the expected ${ZRAM_MB} MB window"
  fi
  SF=$(val /proc/meminfo | awk '/^SwapFree:/{print $2}')
  [ -n "$SF" ] && info "SwapFree $((SF/1024)) MB of ${ST_MB} MB"
else
  fail "no swap — zram is not enabled"
fi
val /proc/swaps | sed -n '2,5p' | while read -r line; do [ -n "$line" ] && info "swap: $line"; done
expect /proc/sys/vm/swappiness 100 "vm.swappiness"
expect /proc/sys/vm/page-cluster 0 "vm.page-cluster"
expect /proc/sys/vm/watermark_scale_factor 1 "vm.watermark_scale_factor"
DS=$(val /sys/block/zram0/disksize)
[ -n "$DS" ] && info "zram0 disksize $((DS/1024/1024)) MB"
MM=$(val /sys/block/zram0/mm_stat)
if [ -n "$MM" ]; then
  set -- $MM
  if [ "${1:-0}" -gt 0 ] 2>/dev/null; then
    info "zram0 orig=$(( $1 /1024/1024 )) MB compressed=$(( ${2:-0} /1024/1024 )) MB mem=$(( ${3:-0} /1024/1024 )) MB"
  fi
fi
P=$(val /proc/pressure/memory | awk '/^some/{print $2}' | sed 's/avg10=//')
[ -n "${P:-}" ] && info "/proc/pressure/memory some avg10=${P}%" ||
  skip "/proc/pressure/memory not readable (CONFIG_PSI is on, needs a live shell)"
for p in ro.lmk.psi_partial_stall_ms ro.lmk.swap_free_low_percentage ro.lmk.thrashing_limit \
         ro.lmk.thrashing_limit_decay ro.lmk.psi_complete_stall_ms; do
  v=$(val "/dev/__props__" 2>/dev/null) # placeholder to keep val() shape uniform
  [ -n "$FAKE_ROOT" ] || v=$(adb shell getprop "$p" 2>/dev/null | tr -d '\r')
  [ -n "$v" ] && info "$p=$v"
done

# ----------------------------------------------------------------- thermal
head2 "thermal"
# SKIN_THROTTLE_C is the skin threshold; lmh/cpu/gpu zones are separate limiters
# and must not be compared to it.
SKINT=0 SKINZ= MAXT=0 MAXZ=
if [ -n "$FAKE_ROOT" ]; then
  ZONES=$(ls -d "$FAKE_ROOT"/sys/class/thermal/thermal_zone* 2>/dev/null | sed "s|$FAKE_ROOT||")
else
  ZONES=$(adb shell 'ls -d /sys/class/thermal/thermal_zone* 2>/dev/null' | tr -d '\r')
fi
for z in $ZONES; do
  t=$(val "$z/temp"); ty=$(val "$z/type")
  [ -n "$t" ] || continue
  case "$ty" in
    *skin*|*quiet_therm*|*xo_therm*)
      if [ "$t" -gt "$SKINT" ] 2>/dev/null; then SKINT=$t; SKINZ=$ty; fi ;;
  esac
  if [ "$t" -gt "$MAXT" ] 2>/dev/null; then MAXT=$t; MAXZ=$ty; fi
done
if [ "$SKINT" -gt 0 ]; then
  MC=$((SKINT/1000))
  if [ "$MC" -ge "$SKIN_THROTTLE_C" ]; then
    warn "skin zone ${SKINZ} ${MC}C >= SKIN_THROTTLE ${SKIN_THROTTLE_C}C (throttling expected)"
  else
    pass "skin zone ${SKINZ} ${MC}C < SKIN_THROTTLE ${SKIN_THROTTLE_C}C"
  fi
else
  skip "no skin*/quiet_therm* zone readable — skin headroom unknown"
fi
[ "$MAXT" -gt 0 ] && info "hottest zone ${MAXZ} $((MAXT/1000))C (bus/cpu limiter, not the skin threshold)"
if [ -z "$FAKE_ROOT" ]; then
  for svc in thermal-engine android.hardware.thermal@2.0-service.qti \
             android.hardware.thermal-service.qti; do
    pid=$(adb shell pidof "$svc" 2>/dev/null | tr -d '\r')
    [ -n "$pid" ] && info "$svc running (pid $pid)"
  done
fi

# ----------------------------------------------------------------- wakeups
head2 "wakeups"
WS=$(val /sys/kernel/debug/wakeup_sources)
if [ -n "$WS" ]; then
  printf '%s\n' "$WS" | awk 'NR==1 || $2+0>0' | head -8 | while read -r line; do info "$line"; done
else
  skip "wakeup_sources needs root (ro.debuggable=0); use a bugreport instead"
fi

# ----------------------------------------------------------------- summary
printf '\n%ssummary%s  PASS %d  WARN %d  FAIL %d  SKIP %d\n' "$B" "$N" "$PASS" "$WARN" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '%sthe phone is not running the tuning this build asks for:%s\n' "$R" "$N"
  for f in "${fails[@]}"; do printf '  - %s\n' "$f"; done
fi
[ "$FAIL" -gt 99 ] && FAIL=99
exit "$FAIL"
