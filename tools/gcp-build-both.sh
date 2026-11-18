#!/usr/bin/env bash
# Build the standard and debloat variants at the same time on two VMs.
#
# Builds run in parallel; releases are serialized so the two `finish` calls
# cannot race on the same GitHub tag or on the two OTA feeds. Each VM is
# deleted only after its own release and OTA update succeed.
#
# Usage:
#   tools/gcp-build-both.sh
#
# Environment:
#   MACHINE   per-VM shape. Default n2-custom-6-49152: two of them fit the
#             project's CPUS_ALL_REGIONS=12 quota and leave 64 GB total RAM.
#   TAG       release tag shared by both variants (default: today).
#   NAME      base VM name; the script uses <name>-std and <name>-debloat.
#   Other gcp-build.sh variables (HOURS, GH_TOKEN, ...) pass through.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GCP=$HERE/gcp-build.sh
BASE=${NAME:-crdroid-build}
STD=$BASE-std
DEB=$BASE-debloat

export MACHINE=${MACHINE:-n2-custom-6-49152}
export TAG=${TAG:-crdroid-$(date +%Y%m%d)}

cpus=$(printf '%s\n' "$MACHINE" | sed -n 's/.*-\([0-9][0-9]*\)-[0-9][0-9]*$/\1/p')
if [ -n "$cpus" ] && [ "$cpus" -gt 6 ]; then
  echo "MACHINE=$MACHINE is too wide for two simultaneous VMs." >&2
  echo "CPUS_ALL_REGIONS is 12; use n2-custom-6-49152 or raise the quota." >&2
  exit 1
fi

echo "standard VM: $STD"
echo "debloat  VM: $DEB"
echo "tag: $TAG"
echo "machine: $MACHINE"

NAME=$STD DEBLOAT=0 "$GCP" create
NAME=$DEB DEBLOAT=1 "$GCP" create

NAME=$STD DEBLOAT=0 "$GCP" setup &
p_std=$!
NAME=$DEB DEBLOAT=1 "$GCP" setup &
p_deb=$!
wait "$p_std"
wait "$p_deb"

# Both builds start now; each runs in its own tmux session on its own VM.
NAME=$STD DEBLOAT=0 "$GCP" build
NAME=$DEB DEBLOAT=1 "$GCP" build

# Release sequentially: same tag, two variants; each finish updates only its
# own OTA channel. The second sees the first's tag and adds its assets.
NAME=$STD DEBLOAT=0 "$GCP" finish
NAME=$DEB DEBLOAT=1 "$GCP" finish

echo "both variants built, released and published to their OTA channels"
