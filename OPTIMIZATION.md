# doha optimization plan

Plan of record for "make the Moto G8 Plus lag-free under heavy multitasking".
Nothing here beyond the baseline measurement has been executed. Each phase lists
what changes, how it is measured, and how it is undone.

Status: planning. Device serial `ZF6522633X`, build `crDroidAndroid-17.0-20261118`
(the 2 GB zram commit `4826962` is **not** on it yet), kernel `4.14` pinned at
`73b7957`.

## 1. Baseline (measured 2026-11-20, `tools/perf-audit.sh` + `tools/perf-multitask.sh`)

| Metric | Value |
|---|---|
| MemTotal / MemFree / MemAvailable | 3598 / 91 / 925 MB |
| zram | 1023 MB total, 151 MB free at rest → **full** |
| Apps resident after cycling 8 | **0 of 8** (every return is a reload) |
| Cold launch | Settings 1260 ms, Chrome 1077, WhatsApp 2664, Telegram 2078, Gmail 3888, Truecaller 3936, Google app 4706, Photos 17903 |
| Warm reload (same order) | Settings 2060, Chrome 3123, WhatsApp 2512, Telegram 630, Gmail 1882, Photos 7972, Truecaller 1080, Google app 2769 ms |
| Launcher jank | 13.25% janky frames, p50 12 ms, p90 22 ms, p95 29 ms, p99 81 ms |
| CPU governor | `schedutil` both clusters (correct); min 300 MHz, max 1804/2016 MHz |
| LMK kills | 8 in the events buffer, 133 in the 2026-11-18 bugreport capture |
| Thermal | hottest zone `lmh-dcvs-00` 75 C (bus/DDR limiter, not skin — needs the skin zone read separately) |
| Animation scales | all 0 (already off) |
| Storage | `/`, `/vendor`, `/data` on `mmcblk0p*`; **no `dm-*` devices** (non-dynamic partitions) |

RSS at rest: system_server 672 MB, SystemUI 332 MB, GMS 283, Truecaller 214,
Google app 205 + search 193, Launcher3 204, WhatsApp 170, Gmail 141, Play Store 112,
Telegram 106, `gms.unstable` 104, Wellbeing 73, naviapp 100, Photos 91.

## 2. Diagnosis

The device is not under-tuned, it is out of memory. 3.5 GB usable minus ~1.0 GB of
GApps, ~0.7 GB system_server, ~0.3 GB SystemUI leaves roughly 1.5 GB for the user's
apps; 1 GB of zram absorbs the overflow and is full, so LMK evicts, and every app
switch is a full reload. Governor/read-ahead changes cannot recover that — swap
geometry, resident set and startup cost can.

Three measured facts that constrain the plan:

1. **zram is 1 GB, and the vendor's own 50%-of-RAM sizing never applies.** `on fs`
   `swapon_all` initialises zram from `fstab.qcom`, and `zram_drv.c` refuses a new
   `disksize` once `init_done` (`-EBUSY`). `fstab` is the only real owner.
2. **There are no `dm-*` devices.** Every read-ahead/queue write aimed at `dm-*`
   (both AOSPA's perf rc and this kit) is a no-op; `mmcblk0` is the only target.
3. **`adb shell` cannot read the queue knobs** (`Permission denied` on
   `/sys/block/mmcblk0/queue/*`; `ro.debuggable=0`, no `adb root`). Verification of
   I/O knobs must come from a bugreport (dumpstate runs as root) or a DEV_ROOT build.

## 3. Constraints

- No root on the shipping build → `/proc/sys/vm/*`, sysfs queue and zram knobs are
  read/write-blocked; user-space (settings, dexopt, package enable/disable) is open.
- Every kernel/ramdisk/init change costs a build + flash; builds are ~9 h cold and
  ~15–40 min warm on a kept VM (`NO_DELETE=1`).
- 4 GB device: zram above ~2.5 GB trades CPU/battery for swap and is not worth it.
- GApps is installed; it is ~1.0 GB of RSS and the single largest lever.

## Phase 0 — measurement harness (mostly done)

- [x] `tools/perf-audit.sh` — effective governor, read-ahead, `nr_requests`, zram
      size/usage, PSI, thermal headroom; exit = mismatch count.
- [x] `tools/perf-multitask.sh` — the 8-app cycle that produced §1.
- [ ] Fix `perf-audit.sh` zone classification: compare only `skin*`/`quiet_therm`
      zones to `SKIN_THROTTLE_C`, report `lmh-*`/`cpu-*`/`gpu-*` as info.
- [ ] Distinguish "node missing" from "permission denied" so root-only knobs show as
      `SKIP (needs root)` instead of pretending the value is absent.
- Gate: no phase below starts without a fresh §1-style table.

## Phase 1 — free, reversible, no flash (biggest immediate effect)

Each step is measured alone with `perf-multitask.sh` + `perf-audit.sh`.

- [ ] **Dexopt the hot set** (`cmd package compile -m speed -f <pkg>`): launcher3,
      settings, chrome, whatsapp already compiled to `speed`; telegram, gmail and
      googlequicksearchbox still need it (the run was cut when the phone dropped off
      adb). Rollback: `-m speed-profile`.
- [ ] **Free resident memory by disabling apps the owner does not use** — measured
      candidates: Truecaller 214 MB, Google app `quicksearchbox` 205+193 MB,
      Wellbeing 73 MB, naviapp 100 MB, Photos 91 MB.
      `pm disable-user --user 0 <pkg>` / rollback `pm enable <pkg>`.
      Requires the owner's decision per app.
- [ ] **Cached apps freezer** — currently unset (`default`); set
      `settings put global cached_apps_freezer enabled` and confirm cached processes
      actually freeze (`dumpsys activity processes | grep -i frozen`).
- [ ] **Trim per-app waste**: clear caches for the largest background offenders,
      re-check `dumpsys meminfo` total.
- Success criteria: resident ≥ 2 of 8, at least +200 MB `MemAvailable`, no app
  disabled that the owner uses.

## Phase 2 — the build that changes memory geometry

Already committed (`4826962`) but not flashed:

- [ ] **zram 1 GB → 2 GB** (`fstab.qcom` `zramsize=2147483648`). The only change
      with a real mechanism behind it: doubles the spill area before LMK evicts.
- [ ] **`nr_requests` 256 → 128**, dead read-ahead writes removed from
      `init.amogus.rc`.
- [ ] **Retarget the read-ahead owner to `mmcblk0`** — the current patch renders
      `@READAHEAD_KB@` into `init.aospa.perf.common.rc`'s `dm-*`/`sd*` lines, but on
      doha only `mmcblk0` exists. Add `mmcblk0` explicitly (it is already one of the
      lines) and drop nothing else; confirm on device that the value sticks.
- Verify with `tools/perf-audit.sh` (SwapTotal ~2047 MB) and, for root-only knobs, a
  fresh bugreport: `SwapTotal`, `/sys/block/mmcblk0/queue/read_ahead_kb`,
  `nr_requests`.
- Success criteria: `SwapTotal ≈ 2047 MB`, `SwapFree > 300 MB` at rest, resident
  ≥ 4 of 8, reload p50 < 1.5 s.

## Phase 3 — LMK / swap policy, one variable per build

- [ ] `config_extraFreeKbytesAdjust` 131072 → 65536 (device overlay). Lower reserve →
      fewer early kills; watch for allocation stalls.
- [ ] `lmkd` PSI limits (`ro.lmk.*` are read-only properties → build-time only):
      currently `psi_partial_stall_ms=200`, `swap_free_low_percentage=10`,
      `thrashing_limit=30`, `thrashing_limit_decay=50`. Only touch after Phase 2
      numbers, and one property at a time.
- [ ] Decide zram 2 GB vs 3 GB from `SwapFree` and CPU cost of `lz4` (`mpstat` idle).
- [ ] `READAHEAD_KB` A/B: 128 (current) vs 512, same workload.
- Success criteria: resident ≥ 6 of 8, jank < 5%, battery drain unchanged within 10%.

## Phase 4 — stability work that shows up as "lag"

- [ ] Re-check P2 (suspend/report: `misconfigured IRQ 20`, `NETLINK`,
      `SensorsHAL_WAKEUP`) after Phase 2 — wakeup churn costs both battery and CPU.
- [ ] Read the **skin** thermal zone properly (not `lmh-dcvs`), decide whether 40 C
      `SKIN_THROTTLE_C` is throttling earlier than the hardware needs.
- [ ] Confirm P1 (modem notifier panic) stays fixed on the flashed pin; a panic reads
      as a "random lag/reboot" to the owner.
- [ ] Logcat sweep for repeated GMS/Wellbeing service starts — those keep waking LMK.

## Phase 5 — acceptance

A build is "done" when, on the same 8-app cycle and the same GApps set:

- resident ≥ 6 of 8, reload p50 < 1.5 s, launcher jank < 5%;
- `SwapFree > 300 MB` at rest, no LMK storm (`am_kill` count flat over an hour);
- `perf-audit.sh` exits 0;
- battery drain on 1 h idle within 10% of the pre-tuning figure;
- calls/SMS/data, camera, Wi-Fi, BT, fingerprint, GNSS still pass `device-check.sh`.

## Explicit non-goals

CPU/GPU overclock or undervolt, disabling thermal protection, SELinux permissive,
KSM/THP, zram > 2.5 GB, `ro.config.low_ram=true`, `performance` governor, random
`ro.lmk.*` values, Magisk tuning modules that fight the vendor scripts.

## Decisions needed from the owner

1. Which of these may be disabled: Truecaller, Google app, Wellbeing, naviapp, Photos?
2. Is a **test-only DEV_ROOT build** acceptable (real `adb root`, live sysfs tuning,
   `dmesg`) — never published, one flash, then all of Phase 2/3 is tunable in minutes?
3. GApps: keep the current set, switch to NikGapps core, or use the debloat variant?
4. Keep the VM alive between tuning builds (`NO_DELETE=1`) so each A/B is
   ~15–40 min instead of a 9 h cold build?

## Rollback

| Action | Undo |
|---|---|
| `pm disable-user` | `pm enable <pkg>` |
| `cmd package compile -m speed` | `cmd package compile -m speed-profile -f <pkg>` |
| `settings put global cached_apps_freezer enabled` | `settings delete global cached_apps_freezer` |
| Phase 2/3 patch changes | `git revert <commit>`, rebuild, flash |
| A flash that regresses | `fastboot --set-active=<other slot>`; the previous slot is intact |
