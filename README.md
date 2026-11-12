# doha A16 buildkit

Reproducible Android 16 (crDroid 12.13) builds for the **Motorola Moto G8 Plus**
(`amogus_doha`, SM6125). The device layer is the stable community port that
produced the Android 13 crDroid 9 ROM, carried forward with the Android 16
platform patches the device actually needs.

> **Status:** active Android 16 (crDroid 12.13) port. `./scripts/build.sh dryrun`
> validates the configuration, URLs and patch set. Full builds are run on the
> GCP VM; a local build needs the disk and RAM below.

## Quick start

```bash
# 1. Validate without downloading or compiling anything
./scripts/build.sh dryrun

# 2. Full pipeline: host deps -> repo init -> manifest -> sync -> patch -> build
./scripts/build.sh all

# 3. Show which steps completed and the tree size
./scripts/build.sh status

# or run steps individually
./scripts/build.sh deps
./scripts/build.sh init
./scripts/build.sh manifest
./scripts/build.sh sync
./scripts/build.sh patch
./scripts/build.sh build
./scripts/build.sh verify
./scripts/build.sh collect
```

Artifacts land in `dist/v16-<date>-<time>/` with the ROM zip, `boot.img`,
`dtbo.img`, `vbmeta.img`, `SHA256SUMS` and `BUILD_INFO.txt`.

To record the exact SHAs a build resolved to:

```bash
./scripts/build.sh snapshot
# writes manifests/resolved-<date>-<time>.xml
```

## Pinning

Pinned to exact commits:

- device tree, vendor blobs, `amogus`/`common`/`targets`, kernel
- MindTheGapps (`baklava`)
- every project the patch set touches: AOSP CarrierConfig tag `r4`,
  `vendor/apn`, `system/core`, `packages/modules/Connectivity`,
  `device/lineage/sepolicy`, `hardware/nxp/nfc`
- all 28 supporting moto-common / Aldair402 / AOSPA repositories

Not pinned: the crDroid `16.0` base branch itself (900+ projects). That is
intentional: the base moves, the port does not. `sync` writes
`work/state/resolved-manifest.xml`; `snapshot` writes a committable copy under
`manifests/`. Use the snapshot if you need to rebuild the exact tree months
later.

## GCP build

`gcp/doha.sh` creates a 12 vCPU / 48 GB Ubuntu 24.04 VM with a 700 GB
`pd-standard` disk, runs the build inside `tmux`, fetches `dist/`, optionally
publishes a GitHub release, and backs the build to Google Drive.

```bash
# one-time: get a token from a browser machine with `rclone authorize "drive"`
./gcp/doha.sh rclone-setup

# create VM -> build -> release -> incremental backup
./gcp/doha.sh all --repo YOUR_GITHUB/REPO

# inspect without touching the build
./gcp/doha.sh status
./gcp/doha.sh ssh

# build only, no release/backup
./gcp/doha.sh build

# incremental backup: first run full, later runs changed files only
./gcp/doha.sh backup

# restore `current` or a named snapshot
./gcp/doha.sh restore
./gcp/doha.sh restore --local
```

Requirements: `gcloud` authenticated, `gh` authenticated for releases, and an
rclone `gdrive` remote on the VM. `rclone-setup` configures it from the token
only; `--copy-rclone` remains available for an existing config.

When `gcp/doha.sh` runs **on the VM**, `build`, `backup`, `restore` and
`rclone-setup` automatically run locally instead of looking for another
machine.

Backups are incremental: `gdrive:doha-a16/current/` is updated in place.
Changed files replace the old file; unchanged files are not re-uploaded. An
explicit `--snapshot NAME` still creates a full snapshot. See
[gcp/README.md](gcp/README.md) for every flag and the restore workflow.

## Host requirements

| Resource | Requirement |
|---|---|
| OS | Ubuntu 22.04/24.04/26.04, native or WSL2 on the Linux filesystem |
| Disk | 400 GB free minimum (250 GB checkout + 150 GB `out/`); 500 GB comfortable. The GCP VM uses 700 GB |
| RAM | 32 GB preferred; 16 GB works with swap. Soong peaks around 20 GB |
| CPU | 8+ threads useful; a clean build is 2–4 h, incremental ~20–40 min |
| Network | ~250 GB checkout; first sync is the long pole |

The build does **not** run on 4 GB/8 GB machines. `dryrun` warns below 250 GB
free and below 16 GB RAM. A full `work/android` is ~220–250 GB before `out/`;
`.repo` is most of that, so do not size the disk from the checkout alone.

## What this repo deliberately does

**Keeps**

- The A13-derived hardware layer: `amogus_doha` device tree, vendor blobs,
  `amogus`/`common` trees, and the 4.14.357 LTS kernel with the doha fixes.
- All 17 Android 16 platform patches needed to build and boot a 4.14 kernel:
  BPF gates, thermal HAL, SELinux, kernel headers, `libqsap_sdk`, touch
  modules, WPA3, NFC, fingerprint, camera CCI, `close_range()` tethering.
- MindTheGapps baked into the system image (`vendor/gapps`, branch `baklava`).
- The CarrierConfig BSNL VoLTE fix (carrier id 1549), the confirmed framework
  root cause of SIM1 call failure.
- A missing-only BSNL IMS APN injector, so it does not duplicate rows that
  newer `vendor/apn` trees already ship.
- The `system/core` Basic Play Integrity property patch.

**Drops**

- The failed ext4-system rewrite (`v1.3.0-test1`) — it did not boot.
- Infamick/Samsung/Magisk utility tweaks and the unmeasured zram/swappiness
  profile. The kernel already enables zram/PSI/schedutil; no magic is claimed.
- The ginkgo “K2” kernel experiment — the LTS doha kernel already carries
  4.14.357.
- The modem `mcfg`/`mbn`/`omc` pull from the A13 phone. The modem firmware is
  not changed by a ROM, and the A13/A16 vendor trees have identical radio
  blobs; only add these if a hash diff proves a difference.
- Scrubbing `persist.dbg.volte_avail_ovr` — it is identical in the working A13
  and A16 trees; removing it changes a working variable without evidence.
- Unused Qualcomm platform stacks and the stale `vendor/crdroid` layout.

## Structure

```
config/                 build, ROM, device and pin definitions
manifest/               repo manifest inputs (core/supporting lists, remotes)
patches/a16/            the 17 Android 16 port patches, by project path
patches/carrierconfig/  BSNL VoLTE CarrierConfig patch
scripts/build.sh        single entry point, resumable steps
scripts/lib.sh          config loading, patch application, logging
scripts/tools/          manifest generator, APN injector, build verifier
gcp/doha.sh             GCP VM, build, release, rclone setup, backup/restore
docs/                   architecture, patch map, VoLTE, integrity, flashing, tests
```

## Provenance

- Device/vendor/targets: **Aldair402** (`android_device_motorola_amogus_doha`
  branch `2.1`, vendor `14`, targets `master`).
- Android 16 platform patches and LTS kernel: **christiaan**
  (`christiaan/lineage-23-amogus_doha`, kernel
  `christiaan/android_kernel_motorola_msm-4.14` branch `lts`).
- crDroid 12.13 sources: **crDroidAndroid**.
- MindTheGapps: **MindTheGapps/vendor_gapps** branch `baklava`.
- Stable Android 13 reference: XDA 4711795, crDroid 9.20, and the
  moto-common branch-13 trees.

The patches are copied from the public Christiaan repository and keep their
original metadata. See `NOTICE`.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — why the device layer is
  unchanged and what the patches do.
- [docs/PATCHES.md](docs/PATCHES.md) — every patch, the failure it prevents.
- [docs/BSNL_VOLTE.md](docs/BSNL_VOLTE.md) — the confirmed SIM1 root cause and
  the APN decision.
- [docs/PLAY_INTEGRITY.md](docs/PLAY_INTEGRITY.md) — BASIC/DEVICE/STRONG and
  signing.
- [docs/FLASHING.md](docs/FLASHING.md) — A/B recovery, clean flash, rollback.
- [docs/VERIFICATION.md](docs/VERIFICATION.md) — post-build gates and the
  device test matrix.
- [docs/FUTURE_TASKS.md](docs/FUTURE_TASKS.md) — OTA, signing, backup, disk
  and hardware follow-up checklist.
