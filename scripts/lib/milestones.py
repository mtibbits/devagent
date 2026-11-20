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
import re
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
            if d:
                rows.append({**base, "event": "log", "at": d.group(1), "name": "-",
                             "revision": revision})
            continue
        date, hhmm, name, msg = m.groups()
        at = f"{date}T{hhmm}{suffix}"
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
    warnings = []
    if started != headings:
        warnings.append(f"{rel}: revision starts logged {_fmt_set(started)} "
                        f"but ## Revision headings {_fmt_set(headings)}")
    return rows, warnings
