# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A build recipe, not an Android source tree. It holds a `repo` manifest, a
set of patch files, and a script that syncs the upstream sources, applies
the patches, and builds an unofficial ROM for the Motorola Moto G8 Plus
(`doha`, device name `amogus_doha`, Snapdragon 665, 4.14 kernel).

- `crdroid-android-17` is the **crDroid 13** (Android 17) integration branch,
  built from crDroid's manifest branch `17.0`; `performance-tuning` is the
  daily-work branch. Merges go `performance-tuning` -> `crdroid-android-17`
  after device testing.
- `lineage-24.0` is the LineageOS 24.0 (Android 17) build of the same device
  work. There is no `main`; do not merge crDroid work back into the LineageOS
  lines.
- `README.md` is the authoritative, detailed document: install/update
  steps, known issues, and — importantly — one section per fix explaining
  why it exists. `AGENTS.md` is the compact repo mechanics guide.
- `tools/gcp-build.sh` discovers the project/VM from `gcloud config`;
  `logs [--full]` formats the tail or streams the raw log. The 2026-11-27
  build carries the Dolby Atmos stack under
  `device/motorola/amogus_doha/dolby` and removes AudioFX; see README.

The Android sources themselves are never committed here. Even the device
trees and vendor blobs are third-party (Aldair402, moto-common); the value
in this repo is the patches that make them build and boot on Android 17.

## Building

Docker build (needs ~350 GB disk and ~100 GB RAM+swap). The container is
only a toolchain: `build.sh` replaces the image's entrypoint, so the
LineageOS patches that image would normally apply never run.

```sh
docker run --rm -it \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/manifest:ro" \
  -v ~/android/crdroid-17.0:/src \
  -v ~/android/ccache/doha:/ccache -e CCACHE_DIR=/ccache \
  -v ~/doha/zips:/zips -e ZIP_DIR=/zips \
  --entrypoint /manifest/build.sh \
  lineageos4microg/docker-lineage-cicd:latest /src
```

Or directly on a host with `repo` and the AOSP build deps:

```sh
./build.sh ~/android/crdroid-17.0
```

`build.sh` is the only build entry point. It (1) `repo init`/`repo sync`
against this clone's manifest, (2) resets each patched project and applies
`patches/`, (3) creates the empty `kernel-headers` file, (4) runs
`breakfast amogus_doha userdebug` and `mka bacon`,
(5) copies the zip plus `boot`, `dtbo` and `vbmeta` images and their
`.sha256sum` to the zip directory.

Useful environment variables: `SKIP_SYNC=1` (skip init/sync — use this
when iterating), `JOBS`, `SYNC_JOBS`, `CCACHE_SIZE`, `ZIP_DIR`,
`SKIN_THROTTLE_C`, `DEBLOAT` (variant: 0 standard, 1 without the optional
crDroid extras), `ADB_KEY` (test builds only), `MANIFEST_BRANCH`.
With Docker, pass them as `-e NAME=value`.

There is **no test suite, linter, or CI**. Correctness is verified by
building and flashing to real hardware; see "Status" in the README for
what has been tested. A failed compile or a bootloop is the feedback
loop. `bash -n build.sh` is the only cheap check.

## How the pieces fit

`default.xml` — crDroid's own manifest
(`crdroidandroid/android`, branch `17.0`) with our remotes added and
`<include name="snippets/doha.xml" />` appended next to crDroid's
`snippets/crdroid.xml` and `snippets/lineage.xml`. Do not add a second
`github` remote: crDroid's uses `fetch=".."`, which resolves to
`https://github.com/` for this manifest URL.

`snippets/` — `crdroid.xml` and `lineage.xml` are copied from crDroid
verbatim; keep them that way so a rebase is a plain re-copy.
`snippets/doha.xml` is ours: the 27 `local::doha` projects (device trees,
vendor blobs, kernel, HALs, the AOSPA `device/qcom/*` and
`vendor/qcom/common`). It starts with two `<remove-project>` entries, for
the two crDroid projects whose path doha takes over:

- `platform/external/fastrpc` — doha uses AOSPA's fastrpc at that path.
- `LineageOS/android_vendor_qcom_opensource_data-ipa-cfg-mgr` at
  `vendor/qcom/opensource/data-ipa-cfg-mgr-legacy-um` — doha's IPACM comes
  from moto-common's `.../data-ipa-cfg-mgr-legacy`. With both, Soong stops
  on `ipacm` and `IPACM_cfg.xml` being in two namespaces. Removed by
  `name` **and** `path`: the same project name backs the
  `hardware/qcom-caf/*/data-ipa-cfg-mgr` entries other devices use.

Pinning: the doha projects are pinned to commits; the crDroid, LineageOS
and AOSP projects currently follow branch/tag refs. Once a build boots,
`repo manifest -r -o default.xml` flattens the includes into a fully
pinned manifest — that is the intended final state, matching the
LineageOS branches. `snippets/` then stays as the upstream baseline for
the next crDroid bump.

`patches/<project path>.patch` — one patch per upstream project. The
filename is the project's **path** in the manifest (e.g.
`patches/packages/modules/Connectivity.patch`), and the diff paths are
relative to that project's root. Patches are plain `git diff` output
applied with `git apply --whitespace=nowarn`. crDroid replaces ~64 core
projects with its own forks (including `system/core`,
`hardware/interfaces`, `packages/modules/Connectivity`,
`device/lineage/sepolicy` and `vendor/lineage` at that path), so a patch
that targets one of them has to be rebased on crDroid's version of the
file, not LineageOS's.

`build.sh` — sync/apply/build driver. Two behaviours matter when editing
patches:

- It is idempotent. A stamp in `.repo/doha-patches` records each patch's
  blob and the resulting worktree tree; unchanged projects keep their
  timestamps and are not rebuilt.
- `reset_project()` runs `git reset --hard && git clean -fd` before
  applying. Untracked files in a patched project are therefore deleted,
  so **new files must be part of the patch** (stage or `git add -N` them
  before producing the diff). Hand edits to a patched project are wiped
  on the next run — change the patch, not the tree.

Placeholders rendered when patches are applied: `@SKIN_THROTTLE_MC@` →
`SKIN_THROTTLE_C * 1000`, `@DEBLOAT@` → 0/1, `@UPDATER_CHANNEL@` →
`standard`/`debloat`. The rendered blob is what the stamp compares, so
changing any of them re-applies the affected patches.

`build.sh` also generates `vendor/extra/product.mk` for `ADB_KEY` test
builds and deletes it otherwise; that directory is not in the manifest and
must not be committed. crDroid's `vendor/lineage/config/common.mk`
inherits it first, so the mechanism works unchanged. Never distribute an
`-adbkey` build.

## Changing a fix

1. Sync once (or `SKIP_SYNC=1` if a tree already exists) and edit the
   files inside the corresponding project under the source directory.
2. Regenerate that project's patch from its root, e.g.
   `git -C kernel/motorola/msm-4.14 diff > .../patches/kernel/motorola/msm-4.14.patch`.
   The patch must apply cleanly to the current revision — `build.sh`
   resets to it before applying. A patch can be checked without a full
   sync by reconstructing the touched files in a scratch git repo and
   running `git apply --check`.
3. Update the matching section in README.md. Every fix there names its
   patch file(s) and the symptom it addresses; the README is the design
   record for this repo, and an undocumented patch is a maintenance
   hazard.
4. Commit the patch (and any `default.xml` change) before building.

Kernel work is split: doha's kernel is our fork
`ishwar-chandra/android_kernel_motorola_msm-4.14`. `lts` carries the
4.14.357 baseline; the build currently pins `9a3cf72` on
`fix`. Either add the change to
`patches/kernel/motorola/msm-4.14.patch` or land it in the fork and bump
the kernel project's revision in `snippets/doha.xml`.

## Gotchas

- `device/motorola/amogus_doha/kernel-headers` must be an empty **file**.
  It is created at build time, not committed. Turning it into a directory
  shadows bionic's headers and breaks the compile.
- `build.sh` refuses to run with a dirty `default.xml`; commit first or
  set `SKIP_SYNC=1`.
- crDroid's `bacon` **moves** the OTA zip to
  `crDroidAndroid-<version>.zip` and deletes the target-files
  intermediates, so `out/target/product/amogus_doha/` has no
  `lineage_<device>-ota.zip` and no `IMAGES/` directory afterwards.
  `build.sh` handles this; don't reintroduce LineageOS's
  `-samefile`/`IMAGES` logic.
- crDroid version numbers and the Android version differ: branch `17.0`
  is crDroid **13.1**, and the zip is named
  `crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip`.
- A `repo sync` (without `SKIP_SYNC=1`) overwrites local changes in every
  project, patched or not.
- The released build is `userdebug`, unsigned (AOSP test keys), no GApps.
  crDroid sets `PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG`, so both `userdebug` and
  `user` report `ro.build.type=user`/`ro.debuggable=0`; there is no `adb root`
  or shell `dmesg`, and pstore is read from recovery. It also no longer carries
  the docker-lineage-cicd SafetyNet patch: crDroid's
  `system/core` spoofs SafetyNet itself (`SPOOF_SAFETYNET=1` in
  `init/Android.bp`). That spoof does not make Play Integrity pass on doha;
  the vendor keymaster refuses attestation (`-10003`). See the README section
  "Play Integrity" and `tools/integrity-setup.sh`.

## Commit convention

Commit subjects state the fix in plain language, optionally prefixed by
the area (`build.sh:`, `README:`, `zygote_next:`), and end with the
tracking issue, e.g. `(doha_android#49)`. Merge commits follow
`Merge <branch> into <branch>: <summary> (doha_android#N)`.
