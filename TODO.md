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
