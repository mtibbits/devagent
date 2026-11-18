"""Changelog entry files for devAgent (#1127): a repository maintenance tool.

A pull request records its changelog entry as ``changelog.d/<key>.md`` instead
of editing ``## [Unreleased]`` in CHANGELOG.md, so two open pull requests never
edit the same lines. ``<key>`` is the issue number (a positive integer with no
leading zero) or, for a change with no issue, a slug: a lowercase letter, then
lowercase letters, digits and single hyphens. The body is one or more entries
exactly as they read in CHANGELOG.md; each entry's first line starts
``- **<Kind>: `` or ``- **<Kind> (<qualifier>): ``.

    python3 scripts/changelog.py check

``check`` reports every problem in ``changelog.d/`` and exits 1 if it finds
any. Its universe is the filesystem listing of ``changelog.d/`` (not git's
list), because release compiles and deletes what is on disk; a missing folder
reads as empty.

This is not a plugin command and not a workflow step: next.sh's role detection
reads only ``scripts/<step>.sh``. Stdlib only, Python 3.8 or later.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROG = "changelog"

KINDS = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security", "Docs")
ENTRY_HEAD = re.compile(r"- \*\*(?:%s)(?: \([a-z]+(?: [a-z]+)*\))?: " % "|".join(KINDS))  # .match
ISSUE_KEY = re.compile(r"[1-9][0-9]*")  # .fullmatch
SLUG_KEY = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*")  # .fullmatch

NO_KIND = "an entry with no listed kind (%s)" % ", ".join(KINDS)
PROSE = "prose outside an entry"
HEADING = "a heading"
ONLY_ENTRIES = "changelog.d/ holds only entry files"


# --- the entry grammar ---------------------------------------------------------


def parse_entries(lines):
    """Split lines into entries -> (entries, problems).

    The ONE grammar, used for entry files and for the ``## [Unreleased]`` span.
    Each entry is a list of its lines, text never rewritten. ``problems`` is a
    list of ``(line_no, reason)`` with 1-based line numbers. An entry starts at
    a line matching ENTRY_HEAD and continues over indented lines; a blank line
    is kept only when an indented line follows inside an entry, so an entry
    ends at a blank line followed by the next entry's first line, or at the end.
    """
    entries = []
    problems = []
    current = None  # the open entry's lines
    pending = []  # blank lines seen inside the open entry
    swallowing = False  # inside a no-kind entry: its indented lines are not reported
    for number, line in enumerate(lines, 1):
        if not line.strip():
            if current is not None:
                pending.append(line)
            continue
        if ENTRY_HEAD.match(line):
            current = [line]
            entries.append(current)
            pending = []
            swallowing = False
            continue
        if line[0] in " \t":
            if current is not None:
                current.extend(pending)
                pending = []
                current.append(line)
            elif not swallowing:
                problems.append((number, PROSE))
            continue
        current = None
        pending = []
        swallowing = False
        if line.startswith("- "):
            problems.append((number, NO_KIND))
            swallowing = True
        elif line.startswith("#"):
            problems.append((number, HEADING))
        else:
            problems.append((number, PROSE))
    return entries, problems


def _lines(text):
    """Text -> lines without terminators; CRLF reads as LF."""
    lines = text.replace("\r\n", "\n").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


# --- changelog.d/ ----------------------------------------------------------------


def _key_problem(stem):
    if stem.isdigit() and stem.isascii():
        if int(stem) == 0:
            return "the issue number must be a positive integer"
        if not ISSUE_KEY.fullmatch(stem):
            return "the issue number has a leading zero"
        return None
    if not SLUG_KEY.fullmatch(stem):
        return (
            "the slug must start with a letter and use only lowercase letters, "
            "digits and single hyphens"
        )
    return None


def _sort_key(stem):
    """Issue numbers from highest to lowest, then slugs in alphabetical order."""
    if ISSUE_KEY.fullmatch(stem):
        return (0, -int(stem), "")
    return (1, 0, stem)


def scan(root):
    """Read changelog.d/ -> (files, problems).

    ``files`` is a list of ``(name, entries)`` for the entry files that read
    cleanly, in release order; ``problems`` is a list of message strings in
    name order (a file's name problem first, then its body problems). A child
    that vanishes between the listing and its lstat or read counts as gone.
    """
    folder = Path(root) / "changelog.d"
    try:
        st = os.lstat(folder)
    except FileNotFoundError:
        return [], []
    if not stat.S_ISDIR(st.st_mode):
        return [], ["changelog.d: not a directory"]
    files = []
    problems = []
    for name in sorted(os.listdir(folder)):
        path = folder / name
        where = "changelog.d/" + name
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(st.st_mode):
            problems.append("%s: a symlink; %s" % (where, ONLY_ENTRIES))
            continue
        if stat.S_ISDIR(st.st_mode):
            problems.append("%s: a subdirectory; %s" % (where, ONLY_ENTRIES))
            continue
        if not stat.S_ISREG(st.st_mode) or not name.endswith(".md"):
            problems.append("%s: not a .md file; %s" % (where, ONLY_ENTRIES))
            continue
        stem = name[: -len(".md")]
        before = len(problems)
        reason = _key_problem(stem)
        if reason:
            problems.append("%s: %s" % (where, reason))
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            del problems[before:]
            continue
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            problems.append("%s: not UTF-8" % where)
            continue
        lines = _lines(text)
        if not any(line.strip() for line in lines):
            problems.append("%s: empty; an entry file holds one or more entries" % where)
            continue
        entries, body = parse_entries(lines)
        for number, why in body:
            problems.append("%s: line %d: %s" % (where, number, why))
        if len(problems) == before:
            files.append((stem, name, entries))
    files.sort(key=lambda f: _sort_key(f[0]))
    return [(name, entries) for _stem, name, entries in files], problems


def check(root):
    """Every changelog.d/ problem, in name order; [] when there is none."""
    return scan(root)[1]


# --- command line ------------------------------------------------------------------


def _plural(count, one, many):
    return "%d %s" % (count, one if count == 1 else many)


def build_parser():
    parser = argparse.ArgumentParser(
        prog=PROG,
        allow_abbrev=False,
        description="Check changelog.d/ entry files (#1127).",
    )
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True
    sub.add_parser("check", help="report every problem in changelog.d/", allow_abbrev=False)
    return parser


def validate_args(ns):
    """The rules argparse cannot state; a breach is a usage error (exit 2)."""
    return ns


def _say(stream, message):
    stream.write(PROG + ": " + message + "\n")


def main(argv=None, root=None):
    root = ROOT if root is None else Path(root)
    try:
        ns = validate_args(build_parser().parse_args(argv))
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    if ns.command == "check":
        files, problems = scan(root)
        for problem in problems:
            _say(sys.stderr, problem)
        if problems:
            return 1
        _say(sys.stdout, "no problems in " + _plural(len(files), "entry file", "entry files"))
        return 0
    return 2  # pragma: no cover - argparse admits only the commands above


if __name__ == "__main__":
    for _stream in (sys.stdout, sys.stderr):
        _stream.reconfigure(encoding="utf-8", newline="\n")
    sys.exit(main())
