#!/usr/bin/env bash
# Read-only health check for a booted doha phone over adb.
#
# Runs every check the device can answer without root, prints PASS / WARN /
# FAIL / SKIP per line, then a summary. Exit status is the number of FAILs
# (capped at 99), so it can gate a release. The only write is a 4-byte /sdcard
# probe that is deleted immediately.
#
#   tools/device-check.sh [--verbose]
#
# What needs a human (touch panels, calls, camera capture, GNSS fix) is
# reported as SKIP with what to try; README "Status" is the manual checklist.
set -uo pipefail

VERBOSE=0
[ "${1:-}" = --verbose ] && VERBOSE=1

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

sh_() { adb shell "$@" 2>/dev/null | tr -d '\r'; }
prop() { sh_ getprop "$1"; }

command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
STATE=$(adb devices | awk 'NR>1 && $2!=""{print $2; exit}')
[ "$STATE" = device ] || {
  echo "no device in 'device' state (adb sees: ${STATE:-nothing})" >&2
  echo "boot the ROM, or unlock the phone; recovery shows as 'recovery'" >&2
  exit 1
}

MODEL=$(prop ro.product.device) SERIAL=$(adb get-serialno)
printf '%sdoha health check%s  %s (%s)\n' "$B" "$N" "$MODEL" "$SERIAL"
printf '%s%s%s\n' "$D" "$(printf '─%.0s' $(seq 1 64))" "$N"

# ------------------------------------------------------------------- boot
head2 "boot"
[ "$(prop sys.boot_completed)" = 1 ] && pass "boot_completed=1" || fail "boot_completed=$(prop sys.boot_completed)"
[ "$(prop init.svc.bootanim)" = stopped ] && pass "boot animation finished" || warn "bootanim=$(prop init.svc.bootanim)"
UP=$(sh_ cat /proc/uptime | cut -d' ' -f1 | cut -d. -f1)
[ -n "$UP" ] && pass "up ${UP}s ($((UP/60)) min)" || warn "cannot read uptime"
info "sdk=$(prop ro.build.version.sdk) type=$(prop ro.build.type) slot=$(prop ro.boot.slot_suffix)"
info "built $(prop ro.build.date)"

# -------------------------------------------------------------- stability
head2 "stability"
FATALS=$(adb logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION")
if [ "$FATALS" = 0 ]; then
  pass "no FATAL EXCEPTION in the current log buffer"
else
  warn "$FATALS FATAL EXCEPTION entr(ies) in the current log buffer"
  adb logcat -d 2>/dev/null | grep -A1 "FATAL EXCEPTION" | grep -oE "Process: [a-zA-Z0-9._]+" |
    sort | uniq -c | sed 's/^/       /'
fi
ANR=$(adb logcat -d 2>/dev/null | grep -c "ANR in ")
[ "$ANR" = 0 ] && pass "no ANR recorded" || warn "$ANR ANR line(s) in logcat"
TOMB=$(sh_ ls /data/tombstones 2>/dev/null | wc -l)
[ "${TOMB:-0}" -le 2 ] 2>/dev/null && pass "tombstones: ${TOMB:-0} file(s)" || warn "tombstones: $TOMB files"
WDOG=$(adb logcat -d -b all 2>/dev/null | grep -c "WATCHDOG KILLING SYSTEM PROCESS")
[ "$WDOG" = 0 ] && pass "no system_server watchdog kill in the buffer" || warn "watchdog kills: $WDOG"

# --------------------------------------------------------------- security
head2 "security / SELinux"
VBS=$(prop ro.boot.verifiedbootstate)
case $VBS in
  orange) pass "verified boot: orange (unlocked bootloader)" ;;
  green)  warn "verified boot: green — reports locked/verified, unexpected on an unlocked phone" ;;
  *)      warn "verified boot: ${VBS:-unknown}" ;;
esac
ENF=$(sh_ getenforce); [ "$ENF" = Enforcing ] && pass "SELinux enforcing" || fail "SELinux ${ENF:-unknown}"
AVC=$(adb logcat -d -b all 2>/dev/null | grep -c "avc: denied")
[ "$AVC" = 0 ] && pass "no SELinux denials in logcat" || warn "$AVC avc denial line(s)"
[ "$(prop ro.adb.secure)" = 1 ] && pass "adb authentication on (ro.adb.secure=1)" || warn "ro.adb.secure=$(prop ro.adb.secure)"
[ "$(prop persist.sys.usb.config)" = adb ] && info "persist.sys.usb.config=adb (usb debugging or a test build)"

# ----------------------------------------------------------------- radios
head2 "radios"
WIFION=$(sh_ dumpsys wifi | grep -c "Wi-Fi is enabled")
[ "${WIFION:-0}" -ge 1 ] 2>/dev/null && pass "Wi-Fi enabled" || info "Wi-Fi switched off"
SSID=$(sh_ dumpsys wifi | grep -m1 "mWifiInfo" | sed -n 's/.*SSID: \([^,]*\).*/\1/p')
case $SSID in
  ""|"<none>"|"<unknown ssid>")
    [ "${WIFION:-0}" -ge 1 ] 2>/dev/null && warn "Wi-Fi on but not associated" ;;
  *) pass "Wi-Fi associated: $SSID" ;;
esac
BT=$(sh_ dumpsys bluetooth_manager | sed -n 's/^ *State: *//p' | head -1)
case $BT in
  ON)  pass "bluetooth on" ;;
  OFF) pass "bluetooth service up (switched off)" ;;
  *)   warn "bluetooth state '${BT:-unknown}'" ;;
esac
SIM=$(prop gsm.sim.state)
case $SIM in *LOADED*) pass "SIM state: $SIM" ;; *) warn "SIM state: ${SIM:-unknown}" ;; esac
VOICE=$(sh_ dumpsys telephony.registry | grep -m1 "mServiceState" | grep -oE "mVoiceRegState=[0-9]\([A-Z_]+\)")
case $VOICE in
  *IN_SERVICE*) pass "voice registered (${VOICE})" ;;
  "")           warn "voice registration not reported" ;;
  *)            warn "voice ${VOICE}" ;;
esac
DATA_ON=$(sh_ settings get global mobile_data)
DATA=$(sh_ dumpsys telephony.registry | grep -m1 "mServiceState" | grep -oE "mDataRegState=[0-9]\([A-Z_]+\)")
case $DATA in
  *IN_SERVICE*) pass "mobile data registered (${DATA})" ;;
  *) if [ "$DATA_ON" = 1 ]; then
       warn "mobile data enabled but not registered (${DATA}) — APN or coverage"
     else
       info "mobile data switched off in settings (mobile_data=0)"
     fi ;;
esac
if adb shell ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
  pass "internet reachable (ICMP 1.1.1.1)"
else
  skip "no internet path right now (Wi-Fi and mobile data both off)"
fi
NFC=$(sh_ dumpsys nfc | sed -n 's/^mState=//p' | head -1)
case $NFC in
  on|off) pass "NFC service up (${NFC})" ;;
  *)      warn "NFC state '${NFC:-unknown}'" ;;
esac

# ---------------------------------------------------------------- sensors
head2 "sensors / input"
NSENS=$(sh_ dumpsys sensorservice | sed -n 's/^Total \([0-9]*\) h\/w sensors.*/\1/p' | head -1)
[ "${NSENS:-0}" -gt 5 ] 2>/dev/null && pass "$NSENS hardware sensors registered" || warn "sensors reported: ${NSENS:-0}"
NACC=$(sh_ dumpsys sensorservice | grep -ci "Accelerometer")
[ "${NACC:-0}" -ge 1 ] 2>/dev/null && pass "accelerometer present" || warn "no accelerometer in sensor list"
NTOUCH=$(sh_ dumpsys input | grep -c "TOUCHSCREEN")
[ "${NTOUCH:-0}" -ge 1 ] 2>/dev/null && pass "touchscreen device declared" || warn "no touchscreen in input dump"
FP=$(sh_ dumpsys fingerprint | grep -m1 -o '"service":"[^"]*"')
[ -n "$FP" ] && pass "fingerprint HAL: $FP" || warn "fingerprint HAL did not report"
skip "panel behaviour (double-tap-to-wake, edge taps) needs a finger"

# ------------------------------------------------------------------ media
head2 "media / camera / display"
CAM=$(sh_ dumpsys media.camera | sed -n 's/Number of camera devices: //p')
[ "${CAM:-0}" -ge 3 ] 2>/dev/null && pass "$CAM camera devices" || warn "camera devices: ${CAM:-0}"
if adb shell test -x /system/bin/screenrecord; then
  pass "screenrecord binary present"
else
  warn "no /system/bin/screenrecord"
fi
# File presence is not a Widevine security-level assertion; L1 still has to be
# proven in a DRM-info app (see the plan's Verification steps).
if adb shell test -e /vendor/lib64/liboemcrypto.so; then
  pass "OEMCrypto library present (/vendor/lib64/liboemcrypto.so)"
else
  fail "OEMCrypto library missing (/vendor/lib64/liboemcrypto.so)"
fi
NAUD=$(sh_ dumpsys audio | grep -ciE "Active communication device|type:earpiece|type:speaker")
[ "${NAUD:-0}" -ge 1 ] 2>/dev/null && pass "audio outputs enumerated" || warn "audio outputs not reported"
RES=$(sh_ wm size | sed -n 's/Physical size: //p')
HZ=$(sh_ dumpsys display | sed -n 's/.*fps=\([0-9.]*\).*/\1/p' | head -1)
[ -n "$RES" ] && pass "display ${RES}${HZ:+ @ ${HZ}fps}" || warn "cannot read display size"
DISPON=$(sh_ dumpsys display | grep -c "mScreenState=ON")
[ "${DISPON:-0}" -ge 1 ] 2>/dev/null && info "screen on" || info "screen off"
skip "camera capture, video playback and speaker sound need a human"

# --------------------------------------------------------------- storage
head2 "storage / memory / thermal"
DUSE=$(sh_ df /data | awk 'NR==2{print $5" used, "$4" free"}')
[ -n "$DUSE" ] && pass "/data ${DUSE}" || warn "cannot read /data usage"
MEMAVAIL=$(sh_ grep MemAvailable /proc/meminfo | awk '{print $2}')
if [ "${MEMAVAIL:-0}" -gt 200000 ] 2>/dev/null; then
  pass "MemAvailable $((MEMAVAIL/1024)) MiB"
else
  warn "MemAvailable ${MEMAVAIL:-?} kB"
fi
if adb shell 'echo x > /sdcard/.doha-write-test && rm /sdcard/.doha-write-test' >/dev/null 2>&1; then
  pass "/sdcard writable"
else
  fail "/sdcard not writable"
fi
LEV=$(sh_ dumpsys battery | sed -n 's/^ *level: //p' | head -1)
TEMP=$(sh_ dumpsys battery | sed -n 's/^ *temperature: //p' | head -1)
if [ -n "$LEV" ]; then
  pass "battery ${LEV}%${TEMP:+, $((TEMP/10)).$((TEMP%10)) °C}"
else
  warn "battery state unavailable"
fi
CPU_T=$(sh_ dumpsys thermalservice | grep -m1 "mName=CPU" | sed -n 's/.*mValue=\([0-9.]*\).*/\1/p')
[ -n "$CPU_T" ] && pass "CPU ${CPU_T} °C" || skip "no CPU thermal reading"

# --------------------------------------------------------------- summary
printf '\n%s%s%s\n' "$D" "$(printf '─%.0s' $(seq 1 64))" "$N"
printf '%s%d passed%s · %s%d warned%s · %s%d failed%s · %s%d skipped%s\n' \
  "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N" "$D" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailures:\n'
  printf '  - %s\n' "${fails[@]}"
fi
[ "$VERBOSE" = 1 ] && info "for a full report: adb logcat -b all -d > logcat.txt"
[ "$FAIL" -gt 99 ] && exit 99
exit "$FAIL"
