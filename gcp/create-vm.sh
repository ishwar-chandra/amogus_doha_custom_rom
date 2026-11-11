#!/usr/bin/env bash
# Create/stop/delete the cheapest available 12 vCPU / 48 GB GCP builder.
#
#   ./gcp/create-vm.sh find      # show the cheapest zone/type, create nothing
#   ./gcp/create-vm.sh create    # create the VM + SSH firewall rule
#   ./gcp/create-vm.sh ssh
#   ./gcp/create-vm.sh stop
#   ./gcp/create-vm.sh start
#   ./gcp/create-vm.sh status
#   ./gcp/create-vm.sh delete    # deletes the VM and its boot disk
#
# Overrides:
#   PROJECT=... ZONE=... MACHINE_TYPE=... VM_NAME=... DISK_SIZE=500GB
#   DISK_TYPE=pd-balanced IMAGE_FAMILY=ubuntu-2404-lts-amd64
#   MACHINE_TYPES="e2-standard-12 t2d-standard-12 n2d-standard-12 n2-standard-12 c2-standard-12"
#   SPOT=1 SSH_SOURCE_RANGE=0.0.0.0/0 NETWORK=default
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_ENV="$ROOT/gcp/vm.env"

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
[ -n "$PROJECT" ] || { echo "No GCP project. Run: gcloud config set project <id>" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "gcloud not found" >&2; exit 1; }

VM_NAME="${VM_NAME:-doha-a16-builder}"
DISK_SIZE="${DISK_SIZE:-500GB}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
NETWORK="${NETWORK:-default}"
SSH_SOURCE_RANGE="${SSH_SOURCE_RANGE:-0.0.0.0/0}"
SPOT="${SPOT:-0}"

# Cheapest first. e2 is the cheapest 12/48 shape; t2d/n2d are often close.
MACHINE_TYPES="${MACHINE_TYPES:-e2-standard-12 t2d-standard-12 n2d-standard-12 n2-standard-12 c2-standard-12}"

# Approximate GCP price order: cheapest general-purpose regions first.
REGION_ORDER="us-central1 us-east1 us-west1 us-east4 us-south1 us-west2 us-west3 us-west4
northamerica-northeast1 northamerica-northeast2 southamerica-east1 southamerica-west1
europe-west1 europe-west2 europe-west3 europe-west4 europe-west6 europe-north1 europe-central2
asia-south1 asia-southeast1 asia-east1 asia-northeast1 asia-northeast2 asia-northeast3
australia-southeast1 australia-southeast2"

find_zone() {
    local list candidates best
    echo "Querying GCP for 12 vCPU machine types (can take a minute)..." >&2
    if ! list=$(timeout "${FIND_TIMEOUT:-180}" gcloud compute machine-types list \
            --project="$PROJECT" \
            --filter='guestCpus=12' \
            --format='value(zone.basename(),name)' \
            --quiet 2>/dev/null); then
        echo "Machine-type query failed or timed out after ${FIND_TIMEOUT:-180}s." >&2
        echo "Pick manually, for example:" >&2
        echo "  ZONE=us-central1-a MACHINE_TYPE=e2-standard-12 $0 create" >&2
        exit 1
    fi
    [ -n "$list" ] || { echo "No 12 vCPU machine types visible in $PROJECT" >&2; exit 1; }

    declare -A RANK=()
    local i=0 r
    for r in $REGION_ORDER; do RANK[$r]=$i; i=$((i + 1)); done

    candidates=$(
        while read -r zone name; do
            [ -n "$zone" ] || continue
            region="${zone%-*}"
            for mt in $MACHINE_TYPES; do
                if [ "$name" = "$mt" ]; then
                    printf '%s\t%s\t%s\n' "${RANK[$region]:-999}" "$zone" "$name"
                    break
                fi
            done
        done <<< "$list" | sort -n -k1,1
    )

    best=$(printf '%s\n' "$candidates" | head -1)
    if [ -z "$best" ]; then
        echo "No preferred 12/48 shape available. Available 12 vCPU types:" >&2
        printf '%s\n' "$list" | awk '{print $2}' | sort -u | sed 's/^/  /' >&2
        echo "Set MACHINE_TYPES or MACHINE_TYPE/ZONE manually." >&2
        exit 1
    fi

    IFS=$'\t' read -r _ ZONE MACHINE_TYPE <<< "$best"
    echo "Selected: $MACHINE_TYPE in $ZONE ($PROJECT)" >&2
}

write_vm_env() {
    cat > "$VM_ENV" <<EOF
PROJECT=$PROJECT
ZONE=$ZONE
VM_NAME=$VM_NAME
MACHINE_TYPE=$MACHINE_TYPE
DISK_SIZE=$DISK_SIZE
DISK_TYPE=$DISK_TYPE
EOF
    chmod 600 "$VM_ENV"
}

load_vm_env() {
    if [ -f "$VM_ENV" ]; then
        # shellcheck disable=SC1090
        . "$VM_ENV"
    fi
}

ensure_network() {
    if ! gcloud compute networks describe "$NETWORK" --project="$PROJECT" >/dev/null 2>&1; then
        echo "VPC network '$NETWORK' not found in $PROJECT. Set NETWORK=<name>." >&2
        exit 1
    fi
}

ensure_firewall() {
    if gcloud compute firewall-rules describe doha-allow-ssh --project="$PROJECT" >/dev/null 2>&1; then
        return 0
    fi
    echo "Creating firewall rule doha-allow-ssh (tcp/22 from $SSH_SOURCE_RANGE)..."
    gcloud compute firewall-rules create doha-allow-ssh \
        --project="$PROJECT" \
        --network="$NETWORK" \
        --allow=tcp:22 \
        --source-ranges="$SSH_SOURCE_RANGE" \
        --target-tags=doha-builder \
        --description="SSH for the doha Android 16 builder"
}

cmd_find() {
    if [ -n "${ZONE:-}" ] && [ -n "${MACHINE_TYPE:-}" ]; then
        echo "Using supplied ZONE=$ZONE MACHINE_TYPE=$MACHINE_TYPE"
        return 0
    fi
    find_zone
}

cmd_create() {
    cmd_find
    ensure_network

    if gcloud compute instances describe "$VM_NAME" \
            --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1; then
        echo "VM already exists: $VM_NAME ($ZONE)"
        write_vm_env
        cmd_status
        return 0
    fi

    ensure_firewall

    local spot_args=()
    [ "$SPOT" = 1 ] && spot_args=(--spot)

    echo "Creating $VM_NAME: $MACHINE_TYPE, $DISK_SIZE $DISK_TYPE, $IMAGE_FAMILY"
    gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --boot-disk-size="$DISK_SIZE" \
        --boot-disk-type="$DISK_TYPE" \
        --tags=doha-builder \
        --labels=app=doha-a16 \
        --quiet \
        "${spot_args[@]}"

    write_vm_env
    cmd_status
    cat <<EOF

Next:
  ./gcp/sync-kit.sh       copy this repo to the VM
  ./gcp/build-remote.sh   provision + build + download dist/

SSH:
  gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT
EOF
}

cmd_ssh() {
    load_vm_env
    [ -n "${ZONE:-}" ] || { echo "Run ./gcp/create-vm.sh create first" >&2; exit 1; }
    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
        --ssh-flag="-o ServerAliveInterval=30" \
        --ssh-flag="-o ServerAliveCountMax=60"
}

cmd_status() {
    load_vm_env
    [ -n "${ZONE:-}" ] || { echo "No gcp/vm.env; pass ZONE and VM_NAME" >&2; exit 1; }
    gcloud compute instances describe "$VM_NAME" \
        --zone="$ZONE" --project="$PROJECT" \
        --format='table(name,status,machineType.basename(),zone.basename():label=ZONE,disks[0].diskSizeGb:label=DISK_GB)'
}

cmd_stop() {
    load_vm_env
    gcloud compute instances stop "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet
}

cmd_start() {
    load_vm_env
    gcloud compute instances start "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet
}

cmd_delete() {
    load_vm_env
    gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
        --delete-disks=boot --quiet
    rm -f "$VM_ENV"
    echo "Deleted $VM_NAME and its boot disk."
}

case "${1:-create}" in
    find)    cmd_find ;;
    create)  cmd_create ;;
    ssh)     cmd_ssh ;;
    status)  cmd_status ;;
    stop)    cmd_stop ;;
    start)   cmd_start ;;
    delete)  cmd_delete ;;
    *) echo "usage: $0 {find|create|ssh|status|stop|start|delete}" >&2; exit 2 ;;
esac
