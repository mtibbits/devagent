#!/usr/bin/env python3
"""Token cost per issue and per workflow step, from Claude Code transcripts.

Every API call in a session transcript records its token usage. This charges
each call to the devAgent step running when it was made: the last `dispatch:`
header a next.sh call printed, or a step invoked directly (a typed
/devagent:<step>, or a Skill call to devagent:<step>). A subagent is charged
to the step that launched it, through the toolUseId in its .meta.json.

Cost is in input-token equivalents: each token class weighted by its price
relative to the base input price (WEIGHTS). A session re-reads its whole
context on every call, so cache reads dominate a long session; that is what
next.sh's phase breaks cut.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

WEIGHTS = {
    "input": 1.0,
    "cache_read": 0.1,
    "cache_write_5m": 1.25,
    "cache_write_1h": 2.0,
    "output": 5.0,
}

# The header next.sh prints before every step (see scripts/next.sh).
DISPATCH = re.compile(r"dispatch: [\w.-]+/([\w.-]*\d) — step \d+ \(([\w-]+)\)")
COMMAND = re.compile(
    r"<command-name>/devagent:([\w-]+)</command-name>"
    r"(?:\s*<command-args>([^<]*)</command-args>)?"
)
ISSUE_TOKEN = re.compile(r"(?:^|/)([A-Za-z]+-\d+)/?$")
# Commands that drive steps rather than being one.
DRIVERS = {"next"}
NO_ISSUE = "(no issue)"
NO_STEP = "(no step)"


def call_cost(u: dict) -> float:
    writes = u.get("cache_creation_input_tokens") or 0
    split = u.get("cache_creation") or {}
    w1h = split.get("ephemeral_1h_input_tokens")
    w5m = split.get("ephemeral_5m_input_tokens")
    if w1h is None and w5m is None:
        w5m, w1h = writes, 0
    return (
        WEIGHTS["input"] * (u.get("input_tokens") or 0)
        + WEIGHTS["cache_read"] * (u.get("cache_read_input_tokens") or 0)
        + WEIGHTS["cache_write_5m"] * (w5m or 0)
        + WEIGHTS["cache_write_1h"] * (w1h or 0)
        + WEIGHTS["output"] * (u.get("output_tokens") or 0)
    )


def context_size(u: dict) -> int:
    return (
        (u.get("input_tokens") or 0)
        + (u.get("cache_read_input_tokens") or 0)
        + (u.get("cache_creation_input_tokens") or 0)
    )


def load(path: Path) -> list[dict]:
    records = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                records.append(json.loads(line))
            except ValueError:
                continue
    return records


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


def _command(match, issue: str, step: str) -> tuple[str, str]:
    name, args = match.group(1), (match.group(2) or "").split()
    if name in DRIVERS:
        return issue, step
    if name == "pull" and args and args[-1].isdigit():
        return f"Issue-{args[-1]}", name       # the Issue- dir_prefix default
    for a in args:
        m = ISSUE_TOKEN.search(a)
        if m:
            issue = m.group(1)
    return issue, name


def attribute(records: list[dict]):
    """Return ([(issue, step, usage)] per API call, {Agent tool_use id: (issue, step)})."""
    issue, step = NO_ISSUE, NO_STEP
    next_calls: set[str] = set()
    seen: set[str] = set()
    calls, launches = [], {}
    for d in records:
        kind, msg = d.get("type"), d.get("message") or {}
        if kind == "user":
            content = msg.get("content")
            blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    m = COMMAND.search(b.get("text", ""))
                    if m:
                        issue, step = _command(m, issue, step)
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in next_calls:
                    hits = DISPATCH.findall(_text(b.get("content")))
                    if hits:
                        issue, step = hits[-1]
        elif kind == "assistant":
            for b in msg.get("content") or []:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                name, inp = b.get("name"), b.get("input") or {}
                if name == "Bash" and "next.sh" in str(inp.get("command", "")):
                    next_calls.add(b.get("id"))
                elif name == "Skill":
                    s = str(inp.get("skill", ""))
                    if s.startswith("devagent:"):
                        n = s.split(":", 1)[1]
                        if n not in DRIVERS and not n.startswith("core-"):
                            step = n
                elif name in ("Agent", "Task"):
                    launches[b.get("id")] = (issue, step)
            mid, usage = msg.get("id"), msg.get("usage")
            if mid and usage and mid not in seen:
                seen.add(mid)
                calls.append((issue, step, usage))
    return calls, launches


class Row:
    __slots__ = ("calls", "peak", "main", "sub")

    def __init__(self):
        self.calls, self.peak, self.main, self.sub = 0, 0, 0.0, 0.0


def collect(dirs: list[Path], issue_filter: str | None):
    rows: dict[str, dict[str, Row]] = defaultdict(dict)
    sessions: dict[str, set[str]] = defaultdict(set)
    files = sorted((p for d in dirs for p in d.glob("*.jsonl")), key=os.path.getmtime)
    # A cheap pre-filter on the issue NUMBER: a session begun with
    # `/devagent:pull <project> origin 7` never spells "Issue-7".
    key = re.sub(r"^.*?(\d+)$", r"\1", issue_filter) if issue_filter else None
    for path in files:
        if key and key not in path.read_text(encoding="utf-8", errors="replace"):
            continue
        calls, launches = attribute(load(path))
        for issue, step, u in calls:
            r = rows[issue].setdefault(step, Row())
            r.calls += 1
            r.peak = max(r.peak, context_size(u))
            r.main += call_cost(u)
            sessions[issue].add(path.stem)
        for sub in sorted(path.with_suffix("").glob("subagents/*.jsonl")):
            meta_path = sub.with_suffix(".meta.json")
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                meta = {}
            issue, step = launches.get(meta.get("toolUseId"), (NO_ISSUE, NO_STEP))
            seen: dict[str, dict] = {}
            for d in load(sub):
                msg = d.get("message") or {}
                if d.get("type") == "assistant" and msg.get("id") and msg.get("usage"):
                    seen[msg["id"]] = msg["usage"]
            if seen:
                rows[issue].setdefault(step, Row()).sub += sum(map(call_cost, seen.values()))
    if issue_filter:
        rows = {k: v for k, v in rows.items() if k == issue_filter}
    return rows, sessions


def _m(x: float) -> str:
    return f"{x / 1e6:.2f}"


def summary_line(issue: str, steps: dict[str, Row], n_sessions: int) -> str:
    main = sum(r.main for r in steps.values())
    sub = sum(r.sub for r in steps.values())
    calls = sum(r.calls for r in steps.values())
    peak = max((r.peak for r in steps.values()), default=0)
    return (
        f"{issue}: {(main + sub) / 1e6:.1f}M input-token equivalents over "
        f"{n_sessions} session(s), {calls} calls, peak context {peak // 1000}K "
        f"(main {main / 1e6:.1f}M, subagents {sub / 1e6:.1f}M)"
    )


def report(rows, sessions, dirs, summary: bool) -> str:
    out = []
    if not summary:
        out.append(f"Token cost by step, from {', '.join(map(str, dirs))}")
        out.append(
            "input-token equivalents, weighted by price vs base input: cache read 0.1, "
            "cache write 1.25 (5m) / 2 (1h), output 5"
        )
    for issue, steps in rows.items():
        line = summary_line(issue, steps, len(sessions.get(issue, ())))
        if summary:
            out.append(line)
            continue
        total = sum(r.main + r.sub for r in steps.values()) or 1.0
        out += ["", line, f"  {'step':<22}{'calls':>6}{'peak ctx':>10}{'main M':>9}{'sub M':>8}{'total M':>9}{'share':>7}"]
        for step, r in steps.items():
            out.append(
                f"  {step:<22}{r.calls:>6}{r.peak // 1000:>9}K{_m(r.main):>9}{_m(r.sub):>8}"
                f"{_m(r.main + r.sub):>9}{100 * (r.main + r.sub) / total:>6.0f}%"
            )
    return "\n".join(out)


def default_dirs() -> list[Path]:
    home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())
    return [p for p in home.glob("*") if p.is_dir() and p.name.lower() == slug.lower()]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--transcripts", action="append", type=Path,
                    help="a Claude Code project transcript dir (repeatable); default: the one for the current directory")
    ap.add_argument("--issue", help="report only this issue (Issue-N or N)")
    ap.add_argument("--summary", action="store_true", help="one line per issue")
    a = ap.parse_args(argv)
    issue = f"Issue-{a.issue}" if a.issue and a.issue.isdigit() else a.issue
    dirs = a.transcripts or default_dirs()
    if not dirs or not all(d.is_dir() for d in dirs):
        print("cost-report: no transcript dir; pass --transcripts ~/.claude/projects/<slug>", file=sys.stderr)
        return 2
    rows, sessions = collect(dirs, issue)
    if not rows:
        print(f"cost-report: no calls attributed to {issue or 'any issue'}", file=sys.stderr)
        return 1
    print(report(rows, sessions, dirs, a.summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
