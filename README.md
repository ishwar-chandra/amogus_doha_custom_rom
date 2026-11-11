# amogus_doha custom ROMs

Buildkits for the **Motorola Moto G8 Plus** (`amogus_doha`, SM6125).

`main` is the landing/release-index branch only. The build code lives in
Android-version branches:

| Branch | Android | Status | Use |
|---|---|---|---|
| [`16`](../../tree/16) | **16** (crDroid 16.0) | buildkit ready; first full build pending | the stable target |
| [`17`](../../tree/17) | **17** (crDroid 17.0) | experimental; A16 patches need rebasing | future work |

## Build Android 16

```bash
git clone -b 16 https://github.com/ishwar-chandra/amogus_doha_custom_rom.git
cd amogus_doha_custom_rom

./scripts/build.sh dryrun
INSTALL_DEPS=1 JOBS=16 ./scripts/build.sh all
```

The result is in `dist/`. See the `16` branch README for details.

## Build on GCP (one command)

No 32 GB machine needed:

```bash
git clone -b 16 https://github.com/ishwar-chandra/amogus_doha_custom_rom.git
cd amogus_doha_custom_rom

./gcp/doha.sh all --repo ishwar-chandra/amogus_doha_custom_rom
```

That creates a 12 vCPU / 48 GB Ubuntu 24.04 VM, builds, publishes the GitHub
release and backs the source, `out/`, ccache and artifacts up to Google Drive.
See the `16` branch `gcp/README.md`.

## Android 17

Check out `17`:

```bash
git clone -b 17 https://github.com/ishwar-chandra/amogus_doha_custom_rom.git
```

It is a starting point, not a boot-tested ROM. The 4.14 kernel and A16 patch
set need rebasing; see `docs/ANDROID_17.md` on that branch.

## Releases

Published builds are under [Releases](../../releases). The default branch is
`main`; download from a release or switch to `16`.
