#!/usr/bin/env python3
"""Format the incremental tail of the remote build log for `tools/gcp-build.sh logs`.

The caller fetches bytes in chunks. This helper keeps the incomplete last line
in --pending, so a line split by a network chunk is still printed once, and it
collapses repeated ninja percentages so the output stays readable.

Colors are emitted only when asked (auto = stdout is a TTY, or FORCE_COLOR).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[1;31m"
YELLOW = "\033[1;33m"
GREEN = "\033[1;32m"
CYAN = "\033[1;36m"
BLUE = "\033[1;34m"

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
PROGRESS_RE = re.compile(
    r"^\s*\[\s*(\d{1,3})%\s*(?:(\d+)\s*/\s*(\d+))?\s*\]\s*(.*)$"
)
EXIT_RE = re.compile(r"build\.sh exited\s+(\d+)")
ERROR_RE = re.compile(
    r"(?i)(^\s*(error|fatal)\s*:|^\s*FAILED\b|ninja:\s*error:"
    r"|ninja:\s*build stopped|\*\*\*.*error|undefined reference"
    r"|No rule to make target|\bexception\b|Permission denied"
    r"|avc:\s*denied|SELinux.*denied)"
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
    r"(?i)^\s*(ninja: no work to do|ninja: entering directory|"
    r"TARGET_BUILD_VARIANT|TARGET_ARCH|TARGET_CPU|HOST_OS|HOST_CROSS_OS|"
    r"BUILD_ID|OUT_DIR|PRODUCT_SOONG_NAMESPACES|SOONG_|PLATFORM_VERSION|"
    r"============================================)"
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


def emit(kind, value, on: bool, width: int, last_pct, first_line: bool):
    """Print one classified line. Returns the new last_pct and whether anything
    was written."""
    out = sys.stdout
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
        room = max(12, width - 36)
        if len(target) > room:
            target = target[: room - 1] + "…"
        out.write(
            f"{gutter(on)}{paint(on, BLUE)}{bar}{paint(on, RESET)} "
            f"{paint(on, BOLD)}{pct:3d}%{paint(on, RESET)} "
            f"{paint(on, DIM)}{counts}{paint(on, RESET)} {target}\n"
        )
        return pct, True

    if kind == "phase":
        if not first_line:
            out.write("\n")
        out.write(f"{gutter(on)}{paint(on, CYAN)}▸{paint(on, RESET)} "
                  f"{paint(on, CYAN)}{value}{paint(on, RESET)}\n")
        return last_pct, True
    if kind == "success":
        if not first_line:
            out.write("\n")
        out.write(f"{gutter(on)}{paint(on, GREEN)}✔{paint(on, RESET)} "
                  f"{paint(on, GREEN)}{paint(on, BOLD)}{value}{paint(on, RESET)}\n")
        return last_pct, True
    if kind == "error":
        out.write(f"{gutter(on)}{paint(on, RED)}✖{paint(on, RESET)} "
                  f"{paint(on, RED)}{value}{paint(on, RESET)}\n")
        return last_pct, True
    if kind == "warning":
        out.write(f"{gutter(on)}{paint(on, YELLOW)}▲{paint(on, RESET)} "
                  f"{paint(on, YELLOW)}{value}{paint(on, RESET)}\n")
        return last_pct, True
    out.write(f"{gutter(on)}{paint(on, DIM)}·{paint(on, RESET)} {value}\n")
    return last_pct, True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("chunk", nargs="?")
    parser.add_argument("--pending", default="")
    parser.add_argument("--state", default="")
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
        last_pct, printed = emit(kind, value, on, width, last_pct, not wrote)
        wrote = wrote or printed

    if args.flush and tail:
        kind, value = classify(tail)
        last_pct, printed = emit(kind, value, on, width, last_pct, not wrote)
        wrote = wrote or printed
        tail = ""

    if args.pending:
        with open(args.pending, "w", encoding="utf-8") as f:
            f.write(tail)
    if args.state:
        with open(args.state, "w", encoding="ascii") as f:
            f.write("" if last_pct is None else str(last_pct))

    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
