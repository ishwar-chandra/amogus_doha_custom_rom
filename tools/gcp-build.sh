#!/usr/bin/env bash
# Build amogus_doha on a Google Cloud VM, with the expensive parts backed
# up to Google Drive so a fresh VM never has to re-sync.
#
#   tools/gcp-build.sh create     create the instance (auto-deletes after HOURS)
#   tools/gcp-build.sh config     copy your local rclone.conf to the VM
#   tools/gcp-build.sh setup      install build deps in the VM, clone the recipe
#   tools/gcp-build.sh build      start ./build.sh in the VM (background)
#   tools/gcp-build.sh logs       follow the build log
#   tools/gcp-build.sh backup     mirror .repo, ccache, zips to Drive
#   tools/gcp-build.sh restore    pull them back into a fresh VM
#   tools/gcp-build.sh check      compare local .repo/ccache against Drive
#   tools/gcp-build.sh fetch      copy the finished zip and images here
#   tools/gcp-build.sh ssh        open a shell in the VM
#   tools/gcp-build.sh delete     tear the instance down now
#
# What is backed up, and why only that:
#
#   src/.repo  the bare git objects for all ~1280 projects. Immutable once
#              fetched, so rclone only uploads what is new. Restoring it and
#              letting `repo sync` re-create the worktrees means no download
#              and no broken file modes or symlinks -- Google Drive has
#              neither, so copying the checked-out tree (400 GB, mostly
#              regenerable) would restore into something that cannot build.
#   ccache     content-addressed, so also immutable and incremental. A warm
#              ccache turns a rebuild into minutes instead of hours.
#   manifest   this recipe clone, a few MB.
#   zips       the finished builds, so they survive the VM.
#
# out/ is deliberately not backed up: ~120 GB of regenerable intermediates.
#
# backup mirrors with `rclone sync`, so a file deleted locally is deleted on
# Drive too. That is what keeps .repo from accumulating stale packs. Watch
# the two Google limits when planning: Drive accepts ~750 GB of uploads per
# account per day, and egress from GCP is billed (~180 GB out of asia-south1
# is a few dollars), so the first backup is the expensive one.
#
# First run: `rclone config` on your own machine (new remote, type drive,
# name it gdrive), then `tools/gcp-build.sh config` copies it to the VM.
#
# Environment (all optional):
#   PROJECT   GCP project          (default: customrom-514215)
#   ZONE      zone                 (default: asia-south1-a, closest to India)
#   NAME      instance name        (default: crdroid-build)
#   MACHINE   machine type         (default: n2-custom-12-98304, 12 vCPU/96 GB;
#                                   raise once the CPUS_ALL_REGIONS quota lands)
#   DISK      boot disk size       (default: 500GB, holds the sources)
#   HOURS     auto-delete after    (default: 8)
#   REPO      recipe repo          (default: this fork)
#   BRANCH    branch to build      (default: crdroid-android-17)
#   OUT       where fetch puts it  (default: ./gcp-out)
#   RCLONE_REMOTE / RCLONE_PATH    (default: gdrive / amogus-doha)
set -euo pipefail

PROJECT=${PROJECT:-customrom-514215}
ZONE=${ZONE:-asia-south1-a}
NAME=${NAME:-crdroid-build}
MACHINE=${MACHINE:-n2-custom-12-98304}
DISK=${DISK:-500GB}
HOURS=${HOURS:-8}
REPO=${REPO:-https://github.com/ishwar-chandra/amogus_doha_custom_rom.git}
BRANCH=${BRANCH:-crdroid-android-17}
OUT=${OUT:-$PWD/gcp-out}
SSD=/mnt/ssd
RCLONE_REMOTE=${RCLONE_REMOTE:-gdrive}
RCLONE_PATH=${RCLONE_PATH:-amogus-doha}
CCACHE_MAX=${CCACHE_MAX:-50G}

gcloud_() { gcloud --project "$PROJECT" --zone "$ZONE" "$@"; }

# Run a mode-specific script inside the VM. $1 is the mode; the rest of
# the arguments are passed through.
remote_exec() {
  gcloud_ compute ssh "$NAME" --command \
    "bash -s -- '$1' '$REPO' '$BRANCH' '$SSD' '$RCLONE_REMOTE' '$RCLONE_PATH' '$CCACHE_MAX'" \
    <<'REMOTE'
set -euo pipefail
MODE=$1 REPO=$2 BRANCH=$3 SSD=$4 RCLONE_REMOTE=$5 RCLONE_PATH=$6 CCACHE_MAX=$7
LOG=$SSD/build.log RLOG=$SSD/rclone.log

# The local SSD arrives unformatted, and its contents do not survive a
# stop/start, so everything below recreates what it needs.
if ! mountpoint -q "$SSD"; then
  DEV=${SSD_DEV:-/dev/nvme0n1}
  sudo mkfs.ext4 -F -m 0 "$DEV"
  sudo mkdir -p "$SSD"
  sudo mount "$DEV" "$SSD"
  sudo chown "$(id -u):$(id -g)" "$SSD"
fi

# Swap on the fast disk, in case Soong's analysis overshoots RAM.
if [ ! -e "$SSD/swap" ]; then
  fallocate -l 48G "$SSD/swap" || dd if=/dev/zero of="$SSD/swap" bs=1M count=49152 status=none
  chmod 600 "$SSD/swap"
  sudo mkswap "$SSD/swap" >/dev/null
fi
sudo swapon "$SSD/swap" 2>/dev/null || true

# rclone only when we are actually going to use it.
need_rclone() {
  command -v rclone >/dev/null && return
  curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null
}
# Flags shared by every rclone call: Drive is slow per small file, so use
# many parallel transfers and big chunks; --fast-list saves listing round
# trips; the log is on the SSD and stays out of the build log.
rclone_() {
  rclone --fast-list --transfers 16 --checkers 32 --drive-chunk-size 128M \
         --stats 60s --stats-one-line --log-file "$RLOG" "$@"
}
# Sample hooks are ~15 files per project and are never used.
EXCLUDES=(--exclude "/**/hooks/*.sample")

case "$MODE" in

setup)
  if [ ! -x "$HOME/.deps-installed" ]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
      git-lfs gnupg gperf imagemagick lib32ncurses-dev lib32z1-dev libelf-dev \
      liblz4-tool libssl-dev libxml2 libxml2-utils lzop rsync schedtool \
      squashfs-tools xsltproc zip zlib1g-dev openjdk-21-jdk-headless python3
    touch "$HOME/.deps-installed"
  fi

  if ! command -v repo >/dev/null; then
    mkdir -p "$HOME/bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
    chmod +x "$HOME/bin/repo"
    export PATH="$HOME/bin:$PATH"
    grep -q 'HOME/bin' "$HOME/.profile" || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
  fi

  mkdir -p "$SSD/src" "$SSD/zips" "$SSD/ccache"
  if [ ! -d "$SSD/manifest/.git" ]; then
    git clone -b "$BRANCH" "$REPO" "$SSD/manifest"
  fi
  echo "setup done"
  ;;

config)
  echo "rclone.conf comes from your own machine; run 'rclone config' there"
  echo "once (new remote, type drive, named gdrive) and rerun this."
  ;;

build)
  cd "$SSD/manifest"
  nohup env PATH="$HOME/bin:$PATH" \
        CCACHE_DIR="$SSD/ccache" ZIP_DIR="$SSD/zips" JOBS="$(nproc)" \
        ./build.sh "$SSD/src" >"$LOG" 2>&1 &
  echo "build started, log: $LOG"
  ;;

backup)
  need_rclone
  rclone_ sync "$SSD/src/.repo" "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo" "${EXCLUDES[@]}"
  rclone_ sync "$SSD/ccache"    "$RCLONE_REMOTE:$RCLONE_PATH/ccache" "${EXCLUDES[@]}"
  rclone_ sync "$SSD/zips"      "$RCLONE_REMOTE:$RCLONE_PATH/zips"
  rclone_ sync "$SSD/manifest"  "$RCLONE_REMOTE:$RCLONE_PATH/manifest"
  du -sh "$SSD/src/.repo" "$SSD/ccache" "$SSD/zips"
  echo "backup done (log: $RLOG)"
  ;;

restore)
  need_rclone
  mkdir -p "$SSD/src" "$SSD/zips" "$SSD/ccache"
  rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo" "$SSD/src/.repo" "${EXCLUDES[@]}"
  rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/ccache"    "$SSD/ccache" "${EXCLUDES[@]}"
  rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/zips"      "$SSD/zips"
  [ -d "$SSD/manifest/.git" ] || \
    rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/manifest" "$SSD/manifest"
  echo "restored: $(du -sh "$SSD/src/.repo" | cut -f1) of .repo. Now: build"
  echo "(build.sh runs repo init/sync itself, which re-creates the worktrees"
  echo " from these local objects, so there is nothing to download)"
  ;;

check)
  need_rclone
  rclone_ check --size-only "$SSD/src/.repo" "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo"
  rclone_ check --size-only "$SSD/ccache"    "$RCLONE_REMOTE:$RCLONE_PATH/ccache"
  ;;

*)
  echo "unknown mode: $MODE" >&2
  exit 1
  ;;
esac
REMOTE
}

case "${1:-}" in
create)
  gcloud compute instances create "$NAME" \
    --machine-type "$MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --boot-disk-size "$DISK" --boot-disk-type pd-balanced \
    --local-ssd interface=nvme,size=375gb \
    --max-run-duration="$((HOURS * 3600))s" --instance-termination-action=DELETE \
    --scopes cloud-platform
  echo
  echo "Created $NAME ($MACHINE, auto-delete in ${HOURS}h). Next: config, setup, build"
  ;;

config)
  CONF=${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}
  [ -f "$CONF" ] || { echo "No $CONF. Run 'rclone config' here first (new remote, type drive, name gdrive)." >&2; exit 1; }
  gcloud_ compute scp "$CONF" "$NAME:/tmp/rclone.conf"
  gcloud_ compute ssh "$NAME" --command 'mkdir -p ~/.config/rclone && mv /tmp/rclone.conf ~/.config/rclone/rclone.conf && chmod 600 ~/.config/rclone/rclone.conf && command -v rclone >/dev/null || (curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null); rclone lsd gdrive: | head'
  ;;

setup|build|backup|restore|check)
  remote_exec "$1"
  ;;

logs)
  gcloud_ compute ssh "$NAME" --command 'tail -f /mnt/ssd/build.log'
  ;;

ssh)
  gcloud_ compute ssh "$NAME"
  ;;

fetch)
  mkdir -p "$OUT"
  gcloud_ compute scp --recurse "$NAME:/mnt/ssd/zips/*" "$OUT/"
  echo "fetched into $OUT"
  ;;

delete)
  gcloud compute instances delete "$NAME" --project "$PROJECT" --zone "$ZONE" --quiet
  ;;

*)
  sed -n '2,60p' "$0"
  exit 1
  ;;
esac
