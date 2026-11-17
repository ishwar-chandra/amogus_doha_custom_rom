#!/usr/bin/env bash
# Flash a doha build from an artifacts directory (default: ./gcp-out).
#
# A "set" is what build.sh copied out of one build: a zip, boot/dtbo/vbmeta
# images and a .sha256sum naming them. Sets are discovered through that
# .sha256sum, so both layouts work — build.sh's current <zipname>-boot.img and
# the older plain boot.img. Only sets whose files are all present are
# selectable; every other variant (release, userdebug, GApps) is listed but
# disabled, because no artifact for it exists in this directory.
#
# Usage:
#   tools/flash.sh [ARTIFACT_DIR] [--list] [--set N] [--dry-run] [--yes]
#                  [--sideload-only] [--no-color]
#
#   --list           print the detected sets, then exit
#   --set N          pick entry N without prompting
#   --dry-run        print the fastboot/adb commands instead of running them
#   --yes            skip the confirmation prompt
#   --sideload-only  skip the images; wait for recovery and sideload only
#   --current-slot   flash boot/dtbo/vbmeta into the active slot only (default:
#                    both slots, because the sideload installs into the *other*
#                    one — a hand-flashed active slot is how a phone ends up
#                    booting a mismatched pair and hanging at the animation)
#   --no-color       plain text (also honours NO_COLOR=1)
#
# Waits are tunable: WAIT_FB (60s for the fastboot screen), WAIT_ADB (180s for
# adb to appear after the reboot to recovery), WAIT_SIDELOAD (300s for the
# phone to enter sideload mode once you pick Apply from ADB).
#
# The build variant (user vs userdebug) is NOT recorded in these artifacts:
# crDroid sets PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG, so both report
# user/release-keys. Keep one directory per variant (gcp-out-user,
# gcp-out-userdebug) if you build both. Only the -adbkey suffix is
# distinguishable: a test build whose adb trusts the builder's key.
set -euo pipefail

DIR=${ARTIFACTS_DIR:-}
LIST=0 SET="" DRY=0 YES=0 SIDELOAD_ONLY=0 SLOT_ALL=1 COLOR=auto
WAIT_FB=${WAIT_FB:-60} WAIT_ADB=${WAIT_ADB:-180} WAIT_SIDELOAD=${WAIT_SIDELOAD:-300}
while [ $# -gt 0 ]; do
  case $1 in
    --list) LIST=1 ;;
    --set) SET=${2:?--set needs a number}; shift ;;
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --sideload-only) SIDELOAD_ONLY=1 ;;
    --current-slot) SLOT_ALL=0 ;;
    --no-color) COLOR=never ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) DIR=$1 ;;   # a bare argument is the artifacts directory
  esac
  shift
done

# ---- colour + layout -------------------------------------------------------
# Status goes to stderr (so --list stays pipeable); the menu follows the same
# rule. Colour only when that stream is a terminal, so logs and pipes stay
# clean. Width is re-read on every render, so resizing the window is fine.
if [ "$COLOR" = never ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-dumb}" = dumb ] || [ ! -t 2 ]; then
  B= DIM= R= G= Y= C= M= INV=
else
  B=$'\033[1m' DIM=$'\033[2m' R=$'\033[0m' G=$'\033[32m' Y=$'\033[33m'
  C=$'\033[36m' M=$'\033[35m' INV=$'\033[7m'
fi
trap 'printf "%s" "${R:-}" >&2' EXIT

W=80
width() {
  local c=${COLUMNS:-0}
  [ "$c" -gt 0 ] 2>/dev/null || c=$(tput cols 2>/dev/null) || c=80
  case $c in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 56 ] && c=56
  [ "$c" -gt 120 ] && c=120
  W=$((c > 4 ? c - 2 : 56))
  echo "$W"
}

fit() {  # fit "string" width -> truncated with an ellipsis
  local s=$1 n=$2
  if [ "${#s}" -le "$n" ]; then printf '%s' "$s"; else printf '%s…' "${s:0:$((n - 1))}"; fi
}

rule() { width >/dev/null; printf '%s%s%s\n' "$DIM" "$(printf '─%.0s' $(seq 1 "$W"))" "$R" >&2; }
title() {
  width >/dev/null
  printf '\n%s%s%s%s\n' "$B" "$M" "$1" "$R" >&2
  printf '%s%s%s\n' "$DIM" "$(printf '─%.0s' $(seq 1 "$W"))" "$R" >&2
}
step()  { printf '%s▸%s %s%s%s\n' "$C" "$R" "$B" "$*" "$R" >&2; }
ok()    { printf '  %s✔%s %s\n' "$G" "$R" "$*" >&2; }
warn()  { printf '  %s▲%s %s%s%s\n' "$Y" "$R" "$Y" "$*" "$R" >&2; }
err()   { printf '  %s✖%s %s%s%s\n' "$R" "$R" "$B" "$*" "$R" >&2; }
note()  { printf '  %s•%s %s%s%s\n' "$DIM" "$R" "$DIM" "$*" "$R" >&2; }
kv()    { printf '  %s%-8s%s %s\n' "$DIM" "$1" "$R" "$2" >&2; }
ask()   { printf '\n%s?%s %s%s%s ' "$M" "$R" "$B" "$1" "$R" >&2; }

# ---- locate the artifacts --------------------------------------------------
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR=${DIR:-$HERE/../gcp-out}
RESOLVED=$(cd "$DIR" 2>/dev/null && pwd) || {
  err "no such directory: $DIR"
  note "pull a build first: tools/gcp-build.sh fetch"
  exit 1
}
DIR=$RESOLVED

# ---- detection -------------------------------------------------------------
S_NAME=() S_KIND=() S_ZIP=() S_BOOT=() S_DTBO=() S_VBMETA=() S_SUM=() S_SIZE=() S_TIME=()

add_set() {  # $1 sum, $2 zip, $3 boot, $4 dtbo, $5 vbmeta
  [ -f "$2" ] && [ -f "$3" ] && [ -f "$4" ] && [ -f "$5" ] || return 0
  S_NAME+=("$(basename "${2%.zip}")")
  case ${2##*/} in
    *-adbkey.zip) S_KIND+=("ADB_KEY test") ;;
    *)            S_KIND+=("release/userdebug") ;;
  esac
  S_ZIP+=("$2") S_BOOT+=("$3") S_DTBO+=("$4") S_VBMETA+=("$5") S_SUM+=("$1")
  S_SIZE+=("$(du -h "$2" | cut -f1)")
  S_TIME+=("$(date -r "$2" '+%Y-%m-%d %H:%M')")
}

# Primary: the .sha256sum build.sh wrote, which names that build's files.
for sum in "$DIR"/*.sha256sum; do
  [ -f "$sum" ] || continue
  zip="" boot="" dtbo="" vbmeta=""
  while read -r _hash path; do
    case $path in
      *.zip)         [ -z "$zip" ] && zip=$DIR/${path##*/} ;;
      *boot.img)     [ -z "$boot" ] && boot=$DIR/${path##*/} ;;
      *dtbo.img)     dtbo=$DIR/${path##*/} ;;
      *vbmeta.img)   vbmeta=$DIR/${path##*/} ;;
    esac
  done < "$sum"
  [ -n "$zip" ] && add_set "$sum" "$zip" "${boot:-/x}" "${dtbo:-/x}" "${vbmeta:-/x}"
done

# Fallback: a zip carrying <name>-images but no .sha256sum (hand-copied).
for zip in "$DIR"/*.zip; do
  [ -f "$zip" ] || continue
  already=0
  for n in ${S_ZIP[@]+"${S_ZIP[@]}"}; do [ "$n" = "$zip" ] && already=1; done
  [ "$already" = 1 ] && continue
  base=${zip%.zip}
  add_set "" "$zip" "$base-boot.img" "$base-dtbo.img" "$base-vbmeta.img"
done

# ---- menu ------------------------------------------------------------------
# One entry, two lines: the artifact name gets the full width, the metadata
# sits underneath. A table collapses on narrow terminals; this does not.
menu() {
  local i name badge
  width >/dev/null
  for i in ${S_NAME[@]+"${!S_NAME[@]}"}; do
    name=$(fit "${S_NAME[$i]}" $((W - 6)))
    case ${S_KIND[$i]} in
      ADB_KEY*) printf '  %s%2d%s  %s%s%s\n' "$B" "$((i + 1))" "$R" "$Y" "$name" "$R" >&2
                badge="${Y}ADB_KEY test build${R}" ;;
      *)        printf '  %s%2d%s  %s\n' "$B" "$((i + 1))" "$R" "$name" >&2
                badge="${DIM}release/userdebug${R}" ;;
    esac
    printf '      %s%s · %s · %s%s\n' "$DIM" "$badge" "${S_SIZE[$i]}" "${S_TIME[$i]}" "$R" >&2
  done
  [ ${#S_NAME[@]} -eq 0 ] && printf '  %s(none — pull a build first: tools/gcp-build.sh fetch)%s\n' "$DIM" "$R" >&2
  return 0
}

legend() {
  title "what is not selectable"
  printf '%s' "$DIM" >&2
  printf 'release (user) and userdebug are not recorded in the artifacts — crDroid\n' >&2
  printf 'spoofs user/release-keys, so both sets look alike; keep one directory per\n' >&2
  printf 'variant and pass it as the argument.  vanilla (no GApps) is every current\n' >&2
  printf 'build (GApps are sideloaded separately); GApps baked in is planned.%s\n' "$R" >&2
}

banner() {
  width >/dev/null
  printf '\n%s%s┌─%s %sdoha flasher%s\n' "$B" "$M" "$R" "$B" "$R" >&2
  printf '%s│%s  %s%s%s\n' "$M" "$R" "$DIM" "$DIR" "$R" >&2
  printf '%s└─%s %sflash a build · %d set(s) found%s\n' "$M" "$R" "$DIM" "${#S_NAME[@]}" "$R" >&2
  rule
}

# ---- list mode -------------------------------------------------------------
if [ "$LIST" = 1 ]; then
  banner; menu err; rule
  exit 0
fi

[ ${#S_NAME[@]} -gt 0 ] || { err "nothing to flash in $DIR"; exit 1; }

banner
menu err
rule
legend

# ---- pick ------------------------------------------------------------------
if [ -n "$SET" ]; then
  pick=$SET
else
  ask "Which set? [1-${#S_NAME[@]}, q]"
  read -r pick || { printf '\n' >&2; err "cancelled (no input)"; exit 1; }
fi
case $pick in q|Q|"") err "cancelled"; exit 1 ;; esac
{ [[ $pick =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#S_NAME[@]} ]; } || {
  err "not a valid entry: $pick"
  note "only the numbered sets above exist"
  exit 1
}

i=$((pick - 1))
zip=${S_ZIP[$i]} boot=${S_BOOT[$i]} dtbo=${S_DTBO[$i]} vbmeta=${S_VBMETA[$i]}
sum=${S_SUM[$i]} kind=${S_KIND[$i]}

# ---- verify ----------------------------------------------------------------
if [ -n "$sum" ]; then
  step "verifying $(basename "$zip")"
  if [ "$DRY" = 1 ]; then
    note "would run: sha256sum -c $(basename "$sum")"
  else
    ( cd "$DIR" && sha256sum -c "$(basename "$sum")" >/dev/null ) || {
      err "checksum mismatch — do not flash this copy (incomplete transfer?)"
      exit 1
    }
    ok "checksums match"
  fi
else
  warn "no .sha256sum for this set — skipping verification"
fi

# ---- plan ------------------------------------------------------------------
title "flash plan"
kv boot   "$(basename "$boot")"
kv dtbo   "$(basename "$dtbo")"
kv vbmeta "$(basename "$vbmeta")"
kv system "$(basename "$zip")   (sideload)"
kv kind   "$kind"

if [ "$kind" = "ADB_KEY test" ]; then
  printf '\n' >&2
  warn "test build: its adb trusts the builder's key"
  note "never share it; flash it only after Factory reset → Format data, or"
  note "Android's trade-in mode owns adb until the setup wizard finishes."
fi

rule
step "sequence (A/B phone, current slot)"
note "1. fastboot flash boot / dtbo / vbmeta"
note "2. reboot to recovery"
note "3. Factory reset → Format data   (required when changing adb-key state)"
note "4. Apply update → Apply from ADB, then this script sideloads"
rule

if [ "$YES" = 0 ] && [ "$DRY" = 0 ]; then
  ask "Continue? [y/N]"
  read -r go || { printf '\n' >&2; exit 1; }
  case $go in y|Y) ;; *) err "cancelled"; exit 1 ;; esac
fi

run() { if [ "$DRY" = 1 ]; then printf '  %s$%s %s\n' "$C" "$R" "$*" >&2; else "$@"; fi; }

adb_state()  { adb devices 2>/dev/null | awk 'NR>1 && $2!="" {print $2; exit}'; }
adb_serial() { adb devices 2>/dev/null | awk 'NR>1 && $2!="" {print $1; exit}'; }
adb_count()  { adb devices 2>/dev/null | awk 'NR>1 && $2!=""' | wc -l; }
fb_serial()  { fastboot devices 2>/dev/null | awk 'NF{print $1; exit}'; }

# Wait for a device to reach $goal (recovery|sideload), up to $2 s.
wait_adb() {
  local goal=$1 secs=$2 start=$SECONDS st spin=0
  while :; do
    st=$(adb_state)
    if [ "$st" = "$goal" ] || { [ "$goal" = recovery ] && [ "$st" = sideload ]; }; then
      printf '\r%*s\r' "$W" '' >&2
      ok "adb: $st"
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      printf '\r%*s\r' "$W" '' >&2
      err "adb stayed '${st:-none}' for ${secs}s"
      return 1
    fi
    spin=$(((spin + 1) % 4))
    printf '\r  %s%s%s waiting for %s  %s(%s)%s' "$DIM" "$(printf '|/-\\' | cut -c$((spin + 1)))" "$R" \
      "$goal" "$DIM" "${st:-no device}, ${SECONDS}s" "$R" >&2
    sleep 1
  done
}

# ---- device state ----------------------------------------------------------
step "looking for the phone"
if [ "$DRY" = 0 ] && [ "$(adb_count)" -gt 1 ] 2>/dev/null; then
  err "more than one adb device attached — unplug the others"
  adb devices >&2
  exit 1
fi

if [ "$SIDELOAD_ONLY" = 0 ]; then
  if [ "$DRY" = 0 ]; then
    start=$SECONDS
    until [ -n "$(fb_serial)" ]; do
      [ $((SECONDS - start)) -ge "$WAIT_FB" ] && break
      printf '\r%s  ⋯%s fastboot… %ss  %s' "$DIM" "$R" "$((SECONDS - start))" "" >&2
      sleep 1
    done
    printf '\r%*s\r' "$W" '' >&2
  fi
  if [ -z "$(fb_serial)" ] && [ "$DRY" = 0 ]; then
    case $(adb_state) in
      recovery|sideload) warn "no fastboot device, but adb sees $(adb_state) — skipping images" ;;
      *)
        err "no phone in fastboot"
        note "power + volume down → fastboot screen → plug USB, then re-run"
        note "or, from recovery:  ./flash.sh --sideload-only"
        exit 1 ;;
    esac
  else
    slot_arg=(); [ "$SLOT_ALL" = 1 ] && slot_arg=(--slot=all)
    run fastboot flash "${slot_arg[@]}" boot   "$boot"
    run fastboot flash "${slot_arg[@]}" dtbo   "$dtbo"
    run fastboot flash "${slot_arg[@]}" vbmeta "$vbmeta"
    run fastboot reboot recovery
  fi
fi

if [ "$DRY" = 1 ]; then
  printf '  %s$%s adb wait-for-device   %s# up to %ss, state recovery|sideload%s\n' \
    "$C" "$R" "$DIM" "$WAIT_ADB" "$R" >&2
  printf '  %s$%s adb sideload %s\n' "$C" "$R" "$zip" >&2
  ok "dry run — nothing was flashed"
  exit 0
fi

# Recovery needs 20-60 s to bring adbd up; the old script went straight to
# `adb sideload` and failed here.
step "waiting for recovery"
if ! wait_adb recovery "$WAIT_ADB"; then
  err "adb never appeared"
  note "phone booted Android instead of recovery → power+volume down, pick Recovery"
  note "recovery up but no USB → replug, or try another port"
  note "stale adb server → adb kill-server, then re-run"
  note "nothing was sideloaded; resume with:  ./flash.sh --sideload-only"
  exit 1
fi

if [ "$(adb_state)" != "sideload" ]; then
  printf '\n' >&2
  step "select  Apply update → Apply from ADB  on the phone"
  note "that puts it in sideload mode; waiting ${WAIT_SIDELOAD}s"
  wait_adb sideload "$WAIT_SIDELOAD" || {
    err "phone never entered sideload mode"
    note "select Apply from ADB and re-run with --sideload-only"
    exit 1
  }
fi

serial=$(adb_serial)
step "sideloading $(basename "$zip") → $serial"
adb -s "$serial" sideload "$zip"
ok "sideload finished"
note "format data if you changed the adb-key state, then reboot"
note "first boot after a wipe takes several minutes"
