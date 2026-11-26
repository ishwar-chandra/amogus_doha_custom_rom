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
  On GCP the script sizes this for you (12 vCPU, 48 GB RAM + 32 GB swap, one
  50 GB boot disk plus two 375 GB local NVMe). A cold build takes hours (~9 h at 12 vCPU, ~6.5 h at 16); a warm rebuild
  takes minutes. The local NVMe pair is the default.
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

The script provisions a VM, syncs, builds and publishes a release. Commands
(run from the repo root, `gcloud` in `PATH`):

```sh
tools/gcp-build.sh create     # VM + two 375 GB local NVMe
tools/gcp-build.sh setup      # install deps, clone the recipe
tools/gcp-build.sh build      # start sync+build in tmux
AUTO_FINISH=1 tools/gcp-build.sh build   # wait, release, update OTA, delete
tools/gcp-build.sh state      # exit file, tmux, last log lines
tools/gcp-build.sh logs       # tail -f the build log
tools/gcp-build.sh att        # attach to the tmux session (Ctrl-b d to detach)
tools/gcp-build.sh fetch      # copy zips/ to ./gcp-out locally
tools/gcp-build.sh finish     # wait, verify, release, update OTA, delete
TAG=crdroid-20261118 tools/gcp-build.sh release   # release only (one tag: all variants)
OTA_CHANNEL=debloat TAG=crdroid-20261118 tools/gcp-build.sh ota   # write <channel>/doha.json
OTA_CHANNEL=test TAG=crdroid-20261126 AUTO_FINISH=1 tools/gcp-build.sh build  # tester feed
tools/gcp-build.sh promote crdroid-20261126   # tested test build -> standard (--dry-run first)
tools/gcp-build.sh delete     # delete the VM now
```

Typical session: `create; setup; build; finish`.

Knobs: `VARIANT`, `DEBLOAT` (`1` = debloat variant, zip gets `-debloat`), `JOBS`,
`SYNC_JOBS`, `REPO_DEPTH` (default `1`), `SWAP_GB`, `HOURS` (hard stop/auto-delete,
default 48), `TAG=...`, `OTA_CHANNEL=standard|debloat|test`, `NO_RELEASE=1`, `NO_OTA=1`,
`NO_DELETE=1`.

The VM self-deletes after `HOURS`. A failed build leaves the VM alive for
log reading; `finish` exits before deleting anything.

### 2.4 No persistent backup

There is no Drive, rclone, GCS or `.repo` backup. The VM is disposable:
after a successful build `finish` publishes the zip and images to the GitHub
release, updates the OTA feed, and deletes the VM. A later build re-syncs and
rebuilds; `ccache` and `.repo` do not survive the VM. Use `fetch` if you want
the artifacts locally before `finish` deletes the machine.

### 2.5 Both variants on one VM

```sh
tools/gcp-build-both.sh
```

This creates one VM (`crdroid-build` by default), builds **standard**, runs
`finish` with `NO_DELETE=1` so the VM survives, then builds **debloat** on the
same VM and runs the final `finish` (which releases and deletes). Both
`finish` calls use the same `TAG`, so the two variants land in one release;
each updates only its own OTA channel.

Defaults: `MACHINE=n2-custom-12-49152` (the full `CPUS_ALL_REGIONS` quota).
The builds are sequential; the second waits for the first `finish` to finish.
`GH_TOKEN` (or the token file) and the other `gcp-build.sh` variables pass
through. If the standard build or release fails, the wrapper stops and keeps
the VM for inspection.

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

### 4.3 After first boot: optional per-device tuning

The ROM already carries the memory, queue and read-ahead changes. Two further
levers stay outside the build because they are reversible user-space state, not
artifacts; both are safe to skip and both can be undone.

The ROM does not compile apps automatically at first boot. Run the compile once
after installing apps, then use these for re-running it on demand and for
trimming GMS background work.

```sh
tools/dexopt-all.sh              # compile all apps now, instead of waiting for the
                                 # charging+idle bg-dexopt-job to get round to it
tools/gms-trim.sh --list         # Google Play Services background work, grouped
tools/gms-trim.sh                # default groups: ads, analytics, stats reporting
tools/gms-trim.sh -g all         # also Wallet/tap-to-pay, Quick Share, Play Games, Fitness
tools/gms-trim.sh --restore      # re-enable everything the tool disabled
```

Play Integrity is a separate story — the vendor keymaster on doha refuses attestation, so the
built-in TrickyStore needs a keybox that this kit does not ship or download:

```sh
tools/integrity-setup.sh status            # GApps, PIF config, keybox, boot props
tools/integrity-setup.sh import keybox.xml # same Settings keys the crDroid UI writes
tools/integrity-setup.sh check             # open KeyAttestation and read the chain
tools/integrity-setup.sh clear             # remove the keybox again
```

`gms-trim.sh` needs a build where the shell may change component state. If the
phone has Magisk/KernelSU it detects the root shell and runs `su -c pm ...`; on a
plain unlock it prints `denied` per component, disables nothing and exits non-zero. Disabled components are stored in `/data`, so they survive OTA updates
and re-flashing a new ROM zip without a data wipe.

## 4.4 Publishing without babysitting the build

`tools/gcp-build.sh auto-finish` hands the whole tail of the cycle to the VM: it
copies the script's own remote half (`~/doha-remote.sh`) and a small chain
(`~/doha-chain.sh`) there, stages the GitHub token as `~/.gh_token_master`, and
starts it in tmux session `publish`. The chain waits for the first build to exit,
verifies its checksums, **builds the second variant**, verifies that too, and only
then publishes: one release carrying both variants, followed by both OTA channels.
Publishing per variant is deliberately avoided — the first release would offer only
one variant for the hour the second build takes, and people on the other channel
would download the wrong zip. Each variant's `build.prop` is saved as
`~/build.prop.<channel>` right after its build, because `out/` only holds the last
variant's. Nothing after the call belongs to the workstation, so a dropped
connection cannot leave a finished build unpublished. The VM is never deleted.

```sh
TAG=crdroid-20261120 tools/gcp-build.sh auto-finish      # build both + publish
FIRST_VARIANT=1 TAG=... tools/gcp-build.sh auto-finish   # if the running build is debloat
gcloud compute ssh <vm> --command 'tail -f ~/doha-chain.log'
```

The token is shredded at the end of the chain (`shred -u ~/.gh_token_master`), and
the VM keeps its 48 h `--max-run-duration` deletion timer.

This is the only publishing path: `auto-finish` always releases once both variants
verify. `finish` keeps its own `NO_RELEASE=1` / `NO_OTA=1` / `NO_DELETE=1` switches
for a single already-built variant.

## 4.5 Backing up and restoring the full build tree (Google Drive)

`tools/drive-backup.sh` is deliberately **separate** from the build/release chain —
nothing in `tools/gcp-build.sh` or `build.sh` depends on Drive. To delete the VM
between sessions without paying for another 9-hour cold build, it streams three
compressed archives (`ccache.tar.zst`, `src-tree.tar.zst`, `out.tar.zst`) to your
personal Google Drive via `rclone` (GCP ↔ Drive transfer is free, and streaming
archives avoids Drive's per-file API limit while preserving POSIX permissions,
symlinks and mtimes):

```sh
# After a build finishes (or BACKUP_WAIT=1 to wait for an active build/chain):
tools/drive-backup.sh backup
BACKUP_WAIT=1 tools/drive-backup.sh backup
tools/drive-backup.sh status
gcloud compute ssh crdroid-build --zone asia-south1-a --command 'tail -f ~/backup.log'

# On a fresh VM later:
tools/gcp-build.sh create && tools/gcp-build.sh setup
tools/drive-backup.sh restore
gcloud compute ssh crdroid-build --zone asia-south1-a --command 'tail -f ~/restore.log'
```

Defaults: `RCLONE_CONF=~/.config/rclone/rclone.conf`,
`BACKUP_REMOTE=gdrive:doha-backup/crdroid-17.0`. Pass `SKIP_OUT=1` to skip
`out.tar.zst` (useful if you need a clean `out/` rebuild).

The Drive remote needs a re-auth roughly every 7 days. The OAuth client lives in
Google Cloud project `gen-lang-client-0544155453` and that app is still in
**Testing** publishing status, so Google expires its refresh tokens after 7 days
(`unauthorized_client` from rclone). Two symptoms and their fix:

- `unauthorized_client` -> `rclone config reconnect gdrive:` (browser opens;
  rclone catches the redirect on `http://127.0.0.1:53682/` itself).
- `Error 403: access_denied ... can only be accessed by developer-approved
  testers` -> add the Google account under **Test users** on
  `console.cloud.google.com/apis/credentials/consent?project=gen-lang-client-0544155453`,
  then reconnect.
- To stop the 7-day cycle, set that consent screen's publishing status to
  **In production** (Google then shows an "unverified app" warning, which is
  acceptable for a personal client).

`build.sh`/`gcp-build.sh` never depend on Drive: a failed backup leaves the
release and OTA update intact, and `tools/gcp-build.sh backup` can be re-run at
any time while the VM still exists.

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
the `repo` scope (classic), and the same write access to the feed repo
`$OTA_REPO` (`ishwar-chandra/doha-ota`) — `ota`/`promote` commit the JSON there.
`NO_RELEASE=1` skips publishing, `NO_DELETE=1` keeps the VM.

### 8.1 Test channel, then promote

A test build is the artifact you will ship; it just points at `test/doha.json`.

```sh
OTA_CHANNEL=test TAG=crdroid-20261126 AUTO_FINISH=1 tools/gcp-build.sh build
# install that zip once: System Update -> Install local update (keeps GApps)
tools/gcp-build.sh promote crdroid-20261126 --dry-run   # inspect the JSON
tools/gcp-build.sh promote crdroid-20261126             # writes standard/doha.json
```

- Install the first `test` build once with **System Update -> Install local
  update**; after that the device follows `test/doha.json` like any other build.
  Stable builds never read that path, so nobody else is offered a test build.
- The local-update path runs `UpdateEngine`/addon.d-v2, so GApps survive; a
  recovery sideload does not, hence the one-time install is not a sideload.
- `promote` refuses a different tag, a `-debloat`/`-adbkey` artifact, or a build
  not newer than the one `standard` already advertises. It runs on this machine,
  needs only the token, and rebuilds nothing.

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `default.xml has uncommitted changes` | `repo` reads the committed manifest | commit `default.xml`, or `SKIP_SYNC=1` |
| `not well-formed (invalid token)` in `snippets/*.xml` | `--` inside an XML comment | never put `--` in comments; re-validate with `python3 -c 'import xml.dom.minidom as m; m.parse("snippets/doha.xml")'` |
| build exits 1 at `lstat .../Settings/oat` | old `mka target-files-package bacon` raced crDroid's cleanup | the fix is in `build.sh` (`mka bacon` only); pull the repo and rebuild |
| `build.exit` missing, "no exit file yet" | still building | `tools/gcp-build.sh state` / `logs`; ninja % is action count, not time |
| `scp` of a 1.2 GB file dies (`Broken pipe`) | gcloud scp tunnel drops | use `gcp-out` fetch in the background |
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
  (~$1/h for 12 vCPU + 48 GB).
- Storage shape (`create`):
  - Default: one 50 GB `pd-standard` boot disk plus **2×375 GB local NVMe**
    (750 GB). The first NVMe holds the tree and `out/`; the second holds
    ccache and swap. Local NVMe is fastest and dies with the instance.
  - `SSD_COUNT=0` switches to a single boot disk; `DISK=500GB` with
    `DISK_TYPE=pd-standard` is the quota-safe option. A 500 GB `pd-ssd` is
    refused because `SSD_TOTAL_GB` is 250 GB in this region.
  - `DISK_MODE=pd [DATA_DISK_GB=400] [DATA_DISK_TYPE=pd-ssd]`: optional
    separate data disk at `/mnt/build`; `DATA_DISK_KEEP=1` keeps it after the
    instance goes at extra cost.
- `CPUS_ALL_REGIONS` is **12** on this project, so 12 vCPU is the widest machine that can be created; the
  regional limit (32) does not help. `create` preflights the quota and refuses a wider machine with that reason
  instead of failing inside gcloud. After an increase, `MACHINE=n2-custom-16-49152` (or 24) works unchanged.
- `HOURS` (default 48) is a hard stop that deletes the VM even if forgotten. There is
  no persistent tree or ccache: a later VM re-syncs and rebuilds.
- Nothing is uploaded to Drive or GCS. After a successful build, only the GitHub
  release and its OTA feed survive the VM.

## 12. Where to look

| File | What |
| --- | --- |
| `README.md` | authoritative design record, per-fix rationale, Status |
| `CLAUDE.md` / `AGENTS.md` | repo mechanics for humans/AI assistants |
| `TODO.md` | live hardware-issue list with device evidence |
| `build.sh` | sync → patch → build → artifacts |
| `tools/gcp-build.sh` | GCP cycle, release and OTA feed; no backup |