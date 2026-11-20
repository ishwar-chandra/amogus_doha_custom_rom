# Open issues

Working list for the amogus_doha builds. The README is the released
documentation; this file is the scratchpad behind it. Line and evidence
references are from the hardware session on 2026-11-16 (device
ZF6522633X, XT2019-1, build `24.0-20261113-UNOFFICIAL-amogus_doha`,
kernel `4.14.357-openela+ #16`).

## Open, being investigated


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

`tools/gcp-build.sh` does the whole cycle. Project `customrom-514215`
(asia-south1), 12 vCPU / 48 GB (`n2-custom-12-49152`) with a 50 GB boot disk
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
machine going to sleep does not touch it; `att` attaches, `logs` follows the
log, `state` says whether it is still running and what it exited with.
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

There is no Drive/GCS/rclone backup and no restore step. The VM is
disposable: `.repo`, ccache and `out/` do not survive deletion. A later
build re-syncs and rebuilds; `finish` is what preserves the release and OTA
feed.

Build variant: `build.sh` builds **userdebug** by default (override with
`VARIANT=user`), which is what the debugging here needs — `adb root`,
dmesg and `/sys/fs/pstore` only work when `ro.debuggable=1`. Worth
knowing: the v2.0.0/v2.0.1 zips on GitHub were `user` builds
(`ro.build.type=user` on the phone), which is why the panic log could not
be read from the device. Keep userdebug for test builds; decide
separately whether a public crDroid release should be `user`.

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

- [ ] **The release is a `user` build, not `userdebug`.**
  `ro.build.type=user`, `ro.debuggable=0`, so `adb root`, `dmesg`,
  `/sys/fs/pstore` and most of `/sys/class/power_supply` are denied to
  shell. `build.sh` builds userdebug, so this image came from a plain
  `brunch`. A userdebug build would let panics be read live instead of
  from recovery.
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
- [ ] Play Integrity / D6: blocked on hardware attestation (`Km(-10003)`, 68 hits from Google Pay in
  one report). Analysis in `BUGREPORT.md` §7 (D6); the decisive test needs `KeyAttestation` (vvb2060)
  installed on the phone — `-10003` there means the TEE has no attestation key and nothing ROM-side can
  fix it, a valid chain with `deviceLocked=false` would mean only `MEETS_DEVICE_INTEGRITY` is lost and
  `MEETS_BASIC_INTEGRITY` is reachable.

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
- [ ] `doha-dexopt-once` still did not start on build `1795135461` (`nodiscard` and
  4 GB zram are verified live in `bugreport-...-07-07-57.zip`): a `/vendor/etc/init`
  service running `/system/bin/sh` without a `seclabel`/domain transition is rejected
  by init, and Treble neverallows forbid vendor domains from calling `system_server`'s
  `package` binder service. Either remove the dead vendor service (rely on
  `tools/dexopt-all.sh`) or move it to `system_ext`/`product` init.
- [ ] Verify `tools/gms-trim.sh` on the next flash: does `pm disable` of a GMS
  component succeed while `ro.debuggable=0` (shell is uid 2000)? The tool prints
  `denied` per component and exits non-zero if the platform refuses, so a failure
  is visible, not silent. If it is refused, the same list needs root or a
  DEV_ROOT test build.
- [ ] Measure the cherry-picked tools: `tools/perf-multitask.sh` before/after
  `tools/gms-trim.sh` (default groups) so the owner's impression has numbers
  behind it, and `tools/dexopt-all.sh` timed right after a flash.

- [ ] `AGENTS.md`'s patch-map row for this patch still needs the owner's approval
  to write (the file is protected).
