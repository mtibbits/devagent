"""Tests for #923's character check: the vendored UCD 16.0.0 data
(scripts/lib/ucd/), the generator and its table (chars_gen.py,
chars_table.py) and the runtime module (chars.py).

This file stays ASCII: every character is built with chr(0xXXXX) or written
as bytes with \\x escapes, never typed.
"""
import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
UCD = LIB / "ucd"
DATA_FILES = (
    "PropList.txt",
    "DerivedCoreProperties.txt",
    "DerivedGeneralCategory.txt",
    "Scripts.txt",
    "ScriptExtensions.txt",
    "PropertyValueAliases.txt",
)


def _sums():
    out = {}
    for line in (UCD / "SHA256SUMS").read_bytes().decode("ascii").splitlines():
        digest, name = line.split("  ", 1)
        out[name] = digest
    return out


# ---- Task 2: the vendored files ---------------------------------------------

def test_ucd_checksums():
    sums = _sums()
    assert sorted(sums) == sorted(DATA_FILES)
    for name, digest in sums.items():
        assert hashlib.sha256((UCD / name).read_bytes()).hexdigest() == digest, name


def test_ucd_version_lines():
    for name in DATA_FILES:
        first = (UCD / name).read_bytes().split(b"\n", 1)[0]
        stem = name[: -len(".txt")]
        assert first == ("# %s-16.0.0.txt" % stem).encode("ascii"), name


def test_ucd_licence():
    assert (UCD / "LICENSE").read_bytes().startswith(b"UNICODE LICENSE V3")


# ---- Task 3: the generator and the table ------------------------------------

import importlib.util  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import sys  # noqa: E402

GEN = LIB / "chars_gen.py"
TABLE = LIB / "chars_table.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _rows(name):
    """(lo, hi, [fields]) for every data line of a UCD file. This parser is
    the test's own (it imports nothing from chars_gen): a `#` starts a
    comment, so `# @missing` lines are never data; a range is `XXXX..YYYY`."""
    for raw in (UCD / name).read_bytes().decode("utf-8").split("\n"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(";")]
        lo, _, hi = parts[0].partition("..")
        lo = int(lo, 16)
        yield lo, (int(hi, 16) if hi else lo), parts[1:]


def _points(rows):
    out = set()
    for lo, hi in rows:
        out.update(range(lo, hi + 1))
    return out


def _derive():
    """The four tables, from the vendored files, by the test's own parse."""
    gc = {}
    for lo, hi, f in _rows("DerivedGeneralCategory.txt"):
        for cp in range(lo, hi + 1):
            gc[cp] = f[0]
    members = set()
    for lo, hi, f in _rows("PropList.txt"):
        if f[0] == "Bidi_Control":
            members.update(range(lo, hi + 1))
    for lo, hi, f in _rows("DerivedCoreProperties.txt"):
        if f[0] == "Default_Ignorable_Code_Point":
            members.update(range(lo, hi + 1))
    for cp in range(0x110000):
        g = gc.get(cp, "Cn")  # DerivedGeneralCategory's @missing value
        if g in ("Cf", "Cn", "Cs") or (g == "Cc" and cp not in (0x09, 0x0A, 0x0D)):
            members.add(cp)
    lm = {cp for cp, g in gc.items() if g[0] in "LM"}
    scripts = {}
    for lo, hi, f in _rows("Scripts.txt"):
        for cp in range(lo, hi + 1):
            scripts[cp] = f[0]
    long_name = {}
    for raw in (UCD / "PropertyValueAliases.txt").read_bytes().decode("utf-8").split("\n"):
        parts = [p.strip() for p in raw.split("#", 1)[0].split(";")]
        if parts[0] == "sc":
            long_name[parts[1]] = parts[2]
    scx = {}
    for lo, hi, f in _rows("ScriptExtensions.txt"):
        names = tuple(sorted(long_name[c] for c in f[0].split()))
        for cp in range(lo, hi + 1):
            scx[cp] = names
    return members, lm, scripts, scx


def _expand_valued(ranges):
    out = {}
    for lo, hi, v in ranges:
        for cp in range(lo, hi + 1):
            out[cp] = v
    return out


def _is_sorted_disjoint(ranges):
    prev = -1
    for r in ranges:
        if not (prev < r[0] <= r[1]):
            return False
        prev = r[1]
    return True


def test_tables_equal_independent_derivation():
    t = _load("chars_table", TABLE)
    members, lm, scripts, scx = _derive()
    for name in ("SET", "LM", "SCRIPTS", "SCX"):
        assert _is_sorted_disjoint(getattr(t, name)), name
    assert _points(t.SET) == members
    assert len(members) == 822080
    assert len(t.SET) == 745
    assert _points(t.LM) == lm
    assert _expand_valued(t.SCRIPTS) == scripts
    assert _expand_valued(t.SCX) == scx


def test_set_members():
    t = _load("chars_table", TABLE)
    pts = _points(t.SET)
    for cp in (0x202E, 0xE0041, 0x200B, 0xFE00, 0x00AD, 0x0007, 0x0085, 0x0378, 0xD800):
        assert cp in pts, hex(cp)
    for cp in (0x0009, 0x000A, 0x000D, 0x0041, 0xE000, 0xFFFD):
        assert cp not in pts, hex(cp)


def test_scx_codes_resolve():
    t = _load("chars_table", TABLE)
    codes = set()
    for _lo, _hi, f in _rows("ScriptExtensions.txt"):
        codes.update(f[0].split())
    assert len(codes) == 98
    sc_rows = {}
    for raw in (UCD / "PropertyValueAliases.txt").read_bytes().decode("utf-8").split("\n"):
        parts = [p.strip() for p in raw.split("#", 1)[0].split(";")]
        if parts[0] == "sc":
            sc_rows[parts[1]] = parts[2]
    script_values = {f[0] for _lo, _hi, f in _rows("Scripts.txt")}
    for c in codes:
        assert sc_rows[c] in script_values, c
    held = {n for _lo, _hi, names in t.SCX for n in names}
    assert held <= script_values
    assert not held & (codes - script_values)


def test_table_version_and_sources():
    t = _load("chars_table", TABLE)
    for name in DATA_FILES:
        first = (UCD / name).read_bytes().split(b"\n", 1)[0].decode("ascii")
        assert first.endswith("-%s.txt" % t.UNICODE_VERSION), name
    assert t.UNICODE_VERSION == "16.0.0"
    assert dict(t.SOURCES) == _sums()
    assert TABLE.read_bytes().split(b"\n", 1)[0].startswith(b"# Generated")


def _gen(*args):
    return subprocess.run([sys.executable, "-I", "-X", "utf8", str(GEN)] + list(args),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def test_generator_check(tmp_path):
    r = _gen("check")
    assert r.returncode == 0, r.stderr
    ucd = tmp_path / "ucd"
    shutil.copytree(str(UCD), str(ucd))
    table = tmp_path / "chars_table.py"
    shutil.copyfile(str(TABLE), str(table))
    assert _gen("check", "--ucd", str(ucd), "--table", str(table)).returncode == 0
    # One table range changed.
    text = table.read_bytes()
    bad = text.replace(b"(0x202A, 0x202E),", b"(0x202A, 0x202D),", 1)
    assert bad != text
    table.write_bytes(bad)
    r = _gen("check", "--ucd", str(ucd), "--table", str(table))
    assert r.returncode == 1
    assert b"chars_table.py" in r.stderr
    table.write_bytes(text)
    # One UCD byte changed.
    p = ucd / "Scripts.txt"
    b = bytearray(p.read_bytes())
    b[-2] ^= 0x01
    p.write_bytes(bytes(b))
    r = _gen("check", "--ucd", str(ucd), "--table", str(table))
    assert r.returncode == 1
    assert b"Scripts.txt" in r.stderr
    assert _gen("bogus").returncode == 2
