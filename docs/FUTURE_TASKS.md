# Future tasks

Living checklist. Do not mark an item done until it has been verified on the
device or in a real release.

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
