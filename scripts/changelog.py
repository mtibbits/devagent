"""Changelog entry files for devAgent (#1127): a repository maintenance tool.

A pull request records its changelog entry as ``changelog.d/<key>.md`` instead
of editing ``## [Unreleased]`` in CHANGELOG.md, so two open pull requests never
edit the same lines. ``<key>`` is the issue number (a positive integer with no
leading zero) or, for a change with no issue, a slug: a lowercase letter, then
lowercase letters, digits and single hyphens. The body is one or more entries
exactly as they read in CHANGELOG.md; each entry's first line starts
``- **<Kind>: `` or ``- **<Kind> (<qualifier>): ``.

    python3 scripts/changelog.py check
    python3 scripts/changelog.py preview
    python3 scripts/changelog.py release <version> <date> [--intro <file>]
    python3 scripts/changelog.py release <version> --fold

``check`` reports every problem in ``changelog.d/`` and exits 1 if it finds
any. Its universe is the filesystem listing of ``changelog.d/`` (not git's
list), because release compiles and deletes what is on disk; a missing folder
reads as empty.

**Waiting** is the entry files, ordered by key (issue numbers from highest to
lowest, then slugs alphabetically; a file's own order kept), followed by any
entries still carried under ``## [Unreleased]``. ``preview`` prints the
``## [Unreleased]`` section that would make. ``release`` writes it as
``## [<version>] — <date>`` between ``## [Unreleased]`` and the newest dated
section (``--intro`` puts a file's prose paragraphs first) and deletes the
entry files it used. ``release <version> --fold`` adds what is waiting to the
newest dated section, which must be ``<version>``, above its first entry.

Every refusal exits 1 and changes nothing; usage errors exit 2. CHANGELOG.md is
written in place, UTF-8 with LF, its bytes restored if the write fails. The
entry files are deleted afterwards, one at a time; if one cannot be, the tool
exits 3 naming it: the release is written, so delete it by hand and do not
re-run release or --fold. Exit 3 also covers a write that failed and could not
be undone. preview, the tag gate, refuses whenever it cannot read
``## [Unreleased]`` as release would, so it never fails open.

This is not a plugin command and not a workflow step: next.sh's role detection
reads only ``scripts/<step>.sh``. Stdlib only, Python 3.8 or later.
"""

from __future__ import annotations

import argparse
import datetime
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

VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")  # .fullmatch
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")  # .fullmatch, then datetime.date.fromisoformat
SECTION = re.compile(r"## \[(?P<version>[^\]]+)\]")  # .match on col-0 lines
DATED = re.compile(r"## \[(?P<version>[^\]]+)\] — (?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})")  # .fullmatch
UNRELEASED = "## [Unreleased]"

NO_KIND = "an entry with no listed kind (%s)" % ", ".join(KINDS)
PROSE = "prose outside an entry"
HEADING = "a heading"
ONLY_ENTRIES = "changelog.d/ holds only entry files"
NOTHING_WAITING = (
    "nothing is waiting: no entry files in changelog.d/ and no entries under ## [Unreleased]"
)


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


# --- CHANGELOG.md --------------------------------------------------------------------


class Refusal(Exception):
    """A refusal: its lines are printed to stderr and the tool exits ``code``."""

    def __init__(self, *lines, code=1):
        super().__init__(*lines)
        self.lines = lines
        self.code = code


def _plural(count, one, many):
    return "%d %s" % (count, one if count == 1 else many)


def _read_changelog(root):
    path = Path(root) / "CHANGELOG.md"
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise Refusal("could not read CHANGELOG.md (%s)" % exc.strerror)
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise Refusal("CHANGELOG.md is not UTF-8")
    return path, data, _lines(text)


def _unreleased(lines):
    """-> (u, end): the ``## [Unreleased]`` line and the first col-0 ``## `` after it
    (the newest section's heading, or len(lines)).

    Refuses when there is no such exact line, or when there are two: the second
    one's entries would sit outside the span every command reads, so a release
    would leave them unreleased while preview reported nothing waiting. preview
    is README's tag gate, so it refuses here too rather than fail open."""
    try:
        u = lines.index(UNRELEASED)
    except ValueError:
        raise Refusal("CHANGELOG.md has no '%s' line" % UNRELEASED)
    for i in range(u + 1, len(lines)):
        if lines[i] == UNRELEASED:
            raise Refusal(
                "CHANGELOG.md line %d: a second '%s' line; move its entries under the "
                "first and delete it" % (i + 1, UNRELEASED)
            )
    end = next((i for i in range(u + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return u, end


def _waiting(root, lines, span, command):
    """Everything waiting, in release order -> (files, entries).

    The entry files by key (file-internal order kept), then the entries carried
    under ``## [Unreleased]`` in document order. Refuses on a check problem or
    on anything but entries under ``## [Unreleased]``."""
    files, problems = scan(root)
    if problems:
        raise Refusal(*problems, "%s refused: fix the changelog.d/ problems above" % command)
    u, end = span
    carried, bad = parse_entries(lines[u + 1 : end])
    if bad:
        raise Refusal(
            *("CHANGELOG.md line %d: %s under %s" % (u + 1 + n, why, UNRELEASED) for n, why in bad)
        )
    entries = [entry for _name, file_entries in files for entry in file_entries] + carried
    return files, entries


def _join(entries):
    """Entries as lines, separated by exactly one blank line (preview and release)."""
    out = []
    for entry in entries:
        if out:
            out.append("")
        out.extend(entry)
    return out


def _read_intro(name):
    try:
        data = Path(name).read_bytes()
    except OSError as exc:
        raise Refusal("--intro %s: could not read (%s)" % (name, exc.strerror))
    try:
        lines = _lines(data.decode("utf-8-sig"))
    except UnicodeDecodeError:
        raise Refusal("--intro %s: not UTF-8" % name)
    for number, line in enumerate(lines, 1):
        if line.startswith("#") or ENTRY_HEAD.match(line):
            raise Refusal(
                "--intro %s: line %d is a heading or an entry's first line; the intro is prose"
                % (name, number)
            )
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        raise Refusal("--intro %s: empty" % name)
    return lines


def _check_version(version):
    if not VERSION.fullmatch(version):
        raise Refusal("'%s' is not a plain X.Y.Z version" % version)


def _check_date(date):
    try:
        ok = bool(DATE.fullmatch(date)) and bool(datetime.date.fromisoformat(date))
    except ValueError:
        ok = False
    if not ok:
        raise Refusal("'%s' is not a YYYY-MM-DD date" % date)


def _holds(path, data):
    """True when path reads back as exactly data."""
    try:
        return path.read_bytes() == data
    except OSError:
        return False


def _write(root, path, original, lines, files):
    """Write CHANGELOG.md (UTF-8, LF), restoring its bytes on failure, then delete
    each used entry file on its own. -> the number of files deleted.

    Exit 1 means nothing changed, so a failed write reads the file back: untouched
    (a read-only or locked file) or restored is exit 1; a file left changed is a
    partial state, exit 3, like a failed delete."""
    try:
        path.write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
    except OSError as exc:
        if _holds(path, original):
            raise Refusal(
                "could not write CHANGELOG.md (%s); it is unchanged and no entry file is deleted"
                % exc.strerror
            )
        try:
            path.write_bytes(original)
        except OSError:
            pass
        if _holds(path, original):
            raise Refusal(
                "could not write CHANGELOG.md (%s); it is restored and no entry file is deleted"
                % exc.strerror
            )
        raise Refusal(
            "could not write CHANGELOG.md (%s) nor restore it; compare it with git before "
            "anything else — no entry file is deleted" % exc.strerror,
            code=3,
        )
    left = []
    for name, _entries in files:
        try:
            (Path(root) / "changelog.d" / name).unlink()
        except FileNotFoundError:
            pass
        except OSError:
            left.append("changelog.d/" + name)
    if left:
        raise Refusal(
            "the release is written; delete these files by hand — do not re-run release "
            "or --fold: " + ", ".join(left),
            code=3,
        )
    return len(files)


def preview(root):
    """The ``## [Unreleased]`` section everything waiting would make, as text."""
    _path, _data, lines = _read_changelog(root)
    _files, entries = _waiting(root, lines, _unreleased(lines), "preview")
    if not entries:
        return UNRELEASED + "\n"
    return "\n".join([UNRELEASED, ""] + _join(entries)) + "\n"


def release(root, version, date, intro=None):
    """Write ``## [<version>] — <date>`` from everything waiting -> a report line."""
    _check_version(version)
    _check_date(date)
    path, original, lines = _read_changelog(root)
    span = _unreleased(lines)
    u, end = span
    newest = DATED.fullmatch(lines[end]) if end < len(lines) else None
    for line in lines:
        found = SECTION.match(line)
        if found and found.group("version") == version:
            if newest and newest.group("version") == version:
                raise Refusal(
                    "CHANGELOG.md already has a section for %s; add to it with release %s "
                    "--fold before it is tagged, or release a new version" % (version, version)
                )
            raise Refusal("CHANGELOG.md already has a section for %s; release a new version" % version)
    files, entries = _waiting(root, lines, span, "release")
    if not entries:
        raise Refusal(NOTHING_WAITING)
    intro_lines = _read_intro(intro) + [""] if intro is not None else []
    heading = "## [%s] — %s" % (version, date)
    out = lines[:u] + [UNRELEASED, "", heading, ""] + intro_lines + _join(entries)
    if end < len(lines):
        out += [""] + lines[end:]
    deleted = _write(root, path, original, out, files)
    return "wrote %s: %s, %s deleted" % (
        heading,
        _plural(len(entries), "entry", "entries"),
        _plural(deleted, "entry file", "entry files"),
    )


def fold(root, version):
    """Add everything waiting to the newest dated section, which must be <version>.

    The entries go above the section's first entry and below its opening prose;
    the date and the prose are unchanged -> a report line."""
    _check_version(version)
    path, original, lines = _read_changelog(root)
    span = _unreleased(lines)
    u, end = span
    newest = DATED.fullmatch(lines[end]) if end < len(lines) else None
    if not newest or newest.group("version") != version:
        raise Refusal(
            "--fold adds only to the newest dated section, which is %s, not %s; "
            "release a new version instead" % (newest.group("version") if newest else "none", version)
        )
    files, entries = _waiting(root, lines, span, "release")
    if not entries:
        raise Refusal(NOTHING_WAITING)
    nxt = next((i for i in range(end + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    body = lines[end + 1 : nxt]
    first = next((i for i, line in enumerate(body) if ENTRY_HEAD.match(line)), None)
    if first is not None:
        body = body[:first] + _join(entries) + [""] + body[first:]
    else:
        while body and not body[-1].strip():
            body.pop()
        body = body + [""] + _join(entries) + ([""] if nxt < len(lines) else [])
    out = lines[:u] + [UNRELEASED, "", lines[end]] + body + lines[nxt:]
    deleted = _write(root, path, original, out, files)
    return "folded %s into %s: %s deleted" % (
        _plural(len(entries), "entry", "entries"),
        lines[end],
        _plural(deleted, "entry file", "entry files"),
    )


# --- command line ------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        prog=PROG,
        allow_abbrev=False,
        description="Check and release changelog.d/ entry files (#1127).",
    )
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True
    sub.add_parser("check", help="report every problem in changelog.d/", allow_abbrev=False)
    sub.add_parser(
        "preview", help="print the ## [Unreleased] section a release would write", allow_abbrev=False
    )
    rel = sub.add_parser(
        "release",
        help="write the next dated section, or --fold into the newest one",
        allow_abbrev=False,
    )
    rel.add_argument("version", help="plain X.Y.Z")
    rel.add_argument("date", nargs="?", help="YYYY-MM-DD; omitted with --fold")
    rel.add_argument("--intro", metavar="file", help="the section's opening prose")
    rel.add_argument(
        "--fold", action="store_true", help="add what is waiting to the newest dated section"
    )
    return parser


def validate_args(ns):
    """The rules argparse cannot state; a breach is a usage error (exit 2)."""
    if ns.command == "release":
        reason = None
        if ns.fold and ns.date is not None:
            reason = "release --fold takes no date; the section keeps its own"
        elif ns.fold and ns.intro is not None:
            reason = "release --fold takes no --intro; the section keeps its opening prose"
        elif not ns.fold and ns.date is None:
            reason = "release needs a <date>, or --fold"
        if reason:
            build_parser().error(reason)
    return ns


def _say(stream, message):
    stream.write(PROG + ": " + message + "\n")


def main(argv=None, root=None):
    root = ROOT if root is None else Path(root)
    try:
        ns = validate_args(build_parser().parse_args(argv))
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    try:
        if ns.command == "check":
            files, problems = scan(root)
            if problems:
                raise Refusal(*problems)
            _say(sys.stdout, "no problems in " + _plural(len(files), "entry file", "entry files"))
        elif ns.command == "preview":
            sys.stdout.write(preview(root))
        elif ns.fold:
            _say(sys.stdout, fold(root, ns.version))
        else:
            _say(sys.stdout, release(root, ns.version, ns.date, ns.intro))
    except Refusal as refusal:
        for line in refusal.lines:
            _say(sys.stderr, line)
        return refusal.code
    return 0


if __name__ == "__main__":
    for _stream in (sys.stdout, sys.stderr):
        _stream.reconfigure(encoding="utf-8", newline="\n")
    sys.exit(main())
