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
#   --disk-size 500GB     --disk-type pd-balanced
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
DISK_SIZE="${DISK_SIZE:-500GB}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
NETWORK="${NETWORK:-default}"
SSH_SOURCE_RANGE="${SSH_SOURCE_RANGE:-0.0.0.0/0}"
SPOT="${SPOT:-0}"
MACHINE_TYPES="${MACHINE_TYPES:-e2-standard-12 t2d-standard-12 n2d-standard-12 n2-standard-12 c2-standard-12}"
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

# Cheapest approximate GCP regions first.
REGION_ORDER="us-central1 us-east1 us-west1 us-east4 us-south1 us-west2 us-west3 us-west4
northamerica-northeast1 northamerica-northeast2 southamerica-east1 southamerica-west1
europe-west1 europe-west2 europe-west3 europe-west4 europe-west6 europe-north1 europe-central2
asia-south1 asia-southeast1 asia-east1 asia-northeast1 asia-northeast2 asia-northeast3
australia-southeast1 australia-southeast2"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
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
  ssh        open a shell on the VM
  status     show VM status
  stop       stop the VM (disk still billed)
  start      start the VM
  down       delete the VM and its boot disk
  logs       fetch and show build.log

Flags:
  --project ID          GCP project (default: gcloud config)
  --zone ZONE           force a zone
  --machine-type TYPE   force a shape (default: e2-standard-12 first)
  --disk-size 500GB     boot disk size
  --disk-type TYPE      pd-balanced (default), pd-standard, pd-ssd
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
EOF
}

# ---------- flags ----------
COMMAND="${1:-help}"
[ $# -gt 0 ] && shift || true
case "$COMMAND" in -h|--help|help) usage; exit 0 ;; esac

while [ $# -gt 0 ]; do
    case "$1" in
        --project)        PROJECT="$2"; shift 2 ;;
        --project=*)      PROJECT="${1#*=}"; shift ;;
        --zone)           ZONE="$2"; shift 2 ;;
        --zone=*)         ZONE="${1#*=}"; shift ;;
        --machine-type)   MACHINE_TYPE="$2"; shift 2 ;;
        --machine-type=*) MACHINE_TYPE="${1#*=}"; shift ;;
        --disk-size)      DISK_SIZE="$2"; shift 2 ;;
        --disk-size=*)    DISK_SIZE="${1#*=}"; shift ;;
        --disk-type)      DISK_TYPE="$2"; shift 2 ;;
        --disk-type=*)    DISK_TYPE="${1#*=}"; shift ;;
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
        --yes)            YES=1; shift ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

[ -f "$VM_ENV" ] && { . "$VM_ENV"; } || true

# ---------- shared helpers ----------
ensure_project() {
    command -v gcloud >/dev/null || die "gcloud not found"
    [ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
    [ -n "$PROJECT" ] || die "No project. Set --project or: gcloud config set project <id>"
    export PROJECT
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
    local list candidates best
    log "querying GCP for 12 vCPU shapes (timeout ${FIND_TIMEOUT}s)"
    if ! list=$(timeout "$FIND_TIMEOUT" gcloud compute machine-types list \
            --project="$PROJECT" --filter='guestCpus=12' \
            --format='value(zone.basename(),name)' --quiet 2>/dev/null); then
        die "machine-type query failed/timed out; use --zone/--machine-type"
    fi
    [ -n "$list" ] || die "no 12 vCPU machine types visible in $PROJECT"

    declare -A rank=()
    local i=0 r
    for r in $REGION_ORDER; do rank[$r]=$i; i=$((i + 1)); done

    candidates=$(
        while read -r zone name; do
            [ -n "$zone" ] || continue
            region="${zone%-*}"
            for mt in $MACHINE_TYPES; do
                [ "$name" = "$mt" ] && { printf '%s\t%s\t%s\n' "${rank[$region]:-999}" "$zone" "$name"; break; }
            done
        done <<< "$list" | sort -n -k1,1
    )
    best=$(printf '%s\n' "$candidates" | head -1)
    [ -n "$best" ] || {
        echo "No preferred 12/48 shape. Available 12 vCPU types:" >&2
        printf '%s\n' "$list" | awk '{print $2}' | sort -u | sed 's/^/  /' >&2
        die "set --machine-type/--zone"
    }
    IFS=$'\t' read -r _ ZONE MACHINE_TYPE <<< "$best"
    log "selected $MACHINE_TYPE in $ZONE"
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
        local spot_args=()
        [ "$SPOT" = 1 ] && spot_args=(--spot)
        log "creating $VM_NAME: $MACHINE_TYPE, $DISK_SIZE $DISK_TYPE, $IMAGE_FAMILY"
        gcloud compute instances create "$VM_NAME" \
            --project="$PROJECT" --zone="$ZONE" \
            --machine-type="$MACHINE_TYPE" \
            --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
            --boot-disk-size="$DISK_SIZE" --boot-disk-type="$DISK_TYPE" \
            --tags=doha-builder --labels=app=doha-a16 --quiet \
            "${spot_args[@]}"
    fi
    save_vm_env
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
rm -rf "$HOME/amogus_doha_custom_rom"
mkdir -p "$HOME/amogus_doha_custom_rom"
tar -xzf /tmp/doha-kit.tgz -C "$HOME/amogus_doha_custom_rom"
'

    if [ "$COPY_RCLONE" = 1 ]; then
        local conf="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"
        [ -f "$conf" ] || die "local rclone config not found: $conf"
        log "uploading rclone config (mode 600)"
        remote_scp "$conf" "$VM_NAME:/tmp/rclone.conf"
        remote_ssh --command='mkdir -p "$HOME/.config/rclone" && install -m 600 /tmp/rclone.conf "$HOME/.config/rclone/rclone.conf"'
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
build_on_vm() {
    cd "$ROOT"
    rm -f build.status
    if tmux has-session -t doha 2>/dev/null; then
        log "build already running; waiting"
    else
        tmux new-session -d -s doha "set -o pipefail; INSTALL_DEPS=1 JOBS=\$(nproc) ./scripts/build.sh all 2>&1 | tee build.log; echo \$? > build.status"
    fi
    while tmux has-session -t doha 2>/dev/null; do sleep 20; done
    local rc
    rc="$(cat build.status 2>/dev/null || echo 1)"
    log "build exit: $rc"
    return "$rc"
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
    local snap="${SNAPSHOT:-$(date -u +%Y%m%d-%H%M%S)}"
    [[ "$snap" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid snapshot name: $snap"
    local dst="${RCLONE_REMOTE}:${RCLONE_DIR}/${snap}"
    log "backing up to $dst"

    rclone_copy "$ROOT/work/android" "$dst/work/android"
    rclone_copy "$ROOT/work/ccache" "$dst/work/ccache"
    rclone_copy "$ROOT/dist" "$dst/dist"
    rclone_copy "$ROOT" "$dst/kit" \
        --exclude 'work/**' --exclude 'dist/**' --exclude '.git/**' --exclude 'gcp/vm.env'

    {
        echo "snapshot: $snap"
        echo "created: $(date -u +%FT%TZ)"
        echo "host: $(hostname)"
        echo "kernel: $(uname -r)"
        echo "cpus: $(nproc)"
        free -h
        df -h /
        git -C "$ROOT" log -1 --format='buildkit %H %s' 2>/dev/null || true
        cat "$ROOT/dist-gcp/BUILD_INFO.txt" 2>/dev/null || true
    } > /tmp/SNAPSHOT_INFO.txt
    rclone copyto /tmp/SNAPSHOT_INFO.txt "$dst/SNAPSHOT_INFO.txt"
    log "backup complete: $dst"
}

restore_here() {
    cd "$ROOT"
    check_rclone
    local snap="$SNAPSHOT"
    if [ -z "$snap" ]; then
        snap=$(rclone lsf "${RCLONE_REMOTE}:${RCLONE_DIR}/" --dirs-only \
            | sed 's:/$::' | sort | tail -1)
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
    cmd_up
    sync_kit
    remote_provision
    preflight_rclone
    if ! remote_in_repo 'bash ./gcp/doha.sh _build'; then
        fetch_dist
        die "build failed; see $ROOT/dist-gcp-build.log"
    fi
    fetch_dist
}

cmd_backup() {
    if [ "$LOCAL" = 1 ]; then backup_here; return; fi
    cmd_up
    sync_kit
    remote_provision
    preflight_rclone
    remote_backup
}

cmd_restore() {
    if [ "$LOCAL" = 1 ]; then restore_here; return; fi
    cmd_up
    sync_kit
    remote_provision
    remote_restore
}

cmd_all() {
    cmd_up
    sync_kit
    remote_provision
    preflight_rclone
    if ! remote_in_repo 'bash ./gcp/doha.sh _build'; then
        fetch_dist
        die "build failed; see $ROOT/dist-gcp-build.log"
    fi
    fetch_dist

    local release_rc=0 backup_rc=0
    [ "$DO_RELEASE" = 1 ] && { cmd_release || release_rc=$?; }
    [ "$DO_BACKUP" = 1 ] && { remote_backup || backup_rc=$?; }

    [ "$release_rc" = 0 ] || log "release failed (rc=$release_rc)"
    [ "$backup_rc" = 0 ] || log "backup failed (rc=$backup_rc)"
    [ "$release_rc" = 0 ] && [ "$backup_rc" = 0 ]
}

# ---------- small commands ----------
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

cmd_logs() {
    ensure_project
    require_vm
    remote_scp "$VM_NAME:amogus_doha_custom_rom/build.log" "$ROOT/dist-gcp-build.log"
    tail -n 80 "$ROOT/dist-gcp-build.log"
}

# ---------- VM-internal commands ----------
_provision() {
    if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi
    mapfile -t packages < <(grep -vE '^\s*(#|$)' "$ROOT/config/packages.list")
    $SUDO apt-get update
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${packages[@]}" tmux htop rclone

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

_build()   { build_on_vm; }
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
    ssh)       cmd_ssh ;;
    status)    cmd_status ;;
    stop)      cmd_stop ;;
    start)     cmd_start ;;
    down)      cmd_down ;;
    logs)      cmd_logs ;;
    _provision) _provision ;;
    _build)     _build ;;
    _backup)    _backup ;;
    _restore)   _restore ;;
    *) usage; die "unknown command: $COMMAND" ;;
esac
