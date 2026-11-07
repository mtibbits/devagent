#!/usr/bin/env python3
"""portfolio.py — #726. Build the portfolio document (schema v1.0, #725) over
every configured project's WBS.md, with a parse report that drops nothing
silently, and write it only when it passes both the structural checker
(portfolio-check.py) and this module's own cross-field invariants I1–I15.

    portfolio.py build --out PATH

The project manifest arrives as indexed environment variables, set by
scripts/portfolio.sh from config.toml (this module reads no TOML):
PORTFOLIO_PROJECT_COUNT, and per project i (0-based) PORTFOLIO_NAME_<i>,
PORTFOLIO_DEVDOC_<i>, PORTFOLIO_SOURCE_<i> and PORTFOLIO_WORKTREE_<i>, each
path variable set only when configured (it may be empty).

Standard library only (3.10+), like portfolio-check.py. docs/portfolio-schema.md
is the contract; commands/portfolio.md is the user doc.
"""
from __future__ import annotations

import importlib.util
import math
import re
import sys
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

USAGE = "usage: portfolio.py build --out PATH"

# --- per-node derivations ------------------------------------------------------

# Interim estimate classifier (D16), built from #737's drafted table. The
# factors are WORKING-time hours and provisional: #737's helper replaces this
# classifier when it lands. Every match is a fullmatch on the value as written.
HOUR_FACTORS: dict[str, int] = {"h": 1, "d": 8, "w": 40}
PLACEHOLDER_RE = re.compile(r"\?[A-Za-z]*")
# Digit caps keep every number finite and small: no inf or huge-int path.
QUANTITY_RE = re.compile(r"(?P<q>[0-9]{1,9}(?:\.[0-9]{1,6})?)(?P<u>[A-Za-z]+)")
H_RE = re.compile(r"[0-4]")
EST_SRC_VALUES = ("confirmed", "derived")
# Keys this producer consumes. The parser does not know them yet (#888), so
# they sit in `meta_unknown_keys`; the unknown-key report skips them.
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
    if "h" not in meta:
        return None, False
    v = meta["h"]
    if isinstance(v, str) and H_RE.fullmatch(v):
        return int(v), False
    return None, True


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
    if not v:
        return []
    return v if isinstance(v, list) else [v]


def split_dep(raw: str, project: str) -> dict:
    """One `depends_on` entry by #887's split rule (schema doc, Dependency split)."""
    left, sep, right = raw.partition(":")
    if (sep and ":" not in right and wbs_parser.ID_TOKEN_RE.fullmatch(left)
            and wbs_parser.ID_TOKEN_RE.fullmatch(right)):
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
DONE_GLYPHS = frozenset({"x", "-"})


class ChecklistError(Exception):
    """A present checklist.md that cannot be read, or has no step rows in scope."""


class StuckError(Exception):
    """A present STUCK file that cannot be read."""


def _read_lines(path, error) -> list[str]:
    try:
        text = Path(path).read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise error(f"{path}: {type(e).__name__}: {e}") from e
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
        raise ChecklistError(f"{path}: no step rows in the active revision block")
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
        for c in (by_state[node["state"]],) + (
                (remaining,) if node["state"] not in NOT_REMAINING else ()):
            c["leaves"] += 1
            c[bucket] += 1
        if node["state"] in NOT_REMAINING:
            continue
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


# --- invariants I1–I15 ---------------------------------------------------------

INVARIANTS: tuple[str, ...] = tuple(f"I{i}" for i in range(1, 16))


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
    want_issue = meta.get("issue") if isinstance(meta.get("issue"), str) and meta.get("issue") else None
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
    if est["src"] != est_src(meta)[0]:
        add("I7", f"node {nid}: est.src {est['src']!r} != {est_src(meta)[0]!r}")
    if node["satisfies"] != as_list(meta.get("satisfies")):
        add("I8", f"node {nid}: satisfies {node['satisfies']!r} != meta.satisfies as a list")
    if node["h"] != read_h(meta)[0]:
        add("I9", f"node {nid}: h {node['h']!r} != {read_h(meta)[0]!r}")
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

    Each entry is `"I<n>: <message>"`. Reads known v1.0 fields only, so a
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
    return out


# --- CLI -----------------------------------------------------------------------

def main(argv: list[str]) -> int:
    if argv[:1] in (["-h"], ["--help"]):
        sys.stdout.write(USAGE + "\n")
        return 0
    sys.stderr.write(USAGE + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
