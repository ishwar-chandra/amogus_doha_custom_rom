#!/usr/bin/env python3
"""Format the incremental tail of the remote build log for `tools/gcp-build.sh logs`.

The caller fetches bytes in chunks. This helper keeps the incomplete last line
in --pending, so a line split by a network chunk is still printed once. It
wraps long lines to the terminal width, hides build-system chatter, collapses
repeated warnings/info, and shows ninja percentages as a progress bar.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import textwrap

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[1;31m"
YELLOW = "\033[1;33m"
GREEN = "\033[1;32m"
CYAN = "\x1b[1;36m"
BLUE = "\033[1;34m"

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
PROGRESS_RE = re.compile(
    r"^\s*\[\s*(\d{1,3})%\s*(?:(\d+)\s*/\s*(\d+))?\s*\]\s*(.*)$"
)
EXIT_RE = re.compile(r"build\.sh exited\s+(\d+)")
ERROR_RE = re.compile(
    r"(?i)(^\s*(error|fatal)\s*:|\berror:\s|^\s*FAILED\b|ninja:\s*error:"
    r"|ninja:\s*build stopped|kati failed|failed to build"
    r"|\*\*\*.*error|undefined reference|No rule to make target"
    r"|\bexception\b|Permission denied|avc:\s*denied|SELinux.*denied)"
)
WARN_RE = re.compile(
    r"(?i)(^\s*warning\s*:|\bwarning\b|No such file or directory"
    r"|deprecated|Trying dependencies-only)"
)
SUCCESS_RE = re.compile(
    r"(?i)(build completed successfully|Build Succeeded|"
    r"#### build completed|install ok:|Successfully installed)"
)
PHASE_RE = re.compile(
    r"(?i)^\s*(repo (init|sync)|applying patches|patched |unchanged |"
    r"breakfast|mka |starting |building |install(ing)? |running |"
    r"generating |target |soong|kati|bootstrap)"
)
NOISE_RE = re.compile(
    r"(?i)(^\s*(ninja: no work to do|ninja: entering directory|"
    r"TARGET_BUILD_VARIANT|TARGET_ARCH|TARGET_CPU|HOST_OS|HOST_CROSS_OS|"
    r"BUILD_ID|OUT_DIR|PRODUCT_SOONG_NAMESPACES|SOONG_|PLATFORM_VERSION|"
    r"SISO_EXPERIMENTS|"
    r"============================================)|"
    r"trace_sys_linux|memory stall|Adding CUSTOM_LOCALES|"
    r"out/soong/release-config/.*was modified|"
    r"ninja:\s*(SISO|ignore|Entering|no work)|ninja:\s*$)"
)


def paint(on: bool, code: str) -> str:
    return code if on else ""


def terminal_width() -> int:
    return max(60, min(160, shutil.get_terminal_size((110, 24)).columns))


def gutter(on: bool) -> str:
    return f"{paint(on, DIM)}│{paint(on, RESET)} "


def classify(text: str):
    clean = ANSI_RE.sub("", text).replace("\r", "").rstrip()
    if not clean.strip():
        return "blank", clean
    exit_match = EXIT_RE.search(clean)
    if exit_match:
        return ("success", clean) if exit_match.group(1) == "0" else ("error", clean)
    if ERROR_RE.search(clean):
        return "error", clean
    progress = PROGRESS_RE.match(clean)
    if progress:
        if progress.group(4).lstrip().startswith("including "):
            return "noise", clean
        return "progress", progress
    if SUCCESS_RE.search(clean):
        return "success", clean
    if WARN_RE.search(clean):
        return "warning", clean
    if NOISE_RE.search(clean):
        return "noise", clean
    if PHASE_RE.search(clean):
        return "phase", clean
    return "info", clean


def write_block(out, on, width, icon, icon_color, text_color, value):
    """Wrap a line to the terminal width with a hanging indent."""
    available = max(20, width - 4)          # "│ " + icon/2 spaces
    parts = textwrap.wrap(
        value.expandtabs(4),
        width=available,
        break_long_words=True,
        break_on_hyphens=False,
    ) or [""]
    for index, part in enumerate(parts):
        if index == 0:
            lead = (f"{paint(on, DIM)}│{paint(on, RESET)} "
                    f"{paint(on, icon_color)}{icon}{paint(on, RESET)} ")
        else:
            lead = f"{paint(on, DIM)}│{paint(on, RESET)}   "
        out.write(f"{lead}{paint(on, text_color)}{part}{paint(on, RESET)}\n")


def emit(out, on, width, kind, value, last_pct, wrote):
    if kind in ("blank", "noise"):
        return last_pct, False

    if kind == "progress":
        match = value
        pct = int(match.group(1))
        done = int(match.group(2) or 0)
        total = int(match.group(3) or 0)
        target = match.group(4).strip()
        if last_pct is not None and pct == last_pct and pct < 100:
            return last_pct, False
        bar_width = min(20, max(8, width - 58))
        filled = min(bar_width, max(0, round(pct * bar_width / 100)))
        bar = "▰" * filled + "▱" * (bar_width - filled)
        counts = f"{done}/{total}" if total else ""
        counts = counts[:15]
        room = max(12, width - 50)
        if len(target) > room:
            target = target[: room - 1] + "…"
        out.write(
            f"{gutter(on)}{paint(on, BLUE)}{bar}{paint(on, RESET)} "
            f"{paint(on, BOLD)}{pct:3d}%{paint(on, RESET)} "
            f"{paint(on, DIM)}{counts}{paint(on, RESET)} {target}\n"
        )
        return pct, True

    if kind == "phase":
        if wrote:
            out.write("\n")
        write_block(out, on, width, "▸", CYAN, CYAN, value)
        return last_pct, True
    if kind == "success":
        if wrote:
            out.write("\n")
        write_block(out, on, width, "✔", GREEN, GREEN, value)
        return last_pct, True
    if kind == "error":
        write_block(out, on, width, "✖", RED, RED, value)
        return last_pct, True
    if kind == "warning":
        write_block(out, on, width, "▲", YELLOW, YELLOW, value)
        return last_pct, True
    write_block(out, on, width, "·", DIM, "", value)
    return last_pct, True


def dedupe_key(kind, value):
    if kind not in ("warning", "info", "phase"):
        return None
    key = re.sub(r"^\d{2}:\d{2}:\d{2}\s+", "", value)
    key = re.sub(r"\s+", " ", key.strip())
    return key or None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("chunk", nargs="?")
    parser.add_argument("--pending", default="")
    parser.add_argument("--state", default="")
    parser.add_argument("--seen", default="")
    parser.add_argument("--skip-first", action="store_true")
    parser.add_argument("--flush", action="store_true")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    args = parser.parse_args()

    if args.color == "always":
        on = True
    elif args.color == "never":
        on = False
    else:
        on = bool(sys.stdout.isatty()) and not os.environ.get("NO_COLOR")
    if os.environ.get("FORCE_COLOR", "").lower() in ("1", "true", "yes", "always"):
        on = True

    pending = ""
    if args.pending:
        try:
            with open(args.pending, "r", encoding="utf-8", errors="replace") as f:
                pending = f.read()
        except FileNotFoundError:
            pass

    chunk = ""
    if args.chunk:
        with open(args.chunk, "r", encoding="utf-8", errors="replace") as f:
            chunk = f.read()
    elif not args.flush:
        chunk = sys.stdin.read()

    data = pending + chunk
    if data and data.endswith("\n"):
        body, tail = data, ""
    else:
        cut = data.rfind("\n")
        body, tail = (data[: cut + 1], data[cut + 1:]) if cut >= 0 else ("", data)

    lines = body.splitlines()
    if args.skip_first and lines:
        lines = lines[1:]

    seen = set()
    if args.seen:
        try:
            with open(args.seen, "r", encoding="utf-8", errors="replace") as f:
                seen = {line.rstrip("\n") for line in f if line.strip()}
        except FileNotFoundError:
            pass

    last_pct = None
    if args.state:
        try:
            with open(args.state, "r", encoding="ascii") as f:
                last_pct = int(f.read().strip())
        except (FileNotFoundError, ValueError):
            last_pct = None

    width = terminal_width()
    wrote = False
    for line in lines:
        kind, value = classify(line)
        key = dedupe_key(kind, value)
        if key is not None:
            if key in seen:
                continue
            seen.add(key)
        last_pct, printed = emit(
            sys.stdout, on, width, kind, value, last_pct, not wrote
        )
        wrote = wrote or printed

    if args.flush and tail:
        kind, value = classify(tail)
        key = dedupe_key(kind, value)
        if key is None or key not in seen:
            if key is not None:
                seen.add(key)
            last_pct, printed = emit(
                sys.stdout, on, width, kind, value, last_pct, not wrote
            )
            wrote = wrote or printed
        tail = ""

    if args.pending:
        with open(args.pending, "w", encoding="utf-8") as f:
            f.write(tail)
    if args.state:
        with open(args.state, "w", encoding="ascii") as f:
            f.write("" if last_pct is None else str(last_pct))
    if args.seen:
        with open(args.seen, "w", encoding="utf-8") as f:
            for key in list(seen)[-400:]:
                f.write(key + "\n")

    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
