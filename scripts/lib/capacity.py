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

import datetime
import json
import math
import sys

try:
    import tomllib          # stdlib, Python >= 3.11
except ModuleNotFoundError:  # Python 3.8-3.10: the same parser, packaged
    import tomli as tomllib  # apt install python3-tomli / pip install tomli

CAPACITY_SCHEMA = "1.0"
TOKEN_UNIT = "weighted_input_token_equivalents"

# The shared keys, in the order the document lists them; every one but the last is
# required.
SHARED_KEYS = (
    "operator_hours_per_week",
    "lane_hours_per_week",
    "max_lanes",
    "tokens_per_week",
    "tokens_per_window",
    "windows_per_week",
    "operator_hours_per_agent_hour",
)
BINDING_WEEK = "tokens_per_week"
BINDING_WINDOWS = "tokens_per_window_x_windows_per_week"

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
NOT_DECLARED = "not declared (forecasting off)"


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


def _doc_value(value):
    """A config value as the document writes it: a date as YYYY-MM-DD."""
    if isinstance(value, datetime.date):
        return value.isoformat()
    return value


def _project(name, table):
    """One element of `projects`: the six keys from `table` (None: no capacity table)."""
    out = {"name": name}
    for key in PROJECT_KEYS:
        if isinstance(table, dict) and key in table:
            out[key] = _entry(_doc_value(table[key]), "config")
        else:
            out[key] = _entry(PROJECT_DEFAULTS[key], "default")
    return out


def _effective(cap):
    """min(tokens_per_week, tokens_per_window * windows_per_week); a tie binds on
    tokens_per_week."""
    week = cap["tokens_per_week"]
    windows = cap["tokens_per_window"] * cap["windows_per_week"]
    if week <= windows:
        return {"value": week, "binding": BINDING_WEEK}
    return {"value": windows, "binding": BINDING_WINDOWS}


def resolve(path, names):
    """Return (exit code, document or None)."""
    data = _load(path)
    project_tables = data.get("project")
    if not isinstance(project_tables, dict):
        project_tables = {}
    projects = []
    for name in names:
        ptable = project_tables.get(name)
        pcap = ptable.get("capacity") if isinstance(ptable, dict) else None
        projects.append(_project(name, pcap))
    declared = "capacity" in data
    shared = None
    effective = None
    if declared:
        cap = data["capacity"]
        shared = {}
        for key in SHARED_KEYS:
            if key in cap:
                shared[key] = _entry(cap[key], "config")
            else:
                shared[key] = _entry(None, "default")
        effective = _effective(cap)
    doc = {
        "capacity_schema": CAPACITY_SCHEMA,
        "declared": declared,
        "token_unit": TOKEN_UNIT,
        "shared": shared,
        "effective_tokens_per_week": effective,
        "projects": projects,
    }
    return 0, doc


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _number_text(v):
    """An integral value with no fraction (330000000.0 -> 330000000); any other
    float as Python's repr."""
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() else repr(v)
    return str(v)


def _reject_constant(name):
    raise ValueError("non-finite number: " + name)


def summary(text):
    """The one-line summary of a capacity document, or None when `text` is not one:
    a JSON object with a capacity_schema of major 1, a boolean `declared` and, when
    declared, the four values the line prints."""
    try:
        doc = json.loads(text, parse_constant=_reject_constant)
    except ValueError:
        return None
    if not isinstance(doc, dict):
        return None
    schema = doc.get("capacity_schema")
    if not isinstance(schema, str) or schema.split(".")[0] != "1":
        return None
    declared = doc.get("declared")
    if not isinstance(declared, bool):
        return None
    if not declared:
        return NOT_DECLARED
    try:
        hours = doc["shared"]["operator_hours_per_week"]["value"]
        lanes = doc["shared"]["max_lanes"]["value"]
        tokens = doc["effective_tokens_per_week"]["value"]
        binding = doc["effective_tokens_per_week"]["binding"]
    except (KeyError, TypeError):
        return None
    if not (_is_number(hours) and _is_number(lanes) and _is_number(tokens)):
        return None
    if not isinstance(binding, str) or not binding:
        return None
    return "%s operator h/week, pool of %s lanes, %s weighted tokens/week (%s)" % (
        _number_text(hours), _number_text(lanes), _number_text(tokens), binding)


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
    if argv == ["summary"]:
        try:
            text = sys.stdin.buffer.read().decode("utf-8")
        except (OSError, ValueError):
            text = ""
        line = summary(text)
        if line is None:
            _say("summary: not a capacity document")
            return 1
        print(line)
        return 0
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
