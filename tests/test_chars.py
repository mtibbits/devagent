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
