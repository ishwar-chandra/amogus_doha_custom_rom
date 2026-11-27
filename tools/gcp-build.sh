#!/usr/bin/env bash
# Build amogus_doha on a Google Cloud VM and publish the result as a GitHub
# release. No Google Drive backup: the VM is disposable and every shipped
# artifact is copied to the GitHub release (and the OTA feed) before deletion.
#
# Local commands (they drive gcloud/ssh; the work happens on the VM):
#   create    the instance: MACHINE + two 375 GB local NVMe
#   setup     build deps in the VM, clone the recipe
#   build     start the build in a tmux session (sync, then compile)
#   gh-check  preflight the GitHub token -- run this before a build
#   finish    wait for the build, verify, release, update OTA, then delete
#   auto-finish              build both variants, then publish them together in one
#                            release; runs on the VM, nothing to babysit, no delete
#   att|logs|state|ssh|fetch|delete
#   release                  publish zips/ as one GitHub release tag: every
#                            variant in zips/ (standard + debloat), creating the
#                            tag or adding to it if it already exists
#   ota <tag> <owner/repo>   write <channel>/doha.json to the OTA feed repo
#                            (--dry-run prints the JSON, publishes nothing)
#   promote <tag>            copy the tested test/doha.json entry into
#                            standard/doha.json -- same artifact, no rebuild
#                            (--dry-run prints it, publishes nothing)
#
# Typical session:  create; setup; build; finish
#
# A successful build is released by `finish`: it verifies the artifacts, calls
# `release`, writes the matching OTA channel, and only then deletes the VM. A
# failed build keeps the VM and log for debugging.
#
# Sizing is one machine for the whole job. A repo sync is a download, so it
# will not use all the cores -- that is inherent to fetching, not a
# misconfiguration -- and the compile that follows is what drives them.
# There is deliberately no stop/resize step: the working tree lives on the
# boot disk; `delete` ends the billing and removes it.
#
# Environment (all optional):
#   PROJECT, ZONE, NAME
#   VUSER         VM account that owns the build state -- build.log,
#                 build.exit, build.channel, the tmux socket and the gh
#                 token all live in its $HOME (default: the account `setup`
#                 recorded in instance metadata, else $USER)
#   MACHINE       compile machine      (default: n2-custom-12-49152)
#   SYNC_MACHINE  separate sync box    (default: MACHINE)
#   DISK, DISK_TYPE                    boot disk (default: 50GB pd-standard)
#   SSD_COUNT     local NVMe count     (default: 2; 2/4/8/16/24)
#   SWAP_GB       swap on the NVMe     (default: 32)
#   HOURS         hard stop            (default: 48; 0 disables)
#   VARIANT       userdebug|user|eng   (default: userdebug)
#   DEBLOAT       1 = same ROM without the optional crDroid extras; zip gets a
#                 -debloat suffix and needs its own TAG/channel (default: 0)
#   OTA_CHANNEL   standard|debloat|test: the feed baked into the build and
#                 written by finish/ota (default: debloat when DEBLOAT=1, else
#                 standard). test is the maintainer feed; promote moves a
#                 tested test build into standard without rebuilding.
#   ADB_KEY       path to an adb public key on this machine; `build` copies
#                 it to the VM and bakes it in (build.sh's ADB_KEY), so adb
#                 works from the phone's first boot. Test builds only: the
#                 zip gets an -adbkey suffix and must never be distributed.
#   JOBS          compile jobs         (default: MACHINE's vCPUs)
#   SYNC_JOBS     repo sync jobs       (default: nproc)
#   REPO_DEPTH    shallow clone depth  (default: 1; empty = full history)
#   REPO, OUT, GH_REPO, OTA_REPO, TAG
#   BRANCH        branch to build (default: the branch checked out in this repo)
#   NO_RELEASE=1 / NO_OTA=1 / NO_DELETE=1   for `finish`
#   AUTO_FINISH=1                       `build` waits for success, releases,
#                                       updates OTA and deletes in one command
set -euo pipefail

PROJECT=${PROJECT:-customrom-514215}
ZONE=${ZONE:-asia-south1-a}
NAME=${NAME:-crdroid-build}
HOURS=${HOURS:-48}
VARIANT=${VARIANT:-userdebug}
# Same axis as build.sh's DEBLOAT: 1 leaves the optional crDroid extras out
# and produces a -debloat zip, which goes into the same release tag and has its
# own OTA channel picked with OTA_CHANNEL.
DEBLOAT=${DEBLOAT:-0}
case $DEBLOAT in 0|1) ;; *) echo "DEBLOAT must be 0 or 1" >&2; exit 1 ;; esac
# The channel is compiled into the Updater, so a build and its feed must agree;
# test currently carries standard (DEBLOAT=0) artifacts only.
case ${OTA_CHANNEL:-} in
  '') ;;
  standard|test)
    [ "$DEBLOAT" = 0 ] || { echo "OTA_CHANNEL=$OTA_CHANNEL needs DEBLOAT=0" >&2; exit 1; } ;;
  debloat)
    [ "$DEBLOAT" = 1 ] || { echo "OTA_CHANNEL=debloat needs DEBLOAT=1" >&2; exit 1; } ;;
  *) echo "OTA_CHANNEL must be standard, debloat or test" >&2; exit 1 ;;
esac
# 12 vCPU is the project's CPUS_ALL_REGIONS cap. 48 GB RAM + 32 GB swap
# covers Soong's ~100 GB analysis peak; RAM is the expensive resource
# ($0.005/GB/h), so the swap file covers the top of the peak. The single
# 500 GB boot disk is >100 GB more than the shallow path needs.
# CPUS_ALL_REGIONS is 12 on this project (the regional limit of 32 does not
# help: the global cap is what a create trips over), so 12 vCPU is the widest
# machine that can be created today. Raise the quota, then MACHINE=n2-custom-16-49152.
MACHINE=${MACHINE:-n2-custom-12-49152}
# Two 375 GB local NVMe devices (750 GB) are the build volume: the first
# holds the tree/out, the second holds ccache and swap. GCP attaches local
# SSDs in pairs, so 2 is the smallest usable count.
SSD_COUNT=${SSD_COUNT:-2}
# DISK_MODE=local : local NVMe (default).
# DISK_MODE=pd    : optional separate 400 GB data disk at /mnt/build.
DISK_MODE=${DISK_MODE:-local}
DATA_DISK_GB=${DATA_DISK_GB:-400}
DATA_DISK_TYPE=${DATA_DISK_TYPE:-pd-ssd}
SYNC_MACHINE=${SYNC_MACHINE:-$MACHINE}
DISK=${DISK:-50GB}
DISK_TYPE=${DISK_TYPE:-pd-standard}
SWAP_GB=${SWAP_GB:-32}
SYNC_JOBS=${SYNC_JOBS:-nproc}
REPO_DEPTH=${REPO_DEPTH-1}
REPO=${REPO:-https://github.com/ishwar-chandra/amogus_doha_custom_rom.git}
# Repo root, not $PWD: the script may be started from anywhere (tools/, or an
# absolute path), and the defaults must still point at this checkout.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Build the branch that is checked out here. performance-tuning carries untested
# work and crdroid-android-17 is the release line, so silently building the
# other one is wrong in both directions. BRANCH is only for a detached checkout
# or a deliberate override.
if [ -z "${BRANCH:-}" ]; then
  BRANCH=$(git -C "$ROOT" symbolic-ref -q --short HEAD || true)
fi
[ -n "$BRANCH" ] || {
  echo "BRANCH is unset and $ROOT has a detached HEAD; set BRANCH=<branch>" >&2
  exit 1
}
OUT=${OUT:-$ROOT/gcp-out}
SESSION=doha
GH_REPO=${GH_REPO:-ishwar-chandra/amogus_doha_custom_rom}
OTA_REPO=${OTA_REPO:-ishwar-chandra/doha-ota}
TAG=${TAG:-crdroid-$(date +%Y%m%d)}
TOKEN_FILE=${TOKEN_FILE:-$HOME/.config/crdroid-gh-token}
# mka's -j comes from the build machine, not from nproc at launch time,
# since build.sh would otherwise cache the core count of a smaller box.
JOBS=${JOBS:-$(printf '%s' "$MACHINE" | sed -n 's/.*-custom-\([0-9]*\)-.*/\1/p;s/.*-\([0-9]*\)$/\1/p')}
JOBS=${JOBS:-12}

# --project/--zone must follow the subcommand. Commands taking a
# `-- <cmd>` tail (ssh, scp) cannot use this and spell the flags out.
gcloud_() { gcloud "$@" --project "$PROJECT" --zone "$ZONE"; }

# gcloud compute ssh logs in as the *local* username, but the whole build state
# -- build.log, build.exit, build.channel, the tmux socket, ~/.gh_token -- lives
# in that account's $HOME. When the local username differs from the one that ran
# `setup` (new login, renamed account, a different terminal uid), `logs` tails a
# build.log that is not there and `finish` polls a build.exit that will never
# appear: an idle build and a dead one look the same. `setup` records the account
# in the instance metadata, so resolve it once and address the VM as $VM.
VUSER=${VUSER:-}
VM=$NAME
resolve_vuser() {
  [ -n "$VUSER" ] ||
    VUSER=$(gcloud compute instances describe "$NAME" --project "$PROJECT" --zone "$ZONE" \
              --format='flattened(metadata.items)' 2>/dev/null |
            awk -F': *' '$1 ~ /\.key$/ {k=$2; next}
                         $1 ~ /\.value$/ && k=="doha-build-user" {print $2; exit}' || true)
  case ${VUSER:-} in ''|*[!A-Za-z0-9._-]*) VUSER=$(id -un) ;; esac
  VM=$VUSER@$NAME
}
instance_status() {
  gcloud compute instances describe "$NAME" --project "$PROJECT" --zone "$ZONE" \
    --format='value(status)' 2>/dev/null || echo MISSING
}
delete_instance() {
  [ "$(instance_status)" = MISSING ] || {
    gcloud compute instances delete "$NAME" --project "$PROJECT" --zone "$ZONE" --quiet
    echo "deleted $NAME"
  }
}

# One token, two sources: GH_TOKEN for a one-off, or the file so `finish`
# works from any shell.
resolve_token() {
  [ -n "${GH_TOKEN:-}" ] && { printf '%s' "$GH_TOKEN"; return 0; }
  [ -s "$TOKEN_FILE" ] && { tr -d '\n[:space:]' < "$TOKEN_FILE"; return 0; }
  cat >&2 <<EOF
No GitHub token (GH_TOKEN unset, $TOKEN_FILE missing).

Create one: https://github.com/settings/tokens
  fine-grained -> access: only $GH_REPO
               -> permissions: Contents = Read and write
  (a classic token with the 'repo' scope also works)
Save it:  printf '%s' 'github_pat_...' > $TOKEN_FILE && chmod 600 $TOKEN_FILE
Verify:   $0 gh-check
EOF
  return 1
}

ota_channel() {
  if [ -n "${OTA_CHANNEL:-}" ]; then
    printf '%s\n' "$OTA_CHANNEL"
  elif [ "${DEBLOAT:-0}" = 1 ]; then
    echo debloat
  else
    echo standard
  fi
}

# The channel the running VM was actually built with. OTA_CHANNEL wins; else
# the marker build wrote, so a manual `finish`/`ota` after a test build cannot
# publish it to standard by omission.
channel_for_vm() {
  if [ -n "${OTA_CHANNEL:-}" ]; then printf '%s\n' "$OTA_CHANNEL"; return; fi
  local ch
  ch=$(gcloud_ compute ssh "$VM" --command 'cat $HOME/build.channel 2>/dev/null || true' 2>/dev/null |
         grep -E '^(standard|debloat|test)$' | tail -1)
  if [ -n "$ch" ]; then printf '%s\n' "$ch"; return; fi
  ota_channel
}

# The VM gets the token, uses it, and deletes it again -- one place, so
# `finish` and `release` cannot drift apart.
publish_release() {
  printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$VM" --command 'umask 077; cat > ~/.gh_token'
  remote_exec release "$TAG" "$GH_REPO"
}

# Run a mode-specific script inside the VM. The mode is $1; the rest are
# settings, passed as arguments because the heredoc is quoted.
remote_exec() {
  # Positionals 1-10 are the fixed settings; the mode's own arguments (a tag,
  # a repo, a dry-run flag) follow them, so `release`/`ota` can see them
  # without re-parsing the shared block above.
  local mode=$1 extra="" a
  shift
  for a in "$@"; do extra+=" '$a'"; done
  gcloud_ compute ssh "$VM" --command \
    "bash -s -- '$mode' '$REPO' '$BRANCH' '$VARIANT' '$SESSION' '$SYNC_JOBS' '$SWAP_GB' '$JOBS' '$REPO_DEPTH' '$DEBLOAT'$extra" \
    <<'REMOTE'
set -euo pipefail
MODE=$1 REPO=$2 BRANCH=$3
VARIANT=$4 SESSION=$5 SYNC_JOBS=$6 SWAP_GB=$7
# The heredoc is quoted, so $JOBS_BUILD/$REPO_DEPTH below are expanded by
# this remote shell: they have to arrive as arguments, not from the caller.
JOBS_BUILD=${8} REPO_DEPTH=${9} DEBLOAT_BUILD=${10:-0}
shift 10

BUILD=/mnt/build
# One disk holds the tree, out/, ccache and swap.
CACHE=$([ -b /dev/nvme0n2 ] && echo /mnt/cache || echo "$BUILD/cache")
SRC=$BUILD/src MANIFEST=$BUILD/manifest ZIPS=$BUILD/zips CCACHE=$CACHE/ccache
LOG=$HOME/build.log EXIT=$HOME/build.exit

# DISK_MODE=local with SSD_COUNT=0: /mnt/build is a directory on the boot
# disk. With local NVMe, the first device is /mnt/build and the second
# /mnt/cache; DISK_MODE=pd uses /dev/disk/by-id/google-data.
mount_ssds() {
  local n=0 dev mnt
  # DISK_MODE=pd: no local SSD; the tree lives on a persistent data disk that
  # appears as /dev/disk/by-id/google-data.
  if [ ! -e /dev/nvme0n1 ]; then
    if [ -b /dev/disk/by-id/google-data ]; then
      mnt=$BUILD
      if ! mountpoint -q "$mnt"; then
        sudo mkdir -p "$mnt"
        [ -n "$(sudo blkid -o value -s TYPE /dev/disk/by-id/google-data 2>/dev/null)" ] ||
          sudo mkfs.ext4 -F -m 0 /dev/disk/by-id/google-data >/dev/null
        sudo mount /dev/disk/by-id/google-data "$mnt"
        sudo chown "$(id -u):$(id -g)" "$mnt"
      fi
    else
      # Default single-disk setup: /mnt/build is a directory on the 500 GB
      # boot disk. Create and own it here so setup can write as the user.
      sudo mkdir -p "$BUILD"
      sudo chown "$(id -u):$(id -g)" "$BUILD"
      echo "using $BUILD on the boot disk (no local SSD)"
    fi
    return 0
  fi
  for dev in /dev/nvme0n1 /dev/nvme0n2; do
    n=$((n + 1)); mnt=$([ $n = 1 ] && echo "$BUILD" || echo "$CACHE")
    [ -e "$dev" ] || continue
    mountpoint -q "$mnt" && continue
    sudo mkdir -p "$mnt"
    # Ask about *this* device: plain `blkid $dev` succeeds whenever any
    # device has a signature (the loop mounts, the boot disk), which would
    # skip the format and then fail the mount on a bare disk.
    [ -n "$(sudo blkid -o value -s TYPE "$dev" 2>/dev/null)" ] ||
      sudo mkfs.ext4 -F -m 0 "$dev" >/dev/null
    sudo mount "$dev" "$mnt"
    sudo chown "$(id -u):$(id -g)" "$mnt"
  done
}
mount_ssds

# A custom boot disk can be much larger than the 10 GB image. Google's Ubuntu
# image normally grows the root partition at first boot; do it again here in
# case the image did not, so /mnt/build sees the full 500 GB.
grow_root() {
  local src disk part
  src=$(findmnt -n -o SOURCE / 2>/dev/null) || return 0
  case $src in /dev/*) ;; *) return 0 ;; esac
  disk=${src%[0-9]*}
  part=${src##*[!0-9]}
  [ -b "$disk" ] || return 0
  command -v growpart >/dev/null || return 0
  sudo growpart "$disk" "$part" >/dev/null 2>&1 || true
  sudo resize2fs "$src" >/dev/null 2>&1 || true
}

ensure_swap() {
  local f=$CACHE/swap
  mkdir -p "$CACHE"
  if [ ! -e "$f" ]; then
    fallocate -l "${SWAP_GB}G" "$f" 2>/dev/null ||
      dd if=/dev/zero of="$f" bs=1M count=$((SWAP_GB * 1024)) status=none
    chmod 600 "$f"; sudo chown 0:0 "$f"   # mkswap refuses a user-owned file
    sudo mkswap "$f" >/dev/null
  fi
  swapon --show=NAME --noheadings | grep -qx "$f" || sudo swapon "$f" 2>/dev/null || true
}

install_deps() {
  [ -x "$HOME/.deps-installed" ] && return
  # A fresh image runs unattended-upgrades at boot and holds the dpkg lock.
  sudo apt-get -o DPkg::Lock::Timeout=900 update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
    git-lfs gnupg gperf imagemagick lib32ncurses-dev lib32z1-dev libelf-dev \
    liblz4-tool libssl-dev libxml2 libxml2-utils lzop rsync schedtool \
    squashfs-tools xsltproc zip zlib1g-dev tmux openjdk-21-jdk-headless python3
  mkdir -p "$HOME/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
  chmod +x "$HOME/bin/repo"
  grep -q 'HOME/bin' "$HOME/.profile" || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
  touch "$HOME/.deps-installed"
}

# out/ is 135 GB (112 GB of it Soong intermediates) and the tree plus .repo is
# another 230 GB: on one 369 GB disk a clean build dies at 93% with "No space
# left on device" while add_img_to_target_files stages target_files. Keep out/
# on the second device. The move itself is a one-off (mv + bind mount); this
# only re-establishes the mount, because a reboot drops it while the data stays
# on the cache disk.
ensure_out_on_cache() {
  local out=$SRC/out cache_out=$CACHE/out
  [ "$CACHE" = "$BUILD/cache" ] && return 0     # no second disk to move onto
  mountpoint -q "$CACHE" || return 0
  [ -d "$cache_out" ] || return 0                # nothing migrated yet
  mountpoint -q "$out" && return 0               # already bound
  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    echo "WARN: $out is not empty and $cache_out exists; leaving it alone" >&2
    return 0
  fi
  sudo mkdir -p "$out"
  sudo mount --bind "$cache_out" "$out"
  echo "out/ on $CACHE ($(df -h --output=avail "$out" | tail -1 | tr -d ' ') free) -- one disk cannot hold tree + out/"
}

# One place for both tools: install on first use, no-op afterwards.
install_gh() {
  command -v gh >/dev/null && return
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 \
       install -y gh >/dev/null 2>&1; then
    local v; v=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest |
      sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
    ( cd /tmp && curl -fsSL -o gh.tgz \
        "https://github.com/cli/cli/releases/download/v$v/gh_${v}_linux_amd64.tar.gz" &&
      tar xzf gh.tgz && sudo install -m755 gh_*/bin/gh /usr/local/bin/gh )
  fi
}

release_notes() {
  # One tag carries every variant built that day, so the notes list what is
  # actually in ZIP_DIR instead of deriving a single variant from the tag.
  local variants="standard"
  ls "$ZIPS"/*-debloat*.zip >/dev/null 2>&1 && variants="standard + debloat"
  cat <<EOF
Unofficial crDroid 13 (Android 17) for the Motorola Moto G8 Plus — device \`doha\`, tree \`amogus_doha\`.

**Variants:** $variants · **branch:** $BRANCH · **manifest:** $(git -C "$MANIFEST" rev-parse --short HEAD 2>/dev/null || echo unknown)

## Flash it

The phone is A/B and recovery lives inside \`boot\`. Each zip has its own images, named after it:
\`crDroidAndroid-*-boot.img\` for the standard build, \`crDroidAndroid-*-debloat-boot.img\` for the
debloat build. Flash the images that match the zip you are going to sideload.

1. Unlock the bootloader. From stock or another ROM, flash the images of this release:
   \`\`\`
   fastboot flash boot  crDroidAndroid-*-boot.img
   fastboot flash dtbo  crDroidAndroid-*-dtbo.img
   fastboot flash vbmeta crDroidAndroid-*-vbmeta.img   # only if verification complains
   \`\`\`
2. Boot to recovery (power + volume down → Recovery).
3. **Factory reset → Format data** when coming from another ROM or switching variants.
4. **Apply update → Apply from ADB**, then \`adb sideload crDroidAndroid-*.zip\`.
5. Reboot. First boot takes several minutes; the second is normal.

## Google apps (optional, not included)

This build ships no Google apps. Flash crDroid's own NikGapps package for Android 17 / arm64 in
the same recovery session, right after the ROM, answering **Yes** to "install additional packages":

[NikGapps-crdroid-official-arm64-17](https://sourceforge.net/projects/crdroid/files/gapps/NikGapps-crdroid-official-arm64-17-20261021.zip/download) (486 MB)

It lives in [crDroid's gapps folder](https://sourceforge.net/projects/crdroid/files/gapps/); take the newest
arm64-17 official file there if that date has been superseded. MindTheGapps 17.0.0 arm64
(https://github.com/MindTheGapps/17.0.0-arm64/releases) is the smaller tested alternative.

## Checksums

\`sha256sum -c crDroidAndroid-*.sha256sum\`

Tested items, known issues and the untested checklist: see the repository README ("Status") and
docs/BUGREPORT.md. Do not flash a zip from a different variant over this one without wiping data.
EOF
}

# Only this variant's artifacts, and never a test build: a release must not
# contain an -adbkey zip (it trusts the builder's key) or the other variant.
release_assets() {
  local f base
  for f in "$ZIPS"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    # One release holds every variant built into ZIP_DIR (standard and
    # -debloat), each with its own zip, images and sha256sum. Test builds are
    # still excluded: they trust the builder's adb key.
    case $base in *-adbkey*) continue ;; esac
    echo "$f"
  done
}

case "$MODE" in

setup)  install_deps
        grow_root
        mkdir -p "$SRC" "$ZIPS" "$CCACHE"
        ensure_swap
        ensure_out_on_cache
        [ -d "$MANIFEST/.git" ] || git clone -b "$BRANCH" "$REPO" "$MANIFEST"
        echo "setup done: $(nproc) cpus, $(free -g | awk 'NR==2{print $2}') GiB RAM, swap $(swapon --show=SIZE --noheadings | tr -d ' ')" ;;

build)
        ADB_KEY_BUILD=${1:-0}
        # Feed baked into this build (build.sh's OTA_CHANNEL): handed in by a
        # normal `build`, derived from the variant when auto-finish starts it.
        CHANNEL=${2:-}
        [ -n "$CHANNEL" ] || {
          if [ "$DEBLOAT_BUILD" = 1 ]; then CHANNEL=debloat; else CHANNEL=standard; fi
        }
        case $CHANNEL in standard|debloat|test) ;;
          *) echo "bad OTA channel: $CHANNEL" >&2; exit 1 ;; esac
        # `finish`/`ota` default to this, so a manual run cannot publish a test
        # build into standard just because it did not repeat OTA_CHANNEL.
        printf '%s\n' "$CHANNEL" > "$HOME/build.channel"
        ensure_out_on_cache
        # The VM builds from its own clone of this recipe, so a change that was
        # not pushed never reaches it. Pull the branch first and say which
        # commit is being built; the caller checks for uncommitted work.
        if [ -d "$MANIFEST/.git" ]; then
          if git -C "$MANIFEST" fetch -q origin "$BRANCH" 2>/dev/null &&
             git -C "$MANIFEST" checkout -q -B "$BRANCH" FETCH_HEAD 2>/dev/null; then
            echo "manifest: $(git -C "$MANIFEST" log -1 --format='%h %s')"
          else
            echo "manifest: fetch/reset failed, building the clone as it is" >&2
          fi
        fi
        cat > "$HOME/run-build.sh" <<'EOS'
#!/bin/bash
# Started by tools/gcp-build.sh inside tmux; records the exit code for
# `finish`, whatever happens.
set -o pipefail
BUILD=/mnt/build
# One disk holds the tree, out/, ccache and swap.
CACHE=$([ -b /dev/nvme0n2 ] && echo /mnt/cache || echo "$BUILD/cache")
export PATH="$HOME/bin:$PATH"
export CCACHE_DIR="$CACHE/ccache" ZIP_DIR="$BUILD/zips" TMPDIR="$BUILD/tmp"
mkdir -p "$TMPDIR"
export JOBS=${JOBS:-$(nproc)} VARIANT=${VARIANT:-userdebug}
export REPO_DEPTH="${REPO_DEPTH:-}"
# SYNC_JOBS can arrive as the literal word "nproc", which repo -j rejects,
# so resolve it here where nproc means this machine.
case "${SYNC_JOBS:-nproc}" in nproc|"") SYNC_JOBS=$(nproc) ;; esac
export SYNC_JOBS
# The swap device does not survive a reboot even though the file does.
swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$CACHE/swap" ||
  sudo swapon "$CACHE/swap" 2>/dev/null || true
cd "$BUILD/manifest" || exit 90
rm -f "$HOME/build.exit"
./build.sh "$BUILD/src"; code=$?
echo "$code" > "$HOME/build.exit"
echo "--- build.sh exited $code ---"
EOS
        chmod +x "$HOME/run-build.sh"
        tmux kill-session -t "$SESSION" 2>/dev/null || true
        # Killing the session is not always enough for repo, which keeps its
        # own process tree; a leftover sync would fight the new one. repo
        # resumes where it stopped.
        pkill -f "repo/main.py" 2>/dev/null || true
        sleep 2; rm -f "$EXIT"
        # ADB_KEY builds need the public key on the VM; build.sh does the rest
        # (vendor/extra/product.mk, adb_keys in recovery+product).
        adb_env=
        [ "$ADB_KEY_BUILD" = 1 ] && adb_env="ADB_KEY='$HOME/adbkey.pub' "
        tmux new-session -d -s "$SESSION" \
          "$adb_env VARIANT='$VARIANT' DEBLOAT='$DEBLOAT_BUILD' OTA_CHANNEL='$CHANNEL' SYNC_JOBS='$SYNC_JOBS' JOBS='$JOBS_BUILD' REPO_DEPTH='$REPO_DEPTH' '$HOME/run-build.sh' 2>&1 | tee '$LOG'"
        sleep 3; tmux ls
        echo "started in tmux '$SESSION'; log: $LOG" ;;

state)  [ -f "$EXIT" ] && echo "finished exit=$(cat "$EXIT")" || echo "no exit file yet"
        tmux ls 2>/dev/null || echo "no tmux session"
        tail -n 3 "$LOG" 2>/dev/null || true ;;

verify) fail=0 newest="" latest_zip="" base=""
        latest_zip=$(ls -t "$ZIPS"/crDroidAndroid-*.zip 2>/dev/null | head -1)
        [ -n "$latest_zip" ] || { echo "no crDroidAndroid-*.zip in $ZIPS"; fail=1; }
        base=${latest_zip%.zip}
        for f in boot dtbo vbmeta; do
          [ -e "$base-$f.img" ] || [ -e "$ZIPS/$f.img" ] ||
            { echo "missing $f.img for $(basename "${latest_zip:-zip}")"; fail=1; }
        done
        # Both variants share the image names, so an older sum can no longer
        # match once the other variant is built into the same directory. Only
        # the newest set (the one about to ship) decides pass/fail.
        newest=$(ls -t "$ZIPS"/*.sha256sum 2>/dev/null | head -1)
        for s in "$ZIPS"/*.sha256sum; do
          [ -e "$s" ] || continue
          if ( cd "$ZIPS" && sha256sum -c "$(basename "$s")" >/dev/null ); then
            echo "checksums ok: $(basename "${s%.sha256sum}")"
          elif [ "$s" = "$newest" ]; then
            echo "FAIL: $(basename "$s") does not match its files" >&2
            fail=1
          else
            echo "WARN: $(basename "$s") is superseded (images are shared between variants)" >&2
          fi
        done
        [ "$fail" = 0 ] && echo "artifacts ok: $(ls "$ZIPS" | tr '\n' ' ')"
        exit "$fail" ;;

release) TAG=${1:?release needs a tag} GH_REPO=${2:?release needs owner/repo}
         install_gh
         [ -s "$HOME/.gh_token" ] || { echo "no ~/.gh_token on the VM" >&2; exit 1; }
         export GH_TOKEN=$(cat "$HOME/.gh_token")
         mapfile -t assets < <(release_assets)
         [ ${#assets[@]} -gt 0 ] || { echo "no assets for $TAG in $ZIPS" >&2; exit 1; }
         echo "assets: ${assets[*]}"
         # One tag carries every variant, and the variants are built one after
         # the other, so the second `release` for a date must add its files to
         # the tag that the first one created instead of failing on it.
         if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
           gh release upload "$TAG" "${assets[@]}" --clobber --repo "$GH_REPO"
           gh release edit "$TAG" --notes "$(release_notes)" --repo "$GH_REPO"
           echo "updated $TAG on $GH_REPO ($(ls "$ZIPS" | grep -c '\.zip$') zips)"
         else
           gh release create "$TAG" --repo "$GH_REPO" --target "$BRANCH" --title "$TAG" \
              --notes "$(release_notes)" "${assets[@]}" && rm -f "$HOME/.gh_token"
           echo "published $TAG to $GH_REPO"
         fi ;;

ota)  TAG=${1:?usage: ota <tag> <owner/repo> [--dry-run]}
      OTA_REPO=${2:?usage: ota <tag> <owner/repo> [--dry-run]}
      OTA_DRY=${3:-}
      GH_REPO=${4:-}
      # `finish` passes the variant explicitly. A manual `ota` call on a VM
      # falls back to the DEBLOAT_BUILD fixed argument, then to standard.
      channel=${5:-}
      [ -n "$channel" ] || {
        if [ "${DEBLOAT_BUILD:-0}" = 1 ]; then channel=debloat; else channel=standard; fi
      }
      case $channel in standard|debloat|test) ;; *) echo "bad OTA channel: $channel" >&2; exit 1 ;; esac
      # A run that publishes both variants at once builds them one after the other,
      # so $SRC/out only holds the last variant's props. auto-finish saves each
      # variant's build.prop as ~/build.prop.<channel> right after its build.
      prop=""
      for c in "$HOME/build.prop.$channel" \
               "$SRC/out/target/product/amogus_doha/system/build.prop" \
               "$SRC/out/target/product/amogus_doha/obj/ETC/system_build_prop_intermediates/build.prop"; do
        [ -s "$c" ] && prop=$c && break
      done
      [ -n "$prop" ] || { echo "no build.prop yet: the build has not packaged" >&2; exit 1; }
      if [ "$channel" = debloat ]; then
        zip=$(ls "$ZIPS"/*-debloat.zip 2>/dev/null | grep -v -- -adbkey | head -1)
      else
        zip=$(ls "$ZIPS"/*.zip 2>/dev/null | grep -v -- -debloat | grep -v -- -adbkey | tail -1)
      fi
      [ -n "$zip" ] || { echo "no $channel zip in $ZIPS" >&2; exit 1; }
      dt=$(sed -n 's/^ro.build.date.utc=//p' "$prop" | head -1)
      rtype=$(sed -n 's/^ro.build.type=//p' "$prop" | head -1)
      ver=$(sed -n 's/^ro.cm.version=//p' "$prop" | head -1)
      [ -n "$ver" ] || ver=$(sed -n 's/^ro.crdroid.version=//p' "$prop" | head -1)
      patch=$(sed -n 's/^ro.build.version.security_patch=//p' "$prop" | head -1)
      sdk=$(sed -n 's/^ro.build.version.sdk=//p' "$prop" | head -1)
      base=$(basename "$zip")
      sha256=$(sha256sum "$zip" | cut -d' ' -f1)
      size=$(stat -c %s "$zip")
      # crDroid/Lineage 17 Updater schema: download/timestamp/sha256/buildtype/
      # os_sdk_level. The old datetime/id/url/romtype shape fails JSON parsing.
      body=$(printf '{\n  "response": [\n    {\n      "filename": "%s",\n      "download": "https://github.com/%s/releases/download/%s/%s",\n      "timestamp": %s,\n      "sha256": "%s",\n      "size": %s,\n      "version": "%s",\n      "buildtype": "%s",\n      "os_patch_level": "%s",\n      "os_sdk_level": %s\n    }\n  ]\n}\n' \
             "$base" "$GH_REPO" "$TAG" "$base" "${dt:-0}" "$sha256" "$size" "${ver:-13.1}" \
             "${rtype:-userdebug}" "${patch:-}" "${sdk:-37}")
      if [ "$OTA_DRY" = --dry-run ]; then printf '%s\n' "$body"; exit 0; fi
      [ -s "$HOME/.gh_token" ] || { echo "no ~/.gh_token on the VM" >&2; exit 1; }
      token=$(cat "$HOME/.gh_token")
      api="https://api.github.com/repos/$OTA_REPO/contents/$channel/doha.json"
      sha=$(curl -fsS -H "Authorization: Bearer $token" "$api" 2>/dev/null \
              | sed -n 's/.*"sha": "\([^"]*\)".*/\1/p' | head -1)
      curl -fsS -X PUT -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -d "$(python3 -c 'import base64,json,sys
body,tag,sha=sys.argv[1],sys.argv[2],sys.argv[3]
d={"message":"ota: "+tag,"content":base64.b64encode(body.encode()).decode()}
if sha: d["sha"]=sha
print(json.dumps(d))' "$body" "$TAG" "$sha")" \
        "$api" >/dev/null && rm -f "$HOME/.gh_token"
      echo "published $channel/doha.json to $OTA_REPO" ;;

*) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac
REMOTE
}

# create/delete never log in (and create is the first call on a fresh VM, so
# there is no metadata to read yet); everything that talks to the VM does.
case "${1:-}" in
  setup|build|state|verify|release|ota|att|logs|ssh|fetch|finish|auto-finish) resolve_vuser ;;
esac

case "${1:-}" in
create)
  extra=()
  [ "$HOURS" != 0 ] && extra=(--max-run-duration="$((HOURS * 3600))s" --instance-termination-action=DELETE)
  case "${SSD_COUNT:-0}" in
    0|2|4|8|16|24) ;;
    *) echo "SSD_COUNT=${SSD_COUNT:-0} is not allowed: GCP takes 0, 2, 4, 8, 16 or 24 local SSDs." >&2
       exit 1 ;;
  esac
  ssd=()
  if [ "$DISK_MODE" = local ]; then
    for _ in $(seq 1 "${SSD_COUNT:-0}"); do ssd+=(--local-ssd interface=nvme,size=375gb); done
  fi
  # Fail before the create with a readable reason: a 16-vCPU machine on a
  # 12-vCPU global quota costs nothing to attempt but confuses the log.
  want=$(gcloud_ compute machine-types describe "$SYNC_MACHINE" --format='value(guestCpus)' 2>/dev/null || echo "")
  have=$(gcloud_ compute project-info describe --format='value(quotas[metric=CPUS_ALL_REGIONS].limit)' 2>/dev/null || echo "")
  echo "cpus: $SYNC_MACHINE wants ${want:-?}, project CPUS_ALL_REGIONS is ${have:-?}"
  if [ -n "$want" ] && [ -n "$have" ] && awk "BEGIN{exit !($want > $have)}"; then
    echo "refusing: $SYNC_MACHINE needs $want vCPUs but CPUS_ALL_REGIONS is $have." >&2
    echo "Either request a quota increase, or MACHINE=n2-custom-${have%.*}-49152." >&2
    exit 1
  fi
  case "$DISK_TYPE" in
    pd-ssd|pd-balanced)
      disk_gb=${DISK%GB}
      case "$disk_gb" in
        ''|*[!0-9]*) ;;
        *)
          ssd_have=$(gcloud compute regions describe "${ZONE%-*}" --project "$PROJECT" \
            --format='value(quotas[metric=SSD_TOTAL_GB].limit)' 2>/dev/null || echo "")
          echo "ssd: ${DISK} $DISK_TYPE wants ${disk_gb} GB, regional SSD_TOTAL_GB is ${ssd_have:-?}"
          if [ -n "$ssd_have" ] && awk "BEGIN{exit !($disk_gb > $ssd_have)}"; then
            echo "refusing: ${DISK} does not fit SSD_TOTAL_GB=${ssd_have}." >&2
            echo "Use DISK_TYPE=pd-standard, a smaller DISK, or raise the SSD quota." >&2
            exit 1
          fi ;;
      esac ;;
  esac
  gcloud_ compute instances create "$NAME" \
    --machine-type "$SYNC_MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --boot-disk-size "$DISK" --boot-disk-type "$DISK_TYPE" \
    "${ssd[@]}" \
    --boot-disk-auto-delete \
    "${extra[@]}" --scopes cloud-platform
  if [ "$DISK_MODE" = pd ]; then
    # A data disk has no pair rule: exactly the size asked for, and it can outlive
    # the instance (DATA_DISK_KEEP=1) so a later VM resumes without a re-sync.
    gcloud_ compute disks create "$NAME-data" --size "${DATA_DISK_GB}GB" --type "$DATA_DISK_TYPE"
    gcloud_ compute instances attach-disk "$NAME" --disk "$NAME-data" \
      --device-name data --mode rw
    if [ "${DATA_DISK_KEEP:-0}" = 1 ]; then
      gcloud_ compute instances set-disk-auto-delete "$NAME" --device-name data --no-auto-delete
    else
      gcloud_ compute instances set-disk-auto-delete "$NAME" --device-name data --auto-delete
    fi
    echo "Created $NAME ($SYNC_MACHINE, ${DATA_DISK_GB} GB $DATA_DISK_TYPE at /mnt/build). Next: setup, build, finish"
  else
    if [ "${SSD_COUNT:-0}" = 0 ]; then
      echo "Created $NAME ($SYNC_MACHINE, one $DISK $DISK_TYPE disk). Next: setup, build, finish"
    else
      echo "Created $NAME ($SYNC_MACHINE, ${SSD_COUNT}x 375 GB NVMe). Next: setup, build, finish"
    fi
  fi ;;

gh-check)
  tok=$(resolve_token) || exit 1
  echo "token: ${tok:0:6}...${tok: -4} (${#tok} chars)"
  api=https://api.github.com
  hdr=(-H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json")
  body=$(mktemp); trap 'rm -f "$body"' EXIT
  code=$(curl -sS -o "$body" -w '%{http_code}' "${hdr[@]}" "$api/repos/$GH_REPO")
  [ "$code" = 200 ] || { echo "FAIL: GET /repos/$GH_REPO -> $code"; sed -n 's/.*"message": *"\([^"]*\)".*/  \1/p' "$body"; exit 1; }
  python3 - "$body" "$GH_REPO" <<'PY' || { echo "FAIL: token needs Contents: Read and write"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1])); p = d.get('permissions', {})
print(f"repo: {sys.argv[2]} (default branch {d.get('default_branch')}, private={d.get('private')})")
print(f"token permissions: push={p.get('push')} admin={p.get('admin')}")
sys.exit(0 if p.get('push') else 1)
PY
  tcode=$(curl -sS -o /dev/null -w '%{http_code}' "${hdr[@]}" "$api/repos/$GH_REPO/releases/tags/$TAG")
  case $tcode in
    404) echo "ok: tag $TAG free" ;;
    200) echo "NOTE: a release for $TAG exists -- set TAG=... for a new one" ;;
    *)   echo "WARN: tag check returned $tcode" ;;
  esac
  echo "gh-check passed" ;;

release)  publish_release ;;
ota)
  # Writes the feed entry, so the ROM's Updater finds this release. Runs after
  # the release exists: the JSON points at its download URL.
  printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$VM" --command 'umask 077; cat > ~/.gh_token'
  remote_exec ota "${TAG:-}" "$OTA_REPO" "${OTA_DRY:-}" "$GH_REPO" "$(channel_for_vm)" ;;
promote)
  # Promote the artifact already tested on the test channel: the exact zip the
  # test feed points at becomes the standard one, with no rebuild. Refuses a
  # debloat/adbkey artifact, a tag mismatch, or a build that is not newer than
  # what standard already advertises.
  PTAG=${2:-${TAG:-}}
  case $PTAG in -*|'') echo "usage: promote <tag> [--dry-run]" >&2; exit 1 ;; esac
  PDRY=${3:-}
  case $PDRY in ''|--dry-run) ;; *) echo "usage: promote <tag> [--dry-run]" >&2; exit 1 ;; esac
  tok=$(resolve_token) || exit 1
  api="https://api.github.com/repos/$OTA_REPO/contents"
  hdr=(-H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json")
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  code=$(curl -sS -o "$tmp/test.json" -w '%{http_code}' "${hdr[@]}" "$api/test/doha.json")
  [ "$code" = 200 ] || { echo "promote: no test/doha.json in $OTA_REPO (HTTP $code)" >&2; exit 1; }
  scode=$(curl -sS -o "$tmp/std.json" -w '%{http_code}' "${hdr[@]}" "$api/standard/doha.json")
  case $scode in
    200) ;;
    404) rm -f "$tmp/std.json" ;;
    *) echo "promote: GET standard/doha.json -> $scode" >&2; exit 1 ;;
  esac
  python3 - "$tmp/test.json" "$tmp/std.json" "$PTAG" "$tmp/body.b64" "$tmp/meta" "$tmp/stdsha" <<'PY'
import base64, json, sys
testp, stdp, tag, body_out, meta_out, sha_out = sys.argv[1:7]
d = json.load(open(testp))
body = json.loads(base64.b64decode(d["content"]))
u = body["response"][0]
name, ts, url = u["filename"], int(u["timestamp"]), u["download"]
if f"/download/{tag}/" not in url:
    sys.exit(f"promote: test feed points at {url}, not tag {tag}")
if "-debloat" in name or "-adbkey" in name:
    sys.exit(f"promote: refusing {name}: not a standard artifact")
stdsha = ""
try:
    s = json.load(open(stdp))
except FileNotFoundError:
    pass
else:
    old = json.loads(base64.b64decode(s["content"]))["response"][0]
    ots = int(old["timestamp"])
    if ots > ts:
        sys.exit(f"promote: standard already offers a newer build ({old['filename']})")
    if ots == ts:
        if old["filename"] == name:
            sys.exit(f"promote: {name} is already the standard build")
        sys.exit(f"promote: standard already has a build with timestamp {ts}")
    stdsha = s["sha"]
open(body_out, "w").write(base64.b64encode(json.dumps(body).encode()).decode())
open(meta_out, "w").write(f"{name} {ts}")
open(sha_out, "w").write(stdsha)
print(f"promote: {name} (timestamp {ts})")
PY
  if [ "$PDRY" = --dry-run ]; then
    python3 -c 'import base64,sys; print(base64.b64decode(open(sys.argv[1]).read()).decode())' "$tmp/body.b64"
    exit 0
  fi
  python3 - "$tmp/body.b64" "$PTAG" "$(cat "$tmp/stdsha")" > "$tmp/put.json" <<'PY'
import json, sys
b64, tag, sha = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"message": f"ota: promote {tag} to standard", "content": open(b64).read().strip()}
if sha:
    d["sha"] = sha
print(json.dumps(d))
PY
  curl -fsS -X PUT "${hdr[@]}" -d @"$tmp/put.json" "$api/standard/doha.json" >/dev/null
  echo "promoted $(cat "$tmp/meta") to standard/doha.json" ;;
finish)
  echo "waiting for the build (hours; Ctrl-C is safe, the build keeps running)"
  while [ -z "$(gcloud_ compute ssh "$VM" --command "cat \$HOME/build.exit 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')" ]; do
    sleep 60
  done
  code=$(gcloud_ compute ssh "$VM" --command "cat \$HOME/build.exit" | tr -d '[:space:]')
  echo "build.sh exited $code"
  [ "$code" = 0 ] || { echo "build failed: VM kept, log at $VM:~/build.log" >&2; exit 1; }
  remote_exec verify
  [ "${NO_RELEASE:-0}" = 1 ] || publish_release
  if [ "${NO_OTA:-0}" != 1 ] && [ "${NO_RELEASE:-0}" != 1 ]; then
    # The feed entry points at the release URL, so it has to come after it.
    printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$VM" --command 'umask 077; cat > ~/.gh_token'
    if ! remote_exec ota "${TAG:-}" "$OTA_REPO" "" "$GH_REPO" "$(channel_for_vm)"; then
      echo "OTA feed not updated: check $OTA_REPO and token write access." >&2
      echo "VM kept: fix the feed/token and rerun 'tools/gcp-build.sh finish'." >&2
      exit 1
    fi
  fi
  [ "${NO_DELETE:-0}" = 1 ] && echo "NO_DELETE=1: $NAME left running" || delete_instance ;;

build)
  # The VM builds from its own clone of this repo: anything uncommitted or
  # unpushed simply will not be there, which has bitten this project before.
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "WARN: $ROOT has uncommitted changes; the VM builds origin/$BRANCH only" >&2
  fi
  if [ -n "$(git -C "$ROOT" log --oneline "origin/$BRANCH..HEAD" 2>/dev/null)" ]; then
    echo "WARN: local commits are not pushed to origin/$BRANCH; the VM will not see them" >&2
  fi
  # ADB_KEY is a path on *this* machine; the VM needs the key itself. Its
  # content is validated here so a bad path fails before the build starts.
  adb_arg=0
  if [ -n "${ADB_KEY:-}" ]; then
    [ -f "$ADB_KEY" ] || { echo "ADB_KEY: no such file: $ADB_KEY" >&2; exit 1; }
    [ "$(head -c 5 "$ADB_KEY")" = QAAAA ] ||
      { echo "ADB_KEY must be an adb public key (adbkey.pub): $ADB_KEY" >&2; exit 1; }
    gcloud_ compute scp "$ADB_KEY" "$VM:adbkey.pub" >/dev/null
    adb_arg=1
    echo "ADB_KEY: copied $(basename "$ADB_KEY") to $NAME, build gets -adbkey suffix"
  fi
  remote_exec build "$adb_arg" "$(ota_channel)"
  if [ "${AUTO_FINISH:-0}" = 1 ]; then
    echo "AUTO_FINISH=1: waiting for the build and releasing it"
    "$0" finish
  fi ;;

auto-finish)
  # Publish the variant that is building, then build + publish the other one,
  # all on the VM: nothing after this call needs this machine, so a dropped
  # connection cannot leave a finished build unpublished. The VM is kept.
  status=$(instance_status)
  [ "$status" = RUNNING ] || { echo "auto-finish: $NAME is $status" >&2; exit 1; }
  first=${FIRST_VARIANT:-${DEBLOAT:-0}}
  case $first in 0|1) ;; *) echo "FIRST_VARIANT must be 0 or 1" >&2; exit 1 ;; esac
  tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
  # The remote half of every other mode, verbatim: it is the script's own heredoc.
  sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$0" | sed '1d;$d' > "$tmpd/doha-remote.sh"
  grep -q '^MODE=' "$tmpd/doha-remote.sh" || { echo "auto-finish: could not extract the remote script" >&2; exit 1; }
  cat > "$tmpd/doha-chain.sh" <<'CHAIN'
#!/bin/bash
# Runs ON the VM (tools/gcp-build.sh auto-finish starts it in tmux 'publish'):
# publish the variant that is currently building, build the other one, publish
# that too. No workstation involvement and no VM deletion.
set -uo pipefail
export PATH="$HOME/bin:$PATH"
R=$HOME/doha-remote.sh
exec >>"$HOME/doha-chain.log" 2>&1
FIRST=${FIRST:-0}
SECOND=$([ "$FIRST" = 1 ] && echo 0 || echo 1)
chan() { [ "$1" = 1 ] && echo debloat || echo standard; }

run() { local mode=$1 deb=$2; shift 2
        bash "$R" "$mode" "$REPO" "$BRANCH" "$VARIANT" "$SESS" "$SYNC" \
             "$SWAP" "$JOBS_" "$DEPTH" "$deb" "$@"; }

wait_build() {
    while [ ! -f "$HOME/build.exit" ]; do sleep 60; done
    code=$(cat "$HOME/build.exit")
    echo "build.exit=$code $(date -u +%H:%M)"
    [ "$code" = 0 ]
}

token() { cp -f "$HOME/.gh_token_master" "$HOME/.gh_token" && chmod 600 "$HOME/.gh_token"; }

save_prop() {   # keep each variant's props: out/ only holds the last one
    local ch=$1 c
    for c in /mnt/build/src/out/target/product/amogus_doha/system/build.prop \
             /mnt/build/src/out/target/product/amogus_doha/obj/ETC/system_build_prop_intermediates/build.prop; do
        [ -s "$c" ] && cp -f "$c" "$HOME/build.prop.$ch" && return 0
    done
    echo "warning: no build.prop to save for $ch" >&2
    return 1
}

echo "chain start $(date -u) branch=$BRANCH first-variant=$(chan "$FIRST")"

# Build BOTH variants first and publish once at the end. Publishing the first
# variant on its own leaves a window where the release (and the OTA feed) offers
# only one variant, and people on the other channel grab the wrong zip.
wait_build && save_prop "$(chan "$FIRST")" || { echo "first build failed, stopping"; exit 1; }
run verify "$FIRST" || { echo "first variant verify FAILED"; exit 1; }

rm -f "$HOME/build.exit"
git -C /mnt/build/manifest fetch -q origin "$BRANCH" &&
  git -C /mnt/build/manifest checkout -q -B "$BRANCH" FETCH_HEAD
echo "manifest for second build: $(git -C /mnt/build/manifest log -1 --format='%h %s')"
run build "$SECOND" 0 || { echo "second build failed to start"; exit 1; }
wait_build && save_prop "$(chan "$SECOND")" || { echo "second build failed, nothing published"; exit 1; }
run verify "$SECOND" || { echo "second variant verify FAILED, nothing published"; exit 1; }

# One release carries every variant now sitting in zips/.
token; run release "$SECOND" "$TAG" "$GHR" || { echo "release FAILED, nothing published"; exit 1; }
echo "released $TAG with both variants $(date -u +%H:%M)"
token; run ota "$SECOND" "$TAG" "$OTAR" "" "$GHR" standard || { echo "standard ota FAILED"; exit 1; }
token; run ota "$SECOND" "$TAG" "$OTAR" "" "$GHR" debloat || { echo "debloat ota FAILED"; exit 1; }

shred -u "$HOME/.gh_token_master" 2>/dev/null || rm -f "$HOME/.gh_token_master"
rm -f "$HOME/.gh_token"
echo "chain done $(date -u): both variants published together under $TAG, VM kept"
CHAIN
  gcloud_ compute scp --quiet "$tmpd/doha-remote.sh" "$VM:doha-remote.sh" >/dev/null
  gcloud_ compute scp --quiet "$tmpd/doha-chain.sh" "$VM:doha-chain.sh" >/dev/null
  printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$VM" --command 'umask 077; cat > ~/.gh_token_master'
  gcloud_ compute ssh "$VM" --command "chmod +x \$HOME/doha-chain.sh; tmux kill-session -t publish 2>/dev/null; tmux new-session -d -s publish \"REPO='$REPO' BRANCH='$BRANCH' VARIANT='$VARIANT' SESS='$SESSION' SYNC='$SYNC_JOBS' SWAP='$SWAP_GB' JOBS_='$JOBS' DEPTH='${REPO_DEPTH:-}' TAG='${TAG:-}' GHR='$GH_REPO' OTAR='$OTA_REPO' FIRST='$first' \$HOME/doha-chain.sh\"; sleep 2; tmux ls; tail -n 3 \$HOME/doha-chain.log 2>/dev/null || true"
  echo "auto-finish: chain runs in tmux 'publish' on $VM; log: $VM:~/doha-chain.log"
  echo "auto-finish: builds $([ "$first" = 1 ] && echo debloat || echo standard), then $([ "$first" = 1 ] && echo standard || echo debloat), and publishes both in one release; the VM is not deleted" ;;

setup)
  remote_exec setup
  # Remember which account owns the build state: `logs`, `state` and `finish`
  # then keep working after the local username changes (see resolve_vuser).
  gcloud_ compute instances add-metadata "$NAME" --metadata=doha-build-user="$VUSER" >/dev/null
  echo "build state owner: $VUSER (recorded in $NAME metadata; VUSER=... overrides)" ;;
state|verify) remote_exec "$1" ;;

att)    gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" -- tmux attach -t "$SESSION" ;;
# Two traps here, both of which look like "the build died": a wrong account has
# an empty home, so the file is simply not there; and ssh only flushes a remote
# command's output when that command exits, so `tail -f` prints nothing while the
# build runs. Read by byte offset with short-lived commands instead, and say
# which account was tried when the log is missing.
logs)
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  size=$(gcloud_ compute ssh "$VM" --command 'wc -c < $HOME/build.log 2>/dev/null || echo x' 2>/dev/null | tr -d '[:space:]')
  case ${size:-} in ''|*[!0-9]*)
    echo "no build.log in the home of $VUSER on $NAME: run with VUSER=<account that ran setup>" >&2
    exit 1 ;;
  esac
  # Start ~8 KB back so there is context, without dumping a 12 MB log.
  off=$(( size > 8192 ? size - 8192 : 0 ))
  first=1
  echo "following $VM:~/build.log ($size bytes); Ctrl-C stops following, the build keeps running" >&2
  while :; do
    gcloud_ compute ssh "$VM" --command "tail -c +$((off + 1)) \$HOME/build.log" > "$tmp" 2>/dev/null || true
    n=$(wc -c < "$tmp")
    if [ "$n" -gt 0 ]; then
      # Count what was copied, not what is printed: the log grows during the
      # copy, so the next offset comes from the bytes received.
      off=$(( off + n ))
      if [ "$first" = 1 ] && [ "$off" -gt "$n" ]; then
        sed '1d' "$tmp"    # started mid-line 8 KB back: drop the fragment
      else
        cat "$tmp"
      fi
      first=0
    fi
    sleep 10
  done ;;
ssh)    gcloud_ compute ssh "$VM" ;;
fetch)  mkdir -p "$OUT"; gcloud_ compute scp --recurse "$VM:/mnt/build/zips/*" "$OUT/"; echo "fetched into $OUT" ;;
delete) delete_instance ;;

*)      sed -n '2,26p' "$0"; exit 1 ;;
esac
