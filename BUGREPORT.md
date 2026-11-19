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

## Status at a glance

| Status | Entries | Individual issues |
|---|---|---|
| Fixed in code, device-unverified | 3 (P1, P3, D5) | 5 |
| Partially fixed | 3 (P2, P10, P14) | 3 entries, several sub-items open |
| Mitigation only | 3 (P6, P8, P9) | 3 |
| Likely fixed upstream, unverified | 1 (P4) | 1 |
| Open | 11 (P5/P7/P11/P12/P13/P15/P16/P17, D6, D8, D9) | 35 |
| **Tracked total** | **21** | **44** |

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
`710ed46` (dump stuck task before panic). Both are in the pinned branch `doha-kernel-fixes-2026-11-19`
at `73b7957`.
- [x] Kernel commits present in the build pin.
- [ ] Rebuild with a syncing `./build.sh`; no `SKIP_SYNC=1`.
- [ ] Reboot 5× and reproduce hotspot/WLAN-SSR; `dmesg` must not contain
  `Subsys notifier chain for modem taking too long`.
- [ ] If it still panics, attach the new stack dump from `710ed46`.

## P2 — Suspend ineffective; glink/smp2p wake IRQs misconfigured
**Status:** partial (kernel flags fixed), device-unverified. **Severity:** high.
**Summary:** Nearly every suspend attempt resumed on `misconfigured IRQ 20 glink-native`; pending
sources also include `NETLINK`, `SensorsHAL_WAKEUP`, `smp2p-sleepstate`, and IPA.
**Fix:** kernel `a8b9cfcea310` (glink) and `0c55710bfa99` (smp2p) drop `IRQF_NO_SUSPEND` from IRQs
that use `enable_irq_wake()`. `NETLINK`/sensor wakeups are userspace.
- [x] Both kernel commits in the pinned branch.
- [ ] Screen off on battery 10 min; bugreport must have zero
  `misconfigured IRQ 20 glink-native`.
- [ ] Compare `PM: suspend entry`/`Some devices failed to suspend` with capture B (202/20).
- [ ] Incoming call while suspended must wake and ring; if not, revert P2 commits and report.

## P3 — Launcher3 crash loading a stale themed-icon resource
**Status:** fixed in code (kit patch), device-unverified. **Severity:** high.
**Summary:** Launcher3 died with `Resources$NotFoundException` in
`IconProvider$ThemeData.loadPaddedDrawable()` after a package update invalidated a themed-icon
resource; `KillApplicationHandler` restarted the workspace.
**Fix:** `patches/frameworks/libs/systemui.patch` catches `Resources.NotFoundException` and returns
`null`, so the caller falls back to the default icon.
- [x] Patch applies to `frameworks/libs/systemui` branch `17.0`.
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

---

## Legacy items

### D6 — Key attestation fails (`-10003`)
**Status:** open; unfixable ROM-side. **Severity:** high for Play Integrity.
**Summary:** Keymaster has no attestation key; attested-key requests fail, so Play Integrity labels
cannot be met on an unlocked self-signed build.
- [ ] Treat Play Integrity as unsupported; do not add keybox spoofing.

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
