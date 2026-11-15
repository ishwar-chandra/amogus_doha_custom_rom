#!/usr/bin/env bash
# Provision a Google Cloud VM for the amogus_doha build and run build.sh in
# it. See TODO.md; the README describes what build.sh does.
#
#   tools/gcp-build.sh create    create the instance (auto-deletes after HOURS)
#   tools/gcp-build.sh run       clone this repo in the VM and start building
#   tools/gcp-build.sh ssh       open a shell in the VM
#   tools/gcp-build.sh logs      follow the build log
#   tools/gcp-build.sh fetch     copy the finished zip and images back here
#   tools/gcp-build.sh delete    tear the instance down now
#
# Environment (all optional):
#   PROJECT   GCP project          (default: customrom-514215)
#   ZONE      zone                 (default: asia-south1-a, closest to India)
#   NAME      instance name        (default: crdroid-build)
#   MACHINE   machine type         (default: n2-custom-12-98304, i.e. 12 vCPU
#                                   and 96 GB; raise once the CPUS quota lands)
#   DISK      boot disk size       (default: 500GB, holds the sources)
#   HOURS     auto-delete after    (default: 8)
#   REPO      recipe repo to clone (default: this fork)
#   BRANCH    branch to build      (default: crdroid-android-17)
#   OUT       where fetch puts the build (default: ./gcp-out)
#
# The local SSD (375 GB) is mounted at /mnt/ssd and holds the source tree,
# out/ and ccache: it is fast, and it is wiped when the instance stops, so
# everything worth keeping is copied to the boot disk (or fetched) before
# you delete it. Building as root fails by design, so the work happens as
# the image's default user.
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

gcloud_() { gcloud --project "$PROJECT" --zone "$ZONE" "$@"; }

case "${1:-}" in
create)
  gcloud compute instances create "$NAME" \
    --machine-type "$MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --boot-disk-size "$DISK" --boot-disk-type pd-balanced \
    --local-ssd interface=nvme,size=375gb \
    --max-run-duration="${HOURS}h" --instance-termination-action=DELETE \
    --scopes cloud-platform
  echo
  echo "Created $NAME ($MACHINE, auto-delete in ${HOURS}h). Next: $0 run"
  ;;

run)
  # Runs in the VM as the default user: the build refuses to run as root,
  # so only the individual setup steps use sudo.
  gcloud_ compute ssh "$NAME" --command "bash -s -- '$REPO' '$BRANCH' '$SSD'" <<'REMOTE'
set -euo pipefail
REPO=$1 BRANCH=$2 SSD=$3
LOG=$SSD/build.log

# The local SSD arrives unformatted.
if ! mountpoint -q "$SSD"; then
  DEV=${SSD_DEV:-/dev/nvme0n1}
  sudo mkfs.ext4 -F -m 0 "$DEV"
  sudo mkdir -p "$SSD"
  sudo mount "$DEV" "$SSD"
  sudo chown "$(id -u):$(id -g)" "$SSD"
fi

# A swap file on the fast disk, in case Soong's analysis overshoots RAM.
if [ ! -e "$SSD/swap" ]; then
  fallocate -l 48G "$SSD/swap" || dd if=/dev/zero of="$SSD/swap" bs=1M count=49152
  chmod 600 "$SSD/swap"
  sudo mkswap "$SSD/swap"
fi
sudo swapon "$SSD/swap" 2>/dev/null || true

# Build dependencies. Same list as the LineageOS wiki, minus what Ubuntu
# 24.04 no longer ships (lib32readline-dev, libsdl1.2-dev, pngcrush).
if [ ! -x "$HOME/.deps-installed" ]; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
    git-lfs gnupg gperf imagemagick lib32ncurses-dev lib32z1-dev libelf-dev \
    liblz4-tool libssl-dev libxml2 libxml2-utils lzop rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev openjdk-21-jdk-headless python3
  touch "$HOME/.deps-installed"
fi

# repo, the launcher Google publishes.
if ! command -v repo >/dev/null; then
  mkdir -p "$HOME/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
  chmod +x "$HOME/bin/repo"
  export PATH="$HOME/bin:$PATH"
  grep -q 'HOME/bin' "$HOME/.profile" || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
fi

# A build directory per VM, with the sources on the fast disk and the
# finished zips copied to the boot disk so they survive the local SSD.
SRC=$SSD/src
if [ ! -d "$SRC/.repo" ]; then
  git clone -b "$BRANCH" "$REPO" "$SSD/manifest"
  mkdir -p "$SRC" "$SSD/zips"
fi

cd "$SSD/manifest"
nohup env PATH="$HOME/bin:$PATH" ZIP_DIR="$SSD/zips" JOBS="$(nproc)" \
  ./build.sh "$SRC" >"$LOG" 2>&1 &
echo "build started, log: $LOG"
REMOTE
  ;;

ssh)
  gcloud_ compute ssh "$NAME"
  ;;

logs)
  gcloud_ compute ssh "$NAME" --command 'tail -f /mnt/ssd/build.log'
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
  sed -n '2,30p' "$0"
  exit 1
  ;;
esac
