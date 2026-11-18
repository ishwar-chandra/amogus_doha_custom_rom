#!/usr/bin/env bash
# Build amogus_doha on a Google Cloud VM and publish the result as a GitHub
# release. No Google Drive backup: the VM is disposable and every shipped
# artifact is copied to the GitHub release (and the OTA feed) before deletion.
#
# Local commands (they drive gcloud/ssh; the work happens on the VM):
#   create    the instance: MACHINE + local SSDs
#   setup     build deps in the VM, clone the recipe
#   build     start the build in a tmux session (sync, then compile)
#   gh-check  preflight the GitHub token -- run this before a build
#   finish    wait for the build, verify, release, update OTA, then delete
#   att|logs|state|ssh|fetch|delete
#   release                  publish zips/ as one GitHub release tag: every
#                            variant in zips/ (standard + debloat), creating the
#                            tag or adding to it if it already exists
#   ota <tag> <owner/repo>   write <channel>/doha.json to the OTA feed repo
#                            (--dry-run prints the JSON, publishes nothing)
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
# There is deliberately no stop/resize step: the working tree lives on
# local SSDs, which a stop/start would throw away. `delete` ends the billing.
#
# Environment (all optional):
#   PROJECT, ZONE, NAME
#   MACHINE       compile machine      (default: n2-custom-12-49152)
#   SYNC_MACHINE  separate sync box    (default: MACHINE)
#   DISK, DISK_TYPE                    boot disk only (default: 50GB, OS)
#   SWAP_GB       swap on the NVMe     (default: 32)
#   HOURS         hard stop            (default: 48; 0 disables)
#   VARIANT       userdebug|user|eng   (default: userdebug)
#   DEBLOAT       1 = same ROM without the optional crDroid extras; zip gets a
#                 -debloat suffix and needs its own TAG/channel (default: 0)
#   ADB_KEY       path to an adb public key on this machine; `build` copies
#                 it to the VM and bakes it in (build.sh's ADB_KEY), so adb
#                 works from the phone's first boot. Test builds only: the
#                 zip gets an -adbkey suffix and must never be distributed.
#   JOBS          compile jobs         (default: MACHINE's vCPUs)
#   SYNC_JOBS     repo sync jobs       (default: nproc)
#   REPO_DEPTH    shallow clone depth  (default: 1; empty = full history)
#   REPO, BRANCH, OUT, GH_REPO, OTA_REPO, TAG
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
# 12 vCPU is the project's CPUS_ALL_REGIONS cap. 64 GB RAM + 48 GB swap
# covers Soong's ~100 GB analysis peak; RAM is the expensive resource
# ($0.005/GB/h), so the swap file covers the top of the peak instead of
# paying for 96 GB of it. The 350 GB of NVMe (two 375 GB local SSDs -- N2
# takes them in pairs) is >100 GB more than the shallow path needs, and the
# boot disk stays small: it only holds the OS.
# CPUS_ALL_REGIONS is 12 on this project (the regional limit of 32 does not
# help: the global cap is what a create trips over), so 12 vCPU is the widest
# machine that can be created today. Raise the quota, then MACHINE=n2-custom-16-49152.
MACHINE=${MACHINE:-n2-custom-12-49152}
# GCP attaches local SSDs in multiples of two (0, 2, 4, 8, 16, 24); one
# is rejected by the API, so two is the smallest usable count.
SSD_COUNT=${SSD_COUNT:-2}
# DISK_MODE=local : local SSDs, fastest, billed for the whole 750 GB because GCP
#                   attaches them in pairs (0,2,4,8,16,24) - nothing smaller exists.
# DISK_MODE=pd    : no local SSD, one exactly-sized pd-ssd for the tree. Slower
#                   (about 0.5 MB/s of sustained throughput per GB) but no idle disk.
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
BRANCH=${BRANCH:-crdroid-android-17}
# Repo root, not $PWD: the script may be started from anywhere (tools/, or an
# absolute path), and the defaults must still point at this checkout.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

# The VM gets the token, uses it, and deletes it again -- one place, so
# `finish` and `release` cannot drift apart.
publish_release() {
  printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
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
  gcloud_ compute ssh "$NAME" --command \
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
# One 375 GB device holds the tree, ccache and swap (274 + 25 + 32 = 331 of 369).
# A second one is optional and only carries ccache + swap; SSD_COUNT=2 adds it.
CACHE=$([ -b /dev/nvme0n2 ] && echo /mnt/cache || echo "$BUILD/cache")
SRC=$BUILD/src MANIFEST=$BUILD/manifest ZIPS=$BUILD/zips CCACHE=$CACHE/ccache
LOG=$HOME/build.log EXIT=$HOME/build.exit

# The two local SSDs arrive blank, and fstab would fail a boot before setup
# formatted them, so they are mounted here, idempotently: a reboot keeps
# them, and reformatting would throw away a synced tree.
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
      echo "no local SSD and no /dev/disk/by-id/google-data: nothing to mount" >&2
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

ensure_swap() {
  local f=$CACHE/swap
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
BUGREPORT.md. Do not flash a zip from a different variant over this one without wiping data.
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

setup)  install_deps; ensure_swap
        mkdir -p "$SRC" "$ZIPS" "$CCACHE"
        [ -d "$MANIFEST/.git" ] || git clone -b "$BRANCH" "$REPO" "$MANIFEST"
        echo "setup done: $(nproc) cpus, $(free -g | awk 'NR==2{print $2}') GiB RAM, swap $(swapon --show=SIZE --noheadings | tr -d ' ')" ;;

build)
        ADB_KEY_BUILD=${1:-0}
        # The VM builds from its own clone of this recipe, so a change that was
        # not pushed never reaches it. Pull the branch first and say which
        # commit is being built; the caller checks for uncommitted work.
        if [ -d "$MANIFEST/.git" ]; then
          if git -C "$MANIFEST" fetch -q origin "$BRANCH" 2>/dev/null &&
             git -C "$MANIFEST" reset -q --hard "origin/$BRANCH" 2>/dev/null; then
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
# One 375 GB device holds the tree, ccache and swap (274 + 25 + 32 = 331 of 369).
# A second one is optional and only carries ccache + swap; SSD_COUNT=2 adds it.
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
          "$adb_env VARIANT='$VARIANT' DEBLOAT='$DEBLOAT_BUILD' SYNC_JOBS='$SYNC_JOBS' JOBS='$JOBS_BUILD' REPO_DEPTH='$REPO_DEPTH' '$HOME/run-build.sh' 2>&1 | tee '$LOG'"
        sleep 3; tmux ls
        echo "started in tmux '$SESSION'; log: $LOG" ;;

state)  [ -f "$EXIT" ] && echo "finished exit=$(cat "$EXIT")" || echo "no exit file yet"
        tmux ls 2>/dev/null || echo "no tmux session"
        tail -n 3 "$LOG" 2>/dev/null || true ;;

verify) fail=0 newest=""
        ls "$ZIPS"/crDroidAndroid-*.zip >/dev/null 2>&1 || { echo "no crDroidAndroid-*.zip in $ZIPS"; fail=1; }
        for f in boot dtbo vbmeta; do
          ls "$ZIPS"/"$f".img >/dev/null 2>&1 || { echo "missing $f.img"; fail=1; }
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
      case $channel in standard|debloat) ;; *) echo "bad OTA channel: $channel" >&2; exit 1 ;; esac
      prop=""
      for c in "$SRC/out/target/product/amogus_doha/system/build.prop" \
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
      base=$(basename "$zip")
      id=$(sha256sum "$zip" | cut -d' ' -f1)
      size=$(stat -c %s "$zip")
      body=$(printf '{\n  "response": [\n    {\n      "datetime": %s,\n      "filename": "%s",\n      "id": "%s",\n      "romtype": "%s",\n      "size": %s,\n      "url": "https://github.com/%s/releases/download/%s/%s",\n      "version": "%s"\n    }\n  ]\n}\n' \
             "${dt:-0}" "$base" "$id" "${rtype:-userdebug}" "$size" "$GH_REPO" "$TAG" "$base" "${ver:-13.1}")
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

case "${1:-}" in
create)
  extra=()
  [ "$HOURS" != 0 ] && extra=(--max-run-duration="$((HOURS * 3600))s" --instance-termination-action=DELETE)
  case "${SSD_COUNT:-2}" in
    0|2|4|8|16|24) ;;
    *) echo "SSD_COUNT=${SSD_COUNT:-2} is not allowed: GCP takes 0, 2, 4, 8, 16 or 24 local SSDs." >&2
       exit 1 ;;
  esac
  ssd=()
  if [ "$DISK_MODE" = local ]; then
    for _ in $(seq 1 "${SSD_COUNT:-2}"); do ssd+=(--local-ssd interface=nvme,size=375gb); done
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
  gcloud_ compute instances create "$NAME" \
    --machine-type "$SYNC_MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --boot-disk-size "$DISK" --boot-disk-type "$DISK_TYPE" \
    "${ssd[@]}" \
    --no-boot-disk-auto-delete \
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
    echo "Created $NAME ($SYNC_MACHINE, ${DATA_DISK_GB} GB $DATA_DISK_TYPE at /mnt/build). Next: config, setup, build"
  else
    echo "Created $NAME ($SYNC_MACHINE, ${SSD_COUNT:-2}x 375 GB NVMe). Next: config, setup, build"
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
  printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
  remote_exec ota "${TAG:-}" "$OTA_REPO" "${OTA_DRY:-}" "$GH_REPO" "$(ota_channel)" ;;
finish)
  echo "waiting for the build (hours; Ctrl-C is safe, the build keeps running)"
  while [ -z "$(gcloud_ compute ssh "$NAME" --command "cat \$HOME/build.exit 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')" ]; do
    sleep 60
  done
  code=$(gcloud_ compute ssh "$NAME" --command "cat \$HOME/build.exit" | tr -d '[:space:]')
  echo "build.sh exited $code"
  [ "$code" = 0 ] || { echo "build failed: VM kept, log at $NAME:~/build.log" >&2; exit 1; }
  remote_exec verify
  [ "${NO_RELEASE:-0}" = 1 ] || publish_release
  if [ "${NO_OTA:-0}" != 1 ] && [ "${NO_RELEASE:-0}" != 1 ]; then
    # The feed entry points at the release URL, so it has to come after it.
    printf '%s' "$(resolve_token)" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
    if ! remote_exec ota "${TAG:-}" "$OTA_REPO" "" "$GH_REPO" "$(ota_channel)"; then
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
    gcloud_ compute scp "$ADB_KEY" "$NAME:adbkey.pub" >/dev/null
    adb_arg=1
    echo "ADB_KEY: copied $(basename "$ADB_KEY") to $NAME, build gets -adbkey suffix"
  fi
  remote_exec build "$adb_arg"
  if [ "${AUTO_FINISH:-0}" = 1 ]; then
    echo "AUTO_FINISH=1: waiting for the build and releasing it"
    "$0" finish
  fi ;;

setup|state|verify) remote_exec "$1" ;;

att)    gcloud compute ssh "$NAME" --project "$PROJECT" --zone "$ZONE" -- tmux attach -t "$SESSION" ;;
logs)   gcloud_ compute ssh "$NAME" --command "tail -f \$HOME/build.log" ;;
ssh)    gcloud_ compute ssh "$NAME" ;;
fetch)  mkdir -p "$OUT"; gcloud_ compute scp --recurse "$NAME:/mnt/build/zips/*" "$OUT/"; echo "fetched into $OUT" ;;
delete) delete_instance ;;

*)      sed -n '2,26p' "$0"; exit 1 ;;
esac
