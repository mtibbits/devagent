#!/usr/bin/env python3
"""chars_gen.py -- generate scripts/lib/chars_table.py from the vendored UCD
files in scripts/lib/ucd/ (#923; spec section 9.3).

Run as `python3 -I -X utf8 chars_gen.py write|check [--ucd <dir>] [--table <file>]`.

  write  regenerate the table from the UCD files.
  check  exit 0 when every UCD file's sha256 equals its SHA256SUMS line and the
         table equals a regeneration byte for byte; exit 1 on drift, with one
         line on stderr naming the file; exit 2 on usage.

The table holds, as sorted tuples of inclusive code point ranges:
  SET      the pulled-text check's set: Bidi_Control (PropList.txt) and
           Default_Ignorable_Code_Point (DerivedCoreProperties.txt), with
           General_Category Cf, Cn and Cs, and Cc other than U+0009, U+000A
           and U+000D (extracted/DerivedGeneralCategory.txt). Co is outside.
  LM       General_Category L* or M* (a word's letters, for the mixed-script
           record).
  SCRIPTS  (lo, hi, Script) as Scripts.txt spells it; a code point no range
           holds is Unknown (the file's @missing line).
  SCX      (lo, hi, (Script, ...)): Script_Extensions as long names, mapped
           through the `sc` rows of PropertyValueAliases.txt, so the table
           carries no ISO 15924 code; a code point no range holds has
           Script_Extensions equal to its Script (the file's @missing line).
plus UNICODE_VERSION (from the files' own first lines) and SOURCES (file name
to sha256). The runtime (chars.py) reads only the table; nothing here or there
imports unicodedata.

Bump procedure (a new Unicode version):
  1. Replace the six data files in scripts/lib/ucd/ AND their SHA256SUMS lines
     together, fetched from https://www.unicode.org/Public/<version>/ucd/
     (DerivedGeneralCategory.txt from its extracted/ directory), bytes as
     served.
  2. Run `python3 -I -X utf8 scripts/lib/chars_gen.py write`.
  3. Update the pinned counts in tests/test_chars.py (the set's size and range
     count, the Script_Extensions code count) from an independent derivation,
     never from the table.
  4. Add a changelog.d entry naming the new version.
"""

import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_UCD = os.path.join(HERE, "ucd")
DEFAULT_TABLE = os.path.join(HERE, "chars_table.py")
FILES = (
    "PropList.txt",
    "DerivedCoreProperties.txt",
    "DerivedGeneralCategory.txt",
    "Scripts.txt",
    "ScriptExtensions.txt",
    "PropertyValueAliases.txt",
)
MAX_CP = 0x10FFFF


class Drift(Exception):
    """A file differs from what it should be; the message names it."""


def _data_lines(text):
    """[(lo, hi, [fields])] for each data line; `#` starts a comment."""
    out = []
    for raw in text.split("\n"):
        body = raw.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [f.strip() for f in body.split(";")]
        span = fields[0].split("..")
        lo = int(span[0], 16)
        hi = int(span[1], 16) if len(span) == 2 else lo
        out.append((lo, hi, fields[1:]))
    return out


def _merge(points):
    """Sorted inclusive ranges covering the code point set."""
    return [r[:2] for r in _merge_valued(dict.fromkeys(points, True))]


def _merge_valued(mapping):
    """Sorted inclusive (lo, hi, value) ranges; adjacent equal values join."""
    ranges = []
    for cp in sorted(mapping):
        v = mapping[cp]
        if ranges and ranges[-1][1] == cp - 1 and ranges[-1][2] == v:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp, v])
    return [tuple(r) for r in ranges]


def _read_sums(ucd):
    try:
        with open(os.path.join(ucd, "SHA256SUMS"), "rb") as fh:
            text = fh.read().decode("ascii")
    except (OSError, UnicodeDecodeError):
        raise Drift("SHA256SUMS")
    sums = {}
    for line in text.split("\n"):
        if not line:
            continue
        digest, name = line.split("  ", 1)
        sums[name] = digest
    if sorted(sums) != sorted(FILES):
        raise Drift("SHA256SUMS")
    return sums


def _read_files(ucd, sums):
    texts = {}
    version = None
    for name in FILES:
        try:
            with open(os.path.join(ucd, name), "rb") as fh:
                data = fh.read()
        except OSError:
            raise Drift(name)
        if hashlib.sha256(data).hexdigest() != sums[name]:
            raise Drift(name)
        text = data.decode("utf-8")
        first = text.split("\n", 1)[0]
        stem = name[: -len(".txt")]
        prefix = "# " + stem + "-"
        if not (first.startswith(prefix) and first.endswith(".txt")):
            raise Drift(name)
        v = first[len(prefix): -len(".txt")]
        if version is None:
            version = v
        elif v != version:
            raise Drift(name)
        texts[name] = text
    return texts, version


def generate(ucd):
    """The table's text for the UCD files in <ucd>; raises Drift."""
    sums = _read_sums(ucd)
    texts, version = _read_files(ucd, sums)

    gc = {}
    for lo, hi, f in _data_lines(texts["DerivedGeneralCategory.txt"]):
        for cp in range(lo, hi + 1):
            gc[cp] = f[0]
    members = set()
    for lo, hi, f in _data_lines(texts["PropList.txt"]):
        if f[0] == "Bidi_Control":
            members.update(range(lo, hi + 1))
    for lo, hi, f in _data_lines(texts["DerivedCoreProperties.txt"]):
        if f[0] == "Default_Ignorable_Code_Point":
            members.update(range(lo, hi + 1))
    for cp in range(MAX_CP + 1):
        cat = gc.get(cp, "Cn")
        if cat in ("Cf", "Cn", "Cs") or (cat == "Cc" and cp not in (0x09, 0x0A, 0x0D)):
            members.add(cp)
    letters = {cp for cp, cat in gc.items() if cat[0] in ("L", "M")}

    scripts = {}
    for lo, hi, f in _data_lines(texts["Scripts.txt"]):
        for cp in range(lo, hi + 1):
            scripts[cp] = f[0]
    long_names = {}
    for raw in texts["PropertyValueAliases.txt"].split("\n"):
        fields = [f.strip() for f in raw.split("#", 1)[0].split(";")]
        if len(fields) >= 3 and fields[0] == "sc":
            long_names[fields[1]] = fields[2]
    scx = {}
    for lo, hi, f in _data_lines(texts["ScriptExtensions.txt"]):
        names = tuple(sorted(long_names[code] for code in f[0].split()))
        for cp in range(lo, hi + 1):
            scx[cp] = names

    out = [
        "# Generated by scripts/lib/chars_gen.py from the Unicode %s UCD files in"
        " scripts/lib/ucd/; do not edit." % version,
        '"""The pulled-text character tables (#923). See chars_gen.py."""',
        "",
        "UNICODE_VERSION = %r" % version,
        "",
        "SOURCES = (",
    ]
    out += ["    (%r, %r)," % (name, sums[name]) for name in FILES]
    out += [")", "", "SET = ("]
    out += ["    (0x%04X, 0x%04X)," % r for r in _merge(members)]
    out += [")", "", "LM = ("]
    out += ["    (0x%04X, 0x%04X)," % r for r in _merge(letters)]
    out += [")", "", "SCRIPTS = ("]
    out += ["    (0x%04X, 0x%04X, %r)," % r for r in _merge_valued(scripts)]
    out += [")", "", "SCX = ("]
    out += ["    (0x%04X, 0x%04X, %r)," % r for r in _merge_valued(scx)]
    out += [")", ""]
    return "\n".join(out).encode("ascii")


def _usage():
    sys.stderr.buffer.write(b"usage: chars_gen.py write|check [--ucd <dir>] [--table <file>]\n")
    return 2


def main(argv):
    if not argv or argv[0] not in ("write", "check"):
        return _usage()
    verb, rest = argv[0], argv[1:]
    opts = {"--ucd": DEFAULT_UCD, "--table": DEFAULT_TABLE}
    seen = set()
    while rest:
        if len(rest) < 2 or rest[0] not in opts or rest[0] in seen or not rest[1]:
            return _usage()
        seen.add(rest[0])
        opts[rest[0]] = rest[1]
        rest = rest[2:]
    ucd, table = opts["--ucd"], opts["--table"]
    try:
        text = generate(ucd)
    except Drift as e:
        sys.stderr.buffer.write(b"drift: " + str(e).encode("ascii") + b"\n")
        return 1
    if verb == "write":
        with open(table, "wb") as fh:
            fh.write(text)
        return 0
    try:
        with open(table, "rb") as fh:
            have = fh.read()
    except OSError:
        have = None
    if have != text:
        sys.stderr.buffer.write(b"drift: " + os.path.basename(table).encode("utf-8", "replace") + b"\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
