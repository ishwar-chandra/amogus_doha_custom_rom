#!/usr/bin/env bash
# Build amogus_doha on a Google Cloud VM, back the expensive parts up to
# Google Drive, and publish the result as a GitHub release.
#
# The VM is sized per phase, because a repo sync is a download: it pegs the
# network, not the CPU, so paying for 12 vCPUs through it is waste. `create`
# makes a small instance for the sync; `grow` resizes it in place for the
# compile, where the cores are actually used. The boot disk is the
# persistent part, so nothing is copied and no egress is paid.
#
#   tools/gcp-build.sh create     small instance (SYNC_MACHINE) + big disk
#   tools/gcp-build.sh config     copy your local rclone.conf to the VM
#   tools/gcp-build.sh setup      install build deps in the VM, clone the recipe
#   tools/gcp-build.sh build      start the build in a tmux session on the VM
#   tools/gcp-build.sh wait       stop when the sync phase is done (see below)
#   tools/gcp-build.sh grow       resize to MACHINE for the compile
#   tools/gcp-build.sh shrink     resize back to SYNC_MACHINE
#   tools/gcp-build.sh att        attach to the tmux session
#   tools/gcp-build.sh logs       follow the build log (no tmux needed)
#   tools/gcp-build.sh state      running/finished, exit code, phase
#   tools/gcp-build.sh gh-check   preflight the GitHub token (run this before
#                                 a build, not after -- see the token note)
#   tools/gcp-build.sh finish     wait, verify, back up, release, then delete
#   tools/gcp-build.sh backup     mirror .repo, ccache, zips to Drive
#   tools/gcp-build.sh restore    pull them back into a fresh VM
#   tools/gcp-build.sh check      compare local .repo/ccache against Drive
#   tools/gcp-build.sh release    publish zips/ as a GitHub release
#   tools/gcp-build.sh fetch      copy the finished zip and images here
#   tools/gcp-build.sh ssh        open a shell in the VM
#   tools/gcp-build.sh delete     tear the instance down now
#
# Typical first session:
#
#   create; config; setup; build
#   wait          # ~1-2 h, on the cheap machine: repo sync finishes here
#   grow          # stop/resize/start; the disk keeps the synced tree
#   finish        # wait out the compile, verify, back up, release, delete
#
# `grow` works because nothing lives on a local SSD: the sources, out/ and
# ccache are all on the boot disk, whose size is what DISK controls.
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
# out/ is deliberately not backed up: regenerable intermediates, and the
# biggest thing in the tree.
#
# backup mirrors with `rclone sync`, so a file deleted locally is deleted on
# Drive too. That is what keeps .repo from accumulating stale packs. Two
# limits to plan around: Drive accepts ~750 GB of uploads per account per
# day, and egress from GCP is billed (~180 GB out of asia-south1 is roughly
# $20), which is worth more than the idle cores saved above -- so do the
# first backup once, and prefer `restore` over re-syncing afterwards.
#
# Publishing needs a GitHub token here (not gh): export GH_TOKEN=... . The
# token is piped to the VM for the upload and removed afterwards; gh itself
# is installed on the VM, which is also where the zip already is, so the
# release upload runs from Google's network.
#
# Environment (all optional):
#   PROJECT       GCP project      (default: customrom-514215)
#   ZONE          zone             (default: asia-south1-a)
#   NAME          instance name    (default: crdroid-build)
#   SYNC_MACHINE  sync phase       (default: e2-standard-4, ~$0.15/h)
#   MACHINE       compile phase    (default: n2-custom-12-98304)
#   DISK          boot disk size   (default: 400GB -- sources, out/, ccache)
#   DISK_TYPE     boot disk type   (default: pd-standard; pd-balanced needs
#                                   the SSD_TOTAL_GB increase to land first)
#   HOURS         hard stop        (default: 24; 0 disables)
#   VARIANT       build variant    (default: userdebug, see build.sh)
#   SYNC_JOBS     repo sync jobs   (default: nproc; build.sh uses 4 to avoid
#                                   android.googlesource's 429s, which this
#                                   VM talks to over Google's own network)
#   REPO / BRANCH / OUT / RCLONE_REMOTE / RCLONE_PATH / GH_REPO / TAG
#   NO_RELEASE=1 / NO_DELETE=1     for `finish`
set -euo pipefail

PROJECT=${PROJECT:-customrom-514215}
ZONE=${ZONE:-asia-south1-a}
NAME=${NAME:-crdroid-build}
# Sizing, against the README's own numbers (it builds with 30 GB RAM plus a
# 72 GB swap file, and Soong's analysis is the peak at ~100 GB):
#   12 vCPU        the CPUS_ALL_REGIONS quota cap for this project
#   64 GB RAM      + 48 GB swap = 112 GB, the same headroom, but RAM is the
#                  expensive part ($0.005/GB/h); 96 GB of pure RAM was
#                  paying for memory the swap file covers for a fifth of it
#   400 GB disk    the shallow path needs ~255 GB (sources ~85, out/ ~120,
#                  ccache up to 50, zips ~2), so this leaves >100 GB of
#                  breathing room; disk is the cheap resource (~$0.04/GB/
#                  month, half a cent per 100 GB per hour). A full-history
#                  fallback wants DISK=500GB.
#   4 vCPU sync    only worth it if you deliberately set SYNC_MACHINE --
#                  a sync is network-bound, so a small box is enough. Left
#                  equal to MACHINE by default, since idle cores cost less
#                  than the stop/start dance.
MACHINE=${MACHINE:-n2-custom-12-65536}
SYNC_MACHINE=${SYNC_MACHINE:-$MACHINE}
DISK=${DISK:-400GB}
DISK_TYPE=${DISK_TYPE:-pd-standard}
# mka's -j must come from the *build* machine, not from whatever nproc says
# at launch time: build.sh would otherwise compute 4 on a small sync
# machine and compile with -j4 after being grown to 12 vCPUs.
# Parsed from MACHINE (n2-custom-12-65536 -> 12).
case "$MACHINE" in
  *-custom-*) JOBS_BUILD=${JOBS_BUILD:-$(printf '%s' "$MACHINE" | sed -n 's/.*-custom-\([0-9]*\)-.*/\1/p')} ;;
  *)          JOBS_BUILD=${JOBS_BUILD:-$(printf '%s' "$MACHINE" | sed -n 's/.*-\([0-9]*\)$/\1/p')} ;;
esac
JOBS_BUILD=${JOBS_BUILD:-12}
# Swap file on the boot disk. 48 GB, created by setup and re-enabled by the
# build script, because swap does not survive a stop/start.
SWAP_GB=${SWAP_GB:-48}
HOURS=${HOURS:-24}
VARIANT=${VARIANT:-userdebug}
SYNC_JOBS=${SYNC_JOBS:-nproc}
# Shallow clone: ~15-25 GB instead of ~100 GB of history, and a much
# smaller .repo for the Drive backup. Set REPO_DEPTH= (empty) for a full
# history sync if a pinned commit cannot be fetched shallow.
REPO_DEPTH=${REPO_DEPTH-1}
REPO=${REPO:-https://github.com/ishwar-chandra/amogus_doha_custom_rom.git}
BRANCH=${BRANCH:-crdroid-android-17}
OUT=${OUT:-$PWD/gcp-out}
SESSION=doha
RCLONE_REMOTE=${RCLONE_REMOTE:-gdrive}
RCLONE_PATH=${RCLONE_PATH:-amogus-doha}
CCACHE_MAX=${CCACHE_MAX:-50G}
GH_REPO=${GH_REPO:-ishwar-chandra/amogus_doha_custom_rom}
TAG=${TAG:-crdroid-$(date +%Y%m%d)}

# --project/--zone have to follow the subcommand, so they are appended
# rather than prefixed. Anything taking a `-- command` tail (ssh, scp)
# must not use this wrapper.
gcloud_() { gcloud "$@" --project "$PROJECT" --zone "$ZONE"; }

instance_status() {
  gcloud compute instances describe "$NAME" --project "$PROJECT" --zone "$ZONE" \
    --format='value(status)' 2>/dev/null || echo MISSING
}

# The release upload needs a token that can create releases and upload
# assets on GH_REPO. Reading it from a file means `finish` works from any
# shell, not just one where GH_TOKEN happened to be exported.
TOKEN_FILE=${TOKEN_FILE:-$HOME/.config/crdroid-gh-token}
resolve_token() {
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return 0; fi
  if [ -s "$TOKEN_FILE" ]; then tr -d '\n[:space:]' < "$TOKEN_FILE"; return 0; fi
  cat >&2 <<EOF
No GitHub token found (GH_TOKEN unset, $TOKEN_FILE missing).

Create one: https://github.com/settings/tokens
  Fine-grained token -> Repository access: only $GH_REPO
                     -> Permissions: Contents = Read and write
  (a classic token with the 'repo' scope also works)

Then either export it in this shell, or save it once:
  mkdir -p "$(dirname "$TOKEN_FILE")"
  printf '%s' 'github_pat_...' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

Verify with: tools/gcp-build.sh gh-check
EOF
  return 1
}

# Run a mode-specific script inside the VM. $1 is the mode; a few settings
# follow as arguments because the heredoc is quoted.
remote_exec() {
  gcloud_ compute ssh "$NAME" --command \
    "bash -s -- '$1' '$REPO' '$BRANCH' '$RCLONE_REMOTE' '$RCLONE_PATH' '$VARIANT' '$SESSION' '$SYNC_JOBS' '$CCACHE_MAX' '$SWAP_GB'" \
    <<'REMOTE'
set -euo pipefail
MODE=$1 REPO=$2 BRANCH=$3 RCLONE_REMOTE=$4 RCLONE_PATH=$5
VARIANT=$6 SESSION=$7 SYNC_JOBS=$8 CCACHE_MAX=$9
SWAP_GB=${10}
SRC=$HOME/src MANIFEST=$HOME/manifest ZIPS=$HOME/zips CCACHE=$HOME/.ccache
LOG=$HOME/build.log RLOG=$HOME/rclone.log EXIT=$HOME/build.exit

# RAM is the expensive resource, so Soong's ~100 GB analysis peak is covered
# partly by swap; the README's own build machine uses 30 GB RAM + 72 GB swap.
ensure_swap() {
  local f=$HOME/swap
  if [ ! -e "$f" ]; then
    fallocate -l "${SWAP_GB}G" "$f" 2>/dev/null ||
      dd if=/dev/zero of="$f" bs=1M count=$((SWAP_GB * 1024)) status=none
    chmod 600 "$f"
    sudo mkswap "$f" >/dev/null
  fi
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$f" ||
    sudo swapon "$f" 2>/dev/null || true
}

need_rclone() {
  command -v rclone >/dev/null && return
  curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null
}
need_gh() {
  command -v gh >/dev/null && return
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y gh >/dev/null 2>&1 && return
  ( cd /tmp && v=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest |
      sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p') \
    && curl -fsSL -o gh.tgz "https://github.com/cli/cli/releases/download/v$v/gh_${v}_linux_amd64.tar.gz" \
    && tar xzf gh.tgz && sudo install -m755 gh_*/bin/gh /usr/local/bin/gh )
}
# Drive is slow per small file, so use many parallel transfers and big
# chunks; --fast-list saves listing round trips.
rclone_() {
  rclone --fast-list --transfers 16 --checkers 32 --drive-chunk-size 128M \
         --stats 60s --stats-one-line --log-file "$RLOG" "$@"
}
# Sample hooks are ~15 files per project and are never used.
EXCLUDES=(--exclude "/**/hooks/*.sample")

case "$MODE" in

setup)
  if [ ! -x "$HOME/.deps-installed" ]; then
    # A fresh image runs unattended-upgrades at boot, which holds the dpkg
    # lock; wait for it instead of failing the whole setup.
    sudo apt-get -o DPkg::Lock::Timeout=900 update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y \
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
    grep -q 'HOME/bin' "$HOME/.profile" || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
  fi

  mkdir -p "$SRC" "$ZIPS" "$CCACHE"
  ensure_swap
  if [ ! -d "$MANIFEST/.git" ]; then
    git clone -b "$BRANCH" "$REPO" "$MANIFEST"
  fi
  echo "setup done: $(nproc) cpus, $(free -g | sed -n '2s/.* \([0-9]*\)$/\1/p') GiB RAM, swap $(swapon --show=SIZE --noheadings | tr -d ' ')"
  ;;

build)
  cat > "$HOME/run-build.sh" <<'EOS'
#!/bin/bash
# Started by tools/gcp-build.sh inside tmux; writes the exit-code marker
# that `finish` waits for, whatever happens.
set -o pipefail
# Swap lives on the boot disk, which survives a stop/start, but the active
# swap device does not, so re-enable it here rather than trusting setup.
swapon --show=NAME --noheadings 2>/dev/null | grep -q . ||
  sudo swapon "$HOME/swap" 2>/dev/null || true
cd "$HOME/manifest" || exit 90
export PATH="$HOME/bin:$PATH"
export CCACHE_DIR="$HOME/.ccache" ZIP_DIR="$HOME/zips"
export JOBS=${JOBS:-$(nproc)} VARIANT=${VARIANT:-userdebug}
export REPO_DEPTH="${REPO_DEPTH:-}"
export SYNC_JOBS=${SYNC_JOBS:-$(nproc)}
rm -f "$HOME/build.exit"
./build.sh "$HOME/src"
code=$?
echo "$code" > "$HOME/build.exit"
echo "--- build.sh exited $code ---"
EOS
  chmod +x "$HOME/run-build.sh"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  # Killing the session is not always enough for repo, which keeps its own
  # process tree; a leftover sync would fight the new one over the same
  # .repo, so stop it explicitly. repo sync resumes where it left off.
  pkill -f "repo/main.py" 2>/dev/null || true
  sleep 2
  rm -f "$EXIT"
  tmux new-session -d -s "$SESSION" \
    "VARIANT='$VARIANT' SYNC_JOBS='$SYNC_JOBS' JOBS='$JOBS_BUILD' REPO_DEPTH='$REPO_DEPTH' '$HOME/run-build.sh' 2>&1 | tee '$LOG'"
  sleep 3
  tmux ls
  echo "started in tmux session '$SESSION'; log: $LOG"
  ;;

phase)
  # Has the sync finished and the compile started? build.sh prints these.
  if [ -f "$EXIT" ]; then
    echo "finished exit=$(cat "$EXIT")"
  elif [ -n "$(tmux ls 2>/dev/null)" ]; then
    if grep -q "breakfast\|mka \|Starting build" "$LOG" 2>/dev/null; then
      echo "compiling"
    else
      echo "syncing"
    fi
  else
    echo "idle (no tmux session, no exit file)"
  fi
  ;;

state)
  [ -f "$EXIT" ] && echo "exit=$(cat "$EXIT")" || echo "no exit file yet"
  tail -n 3 "$LOG" 2>/dev/null || true
  ;;

verify)
  fail=0
  ls "$ZIPS"/crDroidAndroid-*.zip >/dev/null 2>&1 || { echo "no crDroidAndroid-*.zip in $ZIPS"; fail=1; }
  for f in boot dtbo vbmeta; do
    ls "$ZIPS"/*-"$f".img >/dev/null 2>&1 || { echo "missing *-$f.img"; fail=1; }
  done
  [ "$fail" = 0 ] && { ( cd "$ZIPS" && sha256sum -c ./*.sha256sum ) || fail=1; }
  [ "$fail" = 0 ] && echo "artifacts ok: $(ls "$ZIPS" | tr '\n' ' ')"
  exit "$fail"
  ;;

backup)
  need_rclone
  mkdir -p "$CCACHE"
  rclone_ sync "$SRC/.repo" "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo" "${EXCLUDES[@]}"
  rclone_ sync "$CCACHE"    "$RCLONE_REMOTE:$RCLONE_PATH/ccache" "${EXCLUDES[@]}"
  rclone_ sync "$ZIPS"      "$RCLONE_REMOTE:$RCLONE_PATH/zips"
  rclone_ sync "$MANIFEST"  "$RCLONE_REMOTE:$RCLONE_PATH/manifest"
  du -sh "$SRC/.repo" "$CCACHE" "$ZIPS"
  echo "backup done (log: $RLOG)"
  ;;

restore)
  need_rclone
  mkdir -p "$SRC" "$ZIPS" "$CCACHE"
  rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo" "$SRC/.repo" "${EXCLUDES[@]}"
  rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/ccache"    "$CCACHE" "${EXCLUDES[@]}"
  rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/zips"      "$ZIPS"
  [ -d "$MANIFEST/.git" ] || \
    rclone_ sync "$RCLONE_REMOTE:$RCLONE_PATH/manifest" "$MANIFEST"
  echo "restored $(du -sh "$SRC/.repo" | cut -f1) of .repo. Next: build"
  echo "(build.sh runs repo init/sync against these local objects, so the"
  echo " worktrees come back without downloading anything)"
  ;;

check)
  need_rclone
  rclone_ check --size-only "$SRC/.repo" "$RCLONE_REMOTE:$RCLONE_PATH/src/.repo"
  rclone_ check --size-only "$CCACHE"    "$RCLONE_REMOTE:$RCLONE_PATH/ccache"
  ;;

release)
  need_gh
  [ -s "$HOME/.gh_token" ] || { echo "no ~/.gh_token on the VM" >&2; exit 1; }
  export GH_TOKEN=$(cat "$HOME/.gh_token")
  tag=$1 repo=$2
  notes="Unofficial crDroid 13 (Android 17) for the Moto G8 Plus (amogus_doha), built on Google Cloud. Variant: $VARIANT; manifest branch: $BRANCH.
Artifacts: flashable zip, boot/dtbo/vbmeta images, sha256sum."
  gh release create "$tag" --repo "$repo" --target "$BRANCH" \
     --title "$tag" --notes "$notes" "$ZIPS"/* && rm -f "$HOME/.gh_token"
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
  gcloud_ compute instances create "$NAME" \
    --machine-type "$SYNC_MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --boot-disk-size "$DISK" --boot-disk-type "$DISK_TYPE" \
    "${extra[@]}" --scopes cloud-platform
  echo
  echo "Created $NAME as $SYNC_MACHINE (sync phase). Next: config, setup, build, wait, grow"
  ;;

grow)
  [ "$(instance_status)" = TERMINATED ] || gcloud_ compute instances stop "$NAME"
  gcloud_ compute instances set-machine-type "$NAME" --machine-type "$MACHINE"
  gcloud_ compute instances start "$NAME"
  echo "resized to $MACHINE for the compile (disk and everything on it kept)"
  ;;

shrink)
  [ "$(instance_status)" = TERMINATED ] || gcloud_ compute instances stop "$NAME"
  gcloud_ compute instances set-machine-type "$NAME" --machine-type "$SYNC_MACHINE"
  gcloud_ compute instances start "$NAME"
  echo "resized back to $SYNC_MACHINE"
  ;;

config)
  CONF=${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}
  [ -f "$CONF" ] || { echo "No $CONF. Run 'rclone config' first (new remote, type drive, name gdrive)." >&2; exit 1; }
  gcloud_ compute scp "$CONF" "$NAME:/tmp/rclone.conf"
  gcloud_ compute ssh "$NAME" --command 'umask 077; mkdir -p ~/.config/rclone && mv /tmp/rclone.conf ~/.config/rclone/rclone.conf; command -v rclone >/dev/null || curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null; rclone lsd gdrive: | head'
  ;;

setup|build|backup|restore|check|state|verify|phase)
  remote_exec "$1"
  ;;

gh-check)
  # Preflight, run before a build rather than after: a token that cannot
  # create releases should fail now, not once the zip exists.
  tok=$(resolve_token) || exit 1
  echo "token: ${tok:0:6}...${tok: -4} (${#tok} chars)"
  api=https://api.github.com
  hdr=(-H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json")
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' "${hdr[@]}" "$api/repos/$GH_REPO")
  if [ "$code" != 200 ]; then
    echo "FAIL: GET /repos/$GH_REPO -> $code"; sed -n 's/.*"message": *"\([^"]*\)".*/  \1/p' "$body"; rm -f "$body"; exit 1
  fi
  if ! python3 - "$body" "$GH_REPO" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
p=d.get('permissions',{})
print(f"repo: {sys.argv[2]} (default branch {d.get('default_branch')}, private={d.get('private')})")
print(f"token permissions: push={p.get('push')} admin={p.get('admin')}")
sys.exit(0 if p.get('push') else 1)
PY
  then
    echo "FAIL: token cannot push to this repo (needs Contents: Read and write)"
    rm -f "$body"; exit 1
  fi
  rm -f "$body"
  echo "--- release tag '$TAG' free?"
  tcode=$(curl -sS -o /dev/null -w '%{http_code}' "${hdr[@]}" "$api/repos/$GH_REPO/releases/tags/$TAG")
  case "$tcode" in
    404) echo "ok: no release for $TAG yet" ;;
    200) echo "NOTE: a release for $TAG already exists -- set TAG=... to a new one" ;;
    *)   echo "WARN: checking the tag returned $tcode" ;;
  esac
  echo "--- scopes (classic tokens only)"
  curl -sSI "${hdr[@]}" "$api/" | sed -n 's/^[Xx]-[Oo]Auth-[Ss]copes: */  /p' | tr -d '\r' || true
  echo "gh-check passed"
  ;;

wait)
  # Wait for the sync to finish so the VM can be grown for the compile.
  # Cheap: this phase is network-bound, so the small shape is enough.
  echo "waiting for the sync to finish (Ctrl-C is safe; the build keeps running)"
  while :; do
    st=$(remote_exec phase 2>/dev/null | tail -1)
    case "$st" in
      compiling|finished*) echo "sync done -> $st"; break ;;
      *) printf '.' ;;
    esac
    sleep 60
  done
  echo "next: tools/gcp-build.sh grow"
  ;;

release)
  # The zip is already on the VM and the upload runs from Google's network,
  # so only the token crosses over -- and is deleted right after.
  tok=$(resolve_token)
  printf '%s' "$tok" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
  remote_exec release "$TAG" "$GH_REPO"
  ;;

finish)
  # Normal end of a session: wait for the build, prove the artifacts are
  # good, back everything up, publish, and only then delete the VM.
  echo "waiting for the build (this can take hours; safe to leave running)"
  while :; do
    out=$(gcloud_ compute ssh "$NAME" --command "cat \$HOME/build.exit 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')
    [ -n "$out" ] && break
    sleep 60
  done
  echo "build.sh exited $out"
  [ "$out" = 0 ] || { echo "build failed: VM kept, log on $NAME:~/build.log" >&2; exit 1; }

  remote_exec verify
  remote_exec backup
  if [ "${NO_RELEASE:-0}" != 1 ]; then
    tok=$(resolve_token)
    printf '%s' "$tok" | gcloud_ compute ssh "$NAME" --command 'umask 077; cat > ~/.gh_token'
    remote_exec release "$TAG" "$GH_REPO"
  fi
  if [ "${NO_DELETE:-0}" != 1 ]; then
    gcloud compute instances delete "$NAME" --project "$PROJECT" --zone "$ZONE" --quiet
    echo "deleted $NAME"
  else
    echo "NO_DELETE=1: $NAME left running"
  fi
  ;;

att)   gcloud compute ssh "$NAME" --project "$PROJECT" --zone "$ZONE" -- tmux attach -t "$SESSION" ;;
logs)  gcloud_ compute ssh "$NAME" --command "tail -f \$HOME/build.log" ;;
ssh)   gcloud_ compute ssh "$NAME" ;;

fetch)
  mkdir -p "$OUT"
  gcloud_ compute scp --recurse "$NAME:~/zips/*" "$OUT/"
  echo "fetched into $OUT"
  ;;

delete)
  gcloud compute instances delete "$NAME" --project "$PROJECT" --zone "$ZONE" --quiet
  ;;

*)
  sed -n '2,40p' "$0"
  exit 1
  ;;
esac
