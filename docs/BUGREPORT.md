# Device bug report — crDroid 13 (Android 17), amogus_doha

Actionable form: each bug has a one-line name, a short summary, the fix location, and a
verification checklist. `code-fixed` means committed but not device-verified; no build or flash was
possible in this workspace.

## Capture metadata

| | capture A | capture B |
|---|---|---|
| File | `bugreports/bugreport.zip` | `bugreports/bugreport-...23-13-33.zip` |
| Time | 2026-11-18 19:57 | 2026-11-18 23:13 |
| Serial | `ZY326WF2N3` | `ZF6522633X` |
| Uptime | 3 h 0 m | 13 h 36 m |
| SIMs | both `ABSENT` | BSNL + JIO, both LTE `IN_SERVICE` |
| Fingerprint | Egistec (`ro.vendor.hw.fps_id=egis`) | Egistec |
| Boot reason | `reboot` | `kernel_panic` |

Build: `ro.build.date=Wed Nov 18 02:13:54 UTC 2026`, `ro.build.version.sdk=37`,
`ro.build.type=user`, `ro.crdroid.version=17.0`.

Capture E: `bugreports/bugreport-doha-CP2A.260605.016-2026-11-26-18-14-59.zip`,
2026-11-26 18:14, serial `ZF6522633X`, uptime 1 d 17 h 54 m, BSNL + JIO both LTE,
build 2026-11-20 (`ro.build.date=Fri Nov 20 02:13:41 UTC 2026`, kernel `#7` Nov 20),
boot reason `reboot`, no panic. It produced P18/P19 and refreshed P11 and C1.

## Status at a glance

| Status | Entries | Individual issues |
|---|---|---|
| Fixed in code, device-unverified | 5 (P1, P3, P18, P19, D5) | 7 |
| Partially fixed | 3 (P2, P10, P14) | 3 entries, several sub-items open |
| Mitigation only | 3 (P6, P8, P9) | 3 |
| Likely fixed upstream, unverified | 1 (P4) | 1 |
| Open | 11 (P5/P7/P11/P12/P13/P15/P16/P17, D6, D8, D9) | 35 |
| **Tracked total** | **23** | **46** |

`P5` is the old `D4`; `D2` is closed (the green verified-boot property is crDroid's SafetyNet spoof).
`D5` is one row of P10.

Legend: `[x]` done in code, `[ ]` needs verification or work.

---

## P1 — Shutdown panic: modem notifier timeout
**Status:** fixed in code (kernel), device-unverified. **Severity:** critical.
**Summary:** During shutdown the modem SSR notifier chain exceeded its timeout and panicked the
kernel (`Subsys notifier chain for modem taking too long`); pstore also records
`androidboot.bootreason=kernel_panic`.
**Fix:** kernel `d93bfa2` (qcacld: move SSR cleanup off `FW_DOWN`, do it on `FW_CRASHED`) plus
`710ed46` (dump stuck task before panic). Both are ancestors of the pinned kernel `fix`
at `9a3cf72`.
- [x] Kernel commits present in the build pin.
- [ ] Rebuild with a syncing `./build.sh`; no `SKIP_SYNC=1`.
- [ ] Reboot 5× and reproduce hotspot/WLAN-SSR; `dmesg` must not contain
  `Subsys notifier chain for modem taking too long`.
- [ ] If it still panics, attach the new stack dump from `710ed46`.

## P2 — Suspend deadlock after dropping `IRQF_NO_SUSPEND` on glink/smp2p (reverted)
**Status:** reverted in kernel branch `fix` at `9a3cf72`, device-unverified. **Severity:** critical (was high).
**Summary:** Dropping `IRQF_NO_SUSPEND` in fork commits `a8b9cfcea310` (glink) and `0c55710bfa99`
(smp2p) to silence `misconfigured IRQ 20 glink-native` broke deep suspend completely on both
`crdroid-20261120` and `crdroid-20261120-2`: 6 of 6 non-reboot boots (`last_kmsg`..`last_kmsg.7` in
`bugreport-doha-CP2A.260605.016-2026-11-20-07-07-57.zip`) deadlocked permanently on the first deep
sleep after locking on battery (`Battery History` showed zero `-running` -> `+running` resumes
after the 05:15:50 OTA reboot, vs 22.3 h / 108 wakes on 2026-11-18). Because Trinket RPM uses
`qcom_glink_rpm` -> `qcom_glink_native` (IRQ 20), removing `IRQF_NO_SUSPEND` lets
`suspend_device_irqs()` arm `IRQD_WAKEUP_ARMED`, so `irq_pm_check_wakeup()` masks IRQ 20 instead of
running the ISR and RPM `msm_rpm_wait_for_ack()` hangs forever inside `dpm_suspend_noirq()` with
the panel off and `msm_watchdog_suspend()` disabled (looks like a silent power-off until long-press
`KPDPWR_N` / `hardware_reset`). Confirmed by Qualcomm's own msm-4.14 commit `647d16d0`
(`deesin@codeaurora.org`).
**Fix:** kernel branch `fix` at `9a3cf72` restores `IRQF_NO_SUSPEND | IRQF_SHARED`
(`qcom_glink_native.c`) and `IRQF_NO_SUSPEND | IRQF_ONESHOT` (`smp2p.c`). Do **not** remove
`IRQF_NO_SUSPEND` from glink without also wiring `pm_system_wakeup()` + `glink_native_pm_ops` on
both RPM and SMEM transports.

The same kernel branch also skips `enable_irq_wake()` on the non-GVM glink path. That is the
separate `misconfigured IRQ 20` fix: glink stays enabled through noirq suspend (`IRQF_NO_SUSPEND`
is retained), but is no longer armed as a wake source. This must not be confused with the failed
`a8b9cfc`/`0c55710` commits, which removed `IRQF_NO_SUSPEND`; smp2p still keeps both flags because
its sleep-state handshake requires wake arming.
- [x] Kernel `fix` branch pushed; kit pins `9a3cf72` and removes the redundant glink/smp2p patch
  hunks.
- [x] Kernel patch applies against `9a3cf72` with `git apply --check`.
- [ ] Rebuild, flash, unplug USB, lock with Power button for 5 min, wake cleanly; repeat 5×.
- [ ] Confirm `Battery History` shows `-running` -> `+running` resumes and no `KPDPWR_N` reset.

## P3 — Launcher3 crash loading a stale themed-icon resource
**Status:** fixed upstream, device-unverified. **Severity:** high.
**Summary:** Launcher3 died with `Resources$NotFoundException` in
`IconProvider$ThemeData.loadPaddedDrawable()` after a package update invalidated a themed-icon
resource; `KillApplicationHandler` restarted the workspace.
**Fix:** upstream `frameworks/libs/systemui` commit `f74e6a0` catches
`Resources.NotFoundException` and returns `null`, so the caller falls back to the default icon.
The local patch was removed after this landed.
- [x] Fix present on the pinned `frameworks/libs/systemui` branch; no local patch.
- [ ] Update/remove an app with a themed icon; Launcher3 must not appear in
  `dumpsys dropbox -p system_app_crash`.
- [ ] Home screen drag and widget placement still work after the update.

## P4 — Settings crash opening the Sidebar preference
**Status:** likely fixed upstream, unverified. **Severity:** high.
**Summary:** Clicking the Sidebar preference threw `ActivityNotFoundException` for
`com.libremobileos.sidebar/...SidebarSettingsActivity`, which is not installed.
**Fix:** no kit patch; current `packages/apps/Settings` branch `17.0` no longer contains that
preference/activity (HEAD 2026-11-18 19:09, after the build under test).
- [ ] Sync Settings to current `17.0` and rebuild.
- [ ] Open every crDroid Settings entry; no `SettingsBaseActivity` crash.
- [ ] If the preference is still present, either package Sidebar or hide the preference when
  `com.libremobileos.sidebar` is absent.

## P5 — GMS crashes on `AdvancedProtection` safety source
**Status:** open (platform/GApps mismatch). **Severity:** medium; this is old D4.
**Summary:** `SafetyCenterManager.setSafetySourceData()` rejects the source
`AdvancedProtection`; GMS dies in `GmsIntentOperationChimeraService` and retries.
**Fix:** no device patch. Needs a platform safety-source enum update or a matching GApps package.
- [ ] Confirm the crash count in dropbox after a GApps update.
- [ ] Do not add a third-party-project patch unless the platform enum is extended intentionally.

## P6 — Nearby Share cannot advertise: local-network AppOp missing
**Status:** mitigation in kit (AppOp registered), device-unverified. **Severity:** medium.
**Summary:** GMS 26.46 asks for `ACCESS_LOCAL_NETWORK`; AppOps reports
`Operation not found`, then `SecurityException: Missing local network permission`; 12×
`BpfNetMaps local_net_access unsupported`.
**Fix:** `patches/frameworks/base.patch` registers `OP_ACCESS_LOCAL_NETWORK` even when the
`access_local_network_permission_enabled` flag is off, so GMS finds the op. The permission stays
unenforced; `BpfNetMaps` still skips the 4.14 local-net maps.
- [x] AppOps patch applies to `frameworks/base` branch `17.0`.
- [ ] Rebuild and start Quick Share/Nearby advertising with BLE on.
- [ ] Bugreport must have no `Operation not found ... ACCESS_LOCAL_NETWORK`.
- [ ] If advertising still fails, capture `NearbyMediums`/`BpfNetMaps` lines; the 4.14 BPF
  limitation remains separate.

## P7 — Find My Device first-party signature rejected
**Status:** open; not fixable in AOSP. **Severity:** medium.
**Summary:** `FirstPartyBroadcaster: Signature check failed. The calling package is not google
signed` on the Find My Device sync path.
**Fix:** none. Requires Google-signed system components; do not spoof the signature.
- [ ] Document Find My Device as unsupported.
- [ ] Verify no user-visible crash beyond the one-time registration failure.

## P8 — NFC writes fail with `-ENOTCONN`
**Status:** mitigation (kernel), device-unverified. **Severity:** medium.
**Summary:** `nq-nci` logged 7× `nfc_write: failed to write -107` and one misleading
`NFCC HW not Supported`; NFC was off during the capture.
**Fix:** kernel `73b7957` retries `nfc_write()` 3× at 10 ms on `-ENOTCONN`/`-EIO`.
- [x] Retry commit in the pinned branch.
- [ ] Enable NFC, tap an NDEF tag, read it.
- [ ] Bugreport must have no `nfc_write: failed to write -107` during the successful session.
- [ ] If NFC is still dead, capture the `nfcc_hw_check` chip-type value; the retry is not enough.

## P9 — Camera EEPROM/CCI read failures
**Status:** mitigation (kernel), device-unverified. **Severity:** medium.
**Summary:** Boot log had `msm_cci_irq MASTER_0 error 0x10000000`, `rc -22`, and
`eeprom_parse_memory_map: read failed`; 4 cameras still enumerate.
**Fix:** kernel `08e44ce67911` retries the EEPROM memory map 3× at 10 ms on
`-EIO/-ENXIO/-EINVAL`. The CCI retime race is already fixed by `52885f0`.
- [x] Retry commit in the pinned branch.
- [ ] Open Aperture and switch through cameras 0–3; take one photo each.
- [ ] Bugreport must not repeat `eeprom_parse_memory_map: read failed` for a present sensor.
- [ ] Compare ultra-wide/macro focus and colour with stock; if calibration is still missing, the
  issue is sensor/EEPROM data, not the retry.

## P10 — SELinux policy gaps
**Status:** partial (two rules fixed), device-unverified. **Severity:** medium/low.
**Summary:** `system_suspend` could not read `sysfs_batteryinfo`; `hal_power_default` could not read
`schedtune` cgroup files; other denials remain (`content_capture`, `dex2oat`, `app_zygote`,
`hal_camera`, `vendor_qtelephony`, Meta `execmod`).
**Fix:** `patches/system/sepolicy.patch` adds:
`allow system_suspend sysfs_batteryinfo:file r_file_perms;` (`system_suspend` is a private
platform type, so this cannot live in vendor policy);
`patches/device/lineage/sepolicy.patch` adds
`allow hal_power_default cgroup:file r_file_perms;`.
`system/sepolicy.patch` also exempts `system_suspend` from the `coredomain`
neverallow on `sysfs_batteryinfo`; otherwise `checkpolicy` rejects the rule.
- [x] Both rules in the kit patch.
- [ ] Bugreport must have zero `system_suspend -> sysfs_batteryinfo` denials.
- [ ] Bugreport must have zero `hal_power_default -> cgroup` denials.
- [ ] Remaining denial classes are intentionally not broadened; address only with a reviewed
  per-domain policy change.

## P11 — Wi-Fi HAL/framework errors
**Status:** open. **Severity:** low/medium.
**Summary:** `getUsableChannels` fails (24 lines in A), `setBtCoexistenceMode` returns code 1,
Passpoint logs `null osuProviders`, and ConnectivityService reports a band-specifier change.
**Fix:** no kernel/kit patch; WiFi HAL, wpa_supplicant and framework.
- [ ] Test hotspot/SoftAP channel selection.
- [ ] Test Wi-Fi + BT coexistence throughput.
- [ ] File against `packages/modules/Wifi` or the vendor WiFi HAL only with a reproducer.

## P12 — Bluetooth A2DP underruns
**Status:** open. **Severity:** low.
**Summary:** 30× `ONLY READ 0 BYTES OUT OF 4096` and AudioFlinger underruns while A2DP was
starting/suspending.
**Fix:** no kit patch; Bluetooth/audio userspace.
- [ ] Play 10 min over A2DP and listen for glitches.
- [ ] If audible, capture `dumpsys media.audio_flinger` and a BT HCI log.

## P13 — USB current-limit and dwc3 PHY errors
**Status:** open. **Severity:** low.
**Summary:** 30× `Failed to open limit_sink_enable`; 14× `could not transition HS PHY to L2`. USB
data enumerated (the bugreport was captured over adb); current limiting is unverified because the
sink-current node is absent from the 4.14 charger ABI.
**Fix:** no kit patch; USB AIDL HAL/charger driver. Do not invent a new sysfs ABI just to silence
the log.
- [ ] Measure USB charge current with a meter.
- [ ] Verify USB data and ADB.
- [ ] Treat the log as diagnostic unless charging is actually limited.

## P14 — Battery `ONLINE` log flood and missing firmware
**Status:** partial (battery fixed), device-unverified. **Severity:** low.
**Summary:** 1,375× `batt power supply prop 4 not supported` from `qpnp-smb5.c`; also
`aw8695_rtp.bin`, FTS firmware and `/vendor/bin/chre` are missing; `ro.product.bevice` is a typo.
**Fix:** kernel `3b0be2c65bf6` reports `POWER_SUPPLY_PROP_ONLINE` from battery presence. The
firmware blobs/typo need vendor-tree changes, not this kernel patch.
- [x] SMB5 `ONLINE` commit in the pinned branch.
- [ ] Boot; bugreport must have zero `batt power supply prop 4 not supported`.
- [ ] `dumpsys battery` still shows status/capacity/temperature.
- [ ] Add the missing firmware blobs and fix the vendor prop separately if the features matter.

## P15 — Launcher unread-badge provider missing
**Status:** open; app-side. **Severity:** low.
**Summary:** Instagram logs 34× `Failed to find provider info for
com.motorola.launcher3.unread_badge`; the Motorola launcher provider is not installed.
**Fix:** no ROM patch. The query is from the app; suppress the lookup in the app or accept no
badges.
- [ ] Confirm Instagram badges are the only affected feature.
- [ ] Do not add a fake Motorola provider.

## P16 — GApps feature gaps
**Status:** open; package choice. **Severity:** low.
**Summary:** Missing `subscribedfeeds`, `MDOC_STORE`, AICore, Wear, and Carrier Services/RCS.
**Fix:** no ROM patch; choose a fuller GApps package or accept the gaps.
- [ ] Decide whether Discover/RCS/AICore are release requirements.
- [ ] Test with the chosen GApps package.

## P17 — App-side failures (not ROM defects)
**Status:** open; out of scope. **Severity:** low.
**Summary:** Photos SQLite unique-constraint loop, one retained Chrome ANR, Brave custom-tab
`Permission Denial`, Solid Explorer root probes.
**Fix:** no ROM patch; report to the app vendors.
- [ ] Reproduce each with the latest app version.
- [ ] Only revisit if the same failure is seen with AOSP apps.

## P18 — Binder transactions fail under memory pressure
**Status:** fixed in code (device init), device-unverified. **Severity:** high.
**Summary:** 11× `binder: <pid>_N: page allocation failure: order:0` at 16:21:42 and
16:52:35 (capture E), each followed by `binder: <pid>:<tid> ioctl c0306201 ... returned -14`
(EFAULT, `BINDER_WRITE_READ`): reclaim could not fault in the user page for the binder
copy-to-user (`Normal free: 1516kB` against `min:2012kB`). The same window has
`binder_alloc_buf, no vma`, `DeadObjectException`, a crashed Chrome sandboxed process and,
later, 8 `lmkd` kills. No `page allocation`/`binder_alloc` wording exists in captures A-D.
**Fix:** `patches/device/motorola/amogus.patch` writes `vm.min_free_kbytes=16384` from
`init.amogus.rc` (`on init`). It only raises the kernel watermark; read-ahead,
`nr_requests`, zram and LMK thresholds are untouched, and it is not
`config_extraFreeKbytesAdjust`.
- [x] Knob in the kit patch.
- [ ] Flash and replay the 16:52 load (camera open + Chrome + Maps).
- [ ] KERNEL LOG must have zero `page allocation failure` and zero `returned -14`.
- [ ] LMK kills and screen-off drain must not regress against the 2026-11-23 baseline.

## P19 — Malformed SMS timestamp (month 0)
**Status:** fixed in code (`frameworks/base`), device-unverified. **Severity:** low.
**Summary:** 96 lines at 17:17:12 (capture E): `SmsMessage: Invalid timestamp` →
`java.time.DateTimeException: Invalid value for MonthOfYear (valid values 1 - 12): 0`.
The PDU's SCTS is invalid, so `getSCTimestampMillis()` returned 0 (message dated 1970) and
every parse dumped a stack trace into the radio buffer.
**Fix:** `patches/frameworks/base.patch` makes the parser fall back to
`System.currentTimeMillis()` and log one warning instead of a stack trace. The PDU stays
malformed; only its effect on the message date changes.
- [x] Parser change in the kit patch.
- [ ] Receive SMS from the same sender; `logcat -b radio` must show no stack trace.
- [ ] Message list must show the receive date, not 1970.

---

## Legacy items

### D6 — Key attestation fails (`-10003`)
**Status:** root-caused; workaround proven on hardware. **Severity:** high for Play Integrity.
**Summary:** `android.hardware.keymaster@4.1-service-qti` returns vendor error `-10003` for every
attested key generation (`KeyMasterHalDevice: Attest key send cmd failed` / `resp->status: -10003`),
including the attestation GMS itself requests (`keystore2: Error::Km(-10003) for AppUid(10227)`).
Measured 2026-11-21 on `ZF6522633X` (build 2026-11-20): Play Store reports "Device is not certified",
the Play Integrity API returns `UNEVALUATED` for every field and `deviceIntegrity` carries no
`deviceRecognitionVerdict`, identically with crDroid's PIF config loaded, with it cleared, with the
PIF hook flags off and with the vending spoof off. vvb2060's KeyAttestation reports the same
`-10003` directly, so the missing piece is not a property or a fingerprint.
**Proven workaround:** crDroid 13.1's built-in TrickyStore (Settings > Misc) detects the broken TEE and
generates a chain from a keybox. With a throwaway self-signed keybox imported through
`tools/integrity-setup.sh import`, KeyAttestation showed a complete chain — `CN=Android Keystore Key`
under the keybox root, "Bootloader is locked", Keymaster 4.1, TrustedEnvironment — where it showed
`-10003` before. Play Integrity still fails with that test key because its root is not Google's; a
Google-rooted keybox is what the API evaluates, and it is the only route to a verdict on this phone.
- [x] Confirm keymaster is the gate (KeyAttestation + `keystore2` logs), not PIF, props or registration.
- [x] Prove the built-in TrickyStore generates a chain from a keybox on this device.
- [x] One prompt per build: `KeyboxMonitor.sync` probes attested keygen (cached in Settings.Secure)
      and, with no keybox installed, posts a notification that opens Settings > Misc > TrickyStore.
      It never imports anything on its own; the user picks the file there.
- [ ] Test with a Google-rooted keybox when the user supplies one; the kit never ships or downloads it.
- [ ] If a user has no keybox, Play Integrity stays `UNEVALUATED`; do not weaken the build for it.

### D8 — No Wi-Fi RTT service
**Status:** open; feature missing. **Severity:** low.
**Summary:** `SystemServiceRegistry: No service published for: wifirtt`.
- [ ] Confirm the vendor WiFi HAL lacks RTT; no software patch.

### D9 — IMEI blank in Settings
**Status:** by design on `user` builds. **Severity:** cosmetic.
**Summary:** `ImeiPreference: PrimaryImei not available`; telephony refuses `getDeviceId` without
the privileged permission.
- [ ] Read the IMEI from the box or `fastboot getvar`; do not weaken the build.

---

## Closed

### D2 — Verified-boot state checker
Closed: the kernel command line is `androidboot.verifiedbootstate=orange`; the `green` property is
crDroid's SafetyNet spoof, not a locked bootloader.

---

## Verification limits

No device build/flash was possible in this workspace: no synced Android tree
(`~/android/crdroid-17.0` absent), no `clang`/aarch64 toolchain, and 78 GB free versus ~350 GB
required. All `[x]` marks mean the code/patch is committed; none mean hardware-verified.

## Capture C — 2026-11-20 05:32, build 2026-11-19 (the OTA-installed one)

| | |
|---|---|
| File | `bugreports/bugreport-doha-CP2A.260605.016-2026-11-20-05-32-15.zip` |
| Uptime at capture | 4 min (boot-time picture, not a load test) |
| Build | `ro.build.date.utc=1795129374` (Thu Nov 19 23:02 UTC), slot `_b` |
| SIMs | BSNL + JIO, both `LOADED`, both LTE |
| Boot reason | `reboot,hardware_reset` (user power cycle) |
| Crashes | 0 ANR, 0 FATAL, 0 watchdog kills |

**C1. `dexopt_chroot_setup` aborts on every shutdown/reboot (tombstone).** `Check failed:
!OR_RETURN(IsSelfOrParentSymlink(target)) /mnt/pre_reboot_dexopt/chroot/system_ext/lib`,
SIGABRT, uid 1082, ppid 1. ART's pre-reboot dexopt copies the partition layout into a
chroot and bind-mounts `system_ext/lib`; on this device there are no dynamic partitions,
so `/system_ext` is a symlink into `/system`, and the target is a symlink's child. The
check refuses that and the process aborts. Effect: **pre-reboot dexopt is skipped after
an update and at every reboot**; capture E has three tombstones (05:15, 06:50, 08:51 on
2026-11-20) matching its three shutdown checkpoints, not a one-off and no crash loop.
Deliberately **not** patched: the fix lives in ART's chroot plumbing (`dexopt_chroot_setup.cc`, `BindMount`), where a
symlinked parent has to be resolved before mounting; a blind C++ change to a core
runtime that cannot be compile-tested outside the build is a worse trade than one
skipped dexopt pass. The first-boot `speed-profile` hook below is the compensation and
now re-runs after every OTA (the flag records `ro.build.date.utc`).

**C2. First-boot dexopt hook did not run on this build.** `init.svc.doha-dexopt-once`
empty, `persist.doha.dexopt_status` unset at 4 min uptime. Cause: the service was
`disabled` and started from `on property:sys.boot_completed=1 start ...`. Fixed in
`patches/device/motorola/amogus.patch` (plain `late_start` oneshot, no trigger).

**C3. `/data` still mounted with `discard`.** `mountinfo` pid 1: `...background_gc=on,
discard,no_heap...`. Cause: this kernel's f2fs sets `DISCARD` in `default_options()`;
dropping the fstab option did nothing. Fixed by mount option `nodiscard`.

**C4. Boot-time log spam, harmless.** 358 x `SystemServiceRegistry: Manager wrapper not
available: jobscheduler` and 240 x `AppOpService: Blocked setUidMode call for runtime
permission app op`, all inside the first three seconds from system_server (pid 1809)
during `Permission_syncPackages`. Standard Android boot race, no functional effect.

**C5. Memory at 4 min uptime.** MemAvailable 1006 MB, zram 607 MB in use of 2047 MB,
2 LMK kills (`org.protonaosp.deviceconfig`, oom_score_adj 945). Top PSS: system_server
323 MB, SystemUI 168, GMS 147, Truecaller 116 (42 in swap), Chrome 113, YouTube 107,
WhatsApp 101, Gmail 92, Launcher3 78. Truecaller is the largest non-system consumer —
still the open app-disable decision.

**C7. The phone went dark after the update — kernel panic in the shutdown path.**
`FS/data/misc/recovery/last_kmsg.3` preserves the boot before the current one:
`[1268] EXT4-fs (loopN): errors=remount-ro ... on umount` x38 (APEX unmounts of an
orderly shutdown), then `[1271.039845] sysrq: Terminate All Tasks`, then

    [1276.214144] Kernel panic - not syncing: Subsys notifier chain for modem taking too long
    Call trace: panic -> notif_timeout_handler -> call_timer_fn -> run_timer_softirq
                -> ... -> lpm_cpuidle_enter -> do_idle

So during a clean shutdown the HLOS->modem sysmon step did not finish inside the 20 s
SSR notifier timeout, and the handler **panicked** because the kernel is built with
`CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT=y` (`arch/arm64/configs/vendor/amogus_defconfig`,
next to `CONFIG_SSR_SYSMON_NOTIF_TIMEOUT=20000`). The panic reboot loop stopped at
"Rebooting in 5 seconds.." with the panel dark, so the phone looked switched off; the
current boot then reports `hardware_reset`, i.e. a power-key reset by the owner, not
the panic itself. Live confirmation on the device: `zcat /proc/config.gz` still lists
`CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT=y`.

Which kernel produced it: `710ed46` (in the fork branch, so in the 2026-11-19 build)
always prints `ssr-timeout: comm=... src=... dest=...` before the panic, and the crash log
contains **zero** such lines. Decompressing the kernel out of the shipped
`...-20261119-...-debloat-boot.img` shows the other side: the strings `ssr-timeout`,
`Subsys notifier chain` and `blocked (D) tasks` are all present. So the crash came from the
**2026-11-18 build** (`christiaan/...` @ `03f0501e`), i.e. before the update — the build
that "worked out of the box" carries the same `CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT=y` and the
same panic path, just without the diagnostic dump. The seven commits between the two pins
(qcacld SSR cleanup, the ssr dump, glink/smp2p `IRQF_NO_SUSPEND`, smb5, eeprom, nci) do not
add the panic; the trigger is the vendor config plus a slow modem sysmon handshake with the
hotspot up.

Fix (this branch): the same defconfig line is flipped to
`# CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT is not set` in
`patches/kernel/motorola/msm-4.14.patch`. The timeout then keeps its diagnostic value
(`WARN` + a blocked-task dump in `subsystem_restart.c`) but can no longer turn a slow
modem handshake during shutdown into a black screen. Not the battery: 45% at capture,
3.75 V, health 2, charging on AC.

**C6. Benign noise, explained.** `No package ID 6b found for resource ID 0x6b0b0013` in
naviapp/truecaller/pinterest/photos right before "App measurement initialization"
(Firebase probing a shared resource); `KeyMasterHalDevice: Attest key send cmd failed`
plus Finsky integrity failures (unsigned test-keys); `SoundTriggerMiddlewareImpl: Failed
to add a SoundTriggerModule` (no always-on hotword HAL); `wifirtt` service not published;
`QC2V4l2Driver: queryControl failed for control id 992077` (90 x, camera v4l2);
`RequestContextBuilder: Could not get APN` at boot only, before the modem came up.

## Capture D — 2026-11-20 07:07, build `1795135461` (`crdroid-20261120-2`, slot `_a`)

File: `bugreports/bugreport-doha-CP2A.260605.016-2026-11-20-07-07-57.zip`.

- **Root cause of silent off on lock proved (see P2 above):** `Battery History` shows dozens of
  clean `-running` -> `+running` resumes before the 05:15:50 OTA reboot into kernel `73b7957`
  (`last_kmsg.9` stayed up 22.3 h / 108 wakes), and **zero** resumes after it. All 6 non-reboot
  boots on `73b7957` (`last_kmsg`..`last_kmsg.7`) froze silently inside `dpm_suspend_noirq()` on
  the first deep sleep after locking on battery (`last_kmsg.4` ended at 43.377 s right after
  `Freezing of tasks aborted` ×2; `last_kmsg.5`/`.6` froze right after USB unplug; current boot
  dmesg reports `PMIC@SID0: Power-off reason: Triggered from KPDPWR_N (Long Press)`). Fixed by
  restoring `IRQF_NO_SUSPEND` on `qcom_glink_native` and `smp2p` in
  `patches/kernel/motorola/msm-4.14.patch`.
- **P1 shutdown hang stack captured (`last_kmsg.2`):** `710ed46` dumped `vndbinder:1119_` stuck
  in `icnss_modem_notifier_nb -> hdd_wlan_exit -> umac_stop -> qdf_wait_single_event` while `init`
  blocked in `f2fs_put_super -> f2fs_issue_discard_timeout`. Both mitigations (`nodiscard` and
  `CONFIG_PANIC_ON_SSR_NOTIF_TIMEOUT` off) are now active.
- **Verified live on `1795135461`:** `/data` mounted with `nodiscard`, `SwapTotal 4194300 kB`
  (4 GB zram), `smb5` `prop 4` log spam gone. `doha-dexopt-once` still absent from `init.svc.*`
  (tracked in `docs/TODO.md`).

## P20 — Sound profile returns to "General" (ringing) after reboot
**Status:** open, needs a capture. **Severity:** medium (user-visible, silent alarms/calls risk).
**Summary:** set the phone to **Vibrate**, reboot, and it comes back on **General / ring**. This
tree has no LineageOS System Profiles (`class ProfileManager` is absent from `frameworks/base`),
so the setting involved is the ringer mode, `Settings.Global.MODE_RINGER`
(`0` silent, `1` vibrate, `2` normal) — the Developer-options/Sound-panel "sound profile".
**Where it lives:** `AudioService.systemReady()` reads the stored value with
`AudioManager.RINGER_MODE_NORMAL` as default, so a missing row is indistinguishable from "ring"
(`services/core/java/com/android/server/audio/AudioService.java:3521`); written back at `:3532`
and `:11850` on every change. `DevicePolicyManagerService:743` still lists `MODE_RINGER` as a
deprecated global setting, so a device policy can also drive it.
**Two distinct causes, told apart by how often it happens:**
- *Once, on the first boot after a flash/update:* expected AOSP behaviour — the settings upgrade
  step `v119: Reset zen + ringer mode` (`SettingsProvider.UpgradeController#onUpgradeLocked`)
  writes `MODE_RINGER` back to the default when the settings database comes from version 118.
  Not a defect, but it should not repeat.
- *On every reboot:* the value is not persisting. Either nothing writes it before shutdown, or
  something rewrites it during boot after `AudioService` restores it (policy, vendor audio HAL
  init, or a crash in `AudioService`/`NotificationManagerService`). This is the case to fix with
  a patch; nothing in the current 30 patches touches ringer mode, so it is inherited behaviour.
**Evidence needed (no capture exists yet):**
- [ ] `adb shell settings get global mode_ringer` → reboot → the same command again
  (`1` before and `2` after proves it is being reset, not lost).
- [ ] `adb shell dumpsys audio | grep -i ringer` before and after the reboot.
- [ ] `adb logcat -b all -v time | grep -iE "ringer|AudioService|mode_ringer"` across the reboot.
- [ ] `adb shell settings list global | grep -iE "mode_ringer|zen_mode"` to see whether a
  `zen_mode` write lands on top of it.
- [ ] Confirm it happens with a third-party launcher/notification app out of the picture.

Note: the workspace cannot take this capture itself — `bugreportz` is refused for app uid
(`Failed to connect to dumpstatez service`, no `DUMP` permission), there is no root, and
`adb pair` over Wireless debugging fails with `protocol fault (couldn't read status message)`
when handed the port from the main screen instead of the pairing dialog.

## P21 — Pre-reboot dexopt aborts on every update (4 tombstones)
**Status:** open, needs a decision. **Severity:** medium (first boot after an update recompiles on demand).
**Summary:** all four tombstones in capture F (2026-11-27 14:25) are the same native abort:

```
pid 18604/13866/12896/30619  >>> /apex/com.android.art/bin/dexopt_chroot_setup <<<
signal 6 (SIGABRT), code -1 (SI_QUEUE)
Abort message: 'Check failed: !OR_RETURN(IsSelfOrParentSymlink(target))
                 /mnt/pre_reboot_dexopt/chroot/system_ext/lib'
  #04 dexopt_chroot_setup ... BindMount()
```

`dalvik.vm.enable_pr_dexopt=true` and `pm.dexopt.ab-ota=speed-profile` are set, so system_server
tries to AOT-compile the *new* build before rebooting for an OTA. Each attempt dies in
`art/dexopt_chroot_setup/dexopt_chroot_setup.cc:183/206`, which refuse to bind-mount onto a path
whose parent is a symlink (`IsSelfOrParentSymlink`, `:148`).
**Cause:** this device has no separate `system_ext`/`product` partition — the build emits
`/system_ext -> /system/system_ext` and `/product -> /system/product` (verified on the running
ROM), and the chroot inherits those symlinks from the root mount, so the target
`chroot/system_ext/lib` is a symlink. Pre-reboot dexopt therefore never runs, and the update
pays the compile on first boot instead — the "feels slow after updating" symptom.
**Fix, two options:**
- [ ] ART patch (`patches/art.patch`): resolve a symlinked bind target and mount/umount the
  resolved path (`IsSelfOrParentSymlink` already computes the real path via
  `/proc/self/fd`, it just discards it), so pre-reboot dexopt works on retrofit-partition
  devices.
- [ ] Cheap alternative: `dalvik.vm.enable_pr_dexopt=false` in the device properties — no more
  tombstones, but no pre-reboot compilation either (current effective behaviour).
- [ ] Verify either way: after an OTA, `pm bg-dexopt-job` is not needed and first boot does not
  sit in `dex2oat`; no new tombstone in `/data/tombstones` after an update.

## P22 — `persist.debug.wfd.enable` rejected: Wi-Fi Display flag never applied
**Status:** open, code-fix identified. **Severity:** low/medium (casting).
**Summary:** capture F, boot 2.129 s: `init: Do not have permissions to set
'persist.debug.wfd.enable' to '1' in property file '/vendor/build_doha.prop': SELinux permission
check failed (source_context=u:r:vendor_init ...)`. The Motorola vendor prop file sets it, but
`vendor_init` may not write a `system_prop`-labelled property, so the flag stays off and Wi-Fi
Display support is decided without it.
**Fix:** set it from the system side instead — `PRODUCT_PROPERTY_OVERRIDES +=
persist.debug.wfd.enable=1` in `patches/device/motorola/amogus_doha.patch` (or `targets.patch`),
which writes `/system/build.prop` as `init`.
- [ ] After flashing: `getprop persist.debug.wfd.enable` is `1`, and the boot log has no
  "Do not have permissions to set 'persist.debug.wfd.enable'".
- [ ] Enable "Wireless display" in Cast/Screen cast; the device advertises over Wi-Fi Display.

## P23 — Vendor prop typo `ro.product.bevice`
**Status:** open, cosmetic. **Severity:** none (log noise only).
**Summary:** same vendor prop file sets `ro.product.bevice` (missing `d`), which SELinux also
rejects. It never had an effect; the property that matters, `ro.product.device`, comes from the
device tree.
**Fix:** drop or correct the line where the vendor props are generated; no behaviour change.
