#!/usr/bin/env bash
# One-command remote build:
#   sync kit -> provision VM -> build in tmux -> download dist/
#
# Re-running while a build is active:
#   SKIP_SYNC=1 ./gcp/build-remote.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_ENV="$ROOT/gcp/vm.env"
[ -f "$VM_ENV" ] || { echo "Missing $VM_ENV; run ./gcp/create-vm.sh create first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$VM_ENV"

if [ "${SKIP_SYNC:-0}" != 1 ]; then
    "$ROOT/gcp/sync-kit.sh"
fi

echo "Provisioning VM (idempotent)..."
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet \
    --command='bash /tmp/provision.sh' \
    --ssh-flag="-o ServerAliveInterval=30"

echo "Starting build (tmux keeps it alive if SSH drops)..."
set +e
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet \
    --command='bash /tmp/remote-build.sh' \
    --ssh-flag="-o ServerAliveInterval=30" \
    --ssh-flag="-o ServerAliveCountMax=240"
rc=$?
set -e

echo "Fetching build log and artifacts..."
gcloud compute scp "$VM_NAME:amogus_doha_custom_rom/build.log" "$ROOT/dist-gcp-build.log" \
    --zone="$ZONE" --project="$PROJECT" --quiet 2>/dev/null || true

rm -rf "$ROOT/dist-gcp"
gcloud compute scp --recurse "$VM_NAME:amogus_doha_custom_rom/dist" "$ROOT/dist-gcp" \
    --zone="$ZONE" --project="$PROJECT" --quiet || true

if [ "$rc" -ne 0 ]; then
    echo "Build failed (exit $rc). Log: $ROOT/dist-gcp-build.log" >&2
    exit "$rc"
fi

echo "Build succeeded. Artifacts in: $ROOT/dist-gcp"
