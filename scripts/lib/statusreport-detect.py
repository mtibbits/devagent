#!/usr/bin/env python3
"""Detection heuristics for /devagent:statusreport (spec §14.4).

Each predicate takes an issue directory (Path or str) and returns bool
or an ancillary datum. The predicates are pure (no filesystem writes,
no network) so they are trivially unit-testable against fixture
directories.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

_LOG_RE = re.compile(
    r"^-\s+(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+(?P<step>[a-zA-Z0-9_]+):\s+(?P<msg>.*)$"
)
_BLOCKING_RE = re.compile(r"(?P<count>\d+)\s+blocking", re.IGNORECASE)
_RECS_RE = re.compile(r"(?P<count>\d+)\s+recommendations?", re.IGNORECASE)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_log_entries(checklist_path: Path) -> list[dict]:
    if not checklist_path.exists():
        return []
    entries: list[dict] = []
    in_log = False
    for line in checklist_path.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("## Log"):
            in_log = True
            continue
        if in_log and line.startswith("## "):
            in_log = False
            continue
        if not in_log:
            continue
        m = _LOG_RE.match(line)
        if not m:
            continue
        ts = datetime.strptime(m.group("ts"), "%Y-%m-%d %H:%M").replace(
            tzinfo=timezone.utc
        )
        entries.append(
            {"ts": ts, "step": m.group("step"), "message": m.group("msg")}
        )
    return entries


def is_stuck(issue_dir: Path | str) -> bool:
    return (Path(issue_dir) / "STUCK").exists()


def failed_redteam(issue_dir: Path | str) -> bool:
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    redmr = [e for e in entries if e["step"] == "redmr"]
    if not redmr:
        return False
    last = redmr[-1]
    m = _BLOCKING_RE.search(last["message"])
    if not m:
        return False
    return int(m.group("count")) > 0


def poorly_scoped(issue_dir: Path | str) -> bool:
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    for e in entries:
        if e["step"] != "scope":
            continue
        if "ambiguity" in e["message"].lower():
            return True
        m = _RECS_RE.search(e["message"])
        if m and int(m.group("count")) >= 3:
            return True
    return False


def is_idle(issue_dir: Path | str, last_step: int, threshold_days: int = 7) -> bool:
    if last_step >= 20:
        return False
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    if not entries:
        return False
    most_recent = max(e["ts"] for e in entries)
    return (_now() - most_recent) > timedelta(days=threshold_days)


def is_completed(issue_dir: Path | str) -> bool:
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    return any(e["step"] == "cleanup" for e in entries)


def completion_timestamp(issue_dir: Path | str) -> Optional[datetime]:
    entries = _parse_log_entries(Path(issue_dir) / "checklist.md")
    for e in entries:
        if e["step"] == "cleanup":
            return e["ts"]
    return None
