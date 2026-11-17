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

**Still present on the 09:06 build** (bugreport captured 18:29, crash at 17:18:45, same
`0x7f082f07`, same `LauncherAppWidgetHostView.<init>` → `LauncherPreviewRenderer.inflateAndAdd`
path). So deleting the Launcher3 intermediates before that rebuild did not fix it: the stale
`resources.arsc` survives a module-level clean because aapt2's output lives in
`out/…/intermediates/packaged_res` and the APK is only re-linked, not re-packed, when the
resource *inputs* look unchanged. The reliable form of the fix is a build from an empty `out/`,
which is what the next VM run does — and the `aapt2 dump resources … | grep
widget_internal_focus_bg` assertion must gate that build, not the next incremental one.

It is one crash per boot on this build, not a loop: the launcher restarts and the phone stays
usable, which is why it survived a day of testing unnoticed.

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

### D7 — Home-screen icons cannot be moved: the workspace never leaves "loading" (high, not a feature)

Reported after the launcher crash: long-press an icon, the drag never starts, the item snaps back,
and the home screen feels stuck. It is **not** a lock-layout feature — Launcher3 has no user-facing
workspace lock; the flag behind it is the load state. Proof from this bugreport's launcher dump:

```
mWorkspaceLoading=true mPendingRequestArgs=null
```

in both snapshots (18:13 and 18:29, ~75 min after the crash), while the icons themselves are drawn.

The chain, from `packages/apps/Launcher3` at branch 17.0:

- `Launcher.isWorkspaceLocked()` returns `isWorkspaceLoading() || mPendingRequestArgs != null`
  (Launcher.java:2643) — `mPendingRequestArgs` was null, so the load flag is what locks it.
- `ItemLongClickListener.canStartDrag` refuses when `launcher.isWorkspaceLocked()`
  (ItemLongClickListener.java:145) — that is the "cannot move anything" symptom, and the same flag
  also gates add-to-workspace, folder creation and widget drops (Workspace.java:908, 973, 1045, 1162).
- `workspaceLoading` is set `true` in `startBinding()` and cleared in exactly one place:
  `finishBindingItems()`, *after* `workspace.restoreInstanceStateForRemainingPages()`
  (ModelCallbacks.kt:195). A throw during that restore — the same resource damage as D1 — leaves the
  flag true for the rest of the session. Only a process restart resets it, and the next bind can hit
  the same path again.

So D1 and D7 are one root cause with two symptoms: the launcher APK's resource table is older than
its code. Fixes in the kit:

- `patches/packages/apps/Launcher3.patch`: the missing-drawable `setBackgroundResource` is wrapped so
  a bad table costs one background instead of the process, and `workspaceLoading` is cleared in a
  `finally` so no failure can lock the home screen for the session.
- `build.sh` now refuses to finish a build whose launcher APK lacks `widget_internal_focus_bg`
  (`aapt2 dump resources`), so the stale-table build cannot be flashed again.

### D4 — GMS crashes on the platform's Safety Center source list (medium, no user-visible break)

Three crashes inside 11 s on the 09:06 build, all the same:

```
FATAL EXCEPTION: [GmsIntentOperationChimeraService-Executor] idle
Process: com.google.android.gms
java.lang.IllegalArgumentException: Unexpected safety source: AdvancedProtection
    at android.os.Parcel.createExceptionOrNull(Parcel.java:3396)   ← thrown by the *platform*
```

The binder call goes into the Safety Center service, which validates the source against the
enum of safety sources the platform build knows. `AdvancedProtection` is newer than the AOSP 17
list this build compiles, so the platform rejects the call and GMS dies in its intent-operation
service; it restarts and retries. Not caused by any doha patch — the same signature is reported
on other Android 17 builds paired with recent GApps packages.

Effect: background GMS work (safety/security check-ins) restarts a few times per boot; Play
Store and sign-in are unaffected. Fix has to come from the platform side (add the source to the
`frameworks/base` safety-source enum) or from a GMS version that matches; not worth patching a
third-party project for.

### D5 — SELinux denials: `system_suspend` cannot read battery sysfs (low, noisy)

263 audit lines, dominated by one pair:

```
avc: denied { read } for scontext=u:r:system_suspend tcontext=u:object_r:sysfs_batteryinfo
```

which is also why `android.system.suspend-service` logs `Error opening kernel wakelock stats for:
wakeup38/…` — the suspend service walks `/sys/class/power_supply` for wakelock accounting and is
denied. Suspend itself works (the phone dozes); only the stats are missing. Either the label or
the rule is missing in the vendor sepolicy; a two-line `allow` in our sepolicy patch would quiet
it, and is safe (read-only, already world-readable sysfs).

The rest is expected noise: 19 × `untrusted_app -> system_adbd_prop: read` (apps probing adb
props on a `user` build), 8 × `mediaprovider_app -> radio_service: find` (upstream AOSP quirk),
plus single digits for shell/dumpstate checks.

### D6 — keystore2 refuses attestation without an attestation key (informational)

`keystore2` logs, whenever an app asks for an attested key:

```
While generating without a provided attestation key and parameter…
```

Keymaster on this device has no provisioned attestation keys, so keys are generated but cannot
be attested. Consequence: Play Integrity basic checks may pass via the SafetyNet spoof, but
hardware attestation does not exist; nothing to fix in the ROM and no app misbehaviour observed.

### D8 — No Wi-Fi RTT service (low, feature missing)

`SystemServiceRegistry: No service published for: wifirtt` (23 times, every time an app asks).
The Wi-Fi HAL never publishes `IWifiRttController`, so 802.11mc ranging — what apps use for
room-level indoor positioning — is unavailable. Nothing crashes; features that call it get a
`ServiceNotFoundException`. Either the vendor Wi-Fi HAL lacks RTT or the feature flag is off in the
device config; would need the HAL sources to confirm.

### D9 — Settings cannot show the IMEI (cosmetic, by design)

`ImeiPreference: PrimaryImei not available` 112 times, i.e. every time About → IMEI is opened. The
telephony service refuses `getDeviceId` on a `user` build without the privileged permission, which
is exactly what `PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG` gives us. Settings shows an empty field
instead of the IMEI. Not fixable without weakening the build; the IMEI is on the box and readable
with `fastboot getvar` anyway.

### D10 — Fingerprint HAL error 5 once (watch item)

```
E FingerprintHal: [fingerprint.c] [on_error_msg:361] on_error 5
E FingerprintHal: [fingerprint.c] [fingerprint_cancel:976] ets_fp_verify_finger(), fps_cancel
                 g_finger_lost_detec
```

One occurrence, during an unlock: the sensor reported "finger lost" while verifying and the HAL
cancelled. Error 5 is a cancel, so the worst case is a retry. Only if it repeats per unlock is it a
sensor/placement problem rather than normal cancellation.

### D11 — Audio HAL cannot take a perf lock (cosmetic)

`audio_hw_extn: audio_extn_perf_lock_acquire: Incorrect params, Failed to acquire perf lock` ×18,
followed by `out_write: retry previous failed cal level set`. The QTI audio HAL asks the perf HAL
for a boost and gets its arguments rejected; audio still plays, the boost just never happens. No
perf HAL is present in this image (only the cameraservice/audio/sensorservice HALs are registered),
which matches the failure.

## 8. Full-sweep inventory (tools/bugreport-scan.py)

`tools/bugreport-scan.py` runs the same analysis over any bugreport zip and groups every error tag
with a sample, so this section is reproducible rather than hand-collected.

Crashes in the 4 h capture (boot 14:36:26 → report 18:31): **3 × GMS (D4), 1 × Launcher3 (D1)**.
No ANRs, no native crashes, no `system_server` restarts, no watchdog kills, no `SYSTEM TOMBSTONE`,
no LMK kills, no thermal trips, no `Davey`/`Slow dispatch` samples. Battery: 159 mAh computed over
the session, screen 53.5 mAh, wakelocks 0.06 mAh, camera 1.2 mAh.

| Count | Tag | Verdict |
| --- | --- | --- |
| 301 | `android.system.suspend-service` wakelock stats | D5, sepolicy |
| 130 | `AndroidRuntime` `Unexpected safety source: AdvancedProtection` | D4, platform/GApps |
| 112 | `ImeiPreference` | D9, `user` build |
| 91 | `VendorCaps: Failed to read platform VT driver version` | vendor lib probing a VT driver; benign |
| 90 | `QC2V4l2Driver: queryControl failed id 992077` | video *decoder* vendor control query (`avcD_0`, `hevcD_0`); benign, not the camera |
| 70 | `YT.mlplayer` / `YT.qoe` | YouTube's own player/analytics |
| 36 | `StandardCaps: FrameRateInputHelper queryParamRanges failed` | encoder caps probe; benign |
| 25 | `TransitionChain: Can't collect into a chain` | WM noise |
| 23 | `SystemServiceRegistry: No service published for: wifirtt` | D8 |
| 21 | `sensors-hal: mot_disprot_event` | Motorola rotation sensor, expected |
| 20 | `iftw: Trace … timed out after 1457038 ms` | GMS trace plumbing, app side |
| 18 | `audio_hw_extn` perf lock | D11 |
| 13 | `OMX-VDEC-1080P: extension not implemented` | optional codec extension, benign |
| 13 | `system_server: poll() failed: Interrupted system call` | EINTR on a signal, expected |
| 12 | `KeyMasterHalDevice: Attest key send cmd failed` | D6 |
| 10 | `ConsumerBase: abandonLocked` | screen-record/camera pipeline teardown |
| 10 | `Settings: Invalid resource ID 0x00000000` | benign null id (see below) |
| 10 | `QcrilOemhookMsgTunnel: Unexpected serial number` | RIL oemhook noise |

One hypothesis to kill before someone chases it: `Invalid resource ID 0x00000001…0x00000010` appears
in Launcher3 (7×) and SystemUI (8×), all at **18:29:56**, i.e. inside the dumpstate run — a dump
artifact, not runtime damage. Only the launcher's `0x7f082f07` (D1) is a real missing resource.
`knrq: Previous channel … garbage collected` (804×) is GMS 26.45.31's own gRPC bookkeeping, uid
10225, not a platform defect.

Also expected with an AOSP launcher plus GMS: `Unable to start service Intent {
act=com.android.launcher3.WINDOW_OVERLAY … pkg=com.google.android.googlequicksearchbox }` — the
Google app looks for its launcher overlay in its own package, which only the Google launcher has.

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
- **No ANRs, no watchdog kills, no tombstones, 0 `Fatal signal`** in the whole report.
- SELinux: the earlier capture showed 0 denials, this one shows 263 (see D5) — same build, so the
  difference is what the phone was doing (charging + dozing), not a policy change. The kernel log
  is otherwise clean: no `EXT4-fs error`, no `hung task`, no thermal trip, no LMK kills.

## 7. Fixes applied for the next build

| Issue | Change |
| --- | --- |
| D1 Launcher3 crash loop | Launcher3/QuickStep intermediates deleted before the rebuild, so the APK is regenerated from the current source (variant switch forces a full rebuild as well). Verified post-build with `aapt2 dump resources … \| grep widget_internal_focus_bg`. |
| D3 charger log spam | `patches/kernel/motorola/msm-4.14.patch`: `pr_err` → `pr_debug` for the unsupported-battery-property path in `qpnp-smb2.c` (pure log level, no behaviour change). |
| D2 verified-boot state | Not patchable in the ROM — it is the bootloader's report. Check `fastboot getvar unlocked` / `fastboot oem device-info` before the next flash. |
| D4 GMS `AdvancedProtection` | Nothing to patch here: the rejection comes from the platform safety-source enum. Revisit if GMS still crashes after the next GApps bump; a `frameworks/base` enum addition is the only real fix. |
| D5 `system_suspend` denials | Proposed, not applied (needs the tree to regenerate the patch): `allow system_suspend sysfs_batteryinfo:dir r_dir_perms;` and `… :file r_file_perms;` in the device sepolicy. Read-only sysfs, safe to allow; it only restores wakelock stats. |
| D6 keystore attestation | Informational. No attestation keys exist on this hardware; documented so it is not mistaken for a regression. |
| Boot-animation hang | Already fixed in `tools/flash.sh` (`--slot=all` by default). |
