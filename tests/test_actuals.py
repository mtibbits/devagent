"""Tests for scripts/lib/actuals.py (#735): the per-issue actuals document.

Every expected figure is a literal computed by hand from the fixture (cost in
input-token equivalents: input 1, cache read 0.1, output 5); none is derived
by calling the code under test. Hermetic: DA_HOME, CLAUDE_CONFIG_DIR and HOME
point into tmp_path.
"""
import importlib.util
import json
import os
import stat
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from test_cost_report import _call, _dispatch, _gz, _in, _sid, _tool, _usage, _write

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
BUILDER = LIB / "actuals.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ac = _load("actuals_under_test", BUILDER)
pc = _load("portfolio_check_for_actuals", LIB / "portfolio-check.py")

SLOT = "projects[].issues[].actuals"
PFIELD = "projects[].actuals"
TOP_KEYS = {"actuals_version", "generated_at", "inputs", "issues", "projects", "sources", "time_rule",
            "unassigned"}
W = {"input": 1.0, "cache_read": 0.1, "cache_write_5m": 1.25, "cache_write_1h": 2.0, "output": 5.0}
STAMP = "%Y-%m-%dT%H:%M:%SZ"


@pytest.fixture(autouse=True)
def _hermetic(tmp_path, monkeypatch):
    for sub in ("da-home", "claude", "home", "cwd"):
        (tmp_path / sub).mkdir()
    monkeypatch.setenv("DA_HOME", str(tmp_path / "da-home"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "claude"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    for k in [k for k in os.environ if k.startswith("ACTUALS_")]:
        monkeypatch.delenv(k)
    monkeypatch.chdir(tmp_path / "cwd")


def _config(tmp_path, archive=None, extra_archive=""):
    body = ""
    if archive is not None:
        body += f"[archive]\ntranscripts_dir = {json.dumps(str(archive))}\nhost_id = \"h1\"\n{extra_archive}\n"
    for name in ("alpha", "beta"):
        body += (f"[project.{name}]\nsource_dir = \"/work/{name}\"\n"
                 f"devdoc_dir = {json.dumps(str(tmp_path / 'devdoc' / name))}\n\n")
    Path(os.environ["DA_HOME"], "config.toml").write_text(body, encoding="utf-8")


def _m(mid, usage, model):
    rec = _call(mid, usage)
    rec["message"]["model"] = model
    return rec


def _archive(tmp_path):
    """Hosts h1 and h2: alpha/Issue-4 on two models, beta/Issue-7 with overhead calls, gamma/Issue-1 unconfigured."""
    a = tmp_path / "A"
    _gz(a / "h1" / "-work-alpha" / "S1.jsonl.gz", [
        *_dispatch("n1", "alpha", "Issue-4", 9, "implement", "d1"),
        _m("m1", _usage(inp=10, out=2), "claude-a"),
        _m("m2", _usage(read=100), "claude-b"),
    ], mtime=1_000_000)
    _gz(a / "h2" / "-work-beta" / "S2.jsonl.gz", [
        _in(_m("c0", _usage(inp=1), "claude-a"), "/work/alpha"),
        _in(_m("c1", _usage(inp=2), "claude-a"), "/home/op"),
        *_dispatch("n2", "beta", "Issue-7", 9, "implement", "d2"),
        _m("b1", _usage(inp=5), "claude-a"),
    ], mtime=1_000_100)
    _gz(a / "h2" / "-work-gamma" / "S3.jsonl.gz", [
        *_dispatch("n3", "gamma", "Issue-1", 9, "implement", "d3"),
        _m("g1", _usage(inp=3), "claude-a"),
    ], mtime=1_000_200)
    return a


def _header(project, missing=()):
    return {"kind": "header", "project": project, "scope": "all",
            "missing": [{"source": s, "detail": d} for s, d in missing]}


def _row(project, issue, event, at, source, **extra):
    return {"kind": "row", "project": project, "issue": issue, "event": event, "at": at, "source": source,
            **extra}


ALPHA_MS = [
    _header("alpha"),
    _row("alpha", "Issue-4", "opened", "2026-11-01T10:00:00Z", "tracker"),
    _row("alpha", "Issue-4", "step_done", "2026-11-02 09:00", "checklist", step="draft", revision=1, tz="-05:00"),
    _row("alpha", "Issue-9", "opened", "2026-11-03T10:00:00Z", "tracker"),
]
BETA_MS = [_header("beta"), _row("beta", "Issue-7", "opened", "2026-11-04T10:00:00Z", "tracker")]


def _jsonl(docs, torn=False):
    text = "".join(json.dumps(d, separators=(",", ":")) + "\n" for d in docs)
    return text[:-5] if torn else text


def _manifest(tmp_path, entries):
    """entries: [(project, rc, stdout text, stderr text)] → the ACTUALS_MS_* environment."""
    d = tmp_path / "ms"
    d.mkdir(exist_ok=True)
    env = {"ACTUALS_MS_COUNT": str(len(entries))}
    for i, (project, rc, out, err) in enumerate(entries):
        (d / f"{i}.out").write_text(out, encoding="utf-8")
        (d / f"{i}.err").write_text(err, encoding="utf-8")
        env.update({f"ACTUALS_MS_{i}_PROJECT": project, f"ACTUALS_MS_{i}_RC": str(rc),
                    f"ACTUALS_MS_{i}_OUT": str(d / f"{i}.out"), f"ACTUALS_MS_{i}_ERR": str(d / f"{i}.err")})
    return env


def _ok_manifest(tmp_path):
    return _manifest(tmp_path, [("alpha", 0, _jsonl(ALPHA_MS), ""), ("beta", 0, _jsonl(BETA_MS), "")])


def _build(tmp_path, archive=None, project=None, env=None):
    return ac.build_document(archive, project, env if env is not None else _ok_manifest(tmp_path))


def _issue(doc, project, issue):
    (row,) = [r for r in doc["issues"] if (r["project"], r["issue"]) == (project, issue)]
    return row["actuals"]


def _cli(*args, env=None, timeout=None):
    full = {**os.environ, **(env or {})}
    return subprocess.run([sys.executable, str(BUILDER), *map(str, args)], capture_output=True, env=full,
                          timeout=timeout)


def _weighted(raw):
    return sum(W[k] * r[k] for r in raw for k in W)


# --- U1 and the document's shape ---------------------------------------------------

def test_one_pass_matches_cost_report_cli(tmp_path):
    _config(tmp_path)
    a = _archive(tmp_path)
    doc = _build(tmp_path, archive=a)
    cr = LIB / "cost-report.py"
    pairs = subprocess.run([sys.executable, str(cr), "--archive", str(a), "--json", "--time"],
                           capture_output=True, encoding="utf-8")
    ovh = subprocess.run([sys.executable, str(cr), "--archive", str(a), "--overhead", "--json"],
                         capture_output=True, encoding="utf-8")
    assert pairs.returncode == 0 and ovh.returncode == 0, (pairs.stderr, ovh.stderr)
    seen = 0
    for o in map(json.loads, pairs.stdout.splitlines()):
        if (o["project"], o["issue"]) == ("(no project)", "(no issue)"):
            continue
        got = _issue(doc, o["project"], o["issue"])
        assert got["tokens"] == {k: o[k] for k in ("main", "subagents", "total", "raw")}
        assert got["sessions"] == o["sources"]
        assert got["time"] == {k: o[k] for k in ("agent_busy_s", "agent_wall_s", "operator_s",
                                                  "operator_events", "returns_after_absence",
                                                  "fallback_events")}
        assert doc["time_rule"] == o["time_rule"]
        seen += 1
    assert seen == 3
    projects = {r["project"]: r["actuals"] for r in doc["projects"]}
    for o in map(json.loads, ovh.stdout.splitlines()):
        tokens = {k: o[k] for k in ("main", "subagents", "total", "raw")}
        if o["project"] == "(unassigned)":
            assert {"cwd": o["cwd"], "sessions": o["sources"], "tokens": tokens} in doc["unassigned"]
        else:
            assert projects[o["project"]]["overhead"] == {
                "rules": {"cwd": o["rules"]["cwd"], "hint": o["rules"]["hint"]},
                "sessions": o["sources"], "tokens": tokens}
        seen += 1
    assert seen == 5


def test_document_top_level_keys(tmp_path):
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    assert set(doc) == TOP_KEYS
    assert doc["actuals_version"] == "1.0"
    datetime.strptime(doc["generated_at"], STAMP)
    assert doc["inputs"] == {"archive": str(tmp_path / "A"), "hosts": ["h1", "h2"], "project": None}
    assert doc["time_rule"] == {"attention_cap_s": 900.0, "idle_gap_s": 300.0, "tool_gap_s": 3600.0}
    assert pc.actuals_usable(doc) is None


def test_rows_validate_against_slot_definition(tmp_path):
    """AC1: every issue and project object passes the schema's own slot definition."""
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    assert len(doc["issues"]) == 4 and len(doc["projects"]) == 2
    for r in doc["issues"]:
        assert pc.check_at(r["actuals"], SLOT) == [], r
    for r in doc["projects"]:
        assert pc.check_at(r["actuals"], PFIELD) == [], r
    for r in doc["unassigned"]:
        assert pc.check_at(r, "actuals.unassigned[]") == [], r


def test_every_figure_traces_to_a_source(tmp_path):
    """AC1: tokens imply a session with host and cwd_slug; every milestone names its source."""
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    for r in doc["issues"]:
        a = r["actuals"]
        if a["tokens"] is not None:
            assert a["sessions"] and all(s["host"] and s["cwd_slug"] for s in a["sessions"])
        for m in a["milestones"] or []:
            assert m["source"]
    assert _issue(doc, "alpha", "Issue-4")["sessions"] == [
        {"cwd_slug": "-work-alpha", "host": "h1", "session": "S1"}]


def test_two_models_weighted_sum_is_headline(tmp_path):
    """AC2: two raw entries, each count a literal, weighing back to total."""
    _config(tmp_path)
    tokens = _issue(_build(tmp_path, archive=_archive(tmp_path)), "alpha", "Issue-4")["tokens"]
    assert tokens["raw"] == [
        {"cache_read": 0, "cache_write_1h": 0, "cache_write_5m": 0, "input": 10, "model": "claude-a", "output": 2},
        {"cache_read": 100, "cache_write_1h": 0, "cache_write_5m": 0, "input": 0, "model": "claude-b", "output": 0},
    ]
    assert tokens["total"] == 30.0   # 10 + 2 * 5 + 100 * 0.1
    assert _weighted(tokens["raw"]) == tokens["total"]


def test_milestone_only_and_cost_only_issues(tmp_path):
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    only_ms = _issue(doc, "alpha", "Issue-9")
    assert only_ms == {"milestones": [{"at": "2026-11-03T10:00:00Z", "event": "opened", "source": "tracker"}],
                       "sessions": [], "time": None, "tokens": None}
    both = _issue(doc, "alpha", "Issue-4")
    assert both["milestones"] == [
        {"at": "2026-11-01T10:00:00Z", "event": "opened", "source": "tracker"},
        {"at": "2026-11-02 09:00", "event": "step_done", "source": "checklist"}]
    assert both["tokens"]["total"] == 30.0
    cost_only = _issue(doc, "gamma", "Issue-1")
    assert cost_only["milestones"] == [] and cost_only["tokens"]["total"] == 3.0


def test_unconfigured_project_rows_are_kept(tmp_path):
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    assert [(r["project"], r["issue"]) for r in doc["issues"]] == [
        ("alpha", "Issue-4"), ("alpha", "Issue-9"), ("beta", "Issue-7"), ("gamma", "Issue-1")]


def test_no_project_pair_not_in_issues(tmp_path):
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    assert all(r["project"] != "(no project)" for r in doc["issues"])
    projects = {r["project"]: r["actuals"] for r in doc["projects"]}
    assert projects["alpha"]["overhead"]["tokens"]["total"] == 1.0
    assert projects["alpha"]["overhead"]["rules"] == {"cwd": 1, "hint": 0}
    assert projects["beta"] == {"overhead": None}
    assert [(u["cwd"], u["tokens"]["total"]) for u in doc["unassigned"]] == [("/home/op", 2.0)]


def test_no_inputs_gives_an_empty_document(tmp_path):
    doc = ac.build_document(None, None, {"ACTUALS_MS_COUNT": "0"})
    assert (doc["issues"], doc["projects"], doc["unassigned"]) == ([], [], [])
    assert doc["inputs"] == {"archive": None, "hosts": [], "project": None}
    assert [(s["source"], s["status"]) for s in doc["sources"]] == [("archive", "missing"), ("live", "missing")]


# --- inputs ------------------------------------------------------------------------

def _live(tmp_path, slug, name, records, mtime=1_000_000):
    root = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"
    _write(root / slug / name, records, mtime=mtime)
    return root


def test_default_reads_live_and_configured_archive(tmp_path):
    store = tmp_path / "store"
    recs = _sid([*_dispatch("n1", "alpha", "Issue-4", 9, "implement", "d1"), _m("m1", _usage(inp=7), "claude-a")],
                "S")
    _live(tmp_path, "-work-alpha", "S.jsonl", recs)
    for h in ("h2", "h3"):
        _gz(store / h / "-work-alpha" / "S.jsonl.gz", recs, mtime=1_000_000)
    _gz(store / "h2" / "-work-beta" / "T.jsonl.gz",
        [*_dispatch("n2", "beta", "Issue-7", 9, "implement", "d2"), _m("t1", _usage(inp=4), "claude-a")])
    _config(tmp_path, archive=store)
    doc = _build(tmp_path)
    assert doc["inputs"] == {"archive": str(store), "hosts": ["h2", "h3", "local"], "project": None}
    alpha = _issue(doc, "alpha", "Issue-4")
    assert alpha["tokens"]["total"] == 7.0   # counted once across three copies
    assert [s["host"] for s in alpha["sessions"]] == ["h2", "h3", "local"]
    assert _issue(doc, "beta", "Issue-7")["tokens"]["total"] == 4.0
    assert {(s["source"], s["status"]) for s in doc["sources"] if s["source"] in ("archive", "live")} == {
        ("archive", "ok"), ("live", "ok")}
    _config(tmp_path)   # no [archive] table
    doc = _build(tmp_path)
    assert doc["inputs"] == {"archive": None, "hosts": ["local"], "project": None}
    (arch,) = [s for s in doc["sources"] if s["source"] == "archive"]
    assert arch == {"source": "archive", "project": None, "status": "missing",
                    "detail": "no [archive].transcripts_dir configured"}


def test_default_skips_own_host_partition_duplicating_live(tmp_path, monkeypatch):
    store = tmp_path / "store"
    recs = _sid([*_dispatch("n1", "alpha", "Issue-4", 9, "implement", "d1"), _m("m1", _usage(inp=7), "claude-a")],
                "S")
    _live(tmp_path, "-work-alpha", "S.jsonl", recs)
    _gz(store / "h1" / "-work-alpha" / "S.jsonl.gz", recs)   # h1 is this host: a copy of a live file
    _gz(store / "h1" / "-work-old" / "O.jsonl.gz",           # archived only: still read
        [*_dispatch("n2", "beta", "Issue-7", 9, "implement", "d2"), _m("o1", _usage(inp=4), "claude-a")])
    _config(tmp_path, archive=store)
    opened = []
    real = ac.cr.scan_session

    def spy(path, *a, **k):
        opened.append(str(path))
        return real(path, *a, **k)

    monkeypatch.setattr(ac.cr, "scan_session", spy)
    doc = _build(tmp_path)
    assert str(store / "h1" / "-work-alpha" / "S.jsonl.gz") not in opened
    assert str(store / "h1" / "-work-old" / "O.jsonl.gz") in opened
    assert _issue(doc, "alpha", "Issue-4")["sessions"] == [{"cwd_slug": "-work-alpha", "host": "local",
                                                            "session": "S"}]
    assert _issue(doc, "beta", "Issue-7")["tokens"]["total"] == 4.0


def _sources(doc, source=None):
    return [s for s in doc["sources"] if source is None or s["source"] == source]


def test_sources_rows(tmp_path):
    _config(tmp_path, archive=tmp_path / "relative-is-fine", extra_archive="actuals_max_age_hours = 0\n")
    a = _archive(tmp_path)
    p = a / "h1" / "-work-alpha" / "Z.jsonl.gz"
    p.write_bytes(__import__("gzip").compress(b'{"type":"assistant"}\n' * 50)[:-12])   # a torn tail
    env = _manifest(tmp_path, [
        ("alpha", 1, "", "some noise\nmilestones: devdoc_dir /x does not exist\n\n"),
        ("beta", 0, _jsonl([_header("beta", [("tracker", "exit 1: boom")]), *BETA_MS[1:]], torn=True), ""),
    ])
    doc = _build(tmp_path, env=env)
    assert _sources(doc, "milestones") == [
        {"source": "milestones", "project": "alpha", "status": "missing",
         "detail": "exit 1: milestones: devdoc_dir /x does not exist"},
        {"source": "milestones", "project": "beta", "status": "missing",
         "detail": "exit 0: output is not whole JSON Lines"},
    ]
    (arch,) = _sources(doc, "archive")
    assert arch["status"] == "missing" and arch["detail"] == (
        "[archive].actuals_max_age_hours must be a number of hours, 0 < x <= 168: 0")
    # A header `missing` entry is carried verbatim, under the header's source name.
    env = _manifest(tmp_path, [
        ("alpha", 0, _jsonl([_header("alpha", [("tracker", "exit 1: boom")]), *ALPHA_MS[1:]]),
         "milestones: WARNING: skipped Issue-3/checklist.md line 4\n"),
        ("beta", 0, _jsonl(BETA_MS), ""),
    ])
    doc = _build(tmp_path, archive=a, env=env)
    assert _sources(doc, "tracker") == [
        {"source": "tracker", "project": "alpha", "status": "missing", "detail": "exit 1: boom"}]
    assert _sources(doc, "milestones") == [
        {"source": "milestones", "project": "alpha", "status": "ok", "detail": None},
        {"source": "milestones", "project": "alpha", "status": "ok",
         "detail": "milestones: WARNING: skipped Issue-3/checklist.md line 4"},
        {"source": "milestones", "project": "beta", "status": "ok", "detail": None},
    ]
    (tr,) = _sources(doc, "transcript")
    assert tr["status"] == "missing" and tr["detail"].startswith(f"truncated {p} (")
    assert _issue(doc, "alpha", "Issue-4")["tokens"]["total"] == 30.0   # the other files still count
    assert _issue(doc, "alpha", "Issue-4")["milestones"]   # a header-only missing entry keeps rows


@pytest.mark.skipif(os.name != "posix" or os.geteuid() == 0, reason="POSIX modes, not as root")
def test_unreadable_host_partition_is_a_transcript_row(tmp_path):
    _config(tmp_path)
    a = _archive(tmp_path)
    (a / "h2").chmod(0)
    try:
        doc = _build(tmp_path, archive=a)
    finally:
        (a / "h2").chmod(0o700)
    (tr,) = _sources(doc, "transcript")
    assert tr["status"] == "missing" and tr["detail"].startswith(f"skipped {a / 'h2'} (")
    assert _issue(doc, "alpha", "Issue-4")["tokens"]["total"] == 30.0
    assert doc["inputs"]["hosts"] == ["h1"]


def test_milestones_null_when_source_failed(tmp_path):
    _config(tmp_path)
    env = _manifest(tmp_path, [("alpha", 2, "", "boom\n"), ("beta", 0, _jsonl(BETA_MS), "")])
    doc = _build(tmp_path, archive=_archive(tmp_path), env=env)
    assert _issue(doc, "alpha", "Issue-4")["milestones"] is None
    assert [(r["project"], r["issue"]) for r in doc["issues"] if r["project"] == "alpha"] == [("alpha", "Issue-4")]
    assert _issue(doc, "beta", "Issue-7")["milestones"] == [
        {"at": "2026-11-04T10:00:00Z", "event": "opened", "source": "tracker"}]


def test_project_filter(tmp_path):
    _config(tmp_path)
    env = _manifest(tmp_path, [("alpha", 0, _jsonl(ALPHA_MS), "")])
    doc = _build(tmp_path, archive=_archive(tmp_path), project="alpha", env=env)
    assert [(r["project"], r["issue"]) for r in doc["issues"]] == [("alpha", "Issue-4"), ("alpha", "Issue-9")]
    assert [r["project"] for r in doc["projects"]] == ["alpha"]
    assert doc["unassigned"] == []
    assert doc["inputs"]["project"] == "alpha"
    assert pc.actuals_usable(doc) == "inputs.project is 'alpha': a one-project document"


def _strip(data: bytes) -> dict:
    doc = json.loads(data)
    doc.pop("generated_at")
    return doc


def test_two_runs_identical_apart_from_generated_at(tmp_path):
    """AC5: the field is popped, never the record; manifest order does not matter."""
    _config(tmp_path)
    a = _archive(tmp_path)
    one = ac.render(_build(tmp_path, archive=a))
    two = ac.render(_build(tmp_path, archive=a))
    rev = ac.render(_build(tmp_path, archive=a, env=_manifest(tmp_path, [
        ("beta", 0, _jsonl(BETA_MS), ""), ("alpha", 0, _jsonl(ALPHA_MS), "")])))
    assert _strip(one) == _strip(two) == _strip(rev)
    lines = [ln for ln in one.decode().splitlines() if '"generated_at"' not in ln]
    assert lines == [ln for ln in rev.decode().splitlines() if '"generated_at"' not in ln]


# --- the CLI: output, refusals, the gate ------------------------------------------------

@pytest.mark.skipif(os.name != "posix", reason="POSIX modes")
def test_write_is_owner_only(tmp_path):
    """AC7: the file is 0600 and a new dir 0700."""
    _config(tmp_path)
    a = _archive(tmp_path)
    out = tmp_path / "priv" / "new" / "actuals.json"
    run = _cli("build", "--archive", a, "--out", out, env=_ok_manifest(tmp_path))
    assert run.returncode == 0, run.stderr
    assert stat.S_IMODE(out.stat().st_mode) == 0o600
    assert stat.S_IMODE(out.parent.stat().st_mode) == 0o700
    assert run.stdout.decode() == f"actuals: wrote {out} (4 issues, 2 projects, 0 missing sources)\n"
    run = _cli("build", "--archive", a, env=_ok_manifest(tmp_path))
    default = Path(os.environ["DA_HOME"]) / "actuals.json"
    assert run.returncode == 0 and stat.S_IMODE(default.stat().st_mode) == 0o600


def test_out_refusals(tmp_path):
    """AC7: inside a git work tree, or under a project's devdoc dir: exit 2, nothing written."""
    _config(tmp_path)
    a = _archive(tmp_path)
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    out = repo / "sub" / "actuals.json"
    for verb in ("preflight", "build"):
        run = _cli(verb, "--archive", a, "--out", out, env=_ok_manifest(tmp_path))
        assert run.returncode == 2
        assert run.stderr.decode().splitlines() == [
            f"actuals: --out is inside a git work tree ({os.path.realpath(out)}); "
            "the document lists project names, session ids and cwd paths"]
        assert not out.exists() and not out.parent.exists()
    devdoc = tmp_path / "devdoc" / "alpha"
    devdoc.mkdir(parents=True)
    out = devdoc / "actuals.json"
    run = _cli("build", "--archive", a, "--out", out, env=_ok_manifest(tmp_path))
    assert run.returncode == 2
    assert run.stderr.decode().splitlines() == [
        f"actuals: refusing to write under a directory of project 'alpha' ({devdoc})"]
    assert not out.exists()


def test_project_needs_out_or_stdout(tmp_path):
    """--project writes a one-project document, never the default all-projects file."""
    _config(tmp_path)
    for verb in ("preflight", "build"):
        run = _cli(verb, "--archive", _archive(tmp_path), "--project", "alpha", env=_ok_manifest(tmp_path))
        assert run.returncode == 2
        assert run.stderr.decode().splitlines() == [
            "actuals: --project builds a one-project document; pass --out PATH or --stdout"]
    assert not (Path(os.environ["DA_HOME"]) / "actuals.json").exists()


def test_build_refuses_a_document_the_reader_would_refuse(tmp_path, monkeypatch, capsys):
    """The builder runs the reader's predicate first: a lone surrogate is exit 2, nothing written."""
    _config(tmp_path)
    a = _archive(tmp_path)
    doc = _build(tmp_path, archive=a)
    doc["issues"][0]["actuals"]["sessions"][0]["cwd_slug"] = "\ud800"
    monkeypatch.setattr(ac, "build_document", lambda *args: doc)
    out = tmp_path / "out" / "actuals.json"
    assert ac.main(["build", "--archive", str(a), "--out", str(out)], env=_ok_manifest(tmp_path)) == 2
    assert capsys.readouterr().err.splitlines() == [
        "actuals: refusing to write an unusable document: a string is not valid UTF-8 (a lone surrogate)"]
    assert not out.exists()


def test_archive_not_a_directory(tmp_path):
    _config(tmp_path)
    run = _cli("preflight", "--archive", tmp_path / "nope", "--stdout")
    assert run.returncode == 2
    assert run.stderr.decode().splitlines() == [f"actuals: no archive dir {tmp_path / 'nope'}"]


def test_unwritable_output_is_exit_2(tmp_path):
    _config(tmp_path)
    out = tmp_path / "x" / "actuals.json"
    out.mkdir(parents=True)   # a directory where the file goes
    run = _cli("build", "--archive", _archive(tmp_path), "--out", out, env=_ok_manifest(tmp_path))
    assert run.returncode == 2
    (line,) = run.stderr.decode().splitlines()
    assert line.startswith(f"actuals: cannot write {out}: ")


def _stamp(hours_ago):
    return (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).strftime(STAMP)


def _default_file(tmp_path, body):
    f = Path(os.environ["DA_HOME"]) / "actuals.json"
    f.write_text(body if isinstance(body, str) else json.dumps(body), encoding="utf-8")
    return f


def _good(tmp_path, hours_ago, project=None):
    _config(tmp_path)
    doc = _build(tmp_path, archive=_archive(tmp_path))
    doc["generated_at"] = _stamp(hours_ago)
    doc["inputs"]["project"] = project
    return doc


@pytest.mark.parametrize("case, expected", [
    ("missing", 0), ("25h", 0), ("key-1-2h", 0), ("torn", 0), ("future", 0), ("not-actuals", 0),
    ("one-project", 0), ("1h", 3), ("refused-key", 2), ("fifo", 0),
])
def test_gate(tmp_path, case, expected):
    """--if-stale: 0 go (rebuild), 3 fresh (skip), 2 a refused actuals_max_age_hours."""
    extra = {"key-1-2h": "actuals_max_age_hours = 1\n", "refused-key": "actuals_max_age_hours = 0\n"}.get(case, "")
    if case == "fifo":   # final review: the foreground gate must never open a FIFO
        os.mkfifo(Path(os.environ["DA_HOME"]) / "actuals.json")
    elif case != "missing":
        body = {"25h": _good(tmp_path, 25), "key-1-2h": _good(tmp_path, 2), "torn": '{"actuals_version": "1.0", ',
                "future": _good(tmp_path, -1), "not-actuals": {"x": 1}, "one-project": _good(tmp_path, 1, "alpha"),
                "1h": _good(tmp_path, 1), "refused-key": _good(tmp_path, 1)}[case]
        _default_file(tmp_path, body)
    store = tmp_path / "store"
    store.mkdir()
    _config(tmp_path, archive=store, extra_archive=extra)
    run = _cli("preflight", "--if-stale", timeout=20)
    assert run.returncode == expected, run.stderr
    if case == "refused-key":
        assert run.stderr.decode().splitlines() == [
            "actuals: [archive].actuals_max_age_hours must be a number of hours, 0 < x <= 168: 0"]
    else:
        assert run.stderr == b"" and run.stdout == b""


def test_stdout_is_utf8_lf_bytes(tmp_path):
    _config(tmp_path)
    a = tmp_path / "A"
    _gz(a / "h1" / "-work-ñ" / "S.jsonl.gz", [_in(_m("u1", _usage(inp=1), "claude-a"), "/work/ñ/ø")])
    env = {**_ok_manifest(tmp_path), "PYTHONIOENCODING": "ascii"}
    run = _cli("build", "--archive", a, "--stdout", env=env)
    assert run.returncode == 0, run.stderr
    assert b"\r" not in run.stdout and run.stdout.endswith(b"}\n")
    assert "/work/ñ/ø".encode("utf-8") in run.stdout
    doc = json.loads(run.stdout.decode("utf-8"))
    assert doc["unassigned"][0]["cwd"] == "/work/ñ/ø"
    assert run.stdout == ac.render(doc)


def test_milestones_output_must_end_in_a_newline(tmp_path):
    """A last line that parses but has lost its newline was cut mid-write: not whole JSON Lines."""
    _config(tmp_path)
    env = _manifest(tmp_path, [("alpha", 0, _jsonl(ALPHA_MS)[:-1], ""), ("beta", 0, _jsonl(BETA_MS), "")])
    doc = _build(tmp_path, archive=_archive(tmp_path), env=env)
    assert _sources(doc, "milestones")[0] == {"source": "milestones", "project": "alpha", "status": "missing",
                                              "detail": "exit 0: output is not whole JSON Lines"}
    assert _issue(doc, "alpha", "Issue-4")["milestones"] is None
