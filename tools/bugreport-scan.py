#!/usr/bin/env python3
"""Sweep an Android bugreport for real defects, in one pass.

    ./tools/bugreport-scan.py bugreport-doha-....zip      # or the .txt inside it
    ./tools/bugreport-scan.py bugreport.txt --area radio  # one section only

Why this exists: a bugreport is 40+ MB of dumpsys, and the interesting lines are
buried between tags that dumpstate itself produces. This groups them: crash
signatures, error clusters per tag, and per-area patterns (permissions, HAL
deaths, radio, connectivity, storage, thermal). It also separates real defects
from dump artifacts, e.g. `Invalid resource ID 0x00000003` lines that only ever
appear during the dump command and mean nothing.
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
    ap.add_argument("--area", choices=sorted(AREAS), help="only show this area")
    ap.add_argument("--max", type=int, default=6, help="samples per section")
    a = ap.parse_args()

    crashes = collections.Counter()
    crash_first = {}
    tags = collections.Counter()
    tags_sample = {}
    area_hits = collections.defaultdict(list)
    pending = None

    for raw in open_text(a.path):
        line = raw.rstrip("\n")
        hit = CRASH.search(line)
        if hit:
            key = hit.group(0).strip()
            crashes[key] += 1
            crash_first.setdefault(key, line[:160])
            pending = key          # the "Process: <pkg>" line follows the header
            continue
        if pending and "Process: " in line:
            pkg = re.search(r"Process: ([\w.]+)", line)
            if pkg:
                crashes[f"{pending} [{pkg.group(1)}]"] += crashes.pop(pending, 1)
                crash_first.setdefault(f"{pending} [{pkg.group(1)}]", crash_first.pop(pending, line[:160]))
            pending = None
            continue
        m = LINE.match(line)
        if not m:
            continue
        ts, _pid, tid, _uid, lvl, tag, msg = m.groups()
        tag = tag.strip()
        for area, rx in AREAS.items():
            if rx.search(msg) and len(area_hits[area]) < 300:
                area_hits[area].append(f"{ts} {tag}: {msg[:150]}")
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

    for area in ([a.area] if a.area else AREAS):
        hits = area_hits[area]
        if not hits:
            continue
        print(f"\n== {area} ({len(hits)} lines) ==")
        for s in hits[: a.max]:
            print("   ", s)

    print("\n== how to read this ==")
    print("  invalid-resource lines that all share one timestamp are dump artifacts,")
    print("  not runtime defects; a NotFoundException next to a 0x7f... id is real.")


if __name__ == "__main__":
    sys.exit(main())
