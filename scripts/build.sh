#!/usr/bin/env bash
# Universal A16 buildkit for the Motorola Moto G8 Plus (amogus_doha).
#
# One entry point, resumable steps, every source pin and patch in this repo.
#   ./scripts/build.sh dryrun     validate everything, build nothing
#   ./scripts/build.sh all        deps -> init -> manifest -> sync -> patch -> build -> verify -> collect
#
# Individual steps: deps init manifest sync patch build verify collect status
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

usage() {
    cat <<'EOF'
Usage: ./scripts/build.sh <command>

  dryrun    validate config, files, scripts, URLs and the manifest generator
  deps      check host packages; download the repo launcher
  init      repo init crDroid 16.0 / Android 16 (idempotent)
  manifest  generate .repo/local_manifests/doha.xml from manifest/*.list
  sync      repo sync (resumable, 3 retries)
  patch     apply the A16 port patches + CarrierConfig + GApps/APN fixes
  build     lunch + make bacon
  verify    inspect the built images (GApps, VoLTE keys, APNs, RIL, props)
  collect   copy zip/images/checksums into dist/
  snapshot  save the exact resolved manifest (all projects) under manifests/
  all       run every step in order
  status    show step markers and tree size

Environment overrides: ROM, DEVICE, JOBS, SYNC_JOBS, ANDROID_SRC,
DIST_DIR, BUILD_VARIANT, BUNDLE_GAPPS, GAPPS_BRANCH, SIGNING, INSTALL_DEPS.
EOF
}

cmd_deps() {
    local packages=() missing=() p
    mapfile -t packages < <(grep -vE '^\s*(#|$)' "$KIT_ROOT/config/packages.list")
    [ "${#packages[@]}" -gt 0 ] || die "config/packages.list is empty"

    for p in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        warn "missing host packages: ${missing[*]}"
        if [ "${INSTALL_DEPS:-0}" = 1 ]; then
            command -v sudo >/dev/null || die "INSTALL_DEPS=1 but sudo is not available"
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}"
        else
            info "install with: sudo apt-get install -y ${missing[*]}"
            info "(or re-run with INSTALL_DEPS=1)"
        fi
    else
        info "host packages present"
    fi

    if ! repo_cmd >/dev/null 2>&1; then
        mkdir -p "$WORK/bin"
        info "downloading repo launcher..."
        curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$WORK/bin/repo"
        chmod +x "$WORK/bin/repo"
    fi
    info "repo: $(repo_cmd)"

    command -v ccache >/dev/null 2>&1 || warn "ccache missing: rebuilds will be slow"
    command -v python3 >/dev/null 2>&1 || die "python3 is required"

    local free_gb
    free_gb=$(df -Pk "$KIT_ROOT" | awk 'NR==2 {print int($4/1024/1024)}')
    info "free disk: ${free_gb} GB"
    [ "$free_gb" -ge 250 ] || warn "less than 250 GB free; the A16 tree + out needs ~300 GB"

    mark deps
}

cmd_init() {
    local repo
    repo=$(repo_cmd) || die "repo launcher missing (run: ./scripts/build.sh deps)"
    mkdir -p "$ANDROID_SRC"
    cd "$ANDROID_SRC"
    if [ -d .repo ]; then
        info "repo checkout already initialized: $ANDROID_SRC"
    else
        info "repo init $MANIFEST_URL -b $MANIFEST_BRANCH"
        "$repo" init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs --no-clone-bundle
    fi
    mark init
}

cmd_manifest() {
    local repo
    repo=$(repo_cmd) || die "repo launcher missing (run: ./scripts/build.sh deps)"
    require_synced
    cd "$ANDROID_SRC"

    mkdir -p .repo/local_manifests
    # Build the base view without our previous local manifest, otherwise repo
    # reports our own projects as remove-project candidates on re-runs.
    rm -f .repo/local_manifests/doha.xml
    "$repo" manifest -o "$STATE/base-manifest.xml"

    python3 "$KIT_ROOT/scripts/tools/gen_manifest.py" \
        "$STATE/base-manifest.xml" \
        "$MANIFEST_DIR/remotes.list" \
        "$MANIFEST_DIR/core.list" \
        "$MANIFEST_DIR/supporting.list" \
        "$MANIFEST_DIR/paths.txt" \
        .repo/local_manifests/doha.xml

    python3 - .repo/local_manifests/doha.xml <<'PY'
import sys, xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
print('local manifest parses: ' + sys.argv[1])
PY

    mark manifest
}

cmd_sync() {
    local repo attempt
    repo=$(repo_cmd) || die "repo launcher missing (run: ./scripts/build.sh deps)"
    require_synced
    cd "$ANDROID_SRC"

    for attempt in 1 2 3; do
        info "repo sync (attempt $attempt/3)"
        if "$repo" sync -c -j"$SYNC_JOBS" --no-tags --no-clone-bundle \
                --force-sync --force-checkout --retry-fetches=5; then
            # Record the exact SHAs this build resolved to. The base branch
            # is intentionally branch-tracked; this file is the full snapshot.
            "$repo" manifest -r -o "$STATE/resolved-manifest.xml" 2>/dev/null \
                || warn "could not write the resolved manifest snapshot"
            mark sync
            return 0
        fi
        warn "sync failed; retrying in 30 s"
        sleep 30
    done
    die "repo sync failed after 3 attempts"
}

patch_carrierconfig() {
    local project="packages/apps/CarrierConfig"
    local dir="$ANDROID_SRC/$project"
    local patch="$PATCHES/carrierconfig/bsnl-volte.patch"
    local asset='assets/carrier_config_carrierid_1549_Bharat-Sanchar-Nigam-Ltd-(BSNL).xml'

    [ -d "$dir" ] || die "CarrierConfig not synced"
    if grep -q 'carrier_volte_available_bool' "$dir/$asset" 2>/dev/null; then
        info "CarrierConfig: BSNL VoLTE keys already present"
        return 0
    fi
    if git -C "$dir" apply --3way --whitespace=nowarn "$patch" >>"$LOGS/patch.log" 2>&1; then
        info "CarrierConfig: BSNL VoLTE patch applied"
        return 0
    fi
    # Fallback for a moved/reformatted asset: insert the two booleans.
    python3 - "$dir/$asset" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if 'carrier_volte_available_bool' not in s:
    s = s.replace('<carrier_config>\n',
                  '<carrier_config>\n'
                  '    <boolean name="carrier_volte_available_bool" value="true" />\n'
                  '    <boolean name="editable_enhanced_4g_lte_bool" value="true" />\n', 1)
    p.write_text(s)
    print('CarrierConfig: inserted BSNL VoLTE keys')
PY
}

patch_gapps() {
    [ "$BUNDLE_GAPPS" = true ] || { info "GApps disabled"; return 0; }
    local mk="$ANDROID_SRC/vendor/gapps/arm64/arm64-vendor.mk"
    [ -f "$mk" ] || die "MindTheGapps not synced ($mk); check GAPPS_BRANCH=$GAPPS_BRANCH"

    # crDroid's LatinIME fork also defines libjni_latinimegoogle. Soong sees
    # every module definition in the tree, so removing it from PRODUCT_PACKAGES
    # is not enough: rename the GApps modules (both 32/64-bit files are parsed)
    # and drop them from the product lists. The keyboard keeps crDroid's module.
    local bp
    for bp in "$ANDROID_SRC/vendor/gapps/arm/Android.bp" \
              "$ANDROID_SRC/vendor/gapps/arm64/Android.bp"; do
        [ -f "$bp" ] || continue
        sed -i 's/name: "libjni_latinimegoogle"/name: "libjni_latinimegoogle_gapps"/' "$bp"
    done

    local makefile
    for makefile in "$ANDROID_SRC/vendor/gapps/arm/arm-vendor.mk" "$mk"; do
        [ -f "$makefile" ] || continue
        python3 - "$makefile" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
out = []
for line in lines:
    if line.strip() == 'libjni_latinimegoogle':
        if out and out[-1].rstrip().endswith('\\'):
            out[-1] = out[-1].rstrip()[:-1].rstrip()
        print(f'vendor_gapps: dropped libjni_latinimegoogle from {p.name}')
        continue
    out.append(line)
p.write_text('\n'.join(out) + '\n')
PY
    done
}

cmd_patch() {
    local patch rel project
    require_synced
    : > "$LOGS/patch.log"

    while IFS= read -r patch; do
        rel="${patch#"$PATCHES/a16/"}"
        project="${rel%.patch}"
        # Christiaan's manifest maps the legacy-um sepolicy project to
        # device/qcom/sepolicy_vndr/legacy-um; this repo maps it to
        # device/qcom/sepolicy_vndr (AOSPA tree). Same files, one level up.
        case "$project" in
            device/qcom/sepolicy_vndr/legacy-um)
                # Christiaan's manifest maps this to the AOSPA root, but this
                # port also syncs the real legacy-um project as a nested tree.
                [ -e "$ANDROID_SRC/device/qcom/sepolicy_vndr/legacy-um/.git" ] \
                    || project=device/qcom/sepolicy_vndr
                ;;
        esac
        apply_patch_to "$project" "$patch"
    done < <(find "$PATCHES/a16" -name '*.patch' | sort)

    patch_carrierconfig
    patch_gapps

    if [ -d "$ANDROID_SRC/vendor/apn" ]; then
        python3 "$KIT_ROOT/scripts/tools/fix_apn.py" "$ANDROID_SRC/vendor/apn" \
            || warn "APN injection skipped/failed (CarrierConfig fix is independent)"
    else
        warn "vendor/apn not synced; skipping APN database check"
    fi

    fix_build_tree
    mark patch
}

fix_build_tree() {
    local blocked="$ANDROID_SRC/system/qcom/softap/sdk/Android.mk"
    if [ -e "$blocked" ]; then
        rm -f "$blocked"
        info "removed A16-blocked legacy Android.mk: system/qcom/softap/sdk"
    fi

    local ipa_um="$ANDROID_SRC/vendor/qcom/opensource/data-ipa-cfg-mgr-legacy-um"
    if [ -d "$ipa_um" ]; then
        rm -rf "$ipa_um"
        info "removed duplicate IPA namespace: data-ipa-cfg-mgr-legacy-um"
    fi

    : > "$ANDROID_SRC/device/motorola/amogus_doha/kernel-headers"

    local sep="$ANDROID_SRC/device/qcom/sepolicy_vndr/SEPolicy.mk"
    local common="$ANDROID_SRC/hardware/qcom-caf/common/os_pickup_sepolicy_vndr.mk"
    if [ -f "$common" ] && [ -e "$sep" ] && [ ! -L "$sep" ]; then
        rm -f "$sep"
        ln -s ../../../hardware/qcom-caf/common/os_pickup_sepolicy_vndr.mk "$sep"
        info "linked device/qcom/sepolicy_vndr/SEPolicy.mk to common"
    fi
}

cmd_build() {
    require_synced
    cd "$ANDROID_SRC"
    [ -d "$VENDOR_DIR" ] || die "crDroid vendor not synced at $VENDOR_DIR"
    [ -f "device/motorola/targets/devices/$DEVICE/lineage_$DEVICE.mk" ] \
        || die "product file missing: device/motorola/targets/devices/$DEVICE/lineage_$DEVICE.mk"
    [ -f "device/motorola/$DEVICE/device.mk" ] || die "device tree missing: device/motorola/$DEVICE"

    if [ "$SIGNING" = release ] && [ ! -f vendor/lineage-priv/keys/keys.mk ]; then
        die "SIGNING=release but vendor/lineage-priv/keys/keys.mk is missing (see docs/PLAY_INTEGRITY.md)"
    fi

    # Kati must see TARGET_DEVICE/TARGET_PRODUCT while parsing the device
    # Android.mk files; otherwise conditional modules disappear and
    # PRODUCT_ENFORCE_PACKAGES_EXIST fails with a huge missing list.
    export TARGET_PRODUCT="lineage_${DEVICE}"
    export TARGET_DEVICE="$DEVICE"
    export ALLOW_MISSING_DEPENDENCIES=true

    mkdir -p "$CCACHE_DIR"
    if command -v ccache >/dev/null 2>&1; then
        export USE_CCACHE=1
        export CCACHE_EXEC
        CCACHE_EXEC=$(command -v ccache)
        "$CCACHE_EXEC" -M "$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
        info "ccache: $CCACHE_DIR ($CCACHE_MAXSIZE)"
    fi

    # envsetup.sh and lunch are not nounset-clean.
    set +u +o pipefail
    # shellcheck disable=SC1091
    . build/envsetup.sh

    if [ -f vendor/lineage/vars/aosp_target_release ]; then
        # shellcheck disable=SC1091
        . vendor/lineage/vars/aosp_target_release
        LUNCH_RELEASE="${aosp_target_release:-$LUNCH_RELEASE}"
    fi

    local target
    if [ -n "${LUNCH_RELEASE:-}" ]; then
        target="lineage_${DEVICE}-${LUNCH_RELEASE}-${BUILD_VARIANT}"
    else
        target="lineage_${DEVICE}-${BUILD_VARIANT}"
    fi
    info "lunch $target"
    lunch "$target" </dev/null || true
    set -u -o pipefail

    [ "${TARGET_PRODUCT:-}" = "lineage_${DEVICE}" ] \
        || die "lunch did not resolve $target (TARGET_PRODUCT=${TARGET_PRODUCT:-unset})"
    [ "${TARGET_BUILD_VARIANT:-}" = "$BUILD_VARIANT" ] \
        || die "unexpected build variant: ${TARGET_BUILD_VARIANT:-unset}"

    info "make bacon -j$JOBS"
    make bacon -j"$JOBS"
    mark build
}

cmd_verify() {
    [ -d "$OUT" ] || die "no build output at $OUT"
    python3 "$KIT_ROOT/scripts/tools/verify_build.py" "$OUT"
    mark verify
}

cmd_collect() {
    [ -d "$OUT" ] || die "no build output at $OUT"
    local zip
    zip=$(find "$OUT" -maxdepth 1 -name 'crDroidAndroid-*.zip' -print -quit)
    [ -n "$zip" ] || die "no crDroidAndroid-*.zip in $OUT"

    local id="v${ANDROID_VERSION}-$(date -u +%Y%m%d-%H%M)"
    local dest="$DIST_DIR/$id"
    mkdir -p "$dest"
    cp -f "$zip" "$dest/"
    for img in boot dtbo vbmeta; do
        [ -f "$OUT/$img.img" ] && cp -f "$OUT/$img.img" "$dest/"
    done
    ( cd "$dest" && sha256sum ./* > SHA256SUMS )

    {
        echo "rom: $ROM_NAME"
        echo "device: $DEVICE ($DEVICE_NAME)"
        echo "android: $ANDROID_VERSION"
        echo "branch: $MANIFEST_BRANCH"
        echo "build: $(date -u +%FT%TZ)"
        echo "gapps: $BUNDLE_GAPPS ($GAPPS_BRANCH)"
        echo "signing: $SIGNING"
        echo "kernel: $(git -C "$ANDROID_SRC/$KERNEL_SLOT" log -1 --format='%H %s' 2>/dev/null || echo unknown)"
        echo "device tree: $(git -C "$ANDROID_SRC/device/motorola/$DEVICE" log -1 --format='%H' 2>/dev/null || echo unknown)"
    } > "$dest/BUILD_INFO.txt"

    info "collected: $dest"
    mark collect
}

cmd_snapshot() {
    local repo
    repo=$(repo_cmd) || die "repo launcher missing (run: ./scripts/build.sh deps)"
    require_synced
    mkdir -p "$KIT_ROOT/manifests"
    local out="$KIT_ROOT/manifests/resolved-$(date -u +%Y%m%d-%H%M).xml"
    ( cd "$ANDROID_SRC" && "$repo" manifest -r -o "$out" )
    info "resolved manifest: $out"
    info "commit it if you need this exact build to be reproducible later"
}

cmd_status() {
    local s
    echo "ROM=$ROM ($ROM_NAME)  DEVICE=$DEVICE  VARIANT=$BUILD_VARIANT"
    echo "source=$ANDROID_SRC"
    echo "gapps=$BUNDLE_GAPPS ($GAPPS_BRANCH)  signing=$SIGNING"
    for s in deps init manifest sync patch build verify collect; do
        if is_marked "$s"; then echo "  [x] $s"; else echo "  [ ] $s"; fi
    done
    [ -d "$ANDROID_SRC" ] && du -sh "$ANDROID_SRC" 2>/dev/null || true
    [ -d "$DIST_DIR" ] && ls -1 "$DIST_DIR" 2>/dev/null | tail -5 || true
}

cmd_dryrun() {
    local fail=0
    info "config: ROM=$ROM DEVICE=$DEVICE variant=$BUILD_VARIANT"
    info "source: $ANDROID_SRC (free $(df -Pk "$KIT_ROOT" | awk 'NR==2 {print int($4/1024/1024)}') GB)"

    for f in config/build.env config/roms/$ROM.env config/device.env config/pins.env \
             manifest/remotes.list manifest/core.list manifest/supporting.list manifest/paths.txt; do
        [ -f "$KIT_ROOT/$f" ] || { warn "missing $f"; fail=1; }
    done

    while IFS= read -r f; do
        bash -n "$f" || fail=1
    done < <(find "$KIT_ROOT/scripts" -name '*.sh' -type f)
    python3 -m py_compile "$KIT_ROOT"/scripts/tools/*.py || fail=1

    local n
    n=$(find "$PATCHES/a16" -name '*.patch' | wc -l)
    info "A16 patches: $n"
    [ "$n" -ge 17 ] || { warn "expected 17 A16 patches"; fail=1; }
    [ -f "$PATCHES/carrierconfig/bsnl-volte.patch" ] || { warn "CarrierConfig patch missing"; fail=1; }

    if ! python3 - "$MANIFEST_DIR/core.list" "$MANIFEST_DIR/supporting.list" <<'PY'
import os, re, sys

HEX = re.compile(r'^[0-9a-f]{40}$')

def expand(v):
    return re.sub(r'@([A-Z0-9_]+)@', lambda m: os.environ.get(m.group(1), m.group(0)), v)

bad = []
for path in sys.argv[1:]:
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        f = [expand(x.strip()) for x in line.split('|')]
        pin = f[4] if len(f) > 4 else ''
        rev = f[3] if len(f) > 3 else ''
        if pin:
            if not HEX.match(pin):
                bad.append(f'{path}: {f[0]} pin is not a 40-hex SHA: {pin}')
        elif path.endswith('supporting.list'):
            bad.append(f'{path}: {f[0]} has no pin')
        elif path.endswith('core.list') and not rev.startswith('refs/tags/'):
            bad.append(f'{path}: {f[0]} has no pin (revision={rev})')
if bad:
    print('\n'.join(bad))
    raise SystemExit(1)
print('all manifest projects pinned (or tag-pinned)')
PY
    then
        warn "manifest pin check failed"
        fail=1
    fi

    # Generator smoke test against a synthetic base manifest.
    local tmp
    tmp=$(mktemp -d)
    cat > "$tmp/base.xml" <<'XML'
<manifest><project path="hardware/qcom/bootctrl" name="platform/hardware/qcom/bootctrl" /><project path="device/motorola/targets" name="old/targets" /></manifest>
XML
    python3 "$KIT_ROOT/scripts/tools/gen_manifest.py" \
        "$tmp/base.xml" "$MANIFEST_DIR/remotes.list" "$MANIFEST_DIR/core.list" \
        "$MANIFEST_DIR/supporting.list" "$MANIFEST_DIR/paths.txt" "$tmp/out.xml" >/dev/null \
        || { warn "manifest generator failed"; fail=1; }
    python3 - "$tmp/out.xml" <<'PY' || fail=1
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert r.tag == 'manifest'
assert len(r.findall('remove-project')) >= 2
assert any(p.get('path') == 'device/motorola/amogus_doha' for p in r.findall('project'))
print('manifest generator: ok')
PY
    rm -rf "$tmp"

    if command -v git >/dev/null 2>&1; then
        while IFS='|' read -r url branch; do
            [ -n "$url" ] || continue
            if [ -n "$(git ls-remote --heads "$url" "$branch" 2>/dev/null)" ]; then
                info "reachable: $url ($branch)"
            else
                warn "unreachable: $url ($branch)"
                fail=1
            fi
        done <<EOF
$MANIFEST_URL|$MANIFEST_BRANCH
https://github.com/Aldair402/android_device_motorola_amogus_doha|2.1
https://github.com/christiaan/android_kernel_motorola_msm-4.14|lts
https://github.com/Aldair402/android_vendor_motorola_amogus_doha|14
https://github.com/MindTheGapps/vendor_gapps|$GAPPS_BRANCH
EOF
    fi

    if [ "$fail" -ne 0 ]; then
        die "dryrun failed"
    fi
    info "dryrun passed"
}

cmd_all() {
    cmd_deps
    cmd_init
    cmd_manifest
    cmd_sync
    cmd_patch
    cmd_build
    cmd_verify
    cmd_collect
}

main() {
    local cmd="${1:-all}"
    case "$cmd" in
        dryrun)   cmd_dryrun ;;
        deps)     cmd_deps ;;
        init)     cmd_init ;;
        manifest) cmd_manifest ;;
        sync)     cmd_sync ;;
        patch)    cmd_patch ;;
        build)    cmd_build ;;
        verify)   cmd_verify ;;
        collect)  cmd_collect ;;
        snapshot) cmd_snapshot ;;
        status)   cmd_status ;;
        all)      cmd_all ;;
        -h|--help|help) usage ;;
        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
