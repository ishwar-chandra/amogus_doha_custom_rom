# Open issues

Working list for the amogus_doha builds. The README is the released
documentation; this file is the scratchpad behind it. Line and evidence
references are from the hardware session on 2026-11-16 (device
ZF6522633X, XT2019-1, build `24.0-20261113-UNOFFICIAL-amogus_doha`,
kernel `4.14.357-openela+ #16`).

## Fixed, needs a release

- [x] **Random reboots while idle.** With double tap to wake on (the
  default), the FocalTech and Himax touch drivers kept their IRQ enabled
  in gesture mode and read touch data over SPI while the controller was
  suspending, ending in a hardware reset. Reproduced by tapping the
  screen with it off and on battery.
  Fixed by kernel `03f0501e6470` ("input: touchscreen: keep the IRQ
  thread off SPI during system suspend"), a direct child of the commit
  both branches pinned. `lineage-24.0` had it as v2.0.1; this branch now
  pins it too. **Still to do: rebuild crDroid so it carries the fix, and
  sideload v2.0.1 on the test phone.**

## Open, being investigated

- [ ] **Double tap to wake does nothing on FocalTech (Tianma) panels.**
  The setting exists and defaults to on, but a double tap does not wake
  the screen. The touch-suspend fix above stops the reboot, not this.
  Upstream is investigating (doha_android#76).
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

## GCP build machine and Drive backup

`tools/gcp-build.sh` does the whole cycle. Project `customrom-514215`
(asia-south1), 12 vCPU / 96 GB (`n2-custom-12-98304`) with a 500 GB boot
disk for the sources and a 375 GB local SSD for `out/`, ccache and swap.
Quota preferences for 64 vCPU, spot CPUs and 500 GB SSD are submitted and
still show `granted` = the old values; the 12 vCPU shape works without
them, so the build does not wait.

Workflow, first time:

```sh
rclone config                        # once, on your own machine: new remote,
                                     # type drive, named gdrive
export GH_TOKEN=...                  # a token with repo scope, for the release
tools/gcp-build.sh create
tools/gcp-build.sh config            # copies rclone.conf to the VM
tools/gcp-build.sh setup
tools/gcp-build.sh build             # starts the build in tmux on the VM
tools/gcp-build.sh finish            # wait, verify, back up, release, delete
```

`build` runs inside tmux on the VM, so a dropped SSH connection or this
machine going to sleep does not touch it; `att` attaches, `logs` follows
the log, `state` says whether it is still running and what it exited with.
Nothing is deleted on a timeout during a build: the only automatic
deletion is the `HOURS` hard stop (default 24, `HOURS=0` disables it), and
`finish` is what normally ends a session, in this order — wait for the
build, verify the zip and images against their `.sha256sum`, mirror
`.repo`/ccache/zips to Drive, publish the release, then delete the VM. A
failed build leaves the VM alone so the log can be read.

The release is published from the VM, where the zip already is, so only
the token crosses over (written to a file, removed after the upload); `gh`
is installed there, and the local machine needs nothing but this script.
`NO_RELEASE=1` and `NO_DELETE=1` skip those steps.

On a later VM: `create`, `config`, `restore`, `build`, `finish`. The
restore puts `.repo` and ccache back, and `build` runs `repo init`/`repo
sync` against those local objects, so the worktrees come back without
downloading anything, and the warm ccache makes the rebuild minutes rather
than hours.

Build variant: `build.sh` builds **userdebug** by default (override with
`VARIANT=user`), which is what the debugging here needs — `adb root`,
dmesg and `/sys/fs/pstore` only work when `ro.debuggable=1`. Worth
knowing: the v2.0.0/v2.0.1 zips on GitHub were `user` builds
(`ro.build.type=user` on the phone), which is why the panic log could not
be read from the device. Keep userdebug for test builds; decide
separately whether a public crDroid release should be `user`.

What is backed up, and why only that:

- `src/.repo` — bare git objects for all ~1280 projects, ~180 GB.
  Immutable once fetched, so rclone uploads only new objects. Restoring
  this and letting `repo sync` re-create the worktrees also sidesteps the
  fact that Drive stores neither file modes nor symlinks: a copied-out
  worktree would restore into something that cannot build.
- `ccache` — content-addressed, so also incremental.
- `manifest` (this recipe clone) and `zips` (finished builds).

`out/` is not backed up: ~120 GB of regenerable intermediates.

Caveats worth remembering:

- `backup` mirrors, so locally deleted files are deleted on Drive too.
- Drive allows ~750 GB of uploads per account per day; the first backup is
  the big one (~230 GB), later ones are small.
- Egress from GCP is billed (~180 GB out of asia-south1 is a few dollars),
  so the first backup is also the only expensive transfer.
- The local SSD does not survive a stop/start; the boot disk does.
- `create` sets `--max-run-duration=8h` with `instance-termination-action=
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

- [x] `DEBLOAT=1` switch in `build.sh` (renders `@DEBLOAT@` / `@UPDATER_CHANNEL@`,
  artifact suffix `-debloat`), documented in README/GUIDE/AGENTS/CLAUDE.
- [ ] Verify the Launcher3 fix on the next flash: no `Resources$NotFoundException`
  (`widget_internal_focus_bg`) and no launcher restart loop.
- [ ] `patches/vendor/lineage.patch`: gate GameSpace, LMOFreeform(+Sidebar),
  BatteryStatsViewer, MatLog, Twelve, Recorder, Glimpse behind `DEBLOAT_BUILD`.
  Keep Jelly (browser), Etar (calendar app), ExactCalculator and every role holder
  (Dialer, messaging, Contacts) in both variants.
- [ ] `patches/packages/apps/Updater.patch`: endpoint → `doha-ota/<channel>/doha.json`
  and a `filterUpdates` guard on `update.name` so a build only accepts its own channel.
- [ ] Create `doha-ota` with `standard/doha.json` and `debloat/doha.json`; add
  `tools/gcp-build.sh ota` to publish build.prop-verified entries.
- [ ] One-click OTA end-to-end: Settings → System update → install → reboot → slot switch.
- [ ] GApps on the standard build: Play Store + GMS work (GMS self-updated to 26.45.31);
  roles stay crDroid's until a Google app set is flashed; `AdvancedProtection` is absent
  from the Safety Center config (see BUGREPORT §8).

## From the 18:29 bugreport (build 09:06)

- [ ] D1 launcher crash survives a module-level clean: gate the next build on
  `aapt2 dump resources out/target/product/amogus_doha/*/priv-app/Launcher3*/Launcher3*.apk | grep widget_internal_focus_bg`
  and only then flash. A build from an empty `out/` is the actual fix.
- [ ] D5 sepolicy: add `allow system_suspend sysfs_batteryinfo:dir r_dir_perms;` and
  `:file r_file_perms;` (174 denials per report, and it is why `suspend-service` cannot read the
  wakeup38 wakelock stats). Regenerate `patches/device/lineage/sepolicy.patch` from the tree.
- [ ] D4 GMS `Unexpected safety source: AdvancedProtection`: platform/GApps mismatch, not ours.
  Re-check after the next NikGapps bump before spending time on a `frameworks/base` enum patch.
- [ ] D6 keystore2 attestation errors: documented in BUGREPORT §D6, no action.

## Home-screen drag (D7), from the 18:29 report

- [x] Root cause: `mWorkspaceLoading=true` forever → `isWorkspaceLocked()` → `canStartDrag` false.
      Not a lock feature; cleared only in `finishBindingItems()`, after a restore that can throw.
- [x] `patches/packages/apps/Launcher3.patch` (verified with `git apply --check` on pristine
      `0be34a1`): try/catch around the widget-host background, and `try/finally` around the page
      restore so the loading flag always clears.
- [x] `build.sh` gate: fails the build if the launcher APK has no `widget_internal_focus_bg`.
- [ ] Verify on the next flash: long-press an icon and drag it across pages; then
      `adb shell dumpsys activity service com.android.launcher3/.LauncherProxyService | grep mWorkspaceLoading`
      must say `false`.
