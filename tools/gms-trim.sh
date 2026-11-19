#!/usr/bin/env bash
# Trim Google Play Services components that cost background time on this phone.
#
# Cherry-picked from the Infamick Magisk script (see docs/OPTIMIZATION.md), which
# disables 302 GMS components in one shot - including Pay, Nearby/Quick Share and
# Play Games. Same mechanism here, but the list is grouped so you disable only
# what you do not use, and everything can be put back.
#
# Component list: tools/gms-trim.components (group<TAB>component). chimera and
# phenotype entries from that script are deliberately excluded: chimera carries
# GMS push/intent delivery and phenotype carries Play Services flag config.
#
# State: tools/.gms-trim.state (gitignored). Disabled components persist in /data
# across OTA updates, so this is run-once, not per-boot.
#
# Usage:
#   tools/gms-trim.sh --list                 # groups with component counts
#   tools/gms-trim.sh --dry-run              # default groups, change nothing
#   tools/gms-trim.sh                        # apply default groups (ads,analytics,stats)
#   tools/gms-trim.sh -g ads,analytics,cast  # pick groups
#   tools/gms-trim.sh -g all                 # every group (breaks Pay/Nearby/Games)
#   tools/gms-trim.sh --restore              # re-enable what this tool disabled
#   tools/gms-trim.sh --su                   # force `su -c pm ...` (Magisk/KernelSU)
#
# On a build that reports ro.debuggable=0 (this one does) plain `pm disable` is
# refused, but a Magisk/KernelSU shell is root and works - the tool detects that
# and switches to `su -c` by itself; --su just forces it.

set -euo pipefail

ADB=${ADB:-adb}
PKG=com.google.android.gms
HERE="$(dirname "$(readlink -f "$0")")"
LIST="$HERE/gms-trim.components"
STATE_FILE="$HERE/.gms-trim.state"
DEFAULT_GROUPS="ads,analytics,stats"

SU=0
die() { printf 'gms-trim: %s\n' "$*" >&2; exit 1; }

# pm wrapper: root shell if the device has one, otherwise the adb shell user.
pm_do() {
    if [ "$SU" = 1 ]; then
        "$ADB" shell "su -c 'pm $*'"
    else
        "$ADB" shell "pm $*"
    fi
}

detect_root() {
    local uid
    uid=$("$ADB" shell id -u 2>/dev/null | tr -d '\r' || echo 2000)
    if [ "$uid" = 0 ]; then SU=0; return; fi
    if [ "$SU" = 0 ] && "$ADB" shell su -c id 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; then
        printf 'gms-trim: root shell detected, using su -c\n'
        SU=1
    fi
}

[ -f "$LIST" ] || die "missing $LIST"

all_groups() { awk -F'\t' '!/^#/ && NF>=2 {print $1}' "$LIST" | sort -u | tr '\n' ' ' | sed 's/ $//'; }

components_for() {
    local g gg
    for g in $(printf '%s' "$1" | tr ',' ' '); do
        if [ "$g" = all ]; then
            for gg in $(all_groups); do
                awk -F'\t' -v G="$gg" '$1==G {print $2}' "$LIST"
            done
        else
            awk -F'\t' -v G="$g" '$1==G {print $2}' "$LIST"
        fi
    done | sort -u
}

need_device() {
    "$ADB" get-state >/dev/null 2>&1 || die "no device over adb (check adb devices)"
    pm_do path "$PKG" >/dev/null 2>&1 || die "$PKG is not installed"
    detect_root
}

do_list() {
    need_device
    printf '%-12s %6s\n' GROUP COUNT
    for g in $(all_groups); do
        printf '%-12s %6s\n' "$g" "$(awk -F'\t' -v G="$g" '!/^#/ && $1==G' "$LIST" | wc -l)"
    done
    printf '\nDefault groups: %s  (root shell: %s)\n' "$DEFAULT_GROUPS" \
        "$([ "$SU" = 1 ] && echo "su -c" || echo "adb shell")"
}

do_restore() {
    need_device
    [ -s "$STATE_FILE" ] || die "nothing recorded in $STATE_FILE"
    ok=0; bad=0
    while IFS= read -r comp; do
        [ -n "$comp" ] || continue
        if pm_do enable "$comp" 2>&1 | grep -qi 'new state'; then
            printf 'enabled   %s\n' "$comp"; ok=$((ok + 1))
        else
            printf 'FAILED    %s\n' "$comp"; bad=$((bad + 1))
        fi
    done < "$STATE_FILE"
    printf '\n%d re-enabled, %d failed\n' "$ok" "$bad"
    [ "$bad" -eq 0 ] && rm -f "$STATE_FILE"
    return $([ "$bad" -eq 0 ] && echo 0 || echo 1)
}

dry=0
groups=$DEFAULT_GROUPS
action=apply
while [ $# -gt 0 ]; do
    case "$1" in
        --list) action=list; shift ;;
        --restore) action=restore; shift ;;
        --dry-run) dry=1; shift ;;
        --su) SU=1; shift ;;
        -g|--groups) groups=${2:-}; shift 2; [ -n "$groups" ] || die "empty --groups" ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
done

[ "$action" = list ] && { do_list; exit 0; }
[ "$action" = restore ] && { do_restore; exit $?; }

for g in $(printf '%s' "$groups" | tr ',' ' '); do
    [ "$g" = all ] && continue
    awk -F'\t' -v G="$g" '$1==G' "$LIST" | grep -q . || die "unknown group '$g' (try --list)"
done

need_device
components=$(components_for "$groups")
[ -n "$components" ] || die "no components matched $groups"

if [ "${dry:-0}" = 1 ]; then
    printf 'would disable:\n'
    printf '%s\n' "$components" | sed 's/^/  /'
    printf '\n%d component(s) in groups %s - nothing changed\n' \
        "$(printf '%s\n' "$components" | wc -l)" "$groups"
    exit 0
fi

ok=0; denied=0; : > "$STATE_FILE.tmp"
while IFS= read -r comp; do
    [ -n "$comp" ] || continue
    out=$(pm_do disable "$comp" 2>&1 | tr -d '\r' || true)
    case "$out" in
        *SecurityException*|*"Permission denial"*|*"not allowed"*|*Exception*)
            printf 'denied   %s\n' "$comp"; denied=$((denied + 1)) ;;
        *"new state"*|*isabled*)
            printf 'disabled %s\n' "$comp"
            printf '%s\n' "$comp" >> "$STATE_FILE.tmp"; ok=$((ok + 1)) ;;
        *)
            printf 'unknown  %s  [%s]\n' "$comp" "$out"; denied=$((denied + 1)) ;;
    esac
done <<< "$components"

if [ "$ok" -eq 0 ]; then
    rm -f "$STATE_FILE.tmp"
    die "every change was refused - this build does not let the shell change component state (ro.debuggable=0 here), so use a rooted build"
fi
cat "$STATE_FILE.tmp" >> "$STATE_FILE"
sort -u -o "$STATE_FILE" "$STATE_FILE"
rm -f "$STATE_FILE.tmp"
printf '\n%d disabled in groups %s, %d refused. Recorded in %s\n' "$ok" "$groups" "$denied" "$STATE_FILE"
