"""Tests for scripts/lib/cost-report.py (per-issue, per-step token cost)."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location("cost_report", REPO / "scripts" / "lib" / "cost-report.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)


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


def _write(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")


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


def test_call_cost_weights_each_token_class():
    assert cr.call_cost(_usage(inp=1, read=10, w5=4, w1=2, out=1)) == 1 + 1 + 5 + 4 + 5


def test_call_cost_without_a_write_split_prices_writes_as_5m():
    u = {"cache_creation_input_tokens": 4}
    assert cr.call_cost(u) == 5


def test_steps_follow_next_dispatches_and_typed_commands(tmp_path):
    rows, sessions = cr.collect([_session(tmp_path)], None)
    steps = rows["Issue-42"]
    assert list(steps) == ["pull", "draft", "implement"]
    # A call belongs to the step that made it: m2 runs next.sh during pull.
    assert steps["pull"].main == 10 + 5              # m1, m2
    assert steps["draft"].calls == 4                 # m3 once, m4, m5, m6: the Read did not move the step
    assert steps["draft"].main == 100 + 5 + 200 + 5
    assert steps["implement"].main == 125 + 500      # m7
    assert steps["implement"].peak == 5100
    assert "Issue-99" not in rows
    assert sessions["Issue-42"] == {"s1"}


def test_subagent_is_charged_to_the_step_that_launched_it(tmp_path):
    rows, _ = cr.collect([_session(tmp_path)], None)
    assert rows["Issue-42"]["draft"].sub == 50 + 10
    assert sum(r.sub for r in rows["Issue-42"].values()) == 60


def test_issue_filter_skips_other_sessions(tmp_path):
    d = _session(tmp_path)
    _write(d / "s2.jsonl", [_typed("pull", "devagent origin 7"), _call("n1", _usage(inp=3))])
    rows, _ = cr.collect([d], "Issue-7")
    assert list(rows) == ["Issue-7"]
    rows, _ = cr.collect([d], "Issue-42")
    assert list(rows) == ["Issue-42"]


def test_summary_line_is_one_pasteable_line(tmp_path):
    rows, sessions = cr.collect([_session(tmp_path)], "Issue-42")
    line = cr.report(rows, sessions, [tmp_path], summary=True)
    assert "\n" not in line
    assert line.startswith("Issue-42: 0.0M input-token equivalents over 1 session(s), 7 calls, peak context 5K")


def test_cli_accepts_a_bare_issue_number(tmp_path):
    d = _session(tmp_path)
    run = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "lib" / "cost-report.py"), "--transcripts", str(d), "--issue", "42"],
        capture_output=True, text=True,
    )
    assert run.returncode == 0, run.stderr
    assert "Issue-42:" in run.stdout
    assert "implement" in run.stdout


def test_cli_reports_an_issue_with_no_calls(tmp_path):
    run = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "lib" / "cost-report.py"), "--transcripts", str(_session(tmp_path)), "--issue", "5"],
        capture_output=True, text=True,
    )
    assert run.returncode == 1
    assert "no calls attributed to Issue-5" in run.stderr
