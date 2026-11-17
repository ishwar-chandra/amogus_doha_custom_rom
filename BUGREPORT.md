# Device test report — crDroid 13 (Android 17), amogus_doha

Date: 2026-11-17 · phone: XT2019-1 (`doha`), serial ZF6522633X · tester: Hermes Agent

Build under test: `crDroidAndroid-17.0-20261117-amogus_doha-v13.1-adbkey`
(`ro.build.date=Tue Nov 17 09:06:03 UTC 2026`, sdk 37, `ro.build.type=user`, slot `_a`,
ADB_KEY test build — adb works from first boot, do not distribute).

Method: `tools/device-check.sh` (read-only PASS/WARN/FAIL over adb) plus targeted probes
(`logcat`, `dumpsys`, `aapt2` on the pulled APKs). Result of the automated pass:
**27 passed · 3 warned · 0 failed · 3 skipped**.

## 1. Defects

### D2 — Verified boot reports green / `ro.boot.flash.locked=1` (needs a check, medium)

`ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`, yet fastboot flashed this build
minutes earlier and the recovery run reported `orange`. A locked bootloader would refuse a
test-key image, so either the bootloader was re-locked after flashing, or these props are being
misreported. Verify from the bootloader (`fastboot oem device-info` / `fastboot getvar
unlocked`) before the next flash; if it is genuinely locked, `fastboot flash` will fail and
`fastboot flashing unlock` (which wipes) is required.

### D3 — Cosmetic kernel noise

- `audit: rate limit exceeded` (SELinux audit queue) and
  `suspend-service: Error opening kernel wakelock stats ... Permission denied` on a user build —
  expected for `ro.debuggable=0`, no action.
- `WindowOrganizerController: Attempting to externally change a non-organized container` when
  apps close — known WM noise, not device-specific.

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

### D6 — key attestation fails with Km(-10003): this is why Play Integrity apps break (high)

`keystore2` logs, whenever an app asks for an attested key:

```
While generating without a provided attestation key and parameter…
```

Keymaster has no attestation key to sign with, so `KeyGenParameterSpec` with an attestation
challenge always fails with `KM_ERROR_KEY_NOT_FOUND`. The bugreport carries 68 of these in six
minutes, all from uid 10316 = `com.google.android.apps.nbu.paisa.user` (**Google Pay India**), and the
Keymaster HAL logs `Attest key send cmd failed / resp->status: -10003` alongside.

This is not cosmetic. On Android 13+ every Play Integrity device label — including
`MEETS_BASIC_INTEGRITY` — requires a key-attestation chain rooted at Google, so with no chain the
verdict is empty and any app that checks it refuses to run. `MEETS_DEVICE_INTEGRITY` would additionally
require a locked bootloader and a certified OEM image, and `MEETS_STRONG_INTEGRITY` patch levels for
all partitions including Motorola's 2022 vendor blob. None of that is reachable on an unlocked,
self-signed build; the attestation key lives in the TEE and cannot be created by the OS. Full
analysis, the decisive KeyAttestation test, and what is deliberately *not* done about it (keybox
spoofing) are in `PLAYINTEGRITY.md`.

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

## 2. Verified working
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

## 3. Needs a human (not covered by adb checks)
Calls with audio both ways · VoLTE with this carrier · mobile data with data enabled (it was
switched off) · Wi-Fi association + browsing · camera capture including ultra-wide · video
playback and speaker/headphone/BT audio · GNSS fix · fingerprint enrolment · NFC tap ·
double-tap-to-wake (known broken on FocalTech panels) · Magisk boot-image patching.

## 4. Reproduce this report
```sh
./tools/device-check.sh                 # PASS/WARN/FAIL summary, exit code = failures
adb logcat -b all -d > logcat.txt       # full buffer for the crash above
adb shell dumpsys activity service com.android.systemui/.SystemUIService | grep ScreenRecordTile
```

## 5. Findings from the on-device bugreport (`adb bugreport`)
Captured 2026-11-17 16:08 (3.6 MB zip, full dumpsys + all log buffers). New detail beyond the live checks:

- **SettingsIntelligence resource spam** — `com.android.settings.intelligence` logs
  `No package ID ff found for resource ID 0xffffffff` ~5,000 times. A resource-table defect like the launcher's; a build from an empty out/ covers it.
- **`ImeiPreference: PrimaryImei not available` (UnsupportedOperationException)** — Settings can't show
  the IMEI. On a `user` build the telephony service refuses it; cosmetic, but Settings → About → IMEI
  will be blank.
- **`HealthInterface: null health service, SAD!`** — misleading: the HAL *is* running
  (`android.hardware.health.IHealth/default`, `android.hardware.health-service.qti`). Transient
  framework race at boot, not a missing service.
- **`TaskPersister: File error accessing recents directory`** — recents persistence failed while the launcher was
  crash-looping; the launcher fix is in the kit.
- **No ANRs, no watchdog kills, no tombstones, 0 `Fatal signal`** in the whole report.
- SELinux: the earlier capture showed 0 denials, this one shows 263 (see D5) — same build, so the
  difference is what the phone was doing (charging + dozing), not a policy change. The kernel log
  is otherwise clean: no `EXT4-fs error`, no `hung task`, no thermal trip, no LMK kills.

## 6. Full-sweep inventory (tools/bugreport-scan.py)

`tools/bugreport-scan.py` runs the same analysis over any bugreport zip and groups every error tag
with a sample, so this section is reproducible rather than hand-collected.

Crashes in the 4 h capture (boot 14:36:26 → report 18:31): **3 × GMS (D4), 1 × Launcher3**.
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
artifact, not runtime damage. Only the launcher's `0x7f082f07` is a real missing resource.
`knrq: Previous channel … garbage collected` (804×) is GMS 26.45.31's own gRPC bookkeeping, uid
10225, not a platform defect.

Also expected with an AOSP launcher plus GMS: `Unable to start service Intent {
act=com.android.launcher3.WINDOW_OVERLAY … pkg=com.google.android.googlequicksearchbox }` — the
Google app looks for its launcher overlay in its own package, which only the Google launcher has.

