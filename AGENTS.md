# Repository Guidelines

## Project Overview

Build recipe for an unofficial **crDroid 13.1 (Android 17)** ROM for the
Motorola Moto G8 Plus (`doha`; in-tree device name `amogus_doha`;
Snapdragon 665, 4.14 kernel). This repo contains **no Android sources**:
only a `repo` manifest, per-project patches, one build driver, and the
docs. All Android trees (device, vendor blobs, kernel, HALs) are
third-party and fetched by `repo sync`; the value here is the patches
that make them build and boot on Android 17.

Current branch is `crdroid-android-17`. `main` is the LineageOS 23.2
(Android 16) build and `lineage-24.0` the LineageOS 24.0 (Android 17)
build of the same device work. Never merge crDroid work back into those
branches.

`README.md` is the authoritative design record: one section per fix
naming its patch and symptom. Read it before changing a patch.

## Architecture & Data Flow

```
build.sh
  1. repo init -u <this clone> -b <current branch> -m default.xml  +  repo sync
       → ~1280 projects (1067 in default.xml, the rest via the 3 snippets)
  2. per patches/<project path>.patch: git reset --hard && git clean -fd,
     render placeholders, git apply --whitespace=nowarn
  3. create empty file device/motorola/amogus_doha/kernel-headers
  4. breakfast amogus_doha userdebug  &&  mka bacon
  5. copy crDroidAndroid-*.zip + boot/dtbo/vbmeta images + .sha256sum to ZIP_DIR
```

- The manifest is crDroid's (`crdroidandroid/android`, branch `17.0`).
  `default.xml` adds our remotes (`aospa`, `aldair402`, `moto-common`, …)
  and includes `snippets/{crdroid,lineage,doha}.xml`. `snippets/doha.xml`
  holds the 27 doha projects, **pinned to exact commits**; crDroid,
  LineageOS and AOSP projects follow branch/tag refs until
  `repo manifest -r -o default.xml` flattens the includes into a fully
  pinned manifest (the intended final state for a booting build).
- A patch file's path *is* the project path: `patches/kernel/motorola/msm-4.14.patch`
  applies inside `kernel/motorola/msm-4.14`; diff paths are relative to
  that project's root. crDroid replaces ~64 core projects with forks, so
  patches targeting them must be rebased on **crDroid's** file versions,
  not LineageOS's.
- `build.sh` is idempotent. A stamp (`<src>/.repo/doha-patches`) records,
  per patched project, the hash of the rendered patch blob and the
  worktree tree incl. untracked files. Unchanged patch + unchanged tree ⇒
  project untouched (mtimes kept, no rebuild); otherwise it is reset and
  re-applied. Removed/renamed patches are reverted.
- `@SKIN_THROTTLE_MC@` is the only placeholder: replaced with
  `SKIN_THROTTLE_C * 1000` when rendering. The rendered blob is what the
  stamp compares, so changing the variable re-applies the patch.

## Key Directories

| Path | Purpose |
| --- | --- |
| `default.xml` | crDroid manifest + our remotes/`<include>`s. 1067 `<project>` entries — do not hand-edit crDroid's entries; touch only our remotes/include/doha pins |
| `snippets/doha.xml` | The 27 `local::doha` projects (device trees, vendor blobs, kernel, HALs, AOSPA `device/qcom/*`, `vendor/qcom/common`), pinned; two `<remove-project>` entries for projects doha takes over |
| `snippets/crdroid.xml`, `snippets/lineage.xml` | Copied from crDroid **verbatim** — never edit; keep as upstream baseline for rebases |
| `patches/<project path>.patch` | One `git diff` per upstream project; the filename maps to the manifest path |
| `tools/gcp-build.sh` | Drives a full GCP VM build cycle (create/config/setup/build/finish, Drive backup, GitHub release) |

## Development Commands

```sh
# Full build via Docker (the image is a toolchain only; build.sh replaces
# its entrypoint, so the image's LineageOS patches never run)
docker run --rm -it --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/manifest:ro" \
  -v ~/android/crdroid-17.0:/src \
  -v ~/android/ccache/doha:/ccache -e CCACHE_DIR=/ccache \
  -v ~/doha/zips:/zips -e ZIP_DIR=/zips \
  --entrypoint /manifest/build.sh \
  lineageos4microg/docker-lineage-cicd:latest /src

# Without Docker (host with repo + AOSP build deps); SOURCE_DIR defaults to ./crdroid
./build.sh ~/android/crdroid-17.0

# Iterate on an existing tree (skip init/sync)
SKIP_SYNC=1 ./build.sh ~/android/crdroid-17.0

# Regenerate a patch after editing inside the synced tree
git -C ~/android/crdroid-17.0/kernel/motorola/msm-4.14 diff \
  > patches/kernel/motorola/msm-4.14.patch

# Cheap checks (the only ones — no test suite, linter or CI exists)
bash -n build.sh
bash -n tools/gcp-build.sh
```

Build-affecting environment variables (pass as `-e NAME=value` in Docker):

| Variable | Effect | Default |
| --- | --- | --- |
| `SKIP_SYNC=1` | skip `repo init`/`repo sync` | off |
| `JOBS` | compile jobs | `nproc` |
| `SYNC_JOBS` | repo sync jobs | `4` (Google's git servers 429 above this) |
| `REPO_DEPTH` | shallow clone depth | unset = full history (~100 GB) |
| `CCACHE_SIZE` | ccache limit | `50G` |
| `ZIP_DIR` | artifact destination | `zips/` next to the source dir |
| `SKIN_THROTTLE_C` | °C where the thermal HAL reports throttling | `40` |
| `VARIANT` | `userdebug`/`user`/`eng` | `userdebug` |
| `ADB_KEY` | test builds only: `adbkey.pub` baked into recovery+system; zip gets `-adbkey` suffix, **never distribute** | unset |
| `MANIFEST_URL`, `MANIFEST_BRANCH` | manifest source | this clone / its current branch |

## Code Conventions & Common Patterns

- **Shell**: plain bash, `set -euo pipefail`; `envsetup.sh`/`breakfast`/
  `mka` are sourced with `set +eu` and their exit codes checked by hand.
  Environment defaults via `${VAR:-default}`. Keep `build.sh` re-runnable.
- **Patches**: edit files inside a synced project, then regenerate with
  `git -C <project> diff > patches/<project path>.patch`. The patch must
  apply cleanly to the project's current revision — `build.sh` runs
  `git reset --hard && git clean -fd` first, so **new files must be part
  of the patch** (`git add -N` / stage before diffing) and hand edits in
  the tree are wiped on the next run.
- **Docs discipline**: every fix gets a README section naming its patch
  file(s) and the symptom; patch changes without a README update are a
  maintenance hazard. Follow "Changing a fix" in `CLAUDE.md`.
- **Commit before building**: `build.sh` refuses to run (without
  `SKIP_SYNC=1`) when `default.xml` is dirty — `repo` reads the committed
  manifest, patches come from the working tree.
- **Commit messages**: plain-language subject, optional area prefix
  (`build.sh:`, `README:`, `zygote_next:`, `gcp-build:`), tracking issue
  suffix `(doha_android#N)`; merges are
  `Merge <branch> into <branch>: <summary> (doha_android#N)`.
- **Branch policy**: device fixes flow `main` → `lineage-24.0` →
  `crdroid-android-17`; crDroid-specific work never flows back.

## Important Files

| File | Why it matters |
| --- | --- |
| `build.sh` | Only build entry point: sync, patch, build, artifact copy |
| `default.xml`, `snippets/*.xml` | Source pinning; `snippets/doha.xml` is ours, the other two are verbatim upstream |
| `patches/…` (21 files) | The actual product — each fix lives here, mirrored by a README section |
| `README.md` | Requirements, install/flash/GApps/Magisk steps, Status (what is tested), per-fix rationale |
| `CLAUDE.md` | Repo rules: manifest/patch/build mechanics and the editing workflow |
| `TODO.md` | Live hardware-issue worklist with on-device evidence (VoLTE, touch, charging, sensors) |
| `tools/gcp-build.sh` | Remote build + Drive backup + release publishing |

## Runtime/Tooling Preferences

- x86-64 Linux, bash, Docker (`lineageos4microg/docker-lineage-cicd`
  used as a toolchain container only) or a host with `repo` + AOSP build
  deps. Git LFS is required (`repo init … --git-lfs`).
- Resources: ~350 GB disk, ~100 GB RAM+swap for Soong's analysis step; a
  warm ccache makes rebuilds ~12 min.
- No Node/Bun/package manager — there is nothing to install or run here
  besides shell scripts and the Android build itself.
- `tools/gcp-build.sh` is the CI substitute: `create`, `config`, `setup`,
  `build`, `finish` on a GCP VM (`customrom-514215`, asia-south1); it
  mirrors `.repo`+ccache+zips to Drive (`rclone`) and publishes releases
  with `gh`. `REPO_DEPTH=1` keeps the first backup/egress cheap.

## Testing & QA

- **No test suite, no linter, no CI.** Do not invent test commands.
  `bash -n build.sh` is the only cheap check; for patches, reconstruct the
  touched files in a scratch git repo and run `git apply --check
  patches/<path>.patch`.
- Verification is a full build plus flashing to real hardware (A/B phone):
  `fastboot flash boot/dtbo`, `adb sideload crDroidAndroid-17.0-*.zip`.
  A failed compile or a bootloop is the feedback loop.
- `README.md` → "Status": the crDroid build is **not yet hardware-tested**;
  the tested checklist is inherited from the `lineage-24.0` build. Known
  issues: VoLTE depends on the modem's carrier profile, double-tap-to-wake
  is broken on FocalTech panels (Himax/Novatek/Egistec untested).
- `TODO.md` is the QA scratchpad: each item carries device evidence and a
  next step. Keep it updated when investigating hardware behaviour.
- State uncertainty explicitly: an untested patch must be called untested
  in the README (e.g. the Egistec fingerprint fix).
