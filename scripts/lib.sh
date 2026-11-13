#!/usr/bin/env bash
# Shared helpers for the doha buildkit. Sourced by build.sh and its tools.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_ROOT

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
info() { printf '  %s\n' "$*" >&2; }
warn() { printf '  [warn] %s\n' "$*" >&2; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }

load_config() {
    # Explicit env overrides win over config/build.env. ROM selects the ROM
    # definition; the job knobs are set by the cloud wrapper.
    local rom_override="${ROM:-}"
    local jobs_override="${JOBS:-}"
    local sync_jobs_override="${SYNC_JOBS:-}"
    local install_deps_override="${INSTALL_DEPS:-}"

    [ -f "$KIT_ROOT/config/build.env" ] || die "missing config/build.env"
    set -a
    # shellcheck disable=SC1091
    . "$KIT_ROOT/config/build.env"
    [ -n "$rom_override" ] && ROM="$rom_override"
    [ -n "$jobs_override" ] && JOBS="$jobs_override"
    [ -n "$sync_jobs_override" ] && SYNC_JOBS="$sync_jobs_override"
    [ -n "$install_deps_override" ] && INSTALL_DEPS="$install_deps_override"
    [ -f "$KIT_ROOT/config/roms/$ROM.env" ] || die "unknown ROM '$ROM' (no config/roms/$ROM.env)"
    # shellcheck disable=SC1091
    . "$KIT_ROOT/config/roms/$ROM.env"
    # shellcheck disable=SC1091
    . "$KIT_ROOT/config/device.env"
    # shellcheck disable=SC1091
    . "$KIT_ROOT/config/pins.env"
    set +a

    : "${ANDROID_SRC:=$KIT_ROOT/work/android}"
    : "${DIST_DIR:=$KIT_ROOT/dist}"
    : "${JOBS:=$(nproc)}"
    : "${SYNC_JOBS:=$(nproc)}"
    : "${BUILD_VARIANT:=userdebug}"
    : "${BUNDLE_GAPPS:=true}"
    : "${GAPPS_BRANCH:=baklava}"
    : "${SIGNING:=test}"
    : "${CCACHE_MAXSIZE:=50G}"

    WORK="$KIT_ROOT/work"
    STATE="$WORK/state"
    LOGS="$WORK/logs"
    : "${CCACHE_DIR:=$WORK/ccache}"
    PATCHES="$KIT_ROOT/patches"
    MANIFEST_DIR="$KIT_ROOT/manifest"
    OUT="$ANDROID_SRC/out/target/product/$DEVICE"

    export KIT_ROOT ROM DEVICE ANDROID_SRC DIST_DIR WORK STATE LOGS CCACHE_DIR
    export JOBS SYNC_JOBS BUILD_VARIANT BUNDLE_GAPPS GAPPS_BRANCH SIGNING
    export PATCHES MANIFEST_DIR OUT

    mkdir -p "$WORK" "$STATE" "$LOGS" "$DIST_DIR"
}

repo_cmd() {
    if [ -x "$WORK/bin/repo" ]; then
        printf '%s\n' "$WORK/bin/repo"
    elif command -v repo >/dev/null 2>&1; then
        command -v repo
    else
        return 1
    fi
}

mark()      { : > "$STATE/$1.done"; }
is_marked() { [ -f "$STATE/$1.done" ]; }
clear_mark(){ rm -f "$STATE/$1.done"; }

apply_patch_to() {
    local project="$1" patch="$2"
    local dir="$ANDROID_SRC/$project"
    local rendered

    [ -d "$dir" ] || die "project not synced: $project (needed for $patch)"
    [ -f "$patch" ] || die "patch not found: $patch"

    # Patches may carry @NAME@ placeholders for build settings (the thermal
    # HAL patch uses @SKIN_THROTTLE_MC@). Render them before applying, or the
    # literal token reaches the compiler and breaks the build at 90%.
    rendered="$LOGS/rendered-$(basename "$patch")"
    render_patch "$patch" > "$rendered"

    # Already applied? A reverse dry-run succeeds only if the patch is present.
    if git -C "$dir" apply --reverse --check "$rendered" >/dev/null 2>&1; then
        info "already applied: $project"
        return 0
    fi

    # Check first so a failed patch cannot leave conflict markers behind.
    if git -C "$dir" apply --check "$rendered" >>"$LOGS/patch.log" 2>&1; then
        git -C "$dir" apply --whitespace=nowarn "$rendered"
        info "applied: $project"
        return 0
    fi

    # Fall back to 3-way only for genuine context drift. On failure, restore
    # tracked files so the next attempt starts clean.
    if git -C "$dir" apply --3way --whitespace=nowarn "$rendered" >>"$LOGS/patch.log" 2>&1; then
        info "applied (3-way): $project"
        return 0
    fi
    git -C "$dir" checkout -- . >/dev/null 2>&1 || true
    warn "patch failed: $project"
    warn "see $LOGS/patch.log"
    die "stopping before the build (a partially patched tree is worse than no build)"
}

# Substitute @NAME@ placeholders in a patch with values from the config.
# Unknown placeholders are an error: a literal @TOKEN@ in a patch is always a
# bug, never a valid source line.
render_patch() {
    local patch="$1" tmp out
    tmp="$(mktemp)"
    out="$(mktemp)"

    sed "s/@SKIN_THROTTLE_MC@/$((SKIN_THROTTLE_C * 1000))/g" "$patch" > "$tmp"

    if grep -qE '@[A-Z][A-Z0-9_]*@' "$tmp"; then
        local leftover
        leftover="$(grep -oE '@[A-Z][A-Z0-9_]*@' "$tmp" | sort -u | tr '\n' ' ')"
        rm -f "$tmp" "$out"
        die "unrendered placeholder(s) in $(basename "$patch"): $leftover"
    fi

    cat "$tmp"
    rm -f "$tmp" "$out"
}

# Guard: after patching, no file in the tree may contain a @NAME@ placeholder
# that came from a patch. Catches the class of bug that breaks a build at 90%.
assert_no_placeholders() {
    local hits
    hits="$(grep -rlE '@[A-Z][A-Z0-9_]{3,}@' "$ANDROID_SRC/vendor/qcom" "$ANDROID_SRC/device/motorola" \
        --include='*.cpp' --include='*.h' --include='*.bp' --include='*.mk' --include='*.rc' \
        2>/dev/null | head -10 || true)"
    [ -z "$hits" ] && return 0
    warn "unrendered @PLACEHOLDER@ found in patched files:"
    printf '  %s\n' $hits >&2
    die "refusing to build: a patch placeholder was not substituted"
}

require_synced() {
    [ -d "$ANDROID_SRC/.repo" ] || die "no repo checkout at $ANDROID_SRC (run: ./scripts/build.sh init && ./scripts/build.sh sync)"
}
