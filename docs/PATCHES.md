# Patch map

All patches live in `patches/a16/<project path>.patch` and are applied with
`git apply` to the synced project. The source is the public
`christiaan/lineage-23-amogus_doha` patch set, which is the only complete
Android 16 port for this device.

## Patch placeholders

A patch may contain `@NAME@` placeholders for build settings.
`scripts/lib.sh:render_patch` substitutes them before the patch is applied;
an unknown placeholder aborts the patch step.

| Placeholder | Config value | Meaning |
|---|---|---|
| `@SKIN_THROTTLE_MC@` | `SKIN_THROTTLE_C` in `config/build.env` (default 40) | Skin temperature in millidegrees at which the thermal HAL reports throttling |

Upstream `christiaan` substitutes this token in its own `build.sh`; this kit
must do the same, otherwise the literal token reaches the compiler and the
build dies at 90% with `error: expected expression` in
`vendor/qcom/opensource/thermal/thermalConfig.cpp`. `cmd_patch` also runs
`assert_no_placeholders` as a fail-fast guard.

| Patch | Project | Prevents |
|---|---|---|
| `device/motorola/amogus.patch` | `device/motorola/amogus` | bootctrl namespace error; `cp -a /.` kernel headers; VINTF kernel rejection; `libqsap_sdk` build; thermal HAL label; sensor file type |
| `device/motorola/amogus_doha.patch` | `device/motorola/amogus_doha` | empty `modules.load` disabling vibrator and FocalTech/Novatek touch |
| `device/motorola/targets.patch` | `device/motorola/targets` | `PRODUCT_VENDOR_KERNEL_HEADERS` empty for source-built kernels |
| `device/motorola/common.patch` | `device/motorola/common` | power HAL aconfig link; fingerprint `fps_id` fallback; Egistec hwservice labels; QCC GPS VINTF |
| `device/qcom/common.patch` | `device/qcom/common` | `libqsap_sdk` product entry; `wificfr`/`wifilearner` init services; QCC GPS packages; sepolicy duplicates |
| `device/qcom/sepolicy_vndr/legacy-um.patch` | `device/qcom/sepolicy_vndr` | missing sm8450-only SELinux types and duplicate labels |
| `device/lineage/sepolicy.patch` | `device/lineage/sepolicy` | duplicate property/type declarations |
| `hardware/motorola.patch` | `hardware/motorola` | `libqsap_shim` source module |
| `hardware/nxp/nfc.patch` | `hardware/nxp/nfc` | PN553 NACK after standby (10 ms retry) |
| `kernel/motorola/msm-4.14.patch` | `kernel/motorola/msm-4.14` | WPA3-SAE `NL80211_WPA_VERSION_3` (skip if already in `lts`) |
| `packages/modules/Connectivity.patch` | `packages/modules/Connectivity` | `BpfNetMaps` null-map guards on 4.14 (crDroid already relaxed the NetBpfLoad/BpfHandler gates, so this file is reduced to the missing Java guards) |
| `system/core.patch` | `system/core` | fastbootd lock-state detection (crDroid already carries the `SetSafetyNetProps` property block, so this file is reduced to the fastboot hunk) |
| `vendor/motorola/amogus.patch` | `vendor/motorola/amogus` | prebuilt `libqsap_sdk.so` installation for `qcrild` |
| `vendor/qcom/common.patch` | `vendor/qcom/common` | QCC GPS protobuf crash-loop; `wificfr` services |
| `vendor/qcom/opensource/audio/sm8150.patch` | `vendor/qcom/opensource/audio/sm8150` | C23 `pthread_create` signature errors |
| `vendor/qcom/opensource/interfaces.patch` | `vendor/qcom/opensource/interfaces` | missing FM HIDL for the Bluetooth HAL |
| `vendor/qcom/opensource/thermal.patch` | `vendor/qcom/opensource/thermal` | thermal sensor names (`xo_therm`, no `soc`) |

Additional non-patch fixes applied by `50-patch`:

| Fix | Where | Why |
|---|---|---|
| BSNL VoLTE booleans | `packages/apps/CarrierConfig` asset 1549 | AOSP ships VoLTE keys for Jio but not BSNL |
| GApps keyboard collision | `vendor/gapps/{arm,arm64}/Android.bp` and both `*-vendor.mk` | rename the GApps `libjni_latinimegoogle` modules to `_gapps` and drop them from the product lists; crDroid’s LatinIME keeps the keyboard |
| Missing BSNL IMS APNs | `vendor/apn` | add only rows the synced tree lacks |

## If a patch fails

`./scripts/build.sh patch` stops before the build and logs to
`work/logs/patch.log`. This is intentional: a partially patched tree is worse
than no build. Two likely causes:

1. the base project moved (crDroid 16.0 branch advanced), or
2. the crDroid fork of `system/core` or `packages/modules/Connectivity`
   differs from the LineageOS 23.2 fork the patch was written against.

Fix by rebasing the patch against the synced file; keep the same semantic
change. Do not delete a patch just to make the build continue.
