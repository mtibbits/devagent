#!/usr/bin/env python3
"""portfolio.py — #726. Build the portfolio document (schema v1.1, #725) over
every configured project's WBS.md, with a parse report that drops nothing
silently, and write it only when it passes both the structural checker
(portfolio-check.py) and this module's own cross-field invariants I1–I16.

    portfolio.py build --out PATH
    portfolio.py ready

`ready` builds the same document in memory, runs the same self-check, and
prints one TSV line per ready leaf (ready_lines); it writes nothing.

The project manifest arrives as indexed environment variables, set by
scripts/portfolio.sh from config.toml (this module reads no TOML):
PORTFOLIO_PROJECT_COUNT, and per project i (0-based) PORTFOLIO_NAME_<i>,
PORTFOLIO_DEVDOC_<i>, PORTFOLIO_SOURCE_<i> and PORTFOLIO_WORKTREE_<i>, each
path variable set only when configured (it may be empty).

Standard library only (3.10+), like portfolio-check.py. docs/portfolio-schema.md
is the contract; commands/portfolio.md is the user doc.
"""
from __future__ import annotations

import contextlib
import errno
import importlib.util
import io
import json
import math
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

LIB = Path(__file__).resolve().parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Registered before exec: a frozen dataclass under `from __future__ import
    # annotations` looks its module up in sys.modules while it is being built.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


wbs_parser = _load("_portfolio_wbs_parser", LIB / "wbs-parser.py")
pc = _load("_portfolio_check", LIB / "portfolio-check.py")

USAGE = "usage: portfolio.py build --out PATH | portfolio.py ready"

# --- per-node derivations ------------------------------------------------------

# Interim estimate classifier (D16), built from #737's drafted table. The
# factors are WORKING-time hours and provisional: #737's helper replaces this
# classifier when it lands. Every match is a fullmatch on the value as written.
HOUR_FACTORS: dict[str, int] = {"h": 1, "d": 8, "w": 40}
PLACEHOLDER_RE = re.compile(r"\?[A-Za-z]*")
# Digit caps keep every number finite and small: no inf or huge-int path.
QUANTITY_RE = re.compile(r"(?P<q>[0-9]{1,9}(?:\.[0-9]{1,6})?)(?P<u>[A-Za-z]+)")
EST_SRC_VALUES = ("confirmed", "derived")
# Keys this producer consumes. `satisfies` and `h` are parser-known keys
# (#888), so they never reach `meta_unknown_keys`; `est_src` is not, and the
# unknown-key report skips it.
PRODUCER_KEYS: frozenset[str] = frozenset({"est_src", "satisfies", "h"})


def _num(d: Decimal) -> int | float:
    """An exact decimal as JSON wants it: an int when integral (D14)."""
    return int(d) if d == d.to_integral_value() else float(d)


def classify_est(raw) -> dict:
    """`meta.est` as the schema's Est fields (without `src`)."""
    out = {"raw": raw, "class": "unparseable", "low_hours": None,
           "high_hours": None, "quantity": None, "unit": None}
    if raw is None:
        out["class"] = "absent"
    elif isinstance(raw, str):
        if PLACEHOLDER_RE.fullmatch(raw):
            out["class"] = "placeholder"
        elif m := QUANTITY_RE.fullmatch(raw):
            q, unit = Decimal(m.group("q")), m.group("u")
            if unit in HOUR_FACTORS:
                hours = _num(q * HOUR_FACTORS[unit])
                out.update({"class": "time", "low_hours": hours, "high_hours": hours})
            else:
                out.update({"class": "non-time", "quantity": _num(q), "unit": unit})
    return out


def est_src(meta: dict) -> tuple[str | None, bool]:
    """(`est.src`, invalid): a value other than confirmed/derived reads as null."""
    if "est_src" not in meta:
        return None, False
    v = meta["est_src"]
    if isinstance(v, str) and v in EST_SRC_VALUES:
        return v, False
    return None, True


def read_h(meta: dict) -> tuple[int | None, bool]:
    """(`h`, malformed): one digit 0–4 as written, else null."""
    h, problem = wbs_parser.h_value(meta)
    return h, problem is not None


def node_issue(meta: dict) -> tuple[str | None, bool]:
    """(`issue`, malformed): a non-empty string passes; a non-string is malformed."""
    v = meta.get("issue")
    if v is None or v == "":
        return None, False
    if isinstance(v, str):
        return v, False
    return None, True


def as_list(v) -> list:
    """Falsy gives [], a list stays a list, a scalar gives [v]."""
    return wbs_parser.as_list(v)


def split_dep(raw: str, project: str) -> dict:
    """One `depends_on` entry by #887's split rule (schema doc, Dependency split)."""
    pair = wbs_parser.split_namespaced(raw)
    if pair is not None:
        left, right = pair
        scope = "local" if left == project else "foreign"
        return {"raw": raw, "scope": scope, "project": left, "issue": right,
                "resolved": None}
    return {"raw": raw, "scope": "local", "project": project, "issue": raw,
            "resolved": None}


def node_deps(meta: dict, project: str) -> list[dict]:
    """A node's `depends_on`, read exactly as the parser's `_dep_ids` reads it."""
    return [split_dep(raw, project) for raw in wbs_parser._dep_ids(meta)]


# --- issue-directory readers ---------------------------------------------------

# A checklist step row: _checklist_line_re (scripts/lib/checklist.sh) with the
# name captured; twin of ROW_RE in scripts/lib/wbs-tracker.py, which drops the
# name group (a test holds the two equal).
STEP_ROW_RE = re.compile(r"^- \[(.)\][ \t\n\r\f\v]+([0-9]+)\.[ \t\n\r\f\v]+([A-Za-z][A-Za-z0-9_-]*)")
REVISION_HEADING = "## Revision "
# A done checklist step row: no work left, done or skipped. It agrees on
# purpose with wbs-tracker.py DONE_GLYPHS and wbs-parser.py FINISHED_GLYPHS
# (WBS node glyphs, another grammar); no import ties them, so
# tests/test_portfolio.py::test_finished_glyph_sets_agree pins the three
# equal. Boundary: these are the Python copies; the shell spellings at
# checklist.sh:234, mergemr.sh:77, next.sh:176, doctor.sh:241 and
# migrate-checklist-numbering.sh:135 are not pinned (#784).
DONE_GLYPHS = frozenset({"x", "-"})


class ChecklistError(Exception):
    """A present checklist.md that cannot be read, or has no step rows in scope."""


class StuckError(Exception):
    """A present STUCK file that cannot be read."""


def _err_detail(e: Exception) -> str:
    """`<ExceptionClass>: <detail>`, never naming a path (the document is shared)."""
    if isinstance(e, UnicodeDecodeError):
        return f"UnicodeDecodeError: {e.reason} at byte {e.start}"
    if isinstance(e, OSError):
        return f"{type(e).__name__}: {e.strerror or 'error'}"
    return f"{type(e).__name__}: {e}"


def _read_lines(path, error) -> list[str]:
    try:
        text = Path(path).read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise error(_err_detail(e)) from e
    # Lines split on LF only, as bash `read` does; a CR stays on its line.
    return text.split("\n")


def checklist_next(path) -> tuple[str, int | None, str | None]:
    """("open", n, name) or ("complete", None, None), by next.sh's rule.

    The port of checklist_current_step + checklist_step_name: scope is the
    rows after the last `## Revision ` line (else the whole file); the first
    row whose glyph is not x/- is the next step, and its name is the first
    row in scope carrying that number. Raises ChecklistError on no rows in
    scope or an unreadable file.
    """
    lines = _read_lines(path, ChecklistError)
    start = 0
    for i, line in enumerate(lines, start=1):
        if line.startswith(REVISION_HEADING):
            start = i
    rows = [m for m in (STEP_ROW_RE.match(line) for line in lines[start:]) if m]
    if not rows:
        raise ChecklistError("no step rows in the active revision block")
    for m in rows:
        if m.group(1) not in DONE_GLYPHS:
            num = m.group(2)
            name = next(r.group(3) for r in rows if r.group(2) == num)
            return "open", int(num), name
    return "complete", None, None


STUCK_KEYS = (("step", "Step:"), ("reason", "Reason:"), ("since", "Created:"))


def read_stuck(path) -> dict:
    """A STUCK file's Step:/Reason:/Created: values verbatim (first of each)."""
    out: dict[str, str | None] = {k: None for k, _ in STUCK_KEYS}
    for line in _read_lines(path, StuckError):
        for key, prefix in STUCK_KEYS:
            if out[key] is None and line.startswith(prefix):
                out[key] = line[len(prefix):].strip()
    return out


# --- reference rollup ----------------------------------------------------------

STATES: tuple[str, ...] = tuple(wbs_parser.STATE_GLYPHS.values())
NOT_REMAINING = frozenset({"done", "skipped"})


def _bucket(est: dict) -> str:
    if est["class"] != "time":
        return "unestimated"
    return "estimated_derived" if est["src"] == "derived" else "estimated"


def _dec(x) -> Decimal:
    # str() of a float is its shortest repr, so 2.5 sums as exactly 2.5.
    return Decimal(str(x))


def rollup(nodes: list[dict]) -> dict:
    """The schema's Rollup over `nodes`: leaves only, parents never summed.

    `remaining` is every leaf not done or skipped (statusreport's rule);
    its hours sum the remaining `time` leaves, derived included, and its
    `non_time` totals each unit as written.
    """
    def counts() -> dict:
        return {"leaves": 0, "estimated": 0, "estimated_derived": 0, "unestimated": 0}

    by_state = {s: counts() for s in STATES}
    remaining = counts()
    low = high = Decimal(0)
    non_time: dict[str, Decimal] = {}
    for node in nodes:
        if not node["leaf"]:
            continue
        est = node["est"]
        bucket = _bucket(est)
        by_state[node["state"]]["leaves"] += 1
        by_state[node["state"]][bucket] += 1
        if node["state"] in NOT_REMAINING:
            continue
        remaining["leaves"] += 1
        remaining[bucket] += 1
        if est["class"] == "time":
            low += _dec(est["low_hours"])
            high += _dec(est["high_hours"])
        elif est["class"] == "non-time":
            non_time[est["unit"]] = non_time.get(est["unit"], Decimal(0)) + _dec(est["quantity"])
    remaining.update({
        "low_hours": _num(low), "high_hours": _num(high),
        "non_time": {u: _num(q) for u, q in non_time.items()},
    })
    return {"by_state": by_state, "remaining": remaining}


# --- invariants I1–I16 ---------------------------------------------------------

INVARIANTS: tuple[str, ...] = tuple(f"I{i}" for i in range(1, 17))


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _rollup_diffs(want, got, path: str) -> list[str]:
    """Where `got` differs from `want`: ints exactly, floats by isclose."""
    if isinstance(want, dict) and isinstance(got, dict):
        if set(want) != set(got):
            return [f"{path}: keys {sorted(got)} != {sorted(want)}"]
        out: list[str] = []
        for k in want:
            out += _rollup_diffs(want[k], got[k], f"{path}.{k}")
        return out
    if _is_num(want) and _is_num(got):
        if isinstance(want, int) and isinstance(got, int):
            same = want == got
        else:
            same = math.isclose(want, got, rel_tol=1e-9, abs_tol=1e-9)
        return [] if same else [f"{path}: {got!r} != recomputed {want!r}"]
    return [] if want == got else [f"{path}: {got!r} != recomputed {want!r}"]


def _node_violations(node: dict, project: str, add) -> None:
    nid, meta, est = node["id"], node["meta"], node["est"]
    want_issue = node_issue(meta)[0]
    if node["issue"] != want_issue:
        add("I4", f"node {nid}: issue {node['issue']!r} != meta.issue {want_issue!r}")
    # I6
    raw, cls = est["raw"], est["class"]
    if raw != meta.get("est"):
        add("I6", f"node {nid}: est.raw {raw!r} != meta.est {meta.get('est')!r}")
    if (cls == "absent") != (raw is None):
        add("I6", f"node {nid}: class {cls!r} with raw {raw!r}")
    lo, hi, q, unit = est["low_hours"], est["high_hours"], est["quantity"], est["unit"]
    if cls == "time":
        if not (_is_num(lo) and _is_num(hi) and 0 <= lo <= hi):
            add("I6", f"node {nid}: time needs hours 0 <= low <= high, got {lo!r}, {hi!r}")
        if q is not None or unit is not None:
            add("I6", f"node {nid}: time with quantity/unit set")
    elif cls == "non-time":
        if not (_is_num(q) and isinstance(unit, str) and unit):
            add("I6", f"node {nid}: non-time needs a quantity and a unit, got {q!r}, {unit!r}")
        if lo is not None or hi is not None:
            add("I6", f"node {nid}: non-time with hours set")
    elif (lo, hi, q, unit) != (None, None, None, None):
        add("I6", f"node {nid}: class {cls!r} with hours/quantity/unit set")
    want_src = est_src(meta)[0]
    if est["src"] != want_src:
        add("I7", f"node {nid}: est.src {est['src']!r} != {want_src!r}")
    if node["satisfies"] != as_list(meta.get("satisfies")):
        add("I8", f"node {nid}: satisfies {node['satisfies']!r} != meta.satisfies as a list")
    want_h = read_h(meta)[0]
    if node["h"] != want_h:
        add("I9", f"node {nid}: h {node['h']!r} != {want_h!r}")
    # I10 (D13: the non-empty-issue clause applies to a non-empty raw only)
    deps = node["depends_on"]
    if [d["raw"] for d in deps] != wbs_parser._dep_ids(meta):
        add("I10", f"node {nid}: depends_on raws != meta.depends_on in order")
    for d in deps:
        if d["scope"] == "local" and d["project"] != project:
            add("I10", f"node {nid}: local dep {d['raw']!r} names project {d['project']!r}")
        if d["scope"] == "foreign":
            if d["project"] == project:
                add("I10", f"node {nid}: foreign dep {d['raw']!r} names its own project")
            if d["raw"] != f"{d['project']}:{d['issue']}":
                add("I10", f"node {nid}: foreign dep {d['raw']!r} != project:issue")
        if d["raw"] and not d["issue"]:
            add("I10", f"node {nid}: dep {d['raw']!r} has an empty issue")
    unknown = node["meta_unknown_keys"]
    if len(set(unknown)) != len(unknown) or not set(unknown) <= set(meta):
        add("I11", f"node {nid}: meta_unknown_keys {unknown!r} not a duplicate-free subset of meta")


def invariant_violations(doc: dict) -> list[str]:
    """The cross-field rules the structural checker does not decide (#725).

    Each entry is `"I<n>: <message>"`. Reads known v1.1 fields only, so a
    document at a newer minor is checked on what this producer knows.
    Assumes `portfolio-check.check(doc)` already passed.
    """
    out: list[str] = []

    def add(tag: str, message: str) -> None:
        out.append(f"{tag}: {message}")

    projects = doc["projects"]
    names = [p["project"] for p in projects]
    if len(set(names)) != len(names):
        add("I12", f"project names are not unique: {names!r}")
    all_ids = [n["id"] for p in projects for n in p["nodes"]]
    parents = {n["parent"] for p in projects for n in p["nodes"] if n["parent"] is not None}
    if len(set(all_ids)) != len(all_ids):
        add("I1", "node ids are not unique across the document")
    for p in projects:
        name, nodes = p["project"], p["nodes"]
        # I12
        if p["status"] == "read":
            if p["rollup"] is None or p["wbs_title"] is None:
                add("I12", f"project {name!r}: read with a null rollup or wbs_title")
            if p["status_reason"] is not None:
                add("I12", f"project {name!r}: read with a status_reason")
        else:
            if nodes or p["issues"] or p["rollup"] is not None or p["wbs_title"] is not None:
                add("I12", f"project {name!r}: {p['status']} with nodes, issues, rollup or title")
            if not (isinstance(p["status_reason"], str) and p["status_reason"]):
                add("I12", f"project {name!r}: {p['status']} needs a non-empty status_reason")
        # I2, I3
        index = {n["id"]: i for i, n in enumerate(nodes)}
        for i, n in enumerate(nodes):
            if i and n["source_line"] <= nodes[i - 1]["source_line"]:
                add("I2", f"node {n['id']}: source_line does not ascend")
            parent = n["parent"]
            if parent is not None:
                j = index.get(parent)
                if j is None:
                    add("I2", f"node {n['id']}: parent {parent!r} is not an earlier node of {name!r}")
                elif j >= i:
                    add("I2", f"node {n['id']}: parent {parent!r} is not earlier")
                elif nodes[j]["depth"] >= n["depth"]:
                    add("I2", f"node {n['id']}: parent {parent!r} is not shallower")
        for n in nodes:
            if n["leaf"] == (n["id"] in parents):
                add("I3", f"node {n['id']}: leaf is {n['leaf']} but children say otherwise")
            if not n["leaf"] and n["ready"] is not None:
                add("I3", f"node {n['id']}: ready is set on a parent")
            _node_violations(n, name, add)
        # I5
        want: dict[str, list[str]] = {}
        for n in nodes:
            if n["issue"] is not None:
                want.setdefault(n["issue"], []).append(n["id"])
        got = [e["issue"] for e in p["issues"]]
        if sorted(got) != sorted(want) or len(set(got)) != len(got):
            add("I5", f"project {name!r}: issues {got!r} != node issues {sorted(want)!r}")
        for e in p["issues"]:
            if e["issue"] in want and e["nodes"] != want[e["issue"]]:
                add("I5", f"project {name!r}: issue {e['issue']!r} nodes {e['nodes']!r} "
                          f"!= {want[e['issue']]!r}")
            # I14: open exactly when both next-step fields are set; each is
            # null unless open (schema doc, IssueEntry).
            fields = (e["next_step"], e["next_step_number"])
            if e["checklist"] == "open":
                bad = None in fields
            else:
                bad = fields != (None, None)
            if bad:
                add("I14", f"project {name!r}: issue {e['issue']!r} checklist {e['checklist']!r} "
                           "disagrees with next_step")
        # I13
        if p["rollup"] is not None:
            for diff in _rollup_diffs(rollup(nodes), p["rollup"], f"{name}.rollup"):
                add("I13", diff)
    # I15
    known = set(names)
    for r in doc["parse_report"]:
        if r["project"] not in known:
            add("I15", f"report entry names project {r['project']!r}, not in the document")
    _readiness_violations(projects, add)
    return out


def _readiness_violations(projects: list[dict], add) -> None:
    """I16: the readiness fields are all null, or all equal a recomputation."""
    nodes = [n for p in projects for n in p["nodes"]]
    if not any(n["ready"] is not None or n.get("ready_via_parent_row") is not None
               or any(d["resolved"] is not None for d in n["depends_on"]) for n in nodes):
        return
    r = compute_readiness(projects)
    for n in nodes:
        nid = n["id"]
        resolved, fields = _readiness_fields(r, n)
        for i, (d, want) in enumerate(zip(n["depends_on"], resolved)):
            if d["resolved"] is not want:
                add("I16", f"node {nid}: depends_on[{i}].resolved {d['resolved']!r} "
                           f"!= recomputed {want!r}")
        for key, want in fields.items():
            got = n.get(key)
            if got is not want:
                add("I16", f"node {nid}: {key} {got!r} != recomputed {want!r}")


# --- readiness (#727) ----------------------------------------------------------

# An ancestor in one of these states keeps every leaf under it from being ready
# (rule 5). A done or in-progress ancestor does not.
BLOCKING_ANCESTOR = frozenset({"parked", "stuck", "blocked_external", "skipped"})


@dataclass(frozen=True)
class Readiness:
    """compute_readiness's result: field values and report findings.

    `resolved` is keyed (node id, dep index); `ready` and `via_parent_row`
    by leaf id. A node id that appears more than once in the document is
    ambiguous and is left out of all three. Each finding is
    (project, source_line, kind, message).
    """
    resolved: dict[tuple[str, int], bool]
    ready: dict[str, bool]
    via_parent_row: dict[str, bool]
    findings: list[tuple[str, int | None, str, str]]


def _line_list(lines) -> str:
    """`line N` or `lines N, M`, ascending."""
    lines = sorted(set(lines))
    if len(lines) == 1:
        return f"line {lines[0]}"
    return "lines " + ", ".join(str(n) for n in lines)


def _strong_components(adj: list[list[int]]) -> list[list[int]]:
    """Tarjan's strongly connected components, iteratively, roots in vertex order."""
    count = len(adj)
    index: list[int | None] = [None] * count
    low = [0] * count
    on_stack = [False] * count
    stack: list[int] = []
    out: list[list[int]] = []
    counter = 0
    for root in range(count):
        if index[root] is not None:
            continue
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on_stack[root] = True
        work = [(root, 0)]
        while work:
            v, i = work[-1]
            if i < len(adj[v]):
                work[-1] = (v, i + 1)
                w = adj[v][i]
                if index[w] is None:
                    index[w] = low[w] = counter
                    counter += 1
                    stack.append(w)
                    on_stack[w] = True
                    work.append((w, 0))
                elif on_stack[w]:
                    low[v] = min(low[v], index[w])
                continue
            work.pop()
            if work:
                u = work[-1][0]
                low[u] = min(low[u], low[v])
            if low[v] == index[v]:
                component = []
                while True:
                    w = stack.pop()
                    on_stack[w] = False
                    component.append(w)
                    if w == v:
                        break
                out.append(component)
    return out


def compute_readiness(projects: list[dict]) -> Readiness:
    """Readiness over the document's own project and node dicts (pure).

    Reads only project `project`/`status` and node `id`, `parent`, `leaf`,
    `state`, `issue`, `source_line` and `depends_on[].raw/scope/project/issue`.
    The rule is commands/portfolio.md's "Ready leaves": a leaf is ready when
    it is pending, no ancestor is parked, stuck, blocked externally or
    skipped, every effective dependency (its own plus every ancestor's)
    resolves, every node it resolves to is done, and the leaf is in no
    dependency cycle. The ancestor walk stops at an unknown parent id and at
    a revisit, so a malformed document cannot loop or raise.
    """
    by_name: dict[str, dict] = {}
    # {project: {issue: [nodes]}} over the nodes of read projects.
    index: dict[str, dict[str, list[dict]]] = {}
    # {project: {id: node}}, first node per id, for the ancestor walk.
    by_id: dict[str, dict[str, dict]] = {}
    seen_ids: set[str] = set()
    ambiguous: set[str] = set()
    for p in projects:
        name = p["project"]
        by_name.setdefault(name, p)
        ids = by_id.setdefault(name, {})
        issues = index.setdefault(name, {}) if p["status"] == "read" else None
        for n in p["nodes"]:
            ids.setdefault(n["id"], n)
            (ambiguous if n["id"] in seen_ids else seen_ids).add(n["id"])
            if issues is not None and n["issue"] is not None:
                issues.setdefault(n["issue"], []).append(n)

    # Every node in document order; a vertex is its position here.
    order: list[tuple[str, dict]] = [(p["project"], n) for p in projects for n in p["nodes"]]
    vertex = {id(n): k for k, (_, n) in enumerate(order)}
    findings: list[tuple[str, int | None, str, str]] = []
    resolved: dict[tuple[str, int], bool] = {}
    # Per vertex: [(entry, target project, [target nodes] or None)] in entry order.
    entries: list[list[tuple[dict, str, list[dict] | None]]] = []

    # 1. Resolve each entry (#726's messages and branch order, verbatim). A
    # dependency on a skipped row is not satisfied: one finding per entry.
    for name, n in order:
        rows = []
        for i, d in enumerate(n["depends_on"]):
            raw, target = d["raw"], d["project"]
            hits = None
            if d["scope"] == "local":
                target = name
                hits = index.get(name, {}).get(d["issue"])
                message = f"depends_on '{raw}' matches no issue in this project"
            elif target not in by_name:
                message = f"depends_on '{raw}' names project '{target}', which is not configured"
            elif by_name[target]["status"] != "read":
                message = (f"depends_on '{raw}' names project '{target}', whose WBS was not "
                           f"read ({by_name[target]['status']})")
            else:
                hits = index.get(target, {}).get(d["issue"])
                message = f"depends_on '{raw}' matches no issue in project '{target}'"
            if n["id"] not in ambiguous:
                resolved[(n["id"], i)] = bool(hits)
            if not hits:
                findings.append((name, n["source_line"], "dep_unresolved", message))
            else:
                skipped = [t["source_line"] for t in hits if t["state"] == "skipped"]
                if skipped:
                    where = _line_list(skipped)
                    if d["scope"] == "foreign":
                        where += f" of project '{target}'"
                    findings.append((name, n["source_line"], "dep_skipped",
                                     f"depends_on '{raw}' resolves to a skipped row at {where}; "
                                     "leaves that depend on it are not ready"))
            rows.append((d, target, hits))
        entries.append(rows)

    def ancestors(name: str, n: dict) -> list[dict]:
        """Ancestors within the node's own project, nearest first."""
        ids = by_id.get(name, {})
        out, seen, parent = [], {n["id"]}, n["parent"]
        while parent is not None and parent in ids and parent not in seen:
            seen.add(parent)
            node = ids[parent]
            out.append(node)
            parent = node["parent"]
        return out

    # Per vertex: its ancestors, and its effective entries (its own, then each ancestor's).
    lineages = [ancestors(name, n) for name, n in order]
    effective = [entries[k] + [row for a in lineages[k] for row in entries[vertex[id(a)]]]
                 for k in range(len(order))]

    # 2. The cycle graph: an edge to every target of a node's effective entries.
    adj: list[list[int]] = [list(dict.fromkeys(vertex[id(t)] for _, _, hits in rows
                                               for t in hits or ()))
                            for rows in effective]
    in_cycle: set[int] = set()
    cycles = []
    for component in _strong_components(adj):
        if len(component) > 1 or component[0] in adj[component[0]]:
            members = sorted(component)
            in_cycle.update(members)
            cycles.append(members)
    for members in sorted(cycles):
        home = order[members[0]][0]
        labels = []
        for k in members:
            name, n = order[k]
            prefix = "" if name == home else f"{name}:"
            labels.append(f"{prefix}{n['issue']} (line {n['source_line']})")
        findings.append((home, order[members[0]][1]["source_line"], "dep_cycle",
                         "dependency cycle: " + ", ".join(labels)))

    # 3. Each leaf's readiness and whether it leans on a parent row.
    ready: dict[str, bool] = {}
    via_parent_row: dict[str, bool] = {}
    pending_under: dict[int, list[int]] = {}
    for k, (name, n) in enumerate(order):
        if not n["leaf"]:
            continue
        lineage, rows = lineages[k], effective[k]
        ok = (n["state"] == "pending"
              and not any(a["state"] in BLOCKING_ANCESTOR for a in lineage)
              and all(hits and all(t["state"] == "done" for t in hits) for _, _, hits in rows)
              and k not in in_cycle)
        if n["id"] not in ambiguous:
            ready[n["id"]] = bool(ok)
            via_parent_row[n["id"]] = any(not t["leaf"] for _, _, hits in rows
                                          for t in hits or ())
        if n["state"] == "pending":
            for a in lineage:
                if a["state"] == "done":
                    pending_under.setdefault(id(a), []).append(n["source_line"])

    # 4. A node marked done with pending leaves under it.
    for name, n in order:
        lines = pending_under.get(id(n))
        if lines:
            findings.append((name, n["source_line"], "parent_done_leaf_pending",
                             "parent is marked done but leaves under it are pending: "
                             + _line_list(lines)))
    return Readiness(resolved, ready, via_parent_row, findings)


def _readiness_fields(r: Readiness, n: dict) -> tuple[list, dict]:
    """Node n's values under r: each entry's `resolved`, and its own fields (null on a parent)."""
    resolved = [r.resolved.get((n["id"], i)) for i in range(len(n["depends_on"]))]
    leaf = n["leaf"]
    return resolved, {"ready": r.ready.get(n["id"]) if leaf else None,
                      "ready_via_parent_row": r.via_parent_row.get(n["id"]) if leaf else None}


def apply_readiness(projects: list[dict], report_for) -> None:
    """Fill `resolved`, `ready` and `ready_via_parent_row`, and report the findings."""
    r = compute_readiness(projects)
    for p in projects:
        for n in p["nodes"]:
            resolved, fields = _readiness_fields(r, n)
            for d, value in zip(n["depends_on"], resolved):
                d["resolved"] = value
            n.update(fields)
    for project, line, kind, message in r.findings:
        report_for(project)(line, kind, message)


_FIELD_BREAK_RE = re.compile(r"[\t\r\n]")


def _field(value: str) -> str:
    """A TSV field: a TAB, CR or LF inside it becomes one space."""
    return _FIELD_BREAK_RE.sub(" ", value)


def ready_lines(doc: dict) -> list[str]:
    """One `project<TAB>issue<TAB>est<TAB>text` line per ready leaf.

    Projects in document (config) order, then nodes by source_line. `issue`
    is empty when the leaf has none; `est` is `est.raw` as written (a list
    joined with `, `), empty when absent, never 0.
    """
    out = []
    for p in doc["projects"]:
        for n in p["nodes"]:
            if not (n["leaf"] and n["ready"] is True):
                continue
            raw = n["est"]["raw"]
            est = ", ".join(raw) if isinstance(raw, list) else (raw or "")
            out.append("\t".join(_field(f) for f in (p["project"], n["issue"] or "", est,
                                                    n["text"])))
    return out


# --- build the document --------------------------------------------------------

@dataclass(frozen=True)
class ProjectInput:
    """One configured project, as config.sh resolves it (None: not configured)."""
    name: str
    devdoc: str | None
    source: str | None = None
    worktree: str | None = None


SCHEMA_VERSION = "1.1"

REASON_UNSET = "no devdoc dir is configured"
REASON_EMPTY = "devdoc_dir is set but empty"
REASON_ABSENT = "the devdoc dir does not exist"
REASON_NOT_DIR = "the devdoc dir is not a directory"
REASON_NO_WBS = "the devdoc dir has no WBS.md"
REASON_NOT_FILE = "WBS.md is not a regular file"
REASON_UNREADABLE = "WBS.md could not be read: {}"
REASON_DEVDOC_UNREADABLE = "the devdoc dir could not be read: {}"

# The parse_report vocabulary (#725 leaves it open to #726), in report order.
# docs/portfolio-schema.md "Report kinds (#726)" lists the same table.
KINDS: tuple[str, ...] = (
    "leaf_no_issue",
    "issue_not_id",
    "dep_unresolved",
    "dep_skipped",
    "dep_cycle",
    "parent_done_leaf_pending",
    "duplicate_issue",
    "est_unparseable",
    "est_src_invalid",
    "h_malformed",
    "issue_malformed",
    "unknown_meta_key",
    wbs_parser.META_UNREADABLE,
    wbs_parser.META_DUPLICATE_KEY,
    "near_miss_line",
    "parser_warning",
    "directive_warning",
    "checklist_unreadable",
    "stuck_unreadable",
)
_KIND_INDEX = {k: i for i, k in enumerate(KINDS)}
_LINE_RE = re.compile(r"\bline ([0-9]+)\b")
SCOPE_NEAR_MISS = ("line {}: not a scope line (want '<!-- " + wbs_parser.SCOPE_KEY
                   + " <range> -->' on one line); ignored")


def _show(v) -> str:
    return json.dumps(v, ensure_ascii=False)


def _empty_project(name: str, status: str, reason: str) -> dict:
    return {"project": name, "status": status, "status_reason": reason,
            "wbs_title": None, "nodes": [], "issues": [], "rollup": None}


def _probe(path, follow: bool = True):
    """os.stat (or lstat) of `path`; None when it does not exist; the OSError otherwise.

    pathlib's is_dir/is_file re-raise EACCES and os.path.lexists swallows it;
    neither may decide a status, so a permission error stays visible here.
    """
    try:
        return os.stat(path) if follow else os.lstat(path)
    except (FileNotFoundError, NotADirectoryError):
        return None
    except OSError as e:
        return e


def _read_wbs(devdoc: str | None) -> tuple[str, str | None, str | None]:
    """(status, reason, text): the project's WBS.md, or why it was not read."""
    if devdoc is None:
        return "no_devdoc_dir", REASON_UNSET, None
    if devdoc == "":
        return "no_devdoc_dir", REASON_EMPTY, None
    root = Path(devdoc)
    st = _probe(root)
    if isinstance(st, OSError):
        return "unreadable", REASON_DEVDOC_UNREADABLE.format(_err_detail(st)), None
    if st is None:
        return "no_devdoc_dir", REASON_ABSENT, None
    if not stat.S_ISDIR(st.st_mode):
        return "no_devdoc_dir", REASON_NOT_DIR, None
    wbs = root / "WBS.md"
    st = _probe(wbs, follow=False)
    if isinstance(st, OSError):
        return "unreadable", REASON_UNREADABLE.format(_err_detail(st)), None
    if st is None:
        return "no_wbs", REASON_NO_WBS, None
    st = _probe(wbs)
    if isinstance(st, OSError):
        return "unreadable", REASON_UNREADABLE.format(_err_detail(st)), None
    if st is None or not stat.S_ISREG(st.st_mode):
        return "unreadable", REASON_NOT_FILE, None
    try:
        # newline="" keeps CR bytes, as wbs_parser.parse_file reads.
        with open(wbs, encoding="utf-8", newline="") as f:
            return "read", None, f.read()
    except (OSError, UnicodeDecodeError) as e:
        return "unreadable", REASON_UNREADABLE.format(_err_detail(e)), None


def _preorder(tree: dict):
    """(node, parent node or None), parents first, in source order."""
    stack = [(n, None) for n in reversed(tree["children"])]
    while stack:
        node, parent = stack.pop()
        yield node, parent
        stack.extend((c, node) for c in reversed(node["children"]))


def _issue_entry(issue: str, node_ids: list[str], devdoc: Path, report) -> dict:
    entry = {"issue": issue, "nodes": node_ids, "stuck": None, "checklist": "absent",
             "next_step": None, "next_step_number": None}
    issue_dir = devdoc / issue
    # Only an id-shaped value names a dir, so nothing traverses out of devdoc.
    if not wbs_parser.ID_TOKEN_RE.fullmatch(issue):
        return entry
    st = _probe(issue_dir)
    if isinstance(st, OSError):
        # Neither file can be probed: both are unknown, not absent.
        entry["stuck"] = dict.fromkeys(k for k, _ in STUCK_KEYS)
        report(None, "checklist_unreadable", f"{issue}/ could not be read: {_err_detail(st)}")
        report(None, "stuck_unreadable", f"{issue}/ could not be read: {_err_detail(st)}")
        return entry
    if st is None or not stat.S_ISDIR(st.st_mode):
        return entry
    checklist = issue_dir / "checklist.md"
    st = _probe(checklist, follow=False)
    if isinstance(st, OSError):
        report(None, "checklist_unreadable",
               f"{issue}/checklist.md could not be read: {_err_detail(st)}")
    elif st is not None:
        try:
            state, number, name = checklist_next(checklist)
        except ChecklistError as e:
            report(None, "checklist_unreadable", f"{issue}/checklist.md could not be read: {e}")
        else:
            entry.update({"checklist": state, "next_step": name, "next_step_number": number})
    stuck = issue_dir / "STUCK"
    st = _probe(stuck, follow=False)
    if isinstance(st, OSError):
        entry["stuck"] = {"step": None, "reason": None, "since": None}
        report(None, "stuck_unreadable", f"{issue}/STUCK could not be read: {_err_detail(st)}")
    elif st is not None:
        try:
            entry["stuck"] = read_stuck(stuck)
        except StuckError as e:
            entry["stuck"] = {"step": None, "reason": None, "since": None}
            report(None, "stuck_unreadable", f"{issue}/STUCK could not be read: {e}")
    return entry


def _build_read_project(name: str, devdoc: Path, text: str, next_id, report) -> dict:
    captured = io.StringIO()
    with contextlib.redirect_stderr(captured):
        tree = wbs_parser.parse_text(text)
    for line in captured.getvalue().splitlines():
        m = _LINE_RE.search(line)
        report(int(m.group(1)) if m else None, "parser_warning", line)
    for w in tree["exclusion_warnings"]:
        report(wbs_parser.warning_line(w), "directive_warning", w)
    for ln, value in tree["scopes"]:
        if value is None:
            report(ln, "directive_warning", SCOPE_NEAR_MISS.format(ln))
    diag = wbs_parser.diagnose_text(text)
    for ln, body in diag["near_misses"]:
        report(ln, "near_miss_line", f"looks like a node but is not one: {body.strip()}")
    for ln, code, message in diag["meta_problems"]:
        report(ln, code, message)

    nodes: list[dict] = []
    ids: dict[int, str] = {}
    carriers: dict[str, list[dict]] = {}
    for raw, parent in _preorder(tree):
        nid = next_id()
        ids[id(raw)] = nid
        meta, ln = raw["meta"], raw["source_line"]
        issue, issue_bad = node_issue(meta)
        src, src_bad = est_src(meta)
        h, h_bad = read_h(meta)
        est = classify_est(meta.get("est"))
        est["src"] = src
        leaf = not raw["children"]
        node = {
            "id": nid, "parent": None if parent is None else ids[id(parent)],
            "depth": raw["depth"], "leaf": leaf, "text": raw["text"],
            "state": raw["state"], "glyph": raw["glyph"], "source_line": ln,
            "issue": issue, "meta": meta, "meta_unknown_keys": raw["meta_unknown_keys"],
            "est": est, "satisfies": as_list(meta.get("satisfies")), "h": h,
            "depends_on": node_deps(meta, name), "ready": None,
            "ready_via_parent_row": None,
        }
        nodes.append(node)
        if leaf and not issue_bad and issue is None:
            report(ln, "leaf_no_issue", f"leaf '{raw['text']}' has no issue")
        if issue_bad:
            report(ln, "issue_malformed",
                   f"issue {_show(meta['issue'])} is not a string; the node carries no issue")
        if issue is not None:
            if not wbs_parser.ID_TOKEN_RE.fullmatch(issue):
                report(ln, "issue_not_id",
                       f"issue '{issue}' is not an issue id; its issue dir is not read")
            if issue in carriers:
                report(ln, "duplicate_issue",
                       f"issue '{issue}' also appears at line {carriers[issue][0]['source_line']}")
            carriers.setdefault(issue, []).append(node)
        if est["class"] == "unparseable":
            report(ln, "est_unparseable",
                   f"est {_show(est['raw'])} is not a time, non-time or placeholder estimate")
        if src_bad:
            report(ln, "est_src_invalid",
                   f"est_src {_show(meta['est_src'])} is not confirmed or derived; est.src reads as null")
        if h_bad:
            report(ln, "h_malformed", f"h {_show(meta['h'])} is not one digit 0-4; h reads as null")
        for key in raw["meta_unknown_keys"]:
            if key not in PRODUCER_KEYS:
                report(ln, "unknown_meta_key", f"unknown metadata key '{key}'")

    issues = [_issue_entry(i, [n["id"] for n in carriers[i]], devdoc, report) for i in carriers]
    return {"project": name, "status": "read", "status_reason": None,
            "wbs_title": tree["title"], "nodes": nodes, "issues": issues,
            "rollup": rollup(nodes)}


def build_document(projects: list[ProjectInput], generated_at: str) -> dict:
    """The portfolio document over `projects`, in config order. Reads only."""
    counter = iter(range(1, sys.maxsize))
    next_id = lambda: f"n{next(counter)}"  # noqa: E731
    entries: list[dict] = []

    def report_for(project: str):
        def report(line: int | None, kind: str, message: str) -> None:
            entries.append({"project": project, "source_line": line, "kind": kind,
                            "message": message})
        return report

    out: list[dict] = []
    for p in projects:
        status, reason, text = _read_wbs(p.devdoc)
        if status != "read":
            out.append(_empty_project(p.name, status, reason))
            continue
        out.append(_build_read_project(p.name, Path(p.devdoc), text, next_id,
                                       report_for(p.name)))
    apply_readiness(out, report_for)
    order = {p.name: i for i, p in enumerate(projects)}
    entries.sort(key=lambda r: (order[r["project"]],
                                -1 if r["source_line"] is None else r["source_line"],
                                _KIND_INDEX.get(r["kind"], len(KINDS)), r["message"]))
    return {"schema": pc.PORTFOLIO_ID, "schema_version": SCHEMA_VERSION,
            "generated_at": generated_at, "projects": out, "parse_report": entries}


# --- write path and CLI --------------------------------------------------------

# One exit map (commands/portfolio.md copies it; a test holds them equal).
EXIT_OK = 0          # written (or printed, under `ready`)
EXIT_CONFIG = 1      # config missing or invalid (raised by portfolio.sh)
EXIT_USAGE = 2       # usage error, refused path, or unwritable path
EXIT_SELF_CHECK = 3  # self-check failed; nothing written

RAIL_ROLES = ("devdoc_dir", "source_dir", "worktree_root")
RAIL_MSG = ("portfolio: refusing to write under the {role} of project '{name}' ({path}); "
            "choose an --out outside every devdoc_dir, source_dir and worktree_root")


class ManifestError(Exception):
    """The PORTFOLIO_* environment is missing or malformed."""


def read_manifest(env=None) -> list[ProjectInput]:
    """The projects portfolio.sh exported, in config order (D3)."""
    env = os.environ if env is None else env
    count = env.get("PORTFOLIO_PROJECT_COUNT", "")
    if not count.isdigit():
        raise ManifestError(f"PORTFOLIO_PROJECT_COUNT is {count!r}, not a count")
    out = []
    for i in range(int(count)):
        name = env.get(f"PORTFOLIO_NAME_{i}")
        if not name:
            raise ManifestError(f"PORTFOLIO_NAME_{i} is not set")
        out.append(ProjectInput(name, env.get(f"PORTFOLIO_DEVDOC_{i}"),
                                env.get(f"PORTFOLIO_SOURCE_{i}"),
                                env.get(f"PORTFOLIO_WORKTREE_{i}")))
    return out


def _canon(path) -> str:
    return os.path.normcase(os.path.realpath(path))


def _is_under(path, root) -> bool:
    p, r = _canon(path), _canon(root)
    try:
        if os.path.commonpath([p, r]) == r:
            return True
    except ValueError:
        # Different drives (Windows) cannot nest by spelling.
        pass
    # By identity: a second spelling of an existing root (a case variant on a
    # case-insensitive mount whose normcase is the identity, such as WSL /mnt/c
    # or APFS; a bind mount) names the same directory as one of out's ancestors.
    if not os.path.isdir(r):
        return False
    a = os.path.realpath(path)
    while True:
        try:
            if os.path.samefile(a, r):
                return True
        except OSError:
            pass
        parent = os.path.dirname(a)
        if parent == a:
            return False
        a = parent


def rail(projects: list[ProjectInput], out) -> str | None:
    """The refusal when `out` lies under a configured devdoc, source or worktree (D10).

    cleanup stages and pushes everything under a devdoc_dir, and the document
    names private projects, so it must never land in one. Non-strict realpath
    on both sides: an absent configured dir is still railed by its path.
    """
    for p in projects:
        for role, path in zip(RAIL_ROLES, (p.devdoc, p.source, p.worktree)):
            if path and _is_under(out, path):
                return RAIL_MSG.format(role=role, name=p.name, path=path)
    return None


def dumps(doc: dict) -> bytes:
    """The document as UTF-8 with LF line ends; NaN and Infinity refused."""
    text = json.dumps(doc, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    return text.encode("utf-8")


def write_document(data: bytes, out) -> None:
    """Write `data` to `out` owner-only: new dirs 0700, the file 0600, atomically."""
    out = Path(out)
    missing = []
    parent = out.parent
    while not parent.exists():
        if parent.parent == parent:
            # A root that does not exist (an unmounted drive letter) is its own parent.
            raise FileNotFoundError(errno.ENOENT, "no such root", str(parent))
        missing.append(parent)
        parent = parent.parent
    for d in reversed(missing):
        # One level at a time: mkdir(parents=True) applies the mode to the leaf only.
        d.mkdir(mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=out.parent, prefix=f".{out.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o600)
        os.replace(tmp, out)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _usage(problem: str | None = None) -> int:
    if problem:
        sys.stderr.write(f"portfolio: {problem}\n")
    sys.stderr.write(USAGE + "\n")
    return EXIT_USAGE


def _self_check(doc: dict) -> int | None:
    """EXIT_SELF_CHECK after printing why, or None when the document passes."""
    errors = pc.check(doc)
    if not errors:
        errors = invariant_violations(doc)
    if not errors:
        return None
    for e in errors:
        sys.stderr.write(f"portfolio: self-check: {e}\n")
    return EXIT_SELF_CHECK


def _checked_document(projects) -> tuple[dict, int | None]:
    """Build the document as of now and self-check it: (doc, None) or (doc, exit code)."""
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = build_document(projects, generated_at)
    return doc, _self_check(doc)


NOT_READ_MSG = "portfolio: {project}: not read ({status}); its leaves are not listed"


def _ready_view() -> int:
    """`portfolio.py ready`: print the ready leaves; write nothing."""
    try:
        projects = read_manifest()
    except ManifestError as e:
        return _usage(str(e))
    doc, failed = _checked_document(projects)
    if failed is not None:
        return failed
    for p in doc["projects"]:
        if p["status"] != "read":
            sys.stderr.write(NOT_READ_MSG.format(project=p["project"], status=p["status"]) + "\n")
    sys.stderr.flush()
    # Bytes, not text mode: Windows text-mode stdout would end lines CRLF and
    # encode with the console code page (mr-link.py's emit does the same).
    data = "".join(line + "\n" for line in ready_lines(doc)).encode("utf-8")
    try:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        # The reader stopped early (`| head -1`): not an error. Point stdout at
        # devnull so the interpreter's exit flush cannot raise again.
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
    return EXIT_OK


def main(argv: list[str]) -> int:
    if argv[:1] in (["-h"], ["--help"]):
        sys.stdout.write(USAGE + "\n")
        return EXIT_OK
    if argv == ["ready"]:
        return _ready_view()
    if len(argv) != 3 or argv[0] != "build" or argv[1] != "--out" or not argv[2]:
        return _usage()
    out = Path(argv[2])
    try:
        projects = read_manifest()
    except ManifestError as e:
        return _usage(str(e))
    refusal = rail(projects, out)
    if refusal:
        sys.stderr.write(refusal + "\n")
        return EXIT_USAGE
    doc, failed = _checked_document(projects)
    if failed is not None:
        return failed
    try:
        write_document(dumps(doc), out)
    except OSError as e:
        sys.stderr.write(f"portfolio: cannot write {out}: {e}\n")
        return EXIT_USAGE
    sys.stdout.write(f"portfolio: wrote {out} ({len(doc['projects'])} projects, "
                     f"{len(doc['parse_report'])} report entries)\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
