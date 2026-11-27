# Changelog

Unofficial crDroid 13.1 (Android 17) for the Motorola Moto G8 Plus (`doha`,
in-tree device `amogus_doha`). One section per build; the date in the heading is
what `tools/gcp-build.sh release` matches to fill the GitHub release notes.

## 2026-11-28 (unreleased)

Build `crDroidAndroid-17.0-20261128-amogus_doha-v13.1` (standard, userdebug).
Baseline: `2026-11-27`.

### Highlights

- **Dolby Atmos stack replaced.** The stock Android 10 port cannot work
  under Android 17: its 2019 `libswdap` rejects every DAP parameter
  (`getNumOfProfiles` returns `-3`), so `daxService`'s provider fails and
  Moto Audio crashes reading it. The ROM now carries the DAX3 3.6 Motorola
  package (`vendor/motorola-dolby`, pinned) - `DaxUI` + `daxService`
  (re-signed with the platform key), `vendor.dolby.hardware.dms@2.0`, the
  DAP effect and its tuning. Moto Audio is replaced by Dolby's DaxUI.
- **`frameworks/base` no longer rewrites `INTERACT_ACROSS_USERS_FULL`.**
  Platform-signing the Dolby apps grants the signature permission, so the
  `privileged` protection-level change, and the privapp allowlist it forced
  for every other holder, are removed.

### Known issues

- Dolby AC-4/E-AC-3 decoding is not enabled (the donor's codec libraries and
  `media_codecs_dolby_audio.xml` are not carried).
- The new Dolby stack is device-untested until this build is flashed.

## 2026-11-27 (unreleased)

Build `crDroidAndroid-17.0-20261127-amogus_doha-v13.1` (standard, userdebug;
manifest `46259d0`). Baseline: the last published build, `crdroid-20261120-3`
(no release notes were recorded for it or for any earlier tag).

### Highlights

- **Dolby Atmos** from the stock `QPIS30.28` firmware is now packaged end to
  end: Moto Audio (`MotoDolbyV3`), `daxService`, the DMS HIDL 1.0 HAL,
  `libswdap`/`libdapparamstorage`/`libdlbdsservice`, the Moto framework jars,
  permissions, VINTF entry and SELinux domain. The DAP effect is registered
  with audioserver, so the DSP is actually engaged, not just the UI installed.
- **Kernel moved to the fork's `lts` branch** (`def1be59`): 106 commits on top
  of the previous `fix` pin, carrying the 4.14.357 OpenELA baseline and the
  device fixes merged into `lts`. The kernel patch was rebased on that tip.
- **Build/release tooling**: VM discovery from the gcloud project, formatted
  live build logs, a maintainer test OTA channel, and `out/` on the second
  disk so packaging fits.
- **System fixes**: Wi-Fi Display prop corrected, pre-reboot dexopt no longer
  aborts on symlinked partitions, 0.5x animations by default, a page reserve
  and malformed-SMS SCTS handling, and several crDroidSettings patches
  rebased to keep Settings-core booting.

### Dolby Atmos

- `8ac868d` port the stock QPIS30.28 Dolby stack: `MotoDolbyV3` (Moto Audio),
  `daxService`, `vendor.dolby.hardware.dms@1.0` HIDL service and impl, DMS
  libraries, `libswdap` sound effect, `dax-default.xml`, init service,
  `hal_dms` SELinux policy, Moto addon/motosignature/settings-shared jars and
  permission XMLs, hidden-API whitelist, and the
  `persist.vendor.audio_fx.current=dolby` property.
- `f253d25` package the Dolby APKs as `BUILD_PREBUILT` modules (Android 17
  rejects APKs in `PRODUCT_COPY_FILES`); `daxService` is a privileged app with
  its privapp-permissions whitelist.
- `9ca8e7d` declare the APK's required `com.motorola.frameworks.core.addon`
  uses-library at the module level so Android 17's
  `enforce_uses_libraries` check passes.
- `24db7e5` skip `check_elf_files` for the stock DMS service binary, whose
  `DT_NEEDED` libraries are copied blobs rather than build modules.
- `e466f4b` declare the DMS HAL in a device framework compatibility matrix so
  `check_vintf_all` accepts `vendor.dolby.hardware.dms@1.0::IDms/default`.
- `46259d0` register the `dap` library and effect in the audio HAL's trinket
  `audio_effects.xml` — the file that actually becomes
  `/vendor/etc/audio_effects.xml`; the entries in `device/motorola/common`'s
  rootdir file are only a fallback because the audio HAL copy overrides them.
- AudioFX is filtered out of `PRODUCT_PACKAGES` so the ROM does not ship two
  audio-effect UIs.

> An earlier 2026-11-27 build had the Dolby APKs and service but no `dap`
> registration (the app opened, the DSP never engaged). This changelog and the
> final zip describe the fixed build.

### Dolby runtime fixes (bugreport 2026-11-27 20:21)

The first build with the registered effect crashed on device. The bugreport
showed two independent failures and three policy gaps:

- `com.dolby.daxservice` crashed 956 times in `DaxService.onCreate` with
  `SecurityException: ... requires android.permission.INTERACT_ACROSS_USERS_FULL`;
  the privapp whitelist only granted `INTERACT_ACROSS_USERS` and `MANAGE_USERS`.
  Grant `_FULL`.
- The DMS HAL exited status 1 immediately: `avc: denied { add } for
  interface=android.hidl.base::IBase ... tcontext=hidl_base_hwservice`, so
  `IDms::registerAsService()` failed and logged "Cannot register IDms vendor
  service". Allow `hal_dms_default hidl_base_hwservice:hwservice_manager add`.
- SELinux denied `find` on `hal_dms_hwservice` from `priv_app_36` (daxService)
  and `hal_audio_default` (the audio HAL loading `libswdap`); the
  `hal_client_domain(priv_app/audioserver, hal_dms)` aliases compiled to
  `priv_app_202604`/`audioserver_202604` and did not cover those domains. Add
  both client domains.
- The native `DolbyManagerService` had no `service_contexts` entry; add the
  type and the `hal_dms_default` add / effect+app find rules.
- Create `/data/vendor/dolby` in `on post-fs-data` (before HAL services start),
  not only in `on boot`.
- Moto Audio's 5 crashes were the downstream symptom
  (`content://com.dolby.daxservice.dolbyprovider/3/status` failed while
  daxService was restarting), not a separate UI bug.
- Other bugreport findings are vendor/pre-existing and outside this patch: one
  GNSS fatal signal, gatekeeper/keymaster fatal signals,
  `addFrozenStateChangeCallback returned -38` from the old audio HAL, and
  `motoexttelephony` service denials.


The next device run showed the HAL/effect side fixed (`IDms` registered,
`DAP FULL` loaded) but `daxService` still crashed: on Android 17
`INTERACT_ACROSS_USERS_FULL` is `signature|installer|module|role` (the privapp
whitelist cannot grant it), and SELinux still denied `hal_dms_hwservice` find
for `priv_app_36`/`hal_audio_default`. `patches/frameworks/base.patch` adds
`privileged` to the permission (the app keeps its stock signature, preserving
the DMS/Dolby broadcast relationship), and
`patches/device/motorola/amogus_doha.patch` adds the explicit client rules.
The stale `AudioFX` APK left by incremental builds is now removed
automatically: `build.sh` runs one `mka installclean` when the filtered package
is still staged, then returns to incremental builds.

### art and frameworks/av (2026-11-27 bugreport)

- **`patches/art.patch`** (project `art`): pre-reboot dexopt aborted with
  `Check failed: !OR_RETURN(IsSelfOrParentSymlink(target))
  /mnt/pre_reboot_dexopt/chroot/system_ext/lib` on every OTA; the archive has
  five tombstones (`tombstone_00..04`). The device ships `system_ext` and
  `product` as symlinks inside `/system`; the patch skips the bind mount when
  the target is behind a symlink, which resolves inside the chroot, so dexopt
  sees the same files.
- **`patches/frameworks/av.patch`** (project `frameworks/av`): `AudioFlinger`
  and `AAudioClientTracker` call the optional frozen-state callback; the 4.14
  binder returns `INVALID_OPERATION` (-ENOSYS), 200x as "returned -38". The
  patch ignores exactly that code and still warns on other failures. The call
  is on the client binder, not the audio HAL.
- **Vendor-only findings, not patched** (no source in the manifest, or expected
  on this ROM): `xtra-daemon`/`DgnssNtripSourc` SIGSEGV and
  `gatekeeper@1.0`/`keymaster@4.1` SIGABRT at `QSEECom_shutdown_app` are stock
  blobs that restart; `moto_ext_telephony.registry` needs the stock Moto
  framework; Google service-missing lines mean no GApps; `keystore2`
  attestation fails on the vendor keymaster (TrickyStore + user keybox is the
  route); the vendor supplicant lacks `setBtCoexistenceMode`, and Passpoint
  null-OSU/DHCP logs are network conditions.

### Kernel

- `0baf855` pin the kernel project to `lts` (`def1be59`, ahead 106/behind 0
  against the old `fix` pin). `patches/kernel/motorola/msm-4.14.patch` still
  applies to that tip.
- `9e75983` drop the duplicate `POWER_SUPPLY_PROP_ONLINE` switch case the
  `lts` merge introduced in `qpnp-smb5.c` (clang: duplicate case value); the
  kernel patch was regenerated against `lts`.
- `15f3b03` bound the `/proc/cmdline` append and apply boot-time scheduler
  margins.
- `b66e16d` keep the glink IRQ enabled without wake arming (the P2 RPM suspend
  deadlock fix) and `f213397` move the IRQ changes into the kernel fork.
- `a270fa3` disable Doze motion sensing for idle battery.

### System, device and settings

- `0061d76` fix the Wi-Fi Display property and drop a duplicated prop.
- `3657c62` stop aborting pre-reboot dexopt on symlinked partitions.
- `845c885` ship 0.5x window/transition animations by default.
- `60e0986` keep a page reserve and tolerate malformed SMS SCTS timestamps.
- `b37632d` rebase the `vendor/lineage` debloat patch onto the new MatLog
  block.
- `faa0cfc` package OEMCrypto and remove dead boot work.
- `6ab8fbd`/`eb85ded` fix the crDroidSettings Kotlin call and rebase the patch
  onto the new import block.
- `a270fa3` Doze motion sensing off (battery).
- `6885cb4` ask once per build when Play Integrity needs a keybox;
  `46e85b3`/`442aa9f`/`d8a6d8c` add `integrity-setup.sh`, repair the
  TrickyStore keybox import and correct the bugreport/performance probes.

### Build, release and tooling

- `0e51e82` discover the build VM from the gcloud project instead of a
  hardcoded instance name; `75eba1e` address it as the account that owns the
  build state.
- `7aad242` keep `out/` on the second disk so packaging fits.
- `908f921` build the branch checked out in this repo by default.
- `7807c63` add the maintainer `test` OTA channel and `promote`.
- `2f8c7bd`/`340fb8d`/`ab31424`/`cf4ef83` add the formatted build log view
  (`logs`, wrapping, dedupe, `--full`/`--raw`).
- `a568a14` split Drive backup out of the build chain; `acfcf9e` record the
  Drive OAuth 7-day expiry and test-user trap.
- `a270fa3` and the other device commits above are applied through
  `patches/`, so a clean sync reproduces them.

### Documentation

- `1d37554`/`3c1a6bb` rewrite `AGENTS.md` around the patch pipeline;
  `95a95bf` record the prebuilt uses-library rule and the interrupted-sync
  recovery; `95a76e9`/`00e203e`/`307e8e1`/`03abe9e` record the P20–P23
  fixes; `73edf98` sync README/GUIDE/TODO/OPTIMIZATION with Dolby, logs and
  VM discovery; `441b6e3` pin the docs to `lts`; `fef6cda` documents the
  Dolby build checks.

### Known limitations

- Dolby Atmos is **device-untested**: this changelog records that the effect
  is registered, not that a phone has played processed audio yet. Verify with
  `dumpsys media.audio_flinger | grep -i dap` after flashing.
- Moto-only hooks cannot be restored without the missing Moto apps:
  `daxService` requests `com.motorola.gamemode.permission.LAUNCH_GAMEMODE`
  (Game Mode) and `MotoDolbyV3` requests
  `com.motorola.permission.ACCESS_CHECKIN`; those integrations stay inert.
- The kernel fork's `lts` merge still carries the duplicate case upstream; the
  patch removes it locally until the fork is fixed.

## Previous releases

No release notes were recorded for these tags. `git log <tag>..<next-tag>` is
the only record of what changed.

| Tag | Date |
|---|---|
| `crdroid-20261120-3` | 2026-11-20 |
| `crdroid-20261120-2` | 2026-11-20 |
| `crdroid-20261120` | 2026-11-20 |
| `crdroid-20261118` | 2026-11-18 |
| `v2.0.0` | 2026-11-14 |
| `v1.3.0-test1` | 2026-10-29 |
| `v1.2.1` | 2026-10-25 |
| `v1.2.0` | 2026-10-24 |
| `v1.0.2` | 2026-10-23 |
| `v1.0.1` | 2026-10-23 |
| `v1.0.0` | 2026-09-26 |
