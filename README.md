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
our remotes and an extra include, and `snippets/doha.xml` holds the 27
doha projects (device, vendor, kernel, HALs and the AOSPA trees the port
uses). crDroid's vendor tree is checked out at `vendor/lineage`, so the
device trees' `vendor/lineage/config/*.mk` inheritance works as-is.

The device tree and vendor blobs come from the community doha port by
Aldair402 and moto-common. We didn't write those. Our work is the
patches that get that port building and booting on Android 17.

The kernel is our fork of Christiaan's `android_kernel_motorola_msm-4.14`:
[`ishwar-chandra/android_kernel_motorola_msm-4.14`](https://github.com/ishwar-chandra/android_kernel_motorola_msm-4.14),
currently pinned to `73b7957` on branch `doha-kernel-fixes-2026-11-19`; `lts` carries the
4.14.357 baseline. Aldair402's kernel is Motorola's 4.14.190. Ours merges the
4.14 LTS updates up to 4.14.357 (OpenELA) on top of it, so it carries
several years of upstream security and stability fixes. `uname -r` shows
`4.14.357-openela+`.

The LineageOS 24.0 (Android 17) version of this ROM, with the same
device work, is on the `lineage-24.0` branch. The LineageOS 23.2
(Android 16) version is on `main`. This branch is `crdroid-android-17`.

New here? [`GUIDE.md`](GUIDE.md) walks through a build end to end: local and
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
5. Copies the zip, `boot.img`, `dtbo.img` and `vbmeta.img` into
   `~/doha/zips`, with a `.sha256sum` file.

The output is
`~/doha/zips/crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip`, next to
plain `boot.img`, `dtbo.img` and `vbmeta.img`, plus the zip's
`.sha256sum` file. The
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
GApps; you can add them yourself (see Installing).

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

1. `fastboot flash boot <boot.img>` and `fastboot flash dtbo
   <dtbo.img>`. This is only needed when you're coming from stock or a
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
2. Copy `boot.img` from the release you have installed to the phone. In
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
sensor and the dual-SIM XT2019-2.

Known issues:

- **VoLTE depends on the modem's carrier profile.** The modem picks one
  of Motorola's carrier profiles by SIM. For carriers Motorola has no
  profile for (for example SIMs on KPN's network in the Netherlands) it
  falls back to a generic profile with IMS off, so calls go over 2G/3G.
  Stock firmware does the same. Being investigated.
- **Double tap to sleep is a setting, and only on the status bar.** Turn on
  Settings → Status bar → "Double tap to sleep"; the lock screen has its own toggle
  and is on by default. Double-tapping the wallpaper does nothing: crDroid's
  Launcher3 for this branch declares the gesture but does not implement it, so that
  is by design rather than a regression.
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
./tools/app-trace.sh com.anthropic.claude # one app: its logs, screenshot, activity state
```

`bugreport-scan.py` drops the tags dumpstate itself produces and groups the rest, so the output is the
handful of lines worth reading instead of 40 MB of dumpsys; it also flags dump artifacts (resource-id
noise that only appears inside the dump). `BUGREPORT.md` is the record of what that sweep found.

## Differences from an official crDroid device

This build isn't official, and crDroid has no doha maintainer. Against
crDroid's [maintainer
rules](https://github.com/crdroidandroid/rules-and-guidelines) and
LineageOS's [device support
requirements](https://github.com/LineageOS/charter/blob/main/device-support-requirements.md)
(which crDroid builds on), it differs in these ways:

- **OTA is self-hosted.** The build does not use crDroid's OTA repo; it reads
  `ishwar-chandra/doha-ota` at `<channel>/doha.json`. `tools/gcp-build.sh
  finish` publishes the release and updates that feed, so a standard build
  only offers standard zips and a debloat build only debloat zips. The feed
  repo and its write token are a one-time setup; without them, update with
  `adb sideload` as described under Installing.
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
  with our remotes, plus `snippets/doha.xml`, which holds the 27 doha
  projects. `snippets/crdroid.xml` and `snippets/lineage.xml` are
  crDroid's, unmodified. crDroid maps `vendor/lineage` and
  `device/lineage/sepolicy` to its own forks at those paths, so the
  device trees' inheritance and `device/motorola/amogus`'s
  `device/lineage/sepolicy/libion/sepolicy.mk` include work unchanged.
- **Quick tap off** (`device/motorola/amogus_doha.patch`). crDroid's
  `vendor/lineage/config/crdroid.mk` adds the `ColumbusService` package
  unless `TARGET_SUPPORTS_QUICK_TAP := false`; doha has no quick-tap
  hardware, so the flag is set in `BoardConfig.mk`.
- **SafetyNet spoofing comes from crDroid.** The LineageOS build carried
  the `0001-Pass-SafetyNet.patch` from the docker-lineage-cicd image as
  `patches/system/core.patch`. crDroid's `system/core` already does this
  (`SPOOF_SAFETYNET=1` in `init/Android.bp`, `SetSafetyNetProps` in
  `property_service.cpp`), so that patch is gone. The docker image is
  still used as a toolchain container, but `build.sh` overrides its
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

### SafetyNet

The LineageOS 24.0 build carried `patches/system/core.patch`, the
`0001-Pass-SafetyNet.patch` from
[lineageos4microg/patches](https://github.com/lineageos4microg/patches)
that the docker-lineage-cicd image applies by default. It makes init
report a locked, verified boot state so that basic Play Integrity passes,
and makes fastbootd read the real lock state from the kernel command line.
crDroid's own `system/core` does the same thing
(`SPOOF_SAFETYNET=1`), so there is no `patches/system/core.patch` on this
branch. Our docker command still uses that image, but only as a toolchain
container, because `build.sh` replaces its entrypoint.

### 2026-11-18 bugreport follow-ups

**Launcher3 themed-icon crash** (`frameworks/libs/systemui.patch`). The
launcher's `IconProvider$ThemeData.loadPaddedDrawable()` treated a resource
ID from an updated or removed package as valid and called
`getResourceTypeName()`/`getDrawable()` on it. `Resources$NotFoundException`
killed the Launcher process (dropbox `system_app_crash`, IDs
`0xe020f5c`/`0xe020f4b`). The patch catches the missing resource and returns
`null`, so the caller falls back to the default icon instead of restarting
the workspace.

**Battery sysfs and power-HAL sepolicy** (`system/sepolicy.patch` and
`device/lineage/sepolicy.patch`). `system_suspend` was denied read access to
`sysfs_batteryinfo`, which is why `android.system.suspend-service` could not
read the wakelock/battery stats (D5). The rule belongs in system policy:
`system_suspend` is a private platform type, so a vendor policy file cannot
name it. `hal_power_default` was also denied `cgroup:file` reads for
`schedtune.boost`/`prefer_high_cap`; that rule stays in the device policy.
Neither patch broadens write access.

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

### Performance profile (`performance-tuning` branch)

Two conservative device changes, no CPU/GPU overclock and no thermal override:

- `patches/device/motorola/amogus.patch` — raise the boot eMMC read-ahead from
  256 to 512 KB, the runtime read-ahead from 2048 to 4096 KB, `nr_requests`
  from 128 to 256, and apply the same read-ahead to `dm-0`…`dm-5` for the
  dynamic partitions.
- `patches/device/motorola/amogus_doha.patch` — set the default app transition
  scale to 0.8 (still user-adjustable in Developer options).

These are not benchmarked on hardware. CPU/GPU governor, LMK/zram and thermal
thresholds are deliberately unchanged: they trade heat, battery or stability
for speed and need per-device measurements first.

