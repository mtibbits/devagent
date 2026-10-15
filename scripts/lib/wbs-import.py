#!/usr/bin/env python3
"""Seed a WBS from tracker history: `wbs init --from-tracker` (#706).

An issue backend's `issue-list <repo>` verb prints JSON Lines, one compact
object per issue (spec section 9.1); empty output is a repo with no issues:

  {"id":"12","title":"t","body":"b","state":"closed","class":"done",
   "created":"2026-01-02","closed":"2026-02-01","milestone":null,
   "labels":["epic"],"type":null,
   "parent":"https://github.com/o/r/issues/3",
   "blocked_by":["https://github.com/o/r/issues/4"],
   "url":"https://github.com/o/r/issues/12"}

  id          GitHub number / GitLab iid (digits), or a Jira key
  title, body strings (an empty body is "")
  state       open | closed
  class       a state-list class (wbs-tracker.py CLASSES)
  created     YYYY-MM-DD
  closed      YYYY-MM-DD when state is closed, else null
  milestone, type, parent   string or null
  labels, blocked_by        string arrays
  parent, blocked_by, url   issue URLs (Jira: <base>/browse/<KEY>)

`parse_issue_list` is the one predicate for that contract: the backend
tests (via `check`) and `wbs init` both use it.

CLI:
  wbs-import.py check   read issue-list output on stdin; print the record
                        count and exit 0, or the error on stderr and exit 1.
"""
from __future__ import annotations

import datetime
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


trk = _load("wbs_tracker", HERE / "wbs-tracker.py")

DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_STR = (str,)
_OPT = (str, type(None))
# key -> allowed types; the order is the documented field order
FIELDS = {
    "id": _STR, "title": _STR, "body": _STR, "state": _STR, "class": _STR,
    "created": _STR, "closed": _OPT, "milestone": _OPT, "labels": (list,),
    "type": _OPT, "parent": _OPT, "blocked_by": (list,), "url": _STR,
}


def _is_date(v) -> bool:
    if not isinstance(v, str) or not DATE_RE.match(v):
        return False
    try:
        datetime.date.fromisoformat(v)
    except ValueError:
        return False
    return True


def _check_record(rec) -> str | None:
    """Return why a decoded record breaks the contract, or None."""
    if not isinstance(rec, dict):
        return "not an object"
    for key, types in FIELDS.items():
        if key not in rec:
            return f"missing key {key}"
        if isinstance(rec[key], bool) or not isinstance(rec[key], types):
            return f"wrong type for {key}"
    for key in ("labels", "blocked_by"):
        if not all(isinstance(v, str) for v in rec[key]):
            return f"wrong type in {key}"
    if not rec["id"]:
        return "empty id"
    if rec["state"] not in ("open", "closed"):
        return f"bad state {rec['state']}"
    if rec["class"] not in trk.CLASSES:
        return f"bad class {rec['class']}"
    if not _is_date(rec["created"]):
        return "bad date in created"
    if rec["state"] == "closed":
        if not _is_date(rec["closed"]):
            return "bad date in closed"
    elif rec["closed"] is not None:
        return "closed set on an open issue"
    return None


def parse_issue_list(text: str) -> list[dict]:
    """Decode issue-list output; blank lines are skipped, CRLF absorbed.

    Raises ValueError("malformed line <n>: <why>") for a line that is not
    one contract record, or for an id listed twice.
    """
    out: list[dict] = []
    seen: set[str] = set()
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            raise ValueError(f"malformed line {n}: not JSON") from None
        why = _check_record(rec)
        if why:
            raise ValueError(f"malformed line {n}: {why}")
        if rec["id"] in seen:
            raise ValueError(f"malformed line {n}: duplicate id {rec['id']}")
        seen.add(rec["id"])
        out.append(rec)
    return out


def _stdout(text: str) -> None:
    # UTF-8 bytes, LF: safe on a cp1252 console
    sys.stdout.flush()
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


def main(argv: list[str]) -> int:
    if argv[1:] == ["check"]:
        text = sys.stdin.buffer.read().decode("utf-8", "replace")
        try:
            recs = parse_issue_list(text)
        except ValueError as e:
            print(e, file=sys.stderr)
            return 1
        _stdout(f"{len(recs)}\n")
        return 0
    print("usage: wbs-import.py check", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
