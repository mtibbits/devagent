#!/usr/bin/env python3
"""Read and write the disk issue file format (#1008).

One issue per file, `<folder>/<N>.md`. This module is the one parser and the
one writer that the disk issue backend, doctor, `wbs init --from-tracker` and
the publish/import converters share, so they can never disagree about what a
file means. The format is documented in docs/disk-issues.md.

    disk-issue.py parse <file>
    disk-issue.py list <folder>
    disk-issue.py check <file>...
    disk-issue.py set <file> key=value... [--unset key]... [--comment <text>] [--date <YYYY-MM-DD>]
    disk-issue.py create <folder> <N> <title> <prompt-file> [key=value...]

Exit codes: 0 ok; 1 an I/O failure, or the file changed underneath; 2 usage, or
a refused value or prompt; 3 `create` found the file already there; 4 the file
fails the check (and was not written).

Python 3.8 floor, stdlib only.
"""
from __future__ import annotations

import os
import re
import sys

KEYS = ("state", "status", "parent", "labels", "github")
MAX_UNCLOSED = 1000
_IS_WINDOWS = os.name == "nt"
_LOCK_WAIT_S = 5.0
_REPLACE_RETRY_S = 1.0

EXIT_OK, EXIT_IO, EXIT_USAGE, EXIT_EXISTS, EXIT_FAULTY = 0, 1, 2, 3, 4

USAGE = (
    "usage: disk-issue.py parse <file>\n"
    "       disk-issue.py list <folder>\n"
    "       disk-issue.py check <file>...\n"
    "       disk-issue.py set <file> key=value... [--unset key]... [--comment <text>] [--date <YYYY-MM-DD>]\n"
    "       disk-issue.py create <folder> <N> <title> <prompt-file> [key=value...]\n"
)

_ISSUE_NAME_RE = re.compile(r"^[1-9][0-9]*\.md$")


class Fail(Exception):
    """A failure with its exit code; main prints `disk-issue: <msg>` to stderr."""

    def __init__(self, code: int, msg: str = "", usage: bool = False):
        super().__init__(msg)
        self.code = code
        self.msg = msg
        self.usage = usage


def _usage_error(msg: str) -> Fail:
    return Fail(EXIT_USAGE, msg, usage=True)


def _err(text: str) -> None:
    sys.stderr.write(text)
    sys.stderr.flush()


def _out(text: str) -> None:
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


def _issue_file_arg(arg: str) -> str:
    if not _ISSUE_NAME_RE.match(os.path.basename(arg)):
        raise _usage_error(f'file name must be <N>.md, got "{arg}"')
    return arg


# ------------------------------------------------------------------ CLI grammar

def _parse_kv(tokens: list, seen: dict) -> None:
    """Fold `key=value` tokens into `seen`; usage errors for the rest."""
    for tok in tokens:
        if "=" not in tok:
            raise _usage_error(f'expected key=value, got "{tok}"')
        key, value = tok.split("=", 1)
        if key not in KEYS:
            raise _usage_error(f'unknown key "{key}"')
        if key in seen:
            raise _usage_error(f'"{key}" given twice')
        if "\r" in value or "\n" in value:
            raise _usage_error(f'"{key}" value contains a line break')
        value = value.strip(" \t")
        if not value:
            raise _usage_error(f'empty value for "{key}"')
        seen[key] = value


def _parse_set_args(args: list) -> tuple:
    """`set <file> key=value... [--unset key]... [--comment t] [--date d]`."""
    if not args:
        raise _usage_error("set needs a file")
    path = _issue_file_arg(args[0])
    sets: dict = {}
    unsets: set = set()
    comment = None
    date = None
    kv: list = []
    i = 1
    while i < len(args):
        tok = args[i]
        if tok in ("--unset", "--comment", "--date"):
            if i + 1 >= len(args):
                raise _usage_error(f"{tok} needs a value")
            val = args[i + 1]          # taken verbatim, even if it starts with "-"
            if tok == "--unset":
                if val not in KEYS:
                    raise _usage_error(f'unknown key "{val}"')
                unsets.add(val)
            elif tok == "--comment":
                if comment is not None:
                    raise _usage_error('"--comment" given twice')
                comment = val
            else:
                if date is not None:
                    raise _usage_error('"--date" given twice')
                date = val
            i += 2
            continue
        if tok.startswith("--"):
            raise _usage_error(f'unknown option "{tok}"')
        kv.append(tok)
        i += 1
    _parse_kv(kv, sets)
    for key in sets:
        if key in unsets:
            raise _usage_error(f'"{key}" is both set and unset')
    if date is not None and comment is None:
        raise _usage_error("--date needs --comment")
    if not sets and not unsets and comment is None:
        raise _usage_error("nothing to change")
    return path, sets, unsets, comment, date


# ------------------------------------------------------------------ verbs

def cmd_parse(args: list) -> int:
    if len(args) != 1:
        raise _usage_error("parse takes one file")
    _issue_file_arg(args[0])
    raise Fail(EXIT_IO, "parse: not implemented")


def cmd_check(args: list) -> int:
    if not args:
        raise _usage_error("check needs at least one file")
    for a in args:
        _issue_file_arg(a)
    raise Fail(EXIT_IO, "check: not implemented")


def cmd_list(args: list) -> int:
    if len(args) != 1:
        raise _usage_error("list takes one folder")
    raise Fail(EXIT_IO, "list: not implemented")


def cmd_set(args: list) -> int:
    _parse_set_args(args)
    raise Fail(EXIT_IO, "set: not implemented")


def cmd_create(args: list) -> int:
    raise Fail(EXIT_IO, "create: not implemented")


VERBS = {
    "parse": cmd_parse,
    "list": cmd_list,
    "check": cmd_check,
    "set": cmd_set,
    "create": cmd_create,
}


def main(argv: list) -> int:
    if not argv:
        _err(USAGE)
        return EXIT_USAGE
    verb, rest = argv[0], argv[1:]
    try:
        fn = VERBS.get(verb)
        if fn is None:
            raise _usage_error(f'unknown verb "{verb}"')
        return fn(rest)
    except Fail as e:
        if e.msg:
            _err(f"disk-issue: {e.msg}\n")
        if e.usage:
            _err(USAGE)
        return e.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
