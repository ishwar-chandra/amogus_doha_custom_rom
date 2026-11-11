# Patch provenance

`patches/a16/` is the Android 16 port patch set from the public
[`christiaan/lineage-23-amogus_doha`](https://github.com/christiaan/lineage-23-amogus_doha)
repository. Each file is named after the project path it applies to:

```
patches/a16/<project path>.patch
```

The build applies it with `git apply` in that project, checks first so a
failure cannot leave conflict markers, and stops before compiling if any
patch does not apply.

Two files are intentionally reduced to the hunks crDroid 16 still lacks:

- `packages/modules/Connectivity.patch` contains only the `BpfNetMaps.java`
  null-map guards. crDroid’s fork already relaxed the `NetBpfLoad` and
  `BpfHandler` kernel gates.
- `system/core.patch` contains only the `fastboot/device/utility.cpp` lock
  detection. crDroid’s fork already has the `SetSafetyNetProps()` block.

`patches/carrierconfig/bsnl-volte.patch` is a one-file patch against AOSP
`packages/apps/CarrierConfig` r4: it adds the BSNL VoLTE booleans to carrier
id 1549. It is not from the Christiaan set; see [docs/BSNL_VOLTE.md](../docs/BSNL_VOLTE.md).

The GApps keyboard collision and the missing-only BSNL IMS APN rows are
applied by scripts, not patches:

- `scripts/build.sh` removes `libjni_latinimegoogle` from
  `vendor/gapps/arm64/arm64-vendor.mk` so crDroid’s LatinIME fork and
  MindTheGapps do not define the same module.
- `scripts/tools/fix_apn.py` adds only IMS rows the synced `vendor/apn` tree
  lacks.

Keep the original patch headers and credits. These files are evidence of the
upstream work, not a new port.
