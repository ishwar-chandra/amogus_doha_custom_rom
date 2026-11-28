# Open issues

Working list for the amogus_doha builds. The README is the released
documentation; this file is the scratchpad behind it. Line and evidence
references are from the hardware session on 2026-11-16 (device
ZF6522633X, XT2019-1, build `24.0-20261113-UNOFFICIAL-amogus_doha`,
kernel `4.14.357-openela+ #16`).

## Open, being investigated


- [ ] **Binder allocation failure fix is device-untested.** After the next flash,
  replay the 2026-11-26 16:52 load (camera + Chrome + Maps) and take a bugreport:
  `KERNEL LOG` must contain zero `binder: ... page allocation failure` and zero
  `ioctl c0306201 ... returned -14`; `am_kill`/`lowmemorykiller` counts and
  screen-off drain must not regress against the 2026-11-23 baseline.
- [ ] **SMS SCTS fallback is device-untested.** Receive SMS from the sender that
  produced month 0 on 2026-11-26; `logcat -b radio` must show one warning, not a
  `DateTimeException` stack, and the message must carry its receive date instead
  of 1970.
- [ ] **Widevine L1 packaging is device-untested.** After the next flash,
  `tools/device-check.sh --verbose` must find `/vendor/lib64/liboemcrypto.so`,
  `logcat -b all` must not repeat `Could not load liboemcrypto.so. Falling back
  to L3`, and a DRM-info app must report L1 before this is called fixed.
- [ ] **Glink suspend wake fix is device-untested.** After the next flash,
  `logcat -b all` must not repeat `Resume caused by misconfigured IRQ 20
  glink-native`; compare `SuspendControl.TotalSuspendDelay` and
  `FailedSuspendDelay` plus screen-off mAh/h against the 2026-11-23 baseline
  (2,564 attempts, 675 failures, 46.2 mAh/h).
- [ ] **Doze motion disable is device-untested.** Confirm
  `dumpsys deviceidle` reports `mUseMotionSensor=false`, `AnyMotionDetector`
  stops holding wakelocks after screen-off, and normal wake methods still
  work. The overlay intentionally stops movement from resetting the idle
  transition.
- [ ] **TrickyStore target migration is device-untested.** After import,
  `settings get secure spoof_trickystore_target` must contain
  `com.google.android.gms` with no literal `null`, and disabling keybox alerts
  must remove a pending prompt. A real Play verdict still requires a
  Google-rooted keybox supplied by the user.
- [ ] **VoLTE / IMS.** Evidence from the device:
  - the IMS PDN connects, then drops and rebuilds every 5–11 minutes
    (17 transitions in one window, e.g. 20:14 → 20:41 on 11-15), and
    `ImsStats` discards the sessions as "transient" (48 s, 76 s);
  - carrier config for both subscriptions says
    `carrier_volte_available_bool = true`, so the framework is not
    refusing it;
  - no `domain=IMS` registration info appears in the radio or system
    log buffers at all.
  Looks like the modem never completes IMS registration, i.e. the
  carrier-profile layer the README already flags, not something to patch
  in the framework. Jio is VoLTE-only, so its SIM gets no calls when
  this happens.
  Next: clear the three `persist.dbg.*_ovr` properties below, reboot,
  capture `logcat -b radio` across an IMS drop, and compare the modem's
  chosen MCFG profile with stock.
- [ ] **`persist.dbg.*_ovr` set on the device.** `volte_avail_ovr`,
  `vt_avail_ovr` and `wfc_avail_ovr` are all `1`. They are not in this
  repo, so they were set by hand (resetprop/Magisk) and they make the UI
  advertise IMS features that may not exist. Clear them before any
  further VoLTE testing.
- [ ] **Charging slowly compared to stock.** Measured so far, on a PC
  USB port: `USB powered: true`, `Max charging current: 500000` (USB 2.0
  SDP), current flipping between +215 mA (screen off) and −114 mA (adb
  active), `charge_type=Fast`, `constant_charge_current_max=3600000`.
  Not conclusive: needs a wall-charger measurement. Ask for
  `dumpsys battery | grep -E "AC powered|USB powered|Max charging
  current"` and `dumpsys thermalservice` on AC. If it reports
  `USB powered: true` and 500 mA on a wall charger, the charger is
  misdetected as SDP — a real bug, and plausible given the move to
  `sysfs_typec`. Watch skin temperature too: `SKIN_THROTTLE_C=40` makes
  the HAL report throttling from 40 °C, and kernel thermal mitigation
  cuts charge current when the skin warms up.
- [ ] **SMS/OTP delivery delayed.** Likely the same IMS instability: on
  LTE, SMS delivery over IMS is delayed while IMS flaps. Test by forcing
  the SIM to 2G/3G-preferred and checking whether SMS lands promptly.
- [ ] **Sensors untested.** All ten vendor modules load correctly
  (`aw8624`, `aw8695`, `ets_fps_mmi`, both `focaltech` touch,
  `nova_0flash_mmi`, `qpnp_smbcharger_mmi`, `stmvl53l1`, `sx933x_sar`,
  `wlan`), so proximity/SAR/ToF should work. Exercise proximity during a
  call and check `dumpsys sensorservice`.

## Answered, no code change

- **USB tethering does not charge the phone.** On a PC port the phone is
  capped at 500 mA (SDP) while tethering plus radios draw more, so the
  current goes negative and the battery stays flat. Any ROM behaves the
  same on that port. Worth a README note so it is not reported as a bug.
- **Hotspot / network throttling.** No ROM-side throttling found:
  `data_saver_mode` unset (off), `restrict-background: false`, no
  restrict-power, the only network policy is a 2 GiB warning with no
  limit, and `net.tethering.noprovisioning=true` disables the carrier
  entitlement check. Remaining limits are upstream LTE quality, the AP's
  band (2.4 GHz by default), and carrier-side tethering policy.
  Optional follow-up: measure the AP band and throughput with the
  hotspot on.
- **GPS "not working".** Location Services was simply off
  (`location_mode = 0`) and `assisted_gps_enabled = 0`; the
  "use assisted GPS" toggle is vestigial on Android 17. The workaround
  people found (`pm grant com.google.android.gms ACCESS_FINE/COARSE_
  LOCATION`, then `settings delete global assisted_gps_enabled`) resets
  a first-boot GMS permission state. Candidate for a README
  troubleshooting entry.

## GCP build machine

`tools/gcp-build.sh` does the whole cycle. The project comes from
`gcloud config` (`customrom-514215` here) and the running VM is discovered,
preferring `labels.doha-build=1`; `NAME`/`ZONE` select one when two are
active. The 12 vCPU / 48 GB (`n2-custom-12-49152`) shape has a 50 GB boot disk
and two 375 GB local NVMe devices: the first holds the tree and `out/`, the
second holds ccache and swap. `SSD_COUNT=0` switches to a single boot disk;
`DISK_MODE=pd` uses a separate data disk instead. Quota preferences
for 64 vCPU, spot CPUs and 500 GB SSD are submitted and still show `granted`
= the old values; the 12 vCPU shape works without them, so the build does not
wait.

Workflow:

```sh
export GH_TOKEN=...                  # token with Contents write on the ROM
                                     # and doha-ota repos
tools/gcp-build.sh create
tools/gcp-build.sh setup
tools/gcp-build.sh build             # starts the build in tmux on the VM
tools/gcp-build.sh logs [--full]     # formatted tail / raw log from byte 0
AUTO_FINISH=1 tools/gcp-build.sh build  # wait, release, update OTA, delete
tools/gcp-build.sh finish            # or wait on an already-started build
```

For both variants on one VM:

```sh
tools/gcp-build-both.sh             # standard, release, then debloat, release
```

The wrapper builds sequentially on `n2-custom-12-49152`; the first `finish`
uses `NO_DELETE=1`, the second deletes the VM. Both use the same `TAG` and
update only their own OTA channel.

`build` runs inside tmux on the VM, so a dropped SSH connection or this
machine going to sleep does not touch it; `att` attaches, `logs [--full]`
shows the formatted tail or the raw log, `state` says whether it is still
running and what it exited with.
Nothing is deleted on a timeout during a build: the only automatic deletion
is the `HOURS` hard stop (default 48, `HOURS=0` disables it), and `finish`
normally ends a session: wait for the build, verify the zip and images
against their `.sha256sum`, publish the release, update the matching
standard/debloat OTA feed, then delete the VM. A failed build leaves the VM
alone so the log can be read.

The release is published from the VM, where the zip already is, so only the
token crosses over (written to a file, removed after the upload); `gh` is
installed there, and the local machine needs nothing but this script.
`NO_RELEASE=1`, `NO_OTA=1` and `NO_DELETE=1` skip those steps.

The build/release chain does not use Drive; `tools/drive-backup.sh` is an
optional separate backup/restore (GUIDE §4.5). The VM is
disposable: `.repo`, ccache and `out/` do not survive deletion. A later
build re-syncs and rebuilds; `finish` is what preserves the release and OTA
feed.

Build variant: `build.sh` defaults to **userdebug**; crDroid sets
`PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG`, so both `userdebug` and `user` report
`ro.build.type=user` and `ro.debuggable=0`. There is no `adb root`, shell
`dmesg`, or live pstore; read `/sys/fs/pstore` from recovery. The
v2.0.0/v2.0.1 zips were `user` builds, but userdebug does not change the
props. Keep userdebug for the build label only; decide separately whether a
public crDroid release should be `user`.

Caveats worth remembering:

- The boot disk is deleted with the VM (`--boot-disk-auto-delete`); a stop/start
  keeps it. Nothing on the VM is part of the release except what `finish`
  uploads.
- `create` sets `--max-run-duration=48h` with `instance-termination-action=
  DELETE`, so a forgotten VM removes itself instead of billing overnight.
- Google always spends credits before the card, but there is no hard spend
  cap: check Console → Billing → Credits before a session, and `delete`
  the VM when done.

## Build and tooling

- [x] **Both variants report user.** crDroid sets
  `PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG`; `userdebug` and `user` both report
  `ro.build.type=user`/`ro.debuggable=0`, so `adb root`, shell `dmesg` and
  live pstore are unavailable. Read pstore from recovery. (The v2.0.0/v2.0.1
  images were plain `brunch` builds, but userdebug would not restore debug.)
- [x] **GCP VM discovery and formatted logs.** `tools/gcp-build.sh` reads the
  project from gcloud, discovers the instance, and `logs [--full]` formats the
  tail (color, wrapping, dedupe) or prints the raw log.
- Note: PSTORE is compiled in (`CONFIG_PSTORE_CONSOLE/RAM/PMSG`,
  `CONFIG_IKCONFIG_PROC=y`), so kernel panics *are* captured. Read them
  from recovery, which runs as root:
  `adb shell cat /sys/fs/pstore/console-ramoops-0` (and
  `pmsg-ramoops-0` for the last userspace messages).
- [ ] **Pin the crDroid manifest once a build boots** (`repo manifest
  -r -o default.xml`), per the README.

## Variants and OTA (2026-11-17)

- [ ] Create `doha-ota` with `standard/doha.json` and `debloat/doha.json`; add
  `tools/gcp-build.sh ota` to publish build.prop-verified entries.
- [ ] One-click OTA end-to-end: Settings → System update → install → reboot → slot switch.
- [ ] GApps on the standard build: Play Store + GMS work (GMS self-updated to 26.45.31);
  roles stay crDroid's until a Google app set is flashed; `AdvancedProtection` is absent
  from the Safety Center config (see BUGREPORT §6).

## From the 18:29 bugreport (build 09:06)

- [ ] D5 sepolicy: the `system_suspend` -> `sysfs_batteryinfo` rule lives in
  `patches/system/sepolicy.patch` (`system_suspend` is private, so the vendor policy cannot name it);
  `patches/device/lineage/sepolicy.patch` keeps the `hal_power_default` cgroup rule. Verify both on the
  next bugreport.
- [ ] D4 GMS `Unexpected safety source: AdvancedProtection`: platform/GApps mismatch, not ours.
  Re-check after the next NikGapps bump before spending time on a `frameworks/base` enum patch.
- [ ] Play Integrity / D6: root-caused. The vendor keymaster refuses attestation (`Km(-10003)`),
  so the API returns `UNEVALUATED` no matter what PIF does; crDroid's built-in TrickyStore pulls a
  chain from a keybox and was proven on hardware with a test key (`BUGREPORT.md` §7, D6).
  Remaining: a real keybox test when the user has one. `tools/integrity-setup.sh` imports it;
  the kit never ships one.

## Performance tuning (2026-11-20, tree + bugreport audit)

Plan of record: `OPTIMIZATION.md` (baseline numbers, phases, success criteria,
rollback). The notes below are the source facts behind it.

Read from the pinned trees and `bugreports/bugreport-doha-...-2026-11-18-23-13-33.zip`;
nothing here is benchmarked. `tools/perf-audit.sh` is the gate — exit status is
the number of knobs the phone is not actually running.

- [x] **zram was 1 GB and full.** Bugreport: `MemTotal 3685120 kB`,
  `SwapTotal 1048572 kB`, `SwapFree 2868 kB` (99.7% used), 133 LMK kills in that
  capture. `fstab.qcom` now sets `zramsize=4294967296`; the post_boot 50%-of-RAM
  resize can never apply (`swapon_all` in `init.target.rc` `on fs` initialises
  zram first, and `zram_drv.c` refuses a new `disksize` once `init_done`).
  Gate: `perf-audit.sh` reports `SwapTotal ~2047 MB` and LMK kills drop under
  the same GApps workload.
- [x] **read-ahead had three writers and the wrong one won.**
  `init.aospa.perf.common.rc` re-applies its value on `vendor.post_boot.parsed=1`,
  which `init.qcom.post_boot.legacy.sh` sets on its last line — after
  `init.amogus.rc`'s `sys.boot_completed` writes. The branch's 4096 KB never
  reached the kernel. Value now lives only in
  `patches/device/qcom/common.patch`, rendered from `READAHEAD_KB` (default 128).
  Gate: `perf-audit.sh` read_ahead PASS for `mmcblk0` and every `dm-*`.
- [x] **`nr_requests` 256 → 128** (kernel default; eMMC + CFQ gains nothing from
  a deeper queue and nothing measured justified 256).
- [ ] **Verify the boot-time scheduler margins were applied.** The kernel's
  `sched_updown_migrate_handler` dropped every write in the first 120 s, so the
  trinket block's `sched_downmigrate` 67 / `sched_upmigrate` 77 never reached the
  scheduler. The gate is removed in `patches/kernel/motorola/msm-4.14.patch`;
  after a flash, `adb shell cat /proc/sys/kernel/sched_upmigrate` must read 77
  (default 70) and `sched_downmigrate` 67 (default 65). Device-untested.
- [ ] **Governor not verified on device.** `post_boot.legacy.sh` selects
  `schedutil` only for trinket `soc_id` 394/467/468 with
  `hispeed_freq` 1305600/1401600 and `hispeed_load` 85. If the phone boots on
  `performance` instead (the defconfig default), every core runs at max and the
  thermal throttling in BUGREPORT makes sense. Check with `perf-audit.sh` cpu.
- [ ] **First A/B if LMK still kills too eagerly:** `config_extraFreeKbytesAdjust`
  131072 → 65536 in `device/motorola/amogus`'s framework overlay (one variable
  per build, same workload).
- [ ] **Second A/B:** `READAHEAD_KB=512` (and back to 128) with the app-launch /
  scroll / install timings from the README verification list.
- [ ] **Do not tune:** `walt`, `core_ctl`, `bfq` writes in the vendor scripts are
  dead — `CONFIG_SCHED_WALT`, `CONFIG_SCHED_CORE_CTL`, `CONFIG_IOSCHED_BFQ` are
  off in `arch/arm64/configs/vendor/amogus_doha_defconfig`. KSM and THP are off
  too. `SKIN_THROTTLE_C` stays at 40 until thermal headroom is measured.

## Dolby Atmos (2026-11-27)

- [x] Carry the stock 10 DMS HIDL 1.0 service, `libswdap`, `dax-default.xml`,
  Moto Audio and `daxService` under `device/motorola/amogus_doha/dolby`.
- [x] 2026-11-28: that stack cannot work under Android 17 - every DAP
  parameter returns EINVAL inside the 2019 effect and Moto Audio crashes
  reading `dolbyprovider`. Replaced with the `vendor/motorola-dolby` DAX3
  3.6 stack (DaxUI + `daxService`, dms@2.0 HAL, DAP effect), re-signed with
  the platform key; the `frameworks/base` protection-level override and its
  privapp allowlist are removed with it. Checked on device 2026-11-28
  (`1795817209`): DaxUI renders the presets and the HAL commits its DAP
  parameters; `dumpsys media.audio_flinger` now times out in the effect dump,
  so use `dumpsys media.audio_policy` for the effect state.
- [x] Register the `dap` effect in the audio HAL's trinket `audio_effects.xml`
  (`vendor/qcom/opensource/audio/sm8150/configs/trinket`, which becomes
  `/vendor/etc/audio_effects.xml`; the `device/motorola/common` rootdir copy is
  only a fallback). Add the HAL to `DEVICE_MANIFEST_FILE` and the device
  framework compatibility matrix; add the `hal_dms` domain.
- [x] Runtime fixes from the 2026-11-27 20:21 bugreport: daxService's
  `INTERACT_ACROSS_USERS_FULL` privapp grant, `hidl_base_hwservice` add for the
  DMS HAL, `priv_app_36`/`hal_audio_default` DMS clients, and the
  `DolbyManagerService` service_contexts + post-fs-data `/data/vendor/dolby`.
- [x] Filter `AudioFX` from `PRODUCT_PACKAGES`
  (`patches/device/motorola/targets.patch:68-70`); `build.sh` runs one
  `mka installclean` when the stale APK is still staged, so the image is clean
  while later builds stay incremental. The system/vendor partitions are fixed;
  this frees blocks inside them, not partition size.
- [x] Prebuilt APKs are `BUILD_PREBUILT` (`PRESIGNED`, `daxService` privileged);
  Android 17 rejects APKs in `PRODUCT_COPY_FILES`.
- [x] Android 17 permission: `INTERACT_ACROSS_USERS_FULL` is
  `signature|installer|module|role`; add `privileged` in
  `patches/frameworks/base.patch` so the privapp whitelist grants it without
  re-signing the stock app.
- [x] Explicit `hal_dms_hwservice`/`hal_dms` SELinux rules for
  `priv_app_36`/`hal_audio_default`; the `hal_client_domain` macro did not
  cover the versioned domains.
- [ ] Device-test: Moto Audio opens; `dumpsys media.audio_flinger | grep -i -A2 dap`
  lists the effect; `pm list packages | grep -i audiofx` is empty; test
  speaker and headphones.

## Bugreport follow-ups (2026-11-27)

- [x] `art`: pre-reboot dexopt aborted on the symlinked `system_ext`/`product`
  layout (`patches/art.patch`); five tombstones in the archive.
- [x] `frameworks/av`: ignore `INVALID_OPERATION` (-ENOSYS) from the optional
  frozen-state callback in `AudioFlinger`/`AAudioClientTracker`.
- [ ] Vendor-only, no source in the manifest: `xtra-daemon` SIGSEGV,
  `gatekeeper@1.0`/`keymaster@4.1` SIGABRT at `QSEECom_shutdown_app`; the
  daemons restart. Not patched.
- [ ] `moto_ext_telephony.registry` needs the stock Moto framework; the
  `moto-telephony.jar` alone does not register it. `vendor_qtelephony` logs the
  miss and continues.
- [ ] Google service-missing (no GApps), `keystore2` attestation (vendor
  keymaster; TrickyStore + user keybox), Wi-Fi/BT coex (vendor supplicant lacks
  `setBtCoexistenceMode`), Passpoint/DHCP logs: expected.

## Debloat leftovers (2026-11-20)

- [x] **Settings kept entries for apps the debloat build removes.** crDroid
  Settings' preference XML is shared by both variants, so "Gaming mode"
  (`io.chaldeaprjkt.gamespace`) and "Sidebar" (`com.libremobileos.sidebar`) stayed
  visible and did nothing — both packages are absent on the installed debloat
  build, verified with `pm path`. `packages/apps/crDroidSettings.patch` adds
  `PreferenceAvailability.hideEntriesForMissingPackages()`, called from
  `Miscellaneous` and `LockScreen`, which hides any preference whose embedded
  intent names an uninstalled package plus any category that ends up empty.
  OmniJaws is still shipped, so the weather entry correctly stays.
- [ ] Verify on the next debloat build: Miscellaneous has no Gaming mode, Sidebar
  is gone, and the weather/OmniJaws entry is still there.
- [ ] Known limitation: Settings search indexes the XML at build time, so a hidden
  entry can still appear in search results; tapping it does nothing.
- [ ] Verify the suspend-deadlock fix (P2 revert: `IRQF_NO_SUSPEND` restored on
  `qcom_glink_native` and `smp2p`): unplug USB, lock with the Power button for 5 min,
  confirm the screen wakes normally without needing a long-press reset (`KPDPWR_N` /
  `hardware_reset`), and confirm `Battery History` records `-running` -> `+running`.
- [ ] Verify the shutdown-panic fix on the next flash: `adb shell zcat /proc/config.gz
  | grep PANIC_ON_SSR` must show it unset, and a reboot must no longer leave the
  screen dark with `Kernel panic - not syncing: Subsys notifier chain for modem taking
  too long` in the next boot's `last_kmsg`.
- [x] Remove `doha-dexopt-once` instead of moving it to another partition. It never
  started on build `1795135461` (`nodiscard` and 4 GB zram are verified live in
  `bugreport-...-07-07-57.zip`): the vendor init service had no usable domain/sepolicy,
  and Treble neverallows forbid its intended `system_server` `package` calls. The
  script and service are removed; use `tools/dexopt-all.sh -m speed-profile --wait`
  after installing apps.
- [ ] Verify `tools/gms-trim.sh` on the next flash: does `pm disable` of a GMS
  component succeed while `ro.debuggable=0` (shell is uid 2000)? The tool prints
  `denied` per component and exits non-zero if the platform refuses, so a failure
  is visible, not silent. If it is refused, the same list needs root or a
  DEV_ROOT test build.
- [ ] Measure the cherry-picked tools: `tools/perf-multitask.sh` before/after
  `tools/gms-trim.sh` (default groups) so the owner's impression has numbers
  behind it, and `tools/dexopt-all.sh` timed right after a flash.

- [x] `AGENTS.md`'s patch-map row for this patch is written; the patch map includes
  the debloat gating and the Dolby/audio changes.
