#!/usr/bin/env bash
# Copy the buildkit to the VM and extract it under ~/amogus_doha_custom_rom.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_ENV="$ROOT/gcp/vm.env"
[ -f "$VM_ENV" ] || { echo "Missing $VM_ENV; run ./gcp/create-vm.sh create first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$VM_ENV"

TARBALL="${TMPDIR:-/tmp}/doha-kit.tgz"
echo "Packing kit (work/, dist/, .git excluded)..."
tar -czf "$TARBALL" \
    --exclude='./work' \
    --exclude='./dist' \
    --exclude='./dist-gcp' \
    --exclude='./.git' \
    --exclude='./gcp/vm.env' \
    --exclude='*/__pycache__' \
    -C "$ROOT" .

echo "Uploading to $VM_NAME ($ZONE)..."
gcloud compute scp "$TARBALL" "$VM_NAME:/tmp/doha-kit.tgz" \
    --zone="$ZONE" --project="$PROJECT" --quiet

gcloud compute scp "$ROOT/gcp/provision.sh" "$VM_NAME:/tmp/provision.sh" \
    --zone="$ZONE" --project="$PROJECT" --quiet
gcloud compute scp "$ROOT/gcp/remote-build.sh" "$VM_NAME:/tmp/remote-build.sh" \
    --zone="$ZONE" --project="$PROJECT" --quiet

gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet --command='
set -e
rm -rf "$HOME/amogus_doha_custom_rom"
mkdir -p "$HOME/amogus_doha_custom_rom"
tar -xzf /tmp/doha-kit.tgz -C "$HOME/amogus_doha_custom_rom"
echo "kit extracted: $HOME/amogus_doha_custom_rom"
'

echo "Kit synced."
