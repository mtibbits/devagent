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
.meta.json; a workflow agent (subagents/workflows/<run>/agent-*.jsonl, whose
meta has none) through the Workflow tool call whose result names its run id.

Transcripts are read from the current directory's dir under
<CLAUDE_CONFIG_DIR or ~/.claude>/projects, from every dir there with
--project, --all-dirs or --overhead, or from --transcripts, which overrides
them. --archive <dir> reads a scripts/archive-transcripts.sh archive
(<dir>/<host>/<cwd-slug>/<session>.jsonl.gz) and, alone, nothing live; the
live dirs are added by --all-dirs, --project, --overhead or --transcripts. A transcript is
read as .jsonl or .jsonl.gz. One API call (message id) is counted once across
every file read, so a session archived on two hosts and still live counts
once; a session is its sessionId. --json prints one JSON object per (project,
issue) with the transcript files it came from.

--overhead (#732) reports the (no project)/(no issue) calls as overhead per
project, each placed by the first rule that applies: the session's most
recent earlier hint (a typed /devagent:<cmd> naming a known project and no
issue, or a Bash call assigning DEVAGENT_PROJECT a known project; a hint
never moves the pair), else the project whose source_dir, worktree_root
(default <source_dir>-wt) or devdoc_dir holds the record's cwd (longest
match, spec 8.1 path containment; a tie between projects is unassigned),
else (unassigned) <cwd>. A subagent follows its launch's placement. Calls
and totals sum to the (no project)/(no issue) pair; session counts can
overlap across lines.

Records stream, so memory does
not grow with transcript size; under --time it grows by one 16-byte uuid key
per user/assistant record (about 150 bytes with set overhead) and one span
per busy run.

Cost is in input-token equivalents: each token class weighted by its price
relative to the base input price (WEIGHTS). A session re-reads its whole
context on every call, so cache reads dominate a long session; that is what
next.sh's phase breaks cut.

--time adds agent and operator time per pair (#733), from the timestamps of
user and assistant records only: attachments, queue operations and other
record types are invisible, and so are client-injected user records (isMeta,
isCompactSummary, isVisibleInTranscriptOnly, <local-command…> text). Each
interval between consecutive records of one transcript is a wait when the
later record answers a still-pending tool_use (any unanswered one, not only
the previous record's) or is a task-notification hand-back; a wait counts as
agent time when it is at most tool_gap, any other interval when it is at
most idle_gap, all or nothing (a peer message is not a wait). An interval
ending in an operator event is never agent time. A wait on an agent launch
whose subagent transcript was read and charged to a pair is not main time:
the subagent's own records carry the work. Agent busy time sums every transcript's busy
intervals (parallel subagents add); agent wall time, the headline, is the
length of their union. Operator events come from main sessions only: a
message with origin human, a user_temporary permission decision, the answer
to an AskUserQuestion or ExitPlanMode prompt, or, by fallback, a no-origin typed user message (not a notification, an
Another Claude session message or local-command output). An event adds its
latency since the previous record when that is at most attention_cap, else
counts a return after absence and adds 0; a typed message whose previous
record is not an end_turn was queued while the agent worked and adds 0.
Time is charged to the pair in force before the record's own events (a
typed /devagent:pull's latency is the prior pair's), and subagent time to
the pair that launched it, as cost is. A record whose uuid was already read
in any file adds nothing, so a live session and its archived copy count once.
"""

from __future__ import annotations

import argparse
import gzip
import importlib.util
import json
import math
import os
import re
import sys
import uuid
import zlib
from collections import defaultdict
from datetime import datetime
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
# A Workflow tool call's result names the run whose agents write
# subagents/workflows/<run>/ (their .meta.json carries no toolUseId).
RUN_ID = re.compile(r"Run ID: (wf_[0-9a-f]{8}-[0-9a-f]{3})")
# Commands that drive steps rather than being one.
DRIVERS = {"next"}
# A Bash command setting DEVAGENT_PROJECT to a literal value; a $-expansion never matches.
PROJECT_ASSIGN = re.compile(
    r"""(?:^|[\s;&|(])DEVAGENT_PROJECT=(?:"([\w.-]+)"|'([\w.-]+)'|([\w.-]+)(?=$|[\s;&|)]))"""
)
NO_PROJECT = "(no project)"
NO_ISSUE = "(no issue)"
NO_STEP = "(no step)"
START = ((NO_PROJECT, NO_ISSUE), NO_STEP)
# A line holding none of these cannot carry a call, a tool use, a dispatch
# header, a workflow run id or a typed command, so it is never parsed. A tool
# result matters only when it holds a dispatch header or a run id, which
# "dispatch: " and "Run ID: " already match.
MARKERS = ('"usage"', '"tool_use"', "dispatch: ", "<command-name>", "Run ID: ")
# A subagent file contributes only its calls.
SUB_MARKERS = ('"usage"',)
# Under --time every user/assistant record is read: operator and idle records carry no cost marker.
# Both separator styles: Claude Code writes compact JSON, Python's json.dumps does not.
TIME_MARKERS = ('"type":"user"', '"type":"assistant"', '"type": "user"', '"type": "assistant"')
# A hand-back notification names the background task it closes.
TASK_TOOL_USE_ID = re.compile(r"<tool-use-id>([^<]+)</tool-use-id>")
# Tool calls whose work a subagent transcript records.
LAUNCH_TOOLS = ("Agent", "Task", "Workflow")
# Tool calls whose result is the operator's answer: the wait is the operator's, not the agent's.
ASK_TOOLS = ("AskUserQuestion", "ExitPlanMode")
# No-origin user text that is not the operator typing.
NOT_TYPED = ("<task-notification>", "Another Claude session", "<local-command")


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


def session_key(path: Path) -> str:
    """A transcript file's session: the name before the first '.' (S.jsonl, S.jsonl.gz, S.ab12cd.jsonl.gz)."""
    return path.name.split(".", 1)[0]


def _open(path: Path):
    if path.name.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def load(path: Path, markers: tuple = MARKERS) -> Iterator[dict]:
    """Yield a transcript's records one at a time.

    A line is parsed only if it holds one of markers; a line that does not
    parse, or parses to anything but an object, is skipped. A .gz whose tail
    is torn (a crash mid-append) yields the records before the tear and warns.
    """
    with _open(path) as f:
        try:
            for line in f:
                if not any(m in line for m in markers):
                    continue
                try:
                    d = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if isinstance(d, dict):
                    yield d
        except (EOFError, zlib.error, gzip.BadGzipFile) as e:
            print(f"cost-report: truncated {path} ({e})", file=sys.stderr)


def _project_tables() -> dict[str, dict]:
    """The [project.<name>] tables of ${DA_HOME:-~/.claude/devagent}/config.toml (scripts/lib/paths.sh)."""
    path = Path(os.environ.get("DA_HOME") or Path.home() / ".claude" / "devagent") / "config.toml"
    if not path.is_file():
        return {}
    try:
        spec = importlib.util.spec_from_file_location("_devagent_toml", Path(__file__).with_name("_toml.py"))
        toml = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(toml)
        data = toml._load(path, retry=True)
    except (OSError, ValueError, ImportError) as e:  # unreadable, invalid TOML, or no TOML parser on this Python
        print(f"cost-report: cannot read {path} ({e}); known projects come from dispatch headers only",
              file=sys.stderr)
        return {}
    tables = data.get("project")
    return {k: v for k, v in tables.items() if isinstance(v, dict)} if isinstance(tables, dict) else {}


def known_projects() -> set[str]:
    return set(_project_tables())


_SLASH_DRIVE = re.compile(r"^/([A-Za-z])(/.*)?$")
_DRIVE = re.compile(r"^[A-Za-z]:")


def _norm(path: str) -> str:
    """Spec §8.1's string fallback (#950): \\ to /, /c/... to c:/..., fold only the drive letter, drop trailing /."""
    p = os.path.expanduser(path).replace("\\", "/")
    m = _SLASH_DRIVE.match(p)
    if m:
        p = f"{m.group(1)}:{m.group(2) or '/'}"
    if _DRIVE.match(p):
        p = p[0].lower() + p[1:]
    q = p.rstrip("/")
    if _DRIVE.fullmatch(q):
        return q + "/"
    return q or ("/" if p.startswith("/") else "")


def _under(p: str, r: str) -> bool:
    """Is path p under dir r, per spec §8.1: identity first when both are existing dirs, else _norm's strings."""
    np_, nr = (_norm(p) if p else ""), (_norm(r) if r else "")
    if not np_ or not nr:
        return False
    pp, rr = (np_ if os.path.isdir(np_) else p), (nr if os.path.isdir(nr) else r)
    if os.path.isdir(pp) and os.path.isdir(rr):
        cur = pp
        for _ in range(64):
            try:
                if os.path.samefile(cur, rr):
                    return True
            except OSError:
                break
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
        return False
    return np_ == nr or np_.startswith(nr if nr.endswith("/") else nr + "/")


def project_dirs(tables: dict[str, dict]) -> list[tuple[str, str]]:
    """(normalised dir, project) for each project's source_dir, worktree_root (default <source_dir>-wt) and devdoc_dir."""
    out: list[tuple[str, str]] = []
    for name, t in tables.items():
        src = t.get("source_dir")
        wt = t["worktree_root"] if "worktree_root" in t else (
            os.path.expanduser(src) + "-wt" if isinstance(src, str) and src else None)
        for v in (src, wt, t.get("devdoc_dir")):
            d = _norm(v) if isinstance(v, str) and v else ""
            if d and (d, name) not in out:
                out.append((d, name))
    return out


def _dir_project(cwd: str, dirs: list[tuple[str, str]], cache: dict) -> str | None:
    """The project whose dir holds cwd, longest dir winning; a tie between two projects is None."""
    if cwd not in cache:
        best, who = -1, set()
        for d, name in dirs:
            if _under(cwd, d):
                if len(d) > best:
                    best, who = len(d), {name}
                elif len(d) == best:
                    who.add(name)
        cache[cwd] = next(iter(who)) if len(who) == 1 else None
    return cache[cwd]


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


def parse_ts(s) -> float | None:
    """A record's ISO-8601 timestamp as epoch seconds; None when missing, unparseable or naive."""
    if not isinstance(s, str):
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    return dt.timestamp() if dt.tzinfo is not None else None


class TimeRules:
    """The three time-rule parameters, in seconds."""
    __slots__ = ("idle_gap", "tool_gap", "attention_cap")

    def __init__(self, idle_gap: float = 300.0, tool_gap: float = 3600.0, attention_cap: float = 900.0):
        self.idle_gap, self.tool_gap, self.attention_cap = float(idle_gap), float(tool_gap), float(attention_cap)

    def rule_line(self) -> str:
        return (f"time rule: idle_gap {self.idle_gap / 60:g}m, tool_gap {self.tool_gap / 60:g}m, "
                f"attention_cap {self.attention_cap / 60:g}m")

    def as_json(self) -> dict:
        return {"attention_cap_s": round(self.attention_cap, 2), "idle_gap_s": round(self.idle_gap, 2),
                "tool_gap_s": round(self.tool_gap, 2)}


class TimeAcc:
    """Agent and operator time charged to one pair (or one bucket of a transcript).

    spans: busy intervals as (start, end), a contiguous busy run kept as one span.
    linked_waits: [(closing tool_use id, start, end)], busy waits on a launched
    agent; collect() adds one only when no subagent file under that id was read.
    """
    __slots__ = ("spans", "busy", "operator", "events", "returns", "fallback", "linked_waits")

    def __init__(self):
        self.spans, self.linked_waits = [], []
        self.busy = self.operator = 0.0
        self.events = self.returns = self.fallback = 0

    def add_busy(self, start: float, end: float):
        if end <= start:
            return
        self.busy += end - start
        if self.spans and self.spans[-1][1] == start:
            self.spans[-1] = (self.spans[-1][0], end)
        else:
            self.spans.append((start, end))

    def merge(self, other: TimeAcc):
        self.spans.extend(other.spans)
        self.busy += other.busy
        self.operator += other.operator
        self.events += other.events
        self.returns += other.returns
        self.fallback += other.fallback

    def wall(self) -> float:
        """The length of the union of the busy spans."""
        total, end = 0.0, None
        for s, e in sorted(self.spans):
            if end is None or s > end:
                total, end = total + e - s, e
            elif e > end:
                total, end = total + e - end, e
        return total


def _typed_text(content) -> str | None:
    """A user record's text when it holds no tool_result: the string, or the first text block."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    text = None
    for b in content:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_result":
            return None
        if text is None and b.get("type") == "text":
            text = b.get("text") if isinstance(b.get("text"), str) else ""
    return text


def _content(d: dict):
    msg = d.get("message")
    return msg.get("content") if isinstance(msg, dict) else None


def injected(d: dict) -> bool:
    """A user record the client wrote (meta, compaction, local-command output): invisible to the time rules."""
    if d.get("type") != "user":
        return False
    if d.get("isMeta") or d.get("isCompactSummary") or d.get("isVisibleInTranscriptOnly"):
        return True
    text = _typed_text(_content(d))
    return text is not None and text.startswith("<local-command")


def operator_kind(d: dict) -> str | None:
    """For a main-session user record: "human", "permission", "fallback" (a no-origin typed message) or None."""
    origin = d.get("origin")
    if isinstance(origin, dict) and origin.get("kind") == "human":
        return "human"
    decision = d.get("permissionDecision")
    if isinstance(decision, dict) and decision.get("source") == "user_temporary":
        return "permission"
    if "origin" in d:
        return None
    text = _typed_text(_content(d))
    return "fallback" if text is not None and not text.startswith(NOT_TYPED) else None


class Clock:
    """The time rules over one transcript's records, in file order: the one place they live.

    tick() takes each user/assistant record with a parsed time t (the caller
    drops injected() records and any without a time). The interval from the
    previous record P to this one is agent time when it is a wait (this record
    answers a pending tool_use, or is a hand-back notification) no longer than
    tool_gap, or otherwise no longer than idle_gap, all or nothing; an interval
    ending in an operator event is never agent time. Operator events (main
    sessions only; operator_kind(), or the answer to an ASK_TOOLS prompt) add their latency when it is at most attention_cap, else
    count a return after absence; a typed message whose P is not an end_turn
    was queued while the agent worked and adds 0. A record whose uuid was
    already seen in any file adds nothing but still becomes P.
    """
    __slots__ = ("rules", "main", "uuids", "added", "pending", "launched", "asks", "prev")

    def __init__(self, rules: TimeRules, main: bool, uuids: set, added: set | None = None):
        # uuids: those read in other files; added: where this file's new ones go (default: uuids itself).
        self.rules, self.main, self.uuids = rules, main, uuids
        self.added = uuids if added is None else added
        self.pending: set = set()     # tool_use ids not yet answered
        self.launched: set = set()    # tool_use ids of agent launches
        self.asks: set = set()        # tool_use ids of ASK_TOOLS prompts
        self.prev = None              # (t, P is an end_turn assistant record)

    def tick(self, d: dict, t: float, acc: TimeAcc):
        kind = d.get("type")
        msg = d.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        blocks = content if isinstance(content, list) else ()
        dup = False
        u = d.get("uuid")
        if isinstance(u, str) and u:
            try:
                key = uuid.UUID(u).bytes
            except ValueError:
                key = u
            dup = key in self.uuids or key in self.added
            if not dup:
                self.added.add(key)
        results = [b.get("tool_use_id") for b in blocks
                   if isinstance(b, dict) and b.get("type") == "tool_result"] if kind == "user" else []
        closing = next((r for r in results if r in self.pending), None)
        wait = closing is not None
        origin = d.get("origin")
        if not wait and isinstance(origin, dict) and origin.get("kind") == "task-notification":
            wait = True
            m = TASK_TOOL_USE_ID.search(_text(content))
            closing = m.group(1) if m else None
        op = operator_kind(d) if self.main and kind == "user" else None
        if op is None and self.main and closing in self.asks:
            op = "permission"
        p = self.prev
        if not dup and p is not None:
            gap = t - p[0]
            if not op and 0 <= gap <= (self.rules.tool_gap if wait else self.rules.idle_gap):
                if wait and closing in self.launched:
                    acc.linked_waits.append((closing, p[0], t))
                else:
                    acc.add_busy(p[0], t)
        if not dup and op:
            acc.events += 1
            if op == "fallback":
                acc.fallback += 1
            if p is not None and (op == "permission" or p[1]):
                gap = max(0.0, t - p[0])
                if gap <= self.rules.attention_cap:
                    acc.operator += gap
                else:
                    acc.returns += 1
        if kind == "assistant":
            for b in blocks:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    self.pending.add(b.get("id"))
                    if b.get("name") in LAUNCH_TOOLS:
                        self.launched.add(b.get("id"))
                    elif b.get("name") in ASK_TOOLS:
                        self.asks.add(b.get("id"))
        else:
            self.pending.difference_update(results)
        self.prev = (t, kind == "assistant" and isinstance(msg, dict) and msg.get("stop_reason") == "end_turn")


class Timing:
    """The rules plus the record uuids seen across every file collect() reads."""
    __slots__ = ("rules", "uuids")

    def __init__(self, rules: TimeRules):
        self.rules, self.uuids = rules, set()

    def clock(self, main: bool, added: set | None = None) -> Clock:
        return Clock(self.rules, main, self.uuids, added)


def _timed(d: dict) -> float | None:
    """A record's time when the time rules see it: a non-injected user/assistant record with a parsed timestamp."""
    if d.get("type") not in ("user", "assistant") or injected(d):
        return None
    return parse_ts(d.get("timestamp"))


class Row:
    __slots__ = ("calls", "peak", "main", "sub")

    def __init__(self):
        self.calls, self.peak, self.main, self.sub = 0, 0, 0.0, 0.0

    def add(self, calls: int, peak: int, main: float):
        self.calls += calls
        self.peak = max(self.peak, peak)
        self.main += main


class Tape:
    """One session reduced to the events that move the pair or the step, with the calls between them bucketed.

    events: ("dispatch", project, issue, step) | ("typed", name, args) | ("skill", step)
            | ("launch", tool_use_id, cwd) | ("calls", Row, cwd) | ("hint", (project, ...))
            | ("time", TimeAcc)
            cwd is the record's cwd (None when absent); a calls bucket holds one cwd. A
            "hint" is the literal DEVAGENT_PROJECT values one Bash command assigns.
    dispatched: every project a next.sh dispatch header named (all hits, not only the last).
    subs: [(toolUseId, cost, fresh, cwd)], one per subagent file with usage; fresh is
          False when every one of its message ids was already counted elsewhere; cwd is
          the file's first record cwd (None when none has one).
    session: the first sessionId in the file, else its session key.
    runs: {workflow run id: the Workflow tool_use id whose result named it} (first wins).
    A "time" event (under --time) holds the time of the records ticked before the
    next pair-moving event: each record's time goes to the pair in force BEFORE
    the record's own events.
    sub_time: [(toolUseId, TimeAcc)], one per subagent file read, under --time.
    """
    __slots__ = ("events", "dispatched", "subs", "session", "runs", "sub_time")

    def __init__(self):
        self.events, self.dispatched, self.subs = [], set(), []
        self.session, self.runs = None, {}
        self.sub_time = []


def scan(records: Iterable[dict], seen: set[str], timing: Timing | None = None) -> Tape:
    """One forward pass over a session's records in file order; no record outlives its own turn.

    seen holds the message ids counted in files read before this one: such a
    call adds nothing, but still opens a calls bucket so the pair records the
    session. A repeat within this file is skipped outright, as before. With
    timing, each timed record ticks the session's Clock before its own events.
    """
    tape = Tape()
    ev = tape.events
    next_calls: set[str] = set()
    workflow_calls: set[str] = set()
    local: set[str] = set()
    clock = timing.clock(main=True) if timing else None
    row = tacc = None   # the open calls and time buckets; a pair-moving event closes both
    row_cwd = None      # the open calls bucket's cwd; a new cwd opens a new bucket

    def move(e):
        nonlocal row, tacc
        ev.append(e)
        row = tacc = None

    for d in records:
        if tape.session is None and isinstance(d.get("sessionId"), str) and d["sessionId"]:
            tape.session = d["sessionId"]
        if clock is not None:
            t = _timed(d)
            if t is not None:
                if tacc is None:
                    tacc = TimeAcc()
                    ev.append(("time", tacc))
                clock.tick(d, t, tacc)
        kind, msg = d.get("type"), d.get("message") or {}
        if not isinstance(msg, dict):
            continue
        cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else None
        if kind == "user":
            content = msg.get("content")
            blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    m = COMMAND.search(b.get("text", ""))
                    if m:
                        move(("typed", m.group(1), tuple((m.group(2) or "").split())))
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in next_calls:
                    hits = DISPATCH.findall(_text(b.get("content")))
                    if hits:
                        tape.dispatched.update(h[0] for h in hits)
                        move(("dispatch", *hits[-1]))
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in workflow_calls:
                    for run in RUN_ID.findall(_text(b.get("content"))):
                        tape.runs.setdefault(run, b.get("tool_use_id"))
        elif kind == "assistant":
            for b in msg.get("content") or []:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                name, inp = b.get("name"), b.get("input")
                if not isinstance(inp, dict):
                    inp = {}
                if name == "Bash":
                    cmd = str(inp.get("command", ""))
                    if "next.sh" in cmd:
                        next_calls.add(b.get("id"))
                    values = _assigned_projects(cmd)   # one command can be both a dispatch and a hint
                    if values:
                        move(("hint", values))
                elif name == "Skill":
                    s = str(inp.get("skill", ""))
                    if s.startswith("devagent:"):
                        n = s.split(":", 1)[1]
                        if n not in DRIVERS and not n.startswith("core-"):
                            move(("skill", n))
                elif name in LAUNCH_TOOLS:
                    move(("launch", b.get("id"), cwd))
                    if name == "Workflow":
                        workflow_calls.add(b.get("id"))
            mid, usage = msg.get("id"), msg.get("usage")
            if mid and isinstance(usage, dict) and usage and mid not in local:
                local.add(mid)
                if row is None or cwd != row_cwd:
                    row, row_cwd = Row(), cwd
                    ev.append(("calls", row, cwd))
                if mid not in seen:
                    seen.add(mid)
                    row.add(1, context_size(usage), call_cost(usage))
    return tape


def _skipped(path: Path, e: OSError):
    print(f"cost-report: skipped {path} ({e})", file=sys.stderr)


def _mtime(path: Path) -> float:
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def _transcripts(paths: Iterable[Path]) -> list[Path]:
    """The .jsonl and .jsonl.gz files among paths (one glob of <pattern>.jsonl* feeds this), sorted."""
    return sorted(p for p in paths if p.name.endswith((".jsonl", ".jsonl.gz")))


def scan_session(path: Path, seen: set[str], timing: Timing | None = None) -> Tape:
    """scan() one session file, then sum each of its subagent files (last usage per message id wins).

    Subagent files are every agent-*.jsonl[.gz] under <dir>/<session>/subagents/,
    workflow agents included (journal.jsonl never matches). seen is shared
    across every file collect() reads: an id counted anywhere else adds nothing.
    With timing, each subagent file also runs its own Clock (no operator events).
    """
    key = session_key(path)
    tape = scan(load(path, MARKERS + TIME_MARKERS if timing else MARKERS), seen, timing)
    tape.session = tape.session or key
    base = path.parent / key / "subagents"
    for sub in _transcripts(base.rglob("agent-*.jsonl*")):
        try:
            meta = json.loads((sub.parent / f"{session_key(sub)}.meta.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, RecursionError):
            meta = {}
        last: dict[str, dict] = {}
        sub_cwd = None
        # Like last for cost, a subagent file's uuids join the shared set only once it reads whole.
        added: set = set()
        clock, acc = (timing.clock(main=False, added=added), TimeAcc()) if timing else (None, None)
        try:
            for d in load(sub, SUB_MARKERS + TIME_MARKERS if timing else SUB_MARKERS):
                msg = d.get("message") or {}
                if sub_cwd is None and isinstance(d.get("cwd"), str):
                    sub_cwd = d["cwd"]
                if d.get("type") == "assistant" and isinstance(msg, dict) and msg.get("id") and isinstance(msg.get("usage"), dict):
                    last[msg["id"]] = msg["usage"]
                if clock is not None:
                    t = _timed(d)
                    if t is not None:
                        clock.tick(d, t, acc)
        except OSError as e:
            _skipped(sub, e)
            continue
        tool_use_id = meta.get("toolUseId") if isinstance(meta, dict) else None
        if tool_use_id is None and sub.parent.parent.name == "workflows":
            tool_use_id = tape.runs.get(sub.parent.name)
        if acc is not None:
            timing.uuids |= added
            tape.sub_time.append((tool_use_id, acc))
        if last:
            fresh = [u for mid, u in last.items() if mid not in seen]
            seen.update(last)
            tape.subs.append((tool_use_id, sum(map(call_cost, fresh)), bool(fresh), sub_cwd))
    return tape


def _typed_names(args: tuple, known: set[str]):
    """(project, issue) a typed command's args name: the project after --project or first, the last issue token."""
    project, used = None, None
    if "--project" in args:
        j = args.index("--project") + 1
        if j < len(args) and args[j] in known:
            project, used = args[j], j
    if project is None and args and args[0] in known:
        project, used = args[0], 0
    issue = None
    for j, a in enumerate(args):
        m = ISSUE_TOKEN.search(a) if j != used and a not in known else None   # a project never doubles as the issue
        if m:
            issue = m.group(1)
    return project, issue


def _typed_hint(name: str, args: tuple, known: set[str]) -> str | None:
    """The project a typed /devagent:<name> <args> hints: the first known project, when no issue is named.

    A hint only places overhead; it never changes the pair. pull never hints.
    """
    if name == "pull" or _typed_names(args, known)[1] is not None:
        return None
    if "--project" in args:
        j = args.index("--project") + 1
        if j < len(args) and args[j] in known:
            return args[j]
    return next((a for a in args if a in known), None)


def _assigned_projects(cmd: str) -> tuple[str, ...]:
    """The literal values a Bash command assigns to DEVAGENT_PROJECT, in order."""
    return tuple(next(g for g in m if g) for m in PROJECT_ASSIGN.findall(cmd))


def _typed_pair(name: str, args: tuple, pair: tuple, step: str, known: set[str]):
    """The (pair, step) after a typed /devagent:<name> <args>."""
    if name in DRIVERS:
        return pair, step
    if name == "pull":
        if len(args) == 3 and args[1] in ("origin", "fork") and re.fullmatch(r"[0-9]+", args[2]):
            return (args[0], f"Issue-{args[2]}"), name   # the Issue- dir_prefix default
        return pair, step                                 # any other shape, pull.sh rejects
    project, issue = _typed_names(args, known)
    if issue is None:
        return pair, name
    if project is not None:
        return (project, issue), name
    # An issue with no project keeps the pair only when it is the same issue.
    return (pair if issue == pair[1] else (NO_PROJECT, issue)), name


def replay(tape: Tape, known: set[str]):
    """Run the pair state machine over a tape, and beside it the project hint (#732).

    Return ([(pair, step, Row, (hint, cwd))], {Agent tool_use id: (pair, step)},
    [(pair, TimeAcc)], {Agent tool_use id: (hint, cwd)}). The hint never moves the pair.
    """
    pair, step = START
    hint = None
    buckets, launches, timed, places = [], {}, [], {}
    for e in tape.events:
        kind = e[0]
        if kind == "calls":
            buckets.append((pair, step, e[1], (hint, e[2])))
        elif kind == "time":
            timed.append((pair, e[1]))
        elif kind == "dispatch":
            pair, step = (e[1], e[2]), e[3]
        elif kind == "typed":
            pair, step = _typed_pair(e[1], e[2], pair, step, known)
            hint = _typed_hint(e[1], e[2], known) or hint
        elif kind == "skill":
            step = e[1]
        elif kind == "hint":
            hint = next((v for v in reversed(e[1]) if v in known), hint)
        elif kind == "launch":
            launches[e[1]] = (pair, step)
            places[e[1]] = (hint, e[2])
    return buckets, launches, timed, places


class Overhead:
    """One overhead line's figures: per-step Rows, sessions, sources, and calls per placement rule."""
    __slots__ = ("steps", "sessions", "sources", "rules")

    def __init__(self):
        self.steps: dict[str, Row] = {}
        self.sessions: set[str] = set()
        self.sources: set[tuple] = set()
        self.rules = {"hint": 0, "cwd": 0, "unassigned": 0}


def _place(hint: str | None, cwd: str | None, dirs: list[tuple[str, str]], cache: dict):
    """Where an overhead call goes, first rule that applies: the session hint, the cwd's project, else unassigned."""
    if hint is not None:
        return ("project", hint), "hint"
    project = _dir_project(cwd, dirs, cache) if cwd else None
    if project is not None:
        return ("project", project), "cwd"
    return ("unassigned", _norm(cwd) if cwd else "(no cwd)"), "unassigned"


def collect(dirs: list[Path], issue_filter: str | None, project_filter: str | None = None, *,
            hosts: dict | None = None, sources: dict | None = None,
            timing: TimeRules | None = None, times: dict | None = None,
            overhead: dict | None = None):
    """Return ({(project, issue): {step: Row}}, {(project, issue): {sessionId}}), each filter an exact match.

    Every session is scanned before any is replayed: a typed command names a
    known project if ANY scanned dispatch header names it, even in a later file.
    One set of message ids spans every file, so a call is counted once however
    many copies of its transcript are read. hosts maps a dir to its archive
    partition (absent: "local"); a dict passed as sources is filled
    {pair: {(host, cwd_slug, sessionId)}}. With timing, a dict passed as times
    is filled {pair: TimeAcc} under the same filters; one set of record uuids
    spans every file, as message ids do. A dict passed as overhead is filled
    {("project", P) | ("unassigned", cwd): Overhead} with the (no project)/(no issue)
    calls, charged at the same sites and from the same Rows, so it sums to that pair.
    """
    hosts = hosts or {}
    sources = {} if sources is None else sources
    clocks = Timing(timing) if timing is not None else None
    files = sorted(((p, d) for d in dirs for p in _transcripts(d.glob("*.jsonl*"))),
                   key=lambda t: (_mtime(t[0]), session_key(t[0]), str(t[0])))
    # One unreadable file is skipped with a warning, not allowed to sink a report over every dir.
    tapes = []
    seen: set[str] = set()
    for p, d in files:
        try:
            tapes.append((scan_session(p, seen, clocks), (hosts.get(d, "local"), d.name)))
        except OSError as e:
            _skipped(p, e)
    tables = _project_tables()
    known = set(tables).union(*(t.dispatched for t, _ in tapes))
    pdirs, cache = (project_dirs(tables), {}) if overhead is not None else ([], {})
    # A wait on a launched agent is not main busy when a subagent file under its id was read and is charged
    # through this tape's launches (its records carry the work); a nested agent's file is charged elsewhere.
    sub_ids = {i for t, _ in tapes for i, _ in t.sub_time if i is not None}
    rows: dict[tuple, dict[str, Row]] = defaultdict(dict)
    sessions: dict[tuple, set[str]] = defaultdict(set)
    acc: dict[tuple, TimeAcc] = defaultdict(TimeAcc)

    def charge(pair, a: TimeAcc, launches):
        acc[pair].merge(a)
        for i, start, end in a.linked_waits:
            if i not in sub_ids or i not in launches:
                acc[pair].add_busy(start, end)

    for tape, where in tapes:
        buckets, launches, timed, places = replay(tape, known)
        origin = (*where, tape.session)
        def slot(place):
            o = overhead.setdefault(place, Overhead())
            o.sessions.add(tape.session)
            o.sources.add(origin)
            return o

        for pair, step, b, (hint, cwd) in buckets:
            if b.calls:
                rows[pair].setdefault(step, Row()).add(b.calls, b.peak, b.main)
                if overhead is not None and pair == START[0]:
                    place, rule = _place(hint, cwd, pdirs, cache)
                    o = slot(place)
                    o.steps.setdefault(step, Row()).add(b.calls, b.peak, b.main)
                    o.rules[rule] += b.calls
            sessions[pair].add(tape.session)
            sources.setdefault(pair, set()).add(origin)
        for tool_use_id, cost, fresh, sub_cwd in tape.subs:
            pair, step = launches.get(tool_use_id, START)
            if fresh:
                rows[pair].setdefault(step, Row()).sub += cost
                if overhead is not None and pair == START[0]:
                    place, _ = _place(*places.get(tool_use_id, (None, sub_cwd)), pdirs, cache)
                    slot(place).steps.setdefault(step, Row()).sub += cost
            sources.setdefault(pair, set()).add(origin)
        for pair, a in timed:
            charge(pair, a, launches)
        for tool_use_id, a in tape.sub_time:
            charge(launches.get(tool_use_id, START)[0], a, launches)

    def wanted(pair):
        return (not issue_filter or pair[1] == issue_filter) and (not project_filter or pair[0] == project_filter)

    if times is not None:
        times.update((k, v) for k, v in acc.items() if wanted(k))
    return {k: v for k, v in rows.items() if wanted(k)}, sessions


def label(pair: tuple) -> str:
    return f"{pair[0]}/{pair[1]}"


def _m(x: float) -> str:
    return f"{x / 1e6:.2f}"


def summary_line(heading: str, steps: dict[str, Row], n_sessions: int) -> str:
    main = sum(r.main for r in steps.values())
    sub = sum(r.sub for r in steps.values())
    calls = sum(r.calls for r in steps.values())
    peak = max((r.peak for r in steps.values()), default=0)
    return (
        f"{heading}: {(main + sub) / 1e6:.1f}M input-token equivalents over "
        f"{n_sessions} session(s), {calls} calls, peak context {peak // 1000}K "
        f"(main {main / 1e6:.1f}M, subagents {sub / 1e6:.1f}M)"
    )


def time_line(pair: tuple, a: TimeAcc) -> str:
    return (
        f"{label(pair)} time: agent wall {a.wall() / 3600:.2f}h, agent busy {a.busy / 3600:.2f}h, "
        f"operator {a.operator / 3600:.2f}h ({a.events} operator events, {a.returns} returns after absence, "
        f"{a.fallback} by fallback)"
    )


def report(rows, sessions, source: str, summary: bool, times: dict | None = None,
           rules: TimeRules | None = None) -> str:
    """The text report; with rules (--time), the rule line heads it and each pair's time line follows its cost line."""
    out = []
    if not summary:
        out.append(f"Token cost by step, from {source}")
        out.append(
            "input-token equivalents, weighted by price vs base input: cache read 0.1, "
            "cache write 1.25 (5m) / 2 (1h), output 5"
        )
    if rules is not None:
        out.append(rules.rule_line())
    for pair, steps in rows.items():
        line = summary_line(label(pair), steps, len(sessions.get(pair, ())))
        lines = [line] if rules is None else [line, time_line(pair, (times or {}).get(pair) or TimeAcc())]
        if summary:
            out += lines
            continue
        out += ["", *lines, *_steps_block(steps)]
    return "\n".join(out)


def _steps_block(steps: dict[str, Row]) -> list[str]:
    """The per-step table under a heading: the column header, then one row per step."""
    total = sum(r.main + r.sub for r in steps.values()) or 1.0
    out = [f"  {'step':<22}{'calls':>6}{'peak ctx':>10}{'main M':>9}{'sub M':>8}{'total M':>9}{'share':>7}"]
    for step, r in steps.items():
        out.append(
            f"  {step:<22}{r.calls:>6}{r.peak // 1000:>9}K{_m(r.main):>9}{_m(r.sub):>8}"
            f"{_m(r.main + r.sub):>9}{100 * (r.main + r.sub) / total:>6.0f}%"
        )
    return out


def _sources_json(sources) -> list[dict]:
    return [{"cwd_slug": c, "host": h, "session": s} for c, h, s in sorted((c, h, s) for h, c, s in sources)]


def _overhead_order(ov: dict):
    """Project lines by name, then unassigned lines by cwd."""
    return sorted(ov.items(), key=lambda kv: (kv[0][0] != "project", kv[0][1]))


def overhead_heading(key: tuple, o: Overhead) -> str:
    kind, name = key
    if kind == "project":
        return summary_line(f"{name}/(overhead)", o.steps, len(o.sessions)) + \
            f"; hint {o.rules['hint']}, cwd {o.rules['cwd']}"
    return summary_line(f"(unassigned) {name}", o.steps, len(o.sessions))


def report_overhead(ov: dict, source: str, summary: bool) -> str:
    """The --overhead text report, in report()'s shape: one line (or block) per project, then per unassigned cwd."""
    out = [] if summary else [
        f"Token cost by step, from {source}",
        "input-token equivalents, weighted by price vs base input: cache read 0.1, "
        "cache write 1.25 (5m) / 2 (1h), output 5",
    ]
    for key, o in _overhead_order(ov):
        out += [overhead_heading(key, o)] if summary else ["", overhead_heading(key, o), *_steps_block(o.steps)]
    return "\n".join(out)


def report_overhead_json(ov: dict) -> str:
    """One JSON object per --overhead line, keys sorted, figures rounded to 2 decimals."""
    out = []
    for (kind, name), o in _overhead_order(ov):
        main = sum(r.main for r in o.steps.values())
        sub = sum(r.sub for r in o.steps.values())
        out.append(json.dumps({
            "calls": sum(r.calls for r in o.steps.values()),
            "cwd": None if kind == "project" else name,
            "main": round(main, 2),
            "peak_context": max((r.peak for r in o.steps.values()), default=0),
            "project": name if kind == "project" else "(unassigned)",
            "rules": dict(o.rules),
            "sessions": len(o.sessions),
            "sources": _sources_json(o.sources),
            "subagents": round(sub, 2),
            "total": round(main + sub, 2),
        }, sort_keys=True))
    return "\n".join(out)


def report_json(rows, sessions, sources, times: dict | None = None, rules: TimeRules | None = None) -> str:
    """One JSON object per pair, in report() order, keys sorted, figures rounded to 2 decimals.

    With rules (--time), each object also carries the pair's time figures (seconds) and the rules as time_rule.
    """
    out = []
    for pair, steps in rows.items():
        main = sum(r.main for r in steps.values())
        sub = sum(r.sub for r in steps.values())
        extra = {}
        if rules is not None:
            a = (times or {}).get(pair) or TimeAcc()
            extra = {
                "agent_busy_s": round(a.busy, 2),
                "agent_wall_s": round(a.wall(), 2),
                "fallback_events": a.fallback,
                "operator_events": a.events,
                "operator_s": round(a.operator, 2),
                "returns_after_absence": a.returns,
                "time_rule": rules.as_json(),
            }
        out.append(json.dumps({
            **extra,
            "calls": sum(r.calls for r in steps.values()),
            "issue": pair[1],
            "main": round(main, 2),
            "peak_context": max((r.peak for r in steps.values()), default=0),
            "project": pair[0],
            "sessions": len(sessions.get(pair, ())),
            "sources": _sources_json(sources.get(pair, ())),
            "subagents": round(sub, 2),
            "total": round(main + sub, 2),
        }, sort_keys=True))
    return "\n".join(out)


def archive_dirs(archive: Path) -> list[Path]:
    """Every <archive>/<host>/<cwd-slug> dir, sorted by host then slug (manifest.jsonl, last-run skipped)."""
    return [c for h in sorted((p for p in archive.iterdir() if p.is_dir()), key=lambda p: p.name)
            for c in sorted((p for p in h.iterdir() if p.is_dir()), key=lambda p: p.name)]


def transcripts_root() -> Path:
    """Where Claude Code keeps one transcript dir per working directory."""
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def default_dirs() -> list[Path]:
    """The current directory's transcript dirs (the slug matched case-insensitively)."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd()).lower()
    return [p for p in all_dirs() if p.name.lower() == slug]


def all_dirs() -> list[Path]:
    """Every transcript dir on this machine, sorted by name."""
    return sorted((p for p in transcripts_root().glob("*") if p.is_dir()), key=lambda p: p.name)


def _nonempty(value: str) -> str:
    if not value:
        raise argparse.ArgumentTypeError("must not be empty")
    return value


def _minutes(value: str) -> float:
    try:
        x = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number of minutes: {value!r}") from None
    if not math.isfinite(x) or x <= 0:
        raise argparse.ArgumentTypeError(f"must be a finite number of minutes > 0: {value!r}")
    return x


# --time parameters: flag, TimeRules attribute (the defaults live in TimeRules).
TIME_FLAGS = (("--idle-gap", "idle_gap"), ("--tool-gap", "tool_gap"), ("--attention-cap", "attention_cap"))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--transcripts", action="append", type=Path,
                    help="a Claude Code project transcript dir (repeatable); overrides --project, --all-dirs "
                         "and --overhead; "
                         "default: the current directory's")
    ap.add_argument("--project", type=_nonempty,
                    help="report only this project (exact match); reads every transcript dir")
    ap.add_argument("--issue", help="report only this issue (Issue-N or N)")
    ap.add_argument("--all-dirs", action="store_true",
                    help="read every transcript dir under <CLAUDE_CONFIG_DIR or ~/.claude>/projects")
    ap.add_argument("--archive", type=Path,
                    help="read a scripts/archive-transcripts.sh archive (every host and cwd partition, "
                         ".jsonl.gz); alone it reads no live dir, --all-dirs/--project/--overhead/--transcripts add them")
    out = ap.add_mutually_exclusive_group()
    out.add_argument("--summary", action="store_true", help="one line per (project, issue) pair")
    out.add_argument("--json", action="store_true",
                     help="one JSON object per (project, issue) pair, with the transcript files it came from")
    ap.add_argument("--time", action="store_true", help="add agent and operator time per pair")
    ap.add_argument("--overhead", action="store_true",
                    help="report (no project)/(no issue) cost as per-project overhead: hint, then cwd, "
                         "else (unassigned); reads every transcript dir")
    defaults = TimeRules()
    for flag, attr in TIME_FLAGS:
        ap.add_argument(flag, type=_minutes, metavar="MIN",
                        help=f"a --time rule parameter, in minutes; default {getattr(defaults, attr) / 60:g}")
    a = ap.parse_args(argv)
    given = {attr: 60 * getattr(a, attr) for _, attr in TIME_FLAGS if getattr(a, attr) is not None}
    if given and not a.time:
        ap.error(f"{next(f for f, attr in TIME_FLAGS if attr in given)} needs --time")
    if a.overhead and a.issue:
        ap.error("--overhead does not take --issue")
    if a.overhead and a.time:
        ap.error("--overhead does not take --time")
    rules = TimeRules(**given) if a.time else None
    times: dict = {}
    issue = f"Issue-{a.issue}" if a.issue and a.issue.isdigit() else a.issue
    every = (a.project or a.all_dirs or a.overhead) and not a.transcripts
    adirs: list[Path] = []
    if a.archive is not None:
        if not a.archive.is_dir():
            print(f"cost-report: no archive dir {a.archive}", file=sys.stderr)
            return 2
        adirs = archive_dirs(a.archive)
    # --archive alone reads no live dir; otherwise the current directory's is the default.
    live = a.transcripts or (all_dirs() if every else [] if a.archive is not None else default_dirs())
    if not (live or adirs) or not all(d.is_dir() for d in live):
        under = f"no transcript dir under {transcripts_root()}" + (f" or archive {a.archive}" if a.archive else "")
        print(f"cost-report: {under}" if every or (a.archive and not a.transcripts)
              else "cost-report: no transcript dir; pass --transcripts ~/.claude/projects/<slug>", file=sys.stderr)
        return 2
    dirs = live + adirs
    hosts = {d: d.parent.name for d in adirs}
    parts = []
    if live:
        parts.append(f"every transcript dir under {transcripts_root()} ({len(live)} dirs)" if every
                     else ", ".join(map(str, live)))
    if a.archive is not None:
        parts.append(f"archive {a.archive} ({len(adirs)} dirs)")
    source = "; ".join(parts)
    sources: dict = {}
    if a.overhead:
        ov: dict = {}
        collect(dirs, None, hosts=hosts, sources=sources, overhead=ov)
        if a.project:
            ov = {k: v for k, v in ov.items() if k == ("project", a.project)}
        if not ov:
            print("cost-report: no overhead calls" + (f" placed on project {a.project}" if a.project else ""),
                  file=sys.stderr)
            return 1
        if a.json:
            print(report_overhead_json(ov))
            return 0
        if hasattr(sys.stdout, "reconfigure"):   # an (unassigned) cwd may not fit the locale codec
            sys.stdout.reconfigure(encoding="utf-8")
        print(report_overhead(ov, source, a.summary))
        return 0
    if a.project and issue:
        # P/N first, then the (no project)/N calls that may be P's too.
        rows, sessions = collect(dirs, issue, hosts=hosts, sources=sources, timing=rules, times=times)
        target, side = (a.project, issue), (NO_PROJECT, issue)
        if target not in rows:
            print(f"cost-report: no calls attributed to {label(target)}", file=sys.stderr)
            if side in rows:
                hint = summary_line(label(side), rows[side], len(sessions.get(side, ())))
                print(f"cost-report: hint: {hint}", file=sys.stderr)
            return 1
        rows = {k: rows[k] for k in (target, side) if k in rows}
    else:
        rows, sessions = collect(dirs, issue, a.project, hosts=hosts, sources=sources, timing=rules, times=times)
        if not rows:
            what = f"project {a.project}" if a.project else issue or "any issue"
            print(f"cost-report: no calls attributed to {what}", file=sys.stderr)
            return 1
    print(report_json(rows, sessions, sources, times, rules) if a.json
          else report(rows, sessions, source, a.summary, times, rules))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
