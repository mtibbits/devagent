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
import importlib.util
import json
import math
import os
import pathlib
import re
import sys

# The one config loader (#293: it retries a Windows sharing violation). Loaded at
# import, so a missing TOML parser crashes this file (exit 1) rather than reading as
# exit 4; through capacity.sh, its _toml.py validate pre-check exits 4 first.
_spec = importlib.util.spec_from_file_location(
    "_capacity_toml", os.path.join(os.path.dirname(os.path.abspath(__file__)), "_toml.py"))
_toml = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_toml)

CAPACITY_SCHEMA = "1.0"
TOKEN_UNIT = "weighted_input_token_equivalents"

BINDING_WEEK = "tokens_per_week"
BINDING_WINDOWS = "tokens_per_window_x_windows_per_week"

PROJECT_DEFAULTS = {
    "priority": 5,
    "max_lanes": None,
    "paused": False,
    "deadline": None,
    "reserve_operator_hours_per_week": None,
    "reserve_tokens_per_week": None,
}

# Every numeric key has a finite upper bound. Where the domain gives none it is
# 2^53 - 1 (JavaScript's Number.MAX_SAFE_INTEGER), so int x float and int + float
# cannot overflow, and #957's doubles agree with Python's integers.
SAFE_MAX = 9007199254740991

# (range text, low, low is allowed, high). The five texts are the complete set.
RANGE_HOURS = ("0 < x <= 168", 0, False, 168)
RANGE_COUNT = ("1 <= x <= 9007199254740991", 1, True, SAFE_MAX)
RANGE_TOKENS = ("0 < x <= 9007199254740991", 0, False, SAFE_MAX)
RANGE_WINDOWS = ("0 < x <= 33.6", 0, False, 33.6)
RANGE_NONNEG = ("0 <= x <= 9007199254740991", 0, True, SAFE_MAX)

# key -> (type, range or None), in the order the document lists the keys.
SHARED_RULES = {
    "operator_hours_per_week": ("number", RANGE_HOURS),
    "lane_hours_per_week": ("number", RANGE_HOURS),
    "max_lanes": ("integer", RANGE_COUNT),
    "tokens_per_week": ("integer", RANGE_TOKENS),
    "tokens_per_window": ("integer", RANGE_TOKENS),
    "windows_per_week": ("number", RANGE_WINDOWS),
    "operator_hours_per_agent_hour": ("number", RANGE_NONNEG),
}
SHARED_OPTIONAL = ("operator_hours_per_agent_hour",)
PROJECT_RULES = {
    "priority": ("integer", RANGE_COUNT),
    "max_lanes": ("integer", RANGE_COUNT),
    "paused": ("boolean", None),
    "deadline": ("date", None),
    "reserve_operator_hours_per_week": ("number", RANGE_NONNEG),
    "reserve_tokens_per_week": ("integer", RANGE_NONNEG),
}
SHARED_KEYS = tuple(SHARED_RULES)
PROJECT_KEYS = tuple(PROJECT_RULES)

# The rule strings (#957 reproduces them).
MISSING = "missing required key"
WRONG_TYPE = "wrong type: expected "
OUT_OF_RANGE = "out of range: "
NOT_A_DATE = "not a calendar date"
TABLE_MISSING = "[capacity] table missing"
EXCEEDS_LANES = "exceeds capacity.max_lanes"
POOL_HOURS = "reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week"
POOL_TOKENS = "reserve_tokens_per_week sum exceeds the effective weekly token budget"
UNKNOWN_KEY = "unknown key (ignored)"
CAPACITY_ONLY = "only key is capacity (misspelled project name?)"

# The hours pool refuses only past this fixed tolerance: it absorbs binary rounding,
# so an exactly-full declaration (4.4 + 11.8 + 3.8 against 20) passes in any order.
HOURS_TOLERANCE = 1e-9

_BARE_PART = re.compile(r"[A-Za-z0-9_-]+")
_DATE_TEXT = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")

USAGE = "capacity: usage: capacity.py resolve <config> [<project>...] | capacity.py summary"
NOT_DECLARED = "not declared (forecasting off)"


class _ConfigError(Exception):
    """The config cannot be read or parsed: exit 4 with this one line."""


def _say(line):
    print("capacity: " + line, file=sys.stderr)


def _load(path):
    try:
        return _toml._load(pathlib.Path(path), retry=True)
    except OSError:
        raise _ConfigError("config not readable: " + path)
    except Exception:
        # Any parse failure, including an integer past the int-conversion limit
        # (a ValueError, not a TOMLDecodeError).
        raise _ConfigError("config is not valid TOML: " + path)


def _entry(value, source):
    return {"value": value, "source": source}


def where(parts):
    """A dotted path: a part matching [A-Za-z0-9_-]+ in full is bare, any other is a
    JSON string (JavaScript's JSON.stringify), so it stays on one line."""
    out = []
    for part in parts:
        if _BARE_PART.fullmatch(part):
            out.append(part)
        else:
            out.append(json.dumps(part, ensure_ascii=False))
    return ".".join(out)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _calendar_date(text):
    """The date a YYYY-MM-DD string names, or None. Never fromisoformat, never \\d."""
    if not _DATE_TEXT.fullmatch(text):
        return None
    try:
        return datetime.date(int(text[0:4]), int(text[5:7]), int(text[8:10]))
    except ValueError:
        return None


def check(value, kind, rng):
    """The one rule `value` breaks (wrong type first), or None when it is valid."""
    if kind == "integer":
        if not _is_int(value):
            return WRONG_TYPE + kind
    elif kind == "number":
        if not (_is_int(value) or isinstance(value, float)):
            return WRONG_TYPE + kind
    elif kind == "boolean":
        if not isinstance(value, bool):
            return WRONG_TYPE + kind
    elif kind == "date":
        # A date-time is a subclass of date: refuse it first.
        if isinstance(value, datetime.datetime):
            return WRONG_TYPE + kind
        if isinstance(value, datetime.date):
            return None
        if not isinstance(value, str):
            return WRONG_TYPE + kind
        return None if _calendar_date(value) else NOT_A_DATE
    if rng is not None:
        text, low, low_ok, high = rng
        # Compare the value as parsed: never convert a huge int to float, and only a
        # float can be non-finite (math.isfinite on a huge int would overflow).
        if isinstance(value, float) and not math.isfinite(value):
            return OUT_OF_RANGE + text
        if (value < low) or (value == low and not low_ok) or value > high:
            return OUT_OF_RANGE + text
    return None


def _doc_value(value):
    """A config value as the document writes it: a TOML date as YYYY-MM-DD (a valid
    date string already is)."""
    if isinstance(value, datetime.date):
        return value.isoformat()
    return value


def _project(name, table):
    """One element of `projects`: the six keys from its capacity table ({}: none)."""
    out = {"name": name}
    for key in PROJECT_KEYS:
        if key in table:
            out[key] = _entry(_doc_value(table[key]), "config")
        else:
            out[key] = _entry(PROJECT_DEFAULTS[key], "default")
    return out


# 2^52: every double at or above it is already whole, and adding 0.5 there can round
# the sum up to the next integer.
_WHOLE_DOUBLES = 4503599627370496


def _whole_tokens(x):
    """x rounded half up to an int, as JavaScript's Math.floor(x + 0.5) (#957). A
    product such as 60000000 * 4.1 is 245999999.99999997 as a double."""
    if isinstance(x, int) or x >= _WHOLE_DOUBLES:
        return int(x)
    return math.floor(x + 0.5)


def _effective(cap):
    """min(tokens_per_week, tokens_per_window * windows_per_week), the product rounded
    to whole tokens; a tie binds on tokens_per_week."""
    week = cap["tokens_per_week"]
    windows = _whole_tokens(cap["tokens_per_window"] * cap["windows_per_week"])
    if week <= windows:
        return {"value": week, "binding": BINDING_WEEK}
    return {"value": windows, "binding": BINDING_WINDOWS}


def _pool_sum(unpaused, key):
    """Each unpaused project's set reservation, added with + from an integer 0 in
    project order. Never sum(), math.fsum or decimal: sum() rounds differently on
    3.12+, and #957 reproduces this in JavaScript."""
    total = 0
    for project in unpaused:
        value = project["table"].get(key)
        if value is not None:
            total = total + value
    return total


def _validate(table, rules, base, violations, warnings, required=(), max_lanes=None):
    """Append a violation per broken rule (in rules order), then a warning per unknown
    key (in table order). Return (the valid values, the keys that broke a rule).
    `max_lanes`: the valid shared lane pool, which a valid max_lanes may not exceed."""
    ok = {}
    bad = set()
    for key, rule_args in rules.items():
        if key not in table:
            if key in required:
                violations.append((base + [key], MISSING))
            continue
        rule = check(table[key], *rule_args)
        if (rule is None and key == "max_lanes" and max_lanes is not None
                and table[key] > max_lanes):
            rule = EXCEEDS_LANES   # a paused project too
        if rule:
            violations.append((base + [key], rule))
            bad.add(key)
        else:
            ok[key] = table[key]
    for key in table:
        if key not in rules:
            warnings.append((base + [key], UNKNOWN_KEY))
    return ok, bad


def resolve(path, names):
    """Return (exit code, document or None). Violations, then warnings, go to stderr."""
    data = _load(path)
    violations = []
    warnings = []

    # The shared table. `shared_ok` holds each key that is present and valid.
    declared = "capacity" in data
    cap = data.get("capacity")
    shared_ok = {}
    if declared and not isinstance(cap, dict):
        violations.append((["capacity"], WRONG_TYPE + "table"))
    elif declared:
        required = [k for k in SHARED_KEYS if k not in SHARED_OPTIONAL]
        shared_ok, _ = _validate(cap, SHARED_RULES, ["capacity"], violations, warnings, required)

    # Each project, in the order given. A capacity that is not a table is read by
    # the pool rules as unpaused with no reservations; its own line reports it.
    project_tables = data.get("project")
    if not isinstance(project_tables, dict):
        project_tables = {}
    projects = []
    for name in names:
        ptable = project_tables.get(name)
        pcap = {}
        bad = set()
        if isinstance(ptable, dict) and "capacity" in ptable:
            base = ["project", name, "capacity"]
            if list(ptable) == ["capacity"]:
                warnings.append((["project", name], CAPACITY_ONLY))
            if not isinstance(ptable["capacity"], dict):
                violations.append((base, WRONG_TYPE + "table"))
            else:
                pcap = ptable["capacity"]
                if not declared:
                    violations.append((base, TABLE_MISSING))
                _, bad = _validate(pcap, PROJECT_RULES, base, violations, warnings,
                                   max_lanes=shared_ok.get("max_lanes"))
        projects.append({"name": name, "table": pcap, "bad": bad,
                         "paused": pcap.get("paused") is True})

    # The pool rules, each only when every value it reads is valid (an absent
    # optional value is valid). Neither runs when [capacity] is absent or not a table.
    paused_ok = all("paused" not in p["bad"] for p in projects)
    unpaused = [p for p in projects if not p["paused"]]
    if (paused_ok and "operator_hours_per_week" in shared_ok
            and all("reserve_operator_hours_per_week" not in p["bad"] for p in unpaused)):
        total = _pool_sum(unpaused, "reserve_operator_hours_per_week")
        if total > shared_ok["operator_hours_per_week"] + HOURS_TOLERANCE:
            violations.append((["pool"], POOL_HOURS))
    effective = None
    if all(k in shared_ok for k in ("tokens_per_week", "tokens_per_window", "windows_per_week")):
        effective = _effective(shared_ok)
        if paused_ok and all("reserve_tokens_per_week" not in p["bad"] for p in unpaused):
            # Strict: the token sum is an exact integer.
            if _pool_sum(unpaused, "reserve_tokens_per_week") > effective["value"]:
                violations.append((["pool"], POOL_TOKENS))

    for parts, rule in violations:
        _say(where(parts) + ": " + rule)
    for parts, text in warnings:
        _say("warning: " + where(parts) + ": " + text)
    if violations:
        return 3, None

    shared = None
    if declared:
        shared = {}
        for key in SHARED_KEYS:
            if key in shared_ok:
                shared[key] = _entry(shared_ok[key], "config")
            else:
                shared[key] = _entry(None, "default")
    doc = {
        "capacity_schema": CAPACITY_SCHEMA,
        "declared": declared,
        "token_unit": TOKEN_UNIT,
        "shared": shared,
        "effective_tokens_per_week": effective,
        "projects": [_project(p["name"], p["table"]) for p in projects],
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
