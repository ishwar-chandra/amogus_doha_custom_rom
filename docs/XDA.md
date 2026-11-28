[IMG]https://i.imgur.com/BE3pE0l.png[/IMG]

A special thanks to [USER=12919039]@Aldairsoraki[/USER] for the device tree, vendor blobs and recovery this build stands on, and to christiaan for the 4.14 kernel fork (lts branch). Without them this ROM would not exist.



crDroid is designed to increase performance and reliability over stock Android for your device, and to bring many of the best features that exist today.

Features: crdroid_features (17.0)



[CODE]

/*

* Your warranty is now void.

*

* I am not responsible for bricked devices, dead SD cards,

* thermonuclear war, or you getting fired because the alarm app failed. Please

* do some research if you have any concerns about features included in this ROM

* before flashing it! YOU are choosing to make these modifications, and if

* you point the finger at me for messing up your device, I will laugh at you.

*/

[/CODE]



• Android OS version: 17 (crDroid 13.1)

• Build release date: 2026-11-28

• Security patch: November 1, 2026

• Build author/Device Maintainer: [USER=13061592]@ishwarch[/USER]

• Kernel version: Linux 4.14.357-openela+ (christiaan/android_kernel_motorola_msm-4.14, branch lts)

• Device: Motorola Moto G8 Plus (XT2019-1 / XT2019-2)

• Device codename: doha (device tree: amogus_doha)

• Build type: userdebug, unsigned (AOSP test keys) — no GApps included



CREDITS



• [USER=12919039]@Aldairsoraki[/USER] — device tree, vendor blobs and recovery this build stands on

• [USER=7198594]@Electimon[/USER] — the original device tree, kernel and recovery work for doha

• christiaan — the 4.14 kernel fork (lts) the kernel patches build on

• crDroid team and LineageOS — the ROM, the manifest and the build system

• AOSPA and moto-common — the [ICODE]device/qcom/*[/ICODE] and [ICODE]vendor/qcom/common[/ICODE] HALs doha uses

• MindTheGapps / NikGapps — the Google app packages linked above



Without them there would be nothing to flash.



DOWNLOAD


[URL='https://github.com/ishwar-chandra/amogus_doha_custom_rom/releases/tag/crdroid-20261128']Download crdroid-20261128 (standard and debloat zips, images and sha256sums)[/URL]



• crDroidAndroid-17.0-<date>-amogus_doha-v13.1.zip — standard, everything crDroid ships

• crDroidAndroid-17.0-<date>-amogus_doha-v13.1-debloat.zip — same ROM without Game Space, floating windows, battery stats, MatLog, Twelve, Recorder and Glimpse



Each zip has its own images, named after it ([ICODE]…-boot.img[/ICODE], [ICODE]…-debloat-boot.img[/ICODE], and the same for dtbo and vbmeta) plus its own sha256sum file. The phone is A/B and recovery lives inside [ICODE]boot[/ICODE], so those images are all you need to get into recovery. Flash the images that match the zip you are going to sideload.



Check what you downloaded:



[CODE]

sha256sum -c crDroidAndroid-*.sha256sum

[/CODE]



ABOUT GAPPS



This ROM comes without Google apps. Use crDroid's own package for Android 17 / arm64:



[URL='https://sourceforge.net/projects/crdroid/files/gapps/NikGapps-crdroid-official-arm64-17-20261021.zip/download']NikGapps-crdroid-official-arm64-17 (486 MB)[/URL]



It lives in [URL='https://sourceforge.net/projects/crdroid/files/gapps/']crDroid's gapps folder[/URL] — take the newest arm64-17 official file if that date has been superseded. [URL='https://github.com/MindTheGapps/17.0.0-arm64/releases']MindTheGapps 17.0.0 arm64[/URL] is the smaller alternative and is what this device was tested with.



Flash it in the same recovery session as the ROM, right after it, answering Yes to "install additional packages". Adding GApps to a phone that already booted without them needs a factory reset.



WHAT HAS BEEN TESTED



• boot to the launcher, [ICODE]ro.build.type=user[/ICODE] with the crDroid user/release-keys spoof

• 47 hardware sensors, touchscreen, all four cameras, fingerprint HAL

• display 1080x2280 @ 60 Hz, speaker / wired / Bluetooth audio

• SIM + voice registration, VoLTE / IMS calls

• double tap to wake (kernel gesture on the FocalTech panel)

• SELinux enforcing with no denials, screen recording

• Play Store and Play services after flashing MindTheGapps/NikGapps

• quick tap (crDroid's ColumbusService)

• Dolby Atmos (DAX3 3.6): DaxUI presets, [ICODE]daxservice[/ICODE], the [ICODE]dms@2.0[/ICODE] HAL and the DAP effect — the Quick Settings tile toggles it

• OTA: the standard and debloat feeds are live and the Updater sees the 2026-11-28 build



BUGS / KNOWN ISSUES



• Basic Play Integrity pass on this device (kernel 4.14.357 on Android 17, test keys). Apps that require it — banking, some games — will refuse to run.

• DaxUI's power icon does not repaint live and the in-app button is unreliable — use the Quick Settings "Dolby" tile.

• In-app OTA install (download → reboot → slot switch) is not verified yet; sideload the zip if it stalls.

• You tell me — with logs (see below).



INSTALLATION NOTE



It is STRONGLY recommended to fully wipe your device before flashing, and please avoid restoring system apps and system data with Titanium Backup (or any backup/restore app) — that causes stability issues that are very hard to debug. Restoring regular apps is fine.



ROM firmware required: the latest stock Android 10 firmware on BOTH slots. The zip does not contain Motorola firmware.



CLEAN FLASH (coming from stock or another ROM)



1. Unlock the bootloader ([ICODE]fastboot flashing unlock[/ICODE], this wipes the phone).

2. Make sure the latest stock firmware is installed, then flash this release's images:



[CODE]

# images are named after the zip: …-boot.img for standard, …-debloat-boot.img for debloat

fastboot flash boot  crDroidAndroid-17.0-*-boot.img

fastboot flash dtbo  crDroidAndroid-17.0-*-dtbo.img

# only if verification complains; the anti-rollback warning is expected:

# fastboot flash vbmeta crDroidAndroid-17.0-*-vbmeta.img --disable-verity --disable-verification

[/CODE]



3. Boot to recovery (power + volume down → Recovery).

4. Factory reset → Format data.

5. Apply update → Apply from ADB, then on the computer:



[CODE]

adb sideload crDroidAndroid-17.0-*.zip

[/CODE]



6. If you want GApps, answer Yes to "install additional packages" and sideload the package in the same session; otherwise reboot.

7. Reboot. The first boot takes several minutes; the second is normal.



You can also put the zip on an SD card and use Apply update → Choose from sdcard1 instead of step 5.



DIRTY FLASH / UPGRADE



Already on this ROM: boot recovery, Apply update → Apply from ADB, [ICODE]adb sideload[/ICODE] the new zip. Flashing from recovery removes GApps, so sideload the same GApps package again in the same session, before booting.



Switching between the standard and the debloat build, or coming from another ROM, needs Format data — do not flash one variant over the other without wiping.



ROOT (optional)



Magisk 31.1 works with this build. Patch the release's [ICODE]boot.img[/ICODE] in the Magisk app (Install → Patch firmware / image), then



[CODE]

fastboot flash boot magisk_patched-*.img

[/CODE]



APatch works the same way on this device. Patch the [ICODE]boot.img[/ICODE] that came with the installed build — not one from another release — and re-patch it after every ROM update, because the boot image is replaced.



SOURCES AND DOCUMENTATION



• ROM source / build recipe (manifest + the 30 patches that make Android 17 boot on doha): [URL='https://github.com/ishwar-chandra/amogus_doha_custom_rom']ishwar-chandra/amogus_doha_custom_rom[/URL]

• Kernel: [URL='https://github.com/christiaan/android_kernel_motorola_msm-4.14']christiaan/android_kernel_motorola_msm-4.14[/URL] (branch lts)

• Device tree, vendor blobs, HALs: Aldair402 / moto-common, pinned in [ICODE]snippets/doha.xml[/ICODE]

• Per-fix rationale and what was tested: [ICODE]README.md[/ICODE] in the recipe repo; step-by-step build/flash walkthrough: [ICODE]GUIDE.md[/ICODE]; on-device findings: [ICODE]BUGREPORT.md[/ICODE].



REPORTING BUGS



Bring logs, not just symptoms:



[CODE]

./tools/device-check.sh                  # PASS/WARN/FAIL health check over adb

adb bugreport ./br.zip                   # while the problem is happening

./tools/bugreport-scan.py ./br.zip       # crash signatures + errors grouped by tag

./tools/app-trace.sh com.example.app     # one app: its logs, screenshot, activity state

[/CODE]



Note that [ICODE]ro.debuggable=0[/ICODE] on these builds (crDroid spoofs [ICODE]user[/ICODE]), so [ICODE]adb root[/ICODE] and [ICODE]dmesg[/ICODE] are not available; use [ICODE]logcat[/ICODE], and [ICODE]adb shell cat /sys/fs/pstore/console-ramoops-0[/ICODE] from recovery after a crash or bootloop.