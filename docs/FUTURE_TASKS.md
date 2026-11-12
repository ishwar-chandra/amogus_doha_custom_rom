# Future tasks

Living checklist. Do not mark an item done until it has been verified on the
device or in a real release.

## After the current build completes

- [ ] Wait for `build.status == 0`; do not change `work/android` mid-build.
- [ ] Run `verify` and `collect`, then confirm `dist/` contains the zip,
      images, checksums and `BUILD_INFO.txt`.
- [ ] Capture an A16 dump with `adb unroot` first. Do not use `adb root`
      for Play Integrity or banking tests.
- [ ] Compare the A16 dump against the A13 `device_dump/` baseline before
      declaring stability.

## A13 baseline findings to carry into A16

Source: `device_dump/` from crDroid 9.20 (Android 13, 2025-01-07 SPL).

### BSNL calls / VoLTE

- [ ] Treat BSNL as **CSFB-first**, not VoLTE-first:
  - A13 shows BSNL `isVopsSupported=false`, `mcfg_version=null`.
  - Jio shows a working IMS APN and `mcfg_version=RJIO_IND`.
- [ ] Test BSNL with preferred network **3G/2G only** and confirm calls work
      through CSFB.
- [ ] If CSFB works, do **not** force `carrier_volte_available_bool=true`
      for BSNL; revisit the CarrierConfig fallback in `scripts/build.sh`.
- [ ] Do not use `persist.dbg.volte_avail_ovr=1` as proof of VoLTE.
- [ ] Only add/enable BSNL IMS if the network actually advertises VoPS.

### GNSS / XTRA ANR

- [ ] On A13, `lshal` cannot see `vendor.qti.gnss@4.0`; the lazy HAL cannot
      start, and `com.qualcomm.location.XT` ANRs every ~20 seconds in
      `LocIDLClientBase.getIDLServiceVersion`.
- [ ] On A16, check `lshal | grep -i gnss` and
      `logcat -b all | grep -iE 'LocIDL|gnss_vendor|XTSysStatus'`.
- [ ] Fix GNSS HAL registration, or remove/disable `xtra_t_app`
      (`com.qualcomm.location.XT`) if it is not needed.
- [ ] Re-test GPS and confirm the XT ANR loop is gone; it is a likely
      battery/heat contributor.

### USB tethering

- [ ] A13 shows `mUsbTetheringFunction=RNDIS` but repeated
      `USB bcast ... rndis:false` with no active tethered interface.
- [ ] Reproduce on A16 with `dumpsys tethering` and inspect the USB/RNDIS
      init path; do not assume the `close_range()` patch fixed tethering.

### Play Integrity / build posture

- [ ] A13 baseline is `user`, `release-keys`, locked, verified-boot green,
      `ro.debuggable=0`; preserve that posture for daily builds.
- [ ] A16 currently uses `userdebug` + test keys. For release:
      `BUILD_VARIANT=user`, `SIGNING=release`, own keys.
- [ ] Never ship `service.adb.root=1`; run `adb unroot` and reboot before
      banking/integrity tests.
- [ ] Google Pay probes `adbd_prop`, `userdebug_or_eng_prop`,
      `system_adbd_prop`, `qemu_hw_prop` and `serialno_prop`; do not go
      SELinux-permissive to silence those probes.
- [ ] Do not claim STRONG integrity on an unlocked custom ROM.

### Keep unchanged unless evidence says otherwise

- [ ] Touch: A13 uses `fts_ts_doha` with the FocalTech/Nova modules; keep
      the same input name and driver path.
- [ ] Thermal: A13 zones were 37–40 °C with no throttling at capture; do not
      add thermal tweaks for this.
- [ ] Security patch: A13 is on 2025-01-07; keep the A16 base newer.

### Crash capture gap

- [ ] The A13 dump could not pull `/data/tombstones` or `/data/anr`; capture
      them with a proper root/bugreport method next time.
- [ ] Track the `dex2oat` SIGABRT seen during Google app bg-dexopt and
      confirm it does not recur on A16.

## OTA updates from GitHub Releases

- [ ] Decide the OTA metadata host: GitHub Pages (`gh-pages`) or a small
      Cloudflare Worker. GitHub's Releases API alone is not compatible with
      the Lineage/crDroid Updater.
- [ ] Choose a stable OTA URL before the next ROM build, for example:
      `https://ishwar-chandra.github.io/amogus_doha_custom_rom/ota.json`
- [ ] Generate `ota.json` after every `gh release create`:
  - [ ] `datetime`
  - [ ] `filename`
  - [ ] `id` (MD5 or SHA-256)
  - [ ] `romtype`
  - [ ] `size`
  - [ ] `url` (GitHub release asset URL)
  - [ ] `version`
- [ ] Bake the stable updater URL into the ROM
      (`lineage.updater.uri` / crDroid equivalent).
- [ ] Ensure the Updater app is present in the build.
- [ ] Sign all builds with the same release keys before shipping OTA.
      Test-key builds must not be mixed with release-key builds.
- [ ] Test the full path: install previous build, publish newer release,
      update through Updater, reboot, confirm the new build and GApps.
- [ ] Verify GitHub asset redirects work with the updater downloader.
- [ ] Confirm every OTA asset stays below GitHub's 2 GB per-file limit.
- [ ] Document that the first install and any key/base change requires a
      clean flash; later same-key updates can use OTA.
- [ ] Remove or disable the OTA entry if a release is withdrawn.

## Widevine L1 / DRM

- [ ] Record the stock baseline: `dumpsys media.drm`, Widevine security
      level (L1/L3), and `ro.boot.verifiedbootstate` on the stock ROM.
- [ ] Preserve the stock `persist` partition and TEE firmware; do not wipe
      or replace them while testing.
- [ ] Port the matching stock Widevine stack: vendor service,
      `libwvhidl`, `libwvdrmengine`, `liboemcrypto`, Keymaster/KeyMint HAL,
      VINTF entries and SELinux policy.
- [ ] Test the custom ROM on the same unit and check whether the TEE still
      reports L1 after unlocking/custom AVB.
- [ ] Document the result: L1 retained, or L3 fallback with the exact reason.
- [ ] Do not extract or redistribute Widevine keys/keyboxes; do not promise
      L1 on an unlocked custom ROM.
- [ ] Keep Play Integrity separate: L1 does not provide STRONG integrity.

## Release and backup

- [ ] Verify `gcp/doha.sh restore` from the first successful GDrive backup.
- [ ] Create a personal Google OAuth client ID before rclone's shared
      client ID is retired.
- [ ] Confirm automatic backup starts only after `verify` and `collect`
      succeed.
- [ ] Decide whether successful builds should create a named full snapshot
      in addition to the incremental `current/` mirror.

## Disk sizing

- [ ] After the first successful build, record final `du` values for
      `.repo`, checkout, `out/`, and ccache.
- [ ] Right-size the VM disk from 700 GB only after that measurement and a
      verified restore. Target 600 GB if the final total stays below ~500 GB.
- [ ] Do not shrink in place; recreate the VM and restore from GDrive.

## Hardware verification

- [ ] Both SIM slots, including BSNL SIM1 calls and data.
- [ ] Hotspot and USB tethering.
- [ ] FocalTech and Novatek touch panels.
- [ ] Random reboots, idle drain, and heating.
- [ ] Camera, fingerprint, NFC, GPS, Bluetooth audio.
- [ ] Play Store and banking apps after GApps setup.
