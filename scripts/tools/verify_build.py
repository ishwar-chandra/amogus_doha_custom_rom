#!/usr/bin/env python3
"""Post-build checks on the unpacked product output.

Usage: verify_build.py OUT_DIR

Exit 1 on a missing port-critical piece (GApps, BSNL carrier key, RIL library).
Warnings cover Play Integrity and optional items.
"""
from __future__ import annotations

import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

PASS = FAIL = WARN = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def warn(msg: str) -> None:
    global WARN
    WARN += 1
    print(f"  [WARN] {msg}")


def find_one(root: Path, *names: str) -> Path | None:
    for name in names:
        p = root / name
        if p.is_file():
            return p
    return None


def find_named(root: Path, name: str) -> Path | None:
    for p in root.rglob(name):
        if p.is_file():
            return p
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    if not out.is_dir():
        print(f"verify: {out} does not exist", file=sys.stderr)
        return 2

    print(f"verify: {out}")

    gms = find_one(out, "system/product/priv-app/GmsCore/GmsCore.apk",
                   "system/priv-app/GmsCore/GmsCore.apk",
                   "product/priv-app/GmsCore/GmsCore.apk")
    store = find_one(out, "system/product/priv-app/Phonesky/Phonesky.apk",
                     "system/priv-app/Phonesky/Phonesky.apk",
                     "product/priv-app/Phonesky/Phonesky.apk")
    if gms:
        ok(f"Play Services: {gms.relative_to(out)}")
    else:
        bad("Play Services (GmsCore.apk) missing - vendor/gapps inherit broken")
    if store:
        ok(f"Play Store: {store.relative_to(out)}")
    else:
        bad("Play Store (Phonesky.apk) missing - vendor/gapps inherit broken")

    cc = find_named(out, "CarrierConfig.apk")
    if cc:
        try:
            with zipfile.ZipFile(cc) as z:
                assets = [n for n in z.namelist()
                          if n.startswith("assets/") and "carrierid_1549" in n]
                if assets and b"carrier_volte_available_bool" in z.read(assets[0]):
                    ok(f"CarrierConfig BSNL VoLTE key present ({cc.name})")
                else:
                    bad("CarrierConfig BSNL asset lacks carrier_volte_available_bool")
        except zipfile.BadZipFile:
            warn(f"CarrierConfig.apk is not a zip: {cc}")
    else:
        warn("CarrierConfig.apk not found in output")

    apns = find_named(out, "apns-conf.xml")
    if apns:
        try:
            rows = [e.attrib for e in ET.parse(apns).getroot().findall("apn")]
            bsnl = [r for r in rows if r.get("mcc") == "404"
                    and (r.get("carrier_id") == "1549" or "bsnl" in (r.get("carrier") or "").lower())]
            ims = [r for r in bsnl if "ims" in (r.get("type") or "").split(",")]
            if bsnl and ims:
                ok(f"apns-conf.xml: {len(ims)} BSNL IMS row(s)")
            else:
                warn("apns-conf.xml: no BSNL IMS row (CarrierConfig may still enable VoLTE)")
        except ET.ParseError:
            warn(f"apns-conf.xml does not parse: {apns}")
    else:
        warn("apns-conf.xml not found in output")

    ril = find_named(out, "libqsap_sdk.so")
    if ril:
        ok(f"RIL dependency present: {ril.relative_to(out)}")
    else:
        bad("libqsap_sdk.so missing - qcrild may fail and SIMs may not register")

    perf = find_named(out, "init.amogus_perf.rc")
    if perf:
        warn("init.amogus_perf.rc present - this repo deliberately does not ship it")
    else:
        ok("no unmeasured perf tuning in the image")

    props = [p for p in out.rglob("build.prop") if p.is_file()]
    text = "\n".join(p.read_text(errors="ignore") for p in props)
    if "ro.build.tags=release-keys" in text:
        ok("ro.build.tags=release-keys")
    else:
        warn("ro.build.tags is not release-keys (test-keys build: Play Integrity BASIC is not guaranteed)")
    if "ro.debuggable=1" in text:
        warn("ro.debuggable=1 (userdebug); release builds should use BUILD_VARIANT=user")

    print(f"\n== {PASS} pass, {WARN} warn, {FAIL} fail")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
