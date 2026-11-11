# Play Integrity and signing

## The three verdicts

| Verdict | Meaning | On an unlocked doha |
|---|---|---|
| `MEETS_BASIC_INTEGRITY` | runtime not tampered; unlock allowed | possible with locked/verified-boot props |
| `MEETS_DEVICE_INTEGRITY` | certified device, hardware-backed | not guaranteed on a custom ROM; may need user-side PIF |
| `MEETS_STRONG_INTEGRITY` | Google hardware keys sign the boot chain | impossible on any unlocked custom ROM |

## What this repo includes

crDroid 16’s `system/core` fork already contains a complete
`SetSafetyNetProps()` block in `init/property_service.cpp`:

```
ro.boot.verifiedbootstate=green
ro.boot.vbmeta.device_state=locked
ro.boot.flash.locked=1
ro.build.tags=release-keys
ro.debuggable=0
```

The only missing piece is fastbootd reading the real lock state after those
props are faked; `patches/a16/system/core.patch` is reduced to that one
`fastboot/device/utility.cpp` hunk. This is the same mechanism the working
LineageOS 23.2 builds used for Basic integrity. It does not fake a Pixel
fingerprint and does not affect OTA.

## Signing

- `SIGNING=test` (default): AOSP test keys. Basic integrity is not guaranteed.
- `SIGNING=release`: expects `vendor/lineage-priv/keys/keys.mk` in the source
  tree. Generate keys with crDroid’s keygen guide and place the result there.
  The build refuses to run `SIGNING=release` without it.

Release-signing only helps if every build you flash uses the same keys. Moving
from a test-key build to a release-key build requires a clean flash.

## If an app needs DEVICE

Do not put fingerprint spoofing in the ROM: it fights every OTA and is the
first thing integrity checkers look for. Use the current user-side module
(PlayIntegrityFix/TrickyStore) and re-test after every ROM update. Banking
apps vary; test the actual app.

## Honest expectation

- Claude/ChatGPT-class apps: Basic should pass with the patch.
- Indian banking apps on SM6125: often accept Basic + working Keystore; some
  require DEVICE and a user-side module.
- STRONG: not possible; do not claim otherwise.
