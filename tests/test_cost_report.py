"""Tests for scripts/lib/cost-report.py (per-(project, issue), per-step token cost)."""
import gzip
import importlib.util
import itertools
import json
import os
import re
import subprocess
import sys
import tracemalloc
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "lib" / "cost-report.py"

spec = importlib.util.spec_from_file_location("cost_report", SCRIPT)
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

NP, NI = "(no project)", "(no issue)"


@pytest.fixture(autouse=True)
def _hermetic(tmp_path, monkeypatch):
    """No test reads the operator's config.toml or ~/.claude/projects (#730).

    The real config names a dozen projects; reading it would make known-project
    resolution green or red by accident. Subprocess tests inherit os.environ.
    """
    for sub in ("da-home", "claude", "cwd"):
        (tmp_path / sub).mkdir()
    monkeypatch.setenv("DA_HOME", str(tmp_path / "da-home"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "claude"))
    monkeypatch.chdir(tmp_path / "cwd")


def _usage(inp=0, read=0, w5=0, w1=0, out=0):
    return {
        "input_tokens": inp,
        "cache_read_input_tokens": read,
        "cache_creation_input_tokens": w5 + w1,
        "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1},
        "output_tokens": out,
    }


def _call(mid, usage, *tool_uses, stop_reason=None):
    """An assistant record; stop_reason defaults to "tool_use" when it carries a tool_use (#733)."""
    msg = {"id": mid, "usage": usage, "content": list(tool_uses)}
    if stop_reason is not None or tool_uses:
        msg["stop_reason"] = stop_reason or "tool_use"
    return {"type": "assistant", "message": msg}


def _tool(tid, name, **inp):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}


def _result(tid, text):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]}}


def _typed(cmd, args):
    return {"type": "user", "message": {"content": f"<command-name>/devagent:{cmd}</command-name>\n<command-args>{args}</command-args>"}}


def _dispatch(tid, project, issue, n, step, mid):
    """A next.sh Bash call and its result carrying next.sh's header, byte for byte.

    The Bash call has no usage, so it is uncounted: it would be charged to the
    pair in force BEFORE the header (see test_dispatch_call_is_charged_to_the_prior_pair).
    """
    return [
        _call(mid, None, _tool(tid, "Bash", command='bash "x/scripts/next.sh" ' + project + " --auto")),
        _result(tid, f"dispatch: {project}/{issue} — step {n} ({step}), skill-backed"),
    ]


def _write(path, records, mtime=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def _subagent(session_path, name, tool_use_id, records):
    sub = session_path.with_suffix("") / "subagents" / f"{name}.jsonl"
    _write(sub, records)
    sub.with_suffix(".meta.json").write_text(json.dumps({"toolUseId": tool_use_id}), encoding="utf-8")


def _config(names):
    """Write DA_HOME/config.toml naming each project in its own [project.<name>] table."""
    body = "".join(f'[project.{n}]\nsource_dir = "/x/{n}"\n\n' for n in names)
    Path(os.environ["DA_HOME"], "config.toml").write_text(body, encoding="utf-8")


def _cwd_slug():
    """The cwd's transcript-dir name, built here for fixtures rather than taken from default_dirs under test."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())


def _cli(*args, cwd=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True, encoding="utf-8", cwd=cwd,
    )


def _calls(rows, key):
    return sum(r.calls for r in rows[key].values())


def _per_issue(rows):
    """{issue: (calls, main, sub)}, summed over projects."""
    out = {}
    for (_, issue), steps in rows.items():
        c, m, s = out.get(issue, (0, 0.0, 0.0))
        out[issue] = (
            c + sum(r.calls for r in steps.values()),
            m + sum(r.main for r in steps.values()),
            s + sum(r.sub for r in steps.values()),
        )
    return out


def _session(tmp_path):
    """One session: pull 42, draft (launches a subagent), a stray Read of a dispatch line, implement."""
    d = tmp_path / "proj"
    _write(d / "s1.jsonl", [
        _typed("pull", "devagent origin 42"),
        _call("m1", _usage(inp=10)),
        _call("m2", _usage(out=1), _tool("b1", "Bash", command='bash "x/scripts/next.sh" devagent --auto')),
        _result("b1", "dispatch: devagent/Issue-42 — step 2 (draft), skill-backed\n→ Run /devagent:draft devagent"),
        _call("m3", _usage(read=1000), _tool("a1", "Agent", description="planner")),
        _call("m3", _usage(read=1000)),  # a second content block of the same message: counted once
        _call("m4", _usage(out=1), _tool("r1", "Read", file_path="some/test.bats")),
        _result("r1", "dispatch: devagent/Issue-99 — step 9 (implement), skill-backed"),  # not next.sh: ignored
        _call("m5", _usage(w1=100)),
        _call("m6", _usage(out=1), _tool("b2", "Bash", command='bash "x/scripts/next.sh" devagent --auto --chained')),
        _result("b2", "dispatch: devagent/Issue-42 — step 9 (implement), skill-backed"),
        _call("m7", _usage(w5=100, read=5000)),
    ])
    _subagent(d / "s1.jsonl", "agent-x", "a1", [_call("s1", _usage(out=10)), _call("s2", _usage(read=100))])
    return d


# --- Task 1: migrated tests (keys and expected lines changed only) ----------

def test_call_cost_weights_each_token_class():
    assert cr.call_cost(_usage(inp=1, read=10, w5=4, w1=2, out=1)) == 1 + 1 + 5 + 4 + 5


def test_call_cost_without_a_write_split_prices_writes_as_5m():
    u = {"cache_creation_input_tokens": 4}
    assert cr.call_cost(u) == 5


def test_steps_follow_next_dispatches_and_typed_commands(tmp_path):
    rows, sessions = cr.collect([_session(tmp_path)], None)
    steps = rows[("devagent", "Issue-42")]
    assert list(steps) == ["pull", "draft", "implement"]
    # A call belongs to the step that made it: m2 runs next.sh during pull.
    assert steps["pull"].main == 10 + 5              # m1, m2
    assert steps["draft"].calls == 4                 # m3 once, m4, m5, m6: the Read did not move the step
    assert steps["draft"].main == 100 + 5 + 200 + 5
    assert steps["implement"].main == 125 + 500      # m7
    assert steps["implement"].peak == 5100
    assert not any(k[1] == "Issue-99" for k in rows)
    assert sessions[("devagent", "Issue-42")] == {"s1"}


def test_subagent_is_charged_to_the_step_that_launched_it(tmp_path):
    rows, _ = cr.collect([_session(tmp_path)], None)
    assert rows[("devagent", "Issue-42")]["draft"].sub == 50 + 10
    assert sum(r.sub for r in rows[("devagent", "Issue-42")].values()) == 60


def test_issue_filter_skips_other_sessions(tmp_path):
    d = _session(tmp_path)
    _write(d / "s2.jsonl", [_typed("pull", "devagent origin 7"), _call("n1", _usage(inp=3))])
    rows, _ = cr.collect([d], "Issue-7")
    assert list(rows) == [("devagent", "Issue-7")]
    rows, _ = cr.collect([d], "Issue-42")
    assert list(rows) == [("devagent", "Issue-42")]


def test_summary_line_is_one_pasteable_line(tmp_path):
    rows, sessions = cr.collect([_session(tmp_path)], "Issue-42")
    line = cr.report(rows, sessions, str(tmp_path), summary=True)
    assert "\n" not in line
    assert line.startswith("devagent/Issue-42: 0.0M input-token equivalents over 1 session(s), 7 calls, peak context 5K")


def test_cli_accepts_a_bare_issue_number(tmp_path):
    run = _cli("--transcripts", _session(tmp_path), "--issue", "42")
    assert run.returncode == 0, run.stderr
    assert "devagent/Issue-42:" in run.stdout
    assert "implement" in run.stdout


def test_cli_reports_an_issue_with_no_calls(tmp_path):
    run = _cli("--transcripts", _session(tmp_path), "--issue", "5")
    assert run.returncode == 1
    assert "no calls attributed to Issue-5" in run.stderr


# --- Task 1: single-project equivalence guard (AC9) -------------------------

def _single_project_fixture(tmp_path):
    """One project, two sessions, every rule that preserves per-issue totals."""
    d = tmp_path / "single"
    s1 = d / "s1.jsonl"
    _write(s1, [
        _call("m0", _usage(inp=7)),                                   # before any signal
        _typed("pull", "devagent origin 42"),
        _call("m1", _usage(inp=10)),
        *_dispatch("b1", "devagent", "Issue-42", 2, "draft", "d1"),
        _call("m2", _usage(read=1000), _tool("a1", "Agent", description="planner")),
        _call("m2", _usage(read=1000)),                               # duplicated message id: counted once
        _call("m3", _usage(out=2), _tool("k1", "Skill", skill="devagent:quality")),
        _typed("draft", "Issue-42"),                                  # exception, keep branch
        _call("m4", _usage(w5=40)),
        *_dispatch("b2", "devagent", "Issue-42", 9, "implement", "d2"),
        _call("m5", _usage(inp=3)),
        _typed("draft", "Issue-43"),                                  # exception, reset branch
        _call("m6", _usage(inp=11)),
        _typed("catchup", "devagent"),                                # project only
        _call("m7", _usage(inp=13)),
    ], mtime=1_000_000)
    _subagent(s1, "agent-a", "a1", [_call("sa1", _usage(out=10)), _call("sa2", _usage(read=100))])
    _write(d / "s2.jsonl", [
        _call("n0", _usage(inp=5)),
        *_dispatch("b3", "devagent", "Issue-43", 9, "implement", "d3"),
        _call("n1", _usage(inp=17)),
        _call("n1", _usage(inp=17)),
    ], mtime=2_000_000)
    return d


# Captured from the unchanged module (846c19c's cost-report.py) by
# analysis/2026-11-07-t1-baseline-totals-run.txt; never from new code.
BASELINE_TOTALS = {
    "(no issue)": (2, 12.0, 0.0),
    "Issue-42": (5, 173.0, 60.0),
    "Issue-43": (3, 41.0, 0.0),
}


def test_single_project_totals_match_846c19c(tmp_path):
    rows, _ = cr.collect([_single_project_fixture(tmp_path)], None)
    assert _per_issue(rows) == BASELINE_TOTALS


# --- Task 2: attribution (collect level) ------------------------------------

def _ac1_fixture(tmp_path):
    """Session A dispatches alpha/Issue-4; session B pulls beta 4 and launches one subagent."""
    d = tmp_path / "ac1"
    _alpha_session(d)
    b = d / "B.jsonl"
    _write(b, [
        _typed("pull", "beta origin 4"),
        _call("bm1", _usage(inp=50), _tool("a1", "Agent", description="planner")),
    ], mtime=2_000_000)
    _subagent(b, "agent-1", "a1", [_call("s1", _usage(out=100_000))])
    return d


def test_same_number_in_two_projects_is_kept_apart(tmp_path):
    rows, sessions = cr.collect([_ac1_fixture(tmp_path)], None)
    alpha, beta = ("alpha", "Issue-4"), ("beta", "Issue-4")
    assert set(rows) == {alpha, beta}
    assert _calls(rows, alpha) == 1
    assert sum(r.main for r in rows[alpha].values()) == 100
    assert sum(r.sub for r in rows[beta].values()) == 500_000
    assert sessions[alpha] == {"A"}
    assert sessions[beta] == {"B"}


def _one(tmp_path, records, name="s"):
    d = tmp_path / name
    _write(d / "s.jsonl", records)
    return d


def test_project_only_command_keeps_the_pair(tmp_path):
    _config(["weave"])
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "revision", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("catchup", "weave"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert set(rows) == {("revision", "Issue-4")}
    assert _calls(rows, ("revision", "Issue-4")) == 2


def test_switch_sets_project_and_issue_together(tmp_path):
    _config(["alpha", "beta"])
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("switch", "beta Issue-8"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert _calls(rows, ("beta", "Issue-8")) == 1
    assert _calls(rows, ("alpha", "Issue-4")) == 1
    # A dispatch is atomic too: it replaces a typed pair's project and issue together.
    rows, _ = cr.collect([_one(tmp_path, [
        _typed("impact", "alpha Issue-4"),
        _call("c3", _usage(inp=1)),
        *_dispatch("b2", "beta", "Issue-4", 9, "implement", "d2"),
        _call("c4", _usage(inp=1)),
    ], name="s2")], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 1
    assert _calls(rows, ("beta", "Issue-4")) == 1


def test_fresh_session_typed_project_and_issue(tmp_path):
    _config(["alpha"])
    rows, _ = cr.collect([_one(tmp_path, [_typed("impact", "alpha Issue-4"), _call("c1", _usage(inp=1))])], None)
    assert set(rows) == {("alpha", "Issue-4")}


def test_typed_issue_without_project_is_unattributed(tmp_path):
    rows, _ = cr.collect([_one(tmp_path, [_typed("draft", "Issue-4"), _call("c1", _usage(inp=1))])], None)
    assert set(rows) == {(NP, "Issue-4")}


def test_typed_issue_without_project_keeps_pair_only_for_the_same_issue(tmp_path):
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("draft", "Issue-4"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert set(rows) == {("alpha", "Issue-4")}
    assert _calls(rows, ("alpha", "Issue-4")) == 2
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("draft", "Issue-9"),
        _call("c2", _usage(inp=1)),
    ], name="s2")], None)
    assert _calls(rows, (NP, "Issue-9")) == 1
    assert ("alpha", "Issue-9") not in rows


def test_free_text_first_argument_is_not_a_project(tmp_path):
    rows, _ = cr.collect([_one(tmp_path, [_typed("draft", "fix Issue-4"), _call("c1", _usage(inp=1))])], None)
    assert set(rows) == {(NP, "Issue-4")}
    assert not any(k[0] == "fix" for k in rows)


def test_history_project_flag_moves_the_pair(tmp_path):
    _config(["alpha", "beta"])
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("history", "--project beta Issue-8"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert _calls(rows, ("beta", "Issue-8")) == 1
    assert _calls(rows, ("alpha", "Issue-4")) == 1


def test_known_projects_come_from_config_or_dispatch_headers(tmp_path, capsys):
    impact = [_typed("impact", "alpha Issue-4"), _call("c1", _usage(inp=1))]
    # Leg 1: config names alpha.
    _config(["alpha"])
    rows, _ = cr.collect([_one(tmp_path, impact, name="leg1")], None)
    assert set(rows) == {("alpha", "Issue-4")}
    # Leg 2: no config file: alpha is free text, and nothing errors.
    Path(os.environ["DA_HOME"], "config.toml").unlink()
    rows, _ = cr.collect([_one(tmp_path, impact, name="leg2")], None)
    assert set(rows) == {(NP, "Issue-4")}
    assert capsys.readouterr().err == ""
    # Leg 3: no config, but a LATER session's dispatch header names alpha.
    d = tmp_path / "leg3"
    _write(d / "impact.jsonl", impact, mtime=1_000_000)
    _write(d / "later.jsonl", [
        *_dispatch("b1", "alpha", "Issue-1", 9, "implement", "d1"),
        _call("c2", _usage(inp=1)),
    ], mtime=2_000_000)
    rows, _ = cr.collect([d], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 1
    assert (NP, "Issue-4") not in rows
    # Leg 4: a malformed config warns once and falls back to dispatch headers.
    Path(os.environ["DA_HOME"], "config.toml").write_text("[project.alpha\n", encoding="utf-8")
    capsys.readouterr()
    rows, _ = cr.collect([d], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 1
    err = capsys.readouterr().err
    assert err.startswith("cost-report: cannot read ") and err.count("\n") == 1


def test_unreadable_transcript_is_skipped_not_fatal(tmp_path):
    """A *.jsonl that cannot be opened (here a directory) is skipped with a warning; the rest still report."""
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    _write(root / "X" / "A.jsonl", [*_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"), _call("c1", _usage(inp=1))])
    (root / "Y" / "broken.jsonl").mkdir(parents=True)
    _write(root / "Y" / "B.jsonl", [_call("c2", _usage(inp=1))])
    (root / "Y" / "B" / "subagents" / "agent-bad.jsonl").mkdir(parents=True)   # #731: subagents are agent-*
    run = _cli("--project", "alpha", "--issue", "Issue-4", "--summary")
    assert run.returncode == 0, run.stderr
    assert _lines(run.stdout)[0].startswith("alpha/Issue-4: ")
    skipped = [line for line in run.stderr.splitlines() if line.startswith("cost-report: skipped ")]
    assert len(skipped) == 2 and any("broken.jsonl" in line for line in skipped)


def test_malformed_usage_or_input_is_skipped_not_fatal(tmp_path):
    """A non-object usage or tool input is skipped like any bad record; the calls around it still count."""
    bad_usage = _call("z1", _usage(inp=1))
    bad_usage["message"]["usage"] = "oops"
    bad_input = _call("z2", _usage(inp=1), {"type": "tool_use", "id": "t9", "name": "Bash", "input": ["x"]})
    bad_input["message"]["usage"] = ["oops"]
    d = _one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)), bad_usage, bad_input, _call("c2", _usage(inp=1)),
    ])
    _subagent(d / "s.jsonl", "agent-x", "nobody", [bad_usage, _call("s1", _usage(inp=1))])
    rows, _ = cr.collect([d], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 2
    assert rows[(NP, NI)][cr.NO_STEP].sub == 1.0


def test_known_project_shaped_like_an_issue_never_doubles_as_the_issue(tmp_path):
    _config(["alpha", "beta", "ml-2"])
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("impact", "ml-2 --project beta"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert set(rows) == {("alpha", "Issue-4")}


@pytest.mark.parametrize("args,message", [
    ((), "cost-report: no transcript dir; pass --transcripts ~/.claude/projects/<slug>"),
    (("--all-dirs",), "cost-report: no transcript dir under {root}"),
])
def test_cli_no_transcript_dir_messages(tmp_path, args, message):
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    run = _cli(*args)
    assert run.returncode == 2
    assert run.stderr.strip() == message.format(root=root)


def test_pull_without_origin_or_fork_sets_nothing(tmp_path):
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("pull", "7"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 2
    assert not any(k[1] == "Issue-7" for k in rows)


def test_project_match_is_exact_and_case_sensitive(tmp_path):
    _config(["revision"])
    rows, _ = cr.collect([_one(tmp_path, [_typed("impact", "reVision Issue-4"), _call("c1", _usage(inp=1))])], None)
    assert set(rows) == {(NP, "Issue-4")}


def test_calls_before_any_pair_are_no_project_no_issue(tmp_path):
    rows, _ = cr.collect([_one(tmp_path, [_call("c1", _usage(inp=1))])], None)
    assert set(rows) == {(NP, NI)}


def test_dispatch_call_is_charged_to_the_prior_pair(tmp_path):
    """Inverse guard: green at 846c19c on the issue part (preserved semantics)."""
    rows, _ = cr.collect([_one(tmp_path, [
        _call("m1", _usage(inp=1), _tool("b1", "Bash", command='bash "x/scripts/next.sh" alpha --auto')),
        _result("b1", "dispatch: alpha/Issue-4 — step 9 (implement), skill-backed"),
        _call("m2", _usage(inp=2)),
    ])], None)
    assert _per_issue(rows) == {NI: (1, 1.0, 0.0), "Issue-4": (1, 2.0, 0.0)}
    assert set(rows) == {(NP, NI), ("alpha", "Issue-4")}


def test_pull_with_trailing_argument_sets_nothing(tmp_path):
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed("pull", "beta origin 7 extra"),
        _call("c2", _usage(inp=1)),
    ])], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 2
    assert not any(k[1] == "Issue-7" for k in rows)


def test_unreadable_records_are_skipped(tmp_path):
    d = tmp_path / "s"
    d.mkdir()
    lines = [
        json.dumps(_call("c1", _usage(inp=1))),
        '["usage"]',                                  # valid JSON, not a dict
        '"tool_use"',                                 # valid JSON, not a dict
        "null",
        "[" * 100_000 + '"usage"',                    # deeper than the recursion limit
        json.dumps(_call("c2", _usage(inp=1))),
    ]
    (d / "s.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    rows, _ = cr.collect([d], None)
    assert _calls(rows, (NP, NI)) == 2


# Each case starts from dispatch alpha/Issue-4 (config: alpha, beta) and names the
# pair the call AFTER the typed command must be charged to. One must-trip and one
# must-not-trip case per shape found in the laptop-dad census (Task 4b).
REAL_SHAPES = [
    ("pull", "beta origin 7", ("beta", "Issue-7")),
    ("pull", "beta 7", ("alpha", "Issue-4")),
    ("pull", "beta fork 7", ("beta", "Issue-7")),
    ("pull", "beta upstream 7", ("alpha", "Issue-4")),
    ("resume", "beta Issue-8", ("beta", "Issue-8")),
    ("resume", "gamma Issue-8", (NP, "Issue-8")),
    ("resume", "Issue-9", (NP, "Issue-9")),
    ("resume", "Issue-4", ("alpha", "Issue-4")),
    ("revise", "beta Issue-8", ("beta", "Issue-8")),
    ("revise", "Issue-4", ("alpha", "Issue-4")),
    ("next", "beta --auto", ("alpha", "Issue-4")),
    ("next", "beta Issue-8 --auto", ("alpha", "Issue-4")),
    ("unstuck", "beta", ("alpha", "Issue-4")),
    ("unstuck", "beta Issue-8", ("beta", "Issue-8")),
    # Added from the 2026-11-07 laptop-dad census (analysis/2026-11-07-t4b-transcript-shape-run.txt).
    ("pull", "gamma origin 7", ("gamma", "Issue-7")),      # a pull's project need not be known
    ("pull", "beta", ("alpha", "Issue-4")),
    ("next", "beta origin 7", ("alpha", "Issue-4")),
    ("next", "beta 7 --auto", ("alpha", "Issue-4")),
    ("where", "beta", ("alpha", "Issue-4")),
    ("sync", "beta", ("alpha", "Issue-4")),
    ("park", "beta Issue-8", ("beta", "Issue-8")),
    ("park", "beta 8", ("alpha", "Issue-4")),             # a bare number is not ISSUE_TOKEN (deferred)
    ("resume", "beta 8", ("alpha", "Issue-4")),
    ("unstuck", "beta 8", ("alpha", "Issue-4")),
    ("wbs", "update beta", ("alpha", "Issue-4")),         # a known project only as a later argument
    ("ship", "", ("alpha", "Issue-4")),
]


@pytest.mark.parametrize("cmd,args,expected", REAL_SHAPES, ids=[f"{c} {a}" for c, a, _ in REAL_SHAPES])
def test_real_typed_shapes(tmp_path, cmd, args, expected):
    _config(["alpha", "beta"])
    prior = ("alpha", "Issue-4")
    rows, _ = cr.collect([_one(tmp_path, [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
        _typed(cmd, args),
        _call("c2", _usage(inp=1)),
    ])], None)
    if expected == prior:
        assert set(rows) == {prior}
        assert _calls(rows, prior) == 2
    else:
        assert set(rows) == {prior, expected}
        assert _calls(rows, prior) == 1
        assert _calls(rows, expected) == 1


# --- Task 3: CLI, filters, transcript dirs ----------------------------------

def _lines(text):
    return [line for line in text.splitlines() if line]


def test_cli_project_filter_reports_one_project(tmp_path):
    d = _ac1_fixture(tmp_path)
    run = _cli("--transcripts", d, "--project", "alpha", "--issue", "Issue-4", "--summary")
    assert run.returncode == 0, run.stderr
    out = _lines(run.stdout)
    assert len(out) == 1
    assert out[0].startswith("alpha/Issue-4: ")
    assert "over 1 session(s)" in out[0]
    run = _cli("--transcripts", d, "--project", "beta", "--issue", "Issue-4", "--summary")
    assert run.returncode == 0, run.stderr
    out = _lines(run.stdout)
    assert len(out) == 1
    assert out[0].startswith("beta/Issue-4: ")
    assert "subagents 0.5M" in out[0]


def test_cli_without_project_prints_one_line_per_pair(tmp_path):
    run = _cli("--transcripts", _ac1_fixture(tmp_path), "--issue", "Issue-4", "--summary")
    assert run.returncode == 0, run.stderr
    out = _lines(run.stdout)
    assert len(out) == 2
    assert {line.split(": ", 1)[0] for line in out} == {"alpha/Issue-4", "beta/Issue-4"}


def _alpha_session(d, mtime=1_000_000):
    _write(d / "A.jsonl", [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("am1", _usage(inp=100)),
    ], mtime=mtime)


def _draft_session(d, mtime=2_000_000):
    _write(d / "C.jsonl", [_typed("draft", "Issue-4"), _call("cm1", _usage(inp=30))], mtime=mtime)


def test_cli_unattributed_side_line_and_hint(tmp_path):
    both = tmp_path / "both"
    _alpha_session(both)
    _draft_session(both)
    run = _cli("--transcripts", both, "--project", "alpha", "--issue", "Issue-4", "--summary")
    assert run.returncode == 0, run.stderr
    out = _lines(run.stdout)
    assert len(out) == 2
    assert out[0].startswith("alpha/Issue-4: ")
    assert out[1].startswith("(no project)/Issue-4: ")

    only = tmp_path / "only"
    _draft_session(only)
    run = _cli("--transcripts", only, "--project", "alpha", "--issue", "Issue-4", "--summary")
    assert run.returncode == 1
    assert run.stdout == ""
    err = _lines(run.stderr)
    assert len(err) == 2
    assert err[0] == "cost-report: no calls attributed to alpha/Issue-4"
    assert err[1].startswith("cost-report: hint: (no project)/Issue-4: ")

    empty = tmp_path / "empty"
    empty.mkdir()
    run = _cli("--transcripts", empty, "--project", "alpha", "--issue", "Issue-4", "--summary")
    assert run.returncode == 1
    assert "cost-report: no calls attributed to alpha/Issue-4" in run.stderr
    assert "hint:" not in run.stderr


def test_cli_project_without_issue_hides_unattributed_rows(tmp_path):
    d = tmp_path / "mixed"
    _alpha_session(d)
    _draft_session(d)
    _write(d / "E.jsonl", [_call("em1", _usage(inp=1))], mtime=3_000_000)
    run = _cli("--transcripts", d, "--project", "alpha", "--summary")
    assert run.returncode == 0, run.stderr
    out = _lines(run.stdout)
    assert out
    assert all(line.startswith("alpha/") for line in out)
    run = _cli("--transcripts", d, "--project", "nobody", "--summary")
    assert run.returncode == 1
    assert run.stderr.strip() == "cost-report: no calls attributed to project nobody"


def test_cli_project_scans_every_transcript_dir(tmp_path):
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    slug = _cwd_slug()
    for name, sess in ((slug, "A"), ("Y", "B")):
        _write(root / name / f"{sess}.jsonl", [
            *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
            _call(f"{sess}m1", _usage(inp=10)),
        ])
    y = root / "Y"

    def sessions_of(*args):
        run = _cli(*args)
        assert run.returncode == 0, (args, run.stderr)
        m = re.search(r"over (\d+) session\(s\)", run.stdout)
        assert m, (args, run.stdout)
        return int(m.group(1))

    assert sessions_of("--project", "alpha", "--issue", "Issue-4", "--summary") == 2
    assert sessions_of("--issue", "Issue-4", "--summary") == 1
    assert sessions_of("--all-dirs", "--issue", "Issue-4", "--summary") == 2
    assert sessions_of("--transcripts", y, "--project", "alpha") == 1
    assert sessions_of("--all-dirs", "--transcripts", y, "--issue", "Issue-4", "--summary") == 1
    assert sessions_of("--all-dirs", "--project", "alpha", "--issue", "Issue-4", "--summary") == 2


def test_cli_rejects_empty_project(tmp_path):
    run = _cli("--transcripts", _ac1_fixture(tmp_path), "--project", "", "--summary")
    assert run.returncode == 2
    assert run.stdout == ""
    assert "argument --project" in run.stderr


def test_default_dirs_matches_the_cwd_slug_case_insensitively(tmp_path):
    """Preservation guard for the sibling lanes importer (inverse born-red)."""
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    slug = _cwd_slug()
    (root / slug).mkdir(parents=True)
    result = cr.default_dirs()
    assert isinstance(result, list)
    assert set(result) == {root / slug}
    # Flip the first LETTER: a POSIX slug starts with '-', which has no case.
    i = next(n for n, ch in enumerate(slug) if ch.isalpha())
    flipped = slug[:i] + slug[i].swapcase() + slug[i + 1:]
    if os.path.normcase(flipped) == os.path.normcase(slug):
        pytest.skip("case-insensitive filesystem: the case-flip leg cannot be built")
    try:
        (root / flipped).mkdir()
    except FileExistsError:
        pytest.skip("case-insensitive filesystem: the case-flip leg cannot be built")
    result = cr.default_dirs()
    assert isinstance(result, list)
    assert set(result) == {root / slug, root / flipped}


def test_cli_every_line_names_its_pair(tmp_path):
    d = tmp_path / "s"
    _write(d / "s.jsonl", [
        _call("c0", _usage(inp=1)),
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("c1", _usage(inp=1)),
    ])
    run = _cli("--transcripts", d, "--summary")
    assert run.returncode == 0, run.stderr
    out = _lines(run.stdout)
    assert len(out) == 2
    assert any(line.startswith("(no project)/(no issue): ") for line in out)
    assert any(line.startswith("alpha/Issue-4: ") for line in out)


# --- Task 4: memory (AC13) --------------------------------------------------

FILLER = "x" * 65536


def _big_session(path, mb, filler=FILLER, stamp=False):
    """Stream a transcript of about `mb` MB to `path`; return the number of counted calls.

    stamp=True gives every record a timestamp (+1 s per record) and a uuid (#733).
    """
    target = mb * 2**20
    blocks = 0
    n = itertools.count()

    def put(f, r):
        if stamp:
            r = _at(r, next(n) / 60)
        f.write(json.dumps(r) + "\n")

    with open(path, "w", encoding="utf-8") as f:
        for r in _dispatch("b0", "alpha", "Issue-4", 9, "implement", "d0"):
            put(f, r)
        while f.tell() < target:
            tools = [_tool(f"k{blocks}", "Skill", skill="devagent:quality")] if blocks % 16 == 0 else []
            put(f, _call(f"m{blocks}", _usage(read=1), *tools))
            put(f, _result(f"r{blocks}", filler))
            blocks += 1
    return blocks


def test_memory_does_not_grow_with_transcript_size(tmp_path):
    mb = int(os.environ.get("DEVAGENT_COST_REPORT_MEMORY_MB", "32"))
    d = tmp_path / "big"
    d.mkdir()
    path = d / "big.jsonl"
    try:
        blocks = _big_session(path, mb)
        size = path.stat().st_size
        tracemalloc.start()
        try:
            rows, _ = cr.collect([d], None)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        print(f"memory: {mb} MB requested, {size} bytes, {blocks} calls, peak {peak} bytes")
        assert peak < 200 * 2**20
        assert peak < size / 4
        assert _calls(rows, ("alpha", "Issue-4")) == blocks
    finally:
        path.unlink(missing_ok=True)


# --- Issue-731: archive reader, global dedupe, sessions, workflow agents, --json --

def _gz(path, records, members=2, mtime=None):
    """Write records as a .jsonl.gz of `members` gzip members (the archiver's append shape)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(r) + "\n" for r in records]
    cut = max(1, len(lines) // members) if members > 1 else len(lines)
    chunks = [lines[:cut], lines[cut:]] if members > 1 else [lines]
    with open(path, "wb") as f:
        for chunk in chunks:
            f.write(gzip.compress("".join(chunk).encode("utf-8"), mtime=0))
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def _sid(records, sid):
    """Stamp every record with Claude Code's sessionId field."""
    return [{**r, "sessionId": sid} for r in records]


def _pair_records(project, issue, mid, inp=10, tid="b1"):
    return [*_dispatch(tid, project, issue, 9, "implement", "d" + mid), _call(mid, _usage(inp=inp))]


def _rows_equal(a, b):
    def flat(rows):
        return {k: {s: (r.calls, r.peak, r.main, r.sub) for s, r in v.items()} for k, v in rows.items()}
    return flat(a) == flat(b)


def test_gz_session_reads_like_jsonl(tmp_path):
    recs = [*_pair_records("alpha", "Issue-4", "m1"), _call("m2", _usage(read=50)), _call("m3", _usage(out=2))]
    _write(tmp_path / "plain" / "S.jsonl", recs)
    _gz(tmp_path / "gz" / "S.jsonl.gz", recs)
    a, sa = cr.collect([tmp_path / "plain"], None)
    b, sb = cr.collect([tmp_path / "gz"], None)
    assert a and _rows_equal(a, b)
    assert sa == sb


def _gz_session_with_agent(d, name):
    _gz(d / name, [*_pair_records("alpha", "Issue-4", "m1"),
                   _call("m2", _usage(inp=1), _tool("a1", "Agent", description="x"))])
    _gz(d / "S" / "subagents" / "agent-a.jsonl.gz", [_call("s1", _usage(out=10))], members=1)
    (d / "S" / "subagents" / "agent-a.meta.json").write_text(json.dumps({"toolUseId": "a1"}), encoding="utf-8")


def test_gz_subagent_is_found_beside_gz_session(tmp_path):
    _gz_session_with_agent(tmp_path / "gz", "S.jsonl.gz")
    rows, _ = cr.collect([tmp_path / "gz"], None)
    assert rows[("alpha", "Issue-4")]["implement"].sub == 50


def test_diverged_copy_reads_the_session_subagents(tmp_path):
    _gz_session_with_agent(tmp_path / "gz", "S.ab12cd.jsonl.gz")
    rows, _ = cr.collect([tmp_path / "gz"], None)
    assert rows[("alpha", "Issue-4")]["implement"].sub == 50


def test_message_id_counted_once_across_files(tmp_path):
    recs = _pair_records("alpha", "Issue-4", "m1", inp=7)
    _write(tmp_path / "x" / "S1.jsonl", recs, mtime=1_000_000)
    _write(tmp_path / "y" / "S2.jsonl", recs, mtime=2_000_000)
    rows, _ = cr.collect([tmp_path / "x", tmp_path / "y"], None)
    assert _calls(rows, ("alpha", "Issue-4")) == 1
    assert sum(r.main for r in rows[("alpha", "Issue-4")].values()) == 7


def test_subagent_message_id_counted_once_across_files(tmp_path):
    for name, mt in (("x", 1_000_000), ("y", 2_000_000)):
        s = tmp_path / name / "S.jsonl"
        _write(s, [*_pair_records("alpha", "Issue-4", "m1"),
                   _call("m2", _usage(inp=1), _tool("a1", "Agent", description="x"))], mtime=mt)
        # Two usages for one id within the file: the LAST wins (out=10 -> 50).
        _subagent(s, "agent-a", "a1", [_call("s1", _usage(out=1)), _call("s1", _usage(out=10))])
    rows, _ = cr.collect([tmp_path / "x", tmp_path / "y"], None)
    assert sum(r.sub for r in rows[("alpha", "Issue-4")].values()) == 50


def test_sessions_counted_by_session_id(tmp_path):
    recs = _sid(_pair_records("alpha", "Issue-4", "m1"), "S")
    _write(tmp_path / "x" / "S.jsonl", recs, mtime=1_000_000)
    _gz(tmp_path / "y" / "S.ab12cd.jsonl.gz", recs + _sid([_call("m9", _usage(inp=1))], "S"), mtime=2_000_000)
    # A copy under another file name (a stem that is not the session) is the same session.
    _write(tmp_path / "w" / "S-copy.jsonl", recs + _sid([_call("m8", _usage(inp=1))], "S"), mtime=3_000_000)
    _, sessions = cr.collect([tmp_path / "x", tmp_path / "y", tmp_path / "w"], None)
    assert sessions[("alpha", "Issue-4")] == {"S"}
    # No sessionId: the session key (the name before the first '.').
    _write(tmp_path / "z" / "T.jsonl", _pair_records("beta", "Issue-5", "n1"))
    _, sessions = cr.collect([tmp_path / "z"], None)
    assert sessions[("beta", "Issue-5")] == {"T"}


WF = "wf_1a2b3c4d-5e6"


def _workflow_session(d, gz, run_id=WF, stamp=False):
    """stamp=True (#733): main records at minutes 0-5, the agent's two calls at 4 and 5."""
    main = _sid([
        *_pair_records("alpha", "Issue-4", "m1"),
        _call("m2", _usage(inp=1), _tool("w1", "Workflow", script="x")),
        _result("w1", f"Workflow started.\nRun ID: {run_id}\nTask: t1"),
        _call("m3", _usage(inp=1)),
    ], "S")
    wdir = d / "S" / "subagents" / "workflows" / WF
    agent = [_call("w-1", _usage(out=20)), _call("w-2", _usage(out=2))]
    if stamp:
        main = [_at(r, i) for i, r in enumerate(main)]
        agent = [_at(r, 4 + i) for i, r in enumerate(agent)]
    journal = [{"type": "assistant", "message": {"id": "j1", "usage": _usage(out=1000)}}]
    if gz:
        _gz(d / "S.jsonl.gz", main)
        _gz(wdir / "agent-w.jsonl.gz", agent, members=1)
        _gz(wdir / "journal.jsonl.gz", journal, members=1)
    else:
        _write(d / "S.jsonl", main)
        _write(wdir / "agent-w.jsonl", agent)
        _write(wdir / "journal.jsonl", journal)
    (wdir / "agent-w.meta.json").write_text(json.dumps({"agentType": "general-purpose"}), encoding="utf-8")


@pytest.mark.parametrize("gz", [False, True], ids=["live", "gz"])
def test_workflow_agent_counted_under_its_session(tmp_path, gz):
    d = tmp_path / "d"
    _workflow_session(d, gz)
    rows, sessions = cr.collect([d], None)
    p = ("alpha", "Issue-4")
    assert rows[p]["implement"].sub == 110
    assert sum(r.sub for steps in rows.values() for r in steps.values()) == 110
    assert sessions[p] == {"S"}
    # No matching Run ID: the agent falls to (no project)/(no issue).
    d2 = tmp_path / "d2"
    _workflow_session(d2, gz, run_id="wf_00000000-000")
    rows, _ = cr.collect([d2], None)
    assert rows[(NP, NI)][cr.NO_STEP].sub == 110
    assert sum(r.sub for r in rows[("alpha", "Issue-4")].values()) == 0


def test_journal_jsonl_is_not_counted(tmp_path):
    d = tmp_path / "d"
    _workflow_session(d, gz=False)
    rows, _ = cr.collect([d], None)
    assert sum(r.sub for steps in rows.values() for r in steps.values()) == 110   # not 110 + 5000


def test_torn_gz_keeps_the_lines_before_the_tear(tmp_path):
    d = tmp_path / "gz"
    recs = [*_pair_records("alpha", "Issue-4", "m1")] + [_call(f"c{i}", _usage(inp=1)) for i in range(40)]
    p = d / "S.jsonl.gz"
    _gz(p, recs)
    p.write_bytes(p.read_bytes()[:-10])
    run = _cli("--transcripts", d, "--summary")
    assert run.returncode == 0, run.stderr
    m = re.search(r"(\d+) calls", run.stdout)
    assert m and 20 <= int(m.group(1)) < 41
    err = run.stderr.splitlines()
    assert len(err) == 1 and err[0].startswith(f"cost-report: truncated {p} (")


def test_equal_mtimes_order_by_session_key(tmp_path):
    _write(tmp_path / "x" / "B.jsonl", _pair_records("beta", "Issue-2", "b1"), mtime=1_000_000)
    _write(tmp_path / "y" / "A.jsonl", _pair_records("alpha", "Issue-1", "a1"), mtime=1_000_000)
    rows, _ = cr.collect([tmp_path / "x", tmp_path / "y"], None)
    assert list(rows) == [("alpha", "Issue-1"), ("beta", "Issue-2")]


def test_cli_archive_reads_every_host_and_cwd_partition(tmp_path):
    a = tmp_path / "store"
    _gz(a / "h1" / "x" / "S1.jsonl.gz", _pair_records("alpha", "Issue-1", "a1"))
    _gz(a / "h2" / "y" / "S2.jsonl.gz", _pair_records("beta", "Issue-2", "b1"))
    (a / "h1" / "manifest.jsonl").write_text("{}\n", encoding="utf-8")
    (a / "h1" / "last-run").write_text("2026-11-07T00:00:00Z\n", encoding="utf-8")
    run = _cli("--archive", a, "--summary")
    assert run.returncode == 0, run.stderr
    assert {ln.split(": ", 1)[0] for ln in _lines(run.stdout)} == {"alpha/Issue-1", "beta/Issue-2"}


@pytest.mark.parametrize("extra,live_seen", [
    ((), False), (("--all-dirs",), True), (("--project", "live"), True), (("--transcripts", "LIVE"), True),
], ids=["alone", "all-dirs", "project", "transcripts"])
def test_cli_archive_flag_grammar(tmp_path, extra, live_seen):
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    _write(root / _cwd_slug() / "L.jsonl", _pair_records("live", "Issue-9", "l1"))
    a = tmp_path / "store"
    _gz(a / "h1" / "x" / "S1.jsonl.gz", _pair_records("live", "Issue-1", "a1"))
    args = [str(root / _cwd_slug()) if x == "LIVE" else x for x in extra]
    run = _cli("--archive", a, *args, "--summary")
    assert run.returncode == 0, run.stderr
    heads = {ln.split(": ", 1)[0] for ln in _lines(run.stdout)}
    assert "live/Issue-1" in heads
    assert ("live/Issue-9" in heads) is live_seen


def test_cli_archive_missing_or_empty(tmp_path):
    missing = tmp_path / "nope"
    run = _cli("--archive", missing, "--summary")
    assert run.returncode == 2
    assert run.stderr.strip() == f"cost-report: no archive dir {missing}"
    empty = tmp_path / "empty"
    empty.mkdir()
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    run = _cli("--archive", empty, "--summary")
    assert run.returncode == 2
    assert run.stderr.strip() == f"cost-report: no transcript dir under {root} or archive {empty}"


JSON_KEYS = {"calls", "issue", "main", "peak_context", "project", "sessions", "sources", "subagents", "total"}


def test_cli_json_shape(tmp_path):
    d = _ac1_fixture(tmp_path)
    run = _cli("--transcripts", d, "--json")
    assert run.returncode == 0, run.stderr
    objs = [json.loads(ln) for ln in _lines(run.stdout)]
    assert len(objs) == 2
    rows, sessions = cr.collect([d], None)
    for o in objs:
        assert set(o) == JSON_KEYS
        steps = rows[(o["project"], o["issue"])]
        main = sum(r.main for r in steps.values())
        sub = sum(r.sub for r in steps.values())
        assert o["calls"] == sum(r.calls for r in steps.values())
        assert o["main"] == round(main, 2) and o["subagents"] == round(sub, 2)
        assert o["total"] == round(main + sub, 2)
        assert o["peak_context"] == max(r.peak for r in steps.values())
        assert o["sessions"] == len(sessions[(o["project"], o["issue"])])
        assert all(set(s) == {"cwd_slug", "host", "session"} and s["host"] == "local" for s in o["sources"])
    assert list(json.loads(_lines(run.stdout)[0])) == sorted(JSON_KEYS)
    assert _cli("--transcripts", d, "--json").stdout == run.stdout   # byte-identical reruns
    bad = _cli("--transcripts", d, "--json", "--summary")
    assert bad.returncode == 2


def test_cli_json_lists_sources_once_per_host(tmp_path):
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    recs = _sid(_pair_records("alpha", "Issue-4", "m1", inp=3), "S")
    _write(root / "c--src-x" / "S.jsonl", recs, mtime=1_000_000)
    a = tmp_path / "store"
    for h in ("h1", "h2"):
        _gz(a / h / "c--src-x" / "S.jsonl.gz", recs, mtime=1_000_000)
    run = _cli("--archive", a, "--all-dirs", "--json")
    assert run.returncode == 0, run.stderr
    (o,) = [json.loads(ln) for ln in _lines(run.stdout)]
    assert o["calls"] == 1 and o["main"] == 3 and o["sessions"] == 1
    assert o["sources"] == [{"cwd_slug": "c--src-x", "host": h, "session": "S"} for h in ("h1", "h2", "local")]


# --- Issue-733: agent time and operator time (--time) ------------------------
# Every expected figure below is hand-computed from the fixture's minute offsets
# (pothole L199): none is derived by calling cr.

T0 = datetime(2026, 10, 1, tzinfo=timezone.utc)
_UIDS = itertools.count(1)


def _at(rec, minutes, uid=None):
    """A copy of rec stamped T0 + minutes (millisecond Z form) with a uuid (default: the next counter value)."""
    ts = (T0 + timedelta(seconds=round(minutes * 60, 3))).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {**rec, "timestamp": ts, "uuid": uid or str(uuid.UUID(int=next(_UIDS)))}


def _str(text, **extra):
    """A user record whose content is a plain string and which has no origin."""
    return {"type": "user", "message": {"role": "user", "content": text}, **extra}


def _human(text):
    return _str(text, origin={"kind": "human"})


def _notify(tid=None):
    body = "<task-notification>\n" + (f"<tool-use-id>{tid}</tool-use-id>\n" if tid else "") + "<status>completed</status>\n</task-notification>"
    return _str(body, origin={"kind": "task-notification"})


def _peer():
    return _str("a message from another session", origin={"kind": "peer"})


def _perm(tid, source):
    return {**_result(tid, "ok"), "permissionDecision": {"decision": "accept", "source": source}}


def _end(mid, usage=None):
    return {"type": "assistant", "message": {"id": mid, "usage": usage, "stop_reason": "end_turn",
                                             "content": [{"type": "text", "text": "done"}]}}


def _attach():
    return {"type": "attachment", "attachment": {"type": "edited_text_file"}}


def _queue(op):
    return {"type": "queue-operation", "operation": op}


def _times(dirs, **rules):
    """{pair: TimeAcc} for dirs under the given rules (seconds; defaults 300 / 3600 / 900)."""
    out = {}
    cr.collect(list(dirs), None, timing=cr.TimeRules(**rules), times=out)
    return out


def _tv(acc):
    """A TimeAcc's figures: (wall, busy, operator, events, returns, fallback)."""
    return (acc.wall(), acc.busy, acc.operator, acc.events, acc.returns, acc.fallback)


def _timed(tmp_path, records, name="t", **rules):
    """Write one stamped session and return the (no project)/(no issue) TimeAcc."""
    d = _one(tmp_path, records, name=name)
    return _times([d], **rules)[(NP, NI)]


def _time_records():
    """The main session and its one subagent for _time_fixture, stamped at these minutes:

    main  0 next.sh call (no usage)   1 dispatch alpha/Issue-4 (charged to START)
          2 m1 end_turn               5 human (operator 180)
          6 m2 calls Bash t1          8 user_temporary permission for t1 (operator 120)
          9 m3 launches Agent a1     10 a1's result (linked: a subagent file exists)
         11 m4                       14 m5 end_turn (a 3-min non-tool interval: busy at idle_gap 5, not 2)
         15 task-notification        16 peer
         17 m6 end_turn              18 attachment, queue-operation (skipped)
         19 no-origin string (fallback; operator 120)   20 m7 end_turn
         23 typed pull beta origin 5 (operator 180, still alpha)
         24 m8 end_turn (beta)      100 human (beta: a return after absence)   101 m9 end_turn
    agent 9 plain-string prompt     10 s1 end_turn

    Default rules: alpha busy 720 (main 660 + agent 60), wall 720, operator 600,
    4 events, 0 returns, 1 fallback; beta busy 120, wall 120, operator 0, 1 event,
    1 return, 0 fallback. At idle_gap 2 min alpha's wall and busy are 540.
    """
    main = [
        _at(_call("d1", None, _tool("b1", "Bash", command='bash "x/scripts/next.sh" alpha --auto')), 0),
        _at(_result("b1", "dispatch: alpha/Issue-4 — step 9 (implement), skill-backed"), 1),
        _at(_end("m1", _usage(inp=100)), 2),
        _at(_human("please continue"), 5),
        _at(_call("m2", _usage(inp=10), _tool("t1", "Bash", command="ls")), 6),
        _at(_perm("t1", "user_temporary"), 8),
        _at(_call("m3", _usage(inp=10), _tool("a1", "Agent", description="x")), 9),
        _at(_result("a1", "agent finished"), 10),
        _at(_call("m4", _usage(inp=10)), 11),
        _at(_end("m5", _usage(inp=1)), 14),
        _at(_notify(), 15),
        _at(_peer(), 16),
        _at(_end("m6", _usage(inp=1)), 17),
        _at(_attach(), 18),
        _at(_queue("enqueue"), 18),
        _at(_str("fix the typo"), 19),
        _at(_end("m7", _usage(inp=1)), 20),
        _at({**_typed("pull", "beta origin 5"), "origin": {"kind": "human"}}, 23),
        _at(_end("m8", _usage(inp=7)), 24),
        _at(_human("back again"), 100),
        _at(_end("m9", _usage(inp=3)), 101),
    ]
    agent = [_at(_str("do the thing"), 9), _at(_end("s1", _usage(out=10)), 10)]
    return main, agent


def _time_fixture(d, gz=False):
    """Write _time_records() to d/S.jsonl (or .jsonl.gz) with agent-x linked to a1; return d."""
    main, agent = _time_records()
    sub = d / "S" / "subagents" / "agent-x.jsonl"
    if gz:
        _gz(d / "S.jsonl.gz", main)
        _gz(sub.with_name("agent-x.jsonl.gz"), agent, members=1)
    else:
        _write(d / "S.jsonl", main)
        _write(sub, agent)
    sub.with_name("agent-x.meta.json").write_text(json.dumps({"toolUseId": "a1"}), encoding="utf-8")
    return d


# Task 2: captured on the unfixed tree (b9475f8's cost-report.py) by
# analysis/2026-11-08-t1-golden-green-at-head.txt; never from new code.
GOLDEN_FULL = (
    "Token cost by step, from <DIR>\n"
    "input-token equivalents, weighted by price vs base input: cache read 0.1, cache write 1.25 (5m) / 2 (1h), output 5\n"
    "\n"
    "alpha/Issue-4: 0.0M input-token equivalents over 1 session(s), 7 calls, peak context 0K (main 0.0M, subagents 0.0M)\n"
    "  step                   calls  peak ctx   main M   sub M  total M  share\n"
    "  implement                  7        0K     0.00    0.00     0.00   100%\n"
    "\n"
    "beta/Issue-5: 0.0M input-token equivalents over 1 session(s), 2 calls, peak context 0K (main 0.0M, subagents 0.0M)\n"
    "  step                   calls  peak ctx   main M   sub M  total M  share\n"
    "  pull                       2        0K     0.00    0.00     0.00   100%\n"
)
GOLDEN_SUMMARY = (
    "alpha/Issue-4: 0.0M input-token equivalents over 1 session(s), 7 calls, peak context 0K (main 0.0M, subagents 0.0M)\n"
    "beta/Issue-5: 0.0M input-token equivalents over 1 session(s), 2 calls, peak context 0K (main 0.0M, subagents 0.0M)\n"
)
GOLDEN_JSON = (
    '{"calls": 7, "issue": "Issue-4", "main": 133.0, "peak_context": 100, "project": "alpha", "sessions": 1, '
    '"sources": [{"cwd_slug": "timefix", "host": "local", "session": "S"}], "subagents": 50.0, "total": 183.0}\n'
    '{"calls": 2, "issue": "Issue-5", "main": 10.0, "peak_context": 7, "project": "beta", "sessions": 1, '
    '"sources": [{"cwd_slug": "timefix", "host": "local", "session": "S"}], "subagents": 0.0, "total": 10.0}\n'
)


def test_cli_output_without_time_is_unchanged(tmp_path):
    d = _time_fixture(tmp_path / "timefix")
    full = _cli("--transcripts", d)
    summary = _cli("--transcripts", d, "--summary")
    js = _cli("--transcripts", d, "--json")
    assert (full.returncode, summary.returncode, js.returncode) == (0, 0, 0)
    assert full.stdout.replace(str(d), "<DIR>") == GOLDEN_FULL
    assert summary.stdout == GOLDEN_SUMMARY
    assert js.stdout == GOLDEN_JSON


# Task 3: one test per rule AC (defaults 5 / 60 / 15 min).

def _bash(mid, tid):
    return _call(mid, None, _tool(tid, "Bash", command="x"))


def _agent(mid, tid):
    return _call(mid, None, _tool(tid, "Agent", description="x"))


@pytest.mark.parametrize("gap,busy", [(4, 240), (6, 0)])
def test_time_idle_gap_is_all_or_nothing(tmp_path, gap, busy):
    acc = _timed(tmp_path, [_at(_call("c1", None), 0), _at(_call("c2", None), gap)])
    assert acc.busy == busy and acc.wall() == busy


@pytest.mark.parametrize("gap,busy", [(50, 3000), (70, 0)])
def test_time_tool_wait_bounded_by_tool_gap(tmp_path, gap, busy):
    acc = _timed(tmp_path, [_at(_bash("c1", "t1"), 0), _at(_result("t1", "ok"), gap)])
    assert acc.busy == busy and acc.wall() == busy


def test_time_task_notification_wait_is_busy(tmp_path):
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_notify(), 40)])
    assert acc.busy == 2400 and acc.events == 0


def test_time_gap_ending_in_human_message_is_not_agent_time(tmp_path):
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_human("go on"), 3)])
    assert acc.busy == 0 and acc.wall() == 0
    assert (acc.operator, acc.events, acc.returns) == (180, 1, 0)


def test_time_attachment_does_not_split_interval(tmp_path):
    acc = _timed(tmp_path, [
        _at(_bash("c1", "t1"), 0), _at(_attach(), 4), _at(_queue("enqueue"), 5), _at(_result("t1", "ok"), 50),
    ])
    assert acc.busy == 3000


def test_time_parallel_subagents_wall_10_busy_20(tmp_path):
    d = _one(tmp_path, [
        _at(_agent("c1", "a1"), 0), _at(_agent("c2", "a2"), 0),
        _at(_result("a1", "done"), 10), _at(_result("a2", "done"), 10),
    ])
    for name, tid in (("agent-a", "a1"), ("agent-b", "a2")):
        _subagent(d / "s.jsonl", name, tid,
                  [_at(_str("go"), 0)] + [_at(_call(f"{name}-{m}", None), m) for m in (2, 4, 6, 8, 10)])
    acc = _times([d])[(NP, NI)]
    assert acc.wall() == 600
    assert acc.busy == 1200


def test_time_operator_latency_charged_to_prior_pair(tmp_path):
    d = _one(tmp_path, [
        *(_at(r, m) for r, m in zip(_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"), (0, 1))),
        _at(_end("e1", _usage(inp=1)), 10),
        _at(_human("<command-name>/devagent:pull</command-name>\n<command-args>beta origin 5</command-args>"), 13),
        _at(_end("e2", _usage(inp=1)), 14),
    ])
    times = {}
    rows, _ = cr.collect([d], None, timing=cr.TimeRules(), times=times)
    alpha, beta = times[("alpha", "Issue-4")], times[("beta", "Issue-5")]
    assert (alpha.operator, alpha.events) == (180, 1)
    assert (beta.operator, beta.events, beta.busy) == (0, 0, 60)
    assert ("beta", "Issue-5") in rows


def test_time_return_after_absence_adds_zero(tmp_path):
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_human("back"), 120)])
    assert (acc.operator, acc.events, acc.returns) == (0, 1, 1)


def test_time_task_notification_and_peer_are_not_operator_events(tmp_path):
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_notify(), 3), _at(_peer(), 4)])
    assert (acc.events, acc.operator, acc.returns, acc.fallback) == (0, 0, 0, 0)


@pytest.mark.parametrize("gap,busy", [(20, 0), (4, 240)])
def test_time_peer_after_end_turn_is_idle_rule(tmp_path, gap, busy):
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_peer(), gap)])
    assert acc.busy == busy and acc.events == 0


@pytest.mark.parametrize("source,events,operator,busy", [("user_temporary", 1, 120, 0), ("config", 0, 0, 120)])
def test_time_user_temporary_permission_is_operator_event(tmp_path, source, events, operator, busy):
    acc = _timed(tmp_path, [_at(_bash("c1", "t1"), 0), _at(_perm("t1", source), 2)])
    assert (acc.events, acc.operator, acc.busy) == (events, operator, busy)


INTERRUPT = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}}


def test_time_fallback_classifies_no_origin_main_record(tmp_path):
    # Must trip: a typed plain string after an end_turn counts its latency.
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_str("fix the typo"), 2)], name="a")
    assert (acc.events, acc.fallback, acc.operator) == (1, 1, 120)
    # Must trip: an interrupt mid-turn (after a tool_use record) is an event with 0 latency.
    acc = _timed(tmp_path, [_at(_bash("c1", "t1"), 0), _at(INTERRUPT, 1)], name="b")
    assert (acc.events, acc.fallback, acc.operator) == (1, 1, 0)
    # Must trip: a no-origin typed command.
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_typed("where", "alpha"), 2)], name="c")
    assert (acc.events, acc.fallback, acc.operator) == (1, 1, 120)
    # Must not trip (pothole L135): client-injected and agent-to-agent strings.
    acc = _timed(tmp_path, [
        _at(_end("e1"), 0),
        _at(_str("<task-notification>\n<status>completed</status>\n</task-notification>"), 1),
        _at(_str("Another Claude session sent a message"), 2),
        _at(_str("<local-command-caveat>Caveat: the messages below were generated locally</local-command-caveat>"), 3),
        _at(_str("<local-command-stdout>ok</local-command-stdout>"), 4),
        _at(_str("This session is being continued from a previous conversation.", isCompactSummary=True), 5),
        _at(_str("shown in the transcript only", isVisibleInTranscriptOnly=True), 6),
        _at(_str("Caveat: meta", isMeta=True), 7),
    ], name="d")
    assert (acc.events, acc.fallback, acc.operator) == (0, 0, 0)


def test_time_subagent_prompt_is_no_operator_event(tmp_path):
    d = _one(tmp_path, [_at(_agent("c1", "a1"), 0), _at(_result("a1", "done"), 1)])
    _subagent(d / "s.jsonl", "agent-a", "a1", [_at(_str("do x"), 0), _at(_end("s1"), 2)])
    acc = _times([d])[(NP, NI)]
    assert (acc.events, acc.fallback) == (0, 0)
    assert acc.busy == 120


def test_time_queued_human_message_adds_zero(tmp_path):
    acc = _timed(tmp_path, [_at(_bash("c1", "t1"), 0), _at(_human("also check X"), 3)])
    assert (acc.operator, acc.events, acc.returns) == (0, 1, 0)


# Task 4: engine and edge tests.

def test_time_pending_set_pairs_parallel_tool_results(tmp_path):
    acc = _timed(tmp_path, [
        _at(_bash("c1", "t1"), 0), _at(_bash("c1", "t2"), 0),
        _at(_result("t1", "ok"), 20), _at(_result("t2", "ok"), 30),
    ], name="a")
    assert acc.busy == 1800 and acc.wall() == 1800
    # Control: a result already answered, or never issued, is no wait (a 20-min gap: idle, 0).
    acc = _timed(tmp_path, [
        _at(_bash("c1", "t1"), 0), _at(_result("t1", "ok"), 1),
        _at(_result("t1", "ok again"), 21), _at(_result("zz", "stray"), 41),
    ], name="b")
    assert acc.busy == 60


def test_time_permission_prompt_is_operator_not_agent_time(tmp_path):
    recs = [_at(_bash("c1", "t1"), 0), _at(_perm("t1", "user_temporary"), 50)]
    acc = _timed(tmp_path, recs, name="a")
    assert (acc.busy, acc.wall()) == (0, 0)
    assert (acc.events, acc.operator, acc.returns) == (1, 0, 1)
    acc = _timed(tmp_path, recs, name="b", attention_cap=3600)
    assert (acc.busy, acc.operator, acc.events, acc.returns) == (0, 3000, 1, 0)
    acc = _timed(tmp_path, [_at(_bash("c1", "t1"), 0), _at(_perm("t1", "config"), 50)], name="c")
    assert (acc.busy, acc.events) == (3000, 0)


def test_time_does_not_change_cost_rows(tmp_path):
    d = _time_fixture(tmp_path / "timefix")
    a, sa = cr.collect([d], None)
    b, sb = cr.collect([d], None, timing=cr.TimeRules(), times={})
    assert a and _rows_equal(a, b)
    assert sa == sb


@pytest.mark.parametrize("x_first", [True, False])
def test_time_session_copies_count_once(tmp_path, x_first):
    recs = [_at(_end("e1"), 0), _at(_human("hi"), 2), _at(_bash("c1", "t1"), 3), _at(_result("t1", "ok"), 5)]
    tail = [_at(_end("e2"), 6), _at(_human("again"), 8)]
    x, y = tmp_path / "x", tmp_path / "y"
    _write(x / "S.jsonl", recs, mtime=1_000_000 if x_first else 3_000_000)
    _gz(y / "S.jsonl.gz", recs + tail, mtime=2_000_000)
    both = _times([x, y])[(NP, NI)]
    alone = _times([y])[(NP, NI)]
    assert (both.busy, both.operator, both.events) == (240, 240, 2)
    assert _tv(both) == _tv(alone)


def test_time_gz_reads_like_jsonl(tmp_path):
    plain = _times([_time_fixture(tmp_path / "plain")])
    gz = _times([_time_fixture(tmp_path / "gz", gz=True)])
    assert plain and {k: _tv(v) for k, v in plain.items()} == {k: _tv(v) for k, v in gz.items()}


def test_time_workflow_agent_charged_through_run_id(tmp_path):
    d = tmp_path / "d"
    _workflow_session(d, gz=False, stamp=True)
    t = _times([d])
    # Main 180 (m1, m2, m3) + the agent's 60; the Workflow wait is linked, so not main busy.
    assert t[("alpha", "Issue-4")].busy == 240
    assert t[(NP, NI)].busy == 60                     # the dispatch wait, before the pair is set
    d2 = tmp_path / "d2"
    _workflow_session(d2, gz=False, run_id="wf_00000000-000", stamp=True)
    t = _times([d2])
    # Unmatched: the agent's 60 falls to (no project)/(no issue); the unlinked wait is main busy.
    assert t[("alpha", "Issue-4")].busy == 240
    assert t[(NP, NI)].busy == 120


def test_time_bad_or_backward_timestamp(tmp_path):
    acc = _timed(tmp_path, [
        _at(_call("c1", None), 0),
        {**_call("c2", None), "timestamp": "garbage", "uuid": str(uuid.UUID(int=10**9))},
        {**_call("c3", None), "timestamp": "2026-10-01T00:02:00.000", "uuid": str(uuid.UUID(int=10**9 + 1))},
        _at(_call("c4", None), 3),
    ], name="a")
    assert acc.busy == 180
    acc = _timed(tmp_path, [_at(_call("c1", None), 10), _at(_call("c2", None), 8)], name="b")
    assert (acc.busy, acc.wall()) == (0, 0)


ZERO_TIME = "time: agent wall 0.00h, agent busy 0.00h, operator 0.00h (0 operator events, 0 returns after absence, 0 by fallback)"


@pytest.mark.parametrize("records", [
    [_at(_call("c1", _usage(inp=1)), 0)],
    [_at(_call("c1", _usage(inp=1)), 0), _at(_call("c2", _usage(inp=1)), 10)],
], ids=["one-record", "over-cap"])
def test_time_extremes(tmp_path, records):
    d = _one(tmp_path, records)
    assert _tv(_times([d])[(NP, NI)]) == (0, 0, 0, 0, 0, 0)
    run = _cli("--transcripts", d, "--summary", "--time")
    assert run.returncode == 0, run.stderr
    assert _lines(run.stdout)[2] == f"(no project)/(no issue) {ZERO_TIME}"


def test_time_unlinked_background_wait_is_busy(tmp_path):
    acc = _timed(tmp_path, [_at(_end("e1"), 0), _at(_notify("bg1"), 40)], name="a")
    assert acc.busy == 2400
    d = _one(tmp_path, [
        _at(_agent("c1", "a1"), 0), _at(_result("a1", "launched in the background"), 1),
        _at(_end("e1"), 2), _at(_notify("a1"), 42),
    ], name="b")
    _subagent(d / "s.jsonl", "agent-a", "a1", [_at(_str("go"), 0), _at(_end("s1"), 1)])
    # The agent's 60 plus main's idle 1-2; the 40-min notification wait names a read agent: 0 from main.
    assert _times([d])[(NP, NI)].busy == 120


def test_time_command_after_local_caveat_counts_latency(tmp_path):
    acc = _timed(tmp_path, [
        _at(_end("e1"), 0),
        _at(_str("<local-command-caveat>Caveat: generated locally</local-command-caveat>"), 1 / 60),
        _at(_typed("draft", "Issue-4"), 3),
    ])
    assert (acc.operator, acc.events, acc.returns) == (180, 1, 0)


def _peak(fn):
    tracemalloc.start()
    try:
        result = fn()
        return result, tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()


def test_time_memory_small_records(tmp_path):
    mb = int(os.environ.get("DEVAGENT_COST_REPORT_MEMORY_MB", "32"))
    d = tmp_path / "small"
    d.mkdir()
    path = d / "small.jsonl"
    try:
        blocks = _big_session(path, mb, filler="x" * 2048, stamp=True)
        records = 2 * blocks + 2
        _, base = _peak(lambda: cr.collect([d], None))
        times = {}
        _, peak = _peak(lambda: cr.collect([d], None, timing=cr.TimeRules(), times=times))
        print(f"memory: {records} records, peak {base} without --time, {peak} with")
        assert peak <= 2 * base + 16 * records + 8 * 2**20
        assert times[("alpha", "Issue-4")].busy > 0
    finally:
        path.unlink(missing_ok=True)


def test_time_memory_does_not_grow_with_transcript_size(tmp_path):
    mb = int(os.environ.get("DEVAGENT_COST_REPORT_MEMORY_MB", "32"))
    d = tmp_path / "big"
    d.mkdir()
    path = d / "big.jsonl"
    try:
        _big_session(path, mb, stamp=True)
        size = path.stat().st_size
        times = {}
        _, peak = _peak(lambda: cr.collect([d], None, timing=cr.TimeRules(), times=times))
        print(f"memory: {size} bytes, peak {peak} bytes with --time")
        assert peak < 200 * 2**20
        assert peak < size / 4
        assert times[("alpha", "Issue-4")].busy > 0     # the time path ran (pothole L190)
    finally:
        path.unlink(missing_ok=True)


# Task 5: CLI.

RULE_LINE = "time rule: idle_gap 5m, tool_gap 60m, attention_cap 15m"
ALPHA_COST, BETA_COST = GOLDEN_SUMMARY.splitlines()
ALPHA_TIME = ("alpha/Issue-4 time: agent wall 0.20h, agent busy 0.20h, operator 0.17h "
              "(4 operator events, 0 returns after absence, 1 by fallback)")
BETA_TIME = ("beta/Issue-5 time: agent wall 0.03h, agent busy 0.03h, operator 0.00h "
             "(1 operator events, 1 returns after absence, 0 by fallback)")


def test_cli_time_line_follows_each_cost_line(tmp_path):
    d = _time_fixture(tmp_path / "timefix")
    run = _cli("--transcripts", d, "--time")
    assert run.returncode == 0, run.stderr
    out = run.stdout.splitlines()
    assert out[2] == RULE_LINE
    for cost, time in ((ALPHA_COST, ALPHA_TIME), (BETA_COST, BETA_TIME)):
        assert out[out.index(cost) + 1] == time


def test_cli_time_summary_lines(tmp_path):
    d = _time_fixture(tmp_path / "timefix")
    run = _cli("--transcripts", d, "--summary", "--time")
    assert run.returncode == 0, run.stderr
    assert run.stdout.splitlines() == [RULE_LINE, ALPHA_COST, ALPHA_TIME, BETA_COST, BETA_TIME]


def test_cli_time_project_issue_prints_side_pair(tmp_path):
    d = _time_fixture(tmp_path / "timefix")
    _draft_session(d)
    run = _cli("--transcripts", d, "--project", "alpha", "--issue", "4", "--summary", "--time")
    assert run.returncode == 0, run.stderr
    out = run.stdout.splitlines()
    assert len(out) == 5
    assert out[0] == RULE_LINE
    assert out[1] == ALPHA_COST and out[2] == ALPHA_TIME
    assert out[3].startswith("(no project)/Issue-4: ")
    assert out[4] == f"(no project)/Issue-4 {ZERO_TIME}"


@pytest.mark.parametrize("flag", ["--idle-gap", "--tool-gap", "--attention-cap"])
def test_cli_time_param_flags(tmp_path, flag):
    d = _time_fixture(tmp_path / "timefix")
    run = _cli("--transcripts", d, "--summary", "--time", "--idle-gap", "2")
    assert run.returncode == 0, run.stderr
    out = run.stdout.splitlines()
    assert out[0] == "time rule: idle_gap 2m, tool_gap 60m, attention_cap 15m"
    assert out[2].startswith("alpha/Issue-4 time: agent wall 0.15h, agent busy 0.15h, ")
    run = _cli("--transcripts", d, "--summary", "--time", "--tool-gap", "0.5")
    assert run.returncode == 0, run.stderr
    assert run.stdout.splitlines()[0] == "time rule: idle_gap 5m, tool_gap 0.5m, attention_cap 15m"
    for bad in ("0", "-1", "nan", "inf", "abc"):
        run = _cli("--transcripts", d, "--summary", "--time", flag, bad)
        assert run.returncode == 2, (flag, bad, run.stdout)
        assert run.stdout == ""
    run = _cli("--transcripts", d, "--summary", flag, "5")
    assert run.returncode == 2
    assert f"{flag} needs --time" in run.stderr


TIME_KEYS = {"agent_wall_s", "agent_busy_s", "operator_s", "operator_events", "returns_after_absence", "fallback_events"}


def test_cli_time_json(tmp_path):
    d = _time_fixture(tmp_path / "timefix")
    run = _cli("--transcripts", d, "--json", "--time")
    assert run.returncode == 0, run.stderr
    lines = _lines(run.stdout)
    objs = [json.loads(ln) for ln in lines]
    assert [(o["project"], o["issue"]) for o in objs] == [("alpha", "Issue-4"), ("beta", "Issue-5")]
    rule = '"time_rule": {"attention_cap_s": 900.0, "idle_gap_s": 300.0, "tool_gap_s": 3600.0}'
    for ln, o in zip(lines, objs):
        assert set(o) == JSON_KEYS | TIME_KEYS | {"time_rule"}
        assert rule in ln
    assert {k: objs[0][k] for k in TIME_KEYS} == {
        "agent_wall_s": 720.0, "agent_busy_s": 720.0, "operator_s": 600.0,
        "operator_events": 4, "returns_after_absence": 0, "fallback_events": 1}
    assert {k: objs[1][k] for k in TIME_KEYS} == {
        "agent_wall_s": 120.0, "agent_busy_s": 120.0, "operator_s": 0.0,
        "operator_events": 1, "returns_after_absence": 1, "fallback_events": 0}
    assert _cli("--transcripts", d, "--json", "--time").stdout == run.stdout   # byte-identical reruns
    two = _cli("--transcripts", d, "--json", "--time", "--idle-gap", "2")
    assert all('"idle_gap_s": 120.0' in ln for ln in _lines(two.stdout))


def test_cli_time_archive(tmp_path):
    store = tmp_path / "store"
    _time_fixture(store / "h1" / "timefix", gz=True)
    live = _time_fixture(tmp_path / "timefix")
    arc = _cli("--archive", store, "--time", "--summary")
    liv = _cli("--transcripts", live, "--time", "--summary")
    assert arc.returncode == 0 and liv.returncode == 0, (arc.stderr, liv.stderr)
    assert arc.stdout == liv.stdout
    assert ALPHA_TIME in arc.stdout.splitlines()
