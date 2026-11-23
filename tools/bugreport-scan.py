#!/usr/bin/env python3
"""Sweep an Android bugreport for real defects, in one pass.

    ./tools/bugreport-scan.py bugreport-doha-....zip            # or the .txt inside it
    ./tools/bugreport-scan.py bugreport.txt --area telephony    # one section only

Why this exists: a bugreport is 40+ MB of dumpsys, and the interesting lines are
buried between tags that dumpstate itself produces. This groups them: crash
signatures, error clusters per tag, and per-area patterns (permissions, HAL
deaths, telephony, connectivity, storage, thermal, DRM, performance and power).
It also separates real defects from dump artifacts, e.g. `Invalid resource ID
0x00000003` lines that only ever appear during the dump command and mean nothing.
"""
import argparse
import collections
import re
import sys
import zipfile

# Tags whose output is the dump itself, or a subsystem that always logs at E.
NOISE_TAGS = re.compile(
    r"dumpstate|lshal|^binder$|ProcStatsManager|TraceableOnGlobalLayout|"
    r"SELinux$|^audit|WindowManagerShell|StatsCompanionService|^statsd$|"
    r"^perfetto|core-|^CORE|DebugLogger|^knrq$|^keystore2$|^init$"
)
LINE = re.compile(r"^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([EW])\s+([^:]+):\s?(.*)$")
CRASH = re.compile(r"FATAL EXCEPTION|Fatal signal \d+|ANR in |WATCHDOG KILLING|"
                   r"\*\*\* FATAL EXCEPTION IN SYSTEM PROCESS")
# The native fatal header names the crashing thread itself; never wait for the
# next arbitrary "Process:" line (which may belong to a later dumpsys section).
NATIVE_FATAL = re.compile(r"Fatal signal (\d+).*?\bin tid (\d+) \(([^)]*)\)")
NATIVE_PID = re.compile(r"\bpid (\d+) \(([^)]*)\)")
# A Java crash header is followed by "Process: <pkg>, PID: ..." in AndroidRuntime.
PROCESS = re.compile(r"\bProcess:\s*([A-Za-z0-9_.]+(?::[A-Za-z0-9_.]+)*)")
PROCESS_WINDOW = 5
# dumpstate section headers, logcat buffer markers and command failures end a
# crash block; ProcessRecord dumps from dumpsys must not leak into it.
SECTION_BOUNDARY = re.compile(r"^(?:-{3,}|={3,}|\*{3,}|DUMP OF SERVICE\b)")

AREAS = {
    "resource-missing": re.compile(r"NotFoundException|No package ID|Invalid resource ID"),
    "permission": re.compile(r"privapp|permission denied|not whitelisted|Missing permission", re.I),
    "service-missing": re.compile(r"ServiceNotFoundException|Unable to start service|"
                                  r"Failed to get .*service|dead object|Binder died", re.I),
    "telephony": re.compile(r"\b(ImsRegistration|ImsPhoneCallTracker|VoLTE|modem|"
                            r"no sim|SIM.*(error|absent)|data call)\b", re.I),
    "connectivity": re.compile(r"wifirtt|WifiService|supplicant|hostapd|bluetooth.*fail", re.I),
    "audio-video": re.compile(r"audio_hw|AudioFlinger|perf_lock|QC2V4l2|OMX-VDEC|EnergySaver", re.I),
    "storage": re.compile(r"ENOSPC|No space left|ext4.*error|f2fs.*error|SQLiteException", re.I),
    "thermal-power": re.compile(r"thermal.*(throttl|trip)|overheat|shutdown.*temp", re.I),
}

# New evidence areas are grouped so one noisy group (wake locks, for example)
# cannot hide the measured summary lines behind the per-section sample limit.
NEW_AREA_GROUPS = {
    "drm": [
        ("WVCdm",
         re.compile(r"WVCdm", re.I)),
        ("security level",
         re.compile(r"IsSecurityLevelSupported|security_level", re.I)),
        ("OEMCrypto L1/L3 fallback",
         re.compile(r"liboemcrypto|oemcrypto_adapter|Falling back to L3|"
                    r"Trying L1|L3 Initialized", re.I)),
        ("DRM linker / AVC",
         re.compile(r"(?:linker|CANNOT LINK EXECUTABLE|avc:\s*denied).*"
                    r"(?:drm|widevine|oemcrypto|wvhidl|mediadrm)", re.I)),
    ],
    "performance": [
        ("zram counters",
         re.compile(r"zram|zswap|mm_stat|disksize|comp_algorithm|/zram0/stat", re.I)),
        ("block counters",
         re.compile(r"/sys/block/|BLOCK STAT", re.I)),
        ("pswpin / pswpout",
         re.compile(r"\bpswpin\b|\bpswpout\b|\bpgpgin\b|\bpgpgout\b", re.I)),
        ("am_kill",
         re.compile(r"\bam_kill\b")),
        ("frame jank percentiles",
         re.compile(r"Janky frames|Total frames rendered|percentile:", re.I)),
        ("thermal status",
         re.compile(r"Thermal [Ss]tatus:?\s*[0-9]", re.I)),
    ],
    "power": [
        ("statistics since last charge",
         re.compile(r"^\s*Statistics since last charge:?|"
                    r"^\s*Estimated battery capacity:|"
                    r"^\s*Time on battery:|^\s*Total run time:|"
                    r"^\s*Total partial wakelock time:", re.I)),
        ("discharge summary",
         re.compile(r"^\s*Discharge:|^\s*(?:Screen (?:on|off|doze)|"
                    r"Device (?:light|deep) doze) discharge:", re.I)),
        ("connectivity power summary",
         re.compile(r"CONNECTIVITY POWER SUMMARY|"
                    r"Cellular (?:kernel active|Sleep|Idle|Rx|Tx) time", re.I)),
        ("network battery drain",
         re.compile(r"^\s*(?:Cellular|Wifi|Bluetooth) Battery drain:", re.I)),
        ("estimated per-UID consumers",
         re.compile(r"Estimated power use|Computed drain|"
                    r"^\s*UID u\d+a?\d+:\s+[0-9]", re.I)),
        ("partial wake locks",
         re.compile(r"All (?:partial|kernel) wake locks|PARTIAL_WAKE_LOCK|"
                    r"Wake lock |Wake Lock Log|ACQ .*\(partial\)", re.I)),
        ("pending wakeup sources",
         re.compile(r"Pending Wakeup Sources", re.I)),
        ("suspend entry/exit",
         re.compile(r"PM: suspend (?:entry|exit)|Resume caused by", re.I)),
        ("ICNSS / firmware context",
         re.compile(r"icnss|Invalid HDD context|"
                    r"Target initial wake up received try again|"
                    r"Firmware attempting wakeup, try again|"
                    r"critical event\(s\) in flight|FW[- ]down|\bSSR\b", re.I)),
        ("suspend no-irq / failed callbacks",
         re.compile(r"pm_suspend_noirq|dpm_run_callback|failed to suspend|"
                    r"Some devices failed to suspend", re.I)),
    ],
}

AREA_GROUPS = {name: [(name, rx)] for name, rx in AREAS.items()}
AREA_GROUPS.update(NEW_AREA_GROUPS)


# Cheap literal gate: only lines that contain one of these stems run the new
# evidence regexes. Old areas keep their original logcat-only behavior.
NEW_GATES = (
    "wvcdm", "liboemcrypto", "oemcrypto_adapter", "falling back to l3",
    "trying l1", "l3 initialized", "security_level",
    "issecuritylevelsupported", "linker", "cannot link", "avc:",
    "zram", "zswap", "/sys/block/", "mm_stat", "disksize",
    "comp_algorithm", "block stat",
    "pswpin", "pswpout", "pgpgin", "pgpgout", "am_kill",
    "janky frames", "total frames rendered", "percentile:",
    "thermal status",
    "statistics since last charge", "time on battery", "discharge:",
    "total run time", "estimated battery capacity", "total partial wakelock",
    "connectivity power summary", "battery drain", "cellular",
    "estimated power use", "computed drain", "uid u",
    "all partial wake locks", "all kernel wake locks", "partial_wake_lock",
    "wake lock", "acq ", "pending wakeup sources", "pm: suspend",
    "resume caused by", "icnss", "invalid hdd context",
    "target initial wake up", "firmware attempting wakeup",
    "critical event", "fw-down", "fw down", " ssr", "ssr ",
    "pm_suspend_noirq", "dpm_run_callback", "failed to suspend",
)


def open_text(path):
    if path.endswith(".zip"):
        z = zipfile.ZipFile(path)
        name = next(n for n in z.namelist() if n.endswith(".txt") and "bugreport" in n)
        import io
        return io.TextIOWrapper(z.open(name), errors="replace")
    return open(path, errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--area", choices=sorted(AREA_GROUPS), help="only show this area")
    ap.add_argument("--max", type=int, default=6, help="samples per evidence group")
    a = ap.parse_args()

    crashes = collections.Counter()
    tags = collections.Counter()
    tags_sample = {}
    area_hits = {area: collections.defaultdict(list) for area in AREA_GROUPS}
    area_counts = {area: collections.Counter() for area in AREA_GROUPS}
    area_seen = {area: set() for area in AREA_GROUPS}
    seen_groups = set()
    seen_crashes = set()
    pending = None          # (crash key, logcat lines left to find Process:)

    for raw in open_text(a.path):
        line = raw.rstrip("\n")
        m = LINE.match(line)

        hit = CRASH.search(line)
        if hit:
            native = NATIVE_FATAL.search(line)
            if line in seen_crashes:
                continue
            seen_crashes.add(line)
            if native:
                sig, tid, thread = native.groups()
                key = f"Fatal signal {sig} in tid {tid} ({thread})"
                crashes[key] += 1
                pending = None
            elif hit.group(0).startswith("Fatal signal"):
                key = hit.group(0).strip()
                pidm = NATIVE_PID.search(line)
                if pidm:
                    key += f" (pid {pidm.group(1)} {pidm.group(2)})"
                crashes[key] += 1
                pending = None
            else:
                key = hit.group(0).strip()
                crashes[key] += 1
                pending = (key, PROCESS_WINDOW)
            continue

        if pending:
            key, remaining = pending
            if SECTION_BOUNDARY.match(line):
                pending = None
            elif m and "Process:" in line:
                pm = PROCESS.search(line)
                if pm:
                    pkg = pm.group(1)
                    if pkg != "ProcessRecord" and not pkg.startswith("ProcessRecord"):
                        newkey = f"{key} [{pkg}]"
                        n = crashes.pop(key, 1)
                        crashes[newkey] += n
                        pending = None
                        # The association line itself is not evidence for an area.
                        continue
                remaining -= 1
                if remaining <= 0:
                    pending = None
                else:
                    pending = (key, remaining)
            elif m:
                remaining -= 1
                if remaining <= 0:
                    pending = None
                else:
                    pending = (key, remaining)

        ts = tag = msg = None
        if m:
            ts, _pid, _tid, _uid, lvl, tag, msg = m.groups()
            tag = tag.strip()

        low = line.lower()
        new_gate = any(g in low for g in NEW_GATES)
        if m or new_gate:
            shown = f"{ts} {tag}: {msg[:180]}" if m else line.strip()[:180]
            for area, groups in AREA_GROUPS.items():
                is_new = area in NEW_AREA_GROUPS
                if is_new and not new_gate:
                    continue
                if not is_new and not m:
                    continue
                for label, rx in groups:
                    if not rx.search(line):
                        continue
                    dedup = (area, label, line)
                    if dedup in seen_groups:
                        continue
                    seen_groups.add(dedup)
                    area_counts[area][label] += 1
                    area_seen[area].add(line)
                    if len(area_hits[area][label]) < a.max:
                        area_hits[area][label].append(shown)

        if not m:
            continue
        if lvl == "E" and not NOISE_TAGS.search(tag):
            tags[tag] += 1
            tags_sample.setdefault(tag, msg[:150])

    print("== crash / watchdog signatures ==")
    for k, n in crashes.most_common():
        print(f"  {n}x {k}")
    if not crashes:
        print("  none")

    if not a.area:
        print("\n== error tags (real, noise filtered) ==")
        for tag, n in tags.most_common(20):
            print(f"  {n:5} {tag:34} {tags_sample[tag]}")

    for area in ([a.area] if a.area else AREA_GROUPS):
        groups = AREA_GROUPS[area]
        total = len(area_seen[area])
        if not total:
            if a.area:
                print(f"\n== {area} (0 lines) ==")
            continue
        print(f"\n== {area} ({total} unique lines) ==")
        if len(groups) == 1:
            for s in area_hits[area][groups[0][0]][: a.max]:
                print("   ", s)
            continue
        for label, _rx in groups:
            n = area_counts[area][label]
            if not n:
                continue
            print(f"  [{label}] {n} lines")
            for s in area_hits[area][label][: a.max]:
                print("   ", s)

    print("\n== how to read this ==")
    print("  invalid-resource lines that all share one timestamp are dump artifacts,")
    print("  not runtime defects; a NotFoundException next to a 0x7f... id is real.")


if __name__ == "__main__":
    sys.exit(main())
