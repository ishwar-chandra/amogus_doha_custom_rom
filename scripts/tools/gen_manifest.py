#!/usr/bin/env python3
"""Generate the local repo manifest for the doha port.

Usage:
  gen_manifest.py BASE_MANIFEST REMOTES CORE SUPPORTING PATHS OUT

The base manifest is `repo manifest -o` output from crDroid 16.0. It is used
only to discover project names for paths we override, so we can emit valid
<remove-project> elements before re-adding them at our pinned revisions.
"""
from __future__ import annotations

import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

TOKEN = re.compile(r"@([A-Z0-9_]+)@")


def expand(value: str) -> str:
    return TOKEN.sub(lambda m: os.environ.get(m.group(1), m.group(0)), value)


def read_rows(path: Path) -> list[list[str]]:
    rows: list[list[str]] = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rows.append([expand(part.strip()) for part in line.split("|")])
    return rows


def read_remotes(path: Path) -> list[tuple[str, str]]:
    return [(row[0], row[1]) for row in read_rows(path)]


def main() -> int:
    if len(sys.argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2
    base, remotes_file, core_file, supporting_file, paths_file, out = map(Path, sys.argv[1:])

    remotes = read_remotes(remotes_file)
    core = read_rows(core_file)
    supporting = read_rows(supporting_file)
    wanted_paths = {line.strip() for line in paths_file.read_text().splitlines() if line.strip()}

    base_names: dict[str, list[str]] = {}
    if base.exists() and base.stat().st_size:
        root = ET.parse(base).getroot()
        for project in root.findall("project"):
            path = project.get("path")
            name = project.get("name")
            if path and name:
                base_names.setdefault(path, []).append(name)

    remove_names: list[str] = []
    for path in sorted(wanted_paths):
        for name in base_names.get(path, []):
            if name not in remove_names:
                remove_names.append(name)

    root = ET.Element("manifest")
    for name, fetch in remotes:
        ET.SubElement(root, "remote", {"name": name, "fetch": fetch})

    for name in remove_names:
        ET.SubElement(root, "remove-project", {"name": name})

    def add_project(row: list[str]) -> None:
        path, remote, name, branch = row[0], row[1], row[2], row[3]
        pin = row[4] if len(row) > 4 else ""
        # Only the supporting list uses field 6 as a linkfile (src|dest).
        # Core-list field 6 is a free-text comment, so require the pipe.
        link = "|".join(row[5:]) if len(row) > 5 and "|" in "|".join(row[5:]) else ""
        attrs = {
            "path": path,
            "name": name,
            "remote": remote,
            "revision": pin or branch,
        }
        if pin:
            # repo needs the branch to fetch a pinned SHA with `repo sync -c`.
            attrs["upstream"] = f"refs/heads/{branch}"
        project = ET.SubElement(root, "project", attrs)
        if link:
            src, dest = (part.strip() for part in link.split("|", 1))
            ET.SubElement(project, "linkfile", {"src": src, "dest": dest})

    for row in core:
        add_project(row)
    for row in supporting:
        add_project(row)

    ET.indent(root, space="  ")
    out.parent.mkdir(parents=True, exist_ok=True)
    body = ET.tostring(root, encoding="unicode")
    out.write_text('<?xml version="1.0" encoding="UTF-8"?>\n' + body + "\n")
    print(f"wrote {out} ({len(core) + len(supporting)} projects, {len(remove_names)} removals)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
