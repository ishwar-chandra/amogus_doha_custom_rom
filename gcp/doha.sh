#!/usr/bin/env bash
# One-command GCP workflow for the doha Android 16 ROM.
#
#   ./gcp/doha.sh all                 # create -> build -> GitHub release -> Drive backup
#   ./gcp/doha.sh up                  # create the VM only
#   ./gcp/doha.sh build               # create/sync/provision/build, fetch dist/
#   ./gcp/doha.sh release             # publish dist-gcp/ to GitHub
#   ./gcp/doha.sh backup              # snapshot source/out/ccache/dist to Drive
#   ./gcp/doha.sh restore             # restore latest snapshot to a VM
#   ./gcp/doha.sh restore --local     # restore into this machine
#   ./gcp/doha.sh snapshots           # list Drive snapshots
#   ./gcp/doha.sh ssh | status | stop | start | down | logs
#
# Flags (env vars work too):
#   --project ID          --zone ZONE          --machine-type TYPE
#   --disk-size 600GB     --disk-type pd-standard
#   --spot                --repo OWNER/REPO    --tag TAG
#   --remote gdrive       --dir doha-a16       --snapshot NAME
#   --copy-rclone         --no-release         --no-backup
#   --local               --yes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_ENV="$ROOT/gcp/vm.env"

# ---------- defaults ----------
PROJECT="${PROJECT:-}"
VM_NAME="${VM_NAME:-doha-a16-builder}"
DISK_SIZE="${DISK_SIZE:-600GB}"
# 600 GB exceeds the 250 GB SSD_TOTAL_GB quota, and pd-balanced bills
# against SSD_TOTAL_GB (measured), so the boot disk must be pd-standard.
# Raise SSD_TOTAL_GB to >=600 to switch this back to pd-balanced.
DISK_TYPE="${DISK_TYPE:-pd-standard}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
NETWORK="${NETWORK:-default}"
SSH_SOURCE_RANGE="${SSH_SOURCE_RANGE:-0.0.0.0/0}"
SPOT="${SPOT:-0}"
# 12 vCPU only: the project's CPUS_ALL_REGIONS quota is 12. Custom types
# must resolve via machineTypes.get; this project exposes them only for
# n1/n2/e2, so c2d/t2d/c3 custom names 404. n2-custom-12 is therefore the
# only 12 vCPU option (Intel Ice Lake ~3.0-3.5 GHz); c2d-standard-8 (AMD
# Milan) and e2-custom-8 are fallbacks when n2 capacity is exhausted.
MACHINE_TYPES="${MACHINE_TYPES:-n2-custom-12-65536 c2d-standard-8 e2-custom-8-32768}"
FIND_TIMEOUT="${FIND_TIMEOUT:-180}"

GH_REPO="${GH_REPO:-ishwar-chandra/amogus_doha_custom_rom}"
TAG="${TAG:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
RCLONE_DIR="${RCLONE_DIR:-doha-a16}"
SNAPSHOT="${SNAPSHOT:-}"
COPY_RCLONE="${COPY_RCLONE:-0}"
DO_RELEASE="${DO_RELEASE:-1}"
DO_BACKUP="${DO_BACKUP:-1}"
LOCAL="${LOCAL:-0}"
KEEP_VM="${KEEP_VM:-0}"

# Cheapest approximate GCP regions first.
REGION_ORDER="us-central1 us-east1 us-west1 us-east4 us-south1 us-west2 us-west3 us-west4
northamerica-northeast1 northamerica-northeast2 southamerica-east1 southamerica-west1
europe-west1 europe-west2 europe-west3 europe-west4 europe-west6 europe-north1 europe-central2
asia-south1 asia-southeast1 asia-east1 asia-northeast1 asia-northeast2 asia-northeast3
australia-southeast1 australia-southeast2"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '  [warn] %s\n' "$*" >&2; }
die() { printf '[fail] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./gcp/doha.sh <command> [flags]

Commands:
  all        create VM -> build -> GitHub release -> Drive backup
  up         create the VM and SSH firewall rule
  build      up + sync kit + provision + build + fetch dist/
  release    publish dist-gcp/ to GitHub (needs gh + gh auth login)
  backup     snapshot work/android, work/ccache and dist/ to Drive
  restore    restore a snapshot to the VM (or --local to this machine)
  snapshots  list Drive snapshots
  rclone-setup  configure Google Drive from an `rclone authorize` token
  ssh        open a shell on the VM
  status     show VM status
  stop       stop the VM (disk still billed)
  start      start the VM
  down       delete the VM and its boot disk
  logs       fetch and show build.log

Flags:
  --project ID          GCP project (default: gcloud config)
  --zone ZONE           force a zone
  --machine-type TYPE   force a shape (default: fastest x86 12 vCPU first)
  --disk-size 600GB     boot disk size
  --disk-type TYPE      pd-standard (default), pd-balanced, pd-ssd
  --spot                spot VM (cheaper, can be preempted)
  --repo OWNER/REPO     GitHub release repo
  --tag TAG             release tag (default: a16-YYYYMMDD-HHMM)
  --remote NAME         rclone remote (default: gdrive)
  --dir NAME            Drive folder (default: doha-a16)
  --snapshot NAME       backup/restore snapshot name
  --copy-rclone         upload ~/.config/rclone/rclone.conf to the VM
  --no-release          skip GitHub release
  --no-backup           skip Drive backup
  --local               backup/restore on this machine, not the VM
  --keep-vm             do not delete the VM after the build (it keeps billing)
EOF
}

# ---------- flags ----------
COMMAND="${1:-help}"
[ $# -gt 0 ] && shift || true
case "$COMMAND" in -h|--help|help) usage; exit 0 ;; esac

while [ $# -gt 0 ]; do
    case "$1" in
        --project)        PROJECT="$2"; FLAG_PROJECT="$2"; shift 2 ;;
        --project=*)      PROJECT="${1#*=}"; FLAG_PROJECT="$PROJECT"; shift ;;
        --zone)           ZONE="$2"; FLAG_ZONE="$2"; shift 2 ;;
        --zone=*)         ZONE="${1#*=}"; FLAG_ZONE="$ZONE"; shift ;;
        --machine-type)   MACHINE_TYPE="$2"; FLAG_MACHINE_TYPE="$2"; shift 2 ;;
        --machine-type=*) MACHINE_TYPE="${1#*=}"; FLAG_MACHINE_TYPE="$MACHINE_TYPE"; shift ;;
        --disk-size)      DISK_SIZE="$2"; FLAG_DISK_SIZE="$2"; shift 2 ;;
        --disk-size=*)    DISK_SIZE="${1#*=}"; FLAG_DISK_SIZE="$DISK_SIZE"; shift ;;
        --disk-type)      DISK_TYPE="$2"; FLAG_DISK_TYPE="$2"; shift 2 ;;
        --disk-type=*)    DISK_TYPE="${1#*=}"; FLAG_DISK_TYPE="$DISK_TYPE"; shift ;;
        --spot)           SPOT=1; shift ;;
        --repo)           GH_REPO="$2"; shift 2 ;;
        --repo=*)         GH_REPO="${1#*=}"; shift ;;
        --tag)            TAG="$2"; shift 2 ;;
        --tag=*)          TAG="${1#*=}"; shift ;;
        --remote)         RCLONE_REMOTE="$2"; shift 2 ;;
        --remote=*)       RCLONE_REMOTE="${1#*=}"; shift ;;
        --dir)            RCLONE_DIR="$2"; shift 2 ;;
        --dir=*)          RCLONE_DIR="${1#*=}"; shift ;;
        --snapshot)       SNAPSHOT="$2"; shift 2 ;;
        --snapshot=*)     SNAPSHOT="${1#*=}"; shift ;;
        --copy-rclone)    COPY_RCLONE=1; shift ;;
        --no-release)     DO_RELEASE=0; shift ;;
        --no-backup)      DO_BACKUP=0; shift ;;
        --local)          LOCAL=1; shift ;;
        --keep-vm)        KEEP_VM=1; shift ;;
        --yes)            YES=1; shift ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

# gcp/vm.env remembers the last VM. It must not silently override an explicit
# CLI flag, so it only fills in values the user did not pass.
if [ -f "$VM_ENV" ]; then
    # shellcheck disable=SC1090
    . "$VM_ENV"
    [ -n "${FLAG_PROJECT:-}" ] && PROJECT="$FLAG_PROJECT"
    [ -n "${FLAG_ZONE:-}" ] && ZONE="$FLAG_ZONE"
    [ -n "${FLAG_MACHINE_TYPE:-}" ] && MACHINE_TYPE="$FLAG_MACHINE_TYPE"
    [ -n "${FLAG_DISK_SIZE:-}" ] && DISK_SIZE="$FLAG_DISK_SIZE"
    [ -n "${FLAG_DISK_TYPE:-}" ] && DISK_TYPE="$FLAG_DISK_TYPE"
fi

# ---------- shared helpers ----------
ensure_project() {
    command -v gcloud >/dev/null || die "gcloud not found"
    [ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
    [ -n "$PROJECT" ] || die "No project. Set --project or: gcloud config set project <id>"
    export PROJECT
}

on_gce() {
    curl -fsS --max-time 2         -H 'Metadata-Flavor: Google'         http://metadata.google.internal/computeMetadata/v1/instance/name         >/dev/null 2>&1
}

save_vm_env() {
    cat > "$VM_ENV" <<EOF
PROJECT=$PROJECT
ZONE=$ZONE
VM_NAME=$VM_NAME
MACHINE_TYPE=$MACHINE_TYPE
DISK_SIZE=$DISK_SIZE
DISK_TYPE=$DISK_TYPE
EOF
    chmod 600 "$VM_ENV"
}

remote_ssh() {
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet \
        --ssh-flag="-o ServerAliveInterval=30" --ssh-flag="-o ServerAliveCountMax=240" "$@"
}

remote_scp() {
    gcloud compute scp "$@" --zone="$ZONE" --project="$PROJECT" --quiet
}

remote_in_repo() {
    remote_ssh --command="cd \"\$HOME/amogus_doha_custom_rom\" && $1"
}

require_vm() {
    [ -n "${ZONE:-}" ] || die "no VM; run ./gcp/doha.sh up first"
}

# ---------- VM lifecycle ----------
find_zone() {
    # The machine-types list API is filtered by project quota and hides the
    # usable shapes, so do not enumerate: pick the fastest candidate and let
    # create_vm_with_fallback walk the rest when a zone is out of capacity.
    ZONE="${ZONE:-us-central1-a}"
    local mt
    for mt in $MACHINE_TYPES; do
        MACHINE_TYPE="$mt"
        break
    done
    MACHINE_TYPE="${MACHINE_TYPE:-n2-custom-12-65536}"
    log "selected $MACHINE_TYPE in $ZONE (fallback will try other shapes/zones on stockout)"
}

ensure_network() {
    gcloud compute networks describe "$NETWORK" --project="$PROJECT" >/dev/null 2>&1 \
        || die "VPC network '$NETWORK' not found (set NETWORK=...)"
}

ensure_firewall() {
    gcloud compute firewall-rules describe doha-allow-ssh --project="$PROJECT" >/dev/null 2>&1 && return 0
    log "creating firewall rule doha-allow-ssh"
    gcloud compute firewall-rules create doha-allow-ssh \
        --project="$PROJECT" --network="$NETWORK" --allow=tcp:22 \
        --source-ranges="$SSH_SOURCE_RANGE" --target-tags=doha-builder \
        --description="SSH for the doha Android 16 builder"
}

cmd_up() {
    ensure_project
    [ -n "${ZONE:-}" ] && [ -n "${MACHINE_TYPE:-}" ] || find_zone
    ensure_network

    if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1; then
        log "VM exists: $VM_NAME ($ZONE, $MACHINE_TYPE)"
    else
        ensure_firewall
        create_vm_with_fallback
    fi
    save_vm_env
}

# GCP zones run out of capacity for specific shapes. On a stockout, try the
# next shape and the next zone instead of failing the whole build.
create_vm_with_fallback() {
    local spot_args=()
    [ "$SPOT" = 1 ] && spot_args=(--spot)

    # Requested shape first, then the configured fallbacks (fastest first).
    # The 12 vCPU entries need CPUS_ALL_REGIONS; e2 is an 8 vCPU last resort
    # because its per-family quota is 8.
    local shapes="" s
    for s in $MACHINE_TYPE $MACHINE_TYPES; do
        case " $shapes " in
            *" $s "*) ;;
            *) shapes="$shapes $s" ;;
        esac
    done
    # Requested zone first, then zones that commonly have spare capacity.
    local zones="$ZONE us-central1-b us-central1-c us-central1-f us-east1-b us-east1-c us-west1-b"

    local shape zone attempt=0 first=1 fam rest cpus mem
    local mt_args=()
    for shape in $shapes; do
        # Custom types are not machine-type resources: the API rejects
        # --machine-type=t2d-custom-12-65536. Translate the FAMILY-custom-
        # VCPUS-MEMMB name into the custom flags instead.
        case "$shape" in
            *-custom-[0-9]*-[0-9]*)
                fam="${shape%%-custom-*}"
                rest="${shape#*-custom-}"
                cpus="${rest%%-*}"
                mem="${rest#*-}"
                mt_args=(--custom-cpu="$cpus" --custom-memory="${mem}MB" --custom-vm-type="$fam")
                ;;
            *)
                mt_args=(--machine-type="$shape")
                ;;
        esac
        for zone in $zones; do
            # The requested shape/zone combination is tried first.
            if [ "$first" = 1 ]; then
                [ "$shape" = "$MACHINE_TYPE" ] && [ "$zone" = "$ZONE" ] && first=0
            fi
            attempt=$((attempt + 1))
            log "creating $VM_NAME: $shape in $zone (attempt $attempt)"
            if gcloud compute instances create "$VM_NAME" \
                    --project="$PROJECT" --zone="$zone" \
                    "${mt_args[@]}" \
                    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
                    --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
                    --tags=doha-builder --labels=app=doha-a16 --quiet \
                    "${spot_args[@]}"; then
                ZONE="$zone"
                MACHINE_TYPE="$shape"
                log "created $VM_NAME: $MACHINE_TYPE in $ZONE"
                return 0
            fi
            warn "no capacity for $shape in $zone, trying the next combination"
            [ "$attempt" -ge 12 ] && break 2
        done
    done
    die "could not create a VM: no capacity for any shape/zone combination tried"
}

# ---------- transfer / remote setup ----------
sync_kit() {
    local tarball="${TMPDIR:-/tmp}/doha-kit.tgz"
    log "packing and uploading kit"
    tar -czf "$tarball" \
        --exclude='./work' --exclude='./dist' --exclude='./dist-gcp' \
        --exclude='./.git' --exclude='./gcp/vm.env' --exclude='*/__pycache__' \
        -C "$ROOT" .
    remote_scp "$tarball" "$VM_NAME:/tmp/doha-kit.tgz"
    remote_ssh --command='
set -e
mkdir -p "$HOME/amogus_doha_custom_rom"
tar -xzf /tmp/doha-kit.tgz -C "$HOME/amogus_doha_custom_rom"
'

    upload_rclone_config
}

upload_rclone_config() {
    [ "$COPY_RCLONE" = 1 ] || return 0
    local conf="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
    [ -f "$conf" ] || die "local rclone config not found: $conf"
    log "uploading rclone config (mode 600)"
    remote_scp "$conf" "$VM_NAME:/tmp/rclone.conf"
    remote_ssh --command='mkdir -p "$HOME/.config/rclone" && install -m 600 /tmp/rclone.conf "$HOME/.config/rclone/rclone.conf"'
}

ensure_remote_kit() {
    if ! remote_ssh --command='test -f "$HOME/amogus_doha_custom_rom/gcp/doha.sh"' >/dev/null 2>&1; then
        sync_kit
    fi
}

remote_provision() {
    log "provisioning VM"
    remote_in_repo 'bash ./gcp/doha.sh _provision'
}

preflight_rclone() {
    [ "$DO_BACKUP" = 1 ] || return 0
    local remotes
    remotes=$(remote_ssh --command='command -v rclone >/dev/null && rclone listremotes' 2>/dev/null) \
        || die "rclone is not installed on the VM"
    grep -qx "${RCLONE_REMOTE}:" <<< "$remotes" && { log "rclone '${RCLONE_REMOTE}:' ready"; return 0; }
    cat >&2 <<EOF
[fail] rclone remote '${RCLONE_REMOTE}:' is not configured on the VM.
  1) ./gcp/doha.sh ssh   -> rclone config
  2) ./gcp/doha.sh all --copy-rclone
  3) ./gcp/doha.sh all --no-backup
EOF
    exit 1
}

# ---------- build / release ----------
# The whole remote chain (provision -> rclone check -> build) runs detached
# in tmux. chain.status is the only completion signal, so a dropped SSH
# channel can neither kill the chain nor look like a build failure.
_chain() {
    cd "$ROOT"
    local rc=0
    bash ./gcp/doha.sh _provision || rc=$?
    if [ "$rc" -eq 0 ] && [ "${REQUIRE_RCLONE:-0}" = 1 ]; then
        if rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
            log "rclone remote '${RCLONE_REMOTE}:' ready"
        else
            warn "rclone remote '${RCLONE_REMOTE}:' is not configured"
            rc=1
        fi
    fi
    if [ "$rc" -eq 0 ]; then
        INSTALL_DEPS=1 JOBS="$(nproc)" SYNC_JOBS=8 ./scripts/build.sh all || rc=$?
    fi
    printf '%s\n' "$rc" > chain.status
}

# Start (or resume) the chain in tmux on the remote VM. Returns immediately;
# use wait_remote_chain for completion.
start_remote_chain() {
    local env=""
    [ "$DO_BACKUP" = 1 ] && env="REQUIRE_RCLONE=1 RCLONE_REMOTE=$(printf '%q' "$RCLONE_REMOTE") "
    if remote_ssh --command='tmux has-session -t doha 2>/dev/null' 2>/dev/null; then
        log "chain already running on the VM; resuming"
        return 0
    fi
    remote_ssh --command="cd \"\$HOME/amogus_doha_custom_rom\" && rm -f chain.status && tmux new-session -d -s doha \"${env}bash ./gcp/doha.sh _chain 2>&1 | tee build.log\"" \
        || die "could not start the remote chain"
    log "chain started in tmux session doha"
}

# Poll a short SSH command; a disconnected channel is retried, not fatal.
wait_remote_chain() {
    local state misses=0
    while :; do
        state="$(remote_ssh --command='d="$HOME/amogus_doha_custom_rom"; if [ -f "$d/chain.status" ]; then cat "$d/chain.status"; elif tmux has-session -t doha 2>/dev/null; then echo RUNNING; else echo GONE; fi' 2>/dev/null)" || state=""
        case "$state" in
            RUNNING|"") ;;
            GONE) warn "chain ended without writing chain.status"; return 1 ;;
            *) log "chain exit: $state"; return "$state" ;;
        esac
        sleep 20
        misses=$((misses + 1))
        if [ "$misses" -ge 30 ]; then
            gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1 \
                || { warn "VM disappeared while waiting for the chain"; return 1; }
            misses=0
        fi
    done
}

# Local variant used when this script runs on the VM itself.
build_on_vm() {
    cd "$ROOT"
    local require=0 rc
    [ "$DO_BACKUP" = 1 ] && require=1
    if tmux has-session -t doha 2>/dev/null; then
        log "chain already running; waiting"
    else
        rm -f chain.status
        tmux new-session -d -s doha "REQUIRE_RCLONE=$require RCLONE_REMOTE=$(printf '%q' "$RCLONE_REMOTE") bash ./gcp/doha.sh _chain 2>&1 | tee build.log"
    fi
    while tmux has-session -t doha 2>/dev/null; do sleep 20; done
    rc="$(cat chain.status 2>/dev/null || echo 1)"
    log "chain exit: $rc"
    return "$rc"
}

# One remote chain run from the local machine: start, wait, fetch.
run_remote_chain() {
    if remote_ssh --command='tmux has-session -t doha 2>/dev/null' 2>/dev/null; then
        log "chain already running on the VM; resuming"
    else
        sync_kit
        start_remote_chain
    fi
    if ! wait_remote_chain; then
        fetch_dist
        destroy_vm
        die "build failed; see $ROOT/dist-gcp-build.log"
    fi
    fetch_dist
}

fetch_dist() {
    log "fetching dist/ and build.log"
    rm -rf "$ROOT/dist-gcp"
    remote_scp "$VM_NAME:amogus_doha_custom_rom/build.log" "$ROOT/dist-gcp-build.log" 2>/dev/null || true
    remote_scp --recurse "$VM_NAME:amogus_doha_custom_rom/dist" "$ROOT/dist-gcp" 2>/dev/null || true
}

# Derive the release tag from the artifact itself, not from "now".
build_stamp() {
    local dist="$1" zip="$2" info ts
    info=$(find "$dist" -name BUILD_INFO.txt -print -quit)
    if [ -n "$info" ]; then
        ts=$(awk -F': ' '/^build:/{print $2; exit}' "$info")
        if [ -n "$ts" ] && date -u -d "$ts" +%Y%m%d-%H%M >/dev/null 2>&1; then
            date -u -d "$ts" +%Y%m%d-%H%M
            return 0
        fi
    fi
    date -u -d "@$(stat -c %Y "$zip")" +%Y%m%d-%H%M
}

cmd_release() {
    local dist="${DIST_DIR:-$ROOT/dist-gcp}"
    [ -d "$dist" ] || dist="$ROOT/dist"
    [ -d "$dist" ] || die "no dist directory (run build first)"
    local zip
    zip=$(find "$dist" -name 'crDroidAndroid-*.zip' -print -quit)
    [ -n "$zip" ] || die "no crDroidAndroid-*.zip in $dist"

    command -v gh >/dev/null || die "gh not installed (install GitHub CLI, then gh auth login)"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"

    local stamp tag
    stamp=$(build_stamp "$dist" "$zip")
    tag="${TAG:-a16-$stamp}"
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid tag: $tag"

    local assets=("$zip") f
    while IFS= read -r f; do assets+=("$f"); done < <(
        find "$dist" -maxdepth 2 \( -name boot.img -o -name dtbo.img -o -name vbmeta.img \
            -o -name SHA256SUMS -o -name BUILD_INFO.txt \) -print
    )

    local title="crDroid 12.13 amogus_doha ${tag}"
    local notes="Automated crDroid 12.13 (Android 16) build for the Motorola Moto G8 Plus. Buildkit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)."

    if gh release view "$tag" --repo "$GH_REPO" >/dev/null 2>&1; then
        log "release $tag exists; uploading with --clobber"
        gh release upload "$tag" "${assets[@]}" --repo "$GH_REPO" --clobber
    else
        log "creating release $tag on $GH_REPO"
        gh release create "$tag" "${assets[@]}" --repo "$GH_REPO" \
            --title "$title" --notes "$notes" --latest
    fi
}

# ---------- Drive backup / restore ----------
RCLONE_OPTS=(--transfers 8 --checkers 16 --drive-chunk-size 128M --stats-one-line --stats 30s)
rclone_copy() { rclone copy "$1" "$2" "${RCLONE_OPTS[@]}" "${@:3}"; }

check_rclone() {
    command -v rclone >/dev/null || die "rclone not installed"
    rclone listremotes | grep -qx "${RCLONE_REMOTE}:" \
        || die "rclone remote '${RCLONE_REMOTE}:' not configured"
}

backup_here() {
    cd "$ROOT"
    check_rclone
    local snap="${SNAPSHOT:-current}"
    [[ "$snap" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid snapshot name: $snap"
    local dst="${RCLONE_REMOTE}:${RCLONE_DIR}/${snap}"
    local mode=copy
    if [ "$snap" = current ]; then
        mode=sync
        log "incremental backup to $dst"
    else
        log "full snapshot to $dst"
    fi

    sync_dir() {
        local src="$1" dest="$2"
        shift 2
        if [ -d "$src" ]; then
            rclone "$mode" "$src" "$dst/$dest" "${RCLONE_OPTS[@]}" "$@" \
                || die "rclone $mode failed: $src"
        else
            warn "skip missing $src"
        fi
    }

    sync_dir "$ROOT/work/android" work/android
    sync_dir "$ROOT/work/ccache" work/ccache
    sync_dir "$ROOT/dist" dist
    sync_dir "$ROOT" kit \
        --exclude 'work/**' --exclude 'dist/**' \
        --exclude '.git/**' --exclude 'gcp/vm.env'

    {
        echo "snapshot: $snap"
        echo "mode: $mode"
        echo "created: $(date -u +%FT%TZ)"
        echo "host: $(hostname)"
        echo "kernel: $(uname -r)"
        echo "cpus: $(nproc)"
        free -h
        df -h /
        git -C "$ROOT" log -1 --format='buildkit %H %s' 2>/dev/null || true
        cat "$ROOT/dist-gcp/BUILD_INFO.txt" 2>/dev/null || true
    } > /tmp/SNAPSHOT_INFO.txt
    rclone copyto /tmp/SNAPSHOT_INFO.txt "$dst/SNAPSHOT_INFO.txt" "${RCLONE_OPTS[@]}"
    log "backup complete: $dst"
}

restore_here() {
    cd "$ROOT"
    check_rclone
    local snap="$SNAPSHOT"
    if [ -z "$snap" ]; then
        local dirs
        dirs=$(rclone lsf "${RCLONE_REMOTE}:${RCLONE_DIR}/" --dirs-only \
            | sed 's:/$::')
        if grep -qx current <<< "$dirs"; then
            snap=current
        else
            snap=$(sort -r <<< "$dirs" | head -1)
        fi
    fi
    [ -n "$snap" ] || die "no snapshot under ${RCLONE_REMOTE}:${RCLONE_DIR}/"
    local src="${RCLONE_REMOTE}:${RCLONE_DIR}/${snap}"
    log "restoring $src"

    mkdir -p "$ROOT/work"
    rclone_copy "$src/kit" "$ROOT"
    rclone_copy "$src/work/android" "$ROOT/work/android"
    rclone_copy "$src/work/ccache" "$ROOT/work/ccache"
    rclone_copy "$src/dist" "$ROOT/dist"
    chmod +x "$ROOT/scripts/build.sh" "$ROOT/gcp/doha.sh" 2>/dev/null || true
    log "restored $snap"
    "$ROOT/scripts/build.sh" status || true
}

# ---------- orchestration ----------
remote_backup() {
    local snap="$SNAPSHOT"
    [[ -z "$snap" || "$snap" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid snapshot name"
    remote_in_repo "SNAPSHOT='${snap}' bash ./gcp/doha.sh _backup"
}

remote_restore() {
    local snap="$SNAPSHOT"
    [[ -z "$snap" || "$snap" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid snapshot name"
    remote_in_repo "SNAPSHOT='${snap}' bash ./gcp/doha.sh _restore"
}

cmd_build() {
    if on_gce; then
        build_on_vm
        [ "$DO_BACKUP" = 1 ] && backup_here
        return
    fi
    cmd_up
    run_remote_chain
    [ "$DO_BACKUP" = 1 ] && remote_backup
    destroy_vm
}

cmd_backup() {
    if [ "$LOCAL" = 1 ] || on_gce; then backup_here; return; fi
    cmd_up
    ensure_remote_kit
    upload_rclone_config
    remote_provision
    preflight_rclone
    remote_backup
}

cmd_restore() {
    if [ "$LOCAL" = 1 ] || on_gce; then restore_here; return; fi
    cmd_up
    ensure_remote_kit
    upload_rclone_config
    remote_provision
    remote_restore
}

cmd_all() {
    cmd_up
    run_remote_chain

    local release_rc=0 backup_rc=0
    [ "$DO_RELEASE" = 1 ] && { cmd_release || release_rc=$?; }
    [ "$DO_BACKUP" = 1 ] && { remote_backup || backup_rc=$?; }

    [ "$release_rc" = 0 ] || log "release failed (rc=$release_rc)"
    [ "$backup_rc" = 0 ] || log "backup failed (rc=$backup_rc)"
    destroy_vm
    [ "$release_rc" = 0 ] && [ "$backup_rc" = 0 ]
}

# ---------- small commands ----------
prompt_rclone_token() {
    local token="${RCLONE_TOKEN:-}"
    if [ -z "$token" ]; then
        cat >&2 <<'EOF'
On a machine with a browser, run:
  rclone authorize "drive"

Then paste the JSON token it prints (starts with {"access_token"...):
EOF
        read -r -s token
        echo >&2
    fi
    [ -n "$token" ] || die "empty rclone token"
    python3 -c 'import json,sys; json.load(sys.stdin)' <<< "$token" \
        || die "token is not valid JSON"
    printf '%s' "$token"
}

rclone_setup_here() {
    command -v rclone >/dev/null || die "rclone not installed"
    local token
    token=$(prompt_rclone_token)
    rclone config delete gdrive >/dev/null 2>&1 || true
    rclone config create gdrive drive scope=drive token="$token" --non-interactive >/dev/null
    rclone listremotes
    rclone lsf "gdrive:" --max-depth 1 | head
}

cmd_rclone_setup() {
    if [ "$LOCAL" = 1 ] || on_gce; then
        rclone_setup_here
        return 0
    fi
    cmd_up
    if ! remote_ssh --command='command -v rclone >/dev/null' >/dev/null 2>&1; then
        ensure_remote_kit
        remote_provision
    fi
    local token tmp
    token=$(prompt_rclone_token)
    tmp=$(mktemp)
    chmod 600 "$tmp"
    printf '%s' "$token" > "$tmp"
    remote_scp "$tmp" "$VM_NAME:/tmp/rclone-token"
    rm -f "$tmp"
    remote_ssh --command='set -e; rclone config delete gdrive >/dev/null 2>&1 || true; T=$(cat /tmp/rclone-token); rclone config create gdrive drive scope=drive token="$T" --non-interactive >/dev/null; rm -f /tmp/rclone-token; rclone listremotes; rclone lsf "gdrive:" --max-depth 1 | head'
}

cmd_snapshots() {
    check_rclone
    rclone lsf "${RCLONE_REMOTE}:${RCLONE_DIR}/" --dirs-only | sed 's:/$::' | sort
}

cmd_ssh() {
    ensure_project
    require_vm
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
        --ssh-flag="-o ServerAliveInterval=30"
}

cmd_status() {
    ensure_project
    require_vm
    gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
        --format='table(name,status,machineType.basename(),zone.basename():label=ZONE,disks[0].diskSizeGb:label=DISK_GB)'
}

cmd_stop()  { ensure_project; require_vm; gcloud compute instances stop  "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet; }
cmd_start() { ensure_project; require_vm; gcloud compute instances start "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet; }

cmd_down() {
    ensure_project
    require_vm
    gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
        --delete-disks=boot --quiet
    rm -f "$VM_ENV"
}

# Delete the VM and its boot disk. A stopped VM still bills for its disk, so
# a builder that is no longer needed must be destroyed, not stopped.
destroy_vm() {
    [ "$KEEP_VM" = 1 ] && { log "keeping $VM_NAME (--keep-vm)"; return 0; }
    log "destroying $VM_NAME and its boot disk (a stopped VM still bills for disk)"
    gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
        --delete-disks=boot --quiet 2>/dev/null || true
    rm -f "$VM_ENV"
    log "VM destroyed; disk billing stopped"
}

cmd_logs() {
    ensure_project
    require_vm
    remote_scp "$VM_NAME:amogus_doha_custom_rom/build.log" "$ROOT/dist-gcp-build.log"
    tail -n 80 "$ROOT/dist-gcp-build.log"
}

# ---------- VM-internal commands ----------
install_rclone_latest() {
    log "installing latest rclone from rclone.org"
    if ! curl -fsSL https://rclone.org/install.sh | $SUDO bash; then
        warn "rclone.org installer failed; falling back to the distro package"
        $SUDO apt-get install -y rclone
    fi
    rclone version | head -2
}

# Ubuntu's archive hostname round-robins across backends and apt can latch
# onto a ~100 KB/s one, stalling provisioning for an hour. Benchmark the
# IPv4 backends once and pin the fastest in /etc/hosts; force IPv4 so apt
# does not stall on AAAA records. Idempotent: replaces any previous pin.
pin_fast_apt_mirror() {
    local sudo_cmd="" host suite ip speed best_ip="" best_speed=0
    [ "$(id -u)" -ne 0 ] && sudo_cmd=sudo

    host="$(awk '/^URIs:/{print $2; exit}' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null \
        | sed -e 's#^[a-z]*://##' -e 's#/.*$##')"
    [ -n "$host" ] || return 0
    suite="$(awk '/^Suites:/{print $2; exit}' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null)"
    [ -n "$suite" ] || suite=noble

    printf 'Acquire::ForceIPv4 "true";\n' | $sudo_cmd tee /etc/apt/apt.conf.d/99-doha >/dev/null

    for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
        speed="$(curl -o /dev/null -s -w '%{speed_download}' --max-time 5 \
            -H "Host: $host" "http://$ip/ubuntu/dists/$suite/main/binary-amd64/Packages.gz" 2>/dev/null || echo 0)"
        speed="${speed%.*}"
        if [ -n "$speed" ] && [ "$speed" -gt "$best_speed" ]; then
            best_speed="$speed"
            best_ip="$ip"
        fi
    done
    [ -n "$best_ip" ] || { warn "apt mirror: no reachable backend for $host"; return 0; }

    # Rewrite as root in one shell: fs.protected_regular=2 blocks root from
    # appending to a user-owned file in /tmp.
    $sudo_cmd bash -c '
        h="$1"; ip="$2"
        { awk -v h="$h" "\$2 != h" /etc/hosts; printf "%s %s\n" "$ip" "$h"; } > /etc/hosts.doha.new
        mv /etc/hosts.doha.new /etc/hosts
    ' _ "$host" "$best_ip"
    log "apt mirror: $host -> $best_ip (${best_speed} B/s)"
}

_provision() {
    if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi
    pin_fast_apt_mirror
    mapfile -t packages < <(grep -vE '^\s*(#|$)' "$ROOT/config/packages.list")
    $SUDO apt-get update
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${packages[@]}" tmux htop
    install_rclone_latest

    if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
        if [ ! -f /swapfile ]; then
            $SUDO fallocate -l 32G /swapfile 2>/dev/null \
                || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=32768 status=progress
            $SUDO chmod 600 /swapfile
            $SUDO mkswap /swapfile
        fi
        $SUDO swapon /swapfile
    fi
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab
    printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' | $SUDO tee /etc/sysctl.d/99-doha-build.conf >/dev/null
    $SUDO sysctl --system >/dev/null

    git config --global user.name "${GIT_NAME:-Ishwar-Chandra}"
    git config --global user.email "${GIT_EMAIL:-ishwarchandra.official@gmail.com}"
    git lfs install >/dev/null 2>&1 || true
    nproc; free -h; df -h /
}

_backup()  { backup_here; }
_restore() { restore_here; }

case "$COMMAND" in
    all)       cmd_all ;;
    up)        cmd_up ;;
    build)     cmd_build ;;
    release)   cmd_release ;;
    backup)    cmd_backup ;;
    restore)   cmd_restore ;;
    snapshots) cmd_snapshots ;;
    rclone-setup) cmd_rclone_setup ;;
    ssh)       cmd_ssh ;;
    status)    cmd_status ;;
    stop)      cmd_stop ;;
    start)     cmd_start ;;
    down)      cmd_down ;;
    logs)      cmd_logs ;;
    _chain)     _chain ;;
    _provision) _provision ;;
    _backup)    _backup ;;
    _restore)   _restore ;;
    *) usage; die "unknown command: $COMMAND" ;;
esac
