# Building and installing crDroid 13 for doha — step by step

A practical walkthrough for someone starting from a clean machine. It covers
local and Google Cloud builds, the artifacts you get, flashing, GApps, root,
releasing, and the failures you are most likely to hit.

Read `README.md` for the design rationale; this file is the "just do it"
version.

## 0. What you need

- A Motorola Moto G8 Plus (`doha`, XT2019-1/2) with an **unlocked
  bootloader**.
- The latest stock firmware already installed on both slots (Android 10).
  The ROM does not ship Motorola firmware.
- Linux x86-64 host.
- Either:
  - Docker (easiest local build), or
  - A host with `repo` + AOSP build dependencies, or
  - A GCP project with `gcloud` (hands-off build; recommended for a laptop).
- Disk/time: a full build needs ~350 GB of scratch space and a lot of RAM.
  On GCP the script sizes this for you (12 vCPU, 64 GB RAM + 48 GB swap,
  375 GB NVMe; `SSD_COUNT=2` adds a second). A cold build takes hours (~9 h at 12 vCPU, ~6.5 h at 16); a warm rebuild
  takes minutes.
- Optional: an `adb`/`fastboot` setup on the machine you flash from.
- Optional for releases: a GitHub token (see §8).

## 1. Get the recipe

```sh
git clone -b crdroid-android-17 \
  https://github.com/ishwar-chandra/amogus_doha_custom_rom.git doha-crdroid
cd doha-crdroid
```

This repo holds only the manifest, the patches and the build driver. The
Android sources are fetched into a separate directory (`/src`).

## 2. Build

### 2.1 Local build with Docker

The image is only a toolchain; `build.sh` replaces its entrypoint, so the
image's own patches never run.

```sh
mkdir -p ~/android/crdroid-17.0 ~/android/ccache/doha ~/doha/zips

docker run --rm -it --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/manifest:ro" \
  -v ~/android/crdroid-17.0:/src \
  -v ~/android/ccache/doha:/ccache -e CCACHE_DIR=/ccache \
  -v ~/doha/zips:/zips -e ZIP_DIR=/zips \
  --entrypoint /manifest/build.sh \
  lineageos4microg/docker-lineage-cicd:latest /src
```

### 2.2 Local build without Docker

```sh
./build.sh ~/android/crdroid-17.0     # SOURCE_DIR defaults to ./crdroid
SKIP_SYNC=1 ./build.sh ~/android/crdroid-17.0   # iterate, keep the tree
```

Useful variables (all optional, also accepted as `-e NAME=value` in Docker):

| Variable | Effect | Default |
| --- | --- | --- |
| `SKIP_SYNC=1` | skip `repo init`/`repo sync` | off |
| `JOBS` | compile jobs | `nproc` |
| `SYNC_JOBS` | repo sync jobs | `4` (higher gets HTTP 429) |
| `REPO_DEPTH` | shallow clone depth | unset = full history |
| `CCACHE_SIZE` | ccache limit | `50G` |
| `ZIP_DIR` | artifact destination | `zips/` next to the source |
| `SKIN_THROTTLE_C` | thermal-HAL throttling temperature | `40` |
| `VARIANT` | `userdebug`/`user`/`eng` | `userdebug` |
| `DEBLOAT` | `1` drops the optional crDroid extras; zip gets a `-debloat` suffix | `0` |
| `ADB_KEY` | test only: bake an `adbkey.pub` into the build (on GCP: `ADB_KEY=~/.android/adbkey.pub ./tools/gcp-build.sh build`) | unset |
| `MANIFEST_URL`, `MANIFEST_BRANCH` | manifest source | this clone / its branch |

`build.sh` refuses to start (without `SKIP_SYNC=1`) if `default.xml` is
dirty: `repo` reads the committed manifest, patches come from the working
tree.

### 2.3 Build on a GCP VM (the script)

The script provisions a VM, syncs, builds, backs up and can publish a
release. Commands (run from the repo root, `gcloud` in `PATH`):

```sh
tools/gcp-build.sh create     # VM + 375 GB NVMe (SSD_COUNT=2 adds a second)
tools/gcp-build.sh config     # copy ~/.config/rclone/rclone.conf to the VM
tools/gcp-build.sh setup      # install deps, clone the recipe
tools/gcp-build.sh build      # start sync+build in tmux
tools/gcp-build.sh state      # exit file, tmux, last log lines
tools/gcp-build.sh logs       # tail -f the build log
tools/gcp-build.sh att        # attach to the tmux session (Ctrl-b d to detach)
tools/gcp-build.sh fetch      # copy zips/ to ./gcp-out locally
tools/gcp-build.sh finish     # wait, verify, back up, release, delete
TAG=crdroid-20261117-standard tools/gcp-build.sh release   # release only
TAG=… OTA_DRY=--dry-run tools/gcp-build.sh ota             # print the feed JSON
TAG=crdroid-20261117-standard tools/gcp-build.sh ota       # write <channel>/doha.json
tools/gcp-build.sh delete     # delete the VM now
```

Typical session: `create; config; setup; build; finish`.

Knobs: `VARIANT`, `DEBLOAT` (`1` = debloat variant, zip gets `-debloat`), `JOBS`,
`SYNC_JOBS`, `REPO_DEPTH` (default `1`), `SWAP_GB`, `HOURS` (hard stop/auto-delete,
default 48), `NO_RELEASE=1`, `NO_OTA=1`, `NO_DELETE=1`, `TAG=...`.

The VM self-deletes after `HOURS`. A failed build leaves the VM alive for
log reading; `finish` exits before deleting anything.

### 2.4 Backups and restores

`finish` backs up `src/.repo` (~33 GB), `ccache`, `zips` and the recipe
clone to Google Drive (`rclone` remote `gdrive`). Restore on a new VM:

```sh
tools/gcp-build.sh create
tools/gcp-build.sh config
tools/gcp-build.sh setup
tools/gcp-build.sh restore    # pull .repo + ccache + zips + manifest
tools/gcp-build.sh build      # sync re-creates worktrees from local objects
```

Drive uses rclone's shared OAuth client by default, which is **rate
limited** (`rateLimitExceeded`, uploads crawl). Two fixes:

1. **Your own OAuth client** (best): Cloud Console → APIs & Services →
   Credentials → Create OAuth client ID → Desktop app; put the id/secret in
   `~/.config/rclone/rclone.conf` for the `gdrive` remote, then
   `rclone config reconnect gdrive:`. While the app is in "Testing", add
   your Google account under **OAuth consent screen → Test users** or you
   get `Error 403: access_denied`.
2. **GCS bucket** (no OAuth, works immediately with the VM's service
   account):

   ```sh
   gcloud storage buckets create gs://<project>-doha-backup \
     --project <project> --location asia-south1
   ```

   On the VM add to `~/.config/rclone/rclone.conf`:

   ```ini
   [gcs]
   type = google cloud storage
   env_auth = true
   project_number = <project number>
   ```

   Then mirror the same layout:

   ```sh
   B=gcs:<project>-doha-backup
   rclone sync /mnt/build/src/.repo $B/src/.repo \
     --exclude "/**/hooks/*.sample" --transfers 16 --checkers 32
   rclone sync /mnt/cache/ccache $B/ccache
   rclone sync /mnt/build/zips   $B/zips
   rclone sync /mnt/build/manifest $B/manifest
   ```

   Restore is the mirror (`rclone sync $B/src/.repo /mnt/build/src/.repo`,
   etc. on the new VM). Delete the bucket when you no longer need it.

## 3. What the build produces

In `ZIP_DIR` (VM: `/mnt/build/zips`):

| File | What |
| --- | --- |
| `crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip` | flashable OTA |
| `boot.img` | kernel + recovery ramdisk |
| `dtbo.img` | device tree overlay (touch in recovery on Tianma panels) |
| `vbmeta.img` | verity-disabled vbmeta |
| `crDroidAndroid-...zip.sha256sum` | checksums for all four |

The zip keeps its versioned name; the images use plain names, as in most
custom-ROM builds.

## 4. Flash it

You need an unlocked bootloader. The phone is A/B; recovery lives in
`boot`. Do the **first test without GApps** so a failure is attributable to
the ROM, not to Google apps.

### 4.1 From stock or another ROM

`tools/flash.sh` runs this section end to end: it lists the artifact sets in
`gcp-out/` (only complete ones are selectable), verifies checksums and flashes.
`--list` shows what is there without touching the phone, `--dry-run` prints the
commands.

```sh
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
# only if you hit verification errors; the anti-rollback warning is expected:
# fastboot flash vbmeta vbmeta.img
```

Then boot recovery:

1. **Factory reset → Format data** (required when coming from another ROM).
2. **Apply update → Apply from ADB**, then:
   `adb sideload crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip`
3. When asked about additional packages, answer **No** for the vanilla test.
   **Reboot system now.**
4. The first boot can take several minutes. Leave it alone.

### 4.2 Updating an existing install

```sh
adb reboot sideload-auto-reboot
adb wait-for-sideload
adb sideload crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip
```

This keeps data but **removes GApps** — re-sideload them in the same
recovery session if you use them. Recovery installs to the inactive slot;
keep a known-good ROM on the other slot until the new one boots.

## 5. Google apps (optional)

Do this only after the vanilla build boots and works. Pick **one** package
and flash it in the same recovery session as the ROM, before first boot:

- **MindTheGapps 17.0.0 arm64** — verified to fit this device with ~70 MB
  spare. https://github.com/MindTheGapps/17.0.0-arm64/releases
- **NikGapps-crdroid-official-arm64-17** — crDroid's own package, ~486 MB,
  in [crDroid's gapps folder](https://sourceforge.net/projects/crdroid/files/gapps/)
  (`NikGapps-crdroid-official-arm64-17-*.zip`).

```sh
adb sideload <gapps>.zip    # confirm the signature warning ("Yes")
```

Rules:

- Both must be Android **17** and **arm64**.
- Adding GApps after first boot requires a factory reset.
- Sideloaded ROM updates remove them; re-flash the same package each time.
- If recovery says "Insufficient storage", use a smaller package
  (MindTheGapps, or NikGapps Core ~140 MB).

## 6. Root (optional)

Magisk: patch the release's `boot.img` in the Magisk app (Install → Patch
firmware/image), then

```sh
adb reboot bootloader
fastboot flash boot magisk_patched-*.img
```

Every ROM update replaces `boot.img`, so repeat after updating.

## 7. Verify the build

Checklist (from `README.md` → Status), on real hardware:

- Boot; touch in Android and in recovery; all four cameras; fingerprint.
- Calls both ways, SMS, mobile data; Wi-Fi; speaker, wired and Bluetooth
  audio.
- GApps (if used): setup wizard, sign-in, Play Store.
- Magisk (if used).
- Known issues: VoLTE depends on the modem carrier profile; double-tap to
  wake is dead on FocalTech panels; first boot may be 2G-only (one reboot
  fixes it).

If it bootloops: from recovery, `adb shell cat
/sys/fs/pstore/console-ramoops-0`; from Android, `adb logcat`. Note
`ro.debuggable=0`, so `adb root`/`dmesg` are not available.

## 8. Publish a release

```sh
printf '%s' 'github_pat_...' > ~/.config/crdroid-gh-token && chmod 600 ~/.config/crdroid-gh-token
tools/gcp-build.sh gh-check     # token, repo, tag availability
tools/gcp-build.sh finish       # ... publishes tag crdroid-<today>
```

The token needs **Contents: read and write** on the repo (fine-grained) or
the `repo` scope (classic). `NO_RELEASE=1` skips publishing,
`NO_DELETE=1` keeps the VM.

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `default.xml has uncommitted changes` | `repo` reads the committed manifest | commit `default.xml`, or `SKIP_SYNC=1` |
| `not well-formed (invalid token)` in `snippets/*.xml` | `--` inside an XML comment | never put `--` in comments; re-validate with `python3 -c 'import xml.dom.minidom as m; m.parse("snippets/doha.xml")'` |
| build exits 1 at `lstat .../Settings/oat` | old `mka target-files-package bacon` raced crDroid's cleanup | the fix is in `build.sh` (`mka bacon` only); pull the repo and rebuild |
| `build.exit` missing, "no exit file yet" | still building | `tools/gcp-build.sh state` / `logs`; ninja % is action count, not time |
| `scp` of a 1.2 GB file dies (`Broken pipe`) | gcloud scp tunnel drops | use `rclone`/Drive or `gcp-out` fetch in the background |
| rclone `rateLimitExceeded` | shared Drive client quota | own OAuth client (§2.4) or the GCS bucket |
| OAuth `Error 403: access_denied` | OAuth app in Testing, account not a tester | add your account under OAuth consent screen → Test users |
| GApps "Insufficient storage" | system partition too small | MindTheGapps (verified) or NikGapps Core |
| `adb root`/`dmesg` denied | `ro.debuggable=0` (spoofed props) | use `logcat`; pstore from recovery |
| First boot only 2G | modem/SIM init | reboot once |
| VoLTE missing | carrier profile not in modem | see README known issues; not ROM-fixable |

## 10. Changing the ROM (patches)

- The product is `patches/<project path>.patch`; the path is the manifest
  project path (`patches/kernel/motorola/msm-4.14.patch` applies inside
  `kernel/motorola/msm-4.14`).
- Edit inside the synced tree, then regenerate:
  `git -C <src>/<project> diff > patches/<project path>.patch`.
  New files must be staged (`git add -N`) or they will not be in the diff;
  `build.sh` resets and cleans patched projects on every run.
- Every fix needs a README section naming the patch and the symptom.
- `@SKIN_THROTTLE_MC@` is the only placeholder (rendered from
  `SKIN_THROTTLE_C`); the stamp `<src>/.repo/doha-patches` decides whether a
  project is re-patched.
- Branch policy: device fixes flow `main` → `lineage-24.0` →
  `crdroid-android-17`; never merge crDroid work back.

Commit messages: plain-language subject, optional area prefix
(`build.sh:`, `README:`), issue suffix `(doha_android#N)`.

## 11. Costs and cleanup

- `finish` deletes the VM after a successful release; `NO_DELETE=1` keeps it
  (~$1/h for 12 vCPU + 64 GB).
- Storage shape, two options (`create`):
  - `DISK_MODE=local` (default): 2x 375 GB local SSD = 750 GB for ~$0.099/h. GCP only attaches local SSDs in
    pairs (0, 2, 4, 8, 16, 24), so a single 375 GB device cannot be bought; about 331 GB of the 750 is used.
    Fastest by far (several GB/s), and the tree dies with the instance.
  - `DISK_MODE=pd [DATA_DISK_GB=400] [DATA_DISK_TYPE=pd-ssd]`: no local SSD, one exactly-sized data disk at
    /mnt/build for ~$0.093/h at 400 GB pd-ssd. No idle capacity, and `DATA_DISK_KEEP=1` keeps the disk after the
    instance goes (so a later VM resumes without a 1,280-project sync) at ~$68/month idle. Cost of the trade:
    pd-ssd sustains roughly 0.5 MB/s per GB (about 190 MB/s at 400 GB), so the compile takes noticeably longer
    -- check `DATA_DISK_TYPE=pd-balanced` only if you accept it being slower still for ~$0.03/h less.
- `CPUS_ALL_REGIONS` is **12** on this project, so 12 vCPU is the widest machine that can be created; the
  regional limit (32) does not help. `create` preflights the quota and refuses a wider machine with that reason
  instead of failing inside gcloud. After an increase, `MACHINE=n2-custom-16-49152` (or 24) works unchanged.
- `HOURS` (default 48) is a hard stop that deletes the VM even if forgotten; the boot disk is created with
  `--no-boot-disk-auto-delete`, so `~/.repo-backup` (a copy of `.repo`) survives and a later VM can mount it
  instead of re-syncing.
- The backup destination is your own Drive (`gdrive:doha-backup` by default),
  which costs nothing extra. If you back up to the GCS bucket instead
  (option 2 in §2.3), that bucket keeps billing until deleted: 46 GB standard
  in asia-south1 is roughly $1/month — `gcloud storage rm -r gs://<bucket>`.

## 12. Where to look

| File | What |
| --- | --- |
| `README.md` | authoritative design record, per-fix rationale, Status |
| `CLAUDE.md` / `AGENTS.md` | repo mechanics for humans/AI assistants |
| `TODO.md` | live hardware-issue list with device evidence |
| `build.sh` | sync → patch → build → artifacts |
| `tools/gcp-build.sh` | GCP cycle, backup/restore, release |