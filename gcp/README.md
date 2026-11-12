# One-command GCP build, release, backup and restore

Everything lives in **`gcp/doha.sh`**. No other GCP scripts.

## What it does

```mermaid
flowchart LR
  A[create VM] --> B[sync kit]
  B --> C[provision]
  C --> D[build]
  D --> E{success?}
  E -- yes --> F[fetch dist]
  F --> G[GitHub release]
  G --> H[Drive backup]
  E -- no --> I[stop + log]
```

- **VM:** 12 vCPU / 48 GB, cheapest available shape (`e2-standard-12` first,
  then `t2d`, `n2d`, `n2`, `c2`), cheapest approximate region order.
- **OS:** Ubuntu 24.04 LTS (`ubuntu-2404-lts-amd64`).
- **Disk:** 500 GB `pd-standard` + 32 GB swap. Enough for ~200 GB source,
  ~120 GB `out/`, 50 GB ccache and headroom.
- **Build:** runs `scripts/build.sh all` inside `tmux`, so SSH drops do not
  kill it.
- **Release:** only after a successful build, via `gh release create`.
- **Backup:** only after a successful build, to
  `gdrive:doha-a16/<timestamp>/` with `work/android`, `work/ccache`, `dist`
  and the kit.
- **Restore:** latest or named snapshot to a new VM, or `--local`.

## Prerequisites

- `gcloud` installed and authenticated.
- `gh` installed and `gh auth login` done (for release).
- `rclone` configured **on the VM** with a remote named `gdrive`, or pass
  `--copy-rclone` to upload your local
  `~/.config/rclone/rclone.conf`.
- The buildkit repo pushed to GitHub if you want the release step to use it;
  `--repo OWNER/REPO` defaults to
  `ishwar-chandra/amogus_doha_custom_rom`.

## Commands

```bash
# Full pipeline: create -> build -> release -> backup
./gcp/doha.sh all

# Create the VM only
./gcp/doha.sh up

# Build and fetch dist/ without releasing/backing up
./gcp/doha.sh build

# Publish the last fetched dist-gcp/
./gcp/doha.sh release

# Backup the VM now
./gcp/doha.sh backup

# Restore latest snapshot to a VM (creates the VM if needed)
./gcp/doha.sh restore

# Restore into this machine
./gcp/doha.sh restore --local

# List snapshots
./gcp/doha.sh snapshots

# SSH / status / stop / start / delete
./gcp/doha.sh ssh
./gcp/doha.sh status
./gcp/doha.sh stop
./gcp/doha.sh start
./gcp/doha.sh down
```

## Important flags

```bash
./gcp/doha.sh all \
  --repo ishwar-chandra/amogus_doha_custom_rom \
  --remote gdrive \
  --dir doha-a16 \
  --copy-rclone
```

| Flag | Meaning |
|---|---|
| `--project ID` | GCP project |
| `--zone ZONE` | force a zone |
| `--machine-type TYPE` | force a shape |
| `--disk-size 500GB` | boot disk |
| `--spot` | cheaper, can be preempted |
| `--repo OWNER/REPO` | GitHub release target |
| `--tag TAG` | override the auto-detected release tag |
| `--remote NAME` | rclone remote (`gdrive`) |
| `--dir NAME` | Drive folder (`doha-a16`) |
| `--snapshot NAME` | backup/restore snapshot |
| `--copy-rclone` | upload local rclone config to the VM |
| `--no-release` | skip GitHub release |
| `--no-backup` | skip Drive backup |
| `--local` | backup/restore on this machine |

## Rclone setup (recommended before the first `all`)

On the VM:

```bash
./gcp/doha.sh ssh
rclone config          # create a remote named "gdrive" (Google Drive)
exit
```

Or upload your local config once:

```bash
./gcp/doha.sh all --copy-rclone
```

`all` checks the remote **before** starting the multi-hour build. If it is
missing, it stops immediately with instructions instead of failing after the
build.

## GitHub release

The release tag is auto-detected from `BUILD_INFO.txt` (or the ROM zip's mtime), so an older artifact does not get stamped with today's date. Override with `--tag` only when needed.

`release` uses the local `dist-gcp/` directory:

- ROM zip
- `boot.img`, `dtbo.img`, `vbmeta.img`
- `SHA256SUMS`, `BUILD_INFO.txt`

If the tag exists, assets are uploaded with `--clobber`. A missing/unauthenticated
`gh` fails the release step but does not delete the build; the Drive backup
still runs.

## Costs and cleanup

- `e2-standard-12` is roughly $0.45–0.55/hour.
- 500 GB `pd-balanced` is roughly $0.07/hour.
- A 3–5 hour build is a few dollars of trial credit.
- Delete the VM when done:
  ```bash
  ./gcp/doha.sh down
  ```
  A stopped VM still bills for the disk.

If `create` fails with `QUOTA_EXCEEDED`, pick a zone with 12 vCPU quota:

```bash
./gcp/doha.sh up --zone us-central1-a --machine-type e2-standard-12
```

If the machine-type query is slow, skip it with `--zone` + `--machine-type`.
