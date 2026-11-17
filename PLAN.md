# Plan: two variants (standard / debloated) with OTA channels

Status: revised 2026-11-17 after the change of direction · branch `crdroid-android-17`

## What changed

There is **no baked GApps variant any more**. Both variants are the same ROM and both expect the user to
flash crDroid's official NikGapps package in recovery:

| Variant | Apps shipped | GApps |
| --- | --- | --- |
| `standard` | today's build, unchanged | user flashes NikGapps crDroid official (base or full) |
| `debloat` | standard minus the extras listed below | same package, flashed by the user |

Consequences, all of them simplifications:

- **No redistribution risk.** The ROM ships no Google APKs, so the takedown/ToS question disappears; Google's
  apps arrive only through NikGapps, as upstream intends. Both variants can be public.
- **No private release, no baking, no erofs switch, no GMS privapp allowlist work.**
- **Space:** the debloat build *frees* system space, which is what makes the 449 MB NikGapps base package
  comfortable against the ~329 MiB headroom the standard image has on a 3.0 GiB partition.
- One structural knob is still needed so both zips come from one tree.

## Removal list — what is safe

### Tier 1: safe, nothing in the system depends on it

| App | Module | What disappears |
| --- | --- | --- |
| Game Space | `GameSpace` | game dashboard/overlay |
| Floating windows | `LMOFreeform`, `LMOFreeformSidebar` | freeform/sidebar window feature |
| Battery stats viewer | `BatteryStatsViewer` | extra battery stats screen |
| Log viewer | `MatLog` | in-ROM logcat viewer (already gated by `TARGET_DISABLE_MATLOG`) |
| Music player | `Twelve` | no music app; any player from Play works |
| Sound recorder | `Recorder` | no recorder app |
| Gallery | `Glimpse` | no gallery app; Photos/Files still open images |
| Calendar app | `Etar` | no calendar app — **CalendarProvider stays**, so storage/sync still work |
| Browser | `Jelly` | no browser until one is installed (Chrome arrives with NikGapps *full*) |

### Tier 2: removable, but a visible feature goes with it

| App | Effect |
| --- | --- |
| `OmniStyle` | lockscreen clock styles gone; Settings may show an empty section |
| `OmniJaws` | weather provider gone (lockscreen/at-a-glance weather breaks) |
| `AxThemeStore` + `AxSandbox` | crDroid theme store gone; its Settings entry goes dead |
| `backgrounds` | wallpaper picker entries reduced |
| `Profiles` | Lineage system profiles feature gone |
| `Seedvault` | Settings → Backup loses the built-in backup option |

### Must keep — removing these breaks calls, SMS, file pickers or OTA

`Dialer`, `messaging`, `Contacts` (default-role holders; NikGapps *full* debloats them itself at flash time,
*base* does not, so the ROM must not pre-remove them), `DocumentsUI` (only SAF picker), `Aperture` (only
camera), `WebView`/Trichrome (in-app browsing), `Updater`, `LineageSetupWizard`, `ContactsProvider`,
`CalendarProvider`, `MediaProvider`, `TelephonyProvider`, `Settings`/crDroid settings,
`framework_compatibility_matrix`, `lineage.platform`.

Recommendation: ship **Tier 1 only** in the first debloat build; Tier 2 items are user-visible features and
deserve their own decision.

## Variant mechanism (kit structure untouched)

- `DEBLOAT=1 ./build.sh …`, and the same env through `tools/gcp-build.sh build`.
- `build.sh`'s render step gains one placeholder next to `@SKIN_THROTTLE_MC@`: `@DEBLOAT@` (0/1) and
  `@UPDATER_CHANNEL@` (`standard`|`debloat`). The stamp hashes the rendered blob, so switching variants
  re-applies patches exactly like a changed setting does today.
- Artifacts: `…-v13.1.zip` (standard) and `…-v13.1-debloat.zip`; `tools/flash.sh` already lists sets separately.

## Patch inventory

| Patch | Change |
| --- | --- |
| `patches/vendor/lineage.patch` (new) | gated by `ifneq ($(DEBLOAT_BUILD),1)`: `GameSpace`, `LMOFreeform`, `LMOFreeformSidebar`, `BatteryStatsViewer`, `MatLog` (`crdroid.mk`), `Jelly` (`common.mk:147`), `Twelve` + `Etar` (`common_mobile_full.mk`), `Recorder`; `ExactCalculator` stays |
| `patches/device/motorola/amogus_doha.patch` (extend) | `ro.doha.variant=standard|debloat` for the OTA feed, nothing else |
| `patches/packages/apps/Updater.patch` (new) | `updater_server_url` → `https://raw.githubusercontent.com/<owner>/doha-ota/main/@UPDATER_CHANNEL@/doha.json`, plus a `filterUpdates` guard that drops entries whose filename lacks the channel token (fails closed) |
| `patches/kernel/motorola/msm-4.14.patch` | unchanged (pr_debug fix) |

No `build/make` patch and no GApps payload — materially smaller than the previous plan.

## OTA

- Repo `<owner>/doha-ota`: `standard/doha.json`, `debloat/doha.json`, both public.
- Schema is crDroid's parser, not the README: `{"response":[{"filename","download","timestamp","sha256",
  "size","version","os_sdk_level","os_patch_level","buildtype","device","maintainer"}]}`;
  `timestamp` = `ro.build.date.utc`, `os_sdk_level` = 37 (absent ⇒ 0 ⇒ filtered out).
- New `tools/gcp-build.sh ota` mode reads `build.prop` from the produced zip, asserts the variant, writes only
  that channel's JSON, commits `doha-ota`; cross-channel entries are refused.
- Both variants share testkey, so the JSON is the only access control — hence the client-side filename guard.

## Phases

0. Finish the running standard build; publish it (public) — unchanged from today.
1. `DEBLOAT` flag, `vendor/lineage` patch, Updater patch; validate each with `git apply --check`.
2. Standard build once more (picks up the Updater patch) → one-click OTA end-to-end test on the phone.
3. Debloat build → confirm removals, roles still filled, calls/SMS fine, system space freed.
4. `doha-ota` repo + both JSONs + publishing mode + channel-refusal test.
5. Docs: README/GUIDE variant table, tester notes (NikGapps still required, wipe when switching variants).

## Risks

- Never pre-remove default-role apps: NikGapps *base* does not replace Dialer/Messages/Contacts.
- Tier 2 removals leave dead Settings entries; keep them out of the first build.
- Same testkey on both channels: a wrong JSON installs cleanly, so the Updater guard is the safety net.
- OTA only works for phones already running a build with the patched endpoint.
- Build cost: each variant is a near-full rebuild (~3 h, ~$0.76/h) unless the `DEBLOAT` change avoids
  invalidating Soong inputs.

## Open items

1. Tier 1 only (recommended), or add any Tier 2 item?
2. Public OTA repo name/owner (`<owner>/doha-ota`)?
3. Should the debloat zip be the default download or the "advanced" option?
