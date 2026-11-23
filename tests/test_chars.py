"""Tests for #923's character check: the vendored UCD 16.0.0 data
(scripts/lib/ucd/), the generator and its table (chars_gen.py,
chars_table.py) and the runtime module (chars.py).

This file stays ASCII: every character is built with chr(0xXXXX) or written
as bytes with \\x escapes, never typed.
"""
import hashlib
import importlib.util
import random
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

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
                          capture_output=True, check=False)


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


# ---- Task 4: chars.py ---------------------------------------------------------


CHARS = LIB / "chars.py"
LAYOUT = LIB / "staging_layout.py"
RENDER = LIB / "staging_render.py"


def _chars():
    return _load("chars", CHARS)


def _u(cp):
    return chr(cp).encode("utf-8")


def test_ac_code_points_hit():
    c = _chars()
    for cp in (0x202E, 0xE0041, 0x200B, 0xFE00, 0x00AD, 0x0007, 0x0378):
        hits = c.chars_scan("body", b"a" + _u(cp) + b"b", set())
        assert hits == [("body", 1, "U+%04X" % cp)], hex(cp)
    for raw in (b"a" + _u(0xE000) + b"b", b"a\tb", b"one\r\ntwo\r\n"):
        assert c.chars_scan("body", raw, set()) == [], raw


def test_invalid_utf8():
    c = _chars()
    assert c.chars_scan("body", b"ok\nab\xffcd\n", set()) == [("body", 2, "0xFF")]
    assert c.chars_scan("body", b"x\xed\xa0\x80y", set()) == [("body", 1, "0xED")]


def test_allowlist_and_runs():
    c = _chars()
    rlm = _u(0x200F)
    a = {chr(0x200F)}
    assert c.chars_scan("body", b"a" + rlm + b"b", a) == []
    assert c.chars_scan("body", b"a" + rlm * 3 + b"b", a) == [("body", 1, "U+200F")] * 3
    zw = {chr(0x200C), chr(0x200D)}
    assert len(c.chars_scan("body", _u(0x200C) + _u(0x200D) + _u(0x200C), zw)) == 3
    flag = _u(0x1F3F3) + _u(0xFE0F) + _u(0x200D) + _u(0x1F308)
    assert c.chars_scan("body", flag, {chr(0xFE0F), chr(0x200D)}) == []
    assert c.chars_scan("body", rlm * 2 + b"x" + rlm * 2, a) == []
    assert c.chars_scan("body", rlm * 2 + b"\n" + rlm * 2, a) == []
    assert c.chars_scan("body", rlm + _u(0x202E), a) == [("body", 1, "U+202E")]
    sub = _u(0x1F3F4) + b"".join(_u(cp) for cp in (0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F))
    tags = {chr(cp) for cp in (0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE007F)}
    assert len(c.chars_scan("body", sub, tags)) == 6


def test_lines_and_fields():
    c = _chars()
    hit = _u(0x202E)
    for sep in (b"\r\n", b"\r\r\n", b"\r", b"\n"):
        assert c.chars_scan("body", b"a" + sep + b"b" + sep + hit, set()) == [("body", 3, "U+202E")], sep
    for cp in (0x000C, 0x0085, 0x2028):
        hits = c.chars_scan("body", b"a" + _u(cp) + b"b" + _u(0x202E), set())
        assert [h[1] for h in hits] == [1] * len(hits), hex(cp)
        assert ("body", 1, "U+202E") in hits
    assert c.chars_scan("comment:12/ab cd", hit, set()) == [("comment:12_ab_cd", 1, "U+202E")]
    long_id = "a" * 70
    assert c.chars_scan("comment:" + long_id, hit, set())[0][0] == "comment:" + "a" * 64
    with pytest.raises(ValueError):
        c.chars_scan("comments", hit, set())


def test_escape():
    c = _chars()
    a = {chr(0x200F), chr(0xE0041)}
    assert c.chars_escape("x" + chr(0x200F) + "y", a) == "x<U+200F>y"
    assert c.chars_escape("x" + chr(0xE0041) + "y", a) == "x<U+E0041>y"
    run = chr(0x200F) * 3
    assert c.chars_escape(run, a) == run
    assert c.chars_escape("x" + chr(0x202E), a) == "x" + chr(0x202E)
    raw = b"a" + _u(0x200F) + b"\r\nb\xff" + _u(0x200F) + b"\n"
    assert c.chars_escape_bytes(raw, a) == b"a<U+200F>\r\nb\xff" + _u(0x200F) + b"\n"


def test_scan_of_escape_equals_scan():
    c = _chars()
    rnd = random.Random(923)
    allow = {chr(0x200F), chr(0x200D)}
    members = [_u(0x200F), _u(0x200D), _u(0x202E), _u(0x200B), b"\x07"]
    plain = [b"a", b"Z", b" ", _u(0x0430), _u(0x6771)]
    ends = [b"\n", b"\r", b"\r\n"]
    bad = [b"\xff", b"\xed\xa0\x80", b"\xc3"]
    pool = members * 3 + plain * 3 + ends + bad
    for _ in range(2000):
        b = b"".join(rnd.choice(pool) for _ in range(rnd.randint(0, 24)))
        assert c.chars_scan("body", c.chars_escape_bytes(b, allow), set()) == c.chars_scan("body", b, allow), b


def test_mixed_record():
    c = _chars()
    paypal = "p" + chr(0x0430) + "ypal"
    assert c.mixed_record("title", "x\n" + paypal) == [
        {"field": "title", "line": 2, "word_scripts": ["Cyrillic", "Latin"]}]
    privet = "".join(chr(cp) for cp in (0x41F, 0x440, 0x438, 0x432, 0x435, 0x442)) + " " + \
        "".join(chr(cp) for cp in (0x43C, 0x438, 0x440))
    formula = chr(0x3B1) + " + " + chr(0x3B2) + " = " + chr(0x3B3)
    tokyo = "".join(chr(cp) for cp in (0x6771, 0x4EAC, 0x30BF, 0x30EF, 0x30FC))
    for text in (privet, formula, tokyo):
        assert c.mixed_record("body", text) == [], text
    assert c.mixed_record("body", "ab" + chr(0x30FC)) == [
        {"field": "body", "line": 1, "word_scripts": ["Common", "Latin"]}]
    assert c.mixed_record("body", "ab1" + chr(0x0430)) == []
    assert c.mixed_record_bytes("body", b"\xff" + paypal.encode("utf-8") + b"\n" + paypal.encode("utf-8")) == [
        {"field": "body", "line": 2, "word_scripts": ["Cyrillic", "Latin"]}]


def test_runtime_tables_unused():
    c = _chars()
    assert c.chars_scan("body", _u(0x10D40), set()) == []
    assert c.mixed_record("body", "ab" + chr(0xA7CB) + "cd") == []


def test_field_order():
    c = _chars()
    hit = _u(0x202E)
    cand = (b"# acme/widgets#7 \xe2\x80\x94 T" + hit + b"\n\n- State: open" + hit + b"\n- Author: @a" + hit
            + b"\n- Labels: bug" + hit + b"\n- URL: u\n\n---\n\nbody" + hit + b"\n" + hit + b"\n\n---\n\n## Comments (0)\n")
    hits = c.candidate_scan(cand, set())
    assert [h[0] for h in hits] == ["title", "body", "body", "label", "state", "author"]
    assert len(hits) == 6


def test_modules_load_acyclic():
    for path in (CHARS, LAYOUT, RENDER):
        code = ("import importlib.util,sys\n"
                "s=importlib.util.spec_from_file_location('m', %r)\n"
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
                "print('loaded')\n") % str(path)
        r = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, check=False)
        assert r.returncode == 0, r.stderr
        assert r.stdout == b"loaded\n"
        assert b"RecursionError" not in r.stderr


def test_no_unicodedata():
    code = ("import sys\n"
            "sys.modules['unicodedata'] = None\n"
            "import importlib.util\n"
            "s=importlib.util.spec_from_file_location('chars', %r)\n"
            "c=importlib.util.module_from_spec(s); s.loader.exec_module(c)\n"
            "assert c.chars_scan('body', chr(0x202E).encode(), set())\n"
            "c.chars_escape('a', set()); c.mixed_record('body', 'ab')\n"
            "c.chars_escape_bytes(b'a', set()); c.mixed_record_bytes('body', b'ab')\n"
            "g=importlib.util.spec_from_file_location('gen', %r)\n"
            "m=importlib.util.module_from_spec(g); g.loader.exec_module(m)\n"
            "assert m.main(['check']) == 0\n"
            "print('no-unicodedata-ok')\n") % (str(CHARS), str(GEN))
    r = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, check=False)
    assert r.returncode == 0, r.stderr
    assert r.stdout == b"no-unicodedata-ok\n"


def test_new_sources_are_ascii():
    for p in (LIB / "chars.py", LIB / "chars_gen.py", LIB / "chars_table.py", LIB / "staging_layout.py",
              REPO / "tests" / "test_chars.py", REPO / "tests" / "chars.bats", REPO / "tests" / "chars-pull.bats"):
        data = p.read_bytes()
        assert all(b < 0x80 for b in data), p


def test_load_allowlist(tmp_path):
    c = _chars()
    assert c.load_allowlist(None) == frozenset()
    f = tmp_path / "a.json"
    f.write_bytes(b'["\\u200f", "\\u200d"]')
    assert c.load_allowlist(str(f)) == frozenset({chr(0x200F), chr(0x200D)})
    for bad in (b"null", b"{}", b'["ab"]', b"[1]", b'["a"', b""):
        f.write_bytes(bad)
        with pytest.raises(ValueError):
            c.load_allowlist(str(f))
