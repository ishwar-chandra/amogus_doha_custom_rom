#!/usr/bin/env bash
# Stream the build tree of the GCP VM to personal Google Drive, or bring it back
# onto a fresh VM, without touching tools/gcp-build.sh (the build/release chain).
#
#   tools/drive-backup.sh backup            # ccache + src-tree + out -> Drive
#   BACKUP_WAIT=1 tools/drive-backup.sh backup   # wait for an active build first
#   SKIP_OUT=1 tools/drive-backup.sh backup # skip out.tar.zst
#   tools/drive-backup.sh restore           # Drive -> a fresh VM
#   tools/drive-backup.sh status            # what is on Drive / is a job running
#
# The work runs inside tmux on the VM, so a dropped laptop connection cannot
# interrupt it. Each stream is `tar | zstd | rclone rcat`: no temporary archive
# on the NVMe, three API calls instead of two million, and POSIX modes,
# symlinks and mtimes are preserved (so ninja still sees an incremental tree).
#
#   RCLONE_CONF      local rclone.conf          (default: ~/.config/rclone/rclone.conf)
#   BACKUP_REMOTE    rclone target directory    (default: gdrive:doha-backup/crdroid-17.0)
#   BACKUP_WAIT=1    wait for tmux doha/publish to finish cleanly before uploading
#   SKIP_OUT=1       do not upload/restore out.tar.zst (clean out/ rebuild)
#   NAME/PROJECT/ZONE  VM to use (default: crdroid-build / customrom-514215 / asia-south1-a)
#
# Restoring needs the VM created and set up first:
#   tools/gcp-build.sh create && tools/gcp-build.sh setup
#   tools/drive-backup.sh restore
set -euo pipefail

PROJECT=${PROJECT:-customrom-514215}
ZONE=${ZONE:-asia-south1-a}
NAME=${NAME:-crdroid-build}
SESSION=doha
RCLONE_CONF=${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}
BACKUP_REMOTE=${BACKUP_REMOTE:-gdrive:doha-backup/crdroid-17.0}
SKIP_OUT=${SKIP_OUT:-0}
BACKUP_WAIT=${BACKUP_WAIT:-0}

gcloud_() { gcloud "$@" --project "$PROJECT" --zone "$ZONE"; }
instance_status() {
  gcloud compute instances describe "$NAME" --project "$PROJECT" --zone "$ZONE" \
    --format='value(status)' 2>/dev/null || echo MISSING
}

need_vm() {
  local s; s=$(instance_status)
  [ "$s" = RUNNING ] || { echo "$1: $NAME is $s" >&2; exit 1; }
  [ -s "$RCLONE_CONF" ] || { echo "$1: missing rclone config: $RCLONE_CONF" >&2; exit 1; }
  case $SKIP_OUT in 0|1) ;; *) echo "SKIP_OUT must be 0 or 1" >&2; exit 1 ;; esac
}

# Install rclone+zstd and the rclone config on the VM, then create the remote's
# parent directory. The config holds an OAuth token, so it is mode 600.
push_prereqs() {
  local tmpd=$1
  gcloud_ compute scp --quiet "$RCLONE_CONF" "$NAME:.rclone.conf.tmp" >/dev/null
  gcloud_ compute ssh "$NAME" --command "
    set -e
    mkdir -p ~/.config/rclone && mv ~/.rclone.conf.tmp ~/.config/rclone/rclone.conf
    chmod 600 ~/.config/rclone/rclone.conf
    if ! command -v rclone >/dev/null || ! command -v zstd >/dev/null; then
      sudo apt-get -o DPkg::Lock::Timeout=900 update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y -qq rclone zstd
    fi
    rclone lsd '${BACKUP_REMOTE%%:*}' >/dev/null
  " || { echo "prereqs failed: is the Drive remote authorised? try: rclone config reconnect ${BACKUP_REMOTE%%:*}" >&2; exit 1; }
}

case "${1:-}" in
backup)
  need_vm backup
  case $BACKUP_WAIT in 0|1) ;; *) echo "BACKUP_WAIT must be 0 or 1" >&2; exit 1 ;; esac
  tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
  cat > "$tmpd/doha-backup.sh" <<'BACKUP_SH'
#!/bin/bash
set -uo pipefail
exec >>"$HOME/backup.log" 2>&1
BUILD=/mnt/build
CACHE=$([ -b /dev/nvme0n2 ] && echo /mnt/cache || echo "$BUILD/cache")
DEST=${DEST:?missing DEST}
SKIP_OUT=${SKIP_OUT:-0}
BACKUP_WAIT=${BACKUP_WAIT:-0}
SESS=${SESS:-doha}
rm -f "$HOME/backup.exit"
fail() { echo "backup FAILED: $*"; echo 1 > "$HOME/backup.exit"; exit 1; }

echo "=== backup start $(date -u) dest=$DEST skip_out=$SKIP_OUT wait=$BACKUP_WAIT ==="
if tmux has-session -t "$SESS" 2>/dev/null || tmux has-session -t publish 2>/dev/null; then
  [ "$BACKUP_WAIT" = 1 ] ||
    fail "a build/publish tmux session is active; finish first or use BACKUP_WAIT=1"
  echo "waiting for active build/publish sessions to end..."
  while tmux has-session -t "$SESS" 2>/dev/null || tmux has-session -t publish 2>/dev/null; do
    sleep 60
  done
  if [ -f "$HOME/build.exit" ] && [ "$(cat "$HOME/build.exit")" != 0 ]; then
    fail "build exited $(cat "$HOME/build.exit"); refusing to back up a broken tree"
  fi
  echo "sessions finished $(date -u), starting backup"
fi

rclone mkdir "$DEST" || fail "rclone mkdir $DEST failed"
stream() {
  local name=$1 dir=$2; shift 2
  echo "[$(date -u +%H:%M)] uploading $name from $dir..."
  tar -C "$dir" -cf - "$@" | zstd -T0 -3 |
    rclone rcat --drive-chunk-size 128M "$DEST/$name" || fail "upload of $name failed"
  echo "[$(date -u +%H:%M)] done $name"
}

[ -d "$CACHE/ccache" ] && stream ccache.tar.zst "$CACHE" ccache
[ -d "$BUILD/src" ] || fail "missing $BUILD/src"
stream src-tree.tar.zst "$BUILD" --exclude=src/out src
[ "$SKIP_OUT" = 1 ] || [ ! -d "$BUILD/src/out" ] || stream out.tar.zst "$BUILD/src" out

echo "=== remote listing ==="; rclone ls "$DEST" || true
echo 0 > "$HOME/backup.exit"
echo "=== backup done $(date -u) ==="
BACKUP_SH
  push_prereqs "$tmpd"
  gcloud_ compute scp --quiet "$tmpd/doha-backup.sh" "$NAME:doha-backup.sh" >/dev/null
  gcloud_ compute ssh "$NAME" --command "
    chmod +x \$HOME/doha-backup.sh
    tmux kill-session -t backup 2>/dev/null || true
    tmux new-session -d -s backup \"DEST='$BACKUP_REMOTE' SKIP_OUT='$SKIP_OUT' BACKUP_WAIT='$BACKUP_WAIT' SESS='$SESSION' \$HOME/doha-backup.sh\"
    sleep 2; tmux ls; tail -n 3 \$HOME/backup.log 2>/dev/null || true"
  echo "backup: streaming to $BACKUP_REMOTE in tmux 'backup' on $NAME"
  echo "watch:  gcloud compute ssh $NAME --zone $ZONE --command 'tail -f ~/backup.log'"
  echo "result: gcloud compute ssh $NAME --zone $ZONE --command 'cat ~/backup.exit'  (0 = ok)" ;;

restore)
  need_vm restore
  tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
  cat > "$tmpd/doha-restore.sh" <<'RESTORE_SH'
#!/bin/bash
set -uo pipefail
exec >>"$HOME/restore.log" 2>&1
BUILD=/mnt/build
CACHE=$([ -b /dev/nvme0n2 ] && echo /mnt/cache || echo "$BUILD/cache")
DEST=${DEST:?missing DEST}
SKIP_OUT=${SKIP_OUT:-0}
rm -f "$HOME/restore.exit"
fail() { echo "restore FAILED: $*"; echo 1 > "$HOME/restore.exit"; exit 1; }

echo "=== restore start $(date -u) src=$DEST skip_out=$SKIP_OUT ==="
mkdir -p "$BUILD" "$CACHE"
rclone ls "$DEST/src-tree.tar.zst" >/dev/null 2>&1 || fail "$DEST/src-tree.tar.zst not found"

restore_one() {
  local name=$1 dir=$2
  echo "[$(date -u +%H:%M)] restoring $name into $dir..."
  rclone cat "$DEST/$name" | zstd -dc -T0 | tar -C "$dir" -xf - || fail "restore of $name failed"
  echo "[$(date -u +%H:%M)] done $name"
}

rclone ls "$DEST/ccache.tar.zst" >/dev/null 2>&1 && restore_one ccache.tar.zst "$CACHE"
restore_one src-tree.tar.zst "$BUILD"
if [ "$SKIP_OUT" != 1 ] && rclone ls "$DEST/out.tar.zst" >/dev/null 2>&1; then
  restore_one out.tar.zst "$BUILD/src"
fi

df -h "$BUILD" "$CACHE"
echo 0 > "$HOME/restore.exit"
echo "=== restore done $(date -u) ==="
RESTORE_SH
  push_prereqs "$tmpd"
  gcloud_ compute ssh "$NAME" --command "rclone ls '$BACKUP_REMOTE/src-tree.tar.zst' >/dev/null" \
    || { echo "restore: $BACKUP_REMOTE/src-tree.tar.zst is not on the remote" >&2; exit 1; }
  gcloud_ compute scp --quiet "$tmpd/doha-restore.sh" "$NAME:doha-restore.sh" >/dev/null
  gcloud_ compute ssh "$NAME" --command "
    chmod +x \$HOME/doha-restore.sh
    tmux kill-session -t restore 2>/dev/null || true
    tmux new-session -d -s restore \"DEST='$BACKUP_REMOTE' SKIP_OUT='$SKIP_OUT' \$HOME/doha-restore.sh\"
    sleep 2; tmux ls; tail -n 3 \$HOME/restore.log 2>/dev/null || true"
  echo "restore: pulling from $BACKUP_REMOTE in tmux 'restore' on $NAME"
  echo "watch:  gcloud compute ssh $NAME --zone $ZONE --command 'tail -f ~/restore.log'"
  echo "result: gcloud compute ssh $NAME --zone $ZONE --command 'cat ~/restore.exit'  (0 = ok)"
  echo "next:   TAG=... tools/gcp-build.sh build   (incremental, ~20-40 min)" ;;

status)
  need_vm status
  gcloud_ compute ssh "$NAME" --command "
    echo '--- tmux ---'; tmux ls 2>&1
    echo '--- backup ---'; tail -n 3 ~/backup.log 2>/dev/null || echo 'no backup.log'
    echo '--- restore ---'; tail -n 3 ~/restore.log 2>/dev/null || echo 'no restore.log'
    echo '--- remote ---'; rclone ls '$BACKUP_REMOTE' 2>&1 | tail -5
    df -h /mnt/build /mnt/cache | tail -2" ;;

*)
  sed -n '2,30p' "$0" | sed 's/^# \?//'
  exit 1 ;;
esac
