"""Tests for the portfolio producer (#726): scripts/lib/portfolio.py."""
import ast
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
PRODUCER = LIB / "portfolio.py"
FIXTURES = REPO / "tests" / "fixtures" / "portfolio"
EXAMPLE = FIXTURES / "example-1.0.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


pf = _load("portfolio", PRODUCER)
wbs_parser = _load("wbs_parser_for_portfolio_tests", LIB / "wbs-parser.py")


# --- floor (twin of portfolio-check's) ----------------------------------------

def test_portfolio_imports_stdlib_only():
    stdlib = getattr(sys, "stdlib_module_names", None)
    if stdlib is None:
        pytest.skip("needs Python 3.10+ (sys.stdlib_module_names)")
    tree = ast.parse(PRODUCER.read_text(encoding="utf-8"))
    modules = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            modules.add(node.module.split(".")[0])
    assert modules, "no imports found: the walk saw nothing"
    assert modules <= set(stdlib) | {"__future__"}, modules - set(stdlib)


def test_portfolio_floor_runs_isolated():
    r = subprocess.run([sys.executable, "-I", "-S", str(PRODUCER), "--help"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stdout.startswith("usage: portfolio.py")
    assert r.stderr == ""


# --- per-node derivations ------------------------------------------------------

def _est(cls, low=None, high=None, quantity=None, unit=None):
    return {"class": cls, "low_hours": low, "high_hours": high,
            "quantity": quantity, "unit": unit}


EST_ROWS = [
    (None, _est("absent")),
    ("?w", _est("placeholder")),
    ("?", _est("placeholder")),
    ("6h", _est("time", 6, 6)),
    ("1.5d", _est("time", 12, 12)),
    ("1w", _est("time", 40, 40)),
    ("48pr", _est("non-time", quantity=48, unit="pr")),
    ("10.5pr", _est("non-time", quantity=10.5, unit="pr")),
    ("1W", _est("non-time", quantity=1, unit="W")),
    ("?3d", _est("unparseable")),
    ("1d (actual ~14h)", _est("unparseable")),
    ("2-3d", _est("unparseable")),
    (["1w", "2w"], _est("unparseable")),
    ("5", _est("unparseable")),
    ("", _est("unparseable")),
    ("9999999999h", _est("unparseable")),
]


@pytest.mark.parametrize("raw,want", EST_ROWS, ids=[repr(r[0]) for r in EST_ROWS])
def test_classify_est(raw, want):
    got = pf.classify_est(raw)
    assert got == {"raw": raw, **want}
    for k in ("low_hours", "high_hours", "quantity"):
        v = got[k]
        if v is not None and float(v).is_integer():
            assert type(v) is int, (k, v)


def test_hour_factors_pinned():
    assert pf.HOUR_FACTORS == {"h": 1, "d": 8, "w": 40}


def test_producer_keys_pinned():
    assert pf.PRODUCER_KEYS == frozenset({"est_src", "satisfies", "h"})


@pytest.mark.parametrize("meta,want", [
    ({}, (None, False)),
    ({"est_src": "confirmed"}, ("confirmed", False)),
    ({"est_src": "derived"}, ("derived", False)),
    ({"est_src": "guessed"}, (None, True)),
    ({"est_src": ""}, (None, True)),
    ({"est_src": ["derived"]}, (None, True)),
])
def test_est_src(meta, want):
    assert pf.est_src(meta) == want


@pytest.mark.parametrize("meta,want", [
    ({}, (None, False)),
    ({"h": "0"}, (0, False)),
    ({"h": "4"}, (4, False)),
    ({"h": "5"}, (None, True)),
    ({"h": "high"}, (None, True)),
    ({"h": "03"}, (None, True)),
    ({"h": ""}, (None, True)),
    ({"h": ["3"]}, (None, True)),
])
def test_read_h(meta, want):
    assert pf.read_h(meta) == want


@pytest.mark.parametrize("meta,want", [
    ({}, (None, False)),
    ({"issue": ""}, (None, False)),
    ({"issue": "Issue-1"}, ("Issue-1", False)),
    ({"issue": "GH-726!"}, ("GH-726!", False)),
    ({"issue": ["Issue-11", "Issue-12"]}, (None, True)),
])
def test_node_issue(meta, want):
    assert pf.node_issue(meta) == want


@pytest.mark.parametrize("v,want", [
    (None, []), ("", []), ([], []), ("x", ["x"]), (["a", "b"], ["a", "b"]),
])
def test_as_list(v, want):
    assert pf.as_list(v) == want


def _dep(raw, scope, project, issue):
    return {"raw": raw, "scope": scope, "project": project, "issue": issue,
            "resolved": None}


@pytest.mark.parametrize("raw,want", [
    ("Issue-8", _dep("Issue-8", "local", "alpha", "Issue-8")),
    ("beta:Issue-2", _dep("beta:Issue-2", "foreign", "beta", "Issue-2")),
    ("alpha:Issue-9", _dep("alpha:Issue-9", "local", "alpha", "Issue-9")),
    (":Issue-1", _dep(":Issue-1", "local", "alpha", ":Issue-1")),
    ("a:b:c", _dep("a:b:c", "local", "alpha", "a:b:c")),
    ("Issue-Fork-134", _dep("Issue-Fork-134", "local", "alpha", "Issue-Fork-134")),
    ("4.1", _dep("4.1", "local", "alpha", "4.1")),
])
def test_split_dep_rule(raw, want):
    assert pf.split_dep(raw, "alpha") == want


@pytest.mark.parametrize("meta", [
    {}, {"depends_on": ""}, {"depends_on": "Issue-1"},
    {"depends_on": ["Issue-1", "beta:Issue-2"]}, {"depends_on": []},
    {"depends_on": [""]},
])
def test_dep_ids_agreement(meta):
    raws = [d["raw"] for d in pf.node_deps(meta, "alpha")]
    assert raws == wbs_parser._dep_ids(meta)


@pytest.mark.parametrize("meta,want", [
    ({}, []), ({"satisfies": "gantry:FR-1"}, ["gantry:FR-1"]),
    ({"satisfies": ["gantry:FR-12", "gantry:UC-3"]}, ["gantry:FR-12", "gantry:UC-3"]),
])
def test_satisfies_reading(meta, want):
    assert pf.as_list(meta.get("satisfies")) == want
