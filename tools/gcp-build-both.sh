#!/usr/bin/env bash
# Build the standard and debloat variants on ONE VM, one after the other.
# The first build is released with NO_DELETE=1 so the VM stays alive for the
# second; the second release uses the same TAG and then deletes the VM.
#
# Usage:
#   tools/gcp-build-both.sh
#
# Environment:
#   MACHINE   VM shape (default n2-custom-12-49152, the full quota).
#   TAG       release tag shared by both variants (default: today).
#   NAME      VM name (default crdroid-build).
#   Other gcp-build.sh variables (HOURS, GH_TOKEN, ...) pass through.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GCP=$HERE/gcp-build.sh
BASE=${NAME:-crdroid-build}

export MACHINE=${MACHINE:-n2-custom-12-49152}
export TAG=${TAG:-crdroid-$(date +%Y%m%d)}

echo "VM: $BASE"
echo "tag: $TAG"
echo "machine: $MACHINE"

NAME=$BASE DEBLOAT=0 "$GCP" create
NAME=$BASE DEBLOAT=0 "$GCP" setup

# Standard first; keep the VM for the debloat build.
NAME=$BASE DEBLOAT=0 "$GCP" build
NAME=$BASE DEBLOAT=0 NO_DELETE=1 "$GCP" finish

# Debloat on the same VM, then release and delete.
NAME=$BASE DEBLOAT=1 "$GCP" build
NAME=$BASE DEBLOAT=1 "$GCP" finish

echo "both variants built from one VM, released under $TAG"
