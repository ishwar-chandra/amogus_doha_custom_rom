# Flashing

## Device facts

- Bootloader must be unlocked.
- The phone is **A/B**; recovery lives inside `boot.img`
  (`BOARD_USES_RECOVERY_AS_BOOT`).
- `system` is read-only erofs; GApps are baked into the zip. Do not flash a
  separate GApps package.
- Flashing a ROM does not change modem firmware.

## First install / clean flash

Coming from LineageOS 23.2, crDroid 9, stock, or any other ROM: clean flash.

```bash
# 1. Put the phone in fastboot
adb reboot bootloader
fastboot devices

# 2. Flash the matching boot/dtbo/vbmeta from the same build
fastboot flash boot   dist/v16-*/boot.img
fastboot flash dtbo   dist/v16-*/dtbo.img
fastboot flash vbmeta dist/v16-*/vbmeta.img

# 3. Boot recovery (the recovery is in boot)
fastboot reboot recovery
# if that command is unsupported:
#   fastboot reboot
#   and hold Volume Down while booting, then choose Recovery

# 4. In recovery: Factory reset -> Format data/factory reset
#    Then: Apply update -> Apply from ADB
adb sideload dist/v16-*/crDroidAndroid-*.zip
```

At the end, recovery asks whether to install another zip. Choose **No**, then
**Reboot system now**.

> The `vbmeta` flash may print
> `WARNING: vbmeta_a anti rollback downgrade, 0 vs 15`. This is expected on an
> unlocked doha; the flash still succeeds.

## Updating an existing install

```bash
adb reboot sideload-auto-reboot
adb wait-for-sideload
adb sideload dist/v16-*/crDroidAndroid-*.zip
```

Recovery installs to the **inactive slot** and switches to it on reboot. If
you want to keep a known-good slot, make it active before sideloading:

```bash
fastboot --set-active=a   # or b
```

## Rollback

Keep the previous build’s `boot.img`, `dtbo.img`, `vbmeta.img` and zip. To go
back:

1. Flash the older `boot/dtbo/vbmeta`.
2. Sideload the older zip.
3. If Android refuses to boot after a downgrade, factory reset (data will be
   lost).

## Do not

- Do not flash a separate MindTheGapps/NikGapps zip: `/system` is read-only
  and the package is already inside the ROM.
- Do not flash a different device’s firmware or modem.
- Do not use a “writable system” zip on this device; the previous ext4
  experiment did not boot.
