#!/usr/bin/env python3
"""Issue milestones (#734): one row per dated event of each issue in scope,
from the tracker's `issue-list`, the code host's `issue-mrs` and the local
`checklist.md` logs, plus per-issue spans (spec section 13.5).

Python never starts a backend: `scripts/milestones.sh` reads config, runs
the trust check and makes every backend call, and this library does the
rest in three passes (the keys/apply split of `wbs-update.sh`):

  milestones.py resolve <devdoc> <issue-id>
        exit 0 when the id names a configured source or a checklist dir,
        else exit 2 with `milestones: <why>` on stderr.
  milestones.py keys <devdoc> <scope> [<issue-id>]
        print `S<TAB>repo<TAB>id` per id that needs an MR lookup.
  milestones.py emit <devdoc> <project> <scope> [<issue-id>] [--json]
        print the report.

Sources, statuses and backend output arrive in `MS_*` environment
variables (the manifest `milestones.sh` writes; see `_manifest`).

The checklist log parser here is the third reader of `scripts/lib/log.sh`'s
`- YYYY-MM-DD HH:MM  <step>: <msg>` lines; `statusreport-detect.py`
(`_LOG_RE`, which drops names holding `-`, a space or `+`, and assumes UTC)
and `history.sh` (which cuts the name at the first colon) disagree with it
at the edges. Unifying them is deferred (#734 future enhancements).
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


imp = _load("wbs_import", HERE / "wbs-import.py")
trk = imp.trk
mrl = _load("mr_link", HERE / "mr-link.py")

# --- checklist log rows --------------------------------------------------------

CREATED_RE = re.compile(
    r"^Created: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})"
    r"(Z|[+-][0-9]{2}:[0-9]{2})?[ \t]*$")
LOG_RE = re.compile(r"^- ([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}) +([^:\s][^:]*?): ?(.*)$")
DATED_RE = re.compile(r"^- ([0-9]{4}-[0-9]{2}-[0-9]{2})(?: |$)")
# A retier IS a revision start (scripts/revise.sh logs
# `retier: <from> → <to> (revision N)`); `revise: Revision 2 opened
# MANUALLY…` and other revise lines are not.
REVISE_RE = re.compile(r"^(?:revision ([0-9]+) started\b|retier: .*\(revision ([0-9]+)\)\s*$)")
REV_HEADING_RE = re.compile(r"^## Revision ([0-9]+)(?:\s|$)")  # a suffix may follow (volk)


def _lines(path: Path) -> list[str]:
    return [l.rstrip("\r") for l in path.read_bytes().decode("utf-8", "replace").split("\n")]


def _fmt_set(ns) -> str:
    return "{" + ", ".join(str(n) for n in sorted(ns)) + "}"


def _readable(at: str, rel: str, n: int, shown: str, warnings: list[str]) -> bool:
    """Whether a log line's time is a real one; an unreadable one (a
    hand-typed `2026-02-30`, `24:00`) is a warning and the line is skipped,
    so one typo never sinks the report."""
    try:
        utc_instant(at)
    except ValueError:
        warnings.append(f"{rel}:{n}: unreadable time '{shown}'; line skipped")
        return False
    return True


def checklist_rows(path: Path, rel: str, project: str, issue: str) -> tuple[list[dict], list[str]]:
    """The rows of one checklist's `## Log`, and its start-count warnings.

    Classification, first match wins, per dated `## Log` line in file order:
    a `revise` line matching REVISE_RE is `revision_started` and SETS the
    current revision (a repeated start for the same N changes nothing);
    `park` is `parked`; `resume` is `resumed`; a step-row name is
    `step_done` the first time in its revision, else `step_note`; any other
    LOG_RE line is `log` (name kept); a DATED_RE line that is not LOG_RE is
    `log` with name `-` and a date-only `at`.
    """
    lines = _lines(path)
    offset = None
    for line in lines:
        m = CREATED_RE.match(line)
        if m:
            offset = m.group(2)
            break
    tz = "assumed" if offset else "unknown"
    suffix = offset or ""
    step_rows = {m.group("name") for m in map(trk.ROW_RE.match, lines) if m}
    headings = {int(m.group(1)) for m in map(REV_HEADING_RE.match, lines) if m}

    rows: list[dict] = []
    warnings: list[str] = []
    revision = 1
    started = {1}
    seen: set[tuple[int, str]] = set()
    in_log = False
    for n, line in enumerate(lines, start=1):
        if line.startswith("## "):
            in_log = line.startswith("## Log")
            continue
        if not in_log:
            continue
        base = {"project": project, "issue": issue, "source": f"{rel}:{n}", "tz": tz}
        m = LOG_RE.match(line)
        if not m:
            d = DATED_RE.match(line)
            if d and _readable(d.group(1), rel, n, d.group(1), warnings):
                rows.append({**base, "event": "log", "at": d.group(1), "name": "-",
                             "revision": revision})
            continue
        date, hhmm, name, msg = m.groups()
        at = f"{date}T{hhmm}{suffix}"
        if not _readable(at, rel, n, f"{date} {hhmm}", warnings):
            continue
        rv = REVISE_RE.match(msg) if name == "revise" else None
        if rv:
            revision = int(rv.group(1) or rv.group(2))
            started.add(revision)
            rows.append({**base, "event": "revision_started", "at": at, "revision": revision})
        elif name == "park":
            rows.append({**base, "event": "parked", "at": at, "revision": revision})
        elif name == "resume":
            rows.append({**base, "event": "resumed", "at": at, "revision": revision})
        elif name in step_rows:
            event = "step_note" if (revision, name) in seen else "step_done"
            seen.add((revision, name))
            rows.append({**base, "event": event, "at": at, "step": name, "revision": revision})
        else:
            rows.append({**base, "event": "log", "at": at, "name": name, "revision": revision})
    if started != headings:
        warnings.append(f"{rel}: revision starts logged {_fmt_set(started)} "
                        f"but ## Revision headings {_fmt_set(headings)}")
    return rows, warnings


# --- tracker and MR rows -------------------------------------------------------

def tracker_rows(rec: dict, leaf: str, project: str) -> list[dict]:
    """`opened` (at = created) and, when closed, `closed` (at = closed,
    reason = the issue-list class) for one issue-list record."""
    base = {"project": project, "issue": leaf, "source": rec["url"]}
    rows = [{**base, "event": "opened", "at": rec["created"]}]
    if rec["state"] == "closed":
        rows.append({**base, "event": "closed", "at": rec["closed"], "reason": rec["class"]})
    return rows


def mr_rows(mrs: list[dict], leaf: str, project: str) -> list[dict]:
    """One `mr_opened` per MR and an `mr_merged` when it merged; the source
    is the MR's URL, or its ref when the backend gave none."""
    rows = []
    for mr in mrs:
        base = {"project": project, "issue": leaf, "source": mr["url"] or mr["ref"],
                "mr": mr["ref"], "base": mr["base"]}
        rows.append({**base, "event": "mr_opened", "at": mr["created"]})
        if mr["merged"] is not None:
            rows.append({**base, "event": "mr_merged", "at": mr["merged"]})
    return rows


# --- scope ----------------------------------------------------------------------

SRC_RANK = {"ORIGIN": 0, "FORK": 1}
_TAIL_NUM = re.compile(r"([0-9]+)$")


def _hit(sources, leaf):
    """(src, rid, key) for a leaf; all None when it names no configured source."""
    hit = trk.parse_leaf(sources, leaf)
    return (hit[0], hit[1], (hit[0]["S"], hit[1])) if hit else (None, None, None)


def scope_issues(mode: str, sources: list[dict], records: list[tuple[dict, dict]],
                 devdoc: Path, issue: str | None = None) -> list[dict]:
    """The issues in scope, each {"label", "src", "rid", "record", "dir"}.

    `default` is every checklist dir plus every open record; `all` is every
    record plus every checklist dir; `issue` is the one id. A dir and a
    record that name one issue (wbs-tracker.py parse_leaf, so a Jira dir
    `Issue-PROJ-12` and record PROJ-12 meet) are one issue labelled with the
    record's leaf_for form; a dir that matches no record keeps its name, and
    a dir that names no configured source has no src (checklist rows only).
    """
    by_key: dict = {}
    out: list[dict] = []

    def entity(key, src, rid, label):
        if key is not None and key in by_key:
            return by_key[key]
        e = {"label": label, "src": src, "rid": rid, "record": None, "dir": None}
        out.append(e)
        if key is not None:
            by_key[key] = e
        return e

    for src, rec in records:
        leaf = trk.leaf_for(src, rec["id"])
        key = _hit(sources, leaf)[2] or (src["S"], rec["id"])
        e = entity(key, src, key[1], leaf)
        e["record"], e["label"] = rec, leaf
    dirs = sorted(p.parent.name for p in devdoc.glob("*/checklist.md")) if devdoc.is_dir() else []
    for name in dirs:
        src, rid, key = _hit(sources, name)
        entity(key, src, rid, name)["dir"] = name

    if mode == "issue":
        src, rid, want = _hit(sources, issue)
        pick = [e for e in out if e["label"] == issue or e["dir"] == issue
                or (want is not None and by_key.get(want) is e)]
        out = pick[:1] or [entity(want, src, rid, issue)]
    elif mode == "default":
        out = [e for e in out if e["dir"] is not None
               or (e["record"] is not None and e["record"]["state"] == "open")]

    def order(e):
        rank = SRC_RANK.get(e["src"]["S"], 2) if e["src"] else 2
        m = _TAIL_NUM.search(e["rid"] or "")
        return (rank, int(m.group(1)) if m else float("inf"), e["label"])
    return sorted(out, key=order)


def mr_eligible(src: dict | None, code_backend: str) -> bool:
    """Issue-side discovery only sees MRs on the issue's own host (the
    wbs-update.sh rule; the issue-list status is not consulted)."""
    return (src is not None and src["backend"] in ("github", "gitlab")
            and src["backend"] == code_backend)


def mr_keys(issues: list[dict], code_backend: str) -> list[tuple[str, str, str]]:
    """(S, repo, id) per in-scope numeric id an MR lookup needs, ORIGIN
    first, ids ascending."""
    per: dict = {}
    for e in issues:
        if mr_eligible(e["src"], code_backend) and trk.DIGITS_RE.fullmatch(e["rid"] or ""):
            per.setdefault(e["src"]["S"], (e["src"]["REPO"], set()))[1].add(e["rid"])
    return [(S, repo, i) for S in sorted(per, key=lambda s: SRC_RANK.get(s, 2))
            for repo, ids in [per[S]] for i in sorted(ids, key=int)]


def issue_rows(e: dict, devdoc: Path, project: str, mr_details: dict) -> tuple[list[dict], list[str]]:
    """One issue's rows, sorted, and its checklist warnings."""
    rows: list[dict] = []
    warnings: list[str] = []
    if e["record"] is not None:
        rows += tracker_rows(e["record"], e["label"], project)
    if e["src"] is not None and (e["src"]["S"], e["rid"]) in mr_details:
        rows += mr_rows(mr_details[(e["src"]["S"], e["rid"])], e["label"], project)
    if e["dir"] is not None:
        crow, warnings = checklist_rows(devdoc / e["dir"] / "checklist.md",
                                        f"{e['dir']}/checklist.md", project, e["label"])
        rows += crow
    return sort_rows(rows), warnings


# --- time, ordering, spans ------------------------------------------------------

_AT_RE = re.compile(r"^([0-9]{4}-[0-9]{2}-[0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?)?"
                    r"(Z|[+-][0-9]{2}:[0-9]{2})?$")


def utc_instant(at: str) -> datetime:
    """An `at` as a naive UTC datetime: a date-only `at` is 00:00Z and an
    `at` with no offset (tz unknown) is read as UTC."""
    m = _AT_RE.match(at)
    if not m:
        raise ValueError(f"bad time {at!r}")
    date, hh, mm, ss, off = m.groups()
    try:
        dt = datetime.strptime(f"{date} {hh or '00'}:{mm or '00'}:{ss or '00'}", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        raise ValueError(f"bad time {at!r}") from None
    if off and off != "Z":
        delta = timedelta(hours=int(off[1:3]), minutes=int(off[4:6]))
        dt = dt - delta if off[0] == "+" else dt + delta
    return dt


def sort_rows(rows: list[dict]) -> list[dict]:
    """By UTC instant; ties keep input (source, then file/line) order."""
    return sorted(rows, key=lambda r: utc_instant(r["at"]))


def spans_line(label: str, rows: list[dict]) -> str:
    """`<issue>\\topened->merged <d>\\topened->closed <d>\\tfirst-step->closed
    <d>\\tparked <p>` over sorted rows (spec section 13.5)."""
    def first(event):
        hits = [utc_instant(r["at"]) for r in rows if r["event"] == event]
        return min(hits) if hits else None

    def days(a, b):
        return "-" if a is None or b is None else str((b.date() - a.date()).days)

    opened, closed = first("opened"), first("closed")
    parked_s, open_at = 0.0, None
    for r in rows:
        if r["event"] == "parked" and open_at is None:
            open_at = utc_instant(r["at"])
        elif r["event"] == "resumed" and open_at is not None:
            parked_s += (utc_instant(r["at"]) - open_at).total_seconds()
            open_at = None
    parked = f"{parked_s / 86400:.1f}d" + ("+open" if open_at is not None else "")
    return (f"{label}\topened->merged {days(opened, first('mr_merged'))}"
            f"\topened->closed {days(opened, closed)}"
            f"\tfirst-step->closed {days(first('step_done'), closed)}\tparked {parked}")


# --- rendering ------------------------------------------------------------------

ROW_KEYS = {
    "opened": (), "closed": ("reason",),
    "mr_opened": ("mr", "base"), "mr_merged": ("mr", "base"),
    "step_done": ("step", "revision", "tz"), "step_note": ("step", "revision", "tz"),
    "parked": ("revision", "tz"), "resumed": ("revision", "tz"),
    "revision_started": ("revision", "tz"),
    "log": ("name", "revision", "tz"),
}


def _detail(r: dict) -> str:
    ev = r["event"]
    if ev == "opened":
        return "-"
    if ev == "closed":
        return r["reason"]
    if ev in ("mr_opened", "mr_merged"):
        return f"{r['mr']} base={r['base'] or '-'}"
    tail = f"r{r['revision']} tz={r['tz']}"
    if ev in ("step_done", "step_note"):
        return f"{r['step']} {tail}"
    if ev == "log":
        return f"{r['name']} {tail}"
    return tail


def render_text(project: str, scope: str, missing, issues_rows) -> list[str]:
    out = [f"milestones: {project} scope: {scope}"]
    out += [f"missing: {s}: {d}" for s, d in missing]
    with_rows = [(label, rows) for label, rows in issues_rows if rows]
    if not with_rows:
        return out + ["(no rows)"]
    for label, rows in with_rows:
        out += [f"{label}\t{r['at']}\t{r['event']}\t{_detail(r)}\t{r['source']}" for r in rows]
    out.append("spans:")
    out += [spans_line(label, rows) for label, rows in with_rows]
    return out


def _json(doc: dict) -> str:
    return json.dumps(doc, ensure_ascii=False, separators=(",", ":"))


def render_json(project: str, scope: str, missing, issues_rows) -> list[str]:
    out = [_json({"kind": "header", "project": project, "scope": scope,
                  "missing": [{"source": s, "detail": d} for s, d in missing]})]
    for _, rows in issues_rows:
        for r in rows:
            doc = {"kind": "row", "project": r["project"], "issue": r["issue"],
                   "event": r["event"], "at": r["at"], "source": r["source"]}
            doc.update((k, r[k]) for k in ROW_KEYS[r["event"]])
            out.append(_json(doc))
    return out


# --- the manifest and the CLI ---------------------------------------------------
# milestones.sh hands every input over in MS_* variables (S = ORIGIN | FORK):
#   MS_TRK_<S>_BACKEND, _REPO, _PREFIX   the configured source (all three set,
#                                        else not configured)
#   MS_TRK_<S>_STATUS                    nolookup | ok | failed (after fetch)
#   MS_TRK_<S>_FILE, _DETAIL             issue-list stdout; why nolookup
#                                        (`no script`, `<cli> not on PATH`,
#                                        `exit 2|78`) or failed (`exit N: <line>`)
#   MS_MR_BACKEND                        code_source.backend ("" = none)
#   MS_MR_STATUS, MS_MR_DETAIL           nolookup (and why) | ready
#   MS_MR_<S>_RC, _FILE, _DETAIL         issue-mrs exit, stdout, last stderr
#                                        line (set only for a source called)

LABELS = {"ORIGIN": ("tracker", "mr"), "FORK": ("fork tracker", "fork mr")}


def sources_from_env(env) -> list[dict]:
    out = []
    for S in ("ORIGIN", "FORK"):
        f = {k: env.get(f"MS_TRK_{S}_{k}", "") for k in ("REPO", "STATUS", "FILE", "DETAIL")}
        backend, prefix = env.get(f"MS_TRK_{S}_BACKEND", ""), env.get(f"MS_TRK_{S}_PREFIX", "")
        if not (backend and f["REPO"] and prefix):
            continue
        out.append({**f, "S": S, "backend": backend, "prefix": prefix,
                    "keyprefix": trk.jira_keyprefix(env, f["REPO"]) if backend == "jira" else ""})
    return out


def _read(path: str) -> str:
    return Path(path).read_bytes().decode("utf-8", "replace")


def tracker_inputs(env, sources):
    """(records, missing, failed) from the issue-list results."""
    records, missing, failed = [], [], []
    configured = {s["S"] for s in sources}
    if "ORIGIN" not in configured:
        missing.append(("tracker", "not configured"))
    for src in sources:
        label = LABELS[src["S"]][0]
        st, b, repo, detail = src["STATUS"], src["backend"], src["REPO"], src["DETAIL"]
        if st == "nolookup":
            missing.append((label, f"{b} has no issue-list ({detail})"))
        elif st == "ok":
            try:
                records += [(src, rec) for rec in imp.parse_issue_list(_read(src["FILE"]))]
            except (OSError, ValueError) as e:
                failed.append((label, f"{b} {repo} issue-list failed ({e})"))
                missing.append(failed[-1])
        else:
            failed.append((label, f"{b} {repo} issue-list failed ({detail or 'not fetched'})"))
            missing.append(failed[-1])
    return records, missing, failed


def mr_inputs(env, sources, issues):
    """(mr_details, missing, failed) from the issue-mrs results."""
    cb = env.get("MS_MR_BACKEND", "")
    details: dict = {}
    missing, failed = [], []
    keys = mr_keys(issues, cb)
    for src in sources:
        S, label, b = src["S"], LABELS[src["S"]][1], src["backend"]
        if not cb:
            missing.append((label, "no code_source.backend"))
            continue
        if not mr_eligible(src, cb):
            missing.append((label, f"tracker backend {b} is not the code backend {cb}; MRs not read"))
            continue
        if env.get("MS_MR_STATUS", "") == "nolookup":
            missing.append((label, f"{cb} has no issue-mrs ({env.get('MS_MR_DETAIL', '')})"))
            continue
        rc = env.get(f"MS_MR_{S}_RC", "")
        if rc == "":
            continue  # no id of this source in scope: nothing asked
        if rc in ("2", "78"):
            missing.append((label, f"{cb} has no issue-mrs (exit {rc})"))
        elif rc != "0":
            last = env.get(f"MS_MR_{S}_DETAIL", "")
            f = (label, f"{cb} {src['REPO']} issue-mrs failed (exit {rc}: {last})")
            missing.append(f)
            failed.append(f)
        else:
            ids = [k for s, _, k in keys if s == S]
            try:
                _, mrs = mrl.parse_issue_mrs_detail(_read(env.get(f"MS_MR_{S}_FILE", "")), ids)
                for mr in (m for v in mrs.values() for m in v):
                    utc_instant(mr["created"])
                    if mr["merged"] is not None:
                        utc_instant(mr["merged"])
            except (OSError, ValueError) as e:
                f = (label, f"{cb} {src['REPO']} issue-mrs failed ({e})")
                missing.append(f)
                failed.append(f)
                continue
            details.update(((S, k), v) for k, v in mrs.items())
    return details, missing, failed


def _out(lines, stream) -> None:
    # bytes: Windows text-mode streams would end lines CRLF
    stream.buffer.write("".join(l + "\n" for l in lines).encode("utf-8"))
    stream.flush()


def main(argv: list[str], env=None) -> int:
    env = os.environ if env is None else env
    usage = ("usage: milestones.py resolve <devdoc> <issue-id>\n"
             "       milestones.py keys <devdoc> <scope> [<issue-id>]\n"
             "       milestones.py emit <devdoc> <project> <scope> [<issue-id>] [--json]")
    if len(argv) < 2 or argv[1] not in ("resolve", "keys", "emit"):
        print(usage, file=sys.stderr)
        return 2
    verb, rest = argv[1], argv[2:]
    as_json = "--json" in rest
    rest = [a for a in rest if a != "--json"]
    sources = sources_from_env(env)
    if verb == "resolve":
        devdoc, iid = Path(rest[0]), rest[1]
        if trk.parse_leaf(sources, iid) is None and not (devdoc / iid / "checklist.md").is_file():
            print(f"milestones: --issue {iid} names no configured source and no "
                  f"{devdoc / iid / 'checklist.md'}", file=sys.stderr)
            return 2
        return 0
    if verb == "keys":
        devdoc, scope = Path(rest[0]), rest[1]
        issue = rest[2] if len(rest) > 2 else None
        records, _, _ = tracker_inputs(env, sources)
        issues = scope_issues(scope, sources, records, devdoc, issue)
        _out([f"{S}\t{repo}\t{k}" for S, repo, k in mr_keys(issues, env.get("MS_MR_BACKEND", ""))],
             sys.stdout)
        return 0
    devdoc, project, scope = Path(rest[0]), rest[1], rest[2]
    issue = rest[3] if len(rest) > 3 else None
    records, t_missing, t_failed = tracker_inputs(env, sources)
    issues = scope_issues(scope, sources, records, devdoc, issue)
    details, m_missing, m_failed = mr_inputs(env, sources, issues)
    issues_rows, warnings = [], []
    for e in issues:
        rows, ws = issue_rows(e, devdoc, project, details)
        issues_rows.append((e["label"], rows))
        warnings += ws
    missing = t_missing + m_missing
    _out([f"milestones: WARNING: {s}: {d}; other sources still reported"
          for s, d in t_failed + m_failed]
         + [f"milestones: WARNING: {w}" for w in warnings], sys.stderr)
    render = render_json if as_json else render_text
    _out(render(project, scope, missing, issues_rows), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
