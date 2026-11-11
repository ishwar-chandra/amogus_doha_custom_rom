# BSNL / SIM1 VoLTE

## Symptom

On the LineageOS 23.2 builds, SIM1 (BSNL, India) cannot place or receive
calls. SIM2 (Jio) works. The same phone and modem work on crDroid 9 (A13).

## Confirmed framework cause

Android 15 moved per-carrier configs into `packages/apps/CarrierConfig` and
keyed them by carrier id. In AOSP `android-16.0.0_r4`:

| Carrier | File | `carrier_volte_available_bool` |
|---|---|---|
| Jio, id 2018 | `carrier_config_carrierid_2018_Reliance-Jio.xml` | **true** |
| BSNL, id 1549 | `carrier_config_carrierid_1549_Bharat-Sanchar-Nigam-Ltd-(BSNL).xml` | **absent** |

The framework therefore enables VoLTE for Jio and not for BSNL. That matches
the observed SIM1/SIM2 split. The fix is the CarrierConfig patch in
`patches/carrierconfig/bsnl-volte.patch`, which adds:

```xml
<boolean name="carrier_volte_available_bool" value="true" />
<boolean name="editable_enhanced_4g_lte_bool" value="true" />
```

to the BSNL asset. The filename is load-bearing: the loader parses carrier id
`1549` from it.

## APN reality

The APN database is version-dependent:

- The LineageOS 23.2 pin `6e73ba9` (`IN.xml`) has only one BSNL IMS row
  (MNC 58, `apn=bsnlnet`); most BSNL MNCs have no `type="ims"` row.
- Current `LineageOS/android_vendor_apn@main` already ships IMS rows for all
  24 BSNL MNCs with `carrier_id="1549"`.

`scripts/tools/fix_apn.py` reads the **synced** tree and adds only the missing
IMS rows. It does not duplicate rows that already exist. The old kit added a
full BSNL table unconditionally, which produced duplicate APNs on newer trees.

## What this repo does not do

- It does not scrub `persist.dbg.volte_avail_ovr`. That property is present in
  both the working A13 tree and the A16 tree (`common-prop.mk`). Removing it
  changes a variable that was not different between working and broken ROMs.
- It does not bake `mcfg`/`mbn`/`omc` files from the A13 phone. The modem
  firmware is not changed by flashing a ROM, and the A13/A16 vendor trees have
  identical radio blobs. Only include them if a hash diff proves otherwise.

## Diagnose on device

```bash
adb shell getprop persist.vendor.radio.mcfg_version
adb shell getprop | grep -iE 'ims|volte|operator.numeric'
adb shell dumpsys telephony.registry | grep -i ims
adb shell dumpsys carrier_config | grep -iA5 bsnl
adb shell content query --uri content://telephony/carriers \
  --projection name:numeric:apn:type
adb logcat -b radio -d > radio.txt
```

Experiments, in order:

| # | Test | Decides |
|---|---|---|
| E0 | On A13, `getprop persist.dbg.volte_avail_ovr`; on A16, toggle 4G calling | whether the debug override matters |
| E1 | BSNL preferred network 3G/2G only, then call | CS fallback works vs no call path |
| E2 | Swap SIM slots | slot-specific vs carrier-specific |
| E3 | During A13 BSNL call, does the icon stay 4G or drop to 2G/3G | true VoLTE vs CSFB |

Expected after the fix: the BSNL "4G calling" toggle appears; `dumpsys
carrier_config` shows the BSNL asset; calls connect and the icon stays 4G
during a VoLTE call, or cleanly drops to 2G/3G if the network uses CSFB.
