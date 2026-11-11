# Verification

## Build gates (automatic)

`./scripts/build.sh verify` inspects `out/target/product/amogus_doha`:

| Check | Fatal? |
|---|---|
| `GmsCore.apk` present | yes |
| `Phonesky.apk` present | yes |
| `CarrierConfig.apk` BSNL asset has `carrier_volte_available_bool` | no (warn) |
| `apns-conf.xml` has at least one BSNL IMS row | no (warn) |
| `libqsap_sdk.so` present | yes |
| `init.amogus_perf.rc` absent (stripped tuning) | no |
| `ro.build.tags=release-keys` | no (warn on test keys) |
| `ro.debuggable=1` | no (warn on userdebug) |

A build that fails a fatal check is not shippable. Warnings are expected on
the first userdebug build.

## Device test matrix

Run after every flash; 72 h before calling a build stable.

| ID | Test | Pass |
|---|---|---|
| T1 | 24 h normal use, 72 h before release; after any reboot capture `/sys/fs/pstore` and `dmesg` | 0 unexpected reboots |
| T2 | Unlock, swipe to app drawer | drawer starts < 1 s |
| T3 | Hotspot 2.4/5 GHz, browse + speedtest | enables < 2 s, client gets IP and traffic |
| T4 | USB tethering | client gets IP and browses |
| T5 | BSNL SIM1 outgoing/incoming, 4G calling on/off | calls connect both ways; 4G icon during call or clean CSFB |
| T6 | Jio SIM2 control | unchanged |
| T7 | Overnight standby (8 h, screen off, SIMs/Wi-Fi on) | < 10 % first build, < 3 % target |
| T8 | Touch across lock/unlock/sleep on Himax/FocalTech/Novatek units | no dead zones |
| T9 | 30 min camera + browsing + hotspot | no uncomfortable heat |
| T10 | Play Store sign-in, install, Quick Share, integrity checker | Store works; BASIC passes |
| T11 | Swap default data SIM, calls on both slots | both stay registered |
| T12 | Dirty-flash next build | GApps and settings survive |

## Diagnostics

```bash
# unexpected reboot
adb shell ls -la /sys/fs/pstore
adb pull /sys/fs/pstore
adb shell dmesg > dmesg.txt

# SIM1
adb shell getprop persist.vendor.radio.mcfg_version
adb shell dumpsys telephony.registry | grep -i ims
adb shell dumpsys carrier_config | grep -iA5 bsnl
adb logcat -b radio -d > radio.txt

# GApps
adb shell pm list packages | grep -E 'com.google.android.gms|com.android.vending'
adb shell getprop ro.build.fingerprint
```

The doha DTS has no `ramoops` reserved-memory node, so `CONFIG_PSTORE_RAM`
alone does not capture a kernel panic. If random reboots persist, add a
`ramoops` node to the device DTS or use a serial/last-kmsg path; do not claim
pstore is working just because the config symbol is enabled.
