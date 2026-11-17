# Device test report — crDroid 13 (Android 17), amogus_doha

Date: 2026-11-17 · phone: XT2019-1 (`doha`), serial ZF6522633X · tester: Hermes Agent

Build under test: `crDroidAndroid-17.0-20261117-amogus_doha-v13.1-adbkey`
(`ro.build.date=Tue Nov 17 09:06:03 UTC 2026`, sdk 37, `ro.build.type=user`, slot `_a`,
ADB_KEY test build — adb works from first boot, do not distribute).

Method: `tools/device-check.sh` (read-only PASS/WARN/FAIL over adb) plus targeted probes
(`logcat`, `dumpsys`, `aapt2` on the pulled APKs). Result of the automated pass:
**27 passed · 3 warned · 0 failed · 3 skipped**.

## 1. Defects

### D1 — Launcher3 crash loop (high, blocks daily use as a home screen)

Symptom: `com.android.launcher3` dies and restarts every 5-8 s (pids 5060 → 5547 → 6887 → 6972
observed), same exception each time:

```
FATAL EXCEPTION: main   Process: com.android.launcher3, PID 5547
android.content.res.Resources$NotFoundException: Resource ID #0x7f082f07
    at android.content.res.ResourcesImpl.getValueForDensity
    at android.view.View.setBackgroundResource(View.java:26891)
    at com.android.launcher3.widget.LauncherAppWidgetHostView.<init>(LauncherAppWidgetHostView.java:111)
    at com.android.launcher3.uioverrides.QuickstepWidgetHolder.createViewInternal
    at com.android.launcher3.preview.LauncherPreviewRenderer.bindCompleteUI
```

Root cause (verified): the shipped APK has no resource `widget_internal_focus_bg`, while its dex
asks for it. `LauncherAppWidgetHostView` line 111 is
`setBackgroundResource(R.drawable.widget_internal_focus_bg)`; the source tree contains
`packages/apps/Launcher3/res/drawable/widget_internal_focus_bg.xml` (added by Launcher3 commit
`cecb52c`), and `aapt2 dump resources` on the installed `Launcher3QuickStep.apk` shows the
surrounding drawable IDs (`0x7f082f00..04` = wi_fi_launcher, wibuku, wickr_me, wide_launcher)
but not `0x7f082f05..07` — the alphabetically-next entries, where `widget_internal_focus_bg`
belongs. The dex *does* contain the string, so code and resource table are from different
revisions.

Conclusion: an incremental build reused a stale `resources.arsc` while recompiling the Java.
Fix: clean-rebuild the launcher (`m installclean && mka Launcher3QuickStep bacon`, or drop
`out/` for that module), then assert the drawable is present:

```sh
aapt2 dump resources Launcher3QuickStep.apk | grep widget_internal_focus_bg   # must print a line
```

Trigger: any code path that inflates a widget host in a preview (Recents/overview, and the
widget picker) — i.e. it is not rare; it reproduces while simply using the phone.

### D2 — Verified boot reports green / `ro.boot.flash.locked=1` (needs a check, medium)

`ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`, yet fastboot flashed this build
minutes earlier and the recovery run reported `orange`. A locked bootloader would refuse a
test-key image, so either the bootloader was re-locked after flashing, or these props are being
misreported. Verify from the bootloader (`fastboot oem device-info` / `fastboot getvar
unlocked`) before the next flash; if it is genuinely locked, `fastboot flash` will fail and
`fastboot flashing unlock` (which wipes) is required.

### D3 — Cosmetic kernel noise

- `pmi632_charger: batt power supply prop 4 not supported` every 2-3 s while charging
  (`E` level, from the Motorola charger driver) — harmless, but it floods the kernel buffer.
- `audit: rate limit exceeded` (SELinux audit queue) and
  `suspend-service: Error opening kernel wakelock stats ... Permission denied` on a user build —
  expected for `ro.debuggable=0`, no action.
- `WindowOrganizerController: Attempting to externally change a non-organized container` when
  apps close — known WM noise, not device-specific.

## 2. Fixed: the earlier boot-animation hang (slot mismatch)

The previous ROM hung at the boot animation. Root cause: the images were flashed into the slot
that was active at that moment (`boot_b`), while the sideload installed the OS into the other
slot and switched to it (`boot_a`). Booting the hand-flashed slot paired a fresh boot/dtbo/vbmeta
with the older system → hang before `boot_completed` (no bootstat, no dropbox, no tombstones).
After letting the OTA reboot into its own slot, the same build boots.

`tools/flash.sh` now flashes boot/dtbo/vbmeta into **both** slots
(`fastboot flash --slot=all …`) so either slot the OTA activates is consistent;
`--current-slot` restores the old single-slot behaviour.

## 3. Verified working

| Area | Evidence |
| --- | --- |
| Boot | `sys.boot_completed=1`, bootanim stopped, 16 min uptime |
| adb from first boot | baked key works, `ro.adb.secure=1` kept |
| Radio (voice) | SIM `LOADED,LOADED`, `mVoiceRegState=IN_SERVICE` (BSNL, GSM) |
| Wi-Fi | service up, enabled (not associated at test time) |
| Bluetooth | service up, switched off |
| NFC | service up, switched off |
| Sensors | 47 hardware sensors, accelerometer present |
| Touch | `TOUCHSCREEN` source declared in input dump |
| Fingerprint | HAL `FingerprintProvider/defaultHIDL` answers |
| Camera | 4 camera devices |
| Display | 1080x2280 @ 60 fps |
| Audio | outputs enumerated (earpiece active) |
| Screen record | `/system/bin/screenrecord` present; 5 s recording produced a valid 72 KB MP4; tile works |
| Storage | `/data` 2 % used, `/sdcard` writable |
| Power/thermal | 85 %, 31.4 °C battery · CPU 47.7 °C |
| SELinux | enforcing, 0 denials in the buffer |

## 4. Needs a human (not covered by adb checks)

Calls with audio both ways · VoLTE with this carrier · mobile data with data enabled (it was
switched off) · Wi-Fi association + browsing · camera capture including ultra-wide · video
playback and speaker/headphone/BT audio · GNSS fix · fingerprint enrolment · NFC tap ·
double-tap-to-wake (known broken on FocalTech panels) · Magisk boot-image patching.

## 5. Reproduce this report

```sh
./tools/device-check.sh                 # PASS/WARN/FAIL summary, exit code = failures
adb logcat -b all -d > logcat.txt       # full buffer for the crash above
adb shell dumpsys activity service com.android.systemui/.SystemUIService | grep ScreenRecordTile
```

## 6. Findings from the on-device bugreport (`adb bugreport`)

Captured 2026-11-17 16:08 (3.6 MB zip, full dumpsys + all log buffers). New detail beyond the live checks:

- **SettingsIntelligence resource spam** — `com.android.settings.intelligence` logs
  `No package ID ff found for resource ID 0xffffffff` ~5,000 times. Same class of defect as D1
  (code asking for a resource the APK does not have); the clean rebuild below covers it too.
- **`ImeiPreference: PrimaryImei not available` (UnsupportedOperationException)** — Settings can't show
  the IMEI. On a `user` build the telephony service refuses it; cosmetic, but Settings → About → IMEI
  will be blank.
- **`HealthInterface: null health service, SAD!`** — misleading: the HAL *is* running
  (`android.hardware.health.IHealth/default`, `android.hardware.health-service.qti`). Transient
  framework race at boot, not a missing service.
- **`TaskPersister: File error accessing recents directory`** — recents persistence fails while the
  launcher crash-loops (D1); expect it to clear once the launcher is fixed.
- **No ANRs, no watchdog kills, 0 SELinux denials** in the whole report — the failure mode is one
  crash loop, not a broad framework problem.

## 7. Fixes applied for the next build

| Issue | Change |
| --- | --- |
| D1 Launcher3 crash loop | Launcher3/QuickStep intermediates deleted before the rebuild, so the APK is regenerated from the current source (variant switch forces a full rebuild as well). Verified post-build with `aapt2 dump resources … \| grep widget_internal_focus_bg`. |
| D3 charger log spam | `patches/kernel/motorola/msm-4.14.patch`: `pr_err` → `pr_debug` for the unsupported-battery-property path in `qpnp-smb2.c` (pure log level, no behaviour change). |
| D2 verified-boot state | Not patchable in the ROM — it is the bootloader's report. Check `fastboot getvar unlocked` / `fastboot oem device-info` before the next flash. |
| Boot-animation hang | Already fixed in `tools/flash.sh` (`--slot=all` by default). |
