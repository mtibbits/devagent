"""Tests for the portfolio producer (#726): scripts/lib/portfolio.py."""
import ast
import copy
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from functools import lru_cache
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

def _line_of(text, marker):
    hits = [n for n, line in enumerate(text.splitlines(), start=1) if marker in line]
    assert len(hits) == 1, (marker, hits)
    return hits[0]


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
    assert pf.PRODUCER_KEYS == frozenset({"est_src", "satisfies", "h", "thinking", "checking"})


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


def test_read_h_reads_the_parser_rule(monkeypatch):
    # #888: read_h looks the parser's H_RE up at call time; no second rule.
    monkeypatch.setattr(pf.wbs_parser, "H_RE", re.compile(r"[0-9]"))
    assert pf.read_h({"h": "7"}) == (7, False)


def test_split_dep_reads_the_parser_rule(monkeypatch):
    monkeypatch.setattr(pf.wbs_parser, "split_namespaced", lambda raw: None)
    assert pf.split_dep("beta:Issue-2", "alpha")["scope"] == "local"


def test_as_list_reads_the_parser_rule(monkeypatch):
    monkeypatch.setattr(pf.wbs_parser, "as_list", lambda v: ["sentinel"])
    assert pf.as_list("x") == ["sentinel"]


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


# --- reference rollup ----------------------------------------------------------

def _n(state, cls, *, leaf=True, low=None, high=None, quantity=None, unit=None, src=None):
    return {"leaf": leaf, "state": state,
            "est": {"class": cls, "low_hours": low, "high_hours": high,
                    "quantity": quantity, "unit": unit, "src": src}}


def _counts(leaves=0, estimated=0, derived=0, unestimated=0):
    return {"leaves": leaves, "estimated": estimated, "estimated_derived": derived,
            "unestimated": unestimated}


def _by_state(**kw):
    out = {s: _counts() for s in ("pending", "done", "skipped", "stuck", "in_progress",
                                  "blocked_external", "parked")}
    out.update(kw)
    return out


def test_rollup_hand_worked():
    nodes = [
        _n("pending", "non-time", leaf=False, quantity=10.5, unit="pr"),   # parent: never summed
        _n("done", "time", low=6, high=6, src="confirmed"),
        _n("in_progress", "time", low=4, high=8, src="derived"),
        _n("pending", "time", low=2.5, high=2.5, src="confirmed"),
        _n("pending", "non-time", quantity=48, unit="pr"),
        _n("pending", "non-time", quantity=1.5, unit="pt"),
        _n("pending", "placeholder"),
        _n("pending", "absent"),
        _n("skipped", "time", low=3, high=3),
    ]
    # Worked by hand: 8 leaves. pending = n4 (estimated) + n5 n6 n7 n8
    # (unestimated); remaining = pending + in_progress; hours 2.5 + 4 and 2.5 + 8.
    assert pf.rollup(nodes) == {
        "by_state": _by_state(pending=_counts(5, 1, 0, 4), done=_counts(1, 1, 0, 0),
                              in_progress=_counts(1, 0, 1, 0), skipped=_counts(1, 1, 0, 0)),
        "remaining": {"leaves": 6, "estimated": 1, "estimated_derived": 1, "unestimated": 4,
                      "low_hours": 6.5, "high_hours": 10.5,
                      "non_time": {"pr": 48, "pt": 1.5}},
    }


def test_rollup_extremes():
    zero = {"leaves": 0, "estimated": 0, "estimated_derived": 0, "unestimated": 0,
            "low_hours": 0, "high_hours": 0, "non_time": {}}
    assert pf.rollup([]) == {"by_state": _by_state(), "remaining": zero}
    done = [_n("done", "time", low=6, high=6), _n("done", "absent")]
    got = pf.rollup(done)
    assert got["remaining"] == zero
    assert got["by_state"]["done"] == _counts(2, 1, 0, 1)


def _example():
    return json.loads(EXAMPLE.read_text(encoding="utf-8"))


def test_schema_version_matches_live_schema():
    assert pf.SCHEMA_VERSION == pf.pc.load_schema()["version"] == "1.2"


def test_compat_both_directions():
    old_schema = pf.pc.load_schema(FIXTURES / "schema-history" / "1.0.json")
    new_doc = _example()
    new_doc["schema_version"] = "1.1"
    for p in new_doc["projects"]:
        for n in p["nodes"]:
            n["ready_via_parent_row"] = None
    # The old reader reads a new document: an unknown field at a newer minor.
    assert pf.pc.check(new_doc, old_schema) == []
    # The new reader reads an old one.
    assert pf.pc.check(_example()) == []
    # Negative control: the same new field under the old label is an error.
    mislabelled = copy.deepcopy(new_doc)
    mislabelled["schema_version"] = "1.0"
    errors = pf.pc.check(mislabelled, old_schema)
    assert errors
    assert all(e.endswith(".ready_via_parent_row: unknown field") for e in errors), errors


def test_compat_models_both_directions():
    # #890: schema 1.2 adds optional projects[].nodes[].models (Issue-725's
    # both-directions rule, with a mislabelled negative control).
    old_schema = pf.pc.load_schema(FIXTURES / "schema-history" / "1.1.json")
    new_doc = _example()
    new_doc["schema_version"] = "1.2"
    for p in new_doc["projects"]:
        for n in p["nodes"]:
            n["ready_via_parent_row"] = None
            if n["leaf"]:
                n["models"] = {"thinking": {"value": "opus", "source": "wbs"},
                               "checking": None}
    assert pf.pc.check(new_doc, old_schema) == []
    assert pf.pc.check(new_doc) == []
    assert pf.pc.check(_example()) == []
    mislabelled = copy.deepcopy(new_doc)
    mislabelled["schema_version"] = "1.1"
    errors = pf.pc.check(mislabelled, old_schema)
    assert errors
    assert all(e.endswith(".models: unknown field") for e in errors), errors
    # bad shapes on the live reader, each naming its path
    for bad in ({"value": "opus", "source": "x"},
                {"value": "opus", "source": "wbs", "why": "?"},
                {"value": 3, "source": "wbs"}):
        doc = copy.deepcopy(new_doc)
        leaf = next(n for p in doc["projects"] for n in p["nodes"] if n["leaf"])
        leaf["models"]["checking"] = bad
        errors = pf.pc.check(doc)
        assert errors, bad
        assert any(".models.checking" in e for e in errors), (bad, errors)


def test_rollup_matches_example():
    # #725 worked these figures independently of this producer.
    read = [p for p in _example()["projects"] if p["status"] == "read"]
    assert len(read) == 2
    for p in read:
        assert pf.rollup(p["nodes"]) == p["rollup"], p["project"]


# --- invariants I1–I17 ---------------------------------------------------------

def test_example_satisfies_invariants():
    assert pf.invariant_violations(_example()) == []


def _alpha(d):
    return d["projects"][0]


def _node(d, nid):
    return next(n for p in d["projects"] for n in p["nodes"] if n["id"] == nid)


def _entry(d, issue, project=0):
    return next(e for e in d["projects"][project]["issues"] if e["issue"] == issue)


def _at(d, path):
    obj = d
    for k in path:
        obj = obj[k]
    return obj


def _set(path, value):
    def f(d):
        _at(d, path[:-1])[path[-1]] = value
    return f


def _bump(path, delta):
    def f(d):
        _at(d, path[:-1])[path[-1]] += delta
    return f


def _nset(nid, key, value):
    def f(d):
        _node(d, nid)[key] = value
    return f


def _eset(nid, key, value):
    def f(d):
        _node(d, nid)["est"][key] = value
    return f


def _dset(nid, i, key, value):
    def f(d):
        _node(d, nid)["depends_on"][i][key] = value
    return f


def _iset(issue, key, value):
    def f(d):
        _entry(d, issue)[key] = value
    return f


def _many(*fs):
    def f(d):
        for g in fs:
            g(d)
    return f


def _call(fn):
    """A row that mutates by calling fn(d) (for list edits)."""
    return fn


RU = ("projects", 0, "rollup")


def _computed(*fs):
    """A row that first fills the example's readiness fields, then mutates."""
    def f(d):
        pf.apply_readiness(d["projects"], lambda p: lambda *a: None)
        for g in fs:
            g(d)
    return f


def _flip(nid, key):
    def f(d):
        _node(d, nid)[key] = not _node(d, nid)[key]
    return f


def _dflip(nid, i, key):
    def f(d):
        dep = _node(d, nid)["depends_on"][i]
        dep[key] = not dep[key]
    return f

def _meta(nid, key, value):
    return _call(lambda d: _node(d, nid)["meta"].__setitem__(key, value))


def _models(thinking=None, checking=None):
    """A models object from (value, source) pairs; None stays null (#890)."""
    def choice(pair):
        return None if pair is None else {"value": pair[0], "source": pair[1]}
    return {"thinking": choice(thinking), "checking": choice(checking)}


# (tag, row id, mutation). The unmutated example is the control (it returns []).
MUTATION_ROWS = [
    ("I1", "duplicate-id", _nset("n9", "id", "n1")),
    ("I2", "source-line-order", _nset("n3", "source_line", 4)),
    ("I2", "parent-not-an-id", _nset("n2", "parent", "zz")),
    ("I2", "parent-later", _many(_nset("n2", "parent", "n3"), _nset("n2", "depth", 3))),
    ("I2", "parent-other-project", _many(_nset("n9", "parent", "n1"), _nset("n9", "depth", 2))),
    ("I2", "parent-not-shallower", _nset("n2", "depth", 1)),
    ("I3", "leaf-true-on-parent", _nset("n1", "leaf", True)),
    ("I3", "leaf-false-childless", _nset("n2", "leaf", False)),
    ("I3", "ready-on-parent", _nset("n1", "ready", False)),
    ("I4", "issue-differs", _nset("n2", "issue", "Issue-99")),
    ("I4", "issue-without-meta", _nset("n1", "issue", "Issue-8")),
    ("I5", "missing-entry", _call(lambda d: _alpha(d)["issues"].pop(0))),
    ("I5", "extra-entry", _call(lambda d: _alpha(d)["issues"].append(
        dict(_entry(d, "Issue-8"), issue="Issue-77")))),
    ("I5", "nodes-order", _iset("Issue-10", "nodes", ["n5", "n4"])),
    ("I5", "nodes-empty", _iset("Issue-10", "nodes", [])),
    ("I6", "raw-differs", _eset("n2", "raw", "7h")),
    ("I6", "absent-with-raw", _many(_eset("n2", "class", "absent"), _eset("n2", "low_hours", None),
                                    _eset("n2", "high_hours", None))),
    ("I6", "time-null-hours", _eset("n2", "low_hours", None)),
    ("I6", "time-low-gt-high", _eset("n2", "low_hours", 7)),
    ("I6", "time-negative", _many(_eset("n2", "low_hours", -1), _eset("n2", "high_hours", -1))),
    ("I6", "time-with-unit", _eset("n2", "unit", "h")),
    ("I6", "non-time-with-hours", _eset("n1", "low_hours", 1)),
    ("I6", "non-time-empty-unit", _eset("n1", "unit", "")),
    ("I6", "other-with-quantity", _eset("n4", "quantity", 1)),
    ("I7", "src-differs", _eset("n2", "src", "derived")),
    ("I7", "src-when-invalid", _call(lambda d: _node(d, "n2")["meta"].__setitem__("est_src", "guessed"))),
    ("I8", "satisfies-differs", _nset("n3", "satisfies", ["x"])),
    ("I9", "h-differs", _nset("n3", "h", 2)),
    ("I9", "h-when-malformed", _nset("n5", "h", 1)),
    ("I10", "raw-order", _call(lambda d: _node(d, "n3")["depends_on"].reverse())),
    ("I10", "foreign-own-project", _dset("n3", 0, "scope", "foreign")),
    ("I10", "foreign-raw-mismatch", _dset("n3", 1, "issue", "Issue-3")),
    ("I10", "local-other-project", _dset("n3", 0, "project", "beta")),
    ("I10", "empty-issue", _dset("n3", 0, "issue", "")),
    ("I11", "duplicate-key", _call(lambda d: _node(d, "n3")["meta_unknown_keys"].append("h"))),
    ("I11", "key-not-in-meta", _call(lambda d: _node(d, "n2")["meta_unknown_keys"].append("zzz"))),
    ("I12", "duplicate-project", _set(("projects", 1, "project"), "alpha")),
    ("I12", "read-null-rollup", _set(("projects", 1, "rollup"), None)),
    ("I12", "read-null-title", _set(("projects", 1, "wbs_title"), None)),
    ("I12", "non-read-with-nodes", _call(lambda d: d["projects"][2]["nodes"].append(
        dict(copy.deepcopy(_node(d, "n9")), id="n99")))),
    ("I12", "non-read-with-rollup", _call(lambda d: d["projects"][2].__setitem__(
        "rollup", copy.deepcopy(d["projects"][1]["rollup"])))),
    ("I12", "unreadable-empty-reason", _many(_set(("projects", 2, "status"), "unreadable"),
                                             _set(("projects", 2, "status_reason"), ""))),
    ("I12", "read-with-reason", _set(("projects", 0, "status_reason"), "x")),
    ("I12", "non-read-null-reason", _set(("projects", 3, "status_reason"), None)),
    ("I13", "count-plus-one", _bump(RU + ("by_state", "pending", "leaves"), 1)),
    ("I13", "hours-off-1e-3", _bump(RU + ("remaining", "low_hours"), 1e-3)),
    ("I13", "non-time-keys", _set(RU + ("remaining", "non_time", "pt"), 0)),
    ("I14", "open-null-next-step", _iset("Issue-9", "next_step", None)),
    ("I14", "complete-with-next-step", _iset("Issue-8", "next_step", "draft")),
    ("I15", "report-unknown-project", _call(lambda d: d["parse_report"].append(
        {"project": "nosuch", "source_line": None, "kind": "x", "message": "m"}))),
    ("I16", "ready-flipped", _computed(_flip("n6", "ready"))),
    ("I16", "resolved-flipped", _computed(_dflip("n3", 0, "resolved"))),
    ("I16", "via-parent-row-on-parent", _computed(_nset("n1", "ready_via_parent_row", False))),
    ("I16", "partial-null", _computed(_nset("n7", "ready", None))),
    ("I16", "leaf-via-parent-row-flipped", _computed(_flip("n6", "ready_via_parent_row"))),
    ("I16", "resolved-only-on-uncomputed", _dset("n3", 0, "resolved", True)),
    ("I16", "via-parent-row-only-on-uncomputed", _nset("n6", "ready_via_parent_row", False)),
    ("I16", "computed-with-duplicate-id", _computed(_nset("n9", "id", "n1"))),
    ("I17", "models-on-parent", _nset("n1", "models", {"thinking": None, "checking": None})),
    ("I17", "models-missing-at-1.2", _set(("schema_version",), "1.2")),
    ("I17", "wbs-value-differs", _many(_meta("n2", "thinking", "opus"),
                                       _nset("n2", "models", _models(("sonnet", "wbs"))))),
    ("I17", "project-source-with-legal-key",
     _many(_meta("n2", "thinking", "opus"), _nset("n2", "models", _models(("opus", "project"))))),
    ("I17", "value-not-a-token", _nset("n2", "models", _models(("gpt", "project")))),
]

# Rows that must NOT fire.
SURVIVE_ROWS = [
    ("I13", "hours-off-1e-12", _bump(RU + ("remaining", "low_hours"), 1e-12)),
    ("I16", "computed-clean", _computed()),
    ("I17", "models-consistent", _many(_meta("n2", "thinking", "opus"),
                                       _nset("n2", "models", _models(("opus", "wbs"),
                                                                     ("haiku", "project"))))),
]


@pytest.mark.parametrize("tag,row,mutate", MUTATION_ROWS,
                         ids=[f"{t}-{r}" for t, r, _ in MUTATION_ROWS])
def test_invariant_mutation(tag, row, mutate):
    d = _example()
    mutate(d)
    got = pf.invariant_violations(d)
    assert any(v.startswith(f"{tag}: ") for v in got), got


@pytest.mark.parametrize("tag,row,mutate", SURVIVE_ROWS,
                         ids=[f"{t}-{r}" for t, r, _ in SURVIVE_ROWS])
def test_invariant_must_not_fire(tag, row, mutate):
    d = _example()
    mutate(d)
    assert pf.invariant_violations(d) == []


def test_invariant_rows_total():
    tags = {t for t, _, _ in MUTATION_ROWS}
    assert tags == set(pf.INVARIANTS)
    assert pf.INVARIANTS == tuple(f"I{i}" for i in range(1, 18))
    assert len(MUTATION_ROWS) == 58 + 5
    assert len({(t, r) for t, r, _ in MUTATION_ROWS}) == len(MUTATION_ROWS)


def test_i16_duplicate_id_reports_without_raising():
    d = _example()
    _computed(_nset("n9", "id", "n1"))(d)
    got = pf.invariant_violations(d)
    assert any(v.startswith("I1: ") for v in got), got
    assert any(v.startswith("I16: ") for v in got), got


def test_i16_messages():
    d = _example()
    _computed(_flip("n6", "ready"), _dflip("n3", 0, "resolved"),
              _nset("n1", "ready_via_parent_row", False))(d)
    assert sorted(pf.invariant_violations(d)) == sorted([
        "I16: node n6: ready False != recomputed True",
        "I16: node n3: depends_on[0].resolved False != recomputed True",
        "I16: node n1: ready_via_parent_row False != recomputed None",
    ])


def test_newer_minor_known_fields_only():
    d = _example()
    d["schema_version"] = "1.1"
    d["future_root"] = {"a": 1}
    d["projects"][0]["future_project"] = [1]
    d["projects"][0]["nodes"][0]["future_node"] = "x"
    assert pf.invariant_violations(d) == []


def test_checker_exit0_is_not_correctness():
    d = _example()
    _bump(RU + ("by_state", "pending", "leaves"), 1)(d)
    assert pf.pc.check(d) == []
    assert pf.invariant_violations(d) != []


# --- issue-directory readers ---------------------------------------------------

CHECKLISTS = FIXTURES / "checklists"

# The same subjects the bats differential checks against lib/checklist.sh
# (checklist_current_step + checklist_step_name), pinned here as literals.
CHECKLIST_CASES = [
    ("legacy-open.md", ("open", 5, "improve")),
    ("rev2-open.md", ("open", 5, "improve")),
    ("all-done.md", ("complete", None, None)),
    ("empty-active.md", "error"),
    ("no-rows.md", "error"),
    ("stuck-glyph.md", ("open", 9, "implement")),
    ("parked.md", ("open", 4, "scope")),
    ("blocked.md", ("open", 20, "mergemr")),
]


@pytest.mark.parametrize("name,want", CHECKLIST_CASES, ids=[c[0] for c in CHECKLIST_CASES])
def test_checklist_next_cases(name, want):
    path = CHECKLISTS / name
    if want == "error":
        with pytest.raises(pf.ChecklistError):
            pf.checklist_next(path)
    else:
        assert pf.checklist_next(path) == want


def test_checklist_next_crlf(tmp_path):
    p = tmp_path / "checklist.md"
    p.write_bytes((CHECKLISTS / "rev2-open.md").read_bytes().replace(b"\n", b"\r\n"))
    assert pf.checklist_next(p) == ("open", 5, "improve")


def test_checklist_next_undecodable(tmp_path):
    p = tmp_path / "checklist.md"
    p.write_bytes(b"- [ ]  2. draft\n\xff\xfe\n")
    with pytest.raises(pf.ChecklistError):
        pf.checklist_next(p)


def test_step_row_re_twins_tracker():
    # The name-less half must stay wbs-tracker.py's ROW_RE (checklist.sh:67).
    tracker = _load("wbs_tracker_for_portfolio_tests", LIB / "wbs-tracker.py")
    assert pf.STEP_ROW_RE.pattern.replace("([A-Za-z][A-Za-z0-9_-]*)", "[A-Za-z][A-Za-z0-9_-]*") \
        == tracker.ROW_RE.pattern


def test_finished_glyph_sets_agree():
    # #865: three literal copies of "no work left" (done or skipped), on
    # purpose: WBS node glyphs (wbs-parser.py FINISHED_GLYPHS) and checklist
    # step rows (wbs-tracker.py and portfolio.py DONE_GLYPHS). No production
    # module imports another for it; this leg ties them.
    tracker = _load("wbs_tracker_for_portfolio_tests", LIB / "wbs-tracker.py")
    assert set(tracker.DONE_GLYPHS) == set(pf.DONE_GLYPHS) == set(wbs_parser.FINISHED_GLYPHS) \
        == {g for g, s in wbs_parser.STATE_GLYPHS.items() if s in ("done", "skipped")}


STUCK_SH = (
    "Step:        9 implement\n"
    "Reason:      waiting on the operator's call on the token key\n"
    "Last good:   step 8 branch\n"
    "Created:     2026-11-04 08:47\n"
)
CHECKLIST_STUCK_SH = (
    "Step:        16 redmr\n"
    "Reason:      red-team found a blocker\n"
    "Last good:   (none)\n"
    "Created:     2026-11-04T08:47:12-05:00\n"
)


def test_read_stuck_both_writers(tmp_path):
    p = tmp_path / "STUCK"
    p.write_text(STUCK_SH, encoding="utf-8", newline="")
    assert pf.read_stuck(p) == {"step": "9 implement",
                                "reason": "waiting on the operator's call on the token key",
                                "since": "2026-11-04 08:47"}
    p.write_bytes(CHECKLIST_STUCK_SH.replace("\n", "\r\n").encode("utf-8"))
    assert pf.read_stuck(p) == {"step": "16 redmr", "reason": "red-team found a blocker",
                                "since": "2026-11-04T08:47:12-05:00"}
    p.write_text("Step:        9 implement\nCreated:     2026-11-04 08:47\n",
                 encoding="utf-8", newline="")
    assert pf.read_stuck(p) == {"step": "9 implement", "reason": None,
                                "since": "2026-11-04 08:47"}


def test_read_stuck_undecodable(tmp_path):
    p = tmp_path / "STUCK"
    p.write_bytes(b"Step: 9 implement\n\xff\n")
    with pytest.raises(pf.StuckError):
        pf.read_stuck(p)


# --- build the document --------------------------------------------------------


MULTI = FIXTURES / "multi"
GENERATED_AT = "2026-11-06T00:00:00Z"
CONFIG_ORDER = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota"]


def _multi(tmp_path):
    """The fixture devdocs in tmp, plus the binary/eol-unsafe parts generated."""
    root = tmp_path / "multi"
    shutil.copytree(MULTI, root)
    (root / "epsilon").mkdir()
    (root / "epsilon" / "WBS.md").write_bytes(b"# epsilon\n- [ ] bad \xff byte\n")
    (root / "zeta" / "WBS.md").mkdir(parents=True)
    (root / "alpha" / "Issue-5").mkdir()
    (root / "alpha" / "Issue-5" / "STUCK").write_bytes(b"Step: 9 implement\n\xfe\xff\n")
    devdoc = {"alpha": root / "alpha", "beta": root / "beta", "gamma": root / "gamma",
              "delta": None, "epsilon": root / "epsilon", "zeta": root / "zeta",
              "eta": root / "eta", "theta": root / "theta", "iota": ""}
    projects = [pf.ProjectInput(name, None if devdoc[name] is None else str(devdoc[name]), None)
                for name in CONFIG_ORDER]
    return root, projects


def _build(tmp_path):
    root, projects = _multi(tmp_path)
    return root, pf.build_document(projects, GENERATED_AT)


@lru_cache(maxsize=None)
def _wbs_text(project, root=MULTI):
    return (root / project / "WBS.md").read_bytes().decode("utf-8")


def _project(doc, name):
    return next(p for p in doc["projects"] if p["project"] == name)


def test_build_validates(tmp_path):
    _, doc = _build(tmp_path)
    assert pf.pc.check(doc) == []
    assert pf.invariant_violations(doc) == []


def test_build_statuses(tmp_path):
    _, doc = _build(tmp_path)
    got = [(p["project"], p["status"], p["status_reason"]) for p in doc["projects"]]
    assert got[:4] == [
        ("alpha", "read", None),
        ("beta", "read", None),
        ("gamma", "no_wbs", pf.REASON_NO_WBS),
        ("delta", "no_devdoc_dir", pf.REASON_UNSET),
    ]
    assert got[4][:2] == ("epsilon", "unreadable")
    assert got[4][2].startswith("WBS.md could not be read: UnicodeDecodeError: ")
    assert got[5:] == [
        ("zeta", "unreadable", pf.REASON_NOT_FILE),
        ("eta", "no_devdoc_dir", pf.REASON_ABSENT),
        ("theta", "read", None),
        ("iota", "no_devdoc_dir", pf.REASON_EMPTY),
    ]


def test_reasons_pinned():
    assert (pf.REASON_UNSET, pf.REASON_EMPTY, pf.REASON_ABSENT, pf.REASON_NOT_DIR,
            pf.REASON_NO_WBS, pf.REASON_NOT_FILE, pf.REASON_UNREADABLE) == (
        "no devdoc dir is configured", "devdoc_dir is set but empty",
        "the devdoc dir does not exist", "the devdoc dir is not a directory",
        "the devdoc dir has no WBS.md",
        "WBS.md is not a regular file", "WBS.md could not be read: {}")


# (project, marker or None, kind), in the report's documented order (D11).
REPORT = [
    ("alpha", None, "checklist_unreadable"),
    ("alpha", None, "stuck_unreadable"),
    ("alpha", "wbs-exclude", "directive_warning"),
    ("alpha", "plant-scope", "directive_warning"),
    ("alpha", "plant-dup3", "duplicate_issue"),
    ("alpha", "plant-dup3", "h_malformed"),
    ("alpha", "plant-noissue-est", "leaf_no_issue"),
    ("alpha", "plant-noissue-est", "est_unparseable"),
    ("alpha", "plant-outline", "leaf_no_issue"),
    ("alpha", "plant-outline", "dep_unresolved"),
    ("alpha", "plant-issue4", "dep_unresolved"),
    ("alpha", "plant-issue4", "dep_unresolved"),
    ("alpha", "plant-issue4", "dep_unresolved"),
    ("alpha", "plant-est-src", "est_src_invalid"),
    ("alpha", "plant-jira", "unknown_meta_key"),
    ("alpha", "plant-merged", "unknown_meta_key"),
    ("alpha", "plant-merged", "meta_unreadable"),
    ("alpha", "plant-bracket", "dep_unresolved"),
    ("alpha", "plant-bracket", "meta_unreadable"),
    ("alpha", "plant-trailing", "meta_unreadable"),
    ("alpha", "plant-dupkey", "meta_duplicate_key"),
    ("alpha", "plant-swallowed", "issue_not_id"),
    ("alpha", "plant-swallowed", "meta_unreadable"),
    ("alpha", "plant-issue-list", "issue_malformed"),
    ("alpha", "plant-not-id", "issue_not_id"),
    ("alpha", "plant-near-x", "near_miss_line"),
    ("alpha", "plant-near-star", "near_miss_line"),
    ("beta", "plant-beta-fence", "parser_warning"),
]


def test_build_report_literal(tmp_path):
    _, doc = _build(tmp_path)
    want = [(p, None if m is None else _line_of(_wbs_text(p), m), k) for p, m, k in REPORT]
    got = [(r["project"], r["source_line"], r["kind"]) for r in doc["parse_report"]]
    assert got == want


def test_kinds_all_planted(tmp_path):
    _, doc = _build(tmp_path / "multi-build")
    ready = _ready_build(tmp_path / "ready-build")
    models = _models_build(tmp_path / "models-build")
    kinds = {r["kind"] for d in (doc, ready, models) for r in d["parse_report"]}
    assert kinds == set(pf.KINDS)
    assert len(pf.KINDS) == len(set(pf.KINDS)) == 20


def _walk_lines(tree):
    out, stack = [], list(reversed(tree["children"]))
    while stack:
        n = stack.pop()
        out.append(n["source_line"])
        stack.extend(reversed(n["children"]))
    return out


def test_build_no_node_missing(tmp_path):
    root, doc = _build(tmp_path)
    counts = {}
    for p in doc["projects"]:
        if p["status"] != "read":
            continue
        tree = wbs_parser.parse_file(root / p["project"] / "WBS.md")
        assert [n["source_line"] for n in p["nodes"]] == _walk_lines(tree)
        counts[p["project"]] = len(p["nodes"])
    assert counts == {"alpha": 18, "beta": 3, "theta": 0}


def test_cross_project_same_issue(tmp_path):
    _, doc = _build(tmp_path)
    a = next(e for e in _project(doc, "alpha")["issues"] if e["issue"] == "Issue-1")
    b = next(e for e in _project(doc, "beta")["issues"] if e["issue"] == "Issue-1")
    assert (a["checklist"], b["checklist"]) == ("complete", "absent")
    assert not any(r["kind"] == "duplicate_issue" and "Issue-1" in r["message"]
                   for r in doc["parse_report"])


def test_foreign_resolution(tmp_path):
    _, doc = _build(tmp_path)
    deps = [r for r in doc["parse_report"] if r["kind"] == "dep_unresolved"]
    assert sorted(r["message"] for r in deps) == sorted([
        "depends_on '4.1' matches no issue in this project",
        "depends_on 'beta:Issue-99' matches no issue in project 'beta'",
        "depends_on 'nosuch:Issue-1' names project 'nosuch', which is not configured",
        "depends_on 'gamma:Issue-1' names project 'gamma', whose WBS was not read (no_wbs)",
        "depends_on 'Issue-1, est: 1w' matches no issue in this project",
    ])
    all_deps = [d for p in doc["projects"] for n in p["nodes"] for d in n["depends_on"]]
    assert {d["raw"] for d in all_deps} >= {"beta:Issue-1", "alpha:Issue-1", "alpha:Issue-2"}
    # Every resolved is a bool: False for exactly the 5 raws named above.
    assert all(isinstance(d["resolved"], bool) for d in all_deps)
    assert sorted(d["raw"] for d in all_deps if not d["resolved"]) == sorted([
        "4.1", "beta:Issue-99", "nosuch:Issue-1", "gamma:Issue-1", "Issue-1, est: 1w"])


def test_producer_keys_not_reported_unknown(tmp_path):
    _, doc = _build(tmp_path)
    msgs = [r["message"] for r in doc["parse_report"] if r["kind"] == "unknown_meta_key"]
    assert msgs == ["unknown metadata key 'jira'", "unknown metadata key 'foo, est'"]
    for project in doc["projects"]:
        for node in project.get("nodes") or []:
            assert not {"satisfies", "objective", "h"} & set(node["meta_unknown_keys"])
    # est_src stays parser-unknown: PRODUCER_KEYS' skip path still runs (#888).
    issue2 = next(n for n in _project(doc, "alpha")["nodes"] if n["issue"] == "Issue-2")
    assert issue2["meta_unknown_keys"] == ["est_src"]


def test_objective_exported_as_written(tmp_path):
    # #888: objective is a known key; meta keeps it as written.
    _, doc = _build(tmp_path)
    nodes = _project(doc, "alpha")["nodes"]
    issue2 = next(n for n in nodes if n["issue"] == "Issue-2")
    assert issue2["meta"]["objective"] == ["gantry:UC-3"]
    est = next(n for n in nodes if "plant-noissue-est" in n["text"])
    assert est["meta"]["objective"] == "gantry:FR-1"
    assert not [r for r in doc["parse_report"] if "'objective'" in r["message"]]


def test_parser_stderr_captured(tmp_path, capsys):
    _, doc = _build(tmp_path)
    warn = [r for r in doc["parse_report"] if r["kind"] == "parser_warning"]
    fence = _line_of(_wbs_text("beta"), "plant-beta-fence")
    assert [(r["project"], r["source_line"]) for r in warn] == [("beta", fence)]
    assert warn[0]["message"].startswith(f"wbs-parser: unclosed code fence at line {fence}")
    assert capsys.readouterr().err == ""


def test_issue_dir_fields(tmp_path):
    _, doc = _build(tmp_path)
    alpha = {e["issue"]: e for e in _project(doc, "alpha")["issues"]}
    pick = lambda e: (e["checklist"], e["next_step_number"], e["next_step"], e["stuck"])  # noqa: E731
    assert pick(alpha["Issue-1"]) == ("complete", None, None, None)
    assert pick(alpha["Issue-2"]) == ("open", 5, "improve", {
        "step": "16 redmr", "reason": "red-team found a blocker", "since": "2026-11-04 08:47"})
    assert pick(alpha["Issue-3"]) == ("absent", None, None, None)
    assert pick(alpha["Issue-4"]) == ("absent", None, None, None)
    assert pick(alpha["Issue-5"]) == ("absent", None, None,
                                      {"step": None, "reason": None, "since": None})
    assert pick(alpha["GH-726!"]) == ("absent", None, None, None)
    report = {r["kind"]: r["message"] for r in doc["parse_report"] if r["source_line"] is None}
    assert report["checklist_unreadable"].startswith("Issue-4/checklist.md could not be read: ")
    assert report["stuck_unreadable"].startswith("Issue-5/STUCK could not be read: ")
    assert str(tmp_path) not in json.dumps(doc["parse_report"])
    assert alpha["Issue-3"]["nodes"] == [n["id"] for n in _project(doc, "alpha")["nodes"]
                                         if n["issue"] == "Issue-3"]


def test_build_deterministic(tmp_path):
    root, projects = _multi(tmp_path)
    assert pf.build_document(projects, GENERATED_AT) == pf.build_document(projects, GENERATED_AT)


def _tree_hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


def test_build_writes_nothing_under_devdocs(tmp_path):
    root, projects = _multi(tmp_path)
    before = _tree_hashes(root)
    assert before
    pf.build_document(projects, GENERATED_AT)
    assert _tree_hashes(root) == before
    (root / "theta" / "WBS.md").write_bytes(b"# theta WBS changed\n")
    assert _tree_hashes(root) != before


def test_empty_wbs_rollup(tmp_path):
    _, doc = _build(tmp_path)
    theta = _project(doc, "theta")
    assert (theta["status"], theta["wbs_title"], theta["nodes"], theta["issues"]) == (
        "read", "theta WBS", [], [])
    assert theta["rollup"] == pf.rollup([])


def test_node_ids_config_then_source_order(tmp_path):
    _, doc = _build(tmp_path)
    ids = [n["id"] for p in doc["projects"] for n in p["nodes"]]
    assert ids == [f"n{i}" for i in range(1, len(ids) + 1)]


# --- readiness (#727) ----------------------------------------------------------

READY = FIXTURES / "ready"
READY_EXPECTED = FIXTURES / "ready-expected.tsv"


def _ready_text(project):
    return _wbs_text(project, READY)


def _ready_copy(tmp_path):
    root = tmp_path / "ready"
    shutil.copytree(READY, root)
    return root


def _ready_build(tmp_path):
    """The rho/sigma readiness fixture, copied to tmp and built in that order."""
    root = _ready_copy(tmp_path)
    projects = [pf.ProjectInput("rho", str(root / "rho")),
                pf.ProjectInput("sigma", str(root / "sigma"))]
    return pf.build_document(projects, GENERATED_AT)


def _by_marker(doc, project, marker):
    line = _line_of(_ready_text(project), marker)
    return next(n for n in _project(doc, project)["nodes"] if n["source_line"] == line)


# (project, marker, ready): every leaf of the fixture, derived by hand from
# the rule in commands/portfolio.md.
READY_ROWS = [
    ("rho", "rdy-t-done", False),
    ("rho", "rdy-t-pending", True),
    ("rho", "rdy-t-skipped", False),
    ("rho", "rdy-t-twin-a", False),
    ("rho", "rdy-t-twin-b", True),
    ("rho", "rdy-t-both-a", False),
    ("rho", "rdy-t-both-b", False),
    ("rho", "rdy-nodeps", True),
    ("rho", "rdy-inprogress", False),
    ("rho", "rdy-on-done", True),
    ("rho", "rdy-on-pending", False),
    ("rho", "rdy-outline", False),
    ("rho", "rdy-on-skipped", False),
    ("rho", "rdy-on-twin", False),
    ("rho", "rdy-on-both", True),
    ("rho", "rdy-noissue", True),
    ("rho", "rdy-tab", True),
    ("rho", "rdy-own-prefix", True),
    ("rho", "rdy-bare-foreign", False),
    ("rho", "rdy-foreign-done", True),
    ("rho", "rdy-foreign-pending", False),
    ("rho", "rdy-foreign-noissue", False),
    ("rho", "rdy-foreign-noproject", False),
    ("rho", "rdy-cycle-a", False),
    ("rho", "rdy-cycle-b", False),
    ("rho", "rdy-xcycle", False),
    ("rho", "rdy-c-dep", False),
    ("rho", "rdy-c-parked", False),
    ("rho", "rdy-c-stuck", False),
    ("rho", "rdy-c-blocked", False),
    ("rho", "rdy-c-skipped", False),
    ("rho", "rdy-c-inprogress", True),
    ("rho", "rdy-c-done", True),
    ("rho", "rdy-c-handset", False),
    ("rho", "rdy-on-handset", True),
    ("rho", "rdy-t-mix-a", False),
    ("rho", "rdy-t-mix-b", False),
    ("rho", "rdy-on-mix", False),
    ("rho", "rdy-dcycle-a", False),
    ("rho", "rdy-dcycle-b", False),
    ("rho", "rdy-utf8", True),
    ("rho", "rdy-c-inherit", True),
    ("sigma", "rdy-s-done", False),
    ("sigma", "rdy-s-pending", True),
    ("sigma", "rdy-s-xcycle", False),
]


@pytest.fixture(scope="module")
def ready_doc(tmp_path_factory):
    return _ready_build(tmp_path_factory.mktemp("ready-doc"))


@pytest.mark.parametrize("project,marker,want", READY_ROWS, ids=[r[1] for r in READY_ROWS])
def test_ready_rules(ready_doc, project, marker, want):
    node = _by_marker(ready_doc, project, marker)
    assert node["leaf"] is True
    assert node["ready"] is want


def test_ready_rows_cover_every_leaf(ready_doc):
    got = {(p["project"], n["source_line"]) for p in ready_doc["projects"]
           for n in p["nodes"] if n["leaf"]}
    want = {(p, _line_of(_ready_text(p), m)) for p, m, _ in READY_ROWS}
    assert got == want


def test_bare_issue_in_other_project_does_not_resolve(ready_doc):
    node = _by_marker(ready_doc, "rho", "rdy-bare-foreign")
    assert node["depends_on"][0]["resolved"] is False
    assert node["ready"] is False
    assert {"project": "rho", "source_line": node["source_line"], "kind": "dep_unresolved",
            "message": "depends_on 'Issue-90' matches no issue in this project"} \
        in ready_doc["parse_report"]


def _one_leaf_doc(tmp_path, glyph):
    devdoc = tmp_path / "solo"
    devdoc.mkdir()
    (devdoc / "WBS.md").write_bytes(f"# solo\n\n- [{glyph}] leaf {{issue: Issue-1}}\n".encode())
    return pf.build_document([pf.ProjectInput("solo", str(devdoc))], GENERATED_AT)


@pytest.mark.parametrize("glyph,want", [("x", False), ("-", False), ("!", False),
                                        ("~", False), ("?", False), ("P", False),
                                        (" ", True)],
                         ids=["x", "-", "!", "~", "?", "P", "control"])
def test_ready_non_pending_leaf_states(tmp_path, glyph, want):
    doc = _one_leaf_doc(tmp_path, glyph)
    (leaf,) = doc["projects"][0]["nodes"]
    assert leaf["glyph"] == glyph
    assert leaf["ready"] is want


def test_ready_null_exactly_on_parents(tmp_path, ready_doc):
    _, multi = _build(tmp_path)
    seen = {"parent": 0, "leaf": 0}
    for doc in (ready_doc, multi):
        for p in doc["projects"]:
            for n in p["nodes"]:
                if n["leaf"]:
                    seen["leaf"] += 1
                    assert isinstance(n["ready"], bool), n["id"]
                    assert isinstance(n["ready_via_parent_row"], bool), n["id"]
                else:
                    seen["parent"] += 1
                    assert n["ready"] is None, n["id"]
                    assert n["ready_via_parent_row"] is None, n["id"]
    assert seen["parent"] and seen["leaf"]


def test_resolved_values(ready_doc):
    def resolved(marker):
        return _by_marker(ready_doc, "rho", marker)["depends_on"][0]["resolved"]
    for marker in ("rdy-on-done", "rdy-own-prefix", "rdy-foreign-done",
                   "rdy-foreign-pending", "rdy-on-twin"):
        assert resolved(marker) is True, marker
    for marker in ("rdy-outline", "rdy-bare-foreign", "rdy-foreign-noissue",
                   "rdy-foreign-noproject"):
        assert resolved(marker) is False, marker
    all_deps = [d for p in ready_doc["projects"] for n in p["nodes"] for d in n["depends_on"]]
    unresolved = [r for r in ready_doc["parse_report"] if r["kind"] == "dep_unresolved"]
    assert sum(d["resolved"] is False for d in all_deps) == len(unresolved)


def test_ready_via_parent_row_values(ready_doc):
    for marker, want in (("rdy-on-handset", True), ("rdy-c-inherit", True),
                         ("rdy-on-done", False), ("rdy-nodeps", False)):
        assert _by_marker(ready_doc, "rho", marker)["ready_via_parent_row"] is want, marker


def test_ready_report_literal(ready_doc):
    rho, sigma = _ready_text("rho"), _ready_text("sigma")
    L = lambda m: _line_of(rho, m)  # noqa: E731
    skipped = "resolves to a skipped row at line {}; leaves that depend on it are not ready"
    # Hand-written from portfolio.py's dep_unresolved templates and the plan's
    # D3, in the producer's report order (project, line, kind).
    want = [
        ("rho", "rdy-outline", "dep_unresolved",
         "depends_on '4.1' matches no issue in this project"),
        ("rho", "rdy-on-skipped", "dep_skipped",
         "depends_on 'Issue-3' " + skipped.format(L("rdy-t-skipped"))),
        ("rho", "rdy-bare-foreign", "dep_unresolved",
         "depends_on 'Issue-90' matches no issue in this project"),
        ("rho", "rdy-foreign-noissue", "dep_unresolved",
         "depends_on 'sigma:Issue-99' matches no issue in project 'sigma'"),
        ("rho", "rdy-foreign-noproject", "dep_unresolved",
         "depends_on 'nosuch:Issue-1' names project 'nosuch', which is not configured"),
        ("rho", "rdy-cycle-a", "dep_cycle",
         f"dependency cycle: Issue-25 (line {L('rdy-cycle-a')}), "
         f"Issue-26 (line {L('rdy-cycle-b')})"),
        ("rho", "rdy-xcycle", "dep_cycle",
         f"dependency cycle: Issue-27 (line {L('rdy-xcycle')}), "
         f"sigma:Issue-92 (line {_line_of(sigma, 'rdy-s-xcycle')})"),
        ("rho", "rdy-p-done", "parent_done_leaf_pending",
         f"parent is marked done but leaves under it are pending: line {L('rdy-c-done')}"),
        ("rho", "rdy-on-mix", "dep_skipped",
         "depends_on 'Issue-7' " + skipped.format(L("rdy-t-mix-a"))),
        ("rho", "rdy-dcycle-a", "dep_cycle",
         f"dependency cycle: Issue-41 (line {L('rdy-dcycle-a')}), "
         f"Issue-42 (line {L('rdy-dcycle-b')})"),
    ]
    want = [(p, L(m), k, msg) for p, m, k, msg in want]
    kinds = {"dep_unresolved", "dep_skipped", "dep_cycle", "parent_done_leaf_pending"}
    got = [(r["project"], r["source_line"], r["kind"], r["message"])
           for r in ready_doc["parse_report"] if r["kind"] in kinds]
    assert got == want


def _expected_lines():
    return READY_EXPECTED.read_bytes().decode("utf-8").removesuffix("\n").split("\n")


def test_ready_lines_literal(ready_doc):
    assert pf.ready_lines(ready_doc) == _expected_lines()


def test_ready_lines_deterministic(tmp_path):
    a = pf.ready_lines(_ready_build(tmp_path / "a"))
    b = pf.ready_lines(_ready_build(tmp_path / "b"))
    assert a == b
    assert len(a) == 15


def test_ready_lines_empty_extreme(tmp_path):
    _, projects = _multi(tmp_path)
    keep = [p for p in projects if p.name in ("theta", "delta")]
    assert [p.name for p in keep] == ["delta", "theta"]
    assert pf.ready_lines(pf.build_document(keep, GENERATED_AT)) == []


# The multi fixture's ready leaves, derived by hand from the rule: alpha's
# leaves that are pending and have no or only resolved-and-done dependencies
# (plant-outline, plant-issue4 and plant-bracket hold unresolved entries;
# plant-issue1 is done, plant-issue2 in progress), and beta's two pending
# leaves without a dependency (plant-beta-dep waits on alpha's in-progress
# Issue-2).
MULTI_READY = [
    ("alpha", m) for m in ("plant-issue3", "plant-dup3", "plant-noissue-est", "plant-est-src",
                           "plant-jira", "plant-merged", "plant-trailing", "plant-dupkey",
                           "plant-swallowed", "plant-issue-list", "plant-not-id",
                           "plant-issue5")
] + [("beta", "plant-beta-issue1"), ("beta", "plant-beta-after")]


def test_multi_ready_pinned(tmp_path):
    _, doc = _build(tmp_path)
    got = {(p["project"], n["source_line"]) for p in doc["projects"]
           for n in p["nodes"] if n["ready"] is True}
    want = {(p, _line_of(_wbs_text(p), m)) for p, m in MULTI_READY}
    assert len(want) == 14
    assert got == want


def test_build_validates_ready_fixture(ready_doc):
    assert pf.pc.check(ready_doc) == []
    assert pf.invariant_violations(ready_doc) == []


# --- write path and CLI --------------------------------------------------------

# --- models (#890) ------------------------------------------------------------

MODELS = FIXTURES / "models"
# step_models per fixture project, as portfolio.sh exports them.
MODELS_CONFIG = {"mu": {}, "nu": {"thinking": "sonnet", "9": "fable"},
                 "xi": {"default": "haiku"},
                 "omicron": {"thinking": "gpt", "default": "opus"}, "pi": {}}
TOKENS = "sonnet opus haiku fable inherit"


def _models_build(tmp_path):
    root = tmp_path / "models"
    shutil.copytree(MODELS, root)
    projects = [pf.ProjectInput(name, str(root / name), step_models=sm)
                for name, sm in MODELS_CONFIG.items()]
    return pf.build_document(projects, GENERATED_AT)


def _leaf(doc, project, text):
    return next(n for n in _project(doc, project)["nodes"] if n["text"] == text)


def _bad_models(doc, project):
    return [r for r in doc["parse_report"]
            if r["project"] == project and r["kind"] == "bad_model"]


def _choice(value, source):
    return {"value": value, "source": source}


def test_models_fixture_validates(tmp_path):
    doc = _models_build(tmp_path)
    assert pf.pc.check(doc) == []
    assert pf.invariant_violations(doc) == []


def test_models_both_keys_from_wbs(tmp_path):
    doc = _models_build(tmp_path)
    assert _leaf(doc, "mu", "Both")["models"] == {
        "thinking": _choice("opus", "wbs"), "checking": _choice("fable", "wbs")}


def test_models_class_key_then_null_numeric_ignored(tmp_path):
    doc = _models_build(tmp_path)
    assert _leaf(doc, "nu", "Bare")["models"] == {
        "thinking": _choice("sonnet", "project"), "checking": None}
    assert _bad_models(doc, "nu") == []


def test_models_default_only(tmp_path):
    doc = _models_build(tmp_path)
    assert _leaf(doc, "xi", "Bare")["models"] == {
        "thinking": _choice("haiku", "project"), "checking": _choice("haiku", "project")}


def test_models_inherit_from_wbs(tmp_path):
    doc = _models_build(tmp_path)
    assert _leaf(doc, "mu", "Inherit")["models"] == {
        "thinking": _choice("inherit", "wbs"), "checking": None}


@pytest.mark.parametrize("project,cls,want,shown", [
    ("mu", "thinking", None, '"gpt"'),
    ("xi", "checking", _choice("haiku", "project"), '["opus", "fable"]'),
])
def test_models_malformed_leaf_key_falls_through(tmp_path, project, cls, want, shown):
    doc = _models_build(tmp_path)
    leaf = _leaf(doc, project, "Malformed")
    assert leaf["models"][cls] == want
    bad = _bad_models(doc, project)
    assert [(r["source_line"], r["message"]) for r in bad] == [
        (leaf["source_line"],
         f"{cls} {shown} is not one of: {TOKENS}; the key counts as absent")]


def test_models_bad_config_value_does_not_fall_through(tmp_path):
    doc = _models_build(tmp_path)
    assert _leaf(doc, "omicron", "Bare")["models"] == {
        "thinking": None, "checking": _choice("opus", "project")}
    bad = _bad_models(doc, "omicron")
    assert len(bad) == 1
    assert bad[0]["source_line"] is None
    assert "step_models.thinking" in bad[0]["message"]


def test_models_absent_on_parent(tmp_path):
    doc = _models_build(tmp_path)
    parent = _leaf(doc, "mu", "Parent")
    assert "models" not in parent
    assert parent["meta"]["thinking"] == "opus" and parent["meta"]["checking"] == "fable"
    assert all(r["source_line"] != parent["source_line"] for r in _bad_models(doc, "mu"))
    # Improve B4: a parent's malformed key reports nothing in the portfolio.
    pi_parent = _leaf(doc, "pi", "Parent")
    assert "models" not in pi_parent
    assert _leaf(doc, "pi", "Child")["models"]["checking"] == _choice("opus", "wbs")
    assert _bad_models(doc, "pi") == []


def _cfg_bad(key, cls, v):
    return (f"step_models.{key} {json.dumps(v)} is not one of: {TOKENS}; "
            f"models.{cls} is null")


@pytest.mark.parametrize("step_models,want", [
    # legal rows
    ({"thinking": "sonnet"}, {"thinking": (_choice("sonnet", "project"), None),
                              "checking": (None, None)}),
    ({"thinking": "", "default": "opus"}, {"thinking": (_choice("opus", "project"), None),
                                           "checking": (_choice("opus", "project"), None)}),
    ({"default": "haiku"}, {"thinking": (_choice("haiku", "project"), None),
                            "checking": (_choice("haiku", "project"), None)}),
    ({"checking": "fable"}, {"thinking": (None, None),
                             "checking": (_choice("fable", "project"), None)}),
    ({"thinking": "inherit"}, {"thinking": (_choice("inherit", "project"), None),
                               "checking": (None, None)}),
    # bad rows: no fall-through
    ({"thinking": "gpt", "default": "opus"},
     {"thinking": (None, _cfg_bad("thinking", "thinking", "gpt")),
      "checking": (_choice("opus", "project"), None)}),
    ({"default": "gpt"}, {"thinking": (None, _cfg_bad("default", "thinking", "gpt")),
                          "checking": (None, _cfg_bad("default", "checking", "gpt"))}),
    # edge rows: TOML non-strings arrive in TOML form; {} resolves nothing
    ({"thinking": "3"}, {"thinking": (None, _cfg_bad("thinking", "thinking", "3")),
                         "checking": (None, None)}),
    ({"checking": '["opus"]'}, {"thinking": (None, None),
                                "checking": (None, _cfg_bad("checking", "checking", '["opus"]'))}),
    ({}, {"thinking": (None, None), "checking": (None, None)}),
    ({"9": "fable"}, {"thinking": (None, None), "checking": (None, None)}),
    # Improve B2: a table value is exported as <unreadable>
    ({"thinking": "<unreadable>", "default": "opus"},
     {"thinking": (None, _cfg_bad("thinking", "thinking", "<unreadable>")),
      "checking": (_choice("opus", "project"), None)}),
    # Improve A3: a bad default no class reaches is silent
    ({"thinking": "opus", "checking": "haiku", "default": "gpt"},
     {"thinking": (_choice("opus", "project"), None),
      "checking": (_choice("haiku", "project"), None)}),
])
def test_project_models_truth_table(step_models, want):
    assert pf.project_models(step_models) == want


def test_models_read_tokens_from_parser(monkeypatch):
    # Delegation proof: project_models reads the parser's MODEL_TOKENS.
    monkeypatch.setattr(pf.wbs_parser, "MODEL_TOKENS", ("zz",))
    assert pf.project_models({"default": "zz"})["thinking"] == (_choice("zz", "project"), None)
    assert pf.project_models({"default": "opus"})["thinking"][0] is None
    meta_models, msgs = pf.leaf_models({"thinking": "zz"}, {"thinking": None, "checking": None})
    assert meta_models["thinking"] == _choice("zz", "wbs") and msgs == []


def test_bad_model_messages_pinned():
    assert pf.LEAF_BAD == "{cls} {shown} is not one of: {tokens}; the key counts as absent"
    assert pf.CONFIG_BAD == ("step_models.{key} {shown} is not one of: {tokens}; "
                             "models.{cls} is null")


def _manifest(monkeypatch, projects):
    for k in [k for k in os.environ if k.startswith("PORTFOLIO_")]:
        monkeypatch.delenv(k)
    monkeypatch.setenv("PORTFOLIO_PROJECT_COUNT", str(len(projects)))
    for i, (name, devdoc) in enumerate(projects):
        monkeypatch.setenv(f"PORTFOLIO_NAME_{i}", name)
        if devdoc is not None:
            monkeypatch.setenv(f"PORTFOLIO_DEVDOC_{i}", devdoc)


def test_manifest_from_env(monkeypatch):
    _manifest(monkeypatch, [("alpha", "/d/a"), ("delta", None), ("iota", "")])
    monkeypatch.setenv("PORTFOLIO_SOURCE_0", "/s/a")
    monkeypatch.setenv("PORTFOLIO_WORKTREE_0", "/w")
    # #890: a set step_models var keeps its value, an empty one keeps "",
    # an unset one leaves the key absent.
    monkeypatch.setenv("PORTFOLIO_MODEL_THINKING_0", "sonnet")
    monkeypatch.setenv("PORTFOLIO_MODEL_DEFAULT_0", "")
    assert pf.read_manifest() == [
        pf.ProjectInput("alpha", "/d/a", "/s/a", "/w",
                        {"thinking": "sonnet", "default": ""}),
        pf.ProjectInput("delta", None, None, None),
        pf.ProjectInput("iota", "", None, None),
    ]


@pytest.mark.parametrize("env", [{}, {"PORTFOLIO_PROJECT_COUNT": "x"},
                                 {"PORTFOLIO_PROJECT_COUNT": "1"}])
def test_manifest_malformed(monkeypatch, env):
    _manifest(monkeypatch, [])
    monkeypatch.delenv("PORTFOLIO_PROJECT_COUNT")
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    with pytest.raises(pf.ManifestError):
        pf.read_manifest()


def test_main_self_check_exit_3(tmp_path, monkeypatch, capsys):
    _manifest(monkeypatch, [])
    broken = _example()
    _nset("n9", "id", "n1")(broken)
    monkeypatch.setattr(pf, "build_document", lambda projects, generated_at: broken)
    out = tmp_path / "out" / "p.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_SELF_CHECK == 3
    err = capsys.readouterr().err
    assert "portfolio: self-check: I1: " in err
    assert not out.exists()
    assert not (tmp_path / "out").exists() or list((tmp_path / "out").iterdir()) == []


def test_main_writes_and_reports(tmp_path, monkeypatch, capsys):
    root, _ = _multi(tmp_path)
    _manifest(monkeypatch, [("alpha", str(root / "alpha")), ("delta", None)])
    out = tmp_path / "home" / "portfolio" / "portfolio.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_OK
    doc = json.loads(out.read_bytes().decode("utf-8"))
    assert [p["project"] for p in doc["projects"]] == ["alpha", "delta"]
    assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", doc["generated_at"])
    n = len(doc["parse_report"])
    assert capsys.readouterr().out == f"portfolio: wrote {out} (2 projects, {n} report entries)\n"
    assert [p.name for p in out.parent.iterdir()] == ["portfolio.json"]


@pytest.mark.parametrize("argv", [[], ["build"], ["build", "--out"], ["build", "--out", ""],
                                  ["build", "--bogus", "x"], ["nope", "--out", "x"],
                                  ["build", "--out", "a", "extra"], ["ready", "x"],
                                  ["ready", "--out", "x"], ["Ready"]])
def test_main_usage(argv, capsys):
    assert pf.main(argv) == pf.EXIT_USAGE
    assert pf.USAGE in capsys.readouterr().err


def _ready_manifest(tmp_path, monkeypatch, others=None):
    """rho then `others` (default: sigma) as the manifest, over a tmp copy."""
    root = _ready_copy(tmp_path)
    if others is None:
        others = [("sigma", str(root / "sigma"))]
    _manifest(monkeypatch, [("rho", str(root / "rho")), *others])
    return root


def test_main_ready_prints_lines(tmp_path, monkeypatch, capsysbinary):
    _ready_manifest(tmp_path, monkeypatch)
    assert pf.main(["ready"]) == pf.EXIT_OK
    out, err = capsysbinary.readouterr()
    assert out == READY_EXPECTED.read_bytes()
    assert err == b""


def test_main_ready_self_check_exit_3(monkeypatch, capsys):
    _manifest(monkeypatch, [])
    broken = _example()
    _nset("n9", "id", "n1")(broken)
    monkeypatch.setattr(pf, "build_document", lambda projects, generated_at: broken)
    assert pf.main(["ready"]) == pf.EXIT_SELF_CHECK == 3
    out, err = capsys.readouterr()
    assert out == ""
    assert "portfolio: self-check: I1: " in err


def _subprocess_env(root):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("PORTFOLIO_") and k not in ("PYTHONIOENCODING", "PYTHONUTF8")}
    env.update({"PORTFOLIO_PROJECT_COUNT": "2",
                "PORTFOLIO_NAME_0": "rho", "PORTFOLIO_DEVDOC_0": str(root / "rho"),
                "PORTFOLIO_NAME_1": "sigma", "PORTFOLIO_DEVDOC_1": str(root / "sigma")})
    return env


def test_ready_stdout_is_utf8_lf_bytes(tmp_path):
    root = _ready_copy(tmp_path)
    r = subprocess.run([sys.executable, str(PRODUCER), "ready"], capture_output=True,
                       env=_subprocess_env(root))
    assert (r.returncode, r.stderr) == (0, b"")
    assert r.stdout == READY_EXPECTED.read_bytes()
    assert b"\r\n" not in r.stdout
    assert "Café naïve rdy-utf8" in r.stdout.decode("utf-8")


def test_ready_broken_pipe_exits_quietly(tmp_path):
    # Enough ready leaves to overrun any pipe buffer, so the write meets the
    # closed pipe rather than finishing first.
    root = tmp_path / "many"
    (root / "rho").mkdir(parents=True)
    (root / "sigma").mkdir()
    rows = "".join(f"- [ ] leaf {i} {'x' * 80} {{issue: Issue-{i}}}\n" for i in range(1, 4001))
    (root / "rho" / "WBS.md").write_bytes(("# rho\n\n" + rows).encode("utf-8"))
    (root / "sigma" / "WBS.md").write_bytes(b"# sigma\n")
    proc = subprocess.Popen([sys.executable, str(PRODUCER), "ready"], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=_subprocess_env(root))
    assert proc.stdout.readline().startswith(b"rho\tIssue-1\t")
    proc.stdout.close()
    err = proc.stderr.read()
    proc.stderr.close()
    assert proc.wait() == 0
    assert b"Traceback" not in err, err
    assert err == b""


def test_main_ready_reports_unread_projects(tmp_path, monkeypatch, capsysbinary):
    empty = tmp_path / "empty"
    empty.mkdir()
    dir_wbs = tmp_path / "dirwbs"
    (dir_wbs / "WBS.md").mkdir(parents=True)
    _ready_manifest(tmp_path, monkeypatch, [("nowbs", str(empty)), ("broken", str(dir_wbs))])
    assert pf.main(["ready"]) == pf.EXIT_OK
    out, err = capsysbinary.readouterr()
    # Hand-derived: sigma is not configured here, so rho's sigma:Issue-90
    # entry does not resolve and rdy-foreign-done drops out.
    want = [line for line in _expected_lines()
            if line.startswith("rho\t") and "rdy-foreign-done" not in line]
    assert out.decode("utf-8").splitlines() == want
    assert err.decode("utf-8").splitlines() == [
        "portfolio: nowbs: not read (no_wbs); its leaves are not listed",
        "portfolio: broken: not read (unreadable); its leaves are not listed",
    ]


def test_ready_lines_sanitizes_and_renders_est():
    def leaf(issue, raw, text):
        return {"leaf": True, "ready": True, "issue": issue, "est": {"raw": raw}, "text": text}
    doc = {"projects": [{"project": "p", "nodes": [
        leaf(None, ["1h", "2h"], "a\tb\rc"),
        leaf("Issue-1", None, "t\nu"),
        {"leaf": False, "ready": None, "issue": "Issue-2", "est": {"raw": "3h"}, "text": "parent"},
        {"leaf": True, "ready": False, "issue": "Issue-3", "est": {"raw": "1h"}, "text": "no"},
    ]}]}
    assert pf.ready_lines(doc) == ["p\t\t1h, 2h\ta b c", "p\tIssue-1\t\tt u"]


def test_exit_constants_pinned():
    assert (pf.EXIT_OK, pf.EXIT_CONFIG, pf.EXIT_USAGE, pf.EXIT_SELF_CHECK) == (0, 1, 2, 3)


def test_dumps_is_lf_utf8_and_refuses_nan():
    data = pf.dumps({"a": "café", "b": [1, 2.5]})
    assert isinstance(data, bytes)
    assert b"\r" not in data and data.endswith(b"}\n")
    assert "café".encode("utf-8") in data
    with pytest.raises(ValueError):
        pf.dumps({"x": float("nan")})


def test_rail_refuses_under_a_configured_dir(tmp_path):
    projects = [pf.ProjectInput("alpha", str(tmp_path / "d"), str(tmp_path / "s"), "")]
    assert pf.rail(projects, tmp_path / "d" / "x" / "p.json") == (
        f"portfolio: refusing to write under the devdoc_dir of project 'alpha' "
        f"({tmp_path / 'd'}); choose an --out outside every devdoc_dir, source_dir "
        "and worktree_root")
    assert "the source_dir of" in pf.rail(projects, tmp_path / "s" / "p.json")
    assert pf.rail(projects, tmp_path / "elsewhere" / "p.json") is None
    assert pf.rail(projects, tmp_path / "dd" / "p.json") is None   # a prefix is not a parent


def test_rail_different_drive_is_not_under(tmp_path, monkeypatch):
    def boom(paths):
        raise ValueError("Paths don't have the same drive")
    monkeypatch.setattr(pf.os.path, "commonpath", boom)
    projects = [pf.ProjectInput("alpha", str(tmp_path / "d"), None, None)]
    assert pf.rail(projects, tmp_path / "d" / "p.json") is None


def test_write_document_replaces_atomically(tmp_path):
    out = tmp_path / "a" / "b" / "p.json"
    pf.write_document(b"one\n", out)
    pf.write_document(b"two\n", out)
    assert out.read_bytes() == b"two\n"
    assert [p.name for p in out.parent.iterdir()] == ["p.json"]


def test_write_document_removes_temp_on_failure(tmp_path, monkeypatch):
    out = tmp_path / "p.json"
    def fail(src, dst):
        raise OSError(28, "No space left on device")
    monkeypatch.setattr(pf.os, "replace", fail)
    with pytest.raises(OSError):
        pf.write_document(b"x\n", out)
    assert list(tmp_path.iterdir()) == []


def test_write_document_missing_root_raises_not_loops(tmp_path, monkeypatch):
    # An unmounted drive letter: Path("Z:/").parent is itself and never exists.
    monkeypatch.setattr(pf.Path, "exists", lambda self: False)
    with pytest.raises(FileNotFoundError):
        pf.write_document(b"x\n", tmp_path / "a" / "p.json")


def test_devdoc_that_is_a_file_is_not_a_directory(tmp_path):
    f = tmp_path / "devdoc"
    f.write_text("x")
    assert pf._read_wbs(str(f)) == ("no_devdoc_dir", pf.REASON_NOT_DIR, None)


def test_unknown_report_kind_sorts_last(tmp_path, monkeypatch):
    real = pf.wbs_parser.diagnose_text
    def extra(text):
        d = real(text)
        d["meta_problems"].append((1, "meta_future_code", "a future diagnosis"))
        return d
    monkeypatch.setattr(pf.wbs_parser, "diagnose_text", extra)
    _, doc = _build(tmp_path)
    at_one = [r["kind"] for r in doc["parse_report"]
              if r["project"] == "alpha" and r["source_line"] == 1]
    assert at_one[-1] == "meta_future_code"


# --- docs ----------------------------------------------------------------------

SCHEMA_DOC = REPO / "docs" / "portfolio-schema.md"
COMMAND_DOC = REPO / "commands" / "portfolio.md"
KINDS_START = "<!-- report-kinds:start -->"
KINDS_END = "<!-- report-kinds:end -->"


def test_doc_lists_every_kind():
    text = SCHEMA_DOC.read_text(encoding="utf-8")
    assert text.count(KINDS_START) == text.count(KINDS_END) == 1
    table = text[text.index(KINDS_START):text.index(KINDS_END)]
    rows = re.findall(r"^\| `([a-z_]+)` \|", table, re.MULTILINE)
    assert tuple(rows) == pf.KINDS


def test_command_doc_exit_map():
    text = COMMAND_DOC.read_text(encoding="utf-8")
    rows = [int(n) for n in re.findall(r"^\| `([0-9])` \|", text, re.MULTILINE)]
    assert rows == [pf.EXIT_OK, pf.EXIT_CONFIG, pf.EXIT_USAGE, pf.EXIT_SELF_CHECK]


READY_START = "<!-- ready-rule:start -->"
READY_END = "<!-- ready-rule:end -->"


def test_command_doc_defines_ready():
    # Pins the claim's elements (AC5), not its prose.
    text = COMMAND_DOC.read_text(encoding="utf-8")
    assert text.count(READY_START) == text.count(READY_END) == 1
    block = text[text.index(READY_START):text.index(READY_END)]
    assert re.findall(r"^([0-9])\. ", block, re.MULTILINE) == ["1", "2", "3", "4", "5"]
    for term in ("dep_unresolved", "dep_skipped", "dep_cycle", "parent_done_leaf_pending",
                 "ready_via_parent_row", "<project>:<issue>"):
        assert term in block, term
    paragraphs = re.split(r"\n\s*\n", block)
    assert any("TAB" in para and all(f"`{f}`" in para for f in ("project", "issue", "est", "text"))
               for para in paragraphs), "line-format sentence"
    assert any("config order" in para and "`source_line`" in para
               for para in paragraphs), "order sentence"


def test_command_doc_names_provisional_factors():
    text = COMMAND_DOC.read_text(encoding="utf-8")
    for unit, hours in pf.HOUR_FACTORS.items():
        assert f"`{unit}` = {hours}" in text
    assert "provisional" in text


# --- final-review fixes --------------------------------------------------------

def _deny(monkeypatch, *targets):
    """os.stat / os.lstat raise PermissionError for these paths (EACCES)."""
    deny = {os.path.normcase(os.path.abspath(str(t))) for t in targets}
    for name in ("stat", "lstat"):
        real = getattr(os, name)

        def fake(path, *a, _real=real, **kw):
            if isinstance(path, (str, os.PathLike)) and \
                    os.path.normcase(os.path.abspath(os.fspath(path))) in deny:
                raise PermissionError(13, "Permission denied", os.fspath(path))
            return _real(path, *a, **kw)
        monkeypatch.setattr(os, name, fake)


def test_unsearchable_devdoc_is_that_projects_status(tmp_path, monkeypatch):
    root, projects = _multi(tmp_path)
    _deny(monkeypatch, root / "alpha")
    doc = pf.build_document(projects, GENERATED_AT)
    alpha = _project(doc, "alpha")
    assert alpha["status"] == "unreadable"
    assert alpha["status_reason"] == "the devdoc dir could not be read: PermissionError: Permission denied"
    assert _project(doc, "beta")["status"] == "read"
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_unstatable_wbs_is_unreadable_not_no_wbs(tmp_path, monkeypatch):
    root, projects = _multi(tmp_path)
    _deny(monkeypatch, root / "beta" / "WBS.md")
    doc = pf.build_document(projects, GENERATED_AT)
    beta = _project(doc, "beta")
    assert (beta["status"], beta["status_reason"]) == (
        "unreadable", "WBS.md could not be read: PermissionError: Permission denied")


def test_unstatable_issue_files_are_reported_not_absent(tmp_path, monkeypatch):
    root, projects = _multi(tmp_path)
    _deny(monkeypatch, root / "alpha" / "Issue-2", root / "alpha" / "Issue-1" / "checklist.md")
    doc = pf.build_document(projects, GENERATED_AT)
    msgs = [r["message"] for r in doc["parse_report"] if r["kind"] == "checklist_unreadable"]
    assert "Issue-1/checklist.md could not be read: PermissionError: Permission denied" in msgs
    assert "Issue-2/ could not be read: PermissionError: Permission denied" in msgs
    alpha = {e["issue"]: e for e in _project(doc, "alpha")["issues"]}
    stuck = [r["message"] for r in doc["parse_report"] if r["kind"] == "stuck_unreadable"]
    assert "Issue-2/ could not be read: PermissionError: Permission denied" in stuck
    assert alpha["Issue-1"]["checklist"] == "absent"
    assert alpha["Issue-2"]["stuck"] == {"step": None, "reason": None, "since": None}
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_rail_case_variant_on_case_insensitive_fs(tmp_path, monkeypatch):
    root = tmp_path / "DevDoc"
    root.mkdir()
    if not (tmp_path / "devdoc").exists():
        pytest.skip("tmp filesystem is case-sensitive")
    # POSIX normcase is the identity even on a case-insensitive mount (WSL /mnt/c, APFS).
    monkeypatch.setattr(pf.os.path, "normcase", lambda p: p)
    projects = [pf.ProjectInput("alpha", str(root), None, None)]
    assert pf.rail(projects, tmp_path / "DEVDOC" / "x" / "p.json") is not None


def test_rail_same_directory_by_identity(tmp_path, monkeypatch):
    # A second spelling of the devdoc (a case variant, a bind mount): the string
    # test misses it, so containment is decided by identity.
    root = tmp_path / "devdoc"
    alias = tmp_path / "alias"
    root.mkdir()
    alias.mkdir()
    real = os.path.samefile
    monkeypatch.setattr(pf.os.path, "samefile",
                        lambda a, b: real(a, b) or {os.path.basename(a), os.path.basename(b)} == {"devdoc", "alias"})
    projects = [pf.ProjectInput("alpha", str(root), None, None)]
    assert "the devdoc_dir of project 'alpha'" in pf.rail(projects, alias / "sub" / "p.json")
    assert pf.rail(projects, tmp_path / "elsewhere" / "p.json") is None


def test_meta_block_not_at_line_end_is_reported():
    text = "# T\n- [ ] parent {est: 3w} (note after block)\n- [ ] plain text, no braces\n"
    assert wbs_parser.diagnose_text(text)["meta_problems"] == [
        (2, wbs_parser.META_UNREADABLE, wbs_parser.TRAILING_TEXT)]
    assert wbs_parser.parse_text(text)["children"][0]["meta"] == {}
