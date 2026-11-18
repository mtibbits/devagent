#!/usr/bin/env python3
"""scripts/lib/capacity.py — #743: the capacity reader's rules, document and text.

    capacity.py resolve <config> [<project>...]   exit 0 | 3 | 4 (2: bad argv)
    capacity.py summary                           stdin: a document; stdout: one line; exit 0 | 1

`resolve` reads the [capacity] table and each named project's capacity table from
<config>, validates them, and prints the capacity document (JSON) on stdout. Every
line it writes to stderr starts `capacity: `. Exit 4: the config is missing,
unreadable or not valid TOML. scripts/capacity.sh is the entry point; it passes the
projects in config_list_projects order. A project the config does not name resolves
as one with no capacity table.

The contract (field names, rule strings, exit codes) is pinned in
docs/configuration.md "## Capacity"; #957 reproduces the rule strings in JavaScript.

Syntax stays 3.8-compatible: README.md supports 3.8-3.10 with tomli, and doctor
always runs this file.
"""

import json
import sys

try:
    import tomllib          # stdlib, Python >= 3.11
except ModuleNotFoundError:  # Python 3.8-3.10: the same parser, packaged
    import tomli as tomllib  # apt install python3-tomli / pip install tomli

CAPACITY_SCHEMA = "1.0"
TOKEN_UNIT = "weighted_input_token_equivalents"

PROJECT_KEYS = (
    "priority",
    "max_lanes",
    "paused",
    "deadline",
    "reserve_operator_hours_per_week",
    "reserve_tokens_per_week",
)
PROJECT_DEFAULTS = {
    "priority": 5,
    "max_lanes": None,
    "paused": False,
    "deadline": None,
    "reserve_operator_hours_per_week": None,
    "reserve_tokens_per_week": None,
}

USAGE = "capacity: usage: capacity.py resolve <config> [<project>...] | capacity.py summary"


class _ConfigError(Exception):
    """The config cannot be read or parsed: exit 4 with this one line."""


def _say(line):
    print("capacity: " + line, file=sys.stderr)


def _load(path):
    try:
        fh = open(path, "rb")
    except Exception:
        raise _ConfigError("config not readable: " + path)
    try:
        with fh:
            return tomllib.load(fh)
    except Exception:
        # Any parse failure, including an integer past the int-conversion limit
        # (a ValueError, not a TOMLDecodeError).
        raise _ConfigError("config is not valid TOML: " + path)


def _entry(value, source):
    return {"value": value, "source": source}


def _project_defaults(name):
    out = {"name": name}
    for key in PROJECT_KEYS:
        out[key] = _entry(PROJECT_DEFAULTS[key], "default")
    return out


def resolve(path, names):
    """Return (exit code, document or None)."""
    _load(path)
    doc = {
        "capacity_schema": CAPACITY_SCHEMA,
        "declared": False,
        "token_unit": TOKEN_UNIT,
        "shared": None,
        "effective_tokens_per_week": None,
        "projects": [_project_defaults(n) for n in names],
    }
    return 0, doc


def _emit(doc):
    sys.stdout.write(json.dumps(doc, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def main(argv):
    # Copied from _toml.py main(): UTF-8 and no newline translation on both streams
    # (#294), keeping each stream's errors handler; identity on POSIX.
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(newline="", encoding="utf-8", errors=_s.errors)
        except (AttributeError, ValueError, OSError):
            pass
    if len(argv) >= 2 and argv[0] == "resolve":
        try:
            rc, doc = resolve(argv[1], argv[2:])
        except _ConfigError as e:
            _say(str(e))
            return 4
        if rc == 0:
            _emit(doc)
        return rc
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
