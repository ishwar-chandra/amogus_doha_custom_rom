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
#   tools/integrity-setup.sh import keybox.xml # import + restart GMS (base64 into Settings.Secure)
#   tools/integrity-setup.sh clear             # remove the keybox, keep the target list
#   tools/integrity-setup.sh check             # launch vvb2060 KeyAttestation to read the chain
#
# The import writes the same Settings.Secure key (spoof_trickystore_keybox) and target list
# that crDroid Settings > Misc > TrickyStore writes, so the GUI keeps working afterwards.
#
#   ADB      adb binary (default: adb)
#   KEYBOX   same as `import`'s file argument
set -euo pipefail

ADB=${ADB:-adb}
TARGETS_KEY=spoof_trickystore_target
KEYBOX_KEY=spoof_trickystore_keybox
PIF_KEY=spoof_pif_config
DEFAULT_TARGETS="android
com.android.vending
com.google.android.gsf"
KA_PKG=io.github.vvb2060.keyattestation

die() { printf 'integrity-setup: %s\n' "$*" >&2; exit 1; }
need_device() {
    command -v "$ADB" >/dev/null || die "adb not found"
    [ "$("$ADB" devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')" -ge 1 ] \
        || die "no device attached"
}
sh() { "$ADB" shell "$@"; }

has_pkg() { sh "pm list packages $1" 2>/dev/null | grep -q "package:$1"; }

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
    printf 'PIF config      '
    if [ -n "$(sh "settings get secure $PIF_KEY" | tr -d '\r\n')" ] \
        && [ "$(sh "settings get secure $PIF_KEY" | tr -d '\r\n')" != "null" ]; then
        printf 'loaded (%s)\n' "$(sh "settings get secure $PIF_KEY" \
            | tr -d '\r' | sed -n 's/.*"FINGERPRINT": *"\([^"]*\)".*/\1/p')"
    else
        printf 'none - crDroid Settings > Misc > Play Integrity Fix\n'
    fi
    printf 'keybox          '
    if [ "$(sh "settings get secure $KEYBOX_KEY" | tr -d '\r\n')" != "null" ]; then
        printf 'installed (%s chars base64)\n' "$(sh "settings get secure $KEYBOX_KEY" | tr -d '\r\n' | wc -c)"
    else
        printf 'NONE - the built-in feature has nothing to sign with\n'
    fi
    printf 'targets         %s\n' "$(sh "settings get secure $TARGETS_KEY" | tr -d '\r' | paste -sd, -)"
    printf 'KeyAttestation  '
    has_pkg "$KA_PKG" && printf 'installed\n' || printf 'not installed\n'
}

cmd_import() {
    need_device
    local file=${1:-${KEYBOX:-}}
    [ -n "$file" ] || die "usage: integrity-setup.sh import <keybox.xml>"
    [ -r "$file" ] || die "cannot read $file"
    grep -qi '<Keybox' "$file" || die "$file does not look like a keybox (no <Keybox> element)"
    grep -qi '<PrivateKey' "$file" || die "$file has no <PrivateKey>"

    # crDroidSettings stores base64 of the XML; the framework decodes one layer.
    local payload
    if head -c 5 "$file" | grep -q '<'; then
        payload=$(base64 -w0 <"$file")
    else
        payload=$(tr -d '\r\n' <"$file")
    fi

    sh "settings put secure $KEYBOX_KEY '$payload'"
    [ "$(sh "settings get secure $KEYBOX_KEY" | tr -d '\r\n')" != "null" ] \
        || die "keybox did not land in Settings.Secure"

    # Keep whatever the user already had in the target list; add the defaults if absent.
    local current
    current=$(sh "settings get secure $TARGETS_KEY" | tr -d '\r')
    local merged=$current
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf '%s\n' "$current" | grep -qx "$t" || merged="$merged
$t"
    done <<<"$DEFAULT_TARGETS"
    if [ "$merged" != "$current" ]; then
        sh "settings put secure $TARGETS_KEY '$(printf '%s' "$merged")'"
    fi

    # TrickyStore re-reads the keybox on process start; restart the consumers.
    sh 'am force-stop com.android.vending; am force-stop com.google.android.gms' >/dev/null 2>&1 || true
    printf 'imported %s\n' "$file"
    printf 'targets:  %s\n' "$(sh "settings get secure $TARGETS_KEY" | tr -d '\r' | paste -sd, -)"
    printf 'next:     tools/integrity-setup.sh check\n'
}

cmd_clear() {
    need_device
    sh "settings delete secure $KEYBOX_KEY" >/dev/null
    sh 'am force-stop com.android.vending; am force-stop com.google.android.gms' >/dev/null 2>&1 || true
    printf 'keybox removed\n'
}

cmd_check() {
    need_device
    if has_pkg "$KA_PKG"; then
        # TrickyStore only rewrites attestation for packages on the target list, so the
        # checker has to be on it for the chain to be visible.
        local cur
        cur=$(sh "settings get secure $TARGETS_KEY" | tr -d '\r')
        if ! printf '%s\n' "$cur" | grep -qx "$KA_PKG"; then
            sh "settings put secure $TARGETS_KEY '$(printf '%s\n%s' "$cur" "$KA_PKG")'"
            printf 'added %s to the TrickyStore target list\n' "$KA_PKG"
        fi
        sh "am force-stop $KA_PKG" >/dev/null 2>&1 || true
        sh "am start -n $KA_PKG/.home.HomeActivity" >/dev/null
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
    -h|--help) sed -n '2,27p' "$0" ;;
    *) die "unknown command '$1' (status|import|clear|check)" ;;
esac
