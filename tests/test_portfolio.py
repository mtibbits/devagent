"""Tests for the portfolio producer (#726): scripts/lib/portfolio.py."""
import ast
import copy
import importlib.util
import json
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


def test_rollup_matches_example():
    # #725 worked these figures independently of this producer.
    read = [p for p in _example()["projects"] if p["status"] == "read"]
    assert len(read) == 2
    for p in read:
        assert pf.rollup(p["nodes"]) == p["rollup"], p["project"]


# --- invariants I1–I15 ---------------------------------------------------------

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
]

# Rows that must NOT fire.
SURVIVE_ROWS = [
    ("I13", "hours-off-1e-12", _bump(RU + ("remaining", "low_hours"), 1e-12)),
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
    assert pf.INVARIANTS == tuple(f"I{i}" for i in range(1, 16))
    assert len(MUTATION_ROWS) >= 40
    assert len({(t, r) for t, r, _ in MUTATION_ROWS}) == len(MUTATION_ROWS)


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
