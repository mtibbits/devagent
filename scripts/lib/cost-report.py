#!/usr/bin/env python3
"""Token cost per (project, issue) and per workflow step, from Claude Code transcripts.

Every API call in a session transcript records its token usage. This charges
each call to the session's current (project, issue) pair and to the devAgent
step running when it was made. The pair is set, project and issue together,
by a next.sh `dispatch:` header, a typed `/devagent:pull <project>
origin|fork <N>`, or a typed command naming a known project and an issue; a
typed issue with no project keeps the pair only for the same issue, else it is
`(no project)`. The step is the last header's, or a step invoked directly (a
typed /devagent:<step>, or a Skill call to devagent:<step>). A subagent is
charged to the pair and step that launched it, through the toolUseId in its
.meta.json.

Transcripts are read from the current directory's dir under
<CLAUDE_CONFIG_DIR or ~/.claude>/projects, from every dir there with
--project or --all-dirs, or from --transcripts, which overrides both. Records
stream, so memory does not grow with transcript size.

Cost is in input-token equivalents: each token class weighted by its price
relative to the base input price (WEIGHTS). A session re-reads its whole
context on every call, so cache reads dominate a long session; that is what
next.sh's phase breaks cut.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable, Iterator

WEIGHTS = {
    "input": 1.0,
    "cache_read": 0.1,
    "cache_write_5m": 1.25,
    "cache_write_1h": 2.0,
    "output": 5.0,
}

# The header next.sh prints before every step (see scripts/next.sh).
DISPATCH = re.compile(r"dispatch: ([\w.-]+)/([\w.-]*\d) — step \d+ \(([\w-]+)\)")
COMMAND = re.compile(
    r"<command-name>/devagent:([\w-]+)</command-name>"
    r"(?:\s*<command-args>([^<]*)</command-args>)?"
)
ISSUE_TOKEN = re.compile(r"(?:^|/)([A-Za-z]+-\d+)/?$")
# Commands that drive steps rather than being one.
DRIVERS = {"next"}
NO_PROJECT = "(no project)"
NO_ISSUE = "(no issue)"
NO_STEP = "(no step)"
# A line holding none of these cannot carry a call, a tool use or result, a
# dispatch header or a typed command, so it is never parsed.
MARKERS = ('"usage"', '"tool_use"', '"tool_result"', "dispatch: ", "<command-name>")


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


def load(path: Path) -> Iterator[dict]:
    """Yield a transcript's records one at a time.

    A line is parsed only if it holds one of MARKERS; a line that does not
    parse, or parses to anything but an object, is skipped.
    """
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not any(m in line for m in MARKERS):
                continue
            try:
                d = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if isinstance(d, dict):
                yield d


def known_projects() -> set[str]:
    """The [project.<name>] tables of ${DA_HOME:-~/.claude/devagent}/config.toml (scripts/lib/paths.sh)."""
    path = Path(os.environ.get("DA_HOME") or Path.home() / ".claude" / "devagent") / "config.toml"
    try:
        spec = importlib.util.spec_from_file_location("_devagent_toml", Path(__file__).with_name("_toml.py"))
        toml = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(toml)
        data = toml._load(path, retry=True)
    except FileNotFoundError:
        return set()
    except Exception as e:  # unreadable, invalid TOML, or no TOML parser on this Python
        print(f"cost-report: cannot read {path} ({e}); known projects come from dispatch headers only",
              file=sys.stderr)
        return set()
    tables = data.get("project")
    return {k for k, v in tables.items() if isinstance(v, dict)} if isinstance(tables, dict) else set()


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


class Row:
    __slots__ = ("calls", "peak", "main", "sub")

    def __init__(self):
        self.calls, self.peak, self.main, self.sub = 0, 0, 0.0, 0.0


class Tape:
    """One session reduced to the events that move the pair or the step, with the calls between them bucketed.

    events: ("dispatch", project, issue, step) | ("typed", name, args) | ("skill", step)
            | ("launch", tool_use_id) | ["calls", n, peak, cost]
    dispatched: every project a next.sh dispatch header named (all hits, not only the last).
    subs: [(toolUseId, cost)], one per subagent file with usage.
    """
    __slots__ = ("stem", "events", "dispatched", "subs")

    def __init__(self, stem: str = ""):
        self.stem, self.events, self.dispatched, self.subs = stem, [], set(), []


def scan(records: Iterable[dict], stem: str = "") -> Tape:
    """One forward pass over a session's records in file order; no record outlives its own turn."""
    tape = Tape(stem)
    ev = tape.events
    next_calls: set[str] = set()
    seen: set[str] = set()
    for d in records:
        kind, msg = d.get("type"), d.get("message") or {}
        if not isinstance(msg, dict):
            continue
        if kind == "user":
            content = msg.get("content")
            blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    m = COMMAND.search(b.get("text", ""))
                    if m:
                        ev.append(("typed", m.group(1), tuple((m.group(2) or "").split())))
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in next_calls:
                    hits = DISPATCH.findall(_text(b.get("content")))
                    if hits:
                        tape.dispatched.update(h[0] for h in hits)
                        ev.append(("dispatch", *hits[-1]))
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
                            ev.append(("skill", n))
                elif name in ("Agent", "Task"):
                    ev.append(("launch", b.get("id")))
            mid, usage = msg.get("id"), msg.get("usage")
            if mid and usage and mid not in seen:
                seen.add(mid)
                size, cost = context_size(usage), call_cost(usage)
                if ev and ev[-1][0] == "calls":
                    bucket = ev[-1]
                    bucket[1] += 1
                    bucket[2] = max(bucket[2], size)
                    bucket[3] += cost
                else:
                    ev.append(["calls", 1, size, cost])
    return tape


def scan_session(path: Path) -> Tape:
    """scan() one session file, then sum each of its subagent files (last usage per message id wins)."""
    tape = scan(load(path), path.stem)
    for sub in sorted(path.with_suffix("").glob("subagents/*.jsonl")):
        try:
            meta = json.loads(sub.with_suffix(".meta.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, RecursionError):
            meta = {}
        last: dict[str, dict] = {}
        for d in load(sub):
            msg = d.get("message") or {}
            if d.get("type") == "assistant" and isinstance(msg, dict) and msg.get("id") and msg.get("usage"):
                last[msg["id"]] = msg["usage"]
        if last:
            tool_use_id = meta.get("toolUseId") if isinstance(meta, dict) else None
            tape.subs.append((tool_use_id, sum(map(call_cost, last.values()))))
    return tape


def _typed_pair(name: str, args: tuple, pair: tuple, step: str, known: set[str]):
    """The (pair, step) after a typed /devagent:<name> <args>."""
    if name in DRIVERS:
        return pair, step
    if name == "pull":
        if len(args) == 3 and args[1] in ("origin", "fork") and args[2].isdigit():
            return (args[0], f"Issue-{args[2]}"), name   # the Issue- dir_prefix default
        return pair, step                                 # any other shape, pull.sh rejects
    project, used = None, None
    if "--project" in args:
        j = args.index("--project") + 1
        if j < len(args) and args[j] in known:
            project, used = args[j], j
    if project is None and args and args[0] in known:
        project, used = args[0], 0
    issue = None
    for j, a in enumerate(args):
        m = ISSUE_TOKEN.search(a) if j != used else None
        if m:
            issue = m.group(1)
    if issue is None:
        return pair, name
    if project is not None:
        return (project, issue), name
    # An issue with no project keeps the pair only when it is the same issue.
    return (pair if issue == pair[1] else (NO_PROJECT, issue)), name


def replay(tape: Tape, known: set[str]):
    """Run the pair state machine over a tape.

    Return ([(pair, step, calls, peak, cost)], {Agent tool_use id: (pair, step)}).
    """
    pair, step = (NO_PROJECT, NO_ISSUE), NO_STEP
    buckets, launches = [], {}
    for e in tape.events:
        kind = e[0]
        if kind == "calls":
            buckets.append((pair, step, e[1], e[2], e[3]))
        elif kind == "dispatch":
            pair, step = (e[1], e[2]), e[3]
        elif kind == "typed":
            pair, step = _typed_pair(e[1], e[2], pair, step, known)
        elif kind == "skill":
            step = e[1]
        elif kind == "launch":
            launches[e[1]] = (pair, step)
    return buckets, launches


def collect(dirs: list[Path], issue_filter: str | None, project_filter: str | None = None,
            known: set[str] | None = None):
    """Return ({(project, issue): {step: Row}}, {(project, issue): {session stem}}).

    Every session is scanned before any is replayed: a typed command names a
    known project if ANY scanned dispatch header names it, even in a later file.
    """
    files = sorted((p for d in dirs for p in d.glob("*.jsonl")), key=os.path.getmtime)
    tapes = [scan_session(p) for p in files]
    known = (known_projects() if known is None else set(known)).union(*(t.dispatched for t in tapes))
    rows: dict[tuple, dict[str, Row]] = defaultdict(dict)
    sessions: dict[tuple, set[str]] = defaultdict(set)
    for tape in tapes:
        buckets, launches = replay(tape, known)
        for pair, step, n, peak, cost in buckets:
            r = rows[pair].setdefault(step, Row())
            r.calls += n
            r.peak = max(r.peak, peak)
            r.main += cost
            sessions[pair].add(tape.stem)
        for tool_use_id, cost in tape.subs:
            pair, step = launches.get(tool_use_id, ((NO_PROJECT, NO_ISSUE), NO_STEP))
            rows[pair].setdefault(step, Row()).sub += cost

    def keep(pair):
        project, issue = pair
        if issue_filter and project_filter:
            return issue == issue_filter and project in (project_filter, NO_PROJECT)
        if issue_filter:
            return issue == issue_filter
        if project_filter:
            return project == project_filter
        return True

    kept = [k for k in rows if keep(k)]
    if issue_filter and project_filter:
        kept.sort(key=lambda k: k[0] != project_filter)   # (P, N) first
    return {k: rows[k] for k in kept}, sessions


def label(pair: tuple) -> str:
    return f"{pair[0]}/{pair[1]}"


def _m(x: float) -> str:
    return f"{x / 1e6:.2f}"


def summary_line(label: str, steps: dict[str, Row], n_sessions: int) -> str:
    main = sum(r.main for r in steps.values())
    sub = sum(r.sub for r in steps.values())
    calls = sum(r.calls for r in steps.values())
    peak = max((r.peak for r in steps.values()), default=0)
    return (
        f"{label}: {(main + sub) / 1e6:.1f}M input-token equivalents over "
        f"{n_sessions} session(s), {calls} calls, peak context {peak // 1000}K "
        f"(main {main / 1e6:.1f}M, subagents {sub / 1e6:.1f}M)"
    )


def report(rows, sessions, dirs, summary: bool, source: str | None = None) -> str:
    out = []
    if not summary:
        out.append(f"Token cost by step, from {source or ', '.join(map(str, dirs))}")
        out.append(
            "input-token equivalents, weighted by price vs base input: cache read 0.1, "
            "cache write 1.25 (5m) / 2 (1h), output 5"
        )
    for pair, steps in rows.items():
        line = summary_line(label(pair), steps, len(sessions.get(pair, ())))
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


def transcripts_root() -> Path:
    """Where Claude Code keeps one transcript dir per working directory."""
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def default_dirs() -> list[Path]:
    """The current directory's transcript dirs (the slug matched case-insensitively)."""
    home = transcripts_root()
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())
    return [p for p in home.glob("*") if p.is_dir() and p.name.lower() == slug.lower()]


def all_dirs() -> list[Path]:
    """Every transcript dir on this machine, sorted by name."""
    return sorted((p for p in transcripts_root().glob("*") if p.is_dir()), key=lambda p: p.name)


def _nonempty(value: str) -> str:
    if not value:
        raise argparse.ArgumentTypeError("must not be empty")
    return value


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--transcripts", action="append", type=Path,
                    help="a Claude Code project transcript dir (repeatable); overrides --project and --all-dirs; "
                         "default: the current directory's")
    ap.add_argument("--project", type=_nonempty,
                    help="report only this project (exact match); reads every transcript dir")
    ap.add_argument("--issue", help="report only this issue (Issue-N or N)")
    ap.add_argument("--all-dirs", action="store_true",
                    help="read every transcript dir under <CLAUDE_CONFIG_DIR or ~/.claude>/projects")
    ap.add_argument("--summary", action="store_true", help="one line per (project, issue) pair")
    a = ap.parse_args(argv)
    issue = f"Issue-{a.issue}" if a.issue and a.issue.isdigit() else a.issue
    source = None
    if a.transcripts:
        dirs = a.transcripts
    elif a.project or a.all_dirs:
        dirs = all_dirs()
        if not dirs:
            print(f"cost-report: no transcript dir under {transcripts_root()}", file=sys.stderr)
            return 2
        source = f"every transcript dir under {transcripts_root()} ({len(dirs)} dirs)"
    else:
        dirs = default_dirs()
    if not dirs or not all(d.is_dir() for d in dirs):
        print("cost-report: no transcript dir; pass --transcripts ~/.claude/projects/<slug>", file=sys.stderr)
        return 2
    rows, sessions = collect(dirs, issue, a.project)
    if a.project and issue:
        target, side = (a.project, issue), (NO_PROJECT, issue)
        if target not in rows:
            print(f"cost-report: no calls attributed to {label(target)}", file=sys.stderr)
            if side in rows:
                hint = summary_line(label(side), rows[side], len(sessions.get(side, ())))
                print(f"cost-report: hint: {hint}", file=sys.stderr)
            return 1
    elif not rows:
        what = f"project {a.project}" if a.project else issue or "any issue"
        print(f"cost-report: no calls attributed to {what}", file=sys.stderr)
        return 1
    print(report(rows, sessions, dirs, a.summary, source))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
