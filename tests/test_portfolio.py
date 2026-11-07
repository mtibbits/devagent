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


def _wbs_text(project):
    return (MULTI / project / "WBS.md").read_bytes().decode("utf-8")


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
    _, doc = _build(tmp_path)
    assert {r["kind"] for r in doc["parse_report"]} == set(pf.KINDS)
    assert len(pf.KINDS) == len(set(pf.KINDS)) == 16


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
    assert all(d["resolved"] is None for d in all_deps)


def test_producer_keys_not_reported_unknown(tmp_path):
    _, doc = _build(tmp_path)
    msgs = [r["message"] for r in doc["parse_report"] if r["kind"] == "unknown_meta_key"]
    assert msgs == ["unknown metadata key 'jira'", "unknown metadata key 'foo, est'"]
    issue2 = next(n for n in _project(doc, "alpha")["nodes"] if n["issue"] == "Issue-2")
    assert set(issue2["meta_unknown_keys"]) >= pf.PRODUCER_KEYS


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


# --- write path and CLI --------------------------------------------------------

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
    assert pf.read_manifest() == [
        pf.ProjectInput("alpha", "/d/a", "/s/a", "/w"),
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
                                  ["build", "--out", "a", "extra"]])
def test_main_usage(argv, capsys):
    assert pf.main(argv) == pf.EXIT_USAGE
    assert pf.USAGE in capsys.readouterr().err


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
    assert alpha["Issue-1"]["checklist"] == "absent" and alpha["Issue-2"]["stuck"] is None
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
