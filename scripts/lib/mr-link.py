#!/usr/bin/env python3
"""Linked-MR state for `wbs update` (#704): the link rule and the grammar.

An MR links issue (R, N) when its title or description carries a
closing-keyword reference that resolves to (R, N), whatever its target
branch. `#N` resolves to the MR's own repo; `owner/repo#N` is explicit. The
repo comparison is case-insensitive. A reference without a closing keyword
(`Related: #N`, a bare mention), the URL form and GitLab's bare
`project#N` do not link.

The code backends' optional `issue-mrs <repo> <id>...` verb (spec section
9.2) prints, per requested id in request order:

  issue<TAB><id><TAB>(open|draft|merged|none|missing)
  mr<TAB><id><TAB><ref><TAB>(open|draft|merged|closed)<TAB><created><TAB>(<merged>|-)

one `issue` line carrying the aggregate of its `mr` lines, then one `mr`
line per linked MR (closed-unmerged included), sorted by (created, ref).
Timestamps are UTC, second precision, `YYYY-MM-DDTHH:MM:SSZ`. `missing` is
a per-issue 404 and has no `mr` lines.

CLI:
  mr-link.py emit <github|gitlab> <repo>
        read one normalised JSON object per requested id on stdin
        ({"id", "status": "ok"|"missing", "mrs": [{"repo", "ref", "state":
        "open"|"closed"|"merged", "draft", "created", "merged", "title",
        "body"}]}), apply the link rule and print the verb's lines; exit 5
        on bad input (nothing printed).
  mr-link.py check <id>...
        read verb output on stdin; print the issue count and exit 0, or name
        the first fault on stderr and exit 1. The backend tests and `wbs
        update` share this predicate.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timedelta

# Closing keywords, one reference per keyword (GitHub's documented set).
GITHUB_KW = r"(?i:\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?))"
GITHUB_REF = r"(?:(?P<repo>[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+))?#(?P<num>[0-9]+)\b"
# GitLab's default closing pattern; it continues a list of references.
GITLAB_KW = (r"\b(?:[Cc]los(?:e[sd]?|ing)|[Ff]ix(?:e[sd]|ing)?"
             r"|[Rr]esolv(?:e[sd]?|ing)|[Ii]mplement(?:s|ed|ing)?)")
GITLAB_REF = r"(?:(?P<repo>[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+))?#(?P<num>[0-9]+)\b"

_HEAD = {
    "github": re.compile(GITHUB_KW + r":?[ \t]+" + GITHUB_REF),
    "gitlab": re.compile(GITLAB_KW + r":?[ \t]+(?:issues?[ \t]+)?" + GITLAB_REF),
}
# GitLab's continuation `(?: *,? +and +| *,? *)`, each reference optionally
# preceded by `issue `/`issues `.
_GITLAB_CONT = re.compile(r"(?:[ \t]*,?[ \t]+and[ \t]+|[ \t]*,?[ \t]*)(?:issues?[ \t]+)?"
                          + GITLAB_REF)

ISSUE_STATES = ("open", "draft", "merged", "none", "missing")
MR_STATES = ("open", "draft", "merged", "closed")
TS = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
ISSUE_RE = re.compile(rf"^issue\t([^\t]+)\t({'|'.join(ISSUE_STATES)})$")
MR_RE = re.compile(rf"^mr\t([^\t]+)\t([^\t\s]+[#!][0-9]+)\t({'|'.join(MR_STATES)})\t({TS})\t({TS}|-)$")
_TS_IN = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$")


def link_text(title: str, body: str) -> str:
    """The text the link rule reads: title and description, newline-joined
    so a keyword ending the title cannot take a reference opening the body."""
    return f"{title or ''}\n{body or ''}"


def linked(host: str, text: str, mr_repo: str) -> set[tuple[str, int]]:
    """The casefolded (repo, N) pairs that `text` closes."""
    out: set[tuple[str, int]] = set()
    for m in _HEAD[host].finditer(text):
        c = m
        while c:
            out.add(((c.group("repo") or mr_repo).casefold(), int(c.group("num"))))
            c = _GITLAB_CONT.match(text, c.end()) if host == "gitlab" else None
    return out


def aggregate(states) -> str:
    """open > draft > merged > none (closed-unmerged alone is none)."""
    states = set(states)
    for s in ("open", "draft", "merged"):
        if s in states:
            return s
    return "none"


def norm_ts(s: str) -> str:
    """An ISO-8601 timestamp as UTC `YYYY-MM-DDTHH:MM:SSZ` (fraction dropped).

    No fromisoformat: it rejects `Z` and fractions before Python 3.11, and
    the floor is 3.8.
    """
    m = _TS_IN.match(s if isinstance(s, str) else "")
    if not m:
        raise ValueError(f"bad timestamp: {s!r}")
    dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    tz = m.group(3)
    if tz != "Z":
        off = timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6]))
        dt = dt - off if tz[0] == "+" else dt + off
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_issue_mrs(text: str, ids) -> dict[str, str]:
    """Map each requested id -> its `issue` state. Blank lines are skipped;
    CRLF is absorbed. Raises ValueError on any line outside the grammar, an
    id missing, repeated or not requested, an `mr` line not under its own
    `issue` line, a `missing` id with `mr` lines, or an `issue` state that
    differs from the aggregate of its `mr` lines."""
    want = list(ids)
    out: dict[str, str] = {}
    mrs: dict[str, list[str]] = {}
    cur = None
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        m = ISSUE_RE.match(line)
        if m:
            iid, state = m.groups()
            if iid not in want:
                raise ValueError(f"line {n}: id {iid} was not requested")
            if iid in out:
                raise ValueError(f"line {n}: id {iid} repeated")
            out[iid], mrs[iid], cur = state, [], iid
            continue
        m = MR_RE.match(line)
        if not m:
            raise ValueError(f"malformed line {n}: {line}")
        iid = m.group(1)
        if iid != cur:
            raise ValueError(f"line {n}: mr line for {iid} not under its issue line")
        if out[iid] == "missing":
            raise ValueError(f"line {n}: missing id {iid} has mr lines")
        mrs[iid].append(m.group(3))
    absent = [i for i in want if i not in out]
    if absent:
        raise ValueError(f"id {absent[0]} has no issue line")
    for iid, state in out.items():
        if state != "missing" and aggregate(mrs[iid]) != state:
            raise ValueError(f"id {iid}: state {state} is not the aggregate of its mr lines")
    return out


def _mr_state(mr: dict) -> str:
    state = mr["state"]
    if state not in ("open", "closed", "merged"):
        raise ValueError(f"bad MR state: {state!r}")
    if state == "open" and mr.get("draft") is True:
        return "draft"
    return state


def emit(host: str, repo: str, records) -> list[str]:
    """The verb's lines for normalised records (see the module doc)."""
    if host not in _HEAD:
        raise ValueError(f"unknown host {host!r}")
    lines: list[str] = []
    for rec in records:
        iid, status = str(rec["id"]), rec["status"]
        if status == "missing":
            lines.append(f"issue\t{iid}\tmissing")
            continue
        if status != "ok":
            raise ValueError(f"bad status: {status!r}")
        rows = {}
        for mr in rec["mrs"]:
            state = _mr_state(mr)
            created = norm_ts(mr["created"])
            merged = norm_ts(mr["merged"]) if mr.get("merged") else "-"
            if (repo.casefold(), int(iid)) not in linked(
                    host, link_text(mr.get("title"), mr.get("body")), mr["repo"]):
                continue
            rows[mr["ref"]] = (created, mr["ref"], state, merged)
        rows = sorted(rows.values())
        lines.append(f"issue\t{iid}\t{aggregate(r[2] for r in rows)}")
        lines.extend(f"mr\t{iid}\t{ref}\t{state}\t{created}\t{merged}"
                     for created, ref, state, merged in rows)
    return lines


def _stdin() -> str:
    # bytes, then UTF-8: a Windows console code page must not mangle bodies
    return sys.stdin.buffer.read().decode("utf-8", "replace")


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "emit":
        try:
            records = [json.loads(l) for l in _stdin().splitlines() if l.strip()]
            lines = emit(argv[2], argv[3], records)
        except (ValueError, KeyError, TypeError, AttributeError) as e:
            print(f"mr-link: bad issue-mrs input: {e}", file=sys.stderr)
            return 5
        sys.stdout.write("".join(l + "\n" for l in lines))
        return 0
    if len(argv) >= 2 and argv[1] == "check":
        try:
            parsed = parse_issue_mrs(_stdin(), argv[2:])
        except ValueError as e:
            print(f"mr-link: {e}", file=sys.stderr)
            return 1
        print(len(parsed))
        return 0
    print("usage: mr-link.py emit <github|gitlab> <repo> < records\n"
          "       mr-link.py check <id>... < issue-mrs-output", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
