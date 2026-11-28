# crDroid 13 (Android 17) for the Moto G8 Plus (amogus_doha)

This repo has everything needed to rebuild our unofficial **crDroid 13
(Android 17)** ROM for the **Motorola Moto G8 Plus** (`doha`, XT2019-1/2,
Snapdragon 665). In the source tree the device is called **`amogus_doha`**.

The repo has three parts:

| Path | What it is |
| --- | --- |
| `default.xml` | crDroid's `repo` manifest, plus our `snippets/doha.xml` with the device projects. The doha projects are pinned to exact commits |
| `patches/` | Our fixes. `patches/<project path>.patch` applies to that project |
| `build.sh` | Syncs the sources, applies the patches and builds the zip |

The manifest is built on crDroid's own
([`crdroidandroid/android`](https://github.com/crdroidandroid/android),
branch `17.0`): `snippets/crdroid.xml` and `snippets/lineage.xml` are
copied from there unchanged, `default.xml` is their `default.xml` with
our remotes and an extra include, and `snippets/doha.xml` holds the 28
doha projects (device, vendor, kernel, HALs and the AOSPA trees the port
uses). crDroid's vendor tree is checked out at `vendor/lineage`, so the
device trees' `vendor/lineage/config/*.mk` inheritance works as-is.

The device tree and vendor blobs come from the community doha port by
Aldair402 and moto-common. We didn't write those. Our work is the
patches that get that port building and booting on Android 17.

The kernel is our fork of Christiaan's `android_kernel_motorola_msm-4.14`:
[`ishwar-chandra/android_kernel_motorola_msm-4.14`](https://github.com/ishwar-chandra/android_kernel_motorola_msm-4.14),
currently pinned to `def1be59` on branch `lts`, which carries the
4.14.357 baseline on top of the `fix` work. Aldair402's kernel is Motorola's 4.14.190. Ours merges the
4.14 LTS updates up to 4.14.357 (OpenELA) on top of it, so it carries
several years of upstream security and stability fixes. `uname -r` shows
`4.14.357-openela+`.

The LineageOS 24.0 (Android 17) version of this ROM, with the same
device work, is on the `lineage-24.0` branch. There is no `main` branch:
this checkout is `crdroid-android-17` (integration) or `performance-tuning`
(daily work), depending on what is checked out.

New here? [`docs/GUIDE.md`](docs/GUIDE.md) walks through a build end to end: local and
GCP, flashing, GApps, releasing and troubleshooting.

## Requirements

- **x86-64 Linux** with Docker. The build runs inside the
  [`lineageos4microg/docker-lineage-cicd`](https://github.com/lineageos4microg/docker-lineage-cicd)
  image, which has all the build tools and `repo` installed. It is used
  only as a toolchain container: `build.sh` replaces its entrypoint, so
  the LineageOS patches that image normally applies (including the
  SafetyNet one) never run. To build without Docker, install the
  [LineageOS build dependencies](https://wiki.lineageos.org/emulator#install-the-build-packages)
  and `repo` first.
- **About 350 GB of free disk**: roughly 200 GB for the synced sources and
  120 GB for `out/`. ccache adds up to 50 GB more if you enable it.
  On btrfs (or XFS) you can save most of the source part by starting from
  a checkout you already have: `cp -a --reflink=always <that tree>
  <source dir>` shares its files and git history instead of copying
  them. The LineageOS 24.0 tree on `lineage-24.0` works well for this:
  most projects are the same AOSP and LineageOS repositories, and only
  crDroid's own forks are fetched. Move its
  `.repo/local_manifests/*.xml` out of the copy first;
  `build.sh` then syncs it to this manifest and only downloads what
  differs. The sync doesn't remove the other tree's own changes, though:
  run `repo status` and revert or remove everything except the projects
  `build.sh` patches, and move out folders that no project in
  `default.xml` covers (`repo list -p` lists the projects). A plain
  checkout that no device has touched avoids that: we keep one in
  `~/android/base/crdroid-17.0` (`repo init -u
  https://github.com/crdroidandroid/android.git -b 17.0 --git-lfs`, then
  `repo sync`) and copy it for each new tree.
- **About 100 GB of memory, RAM plus swap.** Soong's analysis step for
  Android 17 needs far more than 23.2 did. We build with 30 GB RAM
  and a 72 GB swap file; it works, but the analysis step is slow while
  it swaps.
- A fast internet connection. The first sync downloads about 100 GB of
  git history.
- Time. A rebuild with a warm ccache takes about 12 minutes; one that
  follows a monthly crDroid update about an hour.

## Building

```sh
git clone -b crdroid-android-17 https://github.com/ishwar-chandra/amogus_doha_custom_rom.git doha-crdroid
mkdir -p ~/android/crdroid-17.0 ~/android/ccache/doha ~/doha/zips

docker run --rm -it \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/doha-crdroid:/manifest:ro" \
  -v ~/android/crdroid-17.0:/src \
  -v ~/android/ccache/doha:/ccache -e CCACHE_DIR=/ccache \
  -v ~/doha/zips:/zips -e ZIP_DIR=/zips \
  --entrypoint /manifest/build.sh \
  lineageos4microg/docker-lineage-cicd:latest /src
```

Without Docker, run `./build.sh ~/android/crdroid-17.0` from the clone.

For GCP, `tools/gcp-build.sh` reads the project from `gcloud config` and
discovers the running VM (preferring `labels.doha-build=1`; `create` sets
it). `NAME`/`ZONE` select one when two VMs are active; no instance name is
hardcoded.

Both `build.sh` and `tools/gcp-build.sh` build the branch checked out in the
clone: from `performance-tuning` they build that branch, and from
`crdroid-android-17` they build the release line. There is no silent default.

`build.sh` does the following:

1. Runs `repo init` against `default.xml` on the branch checked out in this
   clone, and then `repo sync`. repo reads the committed manifest, so the
   script stops if `default.xml` has uncommitted changes. The doha projects
   are pinned to exact commits. The crDroid, LineageOS and AOSP projects
   follow crDroid's branch and tag refs until the manifest is pinned to a
   snapshot (see [Pinning the sources](#pinning-the-sources)).
2. Resets each patched project and applies its patch from `patches/`, so
   you can run the script again safely. A project whose patch and files are
   unchanged since the last run is left alone, so its files keep their
   timestamps and the build doesn't redo work. A project whose patch was
   deleted is reset to its synced commit.
3. Creates the empty file `device/motorola/amogus_doha/kernel-headers`
   (see [the kernel headers fix](#kernel-headers)).
4. Runs `breakfast amogus_doha userdebug` and `mka bacon`.
5. Copies the zip and its `-boot.img`, `-dtbo.img` and `-vbmeta.img`
   (prefixed with the zip name) into `~/doha/zips`, with a `.sha256sum`
   file.

The output is
`~/doha/zips/crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip`, next to
`crDroidAndroid-17.0-<date>-amogus_doha-v13.1-boot.img`, `-dtbo.img` and
`-vbmeta.img`, plus the zip's `.sha256sum` file. The
copies are worth keeping: crDroid's `bacon` renames the OTA zip in `out/`
to that `crDroidAndroid-*.zip` name and deletes the target-files
intermediates it was built from, so `build.sh` takes the images straight
out of `out/target/product/amogus_doha/` and keeps a real copy of every
build. A second build on the same day replaces that day's files in
`~/doha/zips`.

The device is built from the ordinary `lineage_amogus_doha` product: the
device trees in `device/motorola/targets` name their product that way and
inherit `vendor/lineage/config/common_full_phone.mk`, which is crDroid's
vendor tree here and pulls in crDroid's own packages and settings.

Variants: `DEBLOAT=1` builds the same ROM without the optional crDroid extras
(Game Space, floating windows, battery stats viewer, MatLog, the Twelve music
player, Recorder and Glimpse gallery); the zip is named `...-debloat.zip`. Calls,
SMS, camera, the file picker, calendar storage and OTA are untouched by it.
One-click updates use a self-hosted feed and per-channel guard: a standard build
reads `standard/doha.json`, a debloat build reads `debloat/doha.json`. The feed
is generated automatically by `tools/gcp-build.sh finish`; it requires the
public `ishwar-chandra/doha-ota` repo and a token with write access to it. Until
that one-time setup exists, the Updater has nothing to download.

A third feed, `test/`, is the maintainer channel. `OTA_CHANNEL=test` bakes it
into a standard build (`DEBLOAT=0`) and `finish` writes `test/doha.json`; only a
device that installed that build once follows it. Install the first one from
System Update -> **Install local update** (same `UpdateEngine` path as an OTA,
so GApps survive), not by recovery sideload (they do not). After testing,
`tools/gcp-build.sh promote <tag>` copies the tested entry into
`standard/doha.json` without rebuilding, so stable devices receive exactly the
artifact that was tested; their Updater ignores it once it is already installed.
The `-debloat` suffix guard is unchanged, which is why the test channel carries
standard builds only.

The debloat variant also hides the settings entries that pointed at the removed
apps. `packages/apps/crDroidSettings.patch` walks the preference tree once it is
inflated and hides any preference whose embedded intent names a package that is
not installed (Gaming mode -> `io.chaldeaprjkt.gamespace`, Sidebar ->
`com.libremobileos.sidebar`, and any empty category left behind), so one XML
serves both variants instead of a build-time resource fork. Entries whose app is
still shipped (OmniJaws weather) stay visible. Search results are indexed from
the XML at build time, so a hidden entry can still be found by Settings search;
tapping it does nothing.

Options: `JOBS=<n>` sets the build job count (the default is `nproc`).
`SYNC_JOBS=<n>` sets the sync job count (the default is 4). Keep it low:
android.googlesource.com rate-limits parallel fetches with `HTTP 429` /
`RESOURCE_EXHAUSTED`. If a sync still fails that way, wait a few minutes and
run the script again; it picks up where it stopped. `SKIP_SYNC=1` skips
`repo init` and `repo sync` on later runs. `CCACHE_SIZE=<size>` sets the
ccache limit (the default is `50G`). `ZIP_DIR=<dir>` changes where builds
are copied (the default is `zips/` next to the source directory).
`MANIFEST_BRANCH=<branch>` syncs a different branch of the manifest.
`SKIN_THROTTLE_C=<°C>` sets the skin temperature at which the thermal HAL
reports throttling (the default is 40). With Docker, pass these as
`-e NAME=value`.

The build is `userdebug`, unsigned (it uses the AOSP test keys) and has no
GApps; you can add them yourself (see Installing). crDroid sets
`PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG`, so both `userdebug` and `user` report
`ro.build.type=user` and `ro.debuggable=0`: there is no `adb root` or shell
`dmesg`; read pstore from recovery.

### Pinning the sources

`default.xml` currently includes crDroid's `snippets/crdroid.xml` and
`snippets/lineage.xml`, which reference branches (`17.0`, `lineage-24.0`),
so a later sync can pick up newer crDroid commits. Once a build is known
to boot, snapshot it:

```sh
repo manifest -r -o default.xml     # flattens the includes and pins every project
```

Commit the result. The pinned manifest no longer includes the snippets
(`repo` resolves them away), so keep `snippets/` as the upstream baseline:
to move to a new crDroid point release, restore the include-based
`default.xml` from git, refresh the two snippet files from crDroid, sync,
rebase any patch that no longer applies, and pin again.

### Test builds with your adb key

For a test phone you can bake your own adb public key into the build, so
adb works in recovery and in Android right after a wipe, with no
"Allow USB debugging?" dialog:

```sh
  -v ~/.android/adbkey.pub:/adbkey.pub:ro -e ADB_KEY=/adbkey.pub \
```
On a GCP VM the same key travels with the build command instead
(`tools/gcp-build.sh build` copies it to the VM first):

```sh
ADB_KEY=~/.android/adbkey.pub ./tools/gcp-build.sh build
```

Recovery and the system trust only that key (`ro.adb.secure` stays on),
and USB debugging is on by default. Switching from a build without the key needs a
data wipe: if `/data` was set up with USB debugging off, Android's
trade-in mode takes over adb until the setup wizard is done, and only
`adb shell tradeinmode ...` works. The output gets an `-adbkey` suffix.
Don't share such a build: whoever holds the matching private key gets
adb on every phone that runs it. A later build without `ADB_KEY` removes
the key from `out/` again.

## Installing

You need an unlocked bootloader. The phone is A/B, and the recovery is
inside `boot`.

`tools/flash.sh` does the steps below for you: it lists the artifact sets
present in `gcp-out/` (only complete ones are selectable — an unfinished
download cannot be picked), verifies their `.sha256sum`, then flashes
boot/dtbo/vbmeta and sideloads the zip.

```sh
./tools/flash.sh            # interactive menu
./tools/flash.sh --list     # show what is available, change nothing
./tools/flash.sh --dry-run  # print the fastboot/adb commands
```

1. `fastboot flash boot <zip-name>-boot.img` and `fastboot flash dtbo
   <zip-name>-dtbo.img`. This is only needed when you're coming from stock or a
   different ROM, including the LineageOS builds of this device. Recovery
   runs with the dtbo of the current slot, and with stock's, the
   touchscreen doesn't work in recovery on phones with the Tianma
   (FocalTech) panel. The volume keys and the power button work either
   way.
2. Boot into recovery. Do a factory reset (**Factory reset → Format
   data**) when coming from another ROM. Then choose **Apply update →
   Apply from ADB** and run `adb sideload crDroidAndroid-17.0-*.zip`.
3. When the install finishes, recovery asks whether you want to install
   additional packages. To add Google apps, answer **Yes** (recovery
   restarts on the new slot) and follow [Google apps](#google-apps).
   Otherwise choose **No**, then **Reboot system now**.

To update a phone that already runs this ROM, without touching it: turn
on USB debugging, authorize the computer, and run

```sh
adb reboot sideload-auto-reboot
adb wait-for-sideload
adb sideload crDroidAndroid-17.0-*.zip
```

With `sideload-auto-reboot`, recovery skips the additional-zip prompt
and reboots into the new build by itself when the install is done.
**This removes Google apps** (see below); don't use it if you have them.

### Google apps

The system partition is ext4, so add-on packages can be installed from
recovery. We tested
[MindTheGapps](https://github.com/MindTheGapps/17.0.0-arm64/releases)
17.0.0 arm64 (20261022): the full package fits, with about 70 MB to
spare. crDroid's own package,
[NikGapps-crdroid-official-arm64-17](https://sourceforge.net/projects/crdroid/files/gapps/NikGapps-crdroid-official-arm64-17-20261021.zip/download)
(486 MB), is the alternative crDroid recommends.

- Install it right after the ROM, before the first boot: answer **Yes**
  to the additional-packages prompt (or choose **Advanced → Reboot to
  recovery**), then **Apply update → Apply from ADB**, run `adb sideload
  MindTheGapps-17.0.0-arm64-*.zip`, and confirm **Yes** when recovery
  warns that the signature can't be verified.
- Adding GApps to a phone that has already booted without them needs a
  factory reset afterwards.
- **Updates from the built-in Updater keep GApps; recovery sideloads do not.**
  On this A/B device the addon.d-v2 backup runs only through the Updater
  path. If you update by sideloading the ROM zip, sideload MindTheGapps again
  right after it, in the same recovery session, before booting.

Things you should know:

- **Recovery installs to the inactive slot** and then switches to it. If
  one slot holds a known-good ROM you want to keep, make that slot the
  active one before you sideload (`fastboot --set-active=<slot>`).
- During the sideload, the progress on the computer stops at around 47%
  while the phone installs the package. `adb` may then exit with
  `adb: failed to read command: Success`; that is harmless.
- `adb sideload` doesn't exit until you answer the additional-zip prompt
  from step 3 (not with `sideload-auto-reboot`, which has no prompt).
- When you flash `vbmeta`, the bootloader prints
  `WARNING: vbmeta_a anti rollback downgrade, 0 vs 15`. That's expected
  on an unlocked doha, and the flash still goes through.

### Root with Magisk

Magisk 31.1 works with this build. Patch the release's boot image in the
Magisk app and flash it:

1. Install the Magisk app (31.1 or newer) from
   [its GitHub releases](https://github.com/topjohnwu/Magisk/releases).
2. Copy the release's `<zip-name>-boot.img` to the phone. In
   Magisk, tap **Install**, choose **Patch firmware / image** and select
   that file. The app saves `magisk_patched-*.img` in Downloads.
3. Copy the patched image to your computer and flash it to the active
   slot:
   ```sh
   adb reboot bootloader
   fastboot flash boot magisk_patched-*.img
   fastboot reboot
   ```
   To try it first without flashing, use `fastboot boot
   magisk_patched-*.img` instead; the next reboot is back to the
   unrooted boot image.
4. Open Magisk. If it asks for additional setup, tap **OK**; the phone
   reboots.

Since Magisk 31.1 there is no root prompt: an app (or **Shell**, for
`adb shell su`) only gets root after you grant it in Magisk's
**Superuser** tab. Each ROM update replaces the boot image and removes
Magisk, so patch and flash the new release's boot image after updating.

## Status

**The crDroid build boots on hardware**, first flashed on 2026-11-17 (XT2019-1, serial
ZF6522633X, build `crdroid-…-20261117`, slot `_a`). What this build itself has been
verified for:

- boot to the launcher, `ro.build.type=user` with the crDroid user/release-keys spoof
- adb from first boot on an `ADB_KEY` test build (`ro.adb.secure=1` kept)
- 47 hardware sensors, touchscreen, 4 camera devices, fingerprint HAL,
  display 1080x2280 @ 60 Hz, audio outputs, SIM + voice registration,
  SElinux enforcing with 0 denials
- screen recording (5 s clip written, quick-settings tile works)
- Play Store and Play services after flashing MindTheGapps/NikGapps core: GMS
  self-updated 25.34.34 → 26.45.31 and ran for minutes without crashing; the
  crDroid default roles stay in place until a Google app set is flashed

The launcher of that first build crashed on `widget_internal_focus_bg` (a stale `resources.arsc`); the
kit now patches Launcher3 and refuses to finish a build whose launcher APK lacks the drawable, so it
cannot be shipped again.

The list below is the checklist inherited from the LineageOS 24.0 build on this
device; those items still have to be re-run on the crDroid releases:

- A clean install from stock firmware (4-1-7) following the steps above,
  and updates sideloaded over an earlier build.
- Boot, touch (in Android and in recovery), all four cameras including
  the ultra-wide, fingerprint enrolment and unlock.
- Calls with audio both ways, SMS and mobile data (on two Dutch
  carriers), Wi-Fi, audio on the speaker, wired headphones and a
  Bluetooth speaker.
- MindTheGapps with the Google setup wizard, Google sign-in and the
  Play Store, and Chromium-based browsers.
- Root with Magisk 31.1, from a boot image patched in the Magisk app.

NFC, the sensors and GNSS start but haven't been tried by hand. Not
tested: the Himax and Novatek touch panels, the Egistec fingerprint
sensor and the dual-SIM XT2019-2. The 2026-11-27 build adds the Dolby
Atmos stack below; it is device-untested, and AudioFX is removed from
that product.

Known issues:

- **VoLTE depends on the modem's carrier profile.** The modem picks one
  of Motorola's carrier profiles by SIM. For carriers Motorola has no
  profile for (for example SIMs on KPN's network in the Netherlands) it
  falls back to a generic profile with IMS off, so calls go over 2G/3G.
  Stock firmware does the same. Being investigated.
- **Double tap to sleep is a setting on the home screen, status bar and lock screen.**
  Home screen: Settings → Home screen → "Double tap to sleep"; crDroid's Launcher3
  implements the empty-space gesture, and the kit now defaults the preference on for
  new installs. Status bar: Settings → Status bar → "Double tap to sleep"; the lock
  screen has its own toggle and is on by default. Existing Launcher preferences are
  preserved, so an upgrade from an older build may still need the home-screen toggle
  turned on once.
- **Double tap to wake: patched, not yet tested on hardware.** Three things were
  missing on doha, and `patches/kernel/motorola/msm-4.14.patch` now supplies all
  three: gesture suspend was gated on a flag only Motorola's `dt-gesture` sensor
  class writes (no Moto service and no Lineage touch HAL here, so the panel was
  powered down at every suspend), `focaltech,report_gesture_key` is absent from
  the device tree so the gesture only reached that sensor class, and `KEY_WAKEUP`
  was not in the touch device's keybit. The patch defaults the gesture on and
  reports `KEY_WAKEUP` on the touch device itself, which the framework turns into
  a screen wake. Cost: the panel stays in low-power gesture mode while asleep, so
  expect a little standby drain. The reboot this gesture used to cause — a freeze
  when the screen was touched as the phone suspended — stays fixed by kernel
  `03f0501e`, which this manifest pins and which the patch builds on.
- After a fresh install from stock, the first boot may find only 2G.
  One more reboot fixes it.

### Checking a running build

```sh
./tools/device-check.sh                 # PASS/WARN/FAIL health check over adb, exit code = failures
adb bugreport ./br.zip                  # from the phone, while the problem is happening
./tools/bugreport-scan.py ./br.zip      # crash signatures + errors grouped by tag
./tools/bugreport-scan.py ./br.zip --area drm  # DRM, Widevine, and keymaster evidence
./tools/app-trace.sh com.anthropic.claude # one app: its logs, screenshot, activity state
./tools/perf-audit.sh                   # are the kit's perf knobs actually in effect?
./tools/perf-multitask.sh --repeat 3    # 8-app cycle: resident count + reload times
./tools/dexopt-all.sh                   # compile all apps now (speed-profile)
./tools/gms-trim.sh --list              # GMS background work, grouped; --restore undoes it
./tools/integrity-setup.sh status       # Play Integrity: GApps, PIF, keybox, boot props
```

`tools/gcp-build.sh logs` formats the remote build log while it streams: phase
lines are cyan, warnings yellow, failures red, ninja percentages become a
progress bar, and the TARGET_*/SOONG_* environment dump is hidden. Color is
automatic on a TTY; use `FORCE_COLOR=1` when piping, or `NO_COLOR=1` to keep
the layout without ANSI.

`tools/gcp-build.sh logs --full` (also `--raw`/`-f`) prints the entire raw log
from the beginning, with no filtering, dedupe, or wrapping.

`bugreport-scan.py` drops the tags dumpstate itself produces and groups the rest, so the output is the
handful of lines worth reading instead of 40 MB of dumpsys; it also flags dump artifacts (resource-id
noise that only appears inside the dump). Use `--area drm`, `--area performance`, or `--area power`
for the focused evidence groups. `docs/BUGREPORT.md` is the record of what that sweep found.

## Differences from an official crDroid device

This build isn't official, and crDroid has no doha maintainer. Against
crDroid's [maintainer
rules](https://github.com/crdroidandroid/rules-and-guidelines) and
LineageOS's [device support
requirements](https://github.com/LineageOS/charter/blob/main/device-support-requirements.md)
(which crDroid builds on), it differs in these ways:

- **OTA is self-hosted.** The build does not use crDroid's OTA repo; it reads
  `ishwar-chandra/doha-ota` at `<channel>/doha.json` (`standard`, `debloat`, or
  the maintainer-only `test`). `tools/gcp-build.sh finish` publishes the release
  and updates that feed, so a standard build only offers standard zips and a
  debloat build only debloat zips; `promote <tag>` moves a tested test build into
  standard without a rebuild. The feed repo and its write token are a one-time
  setup; without them, update with `adb sideload` as described under Installing.
- **Firmware is not managed for you.** The zip doesn't contain Motorola
  firmware, and the install steps don't copy it to the second slot. Both
  slots should run the latest stock firmware for doha (Android 10)
  before you install.
- **No dm-verity on vendor.** Verified boot is turned off in `vbmeta`
  (`--flags 2`).
- **Kernel 4.14 on Android 17.** Android 17 expects at least 5.10. A few
  features that need a newer kernel are turned off instead of crashing
  the system (see [crDroid 13](#crdroid-13)).
- **Quick tap is off**: doha has no quick-tap hardware, so crDroid's
  ColumbusService is not built (`TARGET_SUPPORTS_QUICK_TAP := false`).
- **Hardware variants**: the build supports every Moto G8 Plus, but only
  some combinations have been tested (see Status).

---

## The fixes, and why each one is needed

Most of these problems come from pairing a recent Android base with a
device that launched on Android 10 with a 4.14 kernel. The shared
Qualcomm trees also assume newer chips. Each section names the patch it
lives in. These are the same fixes the LineageOS 24.0 build on
`lineage-24.0` carries; the crDroid-specific differences are in the
first section.

### crDroid 13

- **The manifest is crDroid's.** `default.xml` is crDroid's own manifest
  with our remotes, plus `snippets/doha.xml`, which holds the 28 doha
  projects. `snippets/crdroid.xml` and `snippets/lineage.xml` are
  crDroid's, unmodified. crDroid maps `vendor/lineage` and
  `device/lineage/sepolicy` to its own forks at those paths, so the
  device trees' inheritance and `device/motorola/amogus`'s
  `device/lineage/sepolicy/libion/sepolicy.mk` include work unchanged.
- **Quick tap off** (`device/motorola/amogus_doha.patch`). crDroid's
  `vendor/lineage/config/crdroid.mk` adds the `ColumbusService` package
  unless `TARGET_SUPPORTS_QUICK_TAP := false`; doha has no quick-tap
  hardware, so the flag is set in `BoardConfig.mk`.
- **SafetyNet spoofing comes from crDroid.** crDroid's `system/core` does it
  itself (`SPOOF_SAFETYNET=1` in `init/Android.bp`, `SetSafetyNetProps` in
  `property_service.cpp`), so there is no `patches/system/core.patch` on this
  branch. It does not make Play Integrity pass on doha: the vendor keymaster
  refuses attested key generation (`-10003`). The measured behaviour and the
  proven workaround are in the Play Integrity section below. The docker image
  is still used, but only as a toolchain container: `build.sh` overrides its
  entrypoint, so its patches never run.
- **Build output handling** (`build.sh`). crDroid's `bacon.mk` renames
  the OTA zip to `crDroidAndroid-<version>.zip` and deletes the
  target-files intermediates instead of hard-linking them as LineageOS
  does, so the zip is taken from `out/target/product/amogus_doha/` and
  the images from `PRODUCT_OUT` rather than the deleted `IMAGES/`
  directory. For the same reason the build asks only for `bacon`:
  adding `target-files-package` makes ninja zip the staging tree that
  bacon is deleting, which fails with `lstat ...: No such file or
  directory` (the OTA is built from the staging directory, not from
  that zip).

### Android 17

- **Boot through the ramdisk.** Android 17's init no longer boots doha's
  legacy system-as-root layout. The kernel now unpacks the boot ramdisk
  despite the bootloader's `skip_initramfs` and tells init to boot
  Android (`CONFIG_INITRAMFS_IGNORE_SKIP_FLAG`,
  `CONFIG_PROC_CMDLINE_APPEND_ANDROID_FORCE_NORMAL_BOOT`, ported from
  LineageOS's ginkgo kernel). First-stage init then needs
  `androidboot.boot_devices` on the command line and mounts system at
  `/system`, and it mounts `/metadata` for Android 17's flag storage.
  (`kernel/motorola/msm-4.14.patch`, `device/motorola/amogus.patch`,
  `device/motorola/amogus_doha.patch`)
- **Legacy HAL paths.** Keymaster and gatekeeper need `libion`'s legacy
  implementation, plus the legacy gralloc and display-service paths
  that the LineageOS-derived trees use for devices of this age
  (`libion,legacy_impl`, `libui,legacy_gralloc`,
  `surfaceflinger,register_displayservice`).
- **BPF on 4.14.** healthd's power-supply filter and netd's traffic
  programs get their kernel limits back so 4.14 loads (or skips) them,
  and system_server no longer aborts when the kernel has no BPF ring
  buffers (local-network and loopback events, kernel 5.8+, are off).
  (`packages/modules/Connectivity.patch` and others)
- **Camera.** The camera HAL links
  `android.frameworks.displayservice@1.0`, which Android 17 removed; the
  interface is restored as a library (`frameworks/hardware/interfaces.patch`,
  `system/tools/hidl.patch`). Nothing serves it, so the HAL gets no
  display events; capture works.
- **ext4 system, sized for GApps.** System is ext4 instead of erofs so
  add-on packages can install, with 16384 inodes instead of mke2fs'
  default 194688 to leave room (`device/motorola/amogus.patch`,
  `device/motorola/amogus_doha.patch`).
- **Recovery touch.** 24.0's build no longer copies the device's
  `recovery/root` into recovery, so the script that loads the touch
  module is installed explicitly (`device/motorola/amogus_doha.patch`).
- **Build fixes.** The kernel is built with LLVM only, so 4.14 gets
  `CROSS_COMPILE` back; BoringSSL without the ENGINE API needs guards in
  the kernel's signing tools; the VINTF manifest moves to target level 7;
  Pixel's moved power and USB HAL namespaces are imported.

### Needed to get the build working

**`device/motorola/amogus`: drop the `hardware/qcom/bootctrl` namespace
import** (`Android.bp`). That project has only makefiles, so it doesn't
declare a Soong namespace, and Soong refuses to import a namespace that
doesn't exist. Nothing in the build used the import.

<a id="kernel-headers"></a>
**Kernel headers** (`device/motorola/targets`, `device/motorola/amogus`,
plus the empty file that `build.sh` creates).
`PRODUCT_VENDOR_KERNEL_HEADERS` normally gets set only for prebuilt
kernels. doha builds its kernel from source, so the variable was empty.
The `KERNEL_OBJ/usr` rule in `amogus/Android.mk` then ran `cp -a /.` and
copied the whole build machine's root filesystem into `out/`. The fix:

- `targets/include/kernel/source.mk` points the variable at the
  sanitized header export in `device/motorola/amogus-kernel/kernel-headers`.
- `Android.mk` only runs the rule when the variable is set.
- An empty *file* is placed at `device/motorola/amogus_doha/kernel-headers`.
  AOSP adds `$(TARGET_DEVICE_DIR)/kernel-headers` to the include path
  whenever that path exists, and there's no way to turn this off. A stale
  raw-header directory at that path shadowed bionic's headers and broke
  the compile (`redefinition of 'sigaction'`). A plain file keeps a
  directory from being created there.

**`device/motorola/amogus`: don't enforce VINTF kernel requirements**
(`device.mk`,
`PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false`). doha ships with
API level 29, which maps to FCM level 5. The compatibility matrices in
Android 17 no longer list a 4.14 kernel for that level, so `checkvintf`
always rejects this kernel.

**`libqsap_sdk` can't be built** (`device/motorola/common`,
`device/qcom/common`, `hardware/motorola`). `libqsap_sdk` is built from
`system/qcom/softap/sdk/Android.mk`, and that file is on Android 17's
`androidmk_denylist.go`. Both `PRODUCT_PACKAGES` entries for it are
removed, and `libqsap_shim` (its only user among source-built modules) is
stubbed out. See the GSM fix below for the prebuilt copy that is
installed instead.

**Sepolicy duplicates and missing types** (`device/qcom/common`,
`device/qcom/sepolicy_vndr/legacy-um`, `device/lineage/sepolicy`,
`device/motorola/amogus`). doha's sepolicy includes two trees:
`device/qcom/sepolicy_vndr/legacy-um`, the tree for this SoC family, and
`device/qcom/common/sepolicy/generic` + `qva`. The second tree was written
for newer chips. Together they cause two kinds of hard errors from
`checkpolicy` and the `*_contexts` tests:

- *Duplicates.* A type, label, property or genfs entry is declared by both
  trees, or by a shared tree and doha's own device tree. We delete one
  copy and keep the device tree's copy where the two disagree. Affected:
  `vendor_persist_wcnss_service_file`, the IMS, persist/wlan and "taro"
  labels, the extcon genfs nodes, `persist.vendor.rcs.singlereg.`,
  `persist.vendor.bt.a2dp_offload_cap`, `xtwifi-inet-agent`,
  `/dev/sec-nfc`, the trinket `bms` and `vibrator` genfs nodes, and
  `sched_energy_aware`.
- *Missing types.* Some rules and labels use types that only exist for
  sm8450 and newer: DMA-BUF heap devices (`hal_drm_widevine.te`,
  `mediacodec.te`), the LOWI/SLIM/XTRA/XTWiFi location daemons, QMS
  (`mutualex`), QCC-TRD/qccvndhal, `perf_qesdk`/`sensors-qesdk`,
  `vendor_ims_service_socket`, `vendor_proc_swappiness`,
  `vendor_modprobe_prop` and the poweropt hwservice/service types. We
  remove only those lines. When nothing in a file applies to this SoC,
  the file is left empty.

`sepolicy_test` also requires every type used under `/vendor` to carry
`vendor_file_type`, so that attribute is added to
`vendor_camera_data_file` (legacy-um) and `vendor_sensor_data_file`
(amogus).

**`device/motorola/common`: power HAL build dependency**
(`power-libperfmgr/Android.bp`). The power HAL includes the generated
aconfig header `powerhal_flags.h` but didn't link
`powerhal_flags-aconfig-cc`, so every object file failed to compile.

**`vendor/qcom/opensource/audio/sm8150`: C23 thread signatures**
(`spkr_protection.c`). In C23, `void *f()` means `void *f(void)`. That
signature doesn't match `pthread_create`, and clang treats the mismatch
as an error. The patch gives both thread functions a `void *` parameter.

**`vendor/qcom/common`: don't install the `wificfr`/`wifilearner`
services** (`wlan-legacy-vendor.mk`). Their init `.rc` files declare
HIDL interfaces that no `hidl_interface` in the tree defines, so
`host_init_verifier` fails. The libraries and command-line tools are
still installed.

### Needed to boot

**BPF kernel-version gates** (`packages/modules/Connectivity`). Android 17
requires kernel 4.19 or newer for BPF networking. doha has 4.14.

- `NetBpfLoad.cpp`: the 4.9/4.14/4.19/5.4 and 5.15 checks returned an
  error, and `reboot_on_failure` in `netbpfload.rc` turned that into a
  bootloop. Now they only log a warning, like the 5.10 check already
  does. LineageOS's abandoned Gerrit change 433516 made the same change,
  and AOSP has since relaxed the 5.10 one itself.
- `BpfHandler.cpp`: netd's 4.19 and 5.4 gates made
  `libnetd_updatable_init` abort, taking `system_server` down with it
  because netd is a critical service. This needs no patch on crDroid:
  its `hardware/interfaces`/Connectivity revision no longer rejects the
  kernel, it checks the version around each 4.19+ or 5.4+ attachment
  instead. The hunk was in the LineageOS 24.0 patch and was dropped when
  the patch was rebased onto crDroid.
- `BpfNetMaps.java`: the `local_net_access` and `local_net_blocked_uid`
  maps can't be created on 4.14. `system_server` threw on this and
  crashed. Now it treats the maps as unsupported and skips them.

**Thermal HAL** (`device/motorola/amogus`, `vendor/qcom/opensource/thermal`).

- doha ships the HIDL `android.hardware.thermal@2.0-service.qti`.
  legacy-um only labels the AIDL binary name, so the HIDL service had the
  generic `vendor_file` label, init couldn't start it, and
  `ctl.interface_start` failed. The patch adds a `hal_thermal_default_exec`
  label to amogus's `file_contexts`.
- With the service unable to start, `HardwarePropertiesManagerService`'s
  blocking `IThermal@1.0::getService()` on `system_server`'s main thread
  never returned, and the watchdog killed `system_server` after 67
  seconds, in a loop. The label fix is enough: the service implements 2.0
  and registers as both `@1.0::IThermal/default` and
  `@2.0::IThermal/default`, so the 1.0 lookup succeeds and
  `frameworks/base` needs no change.
- The HAL's trinket (soc 394) config names two thermal zones that doha's
  kernel doesn't have: the skin sensor `xo-therm-adc`, which is called
  `xo_therm` here, and the battery percentage sensor `soc`. The HAL gives
  up on all sensors when one is missing, so it answered every request with
  "ThermalHAL not initialized properly" and `ThermalManagerService` got no
  temperatures. The patch uses `xo_therm` and drops `soc`. The skin
  sensor reports throttling from 40 °C, Qualcomm's trinket value;
  `SKIN_THROTTLE_C` changes it (see the build options).
- `vendor/qcom/opensource/thermal`: the service in the `.rc` is renamed
  to `vendor.thermal-hal-doha`. This was a debugging attempt that didn't
  fix the problem. It's harmless, and we kept it because the tested build
  included it.

### Workarounds for the 4.14 kernel

Android 17 assumes a 5.10 or newer kernel. The BPF kernel-version gates
under "Needed to boot" put back fallbacks for kernel features doha's
4.14 kernel doesn't have.

**Hotspot and USB tethering** needed no patch here since our kernel
gained `close_range()`. netd uses `posix_spawn()` with
`POSIX_SPAWN_CLOEXEC_DEFAULT` to start dnsmasq, and since bionic commit
`bf8fc35b7` that flag relies on the `close_range()` syscall. Without it
the child process exited with code 127 before dnsmasq ran, and
tethering stopped with
`Failed to send update command to dnsmasq (Broken pipe)`. Earlier
releases reverted that bionic commit. Our kernel fork now backports
`close_range()` with `CLOSE_RANGE_CLOEXEC` from Linux 5.15, so bionic is
unpatched again and every other caller of the syscall works too. clatd
(464XLAT on IPv6-only mobile networks) is started the same way.

**`/proc/cmdline` bounds** (`kernel/motorola/msm-4.14`). The
`CONFIG_PROC_CMDLINE_APPEND_ANDROID_FORCE_NORMAL_BOOT` helper appended
`androidboot.force_normal_boot=1` to a fixed `COMMAND_LINE_SIZE` (4 KiB) buffer
without checking the remaining space. It now verifies the space first and logs
instead of overflowing. Doha's bootloader cmdline is far below the limit, so
this was latent; the source is firmware-controlled and must not be trusted.

### Hardware fixes

**Mobile network / SIM** (`vendor/motorola/amogus`, `device/motorola/amogus`).
The prebuilt `libmdmcutback.so`, which `qcrild` loads, needs
`libqsap_sdk.so`. With the source module gone (see above), nothing
installed the prebuilt copy that is already in the blob tree. `qcrild`
then failed to link, and the phone had no RIL and no SIM. The patch adds
the 32-bit and 64-bit blobs to `amogus-vendor.mk` and
`proprietary-files.txt`.

**Wi-Fi WPA3-SAE** (`kernel/motorola/msm-4.14`). Upstream Linux commit
`cc3e14c21ae9` ("nl80211: add WPA3 definition for SAE authentication") is
cherry-picked here. The kernel had the nl80211 SAE password attribute
from a partial CAF backport, but not `NL80211_WPA_VERSION_3`.
wpa_supplicant sent VERSION_3 for SAE, the kernel rejected it, and WPA3
networks reported a wrong password.

**Vibration and other kernel modules** (`device/motorola/amogus_doha`,
`BOARD_VENDOR_KERNEL_MODULES_LOAD`). The vendor build system always
writes `vendor/lib/modules/modules.load`, even when the list is empty. An empty
file makes `init.modprobe.sh` skip its "load everything" fallback, so no
vendor module loaded. That included the aw8695 haptics driver, so the
vibrator didn't work. The patch lists the modules explicitly: `aw8624`,
`aw8695`, `sx933x_sar` and `stmvl53l1`, plus the FocalTech and Novatek
touch drivers (`focaltech_0flash_mmi`, `focaltech_0flash_mmi_doha`,
`nova_0flash_mmi`). Some doha units have those panels instead of the
Himax one, whose driver is built into the kernel; without them their
touchscreen was dead. Each touch driver only binds when its panel is
present.

**Bluetooth** (`vendor/qcom/opensource/interfaces`). The prebuilt QTI
Bluetooth HAL and FM implementation link against
`vendor.qti.hardware.fm@1.0.so`. LineageOS's copy of this project doesn't
define that interface, so the library wasn't built and the Bluetooth HAL
couldn't start. The patch adds the `fm@1.0` HIDL definition from
moto-common's fork.

**Fingerprint** (`device/motorola/common`, `init.oem.fingerprint2.sh`).
The script picks the fingerprint HAL from `fps_id`. It reads that from a
utag or from persist, and doha has neither. The script then fell through
to its Egistec default, which never registers on doha's FPC sensor and
floods the log with about 785 `getService` retries per second. The patch
adds a fallback to the factory descriptor `/proc/hw/fps_id/ascii`
(`fpc`), which is used only when nothing else supplied an ID.

**Fingerprint, Egistec units** (`device/motorola/common`,
`sepolicy/vendor/hwservice_contexts`). Some G8 Plus units have an
Egistec ET5xx sensor instead of FPC. Their HAL also registers
`vendor.egistec.hardware.fingerprint@2.0::IBiometricsFingerprintEts` and
`com.motorola.hardware.biometric.fingerprint@1.0::IMotoFingerPrintSensorTest`.
Neither interface had a label, so SELinux denied both registrations. The
HAL ignores those failures and still registers the standard
`IBiometricsFingerprint`, but the Egistec and Moto extensions were lost.
The patch labels them `hal_fingerprint_hwservice`, like the FPC
extensions already are. This is untested: our test unit has an FPC
sensor.

**NFC** (`hardware/nxp/nfc`). doha has a PN553 on `nq-nci`. After about
2 seconds idle, the chip goes into standby and NACKs the first I2C write.
The snxxx HAL retried 6 times with no delay, so every retry landed in the
wake-up window, and then it called `abort()`. The patch adds back the
10 ms `usleep` between retries. It was in the first snxxx release and the
pn8x HAL has it too, but NXP commit `594411b` removed it as an unrelated
side change.

**GPS: remove QCC** (`vendor/qcom/common` `gps-vendor.mk`,
`device/motorola/common` `vintf/manifest-qcom.xml`). The prebuilt
`qccsyshal@1.2` system HAL was built against protobuf ~3.21 and can't
link against Android 17's protobuf 25.8. It crash-looped, and the QCC
app restarted every 15 seconds waiting for it. The patch stops installing
the HAL, its libraries and the app, and removes its VINTF entry. GPS and
XTRA downloads work without it.

**Widevine L1 library** (`vendor/motorola/common`). The vendor tree ships the
1.4 DRM service, `libwvhidl.so`, and the signed OEMCrypto library, but the
inherited `hardware/qcom/qcom-vendor.mk` installs only the first two.
`WVCdm` then reports `Could not load liboemcrypto.so. Falling back to L3`, so
L1-capable apps see an L3 device. The patch copies the existing
`hardware/qcom/proprietary/vendor/lib64/liboemcrypto.so` blob to
`/vendor/lib64/liboemcrypto.so`; it adds no key material and no property spoof.
`tools/device-check.sh` fails if the installed file is missing, but installation
alone is not proof of L1: the DRM info app and an L1 stream still have to be
tested on hardware. The current kit change is device-untested.

### Dolby Atmos (`snippets/doha.xml` vendor project, `patches/device/motorola/amogus_doha.patch`, `patches/device/motorola/targets.patch`, `patches/vendor/qcom/opensource/audio/sm8150.patch`)

Dolby Audio Processing is the `dap` effect (`libswdap.so`, UUID
`9d4921da-8225-4f29-aefa-39537a04bcaa`) plus the
`vendor.dolby.hardware.dms` HIDL service. The stock doha 10 firmware
(`QPIS30.28`) carries both, and earlier builds ported those blobs verbatim
from the stock image.

That 2019 port does not survive Android 17. The `daxService` (targetSdk 29)
and `libswdap` load, the effect attaches, but every DAP parameter query
returns `-3` (EINVAL) inside the effect: `DolbyAudioEffect.getNumOfProfiles()`
is the first call in its constructor, so `dolbyprovider` fails and Moto Audio
(`com.motorola.dolby.dolbyui`) crashes reading
`content://com.dolby.daxservice.dolbyprovider/3/status`. No SELinux denial is
involved; it is the old blob's parameter store failing to initialise under
the Android 17 audioserver.

The stack is therefore replaced by the DAX3 3.6 Motorola Dolby package from
`userariii/vendor_motorola-dolby` (branch `v1.2`), pinned in
`snippets/doha.xml` at `vendor/motorola-dolby`. It is built for Android 13+,
talks `vendor.dolby.hardware.dms@2.0` instead of `@1.0`, and ships:

- `DaxUI` (`com.dolby.daxappui`) and `daxService`
  (`com.dolby.daxservice`), installed to `/system_ext/priv-app` and
  **re-signed with the platform key** (`android_app_import`,
  `certificate: "platform"`). That is what lets `daxService` hold
  `INTERACT_ACROSS_USERS_FULL`: the permission stays `signature`-only, so the
  earlier `frameworks/base` rewrite of its protection level, and the privapp
  allowlist it forced for every other holder, are both gone;
- the `dms@2.0` HAL, `/vendor/etc/dolby/dax-default.xml`, the DAP effect
  libraries, and the `privapp`/`sysconfig` permission and hidden-API files.

`patches/device/motorola/amogus_doha.patch` installs only the audio subset:
the two APKs, the dms 2.0 HAL and its libraries, the effect, the tuning XML
and the permission files. The donor's AC4/DD+ decoding pieces
(`libstagefrightdolby`, `libstagefright_soft_{ac4,ddp}dec`,
`media_codecs_dolby_audio.xml`) and its `dms360` ODM service are not carried,
so Dolby *decoding* of AC-4/E-AC-3 is not enabled by this change.
`libdlbdsservice` links `libstagefright_foundation-v33.so`, so the VNDK v33
stage is copied from `prebuilts/vndk/v33` (still present in lineage-24.0).
`DEVICE_MANIFEST_FILE` gets a device-tree HIDL 2.0 fragment
(`dolby/manifest.xml`; the donor's copy declares `target-level="5"`, a stale
level that trips the VINTF check when merged on Android 17) and
`DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE` gets the donor's framework
matrix. The donor's `sepolicy/vendor` joins `BOARD_VENDOR_SEPOLICY_DIRS` (it defines
`hal_dms`/`hal_dms_client`/`hal_dms_server`, `hal_dms_hwservice`, and labels
`/data/vendor/dolby` as `vendor_data_file`). The stock stack's `dolby.te`,
contexts, VINTF files, permission XMLs and APKs are removed from the device
patch.

The `dap` effect entry stays in the audio HAL's `audio_effects.xml`
(`vendor/qcom/opensource/audio/sm8150`) because the effect is loaded by
audioserver. `device.mk` installs `persist.vendor.audio_fx.current=dolby`,
`ro.vendor.audio.dolby.dax.support`, the DAX3 version property and the
`vendor.audio.dolby.ds2.*` overrides, and sets `TARGET_EXCLUDES_AUDIOFX`
alongside the existing `AudioFX` filter in the `targets` patch so the ROM
does not ship two audio-effect UIs.

Verified on the 2026-11-28 debloat build (`1795817209`): `dms@2.0-service`
and `daxservice` run, DaxUI (`com.dolby.daxappui`) renders with the
Dynamic/Movie/Music/Custom presets, `DolbyManagerService` logs
`doOnDapParamUpdate`, and the HAL's `DlbDapEndpointParamCache` commits its
parameter sets (`Committed 63 parameters out of 63`). No
`DolbyAudioEffect: set/get parameter error` appears - that EINVAL killed the
old stack. Speaker/headphone output is still to be confirmed by ear.

Check the effect through the **policy**, not AudioFlinger: the DAP effect's
`dump()` blocks, so `dumpsys media.audio_flinger` ends with
`SERVICE 'media.audio_flinger' DUMP TIMEOUT (10000ms) EXPIRED` and never
prints its effect list (the same truncated dump reaches
`tools/bugreport-scan.py`).

```sh
adb shell dumpsys media.audio_policy | grep -i -A2 '"DAP"'
#   "DAP"; Music Effect? yes; <Enabled|Disabled>; Active
adb shell cmd package resolve-activity --brief com.dolby.daxappui
adb shell lshal | grep -i dms
```

The effect reads `Disabled` while the phone is idle; the power button in
DaxUI toggles it for playback. The vendor APK cannot be used as-is: while
Dolby is off, `MainActivity.dsPowerChanged(false)` swaps the UI for a
full-screen "Dolby is off" image and disables every control, so the app's
own power button cannot turn it back on (only the Quick Settings tile can).
The device tree therefore ships `dolby/DaxUI.apk` - the same APK with the
`if-eqz v13, +0x122` at dex offset `0x16ac72` (the branch into the off
state) replaced by two nops - and `dolby/Android.bp` imports it as
`DaxUI-patched` (`certificate: "platform"`, `system_ext_specific: true`).
After any dex edit the header must be fixed in this order, or ART rejects
the dex and every class fails to load: `sha1(dexd[32:])` into
`dexd[12:32]`, then `adler32(dexd[12:])` into `dexd[8:12]`.
`android_app_import` re-signs the APK, so the copy in the patch can carry
any signature. If the effect never registers, the dms@2.0 HAL did not
start; check `lshal` and `avc` denials for `hal_dms_default`.

### Play Integrity

Measured on the 2026-11-20 build (bugreport `2026-11-20-07-07-57`, phone
`ZF6522633X`): Play Store reports **"Device is not certified"**, and the
Play Integrity API returns `UNEVALUATED` for every field — `deviceIntegrity`
carries no `deviceRecognitionVerdict` at all. The failure is upstream of any
spoof: every key-attestation request dies in the vendor HAL,

```
E KeyMasterHalDevice: Attest key send cmd failed
E KeyMasterHalDevice: resp->status: -10003
E keystore2: Error::Km(-10003) for AppUid(10227)      # com.google.android.gms
```

on `android.hardware.keymaster@4.1-service-qti`, so there is no
Google-rooted attestation chain. That chain is exactly what the basic
label needs: Google's docs say `MEETS_BASIC_INTEGRITY` on Android 13+
"requires only that the attestation root of trust is provided by Google".
No fingerprint spoof or Play Store registration changes that — the verdict
is computed from the signed chain, not from `ro.*` properties.

PIF is not the gate. Measured on the same phone, changing the PIF config and
re-running the check gave an identical `UNEVALUATED` result every time: PIF
off, PIF on with the hook flags off, and PIF on with the vending spoof off.
vvb2060's KeyAttestation reports the reason directly: "Unable to attest …
KeyStoreException: -10003".

The fix that does work is crDroid's own built-in TrickyStore, which notices
the broken TEE and generates a chain from a keybox instead of asking
keymaster. Proven on this phone with a throwaway self-signed keybox: importing
it (through the same Settings.Secure keys the GUI writes) makes KeyAttestation
show a complete chain — `CN=Android Keystore Key` under the keybox's root,
"Bootloader is locked", Keymaster 4.1, TrustedEnvironment — where it showed
`-10003` before. Play Integrity still fails with that test key because the
root is not Google's; with a Google-rooted keybox, that same chain is what the
API evaluates.

The kit cannot ship that file. A keybox is a set of Google attestation
private keys, revoked in waves, and redistributing one is not something this
repo does. What it can do is make the import one step for a user who has one:

```sh
tools/integrity-setup.sh status            # GApps, PIF config, keybox, boot props
tools/integrity-setup.sh import keybox.xml # same keys the Settings UI writes
tools/integrity-setup.sh check             # opens KeyAttestation to read the chain
```

On the phone that path now starts by itself. After an update, the Settings
app's boot receiver (`KeyboxMonitorReceiver`) calls `KeyboxMonitor.sync`,
which probes attested key generation once per build and — when it fails and no
keybox is installed — posts a single notification saying so. Tapping it opens
Settings > Misc > TrickyStore, where the user picks their keybox file; the
screen validates it, stores it, restarts the GMS family and re-checks the
chain. Nothing is imported without that pick. The prompt is keyed to
`Build.TIME`, not the often-identical `Build.VERSION.INCREMENTAL`, and turning
keybox alerts off also removes a pending prompt.

`tools/integrity-setup.sh import` uses the same Settings.Secure contract as the
UI. It preserves custom target entries and mode suffixes; when it finds the old
tool-written three-entry list, it lets crDroid's `AxSpoofManagerService` seed its
full default set and then verifies that `com.google.android.gms` is present.
It refuses to write a shortened list if seeding fails.

What a user can do, in order of effect:

- Import a keybox at crDroid Settings > Misc > TrickyStore (or with
  `tools/integrity-setup.sh import`). That is the only route to
  `MEETS_DEVICE_INTEGRITY`/`MEETS_STRONG_INTEGRITY` on this phone, and the
  only route to any verdict at all without a working TEE attestation key.
- `crDroid Settings > Misc > Play Integrity Fix` fetches a Pixel fingerprint
  and refreshes it; it helps apps that read the legacy signals, but it cannot
  manufacture an attestation chain.
- "Device is not certified" in the Play Store is a Google-side flag keyed to
  the GSF ID. Registering it licenses the Play apps; it does not create
  `MEETS_DEVICE_INTEGRITY` and it did not change any verdict here.

### 2026-11-18 bugreport follow-ups

**Launcher3 themed-icon crash** (upstream `frameworks/libs/systemui`, commit
`f74e6a0`). The launcher's `IconProvider$ThemeData.loadPaddedDrawable()`
treated a resource ID from an updated or removed package as valid and called
`getResourceTypeName()`/`getDrawable()` on it. `Resources$NotFoundException`
killed the Launcher process (dropbox `system_app_crash`, IDs
`0xe020f5c`/`0xe020f4b`). crDroid now catches the missing resource and returns
`null`, so the caller falls back to the default icon instead of restarting
the workspace. The local patch was removed once this reached the pinned
branch.

**Launcher3 double-tap-to-sleep** (`patches/packages/apps/Launcher3.patch`).
crDroid's `WorkspaceTouchListener` already implements double-tap on empty workspace
space when `pref_sleep_gesture` is true, but the preference defaulted to false, so
the home screen did nothing out of the box. The patch changes the default to true
for new installs. Existing preferences are preserved; the setting remains available
under Settings → Home screen → "Double tap to sleep".

**Battery sysfs and power-HAL sepolicy** (`system/sepolicy.patch` and
`device/lineage/sepolicy.patch`). `system_suspend` was denied read access to
`sysfs_batteryinfo`, which is why `android.system.suspend-service` could not
read the wakelock/battery stats (D5). The rule belongs in system policy:
`system_suspend` is a private platform type, so a vendor policy file cannot
name it. `hal_power_default` was also denied `cgroup:file` reads for
`schedtune.boost`/`prefer_high_cap`; that rule stays in the device policy.
Neither patch broadens write access. `system/sepolicy.patch` also exempts
`system_suspend` from the `coredomain` neverallow on `sysfs_batteryinfo`;
without that exception `checkpolicy` rejects the allow rule.

**Nearby Share AppOp** (`frameworks/base.patch`). GMS 26.46 asks for
`ACCESS_LOCAL_NETWORK`, but the platform only registers the op when the
`access_local_network_permission_enabled` flag is on, so the query returned
`Operation not found` and Nearby advertising failed with a missing-permission
exception. The patch registers the op unconditionally; the permission remains
unenforced until the flag is enabled. The 4.14 `BpfNetMaps` local-net map skip
is a separate limitation.

**Still not fixable in a kit patch:** the GMS `AdvancedProtection` safety
source (platform/GApps enum mismatch), Find My Device's Google-signature check,
Motorola launcher badge provider (app-side query), and the Wi-Fi/Bluetooth/USB
HAL/framework errors from the same captures.

### 2026-11-26 bugreport follow-ups

**Malformed SMS SCTS** (`patches/frameworks/base.patch`). Both SIMs' SMSCs sent PDUs whose
service-centre timestamp has month 0; `SmsMessage.getSCTimestampMillis()` threw
`DateTimeException`, logged a stack trace per PDU (96 lines in one 17:17:12 burst) and
returned 0, which dates the message to 1970. The parser now falls back to the receive time
and logs one warning; the PDU stays malformed, the message keeps a sane date.
Device-untested.

**Not patched, by design.** The cgroup2 line
`cgroup: cgroup2: unknown option "memory_recursiveprot"` is diagnostic only:
`system/core`'s `MountV2CgroupController()` (`libprocessgroup/setup/cgroup_map_write.cpp`)
already retries without the option, so cgroups mount; 4.14 simply predates the 5.7
`memory_recursiveprot` feature, and a backport is not justified for a log line. `wifirtt`
is D8 (the vendor Wi-Fi HAL has no RTT service). `icnss_pm_suspend_noirq ... returns -11`
(one event) and `sensors-hal: mot_disprot_event ... status=3` are vendor driver/HAL
behaviour with no kit-side lever.

### 0.5x animations by default (`patches/frameworks/base.patch`)

Sync animations ship at 0.5x (window, transition, animator) so a fresh install and an
update both feel quicker without visiting Developer options. Three mechanisms are
needed because the scale is a stored setting, not a build property:

- `SettingsProvider/res/values/defaults.xml` carries the three fractions at 50%.
- `DatabaseHelper.loadGlobalSettings()` seeds the three `Settings.Global` rows, since the
  readers (`WindowManagerService`, the animator handler) fall back to `1.0f` when a row is
  missing — a resource change alone does nothing.
- `SETTINGS_VERSION` 236 → 237 adds a one-time upgrade step in `onUpgradeLocked()`, because
  an existing device already has `1.0` stored and would otherwise keep it forever. The step
  rewrites only the untouched default (`1.0`/`1`) and inserts where nothing was stored, so a
  scale the user picked (off, 0.25x, 0.75x, 1.5x) survives the update. Device-untested.

### Pre-reboot dexopt on a symlinked system_ext (`patches/art.patch`)

Every OTA in the 2026-11-27 archive left five tombstones from
`/apex/com.android.art/bin/dexopt_chroot_setup`, all `SIGABRT` with
`Check failed: !OR_RETURN(IsSelfOrParentSymlink(target)) /mnt/pre_reboot_dexopt/chroot/system_ext/lib`.
This device has no separate `system_ext`/`product` partition, so the build ships
`/system_ext -> /system/system_ext` and `/product -> /system/product`; the dexopt chroot inherits
those symlinks from the root mount, and `BindMount()`/`BindMountDirect()` abort rather than
follow a symlinked target. Result: `dalvik.vm.enable_pr_dexopt=true` was set but pre-reboot
dexopt never ran, so the first boot after an update recompiled on demand. The patch skips the
mount and logs a warning instead — the symlink resolves inside the same chroot, so dexopt sees
the files it would have bind-mounted. Device-untested.

### Frozen-state callback warning (`patches/frameworks/av.patch`)

`AudioFlinger` and `AAudioClientTracker` register the optional frozen-state callback on each
client binder. The doha 4.14 kernel's binder has no frozen-state support, so
`IBinder::addFrozenStateChangeCallback` returns `INVALID_OPERATION` (-ENOSYS), logged 200x as
"returned -38" in the 2026-11-27 bugreport. The patch ignores exactly that code in both files and
still warns on every other failure. No HAL is involved: the call is on the client binder, not the
audio HAL. Device-untested.

### 2026-11-27 bugreport follow-ups

**Pre-reboot dexopt and frozen-state callback.** See the two sections above:
`patches/art.patch` and `patches/frameworks/av.patch`.

**Vendor daemons, no source in the manifest.** `xtra-daemon` (`DgnssNtripSourc`) took one
`SIGSEGV`; it is a stock proprietary binary under `vendor/qcom/common/vendor/gps-legacy`, and it
restarts with a new pid. `gatekeeper@1.0` and `keymaster@4.1` took one `SIGABRT` each at boot:
the stock QSEE daemons double-own a `RefBase` at `QSEECom_shutdown_app`; both restart and serve.
Keymaster attestation is refused separately (see Play Integrity below).

**Moto telephony extension.** `moto_ext_telephony.registry` is missing. The
`moto-telephony.jar` is installed, but the registering service belongs to the stock Moto
framework, which this ROM does not carry; `vendor_qtelephony` logs the miss and continues.

**Expected on this ROM.** Google service-missing lines (no GApps), `keystore2` attestation
errors (the vendor keymaster refuses attestation; TrickyStore plus a user keybox is the supported
route), the vendor supplicant's `setBtCoexistenceMode` service-specific exception (the stock
supplicant lacks the Android 17 AIDL method), and Passpoint null-OSU/DHCP logs (network
conditions, not errors).

### Wi-Fi Display property (`patches/device/motorola/amogus_doha.patch`)

`/vendor/build_doha.prop` sets `persist.debug.wfd.enable=1`, but that file is loaded as
`vendor_init`, which SELinux denies for a `persist.debug.*` (system) property, so the flag never
took effect. It is now written from `device.mk` as `PRODUCT_PROPERTY_OVERRIDES`, i.e. into
`/system/build.prop` where `init` owns the property. The same file carried a `ro.product.bevice`
typo that was always rejected; it is removed. Device-untested.

### Performance profile (`performance-tuning` branch)

The tuning is small because most of the obvious knobs are already written by the
vendor scripts — from three different places, in an order that decides which
value actually survives. On this device (4.14, `init.qcom.post_boot.sh` is the
*legacy* script) that order is:

1. `init.amogus.rc` — `on init` (boot read-ahead, `nr_requests`) and
   `on property:sys.boot_completed=1` (runtime values).
2. `qcom-post-boot` (`init.qcom.post_boot.legacy.sh`, started by `init.qcom.rc`
   at `sys.boot_completed=1`) — sets the governor, `swappiness` and its own
   read-ahead, then sets `vendor.post_boot.parsed=1` on its last line.
3. `init.aospa.perf.common.rc` (`device/qcom/common`) —
   `on property:vendor.post_boot.parsed=1` rewrites `read_ahead_kb` for
   `mmcblk0`. The earlier `sda`...`sdf` and `dm-0`...`dm-49` writes were
   removed: those block devices do not exist on doha, and their failed writes
   only obscured which value actually reached the eMMC queue.

Because (3) runs after (2), it is the **last** writer of read-ahead. The 2048 →
4096 KB raise this branch originally carried in `init.amogus.rc` was therefore
overwritten a few seconds after boot and never reached the kernel. What the
branch does now:

- **read-ahead has one value source.** Both the early `init.amogus.rc` write and
  the late `init.aospa.perf.common.rc` write use the `READAHEAD_KB` build setting
  (default `128`, AOSPA's own value and what the phone already ran), and both
  target only the real `mmcblk0` queue. The nonexistent `dm-*`/`sd*` targets are
  gone, including the copies in `init.amogus.rc`, so the intended and effective
  values cannot drift apart again. A/B test with `READAHEAD_KB=512 ./build.sh ...`.
- **`nr_requests` back to 128** (the kernel default). It was 256; nothing
  measured justified a deeper eMMC queue, and CFQ on eMMC gains nothing from it.
- **Boot-time scheduler margins are applied, not dropped**
  (`patches/kernel/motorola/msm-4.14.patch`). The downstream
  `sched_updown_migrate_handler` ignored every write in the first 120 s; that
  silently discarded the trinket block in `init.qcom.post_boot.legacy.sh`
  (`sched_downmigrate` 67, `sched_upmigrate` 77 at `sys.boot_completed`). The
  gate is removed, and the values now reach the scheduler; validation
  (`up <= down`) still runs. Read back with
  `adb shell cat /proc/sys/kernel/sched_upmigrate` (77; default 70) and
  `sched_downmigrate` (67; default 65). Device-untested.
- **zram 1 GB → 4 GB** in `rootdir/fstab.qcom` (`fstab_dynamic.qcom` 70% → 50%
  for consistency; doha builds non-dynamic, so `fstab.qcom` is the live file).
  4 GB is a deliberate over-commit on a 3.6 GB device: zram holds *compressed*
  pages, so 2 GB filled to 607 MB in use after one boot while `SwapFree` still
  looked healthy — the cap, not the compressor, was deciding how much of the app
  set survives.
  Evidence: the 2026-11-18 bugreport shows `SwapTotal 1048572 kB` with
  `SwapFree 2868 kB` — zram 99.7% full — and 133 LMK kills in that capture.
  `init.qcom.post_boot.legacy.sh` *tries* to size zram at 50% of RAM, but its
  `disksize` write returns `-EBUSY` because `init.target.rc`'s `on fs`
  `swapon_all` already enabled the device (`zram_drv.c: init_done` check), so
  the fstab is the only write that ever applies.
- **`IRQF_NO_SUSPEND` restored on `qcom_glink_native` and `smp2p`**
  (`patches/kernel/motorola/msm-4.14.patch`, reverting fork commits `a8b9cfc`
  and `0c55710`). Dropping `IRQF_NO_SUSPEND` caused a 100%-reproducible
  deadlock in `dpm_suspend_noirq()` on the first deep sleep after locking the
  screen on battery: on Trinket (`SM6125`), RPM runs over `qcom_glink_rpm` →
  `qcom_glink_native` (IRQ 20); without `IRQF_NO_SUSPEND`,
  `suspend_device_irqs()` marks IRQ 20 `IRQD_WAKEUP_ARMED`, so
  `irq_pm_check_wakeup()` disables it instead of running the ISR and any RPM
  `wait_for_completion()` during `suspend_noirq` hangs forever with the panel
  off and watchdog suspended (requiring a 10 s Power-key reset,
  `KPDPWR_N` / `hardware_reset`). Restoring the stock Motorola/Qualcomm flags
  (`IRQF_NO_SUSPEND | IRQF_SHARED` for glink, `IRQF_NO_SUSPEND | IRQF_ONESHOT`
  for smp2p) matches the 2026-11-18 kernel that survived 22 h / 108 wakes.
  The kit now keeps that IRQ enabled **without** calling `enable_irq_wake()`
  on the non-GVM glink path. Doing both was the configuration CAF explicitly
  reverted for Trinket in `d8d7d2423328`. Fork commits `4ab637fa`/`bfe8abcb`
  restored `IRQF_NO_SUSPEND` on glink and smp2p after pin `73b7957` proved
  fatal: 6 of 6 non-reboot boots froze after the susceptible build. The kit
  patch reconstructs that required flag at build time and must never remove
  it. The 2026-11-23 capture still exits suspend with `Resume caused by
  misconfigured IRQ 20 glink-native`, recording 2,564 suspend attempts and
  675 failures over 22h26m. GVM keeps wake arming; smp2p keeps
  `IRQF_NO_SUSPEND` plus wake because its sleep-state handshake needs it.
- **`CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT` off** in the kernel defconfig (carried by
  `patches/kernel/motorola/msm-4.14.patch`). The 2026-11-20 bugreport shows a clean
  shutdown reaching `sysrq: Terminate All Tasks` and then panicking with
  `Subsys notifier chain for modem taking too long`: the HLOS->modem sysmon handshake
  overran the 20 s `CONFIG_SSR_SYSMON_NOTIF_TIMEOUT`, and the panic turned an ordinary
  power-off into a dark screen. The timeout stays as a diagnostic (`WARN` plus a
  blocked-task dump); it just no longer panics.

- **app transition scale 0.8** in `patches/device/motorola/amogus_doha.patch`
  (still user-adjustable in Developer options).

- **Doze motion detection disabled** by the framework overlay in
  `patches/device/motorola/amogus_doha.patch`
  (`config_autoPowerModeUseMotionSensor=false`). `AnyMotionDetector` held a
  partial wake lock for 4m45s across 33 screen-off transitions in the
  2026-11-23 capture, and motion sensing delayed entry into deep idle. The
  tradeoff is deliberate: moving the phone or its significant-motion sensor
  no longer resets the idle transition; screen-on and alarm-driven wakeups
  are unchanged. This is device-untested.

- **No automatic first-boot dexopt.** The former
  `rootdir/vendor/bin/doha-dexopt-once.sh` service never ran in the shipped build:
  init reported no `doha-dexopt-once` service instance, `persist.doha.dexopt_status`
  stayed unset, and the service had no usable sepolicy domain for its persistent
  properties. It has been removed rather than adding a second dexopt framework.
  A fresh flash otherwise leaves apps in verify/JIT mode until the platform's idle
  `bg-dexopt-job` runs, which wants charging, idle and no reboot — on this phone
  that can be days. After installing apps, run
  `tools/dexopt-all.sh -m speed-profile --wait` once while charging.
- **`discard` turned off on the f2fs `/data` mount** (`rootdir/fstab.qcom`,
  `fstab_dynamic.qcom`, option `nodiscard`). With discard f2fs trims on every
  delete, which on this eMMC shows up as I/O stalls while apps are being evicted —
  exactly when the phone is already struggling. Android's periodic `fstrim` (vold
  idle maintenance) still trims the partition, in one batch instead of
  continuously. Note the option has to be `nodiscard`: removing `discard` from the
  fstab did nothing, because this Motorola 4.14 kernel's f2fs calls
  `set_opt(sbi, DISCARD)` in `default_options()` (`fs/f2fs/super.c`), so discard is
  on unless a mount option clears it.
- **`vm.min_free_kbytes` raised to 16 MB** (`patches/device/motorola/amogus.patch`,
  `init.amogus.rc`, `on init`). The 2026-11-26 capture has 11
  `binder: <pid>_N: page allocation failure: order:0` splats (16:21:42 and 16:52:35)
  each followed by `BINDER_WRITE_READ ... returned -14` (EFAULT): under GApps
  pressure the fault path could not get one page for the binder copy-to-user, with
  `Normal free: 1516kB` against `min:2012kB`. In the same window appear
  `binder_alloc_buf, no vma`, `DeadObjectException` and a crashed Chrome sandboxed
  process. The write changes no other knob (read-ahead, `nr_requests`, zram or LMK
  props); the only side effect is a slightly larger kernel reserve, so the LMK
  comparison below is part of the verification. It is **not**
  `config_extraFreeKbytesAdjust` (that overlay is dead, see below). Device-untested.

Not changed, deliberately: CPU/GPU frequencies and governors (`post_boot` already
selects `schedutil` with `hispeed_freq` 1305600/1401600), thermal thresholds
(`SKIN_THROTTLE_C`), and `walt`/`core_ctl`/`bfq` writes in the vendor scripts,
which are dead code: `CONFIG_SCHED_WALT`, `CONFIG_SCHED_CORE_CTL` and
`CONFIG_IOSCHED_BFQ` are all off in
`arch/arm64/configs/vendor/amogus_doha_defconfig`.

`config_extraFreeKbytesAdjust` is **not** a lever here: the 131072 in
`device/motorola/amogus`'s overlay never reaches the build (only
`dohaFrameworkOverlay`, `dohaSystemUIOverlay`, `dohaApertureOverlay` and
`NoNearbySharingOverlay` are compiled in, per `gcp-out/build.log`), so the phone
runs the AOSP default of `0`. Raising it would reserve free memory and make LMK
kill *earlier*, the opposite of what this device needs.

None of this is benchmarked on hardware yet. `tools/perf-audit.sh` prints what
the phone actually ended up with (governor, read-ahead, `nr_requests`, zram size
and saturation, PSI stall, thermal headroom) and exits with the number of
mismatches, so a build that silently lost a knob is visible without a bugreport.
`docs/OPTIMIZATION.md` is the plan of record for the tuning work: measured baseline,
phases, success criteria and rollback.

