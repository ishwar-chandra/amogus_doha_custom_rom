#!/usr/bin/env bash
# Build amogus_doha on a Google Cloud VM, back the expensive parts up to
# Google Drive, and publish the result as a GitHub release. Nothing here
# needs to run on your own machine except this script itself.
#
#   tools/gcp-build.sh create     create the instance
#   tools/gcp-build.sh config     copy your local rclone.conf to the VM
#   tools/gcp-build.sh setup      install build deps in the VM, clone the recipe
#   tools/gcp-build.sh build      start the build in a tmux session on the VM
#   tools/gcp-build.sh att        attach to that tmux session
#   tools/gcp-build.sh logs       follow the build log (no tmux needed)
#   tools/gcp-build.sh state      is the build running/finished, and its exit code
#   tools/gcp-build.sh finish     wait for the build, verify, back up, release,
#                                 then delete the VM. This is the normal end.
#   tools/gcp-build.sh backup     mirror .repo, ccache, zips to Drive
#   tools/gcp-build.sh restore    pull them back into a fresh VM
#   tools/gcp-build.sh check      compare local .repo/ccache against Drive
#   tools/gcp-build.sh release    publish zips/ as a GitHub release (no VM delete)
#   tools/gcp-build.sh fetch      copy the finished zip and images here
#   tools/gcp-build.sh ssh        open a shell in the VM
#   tools/gcp-build.sh delete     tear the instance down now
#
# The build runs inside tmux on the VM, so losing the SSH connection (or
# this machine sleeping) does not touch it, and an exit-code file marks
# completion for `finish` to read.
#
# What is backed up, and why only that:
#
#   src/.repo  the bare git objects for all ~1280 projects. Immutable once
#              fetched, so rclone uploads only what is new. Restoring it and
#              letting `repo sync` re-create the worktrees means no download
#              and no broken file modes or symlinks -- Google Drive has
#              neither, so copying the checked-out tree (400 GB, mostly
#              regenerable) would restore into something that cannot build.
#   ccache     content-addressed, so also immutable and incremental.
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
# Publishing needs a GitHub token here (not gh): export GH_TOKEN=... . The
# token is piped to the VM for the upload and removed afterwards; gh itself
# is installed on the VM, which is also where the zip already is, so the
# release upload runs from Google's network.
#
# Environment (all optional):
#   PROJECT   GCP project          (default: customrom-514215)
#   ZONE      zone                 (default: asia-south1-a, closest to India)
#   NAME      instance name        (default: crdroid-build)
#   MACHINE   machine type         (default: n2-custom-12-98304, 12 vCPU/96 GB)
#   DISK      boot disk size       (default: 500GB, holds the sources)
#   HOURS     hard stop for the VM (default: 24; 0 disables it). `finish`
#                                   deletes the VM much sooner; this only
#                                   catches a VM left running by accident.
#   VARIANT   build variant        (default: userdebug, see build.sh)
#   REPO      recipe repo          (default: this fork)
#   BRANCH    branch to build      (default: crdroid-android-17)
#   OUT       where fetch puts it  (default: ./gcp-out)
#   RCLONE_REMOTE / RCLONE_PATH    (default: gdrive / amogus-doha)
#   GH_REPO   repo to publish to   (default: ishwar-chandra/amogus_doha_custom_rom)
#   TAG       release tag          (default: crdroid-<date>)
#   NO_RELEASE=1 / NO_DELETE=1     for `finish`
set -euo pipefail

PROJECT=${PROJECT:-customrom-514215}
ZONE=${ZONE:-asia-south1-a}
NAME=${NAME:-crdroid-build}
MACHINE=${MACHINE:-n2-custom-12-98304}
DISK=${DISK:-500GB}
HOURS=${HOURS:-24}
VARIANT=${VARIANT:-userdebug}
REPO=${REPO:-https://github.com/ishwar-chandra/amogus_doha_custom_rom.git}
BRANCH=${BRANCH:-crdroid-android-17}
OUT=${OUT:-$PWD/gcp-out}
SSD=/mnt/ssd
SESSION=doha
RCLONE_REMOTE=${RCLONE_REMOTE:-gdrive}
RCLONE_PATH=${RCLONE_PATH:-amogus-doha}
CCACHE_MAX=${CCACHE_MAX:-50G}
GH_REPO=${GH_REPO:-ishwar-chandra/amogus_doha_custom_rom}
TAG=${TAG:-crdroid-$(date +%Y%m%d)}

gcloud_() { gcloud --project "$PROJECT" --zone "$ZONE" "$@"; }

# Run a mode-specific script inside the VM. $1 is the mode; a few settings
# follow as arguments because the heredoc is quoted.
remote_exec() {
  gcloud_ compute ssh "$NAME" --command \
    "bash -s -- '$1' '$REPO' '$BRANCH' '$SSD' '$RCLONE_REMOTE' '$RCLONE_PATH' '$CCACHE_MAX' '$VARIANT' '$SESSION'" \
    <<'REMOTE'
set -euo pipefail
MODE=$1 REPO=$2 BRANCH=$3 SSD=$4 RCLONE_REMOTE=$5 RCLONE_PATH=$6
CCACHE_MAX=$7 VARIANT=$8 SESSION=$9
LOG=$SSD/build.log RLOG=$SSD/rclone.log EXIT=$SSD/build.exit

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

need_rclone() {
  command -v rclone >/dev/null && return
  curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null
}
need_gh() {
  command -v gh >/dev/null && return
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh >/dev/null 2>&1 && return
  ( cd /tmp && curl -fsSL -o gh.tgz \
      "https://github.com/cli/cli/releases/latest/download/gh_$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep -o '"tag_name": *"v[^"]*' | cut -d'"' -f4 | tr -d v)_linux_amd64.tar.gz" \
    && tar xzf gh.tgz && sudo install -m755 gh_*/bin/gh /usr/local/bin/gh )
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
      squashfs-tools xsltproc zip zlib1g-dev tmux openjdk-21-jdk-headless python3
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

build)
  # Written to a file rather than passed through tmux's shell to keep the
  # quoting honest, and so `att` shows something readable in scrollback.
  cat > "$SSD/run-build.sh" <<'EOS'
#!/bin/bash
# Started by tools/gcp-build.sh inside tmux. Sets the exit-code marker
# that `finish` waits for, whatever happens.
set -o pipefail
SSD=${SSD:-/mnt/ssd}
cd "$SSD/manifest" || exit 90
export PATH="$HOME/bin:$PATH"
export CCACHE_DIR="$SSD/ccache" ZIP_DIR="$SSD/zips"
export JOBS=${JOBS:-$(nproc)} VARIANT=${VARIANT:-userdebug}
rm -f "$SSD/build.exit"
./build.sh "$SSD/src"
code=$?
echo "$code" > "$SSD/build.exit"
echo "--- build.sh exited $code ---"
EOS
  chmod +x "$SSD/run-build.sh"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$EXIT"
  tmux new-session -d -s "$SESSION" "SSD='$SSD' VARIANT='$VARIANT' '$SSD/run-build.sh' 2>&1 | tee '$LOG'"
  sleep 3
  tmux ls
  echo "started in tmux session '$SESSION'; log: $LOG"
  ;;

state)
  if [ -f "$EXIT" ]; then echo "finished exit=$(cat "$EXIT")"; else echo "running (no $EXIT yet)"; fi
  tmux ls 2>/dev/null || echo "no tmux sessions"
  tail -n 3 "$LOG" 2>/dev/null || true
  ;;

verify)
  fail=0
  zips=$(ls "$SSD/zips"/crDroidAndroid-*.zip 2>/dev/null || true)
  [ -n "$zips" ] || { echo "no crDroidAndroid-*.zip in $SSD/zips"; fail=1; }
  for f in boot dtbo vbmeta; do
    ls "$SSD/zips"/*-"$f".img >/dev/null 2>&1 || { echo "missing *-$f.img"; fail=1; }
  done
  if [ "$fail" = 0 ]; then
    ( cd "$SSD/zips" && sha256sum -c ./*.sha256sum ) || fail=1
  fi
  [ "$fail" = 0 ] && echo "artifacts ok: $(ls "$SSD/zips" | tr '\n' ' ')"
  exit "$fail"
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
  echo "restored $(du -sh "$SSD/src/.repo" | cut -f1) of .repo. Next: build"
  echo "(build.sh runs repo init/sync against these local objects, so the"
  echo " worktrees come back without downloading anything)"
  ;;

check)
  need_rclone
  rclone_ check --size-only "$SSD/src/.repo" "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo"
  rclone_ check --size-only "$SSD/ccache"    "$RCLONE_REMOTE:$RCLONE_PATH/ccache"
  ;;

release)
  need_gh
  [ -s "$HOME/.gh_token" ] || { echo "no ~/.gh_token on the VM" >&2; exit 1; }
  export GH_TOKEN=$(cat "$HOME/.gh_token")
  tag=$1 repo=$2
  notes="Built on Google Cloud (as mentioned in TODO.md): $VARIANT, device amogus_doha, manifest branch $BRANCH.
Artifacts are the flashable zip, boot/dtbo/vbmeta images and the sha256sum file."
  gh release create "$tag" --repo "$repo" --target "$BRANCH" \
     --title "$tag" --notes "$notes" "$SSD/zips"/* && \
    rm -f "$HOME/.gh_token"
  echo "published $tag to $repo"
  ;;

*)
  echo "unknown mode: $MODE" >&2; exit 1 ;;
esac
REMOTE
}

case "${1:-}" in
create)
  extra=()
  [ "$HOURS" != 0 ] && extra=(--max-run-duration="$((HOURS * 3600))s" --instance-termination-action=DELETE)
  gcloud compute instances create "$NAME" \
    --machine-type "$MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --boot-disk-size "$DISK" --boot-disk-type pd-balanced \
    --local-ssd interface=nvme,size=375gb \
    "${extra[@]}" --scopes cloud-platform
  echo
  echo "Created $NAME ($MACHINE${extra:+ , hard stop in ${HOURS}h}). Next: config, setup, build, finish"
  ;;

config)
  CONF=${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}
  [ -f "$CONF" ] || { echo "No $CONF. Run 'rclone config' first (new remote, type drive, name gdrive)." >&2; exit 1; }
  gcloud_ compute scp "$CONF" "$NAME:/tmp/rclone.conf"
  gcloud_ compute ssh "$NAME" --command 'umask 077; mkdir -p ~/.config/rclone && mv /tmp/rclone.conf ~/.config/rclone/rclone.conf; command -v rclone >/dev/null || curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null; rclone lsd gdrive: | head'
  ;;

setup|build|backup|restore|check|state|verify)
  remote_exec "$1"
  ;;

release)
  # The zip is already on the VM and the upload runs from Google's network,
  # so only the token crosses over -- and is deleted right after.
  : "${GH_TOKEN:?export GH_TOKEN=<a token with repo scope> first}"
  printf '%s' "$GH_TOKEN" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
  remote_exec release "$TAG" "$GH_REPO"
  ;;

finish)
  # Normal end of a session: wait for the build, prove the artifacts are
  # good, back everything up, publish, and only then delete the VM.
  echo "waiting for the build (this can take hours; safe to leave running)"
  while :; do
    out=$(gcloud_ compute ssh "$NAME" --command "cat $SSD/build.exit 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')
    [ -n "$out" ] && break
    sleep 60
  done
  echo "build.sh exited $out"
  [ "$out" = 0 ] || { echo "build failed: VM kept, log at $NAME:$SSD/build.log" >&2; exit 1; }

  remote_exec verify
  remote_exec backup
  if [ "${NO_RELEASE:-0}" != 1 ]; then
    : "${GH_TOKEN:?export GH_TOKEN=<a token with repo scope> to publish, or NO_RELEASE=1}"
    printf '%s' "$GH_TOKEN" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
    remote_exec release "$TAG" "$GH_REPO"
  fi
  if [ "${NO_DELETE:-0}" != 1 ]; then
    gcloud compute instances delete "$NAME" --project "$PROJECT" --zone "$ZONE" --quiet
    echo "deleted $NAME"
  else
    echo "NO_DELETE=1: $NAME left running"
  fi
  ;;

att)   gcloud_ compute ssh "$NAME" -- tmux attach -t "$SESSION" ;;
logs)  gcloud_ compute ssh "$NAME" --command "tail -f $SSD/build.log" ;;
ssh)   gcloud_ compute ssh "$NAME" ;;

fetch)
  mkdir -p "$OUT"
  gcloud_ compute scp --recurse "$NAME:$SSD/zips/*" "$OUT/"
  echo "fetched into $OUT"
  ;;

delete)
  gcloud compute instances delete "$NAME" --project "$PROJECT" --zone "$ZONE" --quiet
  ;;

*)
  sed -n '2,70p' "$0"
  exit 1
  ;;
esac
