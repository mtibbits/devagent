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
    ("2-3d", _est("time", 16, 24)),
    ("3-2d", _est("unparseable")),
    ("2-4pr", _est("unparseable")),
    (["1w", "2w"], _est("unparseable")),
    ("5", _est("unparseable")),
    ("", _est("unparseable")),
    ("9999999999h", _est("unparseable")),
]


@pytest.mark.parametrize("raw,want", EST_ROWS, ids=[repr(r[0]) for r in EST_ROWS])
def test_est_fields(raw, want):
    got = pf.est_fields(raw)
    assert got == {"raw": raw, **want}
    for k in ("low_hours", "high_hours", "quantity"):
        v = got[k]
        if v is not None and float(v).is_integer():
            assert type(v) is int, (k, v)


def test_interim_classifier_is_gone():
    # #737 replaced #726's interim classifier; the factors live in the parser.
    assert [n for n in ("classify_est", "HOUR_FACTORS", "PLACEHOLDER_RE", "QUANTITY_RE")
            if hasattr(pf, n)] == []


def test_est_fields_delegates_to_parser(monkeypatch):
    # #737: est_fields looks the parser's classify_estimate up at call time.
    sentinel = {"key": "est", "raw": "1w", "class": "sentinel", "low": 7, "high": 9,
                "quantity": 3, "unit": "zz"}
    monkeypatch.setattr(pf.wbs_parser, "classify_estimate", lambda key, raw: sentinel)
    assert pf.est_fields("1w") == {"raw": "1w", "class": "sentinel", "low_hours": 7,
                                   "high_hours": 9, "quantity": 3, "unit": "zz"}


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


@pytest.mark.parametrize("raw,project,want", [
    ("Issue-8", None, _dep("Issue-8", "local", None, "Issue-8")),
    ("beta:Issue-2", None, _dep("beta:Issue-2", "foreign", "beta", "Issue-2")),
    ("alpha:Issue-9", "alpha", _dep("alpha:Issue-9", "local", "alpha", "Issue-9")),
    ("alpha:Issue-9", None, _dep("alpha:Issue-9", "foreign", "alpha", "Issue-9")),
    ("beta:Issue-2", "alpha", _dep("beta:Issue-2", "foreign", "beta", "Issue-2")),
    (":Issue-1", "alpha", _dep(":Issue-1", "local", "alpha", ":Issue-1")),
    ("a:b:c", "alpha", _dep("a:b:c", "local", "alpha", "a:b:c")),
    ("devagent: Issue-726", "alpha",
     _dep("devagent: Issue-726", "local", "alpha", "devagent: Issue-726")),
    ("https://x", "alpha", _dep("https://x", "local", "alpha", "https://x")),
    ("4.1", "alpha", _dep("4.1", "local", "alpha", "4.1")),
])
def test_split_dep_table(raw, project, want):
    # #887: the classification guard, committed against the pre-move code.
    assert pf.split_dep(raw, project) == want


def test_split_dep_delegates_to_parser(monkeypatch):
    # #887: one classifier; portfolio.split_dep only adds `resolved`.
    monkeypatch.setattr(pf.wbs_parser, "split_dep", lambda raw, project: {"raw": "S"})
    assert pf.split_dep("x", "alpha") == {"raw": "S", "resolved": None}


def test_split_dep_key_order():
    # #887: the JSON byte order that dict == cannot see.
    assert list(pf.split_dep("beta:Issue-2", "alpha")) == [
        "raw", "scope", "project", "issue", "resolved"]


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
    assert pf.SCHEMA_VERSION == pf.pc.load_schema()["version"] == "1.4"


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


def test_compat_parked_kind_both_directions():
    # #963: schema 1.4 adds optional projects[].issues[].parked and
    # projects[].issues[].stuck.kind (Issue-725's both-directions rule, with a
    # mislabelled negative control).
    old_schema = pf.pc.load_schema(FIXTURES / "schema-history" / "1.3.json")
    new_doc = _example()
    new_doc["schema_version"] = "1.4"
    kinds = 0
    for p in new_doc["projects"]:
        for n in p["nodes"]:
            n["ready_via_parent_row"] = None
        for e in p["issues"]:
            e["parked"] = False
            if e["stuck"] is not None:
                e["stuck"]["kind"] = "stuck"
                kinds += 1
    assert kinds >= 1
    # The 1.3 reader reads a 1.4 document: unknown fields at a newer minor.
    assert pf.pc.check(new_doc, old_schema) == []
    # The live reader reads the 1.4 document and the older example.
    assert pf.pc.check(new_doc) == []
    assert pf.pc.check(_example()) == []
    # Negative control: the same fields under the 1.3 label are errors.
    mislabelled = copy.deepcopy(new_doc)
    mislabelled["schema_version"] = "1.3"
    errors = pf.pc.check(mislabelled, old_schema)
    assert errors
    assert all(e.endswith((".parked: unknown field", ".kind: unknown field")) for e in errors), errors


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


def _at_own_minor(d):
    """#963: label the example at the producer's minor, where I16 recomputes
    `ready` (rule 7), with the null leaf models that minor requires (I17)."""
    d["schema_version"] = pf.SCHEMA_VERSION
    for p in d["projects"]:
        for n in p["nodes"]:
            if n["leaf"]:
                n.setdefault("models", {"thinking": None, "checking": None})


def _computed(*fs):
    """A row that first fills the example's readiness fields at the producer's
    minor, then mutates."""
    def f(d):
        _at_own_minor(d)
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


def _choice(value, source):
    return {"value": value, "source": source}


def _models(thinking=None, checking=None):
    """A models object from (value, source) pairs; None stays null (#890)."""
    def choice(pair):
        return None if pair is None else _choice(*pair)
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
    ("I16", "stuck-ignored-at-own-minor", _computed(_iset("Issue-10", "stuck", {
        "step": "2 draft", "reason": None, "since": None}))),
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
    assert len(MUTATION_ROWS) == 59 + 5
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


@pytest.fixture
def low_int_digits():
    # #1050 item 2: arm the interpreter's integer-string limit low, so a step
    # number past it is a cheap fixture on every host.
    if not hasattr(sys, "set_int_max_str_digits"):
        pytest.skip("this interpreter has no integer-string limit")
    saved = sys.get_int_max_str_digits()
    sys.set_int_max_str_digits(640)
    try:
        with pytest.raises(ValueError):
            int("1" * 641)
        yield
    finally:
        sys.set_int_max_str_digits(saved)


def test_checklist_next_huge_step_number(tmp_path, low_int_digits):
    p = tmp_path / "checklist.md"
    p.write_text("- [ ] " + "1" * 641 + ". draft\n", encoding="utf-8")
    with pytest.raises(pf.ChecklistError, match=r"^step number of 641 digits is too long to read$"):
        pf.checklist_next(p)


def test_main_huge_step_number_still_writes(tmp_path, monkeypatch, capsys, low_int_digits):
    devdoc = tmp_path / "devdoc"
    (devdoc / "Issue-1").mkdir(parents=True)
    (devdoc / "Issue-2").mkdir()
    (devdoc / "WBS.md").write_text("# p\n\n- [ ] L {issue: Issue-1}\n- [ ] M {issue: Issue-2}\n",
                                   encoding="utf-8")
    (devdoc / "Issue-1" / "checklist.md").write_text("- [ ] " + "1" * 641 + ". draft\n",
                                                      encoding="utf-8")
    (devdoc / "Issue-2" / "checklist.md").write_text("- [ ] 3. scope\n", encoding="utf-8")
    _manifest(monkeypatch, [("p", str(devdoc))])
    out = tmp_path / "out" / "p.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_OK
    doc = json.loads(out.read_bytes().decode("utf-8"))
    entries = [r for r in doc["parse_report"] if r["kind"] == "checklist_unreadable"]
    assert [(r["message"], r["source_line"]) for r in entries] == [
        ("Issue-1/checklist.md could not be read: step number of 641 digits is too long to read",
         None)]
    issues = {e["issue"]: e for e in doc["projects"][0]["issues"]}
    assert issues["Issue-1"]["checklist"] == "absent"
    assert (issues["Issue-2"]["checklist"], issues["Issue-2"]["next_step_number"],
            issues["Issue-2"]["next_step"]) == ("open", 3, "scope")


def test_step_row_re_twins_tracker():
    # Both capture the step name (portfolio positionally, wbs-tracker.py as
    # `name`, #734); with the name group normalised the two are one rule
    # (checklist.sh:67).
    tracker = _load("wbs_tracker_for_portfolio_tests", LIB / "wbs-tracker.py")
    assert pf.STEP_ROW_RE.pattern.replace("([A-Za-z]", "(?P<name>[A-Za-z]") \
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
                                "since": "2026-11-04 08:47", "kind": "stuck"}
    p.write_bytes(CHECKLIST_STUCK_SH.replace("\n", "\r\n").encode("utf-8"))
    assert pf.read_stuck(p) == {"step": "16 redmr", "reason": "red-team found a blocker",
                                "since": "2026-11-04T08:47:12-05:00", "kind": "stuck"}
    p.write_text("Step:        9 implement\nCreated:     2026-11-04 08:47\n",
                 encoding="utf-8", newline="")
    assert pf.read_stuck(p) == {"step": "9 implement", "reason": None,
                                "since": "2026-11-04 08:47", "kind": "stuck"}


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
    return root, pf.build_document(projects, GENERATED_AT, None)


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
    _, tok = _tok_doc(tmp_path / "tok-build")  # #737: tests/fixtures/portfolio stays untouched
    unwired = pf.build_document([pf.ProjectInput("solo", None)], GENERATED_AT,
                                str(tmp_path / "none" / "actuals.json"))  # #735
    no_state = pf.build_document([pf.ProjectInput("solo", None, state_status="unreadable")],
                                 GENERATED_AT, None)  # #963
    kinds = {r["kind"] for d in (doc, ready, models, tok, unwired, no_state)
             for r in d["parse_report"]}
    assert kinds == set(pf.KINDS)
    assert len(pf.KINDS) == len(set(pf.KINDS)) == 23


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
        "step": "16 redmr", "reason": "red-team found a blocker", "since": "2026-11-04 08:47",
        "kind": "stuck"})
    assert pick(alpha["Issue-3"]) == ("absent", None, None, None)
    assert pick(alpha["Issue-4"]) == ("absent", None, None, None)
    assert pick(alpha["Issue-5"]) == ("absent", None, None,
                                      {"step": None, "reason": None, "since": None, "kind": None})
    assert pick(alpha["GH-726!"]) == ("absent", None, None, None)
    report = {r["kind"]: r["message"] for r in doc["parse_report"] if r["source_line"] is None}
    assert report["checklist_unreadable"].startswith("Issue-4/checklist.md could not be read: ")
    assert report["stuck_unreadable"].startswith("Issue-5/STUCK could not be read: ")
    assert str(tmp_path) not in json.dumps(doc["parse_report"])
    assert alpha["Issue-3"]["nodes"] == [n["id"] for n in _project(doc, "alpha")["nodes"]
                                         if n["issue"] == "Issue-3"]


def test_build_deterministic(tmp_path):
    root, projects = _multi(tmp_path)
    assert pf.build_document(projects, GENERATED_AT, None) == pf.build_document(projects, GENERATED_AT, None)


def _tree_hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


def test_build_writes_nothing_under_devdocs(tmp_path):
    root, projects = _multi(tmp_path)
    before = _tree_hashes(root)
    assert before
    pf.build_document(projects, GENERATED_AT, None)
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
    return pf.build_document(projects, GENERATED_AT, None)


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


def _solo_doc(root, body):
    devdoc = root / "solo"
    devdoc.mkdir(parents=True)
    text = "# solo\n\n" + body
    (devdoc / "WBS.md").write_bytes(text.encode())
    return text, pf.build_document([pf.ProjectInput("solo", str(devdoc))], GENERATED_AT, None)


def _one_leaf_doc(tmp_path, glyph):
    return _solo_doc(tmp_path, f"- [{glyph}] leaf {{issue: Issue-1}}\n")[1]


def test_range_and_tok_through_the_producer(tmp_path):
    # #737: a range is `time` with two bounds, `tok` is a known key carried in
    # meta, and a reversed range is still reported.
    text, doc = _solo_doc(tmp_path, "- [ ] ok {issue: Issue-1, est: 2-4d, tok: 1-3M}\n"
                                    "- [ ] bad {issue: Issue-2, est: 4-2d}\n")
    ok, bad = doc["projects"][0]["nodes"]
    assert ok["est"] == {"raw": "2-4d", "class": "time", "low_hours": 16, "high_hours": 32,
                         "quantity": None, "unit": None, "src": None}
    assert ok["meta"]["tok"] == "1-3M"
    assert ok["meta_unknown_keys"] == []
    assert bad["est"]["class"] == "unparseable"
    assert bad["source_line"] == _line_of(text, "bad {")
    report = [(r["source_line"], r["kind"]) for r in doc["parse_report"]]
    assert report == [(bad["source_line"], "est_unparseable")]
    remaining = doc["projects"][0]["rollup"]["remaining"]
    assert (remaining["estimated"], remaining["unestimated"],
            remaining["low_hours"], remaining["high_hours"]) == (1, 1, 16, 32)
    assert pf.pc.check(doc) == []
    assert pf.invariant_violations(doc) == []


TOK_ROWS = [("tbad-int", "500000"), ("tbad-case", "500K"), ("tbad-unit", "2m"),
            ("tgood", "2M"), ("tplaceholder", "?")]


def _tok_doc(root):
    """(text, document) of a solo devdoc with one leaf per TOK_ROWS row."""
    body = "".join(f"- [ ] {m} {{issue: Issue-{i}, tok: {v}}}\n"
                   for i, (m, v) in enumerate(TOK_ROWS, start=1))
    return _solo_doc(root, body)


def test_tok_unparseable_reported(tmp_path):
    # #737: an unparseable `tok` is reported, never read silently.
    text, doc = _tok_doc(tmp_path)
    got = [(r["source_line"], r["kind"], r["message"]) for r in doc["parse_report"]]
    want = [(_line_of(text, f"{m} {{"), "tok_unparseable",
             f'tok "{v}" is not a token estimate or placeholder')
            for m, v in TOK_ROWS[:3]]
    assert got == want
    assert pf.pc.check(doc) == []


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
    assert pf.ready_lines(pf.build_document(keep, GENERATED_AT, None)) == []


# The multi fixture's ready leaves, derived by hand from the rule: alpha's
# leaves that are pending and have no or only resolved-and-done dependencies
# (plant-outline, plant-issue4 and plant-bracket hold unresolved entries;
# plant-issue1 is done, plant-issue2 in progress; #963: plant-issue5's STUCK
# cannot be read, so its stuck is non-null and rule 1 leaves it out), and
# beta's two pending leaves without a dependency (plant-beta-dep waits on
# alpha's in-progress Issue-2).
MULTI_READY = [
    ("alpha", m) for m in ("plant-issue3", "plant-dup3", "plant-noissue-est", "plant-est-src",
                           "plant-jira", "plant-merged", "plant-trailing", "plant-dupkey",
                           "plant-swallowed", "plant-issue-list", "plant-not-id")
] + [("beta", "plant-beta-issue1"), ("beta", "plant-beta-after")]


def test_multi_ready_pinned(tmp_path):
    _, doc = _build(tmp_path)
    got = {(p["project"], n["source_line"]) for p in doc["projects"]
           for n in p["nodes"] if n["ready"] is True}
    want = {(p, _line_of(_wbs_text(p), m)) for p, m in MULTI_READY}
    assert len(want) == 13
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
    return pf.build_document(projects, GENERATED_AT, None)


@pytest.fixture(scope="module")
def models_doc(tmp_path_factory):
    return _models_build(tmp_path_factory.mktemp("models-doc"))


def _leaf(doc, project, text):
    return next(n for n in _project(doc, project)["nodes"] if n["text"] == text)


def _bad_models(doc, project):
    return [r for r in doc["parse_report"]
            if r["project"] == project and r["kind"] == "bad_model"]


def test_models_fixture_validates(models_doc):
    doc = models_doc
    assert pf.pc.check(doc) == []
    assert pf.invariant_violations(doc) == []


def test_models_both_keys_from_wbs(models_doc):
    doc = models_doc
    assert _leaf(doc, "mu", "Both")["models"] == {
        "thinking": _choice("opus", "wbs"), "checking": _choice("fable", "wbs")}


def test_models_class_key_then_null_numeric_ignored(models_doc):
    doc = models_doc
    assert _leaf(doc, "nu", "Bare")["models"] == {
        "thinking": _choice("sonnet", "project"), "checking": None}
    assert _bad_models(doc, "nu") == []


def test_models_default_only(models_doc):
    doc = models_doc
    assert _leaf(doc, "xi", "Bare")["models"] == {
        "thinking": _choice("haiku", "project"), "checking": _choice("haiku", "project")}


def test_models_inherit_from_wbs(models_doc):
    doc = models_doc
    assert _leaf(doc, "mu", "Inherit")["models"] == {
        "thinking": _choice("inherit", "wbs"), "checking": None}


@pytest.mark.parametrize("project,cls,want,shown", [
    ("mu", "thinking", None, '"gpt"'),
    ("xi", "checking", _choice("haiku", "project"), '["opus", "fable"]'),
])
def test_models_malformed_leaf_key_falls_through(models_doc, project, cls, want, shown):
    doc = models_doc
    leaf = _leaf(doc, project, "Malformed")
    assert leaf["models"][cls] == want
    bad = _bad_models(doc, project)
    assert [(r["source_line"], r["message"]) for r in bad] == [
        (leaf["source_line"],
         f"{cls} {shown} is not one of: {TOKENS}; the key counts as absent")]


def test_models_bad_config_value_does_not_fall_through(models_doc):
    doc = models_doc
    assert _leaf(doc, "omicron", "Bare")["models"] == {
        "thinking": None, "checking": _choice("opus", "project")}
    bad = _bad_models(doc, "omicron")
    assert len(bad) == 1
    assert bad[0]["source_line"] is None
    assert "step_models.thinking" in bad[0]["message"]


def test_models_absent_on_parent(models_doc):
    doc = models_doc
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


# #735: build needs PORTFOLIO_ACTUALS; the default names a file that is absent.
NO_ACTUALS = str(Path(os.sep) / "nonexistent-735" / "actuals.json")


def _manifest(monkeypatch, projects, actuals=NO_ACTUALS):
    for k in [k for k in os.environ if k.startswith("PORTFOLIO_")]:
        monkeypatch.delenv(k)
    monkeypatch.setenv("PORTFOLIO_PROJECT_COUNT", str(len(projects)))
    if actuals is not None:
        monkeypatch.setenv("PORTFOLIO_ACTUALS", actuals)
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
    monkeypatch.setattr(pf, "build_document", lambda projects, generated_at, actuals: broken)
    out = tmp_path / "out" / "p.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_SELF_CHECK == 3
    err = capsys.readouterr().err
    assert "portfolio: self-check: I1: " in err
    assert not out.exists()
    assert not (tmp_path / "out").exists() or list((tmp_path / "out").iterdir()) == []


@pytest.mark.parametrize("content", ["{", "[" * 200000,
                                     '{"version": "1.0", "type": "object", "required": [{}]}'],
                         ids=["truncated", "deep", "required-not-strings"])
@pytest.mark.parametrize("verb", ["build", "ready"])
def test_main_schema_unreadable_exits_3(tmp_path, monkeypatch, capsys, verb, content):
    # #1050 item 1: a schema file that cannot be read or linted is one line and exit 3.
    _manifest(monkeypatch, [])
    schema = tmp_path / "schema.json"
    schema.write_text(content, encoding="utf-8")
    monkeypatch.setattr(pf.pc, "SCHEMA_PATH", schema)
    outdir = tmp_path / "out"
    out = outdir / "p.json"
    argv = ["build", "--out", str(out)] if verb == "build" else ["ready"]
    assert pf.main(argv) == pf.EXIT_SELF_CHECK == 3
    captured = capsys.readouterr()
    lines = captured.err.splitlines()
    assert len(lines) == 1
    assert lines[0].startswith("portfolio: self-check: schema: cannot read schema ")
    assert "Traceback" not in captured.err
    if verb == "build":
        assert not out.exists()
        assert not outdir.exists() or list(outdir.iterdir()) == []
    else:
        assert captured.out == ""


def test_main_schema_major_mismatch_exits_3(tmp_path, monkeypatch, capsys):
    _manifest(monkeypatch, [])
    real = json.loads(Path(pf.pc.SCHEMA_PATH).read_bytes().decode("utf-8"))
    real["version"] = "2.0"
    schema = tmp_path / "schema.json"
    schema.write_text(json.dumps(real), encoding="utf-8")
    monkeypatch.setattr(pf.pc, "SCHEMA_PATH", schema)
    assert pf.main(["ready"]) == 3
    lines = capsys.readouterr().err.splitlines()
    assert len(lines) == 1
    assert lines[0].startswith(
        f'portfolio: self-check: schema: unsupported portfolio schema_version "{pf.SCHEMA_VERSION}"')


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
    monkeypatch.setattr(pf, "build_document", lambda projects, generated_at, actuals: broken)
    assert pf.main(["ready"]) == pf.EXIT_SELF_CHECK == 3
    out, err = capsys.readouterr()
    assert out == ""
    assert "portfolio: self-check: I1: " in err


def _subprocess_env(root=None, projects=None):
    """A host-independent env naming `projects` ((name, devdoc) pairs; default
    rho and sigma under `root`)."""
    if projects is None:
        projects = [("rho", root / "rho"), ("sigma", root / "sigma")]
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("PORTFOLIO_") and k not in ("PYTHONIOENCODING", "PYTHONUTF8")}
    env["PORTFOLIO_PROJECT_COUNT"] = str(len(projects))
    env["PORTFOLIO_ACTUALS"] = NO_ACTUALS
    for i, (name, devdoc) in enumerate(projects):
        env.update({f"PORTFOLIO_NAME_{i}": name, f"PORTFOLIO_DEVDOC_{i}": str(devdoc)})
    return env


def test_ready_stdout_is_utf8_lf_bytes(tmp_path):
    root = _ready_copy(tmp_path)
    r = subprocess.run([sys.executable, str(PRODUCER), "ready"], capture_output=True,
                       env=_subprocess_env(root))
    assert (r.returncode, r.stderr) == (0, b"")
    assert r.stdout == READY_EXPECTED.read_bytes()
    assert b"\r\n" not in r.stdout
    assert "Café naïve rdy-utf8" in r.stdout.decode("utf-8")


def test_ready_stderr_lines_are_lf_bytes(tmp_path):
    # #963: Windows text-mode stderr ends each line CRLF, and bats keeps the
    # CR in $stderr. A sitecustomize gives this host's text-mode streams that
    # same CRLF translation, so the check bites here and not only on Windows.
    site = tmp_path / "site"
    site.mkdir()
    (site / "sitecustomize.py").write_text(
        "import sys\nfor s in (sys.stdout, sys.stderr):\n    s.reconfigure(newline='\\r\\n')\n",
        encoding="utf-8")
    root = _ready_copy(tmp_path)
    env = _subprocess_env(projects=[("rho", root / "rho"), ("q", tmp_path / "missing")])
    env["PORTFOLIO_STATE_STATUS_0"] = "unreadable"
    env["PYTHONPATH"] = str(site)
    r = subprocess.run([sys.executable, str(PRODUCER), "ready"], capture_output=True, env=env)
    assert r.returncode == 0, r.stderr
    assert r.stderr == (pf.STATE_UNREADABLE_MSG.format(project="rho") + "\n"
                        + pf.NOT_READ_MSG.format(project="q", status="no_devdoc_dir")
                        + "\n").encode("utf-8")


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
                 "ready_via_parent_row", "<project>:<issue>", "STUCK", "parked",
                 "state_unreadable"):
        assert term in block, term
    paragraphs = re.split(r"\n\s*\n", block)
    assert any("TAB" in para and all(f"`{f}`" in para for f in ("project", "issue", "est", "text"))
               for para in paragraphs), "line-format sentence"
    assert any("config order" in para and "`source_line`" in para
               for para in paragraphs), "order sentence"


def _doc_section(text, heading):
    """The lines from `heading` up to the next heading of the same or a higher level."""
    level = len(heading) - len(heading.lstrip("#"))
    lines = text.splitlines()
    start = lines.index(heading)
    end = next((i for i in range(start + 1, len(lines))
                if re.match(rf"#{{1,{level}}} ", lines[i])), len(lines))
    return "\n".join(lines[start:end])


def test_command_doc_names_contract_factors():
    # #737: the command doc's Estimates section names the contract's factors
    # and its classifier, and the interim wording is gone from it.
    est = _doc_section(COMMAND_DOC.read_text(encoding="utf-8"), "## Estimates")
    assert [f"`{u}` = {h}" for u, h in pf.wbs_parser.HOUR_FACTORS.items()
            if f"`{u}` = {h}" not in est] == []
    assert "classify_estimate" in est
    assert [w for w in ("provisional", "interim") if w in est.lower()] == []


def test_schema_doc_drops_provisional_notes():
    # #737: the est writer row and the Deferred section drop the interim notes;
    # the two retired references are gone from the whole page.
    text = SCHEMA_DOC.read_text(encoding="utf-8")
    assert [w for w in ("issuecomment-6670452997", "tokens_src") if w in text] == []
    (row,) = [ln for ln in text.splitlines() if ln.startswith("| `est.class`, `est.low_hours`")]
    deferred = _doc_section(text, "## Deferred")
    assert [w for w in ("interim", "provisional") if w in (row + deferred).lower()] == []
    assert "#941" in deferred
    assert "classify_estimate" in row
    assert [f for f in ("`d` = 8", "`w` = 40") if f in row] == []


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
    doc = pf.build_document(projects, GENERATED_AT, None)
    alpha = _project(doc, "alpha")
    assert alpha["status"] == "unreadable"
    assert alpha["status_reason"] == "the devdoc dir could not be read: PermissionError: Permission denied"
    assert _project(doc, "beta")["status"] == "read"
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_unstatable_wbs_is_unreadable_not_no_wbs(tmp_path, monkeypatch):
    root, projects = _multi(tmp_path)
    _deny(monkeypatch, root / "beta" / "WBS.md")
    doc = pf.build_document(projects, GENERATED_AT, None)
    beta = _project(doc, "beta")
    assert (beta["status"], beta["status_reason"]) == (
        "unreadable", "WBS.md could not be read: PermissionError: Permission denied")


def test_unstatable_issue_files_are_reported_not_absent(tmp_path, monkeypatch):
    root, projects = _multi(tmp_path)
    _deny(monkeypatch, root / "alpha" / "Issue-2", root / "alpha" / "Issue-1" / "checklist.md")
    doc = pf.build_document(projects, GENERATED_AT, None)
    msgs = [r["message"] for r in doc["parse_report"] if r["kind"] == "checklist_unreadable"]
    assert "Issue-1/checklist.md could not be read: PermissionError: Permission denied" in msgs
    assert "Issue-2/ could not be read: PermissionError: Permission denied" in msgs
    alpha = {e["issue"]: e for e in _project(doc, "alpha")["issues"]}
    stuck = [r["message"] for r in doc["parse_report"] if r["kind"] == "stuck_unreadable"]
    assert "Issue-2/ could not be read: PermissionError: Permission denied" in stuck
    assert alpha["Issue-1"]["checklist"] == "absent"
    assert alpha["Issue-2"]["stuck"] == {"step": None, "reason": None, "since": None, "kind": None}
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


# --- #1050 hardening -----------------------------------------------------------

def _issue_files_devdoc(tmp_path, body):
    devdoc = tmp_path / "devdoc"
    devdoc.mkdir()
    text = "# p\n\n" + body
    (devdoc / "WBS.md").write_text(text, encoding="utf-8")
    return devdoc, text


def _pick(e):
    return (e["checklist"], e["next_step_number"], e["next_step"], e["stuck"])


def _report_of(doc, *kinds):
    return [(r["kind"], r["message"]) for r in doc["parse_report"] if r["kind"] in kinds]


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="no os.mkfifo on this host")
def test_fifo_issue_files_are_unreadable_not_opened(tmp_path):
    devdoc, _ = _issue_files_devdoc(tmp_path, "- [ ] L {issue: Issue-1}\n")
    (devdoc / "Issue-1").mkdir()
    os.mkfifo(devdoc / "Issue-1" / "checklist.md")
    os.mkfifo(devdoc / "Issue-1" / "STUCK")
    env = _subprocess_env(projects=[("p", devdoc)])
    out = tmp_path / "out" / "p.json"
    # A subprocess with a timeout: on an unfixed reader the open() blocks, and the
    # timeout turns that hang into a red test instead of a stuck run.
    r = subprocess.run([sys.executable, str(PRODUCER), "build", "--out", str(out)],
                       env=env, capture_output=True, timeout=30)
    assert r.returncode == 0, r.stderr
    doc = json.loads(out.read_bytes().decode("utf-8"))
    assert _report_of(doc, "checklist_unreadable", "stuck_unreadable") == [
        ("checklist_unreadable", "Issue-1/checklist.md could not be read: not a regular file"),
        ("stuck_unreadable", "Issue-1/STUCK could not be read: not a regular file")]
    entry = doc["projects"][0]["issues"][0]
    assert entry["checklist"] == "absent"
    assert entry["stuck"] == {"step": None, "reason": None, "since": None, "kind": None}


def test_non_regular_issue_files_are_unreadable(tmp_path):
    devdoc, _ = _issue_files_devdoc(tmp_path, "- [ ] L {issue: Issue-1}\n- [ ] M {issue: Issue-2}\n")
    (devdoc / "Issue-1" / "checklist.md").mkdir(parents=True)
    (devdoc / "Issue-2").mkdir()
    expected = [("checklist_unreadable", "Issue-1/checklist.md could not be read: not a regular file")]
    try:
        os.symlink("missing-checklist", devdoc / "Issue-2" / "checklist.md")
        os.symlink("missing-stuck", devdoc / "Issue-2" / "STUCK")
    except (OSError, NotImplementedError):
        pass  # no symlinks here: the directory leg still runs
    else:
        expected += [
            ("checklist_unreadable", "Issue-2/checklist.md could not be read: not a regular file"),
            ("stuck_unreadable", "Issue-2/STUCK could not be read: not a regular file")]
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    assert sorted(_report_of(doc, "checklist_unreadable", "stuck_unreadable")) == sorted(expected)
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_issue_files_symlinked_to_regular_are_read(tmp_path):
    devdoc, _ = _issue_files_devdoc(tmp_path, "- [ ] L {issue: Issue-1}\n")
    (devdoc / "Issue-1").mkdir()
    (tmp_path / "real-checklist").write_text("- [ ] 4. scope\n", encoding="utf-8")
    (tmp_path / "real-stuck").write_text("Step: 9 implement\n", encoding="utf-8")
    try:
        os.symlink(tmp_path / "real-checklist", devdoc / "Issue-1" / "checklist.md")
        os.symlink(tmp_path / "real-stuck", devdoc / "Issue-1" / "STUCK")
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unsupported")
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    entry = doc["projects"][0]["issues"][0]
    assert _pick(entry)[:3] == ("open", 4, "scope")
    assert entry["stuck"]["step"] == "9 implement"
    assert _report_of(doc, "checklist_unreadable", "stuck_unreadable") == []


def _issue7_devdoc(tmp_path, body):
    devdoc, text = _issue_files_devdoc(tmp_path, body)
    (devdoc / "Issue-7").mkdir()
    (devdoc / "Issue-7" / "checklist.md").write_text("- [ ] 2. draft\n", encoding="utf-8")
    (devdoc / "Issue-7" / "STUCK").write_text("Step: 2 draft\n", encoding="utf-8")
    return devdoc, text


def test_noncanonical_issue_ids_are_not_followed(tmp_path):
    devdoc, text = _issue7_devdoc(tmp_path, "- [ ] a {issue: Issue-7.}\n- [ ] b {issue: issue-7}\n"
                                            "- [ ] c {issue: Issue-7}\n- [ ] d {issue: Issue-9}\n")
    line_a, line_b = _line_of(text, "{issue: Issue-7.}"), _line_of(text, "{issue: issue-7}")
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    assert [(r["source_line"], r["message"]) for r in doc["parse_report"]
            if r["kind"] == "issue_not_id"] == [
        (line_a, "issue 'Issue-7.' ends in '.'; its issue dir is not read"),
        (line_b, "issue 'issue-7' matches issue dir 'Issue-7' only case-insensitively; "
                 "its issue dir is not read")]
    issues = {e["issue"]: e for e in doc["projects"][0]["issues"]}
    assert _pick(issues["Issue-7."]) == ("absent", None, None, None)
    assert _pick(issues["issue-7"]) == ("absent", None, None, None)
    assert _pick(issues["Issue-7"]) == ("open", 2, "draft",
                                        {"step": "2 draft", "reason": None, "since": None,
                                         "kind": "stuck"})
    assert _pick(issues["Issue-9"]) == ("absent", None, None, None)
    assert _report_of(doc, "checklist_unreadable", "stuck_unreadable") == []
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def _scandir_patch(monkeypatch, devdoc, *, omit=(), raise_exc=None):
    real = os.scandir
    target = os.path.normcase(os.path.abspath(str(devdoc)))

    class _Listing:
        def __init__(self, it):
            self._it = it

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            self._it.close()
            return False

        def __iter__(self):
            return (e for e in self._it if e.name not in omit)

        def close(self):
            self._it.close()

    def fake(path=".", *a, **kw):
        if os.path.normcase(os.path.abspath(os.fspath(path))) != target:
            return real(path, *a, **kw)
        if raise_exc is not None:
            raise raise_exc
        return _Listing(real(path, *a, **kw))
    monkeypatch.setattr(pf.os, "scandir", fake)


def test_case_alias_is_not_followed_when_the_fs_resolves_it(tmp_path, monkeypatch):
    # Simulates a case-insensitive volume: `issue-7` resolves to the dir, while the
    # listing holds only the stored spelling `Issue-7`.
    devdoc, _ = _issue7_devdoc(tmp_path, "- [ ] b {issue: issue-7}\n")
    if not (devdoc / "issue-7").exists():
        try:
            os.symlink("Issue-7", devdoc / "issue-7")
        except (OSError, NotImplementedError):
            pytest.skip("symlinks unsupported")
    _scandir_patch(monkeypatch, devdoc, omit=("issue-7",))
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    entry = doc["projects"][0]["issues"][0]
    assert _pick(entry) == ("absent", None, None, None)
    assert _report_of(doc, "issue_not_id") == [
        ("issue_not_id", "issue 'issue-7' matches issue dir 'Issue-7' only case-insensitively; "
                         "its issue dir is not read")]


def test_unlistable_devdoc_fails_closed(tmp_path, monkeypatch):
    devdoc, _ = _issue7_devdoc(tmp_path, "- [ ] a {issue: Issue-7}\n- [ ] b {issue: Issue-8.}\n"
                                         "- [ ] c {issue: Issue-9}\n")
    _scandir_patch(monkeypatch, devdoc, raise_exc=PermissionError(13, "Permission denied"))
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    msg = ("issue dir 'Issue-7' could not be verified: devdoc listing failed: "
           "PermissionError: Permission denied")
    assert _report_of(doc, "checklist_unreadable", "stuck_unreadable") == [
        ("checklist_unreadable", msg), ("stuck_unreadable", msg)]
    assert _report_of(doc, "issue_not_id") == [
        ("issue_not_id", "issue 'Issue-8.' ends in '.'; its issue dir is not read")]
    issues = {e["issue"]: e for e in doc["projects"][0]["issues"]}
    assert _pick(issues["Issue-7"]) == ("absent", None, None,
                                        {"step": None, "reason": None, "since": None, "kind": None})
    assert _pick(issues["Issue-8."]) == ("absent", None, None, None)
    assert _pick(issues["Issue-9"]) == ("absent", None, None, None)
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def _kind_row(kind):
    text = SCHEMA_DOC.read_text(encoding="utf-8")
    table = text[text.index(KINDS_START):text.index(KINDS_END)]
    return next(ln for ln in table.splitlines() if ln.startswith(f"| `{kind}` |"))


@pytest.mark.parametrize("kind, present, absent", [
    ("issue_not_id", ("ID_TOKEN_RE", "ends in", "case-insensitively"), ()),
    ("checklist_unreadable",
     ("integer-string limit", "not a regular file", "devdoc listing failed"),
     ("present but unreadable",)),
    ("stuck_unreadable", ("not a regular file", "devdoc listing failed"),
     ("present but unreadable",)),
    ("meta_unreadable", ("est:1w", "missing comma"), ()),
    ("near_miss_line", ("inline link", "(url)"), ()),
])
def test_schema_doc_kind_row_names_1050_causes(kind, present, absent):
    row = _kind_row(kind)
    for element in present:
        assert element in row
    for element in absent:
        assert element not in row


def test_command_doc_rails_default_worktree_root():
    section = _doc_section(COMMAND_DOC.read_text(encoding="utf-8"), "## Output")
    assert "not checked yet" not in section
    assert "`<source_dir>-wt`" in section


def test_one_bad_symlink_in_devdoc_does_not_fail_the_listing(tmp_path):
    # #1050 final review: DirEntry.is_dir() raises on ELOOP; one such entry must not
    # make every present issue dir in the project unverifiable.
    devdoc, _ = _issue7_devdoc(tmp_path, "- [ ] c {issue: Issue-7}\n")
    try:
        os.symlink("loop", devdoc / "loop")
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unsupported")
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    assert _report_of(doc, "checklist_unreadable", "stuck_unreadable") == []
    entry = doc["projects"][0]["issues"][0]
    assert _pick(entry) == ("open", 2, "draft", {"step": "2 draft", "reason": None, "since": None,
                                                 "kind": "stuck"})


# --- #735: the actuals slot, the project field and the top-level object ---------

def _slot(total):
    return {"milestones": [{"at": "2026-11-01T10:00:00Z", "event": "opened", "source": "tracker"}],
            "sessions": [{"cwd_slug": "-w-alpha", "host": "h1", "session": "S1"}],
            "time": {"agent_busy_s": 1.0, "agent_wall_s": 1.0, "operator_s": 0.0, "operator_events": 0,
                     "returns_after_absence": 0, "fallback_events": 0},
            "tokens": {"main": total, "subagents": 0.0, "total": total,
                       "raw": [{"model": "m", "input": int(total), "cache_read": 0, "cache_write_5m": 0,
                                "cache_write_1h": 0, "output": 0}]}}


ALPHA_OVERHEAD = {"overhead": {"rules": {"cwd": 1, "hint": 2},
                               "sessions": [{"cwd_slug": "-w", "host": "local", "session": "S9"}],
                               "tokens": {"main": 3.0, "subagents": 0.0, "total": 3.0, "raw": []}}}
UNASSIGNED = [{"cwd": "/home/op", "sessions": [], "tokens": None}]


def _actuals(at="2026-11-05T00:00:00Z", **changes):
    doc = {"actuals_version": "1.0", "generated_at": at,
           "inputs": {"archive": None, "hosts": ["local"], "project": None},
           "issues": [{"project": "alpha", "issue": "Issue-1", "actuals": _slot(10.0)},
                      {"project": "alpha", "issue": "Issue-3", "actuals": _slot(30.0)},
                      {"project": "alpha", "issue": "Issue-999", "actuals": _slot(99.0)},
                      {"project": "beta", "issue": "Issue-1", "actuals": _slot(11.0)},
                      {"project": "nowhere", "issue": "Issue-1", "actuals": _slot(1.0)}],
           "projects": [{"project": "alpha", "actuals": ALPHA_OVERHEAD},
                        {"project": "gamma", "actuals": {"overhead": None}}],
           "unassigned": UNASSIGNED, "sources": [],
           "time_rule": {"attention_cap_s": 900.0, "idle_gap_s": 300.0, "tool_gap_s": 3600.0}}
    doc.update(changes)
    return doc


def _write_actuals(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8")
    return str(path)


def _slots(doc):
    return {(p["project"], e["issue"]): e["actuals"] for p in doc["projects"] for e in p["issues"]}


def _unavailable(doc):
    return [(r["project"], r["source_line"], r["message"]) for r in doc["parse_report"]
            if r["kind"] == "actuals_unavailable"]


def test_actuals_fill_slots_and_project_field(tmp_path):
    """AC6: each slot and project field is its row's object; the top level carries the file's three fields."""
    _, projects = _multi(tmp_path)
    path = _write_actuals(tmp_path / "a" / "actuals.json", _actuals())
    doc = pf.build_document(projects, GENERATED_AT, path)
    slots = _slots(doc)
    assert slots[("alpha", "Issue-1")] == _slot(10.0)
    assert slots[("alpha", "Issue-3")] == _slot(30.0)
    assert slots[("beta", "Issue-1")] == _slot(11.0)
    assert sum(1 for v in slots.values() if v is not None) == 3
    assert len(slots) == 16
    fields = {p["project"]: p["actuals"] for p in doc["projects"]}
    assert fields == {**{n: None for n in CONFIG_ORDER}, "alpha": ALPHA_OVERHEAD, "gamma": {"overhead": None}}
    assert doc["actuals"] == {"actuals_version": "1.0", "generated_at": "2026-11-05T00:00:00Z",
                              "unassigned": UNASSIGNED}
    assert _unavailable(doc) == []
    assert pf._self_check(doc) is None


UNAVAILABLE = "actuals are empty"


@pytest.mark.parametrize("state, message", [
    ("missing", "{path} does not exist; actuals are empty; run /devagent:actuals"),
    ("directory", "{path} could not be read: "),
    ("torn", "{path} could not be read: "),
    ("null", "{path} is not a usable actuals document: not a JSON object; actuals are empty; "
             "run /devagent:actuals"),
    ("major-2", "{path} is not a usable actuals document: actuals_version 2.0 is not major 1; "
                "actuals are empty; run /devagent:actuals"),
    ("newer-minor", "{path} is not a usable actuals document: actuals_version 1.1 is newer than this "
                    "reader (1.0); actuals are empty; run /devagent:actuals"),
    ("bad-slot", "{path} is not a usable actuals document: issues[1].actuals.tokens.total: expected number, "
                 "got string; actuals are empty; run /devagent:actuals"),
    ("one-project", "{path} is not a usable actuals document: inputs.project is 'alpha': a one-project "
                    "document; actuals are empty; run /devagent:actuals"),
    ("8-days", "{path} was generated at 2026-10-28T23:59:59Z, more than 7 days before this document; "
               "actuals are empty; run /devagent:actuals"),
])
def test_actuals_unavailable_states(tmp_path, monkeypatch, capsys, state, message):
    _, projects = _multi(tmp_path)
    target = tmp_path / "a" / "actuals.json"
    bad = _actuals()
    bad["issues"][1]["actuals"]["tokens"]["total"] = "30"
    body = {"directory": None, "torn": '{"actuals_version": "1.0", ', "null": "null",
            "major-2": _actuals(actuals_version="2.0"), "newer-minor": _actuals(actuals_version="1.1"),
            "bad-slot": bad, "one-project": _actuals(inputs={"archive": None, "hosts": [], "project": "alpha"}),
            "8-days": _actuals(at="2026-10-28T23:59:59Z")}
    if state == "directory":
        target.mkdir(parents=True)
    elif state != "missing":
        _write_actuals(target, body[state])
    path = str(target)
    doc = pf.build_document(projects, GENERATED_AT, path)
    assert all(v is None for v in _slots(doc).values()) and len(_slots(doc)) == 16
    assert all(p["actuals"] is None for p in doc["projects"]) and doc["actuals"] is None
    got = _unavailable(doc)
    assert [p for p, _, _ in got] == CONFIG_ORDER   # one per project, in config order
    expected = message.format(path=path)
    for _, line, text in got:
        assert line is None
        assert text == expected if not expected.endswith(": ") else (
            text.startswith(expected) and text.endswith("; actuals are empty") and "\n" not in text)
    assert pf._self_check(doc) is None
    root = tmp_path / "multi"
    _manifest(monkeypatch, [(n, str(root / n)) for n in ("alpha", "beta")], actuals=path)
    out = tmp_path / "out" / "p.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_OK
    capsys.readouterr()


@pytest.mark.parametrize("at", ["2026-10-30T00:00:00Z", "2026-11-06T01:00:00Z"], ids=["7-days", "future-1h"])
def test_actuals_edge_ages_are_used(tmp_path, at):
    _, projects = _multi(tmp_path)
    path = _write_actuals(tmp_path / "a" / "actuals.json", _actuals(at=at))
    doc = pf.build_document(projects, GENERATED_AT, path)
    assert _unavailable(doc) == []
    assert doc["actuals"]["generated_at"] == at


def test_actuals_no_project_carries_no_entry(tmp_path):
    doc = pf.build_document([], GENERATED_AT, str(tmp_path / "none.json"))
    assert doc["parse_report"] == [] and doc["actuals"] is None
    assert pf._self_check(doc) is None


def test_actuals_unmatched_rows_are_ignored(tmp_path):
    _, projects = _multi(tmp_path)
    doc = pf.build_document(projects, GENERATED_AT, _write_actuals(tmp_path / "a.json", _actuals()))
    assert ("alpha", "Issue-999") not in _slots(doc)
    assert not any("Issue-999" in r["message"] or "nowhere" in r["message"] for r in doc["parse_report"])


def _keys_named(value, name):
    if isinstance(value, dict):
        return (name in value) + sum(_keys_named(v, name) for v in value.values())
    if isinstance(value, list):
        return sum(_keys_named(v, name) for v in value)
    return 0


def test_actuals_none_means_no_keys(tmp_path):
    _, projects = _multi(tmp_path)
    doc = pf.build_document(projects, GENERATED_AT, None)
    assert _keys_named(doc, "actuals") == 0
    assert _unavailable(doc) == []
    wired = pf.build_document(projects, GENERATED_AT, str(tmp_path / "none.json"))
    assert _keys_named(wired, "actuals") == 1 + len(CONFIG_ORDER) + 16


# One process-wide audit hook (hooks cannot be removed): it raises only while armed.
_FORBIDDEN = ("subprocess.Popen", "os.system", "os.exec", "os.fork", "os.forkpty", "os.posix_spawn", "os.spawn",
              "socket.connect", "socket.getaddrinfo", "socket.gethostbyname")
_ARMED = []


def _forbid(event, _args):
    if _ARMED and event in _FORBIDDEN:
        raise RuntimeError(f"forbidden during build: {event}")


sys.addaudithook(_forbid)


def test_build_starts_no_subprocess_and_no_network(tmp_path):
    """AC6: the aggregator only reads actuals.json, in every state."""
    _, projects = _multi(tmp_path)
    good = _write_actuals(tmp_path / "good.json", _actuals())
    torn = _write_actuals(tmp_path / "torn.json", "{")
    stale = _write_actuals(tmp_path / "stale.json", _actuals(at="2026-01-01T00:00:00Z"))
    (tmp_path / "dir.json").mkdir()
    _ARMED.append(1)
    try:
        with pytest.raises(RuntimeError):   # positive control: the hook fires
            os.system("true")
        for path in (good, torn, stale, str(tmp_path / "dir.json"), str(tmp_path / "absent.json"), None):
            pf.build_document(projects, GENERATED_AT, path)
    finally:
        _ARMED.clear()
    names = set()
    for f in (PRODUCER, LIB / "portfolio-check.py", LIB / "wbs-parser.py"):
        for node in ast.walk(ast.parse(f.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Import):
                names.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                names.add(node.module.split(".")[0])
    assert names and not names & {"subprocess", "socket", "urllib", "http"}


def test_build_deterministic_with_actuals(tmp_path):
    _, projects = _multi(tmp_path)
    path = _write_actuals(tmp_path / "a.json", _actuals())
    assert pf.dumps(pf.build_document(projects, GENERATED_AT, path)) == \
        pf.dumps(pf.build_document(projects, GENERATED_AT, path))


@pytest.mark.parametrize("value", [None, ""], ids=["unset", "empty"])
def test_manifest_requires_actuals_path(tmp_path, monkeypatch, capsys, value):
    _manifest(monkeypatch, [], actuals=value)
    out = tmp_path / "p.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_USAGE
    assert "PORTFOLIO_ACTUALS is not set" in capsys.readouterr().err
    assert not out.exists()
    assert pf.main(["ready"]) == pf.EXIT_OK   # ready builds without actuals


def test_actuals_with_a_lone_surrogate_is_unusable_not_a_crash(tmp_path, monkeypatch, capsys):
    """Final review I1: json accepts "\\ud800", UTF-8 cannot encode it; the file is unusable, exit 0."""
    root, _ = _multi(tmp_path)
    path = tmp_path / "a" / "actuals.json"
    path.parent.mkdir()
    path.write_text(json.dumps(_actuals(unassigned=[{"cwd": "\ud800", "sessions": [], "tokens": None}])),
                    encoding="utf-8")
    _manifest(monkeypatch, [("alpha", str(root / "alpha"))], actuals=str(path))
    out = tmp_path / "out" / "p.json"
    assert pf.main(["build", "--out", str(out)]) == pf.EXIT_OK
    capsys.readouterr()
    doc = json.loads(out.read_bytes().decode("utf-8"))
    assert _unavailable(doc) == [("alpha", None, f"{path} is not a usable actuals document: a string is not "
                                                 "valid UTF-8 (a lone surrogate); actuals are empty; run "
                                                 "/devagent:actuals")]
    assert doc["actuals"] is None


# --- #963: parked, stuck.kind, rule 1, state_unreadable ------------------------

@pytest.mark.parametrize("text,want", [
    ("Step: 5 improve\nReason: r\n", "stuck"),
    ("Kind:        question\nStep: 5 improve\n", "question"),
    ("Step: 5 improve\n\nKind: question\n", "stuck"),
    ("Kind: question\r\nStep: 5 improve\r\n\r\nKind: x\r\n", "question"),
    ("Kind:\nStep: 5 improve\n", "stuck"),
    ("Kind:\nKind: later\n", "later"),
    ("Step: 5 improve\n## Question\nKind: question\n", "stuck"),
    ("Step: 5 improve\n \t\nKind: question\n", "stuck"),
    (" Kind: x\nStep: 5 improve\n", "stuck"),
    ("Step: 5 improve\n### x\nKind: deep\n", "deep"),
], ids=["no-kind", "question", "after-blank", "crlf", "lone-blank", "blank-then-later",
        "ends-at-h2", "whitespace-line", "indented", "h3-not-end"])
def test_stuck_header_kind_rule(text, want):
    assert pf.stuck_header_kind(text.split("\n")) == want


def _rule1_devdoc(tmp_path, stucks=None):
    """A WBS with three pending issue leaves and one no-issue leaf."""
    devdoc = tmp_path / "devdoc"
    devdoc.mkdir(parents=True)
    (devdoc / "WBS.md").write_text(
        "# p\n\n- [ ] Held {issue: Issue-1}\n- [ ] Parked {issue: Issue-2}\n"
        "- [ ] Free {issue: Issue-3}\n- [ ] Loose\n", encoding="utf-8")
    for issue in ("Issue-1", "Issue-2", "Issue-3"):
        (devdoc / issue).mkdir()
    for issue, text in (stucks or {}).items():
        (devdoc / issue / "STUCK").write_text(text, encoding="utf-8")
    return devdoc


def _rule1_doc(tmp_path, state_status="read", parked=frozenset(), stucks=None):
    devdoc = _rule1_devdoc(tmp_path, stucks)
    p = pf.ProjectInput("p", str(devdoc), state_status=state_status, parked=frozenset(parked))
    return pf.build_document([p], GENERATED_AT, None)


def _by_issue(doc):
    nodes = {n["text"]: n for n in doc["projects"][0]["nodes"]}
    entries = {e["issue"]: e for e in doc["projects"][0]["issues"]}
    return nodes, entries


QUESTION_STUCK = "Kind:        question\nStep:        5 improve\nReason:      r\n\n## Question\n\nq?\n"
PLAIN_STUCK = "Step:        5 improve\nReason:      r\n"


def test_ready_excludes_held_issue(tmp_path):
    doc = _rule1_doc(tmp_path, stucks={"Issue-1": QUESTION_STUCK})
    nodes, entries = _by_issue(doc)
    assert nodes["Held"]["ready"] is False
    assert entries["Issue-1"]["stuck"]["kind"] == "question"
    assert not any("\tIssue-1\t" in line for line in pf.ready_lines(doc))
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_ready_excludes_parked_issue(tmp_path):
    doc = _rule1_doc(tmp_path, parked={"Issue-2"})
    nodes, entries = _by_issue(doc)
    assert nodes["Parked"]["ready"] is False
    assert entries["Issue-2"]["parked"] is True
    assert entries["Issue-2"]["stuck"] is None
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_ready_excludes_plain_stuck_issue(tmp_path):
    doc = _rule1_doc(tmp_path, stucks={"Issue-1": PLAIN_STUCK})
    nodes, entries = _by_issue(doc)
    assert nodes["Held"]["ready"] is False
    assert entries["Issue-1"]["stuck"]["kind"] == "stuck"


def test_ready_unaffected_issue(tmp_path):
    for status in ("read", "absent"):
        doc = _rule1_doc(tmp_path / status, state_status=status)
        nodes, entries = _by_issue(doc)
        assert entries["Issue-3"]["parked"] is False
        assert nodes["Free"]["ready"] is True
        assert nodes["Loose"]["ready"] is True
    doc = _rule1_doc(tmp_path / "unreadable", state_status="unreadable")
    nodes, _ = _by_issue(doc)
    assert nodes["Loose"]["ready"] is True


def test_state_unreadable_fails_closed(tmp_path):
    doc = _rule1_doc(tmp_path, state_status="unreadable")
    nodes, entries = _by_issue(doc)
    assert all(e["parked"] is None for e in entries.values())
    assert [nodes[t]["ready"] for t in ("Held", "Parked", "Free")] == [False, False, False]
    found = [r for r in doc["parse_report"] if r["kind"] == "state_unreadable"]
    assert len(found) == 1 and found[0]["project"] == "p" and found[0]["source_line"] is None
    assert not any(str(tmp_path) in r["message"] or ".toml" in r["message"]
                   for r in doc["parse_report"])
    assert pf.pc.check(doc) == [] and pf.invariant_violations(doc) == []


def test_state_unreadable_reported_when_wbs_not_read(tmp_path):
    p = pf.ProjectInput("q", str(tmp_path / "missing"), state_status="unreadable")
    doc = pf.build_document([p], GENERATED_AT, None)
    assert [r["kind"] for r in doc["parse_report"]] == ["state_unreadable"]


def test_stuck_kind_null_when_unreadable(tmp_path):
    devdoc = _rule1_devdoc(tmp_path)
    (devdoc / "Issue-1" / "STUCK").mkdir()
    doc = pf.build_document([pf.ProjectInput("p", str(devdoc))], GENERATED_AT, None)
    _, entries = _by_issue(doc)
    assert entries["Issue-1"]["stuck"] == {"step": None, "reason": None, "since": None,
                                           "kind": None}
    assert [r["kind"] for r in doc["parse_report"]].count("stuck_unreadable") == 1


def test_absent_parked_reads_false(tmp_path):
    doc = _rule1_doc(tmp_path)
    projects = copy.deepcopy(doc["projects"])
    for e in projects[0]["issues"]:
        assert e.pop("parked") is False
    with_key, without = pf.compute_readiness(doc["projects"]), pf.compute_readiness(projects)
    assert with_key.ready == without.ready


def test_older_minor_ready_not_recomputed():
    d = _example()
    d["schema_version"] = "1.1"
    pf.apply_readiness(d["projects"], lambda p: lambda *a: None)
    assert _node(d, "n5")["ready"] is True
    _entry(d, "Issue-10")["stuck"] = {"step": "2 draft", "reason": None, "since": None}
    assert pf.invariant_violations(d) == []
    # The same document at the producer's minor is recomputed and differs.
    _at_own_minor(d)
    assert any(v.startswith("I16: node n5: ready") for v in pf.invariant_violations(d))


def test_read_manifest_state_vars(monkeypatch):
    _manifest(monkeypatch, [("a", "/d/a"), ("b", "/d/b"), ("c", "/d/c")])
    monkeypatch.setenv("PORTFOLIO_STATE_STATUS_1", "read")
    monkeypatch.setenv("PORTFOLIO_PARKED_1", "Issue-1\nIssue-2\n")
    monkeypatch.setenv("PORTFOLIO_STATE_STATUS_2", "unreadable")
    monkeypatch.setenv("PORTFOLIO_PARKED_2", "Issue-9")
    a, b, c = pf.read_manifest()
    assert (a.state_status, a.parked) == ("absent", frozenset())
    assert (b.state_status, b.parked) == ("read", frozenset({"Issue-1", "Issue-2"}))
    assert (c.state_status, c.parked) == ("unreadable", frozenset())
    monkeypatch.setenv("PORTFOLIO_STATE_STATUS_0", "bogus")
    with pytest.raises(pf.ManifestError,
                       match=r"^PORTFOLIO_STATE_STATUS_0 is 'bogus', not absent, unreadable or read$"):
        pf.read_manifest()


def test_main_ready_state_unreadable_line(tmp_path, monkeypatch, capsys):
    devdoc = _rule1_devdoc(tmp_path)
    _manifest(monkeypatch, [("p", str(devdoc)), ("q", str(tmp_path / "missing"))])
    monkeypatch.setenv("PORTFOLIO_STATE_STATUS_0", "unreadable")
    monkeypatch.setenv("PORTFOLIO_STATE_STATUS_1", "unreadable")
    assert pf.main(["ready"]) == pf.EXIT_OK
    out, err = capsys.readouterr()
    assert err.splitlines() == [
        pf.STATE_UNREADABLE_MSG.format(project="p"),
        pf.NOT_READ_MSG.format(project="q", status="no_devdoc_dir")]
    assert err.splitlines()[0] == ("portfolio: p: devagent state could not be read; "
                                   "leaves with an issue are not listed")
    assert out == "p\t\t\tLoose\n"
