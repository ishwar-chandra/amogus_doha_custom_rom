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
    # An explicit ROM=... env wins; otherwise use config/build.env.
    local rom_override="${ROM:-}"

    [ -f "$KIT_ROOT/config/build.env" ] || die "missing config/build.env"
    set -a
    # shellcheck disable=SC1091
    . "$KIT_ROOT/config/build.env"
    [ -n "$rom_override" ] && ROM="$rom_override"
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
    : "${SYNC_JOBS:=4}"
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

    [ -d "$dir" ] || die "project not synced: $project (needed for $patch)"
    [ -f "$patch" ] || die "patch not found: $patch"

    # Already applied? A reverse dry-run succeeds only if the patch is present.
    if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
        info "already applied: $project"
        return 0
    fi

    # Check first so a failed patch cannot leave conflict markers behind.
    if git -C "$dir" apply --check "$patch" >>"$LOGS/patch.log" 2>&1; then
        git -C "$dir" apply --whitespace=nowarn "$patch"
        info "applied: $project"
        return 0
    fi

    # Fall back to 3-way only for genuine context drift. On failure, restore
    # tracked files so the next attempt starts clean.
    if git -C "$dir" apply --3way --whitespace=nowarn "$patch" >>"$LOGS/patch.log" 2>&1; then
        info "applied (3-way): $project"
        return 0
    fi
    git -C "$dir" checkout -- . >/dev/null 2>&1 || true
    warn "patch failed: $project"
    warn "see $LOGS/patch.log"
    die "stopping before the build (a partially patched tree is worse than no build)"
}

require_synced() {
    [ -d "$ANDROID_SRC/.repo" ] || die "no repo checkout at $ANDROID_SRC (run: ./scripts/build.sh init && ./scripts/build.sh sync)"
}
