"""Tests for wbs-parser.py's additive diagnostics (#726).

The characterization golden (diagnose.*) pins the parser's existing CLI output
on a fixture that plants every metadata branch, so the diagnostics refactor
cannot change parse/edges/leaves/render. The goldens were produced by the CLI
at the base commit (bec6da0) under Linux python3 and are never hand-edited.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "wbs"
PARSER = str(REPO / "scripts" / "lib" / "wbs-parser.py")
DIAG = FIX / "diagnose.md"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_parser = _load("wbs_parser", PARSER)


def _cli(*args):
    res = subprocess.run([sys.executable, PARSER, *args], capture_output=True, check=True)
    return res.stdout


def _lf(b):
    # parse/edges/leaves print through text-mode stdout, which writes `\r\n` on
    # Windows; the goldens are LF. Content CRs cannot occur: the fixture is LF.
    return b.replace(b"\r\n", b"\n")


def test_diagnose_fixture_cli_unchanged(tmp_path):
    assert b"\r" not in DIAG.read_bytes()
    for cmd, golden in (("parse", "diagnose.parse.json"),
                        ("edges", "diagnose.edges.txt"),
                        ("leaves", "diagnose.leaves.txt")):
        assert _lf(_cli(cmd, str(DIAG))) == (FIX / golden).read_bytes(), cmd
    assert _cli("render", str(FIX / "diagnose.parse.json")) == DIAG.read_bytes()
