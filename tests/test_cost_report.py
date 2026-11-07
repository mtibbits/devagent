"""Tests for scripts/lib/cost-report.py (per-(project, issue), per-step token cost)."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tracemalloc
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


def _call(mid, usage, *tool_uses):
    return {"type": "assistant", "message": {"id": mid, "usage": usage, "content": list(tool_uses)}}


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


def _cli(*args, cwd=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True, encoding="utf-8", cwd=cwd,
    )


def _pair(p, i):
    return (p, i)


def _calls(rows, key):
    return sum(r.calls for r in rows[key].values())


def _per_issue(rows):
    """{issue: (calls, main, sub)}, for either key shape: issue (846c19c) or (project, issue)."""
    out = {}
    for k, steps in rows.items():
        issue = k[1] if isinstance(k, tuple) else k
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
    _write(d / "s1" / "subagents" / "agent-x.jsonl", [_call("s1", _usage(out=10)), _call("s2", _usage(read=100))])
    (d / "s1" / "subagents" / "agent-x.meta.json").write_text(json.dumps({"toolUseId": "a1"}), encoding="utf-8")
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
    line = cr.report(rows, sessions, [tmp_path], summary=True)
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
    _write(d / "A.jsonl", [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("am1", _usage(inp=100)),
    ], mtime=1_000_000)
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
    if all(isinstance(k, tuple) for k in rows):
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
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())   # fixture construction, not default_dirs under test
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
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())
    (root / slug).mkdir(parents=True)
    result = cr.default_dirs()
    assert isinstance(result, list)
    assert set(result) == {root / slug}
    flipped = slug[0].swapcase() + slug[1:]
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


def _big_session(path, mb):
    """Stream a transcript of about `mb` MB to `path`; return the number of counted calls."""
    target = mb * 2**20
    blocks = 0
    with open(path, "w", encoding="utf-8") as f:
        for r in _dispatch("b0", "alpha", "Issue-4", 9, "implement", "d0"):
            f.write(json.dumps(r) + "\n")
        while f.tell() < target:
            tools = [_tool(f"k{blocks}", "Skill", skill="devagent:quality")] if blocks % 16 == 0 else []
            f.write(json.dumps(_call(f"m{blocks}", _usage(read=1), *tools)) + "\n")
            f.write(json.dumps(_result(f"r{blocks}", FILLER)) + "\n")
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
