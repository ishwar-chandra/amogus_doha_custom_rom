#!/usr/bin/env bash
# Install or inspect the keybox that crDroid's built-in TrickyStore needs, without root.
#
# Why: on doha the vendor keymaster (android.hardware.keymaster@4.1-service-qti) answers
# every attested key generation with vendor error -10003, so no Google-rooted attestation
# chain exists and the Play Integrity API returns UNEVALUATED for every field regardless of
# PIF config (measured 2026-11-21). crDroid 13.1 ships TrickyStore, which detects the broken
# TEE and generates a chain signed by the keybox instead; with a keybox imported, KeyAttestation
# shows a complete chain ("Bootloader is locked", Keymaster 4.1, TrustedEnvironment).
#
# A keybox is a file of Google attestation keys. This kit never ships or downloads one: keys
# leak, Google revokes them in waves, and importing one is the user's own call. Supply your
# own file; crDroid's blog names places to look.
#
#   tools/integrity-setup.sh status            # device, GApps, PIF config, keybox, boot props
#   tools/integrity-setup.sh import keybox.xml # import + restart the GMS family
#   tools/integrity-setup.sh clear             # remove the keybox and prompt state, keep targets
#   tools/integrity-setup.sh check             # launch vvb2060 KeyAttestation to read the chain
#
# The import writes the same Settings.Secure key (spoof_trickystore_keybox) and target list
# that crDroid Settings > Misc > TrickyStore writes, so the GUI keeps working afterwards.
# A legacy target list written by older versions of this tool is deleted so crDroid's
# AxSpoofManagerService can seed its full default list; custom entries are preserved.
#
#   ADB      adb binary (default: adb)
#   KEYBOX   same as `import`'s file argument
set -euo pipefail

ADB=${ADB:-adb}
TARGETS_KEY=spoof_trickystore_target
KEYBOX_KEY=spoof_trickystore_keybox
PIF_KEY=spoof_pif_config
NEEDED_PROMPT_KEY=spoof_trickystore_needed_prompt
ATTEST_STATE_KEY=spoof_trickystore_attest_state
KA_PKG=io.github.vvb2060.keyattestation
DEFAULT_TARGETS="android
com.android.vending
com.google.android.gsf
com.google.android.gms"
LEGACY_TARGETS="android
com.android.vending
com.google.android.gsf"
GMS_FAMILY="com.android.vending
com.google.android.gms
com.google.android.gsf
com.google.android.safetycore
com.google.android.rkpdapp
com.google.android.contactkeys"
TMP_WORK=

die() { printf 'integrity-setup: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -z "$TMP_WORK" ] || rm -rf "$TMP_WORK"; }
trap cleanup EXIT

need_device() {
    command -v "$ADB" >/dev/null || die "adb not found"
    [ "$("$ADB" devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')" -ge 1 ] \
        || die "no device attached"
}
sh() { "$ADB" shell "$@"; }

has_pkg() { sh "pm list packages $1" 2>/dev/null | grep -q "package:$1"; }

# Reads a Settings.Secure string. `settings get` prints the literal `null` for an unset key.
get_setting() {
    sh "settings get secure $1" 2>/dev/null | tr -d '\r' | sed -e '/^[[:space:]]*$/d'
}

# One package per line, no surrounding whitespace or blank lines.
clean_list() {
    printf '%s\n' "$1" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

# Legacy state is an unset key, the bare `null` sentinel, or exactly the list older
# versions of this script wrote (`null` plus android/vending/gsf, in that order).
is_legacy_targets() {
    local raw=$1 norm
    norm=$(clean_list "$raw")
    if [ -z "$norm" ] || [ "$norm" = "null" ]; then
        return 0
    fi
    if [ "$norm" = "$LEGACY_TARGETS" ]; then
        return 0
    fi
    if [ "$norm" = "null
$LEGACY_TARGETS" ]; then
        return 0
    fi
    return 1
}

# Mode-aware exact match: `pkg`, `pkg?`, `pkg!` and `pkg-` all count, substrings never do.
target_present() {
    local list=$1 pkg=$2
    if [ -z "$list" ] || [ "$list" = "null" ]; then
        return 1
    fi
    printf '%s\n' "$list" | grep -Eqx -- "${pkg//./\\.}[?!-]?"
}

# Appends whichever defaults are absent. Existing lines, order and mode suffixes are kept;
# the literal `null` sentinel is never carried into a written list.
merge_default_targets() {
    local merged pkg
    merged=$(clean_list "$1" | grep -vx -- 'null' || true)
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        if ! target_present "$merged" "$pkg"; then
            if [ -n "$merged" ]; then
                merged="$merged
$pkg"
            else
                merged=$pkg
            fi
        fi
    done <<<"$DEFAULT_TARGETS"
    printf '%s' "$merged"
}

write_targets() {
    local value=$1 stored
    [ -n "$value" ] || die "refusing to write an empty target list"
    sh "settings put secure $TARGETS_KEY '$value'" >/dev/null
    stored=$(get_setting "$TARGETS_KEY")
    [ -n "$stored" ] && [ "$stored" != "null" ] \
        || die "target list did not land in Settings.Secure"
}

# Saves the keybox's consumers from stale state. Only installed packages are touched.
stop_gms_family() {
    local pkg
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        if has_pkg "$pkg"; then
            sh "am force-stop $pkg" >/dev/null 2>&1 || true
        fi
    done <<<"$GMS_FAMILY"
}

# After import: either reseed the legacy tool-owned list or merge into a customized one.
ensure_target_list() {
    local current seeded i merged
    current=$(get_setting "$TARGETS_KEY")
    if is_legacy_targets "$current"; then
        sh "settings delete secure $TARGETS_KEY" >/dev/null
        seeded=
        for i in $(seq 1 10); do
            sleep 1
            seeded=$(get_setting "$TARGETS_KEY")
            if [ -n "$seeded" ] && [ "$seeded" != "null" ] \
                && target_present "$seeded" com.google.android.gms; then
                break
            fi
        done
        if [ -z "$seeded" ] || [ "$seeded" = "null" ] \
            || ! target_present "$seeded" com.google.android.gms; then
            die "TrickyStore did not seed default targets; open Settings > Misc > TrickyStore"
        fi
        current=$seeded
    fi
    merged=$(merge_default_targets "$current")
    if [ "$merged" != "$(clean_list "$current")" ]; then
        write_targets "$merged"
    fi
}

# Decoded XML must be complete: a truncated file must never reach `settings put`.
validate_keybox_xml() {
    local xml=$1 label=$2
    [ -s "$xml" ] || die "$label is empty"
    { grep -qi '<Keybox' "$xml" && grep -qi '</Keybox>' "$xml"; } \
        || die "$label is not a complete keybox (<Keybox> element missing or truncated)"
    { grep -qi '<PrivateKey' "$xml" && grep -qi '</PrivateKey>' "$xml"; } \
        || die "$label is not a complete keybox (<PrivateKey> element missing or truncated)"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$xml" \
            || die "$label is not well-formed XML"
    fi
}

# TrickyStoreService logs its own parse verdict; surface it instead of hiding a bad keybox.
report_ts_parse_failures() {
    local hits
    hits=$(sh 'logcat -d -s TrickyStoreService' 2>/dev/null | tr -d '\r' \
        | grep -iE 'parse|malformed|invalid|fail|error' | tail -n 5 || true)
    if [ -n "$hits" ]; then
        printf 'TrickyStoreService reported a keybox problem:\n%s\n' "$hits" >&2
    fi
}

cmd_status() {
    need_device
    printf 'device          %s\n' "$(sh getprop ro.product.device | tr -d '\r')"
    printf 'build           %s (%s)\n' "$(sh getprop ro.build.display.id | tr -d '\r')" \
        "$(sh getprop ro.build.date.utc | tr -d '\r')"
    printf 'gms/vending     '
    if has_pkg com.google.android.gms && has_pkg com.android.vending; then
        printf 'installed\n'
    else
        printf 'MISSING - Play Integrity is inert without them\n'
    fi
    printf 'verified boot   state=%s locked=%s (kernel cmdline: %s)\n' \
        "$(sh getprop ro.boot.verifiedbootstate | tr -d '\r')" \
        "$(sh getprop ro.boot.flash.locked | tr -d '\r')" \
        "$(sh cat /proc/cmdline | tr ' ' '\n' | sed -n 's/^androidboot.verifiedbootstate=//p' | tr -d '\r')"
    local pif kb targets
    pif=$(get_setting "$PIF_KEY")
    printf 'PIF config      '
    if [ -n "$pif" ] && [ "$pif" != "null" ]; then
        printf 'loaded (%s)\n' "$(printf '%s' "$pif" \
            | sed -n 's/.*"FINGERPRINT": *"\([^"]*\)".*/\1/p')"
    else
        printf 'none - crDroid Settings > Misc > Play Integrity Fix\n'
    fi
    kb=$(get_setting "$KEYBOX_KEY")
    printf 'keybox          '
    if [ -n "$kb" ] && [ "$kb" != "null" ]; then
        printf 'installed (%s chars base64)\n' "${#kb}"
    else
        printf 'NONE - the built-in feature has nothing to sign with\n'
    fi
    targets=$(get_setting "$TARGETS_KEY")
    if [ -n "$targets" ] && [ "$targets" != "null" ]; then
        targets=$(clean_list "$targets" | grep -vx -- 'null' || true)
    fi
    printf 'targets         '
    case "$targets" in
        ""|null) printf 'unset - import seeds the crDroid default list\n' ;;
        *) printf '%s\n' "$targets" | paste -sd, - ;;
    esac
    printf 'KeyAttestation  '
    has_pkg "$KA_PKG" && printf 'installed\n' || printf 'not installed\n'
}

cmd_import() {
    need_device
    local file=${1:-${KEYBOX:-}}
    [ -n "$file" ] || die "usage: integrity-setup.sh import <keybox.xml>"
    [ -r "$file" ] || die "cannot read $file"

    TMP_WORK=$(mktemp -d) || die "cannot create a temporary directory"
    local xml=$file
    if ! grep -q '<' "$file"; then
        # Base64 input: decode one layer, then re-encode canonically below.
        local b64=$TMP_WORK/input.b64
        tr -d '[:space:]' <"$file" >"$b64"
        [ -s "$b64" ] || die "$file is empty"
        if ! base64 -d "$b64" >"$TMP_WORK/keybox.xml" 2>/dev/null; then
            die "$file is not valid base64"
        fi
        xml=$TMP_WORK/keybox.xml
    fi
    validate_keybox_xml "$xml" "$file"

    # Exactly one layer of contiguous base64, whatever the input wrapping was.
    local payload
    payload=$(base64 -w0 <"$xml")
    [ -n "$payload" ] || die "$file produced an empty payload"
    case "$payload" in
        *[!A-Za-z0-9+/=]*) die "$file produced an unsafe base64 payload" ;;
    esac

    sh "settings put secure $KEYBOX_KEY '$payload'"
    local stored
    stored=$(get_setting "$KEYBOX_KEY")
    [ -n "$stored" ] && [ "$stored" != "null" ] \
        || die "keybox did not land in Settings.Secure"

    ensure_target_list
    stop_gms_family
    report_ts_parse_failures

    printf 'imported %s\n' "$file"
    printf 'targets:  %s\n' "$(get_setting "$TARGETS_KEY" | paste -sd, -)"
    printf 'next:     tools/integrity-setup.sh check\n'
}

cmd_clear() {
    need_device
    sh "settings delete secure $KEYBOX_KEY" >/dev/null
    sh "settings delete secure $NEEDED_PROMPT_KEY" >/dev/null
    sh "settings delete secure $ATTEST_STATE_KEY" >/dev/null
    stop_gms_family
    printf 'keybox and prompt state removed (target list kept)\n'
}

cmd_check() {
    need_device
    if has_pkg "$KA_PKG"; then
        # TrickyStore only rewrites attestation for packages on the target list, so the
        # checker has to be on it for the chain to be visible. Any existing mode wins.
        local cur merged
        cur=$(get_setting "$TARGETS_KEY")
        case "$cur" in
            ""|null) cur= ;;
            *) cur=$(clean_list "$cur") ;;
        esac
        if ! target_present "$cur" "$KA_PKG"; then
            if [ -n "$cur" ]; then
                cur="$cur
$KA_PKG?"
            else
                cur="$KA_PKG?"
            fi
            merged=$(merge_default_targets "$cur")
            write_targets "$merged"
            printf 'added %s? to the TrickyStore target list\n' "$KA_PKG"
        fi
        sh "am force-stop $KA_PKG" >/dev/null 2>&1 || true
        local out
        if ! out=$(sh "am start -W -n $KA_PKG/.home.HomeActivity" 2>&1); then
            die "could not launch $KA_PKG (am start failed)"
        fi
        case "$out" in
            *"Status: ok"*) ;;
            *) die "could not launch $KA_PKG: $(printf '%s' "$out" | tr '\n' ' ')" ;;
        esac
        printf '%s\n' 'KeyAttestation opened: a full chain with "Bootloader is locked" means the keybox works;'
        printf '%s\n' '-10003 means no keybox is installed (or it failed to parse).'
    else
        printf '%s is not installed; its APK is on github.com/vvb2060/KeyAttestation\n' "$KA_PKG"
    fi
}

case "${1:-status}" in
    status) cmd_status ;;
    import) shift; cmd_import "$@" ;;
    clear)  cmd_clear ;;
    check)  cmd_check ;;
    -h|--help) sed -n '2,26p' "$0" ;;
    *) die "unknown command '$1' (status|import|clear|check)" ;;
esac
