# doha A16 buildkit

Reproducible Android 16 (crDroid 16.0) builds for the **Motorola Moto G8 Plus**
(`amogus_doha`, SM6125). The device layer is the stable community port that
produced the Android 13 crDroid 9 ROM, carried forward with the Android 16
platform patches the device actually needs.

> **Status:** this is a code-and-patch repository, not a prebuilt ROM. No build
> has been run in this workspace. `./scripts/build.sh dryrun` validates the
> configuration, URLs and patch set; the first full build is the real test.

## Quick start

```bash
# 1. Validate without downloading or compiling anything
./scripts/build.sh dryrun

# 2. Full pipeline: host deps -> repo init -> manifest -> sync -> patch -> build
./scripts/build.sh all

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

## Host requirements

| Resource | Requirement |
|---|---|
| OS | Ubuntu 22.04/24.04/26.04, native or WSL2 on the Linux filesystem |
| Disk | ~300 GB free (200 GB source + 100 GB `out/`); 350 GB comfortable |
| RAM | 32 GB preferred; 16 GB works with swap. Soong peaks around 20 GB |
| CPU | 8+ threads useful; a clean build is 2–3 h, incremental ~20–40 min |
| Network | ~100 GB first sync |

The build does **not** run on 4 GB/8 GB machines. `dryrun` warns below 250 GB
free and below 16 GB RAM.

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
docs/                   architecture, patch map, VoLTE, integrity, flashing, tests
```

## Provenance

- Device/vendor/targets: **Aldair402** (`android_device_motorola_amogus_doha`
  branch `2.1`, vendor `14`, targets `master`).
- Android 16 platform patches and LTS kernel: **christiaan**
  (`christiaan/lineage-23-amogus_doha`, kernel
  `christiaan/android_kernel_motorola_msm-4.14` branch `lts`).
- crDroid 16.0 sources: **crDroidAndroid**.
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
