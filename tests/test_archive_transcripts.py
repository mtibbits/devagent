"""Tests for scripts/lib/archive-transcripts.py (#731): the durable transcript archive.

Config, refusals and host partition (Task 3); archive behaviour and the
round trip through cost-report (Task 4). Every archive root lives under
tmp_path/store, never inside a git work tree.
"""
import gzip
import hashlib
import importlib.util
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import time
import zlib
from pathlib import Path

import pytest

from test_cost_report import _call, _dispatch, _result, _tool, _usage, _write

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "scripts" / "lib" / "archive-transcripts.py"
COST = REPO / "scripts" / "lib" / "cost-report.py"

spec = importlib.util.spec_from_file_location("archive_transcripts", HELPER)
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)

P = "archive-transcripts: "

# One process-wide audit hook (hooks cannot be removed): while _OPENS is a
# list, every opened path is appended to it.
_OPENS = None


def _audit(event, args):
    if _OPENS is not None and event == "open" and args and isinstance(args[0], (str, bytes, os.PathLike)):
        _OPENS.append(os.path.normcase(os.path.realpath(os.fsdecode(args[0]))))


sys.addaudithook(_audit)


@pytest.fixture(autouse=True)
def _hermetic(tmp_path, monkeypatch):
    """No test reads the operator's config.toml, ~/.claude or archive."""
    for sub in ("da-home", "claude", "cwd", "store"):
        (tmp_path / sub).mkdir()
    monkeypatch.setenv("DA_HOME", str(tmp_path / "da-home"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "claude"))
    monkeypatch.chdir(tmp_path / "cwd")


def _config_path():
    return Path(os.environ["DA_HOME"]) / "config.toml"


def _cfg(tdir=None, host_id="h1", exclude=None, extra=""):
    lines = ["[archive]"]
    if tdir is not None:
        lines.append(f"transcripts_dir = {json.dumps(str(tdir))}")
    if host_id is not None:
        lines.append(f"host_id = {json.dumps(host_id)}")
    if exclude is not None:
        lines.append(f"exclude = {json.dumps(exclude)}")
    _config_path().write_text("\n".join(lines) + "\n" + extra, encoding="utf-8")


def _run(*args, env=None):
    return subprocess.run([sys.executable, str(HELPER), *map(str, args)],
                          capture_output=True, encoding="utf-8", env=env)


def _snapshot(root):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for n in dirnames + filenames:
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            out[os.path.relpath(p, root)] = (st.st_size if n in filenames else 0, st.st_mtime_ns)
    return out


def _projects():
    return Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects"


WF = "wf_1a2b3c4d-5e6"


def _corpus(mtime=1_700_000_000):
    """Two cwd dirs: S1 (dispatch, an Agent subagent, a workflow agent, journal,
    tool-results) and S2; a memory/ dir. Returns the archived source files."""
    root = _projects()
    a, b = root / "c--src-a", root / "c--src-b"
    s1 = [{**r, "sessionId": "S1"} for r in [
        *_dispatch("b1", "alpha", "Issue-4", 9, "implement", "d1"),
        _call("m1", _usage(inp=100), _tool("a1", "Agent", description="x")),
        _call("m2", _usage(inp=1), _tool("w1", "Workflow", script="x")),
        _result("w1", f"Run ID: {WF}"),
        _call("m3", _usage(read=1000)),
    ]]
    _write(a / "S1.jsonl", s1, mtime=mtime)
    sub = a / "S1" / "subagents"
    _write(sub / "agent-a.jsonl", [_call("sa1", _usage(out=10))], mtime=mtime + 1)
    (sub / "agent-a.meta.json").write_text(json.dumps({"toolUseId": "a1"}), encoding="utf-8")
    wdir = sub / "workflows" / WF
    _write(wdir / "agent-w.jsonl", [_call("sw1", _usage(out=20))], mtime=mtime + 2)
    (wdir / "agent-w.meta.json").write_text(json.dumps({"agentType": "x"}), encoding="utf-8")
    _write(wdir / "journal.jsonl", [{"type": "started"}], mtime=mtime + 3)
    _write(a / "S1" / "tool-results" / "r.txt", [{"big": "x"}])
    _write(a / "memory" / "m.md", [{"m": 1}])
    _write(b / "S2.jsonl", [{**r, "sessionId": "S2"} for r in [
        *_dispatch("b2", "beta", "Issue-5", 2, "draft", "d2"), _call("n1", _usage(inp=7))]], mtime=mtime + 4)
    files = [a / "S1.jsonl", sub / "agent-a.jsonl", sub / "agent-a.meta.json", wdir / "agent-w.jsonl",
             wdir / "agent-w.meta.json", wdir / "journal.jsonl", b / "S2.jsonl"]
    for i, f in enumerate(files):
        os.utime(f, ns=(mtime * 10**9, (mtime + 10 + i) * 10**9 + 123))
    return files


def _store(tmp_path):
    return tmp_path / "store"


def _arch(tmp_path, src, host="h1"):
    rel = src.relative_to(_projects())
    name = rel.name + ".gz" if rel.name.endswith(".jsonl") else rel.name
    return _store(tmp_path) / host / rel.parent / name


def _counts(out):
    m = re.search(r"new (\d+), grown (\d+), unchanged (\d+), diverged (\d+), excluded (\d+)", out)
    assert m, out
    return tuple(map(int, m.groups()))


def _manifest(tmp_path, host="h1"):
    return [json.loads(ln) for ln in (_store(tmp_path) / host / "manifest.jsonl").read_text(encoding="utf-8").splitlines()]


def _members(path):
    """Decompressed bytes of each gzip member of path."""
    data, out = path.read_bytes(), []
    while data:
        d = zlib.decompressobj(31)
        out.append(d.decompress(data) + d.flush())
        data = d.unused_data
    return out


def _fs_preserves_modes(tmp_path):
    p = tmp_path / "modeprobe"
    p.write_text("x")
    os.chmod(p, 0o600)
    ok = stat.S_IMODE(os.stat(p).st_mode) == 0o600
    p.unlink()
    return ok


def _git_init(path):
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True, capture_output=True)


# --- Task 3: config, refusals, host partition --------------------------------

WT_MSG = ("[archive].transcripts_dir is inside a git work tree ({}); transcripts hold everything a "
          "session read, so the archive belongs on private storage outside any repository")


def _refusal_case(tmp_path, case):
    """Configure one refusal; return its exact stderr line."""
    if case == "unset":
        _config_path().write_text('[project.x]\nsource_dir = "/x"\n', encoding="utf-8")
        return f"[archive].transcripts_dir is not set in {_config_path()}"
    if case == "relative":
        _cfg("rel/store")
        return ("[archive].transcripts_dir must be an absolute path: rel/store "
                "(on Windows use a drive-letter path, e.g. C:/Users/me/archive)")
    if case in ("work-tree", "git-dir", "work-tree-symlink"):
        repo = tmp_path / "repo"
        _git_init(repo)
        if case == "work-tree":
            t = repo / "a" / "b"
        elif case == "git-dir":
            t = repo / ".git" / "x"
        else:
            link = tmp_path / "link"
            try:
                os.symlink(repo, link, target_is_directory=True)
            except (OSError, NotImplementedError):
                pytest.skip("symlinks not available")
            t = link / "a"
        _cfg(t)
        return WT_MSG.format(os.path.realpath(t))
    if case in ("projects-root", "projects-root-symlink"):
        root = _projects()
        root.mkdir(parents=True, exist_ok=True)
        t = root / "arch"
        if case == "projects-root-symlink":
            link = tmp_path / "plink"
            try:
                os.symlink(Path(os.environ["CLAUDE_CONFIG_DIR"]), link, target_is_directory=True)
            except (OSError, NotImplementedError):
                pytest.skip("symlinks not available")
            t = link / "projects" / "arch"
        _cfg(t)
        return f"[archive].transcripts_dir is inside {root}, where Claude Code deletes old transcripts"
    if case == "unknown-key":
        _cfg(_store(tmp_path), extra='excludes = ["*private*"]\n')
        return "[archive].excludes is not a known key (transcripts_dir, host_id, exclude)"
    if case == "subtable":
        _cfg(_store(tmp_path), extra='\n[archive.x]\nexclude = ["*"]\n')
        return "[archive].x is not a known key (transcripts_dir, host_id, exclude)"
    if case == "exclude-type":
        _cfg(_store(tmp_path), exclude="*private*")
        return "[archive].exclude must be a list of strings"
    raise AssertionError(case)


REFUSALS = ["unset", "relative", "work-tree", "work-tree-symlink", "git-dir",
            "projects-root", "projects-root-symlink", "unknown-key", "subtable", "exclude-type"]


@pytest.mark.parametrize("case", REFUSALS)
def test_refusals_exit_2_and_write_nothing(tmp_path, case):
    _corpus()
    expected = _refusal_case(tmp_path, case)
    before = _snapshot(tmp_path)
    run = _run()
    assert run.returncode == 2, (run.stdout, run.stderr)
    assert run.stderr.splitlines() == [P + expected]
    assert run.stdout == ""
    assert _snapshot(tmp_path) == before


@pytest.mark.parametrize("value", ["a/b", "a\\b", "..", "a..b", ".", "a b", ""])
def test_refuses_host_id(tmp_path, value):
    _corpus()
    _cfg(_store(tmp_path), host_id=value)
    before = _snapshot(tmp_path)
    run = _run()
    assert run.returncode == 2
    assert run.stderr.splitlines() == [
        P + f'[archive].host_id must match [A-Za-z0-9._-]+, without ".." and not ".": {value}']
    assert _snapshot(tmp_path) == before


@pytest.mark.parametrize("value", ["h1", "laptop-dad-wsl", "a.b", "A_9"])
def test_accepts_host_id(tmp_path, value):
    _corpus()
    _cfg(_store(tmp_path), host_id=value)
    run = _run()
    assert run.returncode == 0, run.stderr
    assert (_store(tmp_path) / value / "last-run").is_file()


@pytest.mark.skipif(os.name != "nt", reason="Windows junctions only")
def test_refuses_dir_inside_a_work_tree_through_a_junction(tmp_path):
    repo = tmp_path / "repo"
    _git_init(repo)
    junction = tmp_path / "junction"
    subprocess.run(["cmd", "/c", "mklink", "/J", str(junction), str(repo)], check=True, capture_output=True)
    t = junction / "a" / "b"
    _cfg(t)
    before = _snapshot(tmp_path)
    run = _run()
    assert run.returncode == 2
    assert run.stderr.splitlines() == [P + WT_MSG.format(os.path.realpath(t))]
    assert os.path.normcase(os.path.realpath(t)).startswith(os.path.normcase(str(repo)))
    assert _snapshot(tmp_path) == before


def _path_with_stub_git(tmp_path, body):
    d = tmp_path / "stubbin"
    d.mkdir()
    if os.name == "nt":
        (d / "git.bat").write_text(f"@echo off\r\n{body}\r\n", encoding="utf-8")
    else:
        g = d / "git"
        g.write_text(f"#!/bin/sh\n{body}\n", encoding="utf-8")
        g.chmod(0o755)
    return str(d)


@pytest.mark.parametrize("stub", ["exit-1", "absent"])
def test_git_undetermined_refuses(tmp_path, stub):
    _corpus()
    _cfg(_store(tmp_path) / "x")
    env = dict(os.environ)
    if stub == "exit-1":
        env["PATH"] = _path_with_stub_git(tmp_path, "exit 1" if os.name != "nt" else "exit /b 1")
        why = "rc 1"
    else:
        (tmp_path / "empty-bin").mkdir()
        env["PATH"] = str(tmp_path / "empty-bin")
        why = "git not found"
    before = _snapshot(tmp_path)
    run = _run(env=env)
    assert run.returncode == 2
    resolved = os.path.realpath(_store(tmp_path) / "x")
    assert run.stderr.splitlines() == [
        P + f"cannot tell whether {resolved} is inside a git work tree ({why}); refusing"]
    assert _snapshot(tmp_path) == before


def test_if_configured_without_archive_is_silent(tmp_path):
    _corpus()
    before = _snapshot(tmp_path)
    for body in (None, '[project.x]\nsource_dir = "/x"\n', '[archive]\nhost_id = "h1"\n'):
        if body is None:
            _config_path().unlink(missing_ok=True)
        else:
            _config_path().write_text(body, encoding="utf-8")
        before = _snapshot(tmp_path)
        run = _run("--if-configured")
        assert (run.returncode, run.stdout, run.stderr) == (0, "", ""), body
        assert _snapshot(tmp_path) == before
        bare = _run()
        assert bare.returncode == 2
        assert bare.stderr.splitlines() == [P + f"[archive].transcripts_dir is not set in {_config_path()}"]


def test_if_configured_with_transcripts_dir_archives(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    run = _run("--if-configured")
    assert run.returncode == 0, run.stderr
    assert _counts(run.stdout)[0] == 7


@pytest.mark.parametrize("osrelease,suffix", [
    ("5.15.153.1-microsoft-standard-WSL2", "-wsl"),
    ("4.4.0-19041-Microsoft", "-wsl"),
    ("6.8.0-45-generic", ""),
    (None, ""),
])
def test_host_id_default_appends_wsl(tmp_path, monkeypatch, capsys, osrelease, suffix):
    _corpus()
    _cfg(_store(tmp_path), host_id=None)
    f = tmp_path / "osrelease"
    if osrelease is not None:
        f.write_text(osrelease + "\n", encoding="utf-8")
    monkeypatch.setattr(ar, "OSRELEASE", str(f))
    assert ar.main([]) == 0, capsys.readouterr().err
    assert [p.name for p in _store(tmp_path).iterdir()] == [socket.gethostname() + suffix]
    assert ar.default_host_id("box", str(f)) == "box" + suffix


def test_configured_host_id_wins(tmp_path):
    _corpus()
    _cfg(_store(tmp_path), host_id="box1")
    assert _run().returncode == 0
    assert [p.name for p in _store(tmp_path).iterdir()] == ["box1"]


def test_exclude_globs_skip_matching_slugs(tmp_path):
    files = _corpus()
    _write(_projects() / "c--src-Private-x" / "P.jsonl", [_call("p1", _usage(inp=1))])
    _write(_projects() / "c--src-Private-x" / "P" / "subagents" / "agent-p.jsonl", [_call("p2", _usage(inp=1))])
    _cfg(_store(tmp_path), exclude=["*private*"])
    run = _run()
    assert run.returncode == 0, run.stderr
    assert not (_store(tmp_path) / "h1" / "c--src-Private-x").exists()
    assert _counts(run.stdout) == (len(files), 0, 0, 0, 2)


# --- Task 4: behaviour and round trip ----------------------------------------

def _archive(capsys=None):
    run = _run()
    assert run.returncode == 0, run.stderr
    return run


def test_first_run_archives_every_session_and_subagent(tmp_path):
    files = _corpus()
    _cfg(_store(tmp_path))
    run = _archive()
    assert run.stdout.splitlines() == [
        P + f"h1: new {len(files)}, grown 0, unchanged 0, diverged 0, excluded 0 "
            f"({os.path.join(str(_store(tmp_path)), 'h1')})"]
    for src in files:
        a = _arch(tmp_path, src)
        assert a.is_file(), a
        got = gzip.decompress(a.read_bytes()) if a.name.endswith(".jsonl.gz") else a.read_bytes()
        assert got == src.read_bytes()
    h = _store(tmp_path) / "h1"
    assert not (h / "c--src-a" / "S1" / "tool-results").exists()
    assert not (h / "c--src-a" / "memory").exists()
    man = _manifest(tmp_path)
    assert len(man) == len(files)
    assert {m["source"] for m in man} == {src.relative_to(_projects()).as_posix() for src in files}
    for m in man:
        assert set(m) == {"archive", "archive_size", "mtime_ns", "session", "sha256", "size", "source"}
        src = _projects() / m["source"]
        assert m["size"] == src.stat().st_size
        assert m["sha256"] == hashlib.sha256(src.read_bytes()).hexdigest()
        assert m["mtime_ns"] == src.stat().st_mtime_ns
        assert m["archive_size"] == (h / m["archive"]).stat().st_size
        assert m["session"] == m["source"].split("/")[1].split(".")[0]
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\n", (h / "last-run").read_text(encoding="utf-8"))


def test_second_run_is_a_no_op(tmp_path, capsys):
    global _OPENS
    files = _corpus()
    _cfg(_store(tmp_path))
    wanted = {os.path.normcase(os.path.realpath(f)) for f in files}
    _OPENS = []
    try:
        assert ar.main([]) == 0
        first = set(_OPENS)
        assert wanted <= first                       # positive control: the hook sees source opens
        h = _store(tmp_path) / "h1"
        os.utime(h / "last-run", ns=(0, 0))
        before = _snapshot(_store(tmp_path))
        capsys.readouterr()
        _OPENS = []
        assert ar.main([]) == 0
        second = set(_OPENS)
    finally:
        _OPENS = None
    assert not (wanted & second)
    assert _counts(capsys.readouterr().out) == (0, 0, len(files), 0, 0)
    after = _snapshot(_store(tmp_path))
    lr = os.path.join("h1", "last-run")
    assert after.pop(lr)[1] != before.pop(lr)[1]     # the stamp is rewritten (intent Answers 1)
    assert after == before


def _src(name):
    return _projects() / "c--src-a" / name


def test_grown_source_appends_one_member(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    _archive()
    s = _src("S1.jsonl")
    old = s.read_bytes()
    extra = (json.dumps(_call("m9", _usage(inp=3))) + "\n").encode()
    with open(s, "ab") as f:
        f.write(extra)
    run = _archive()
    assert _counts(run.stdout) == (0, 1, 6, 0, 0)
    a = _arch(tmp_path, s)
    members = _members(a)
    assert members == [old, extra]
    assert gzip.decompress(a.read_bytes()) == s.read_bytes()
    last = [m for m in _manifest(tmp_path) if m["source"] == "c--src-a/S1.jsonl"][-1]
    assert last["size"] == len(old) + len(extra)
    assert last["sha256"] == hashlib.sha256(s.read_bytes()).hexdigest()
    assert last["archive_size"] == a.stat().st_size


def _sha6(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:6]


def test_truncated_source_is_kept_and_written_beside(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    _archive()
    s = _src("S1.jsonl")
    a = _arch(tmp_path, s)
    kept = a.read_bytes()
    s.write_bytes(s.read_bytes()[:50])
    run = _archive()
    assert _counts(run.stdout) == (0, 0, 6, 1, 0)
    beside = a.with_name(f"S1.{_sha6(s)}.jsonl.gz")
    assert a.read_bytes() == kept
    assert gzip.decompress(beside.read_bytes()) == s.read_bytes()
    assert P + f"diverged c--src-a/S1.jsonl.gz kept; source written as c--src-a/{beside.name}" in run.stdout.splitlines()
    with open(s, "ab") as f:
        f.write(b'{"more": 1}\n')
    run = _archive()
    assert _counts(run.stdout) == (0, 1, 6, 0, 0)
    assert a.read_bytes() == kept
    assert gzip.decompress(beside.read_bytes()) == s.read_bytes()


def test_same_size_new_content_is_diverged(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    _archive()
    s = _src("S1.jsonl")
    a = _arch(tmp_path, s)
    data = s.read_bytes()
    # Equal bytes, new mtime: unchanged, the archive mtime follows, a manifest line records it.
    os.utime(s, ns=(0, s.stat().st_mtime_ns + 5 * 10**9))
    run = _archive()
    assert _counts(run.stdout) == (0, 0, 7, 0, 0)
    assert a.stat().st_mtime_ns == s.stat().st_mtime_ns
    assert [m for m in _manifest(tmp_path) if m["source"] == "c--src-a/S1.jsonl"][-1]["mtime_ns"] == s.stat().st_mtime_ns
    # Equal size, other bytes: diverged.
    s.write_bytes(data.replace(b"implement", b"IMPLEMENT"))
    run = _archive()
    assert _counts(run.stdout) == (0, 0, 6, 1, 0)
    assert gzip.decompress(a.read_bytes()) == data


def test_torn_archive_is_never_appended_to(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    _archive()
    s = _src("S1.jsonl")
    a = _arch(tmp_path, s)
    with open(a, "ab") as f:
        f.write(b"\x1f\x8b junk from a crash")
    torn = a.read_bytes()
    with open(s, "ab") as f:
        f.write(b'{"more": 1}\n')
    run = _archive()
    assert _counts(run.stdout) == (0, 0, 6, 1, 0)
    assert a.read_bytes() == torn
    assert gzip.decompress(a.with_name(f"S1.{_sha6(s)}.jsonl.gz").read_bytes()) == s.read_bytes()


def test_planted_target_without_a_record_is_written_beside(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    s = _src("S1.jsonl")
    a = _arch(tmp_path, s)
    a.parent.mkdir(parents=True)
    a.write_bytes(b"planted")
    run = _archive()
    assert _counts(run.stdout) == (6, 0, 0, 1, 0)
    assert a.read_bytes() == b"planted"
    assert gzip.decompress(a.with_name(f"S1.{_sha6(s)}.jsonl.gz").read_bytes()) == s.read_bytes()


def test_diverged_name_collision_never_overwrites(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    _archive()
    s = _src("S1.jsonl")
    a = _arch(tmp_path, s)
    full = s.read_bytes()
    short = full[:60]
    s.write_bytes(short)
    _archive()                                   # S1.<sha6(short)> written
    b_name = a.with_name(f"S1.{_sha6(s)}.jsonl.gz")
    b_bytes = b_name.read_bytes()
    s.write_bytes(full + b'{"x": 1}\n')          # diverges from short again
    _archive()
    s.write_bytes(short)                          # back to short: its name exists with that sha
    os.utime(s, ns=(0, 1_800_000_000 * 10**9))
    before = _snapshot(_store(tmp_path) / "h1" / "c--src-a")
    run = _archive()
    assert _counts(run.stdout) == (0, 0, 7, 0, 0)
    assert b_name.read_bytes() == b_bytes
    assert _snapshot(_store(tmp_path) / "h1" / "c--src-a") == before
    # A name taken by OTHER content: the next free -<n> is used.
    other = b'{"other": 1}\n'
    s.write_bytes(other)
    planted = a.with_name(f"S1.{_sha6(s)}.jsonl.gz")
    planted.write_bytes(b"not this content")
    run = _archive()
    assert _counts(run.stdout) == (0, 0, 6, 1, 0)
    assert planted.read_bytes() == b"not this content"
    assert gzip.decompress(a.with_name(f"S1.{_sha6(s)}-1.jsonl.gz").read_bytes()) == other


def test_growth_compresses_only_the_new_bytes(tmp_path, monkeypatch, capsys):
    mb = int(os.environ.get("DEVAGENT_ARCHIVE_GROWTH_MB", "8"))
    _cfg(_store(tmp_path))
    s = _projects() / "c--big" / "B.jsonl"
    s.parent.mkdir(parents=True)
    line = (json.dumps(_call("m", _usage(inp=1))) + " " * 900 + "\n").encode()
    with open(s, "wb") as f:
        while f.tell() < mb * 2**20:
            f.write(line)
    assert ar.main([]) == 0
    a = _store(tmp_path) / "h1" / "c--big" / "B.jsonl.gz"
    size1 = a.stat().st_size
    appended = (2**20 // len(line) + 1) * len(line)   # just over 1 MB
    with open(s, "ab") as f:
        f.write(line * (appended // len(line)))
    spied = []
    real = ar._compress_member

    def spy(out, src, start, end, hasher):
        spied.append(end - start)
        return real(out, src, start, end, hasher)

    monkeypatch.setattr(ar, "_compress_member", spy)
    t0 = time.perf_counter()
    assert ar.main([]) == 0
    dt = time.perf_counter() - t0
    assert spied == [appended]
    members = _members(a)
    assert len(members) == 2 and members[1] == s.read_bytes()[-appended:]
    tail = a.read_bytes()[size1:]
    assert gzip.decompress(tail) == members[1]
    print(f"growth: prefix {mb} MB, appended {appended} bytes, archive {size1} -> {a.stat().st_size} bytes, "
          f"second run {dt:.3f}s")


def test_archived_files_keep_source_mtimes(tmp_path):
    files = _corpus()
    _cfg(_store(tmp_path))
    _archive()
    s = _src("S1.jsonl")
    with open(s, "ab") as f:
        f.write(b'{"g": 1}\n')                       # grown
    t = _src("S1/subagents/agent-a.jsonl")
    t.write_bytes(b'{"d": 1}\n')                       # diverged
    _archive()
    for m in _manifest(tmp_path):
        src = _projects() / m["source"]
        assert (_store(tmp_path) / "h1" / m["archive"]).stat().st_mtime_ns == src.stat().st_mtime_ns, m
    assert len(files) == 7


def test_modes_are_owner_only(tmp_path):
    if not _fs_preserves_modes(tmp_path):
        pytest.skip("filesystem does not honour POSIX modes")
    _corpus()
    _cfg(_store(tmp_path) / "new")
    _archive()
    for dirpath, dirnames, filenames in os.walk(_store(tmp_path) / "new"):
        assert stat.S_IMODE(os.stat(dirpath).st_mode) == 0o700, dirpath
        for n in filenames:
            assert stat.S_IMODE(os.stat(os.path.join(dirpath, n)).st_mode) == 0o600, n


def test_held_lock_exits_1_and_writes_nothing(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    _archive()
    h = _store(tmp_path) / "h1"
    lock = h / ".lock"
    before = _snapshot(_store(tmp_path))
    with ar.held_lock(lock) as got:
        assert got
        run = _run()
    assert run.returncode == 1
    assert run.stderr.splitlines() == [P + f"another run holds {lock}; nothing archived"]
    assert _snapshot(_store(tmp_path)) == before


def test_failed_file_exits_1_without_stamp(tmp_path):
    _corpus()
    s = _src("S1.jsonl")
    os.chmod(s, 0)
    try:
        try:
            open(s, "rb").close()
            pytest.skip("chmod 000 not honoured here")
        except PermissionError:
            pass
        _cfg(_store(tmp_path))
        run = _run()
    finally:
        os.chmod(s, 0o644)
    assert run.returncode == 1
    assert any(ln.startswith(P + "failed c--src-a/S1.jsonl (") for ln in run.stderr.splitlines())
    assert _counts(run.stdout) == (6, 0, 0, 0, 0)
    assert not (_store(tmp_path) / "h1" / "last-run").exists()


def _cost(*args):
    run = subprocess.run([sys.executable, str(COST), *map(str, args)], capture_output=True, encoding="utf-8")
    assert run.returncode == 0, run.stderr
    return run.stdout


def _json_by_host(out, mapping):
    objs = [json.loads(ln) for ln in out.splitlines() if ln]
    for o in objs:
        o["sources"] = sorted(({**s, "host": mapping.get(s["host"], s["host"])} for s in o["sources"]),
                              key=lambda s: (s["cwd_slug"], s["host"], s["session"]))
    return objs


def test_archive_alone_reports_what_live_dirs_reported(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    live = _cost("--all-dirs", "--summary")
    live_json = _cost("--all-dirs", "--json")
    assert "alpha/Issue-4" in live and "beta/Issue-5" in live
    _archive()
    shutil.rmtree(_projects())
    assert _cost("--archive", _store(tmp_path), "--summary") == live
    assert _json_by_host(_cost("--archive", _store(tmp_path), "--json"), {}) == _json_by_host(live_json, {"local": "h1"})


def test_session_in_two_hosts_and_live_counts_once(tmp_path):
    _corpus()
    _cfg(_store(tmp_path))
    live = {(o["project"], o["issue"]): o for o in _json_by_host(_cost("--all-dirs", "--json"), {})}
    _archive()
    shutil.copytree(_store(tmp_path) / "h1", _store(tmp_path) / "h2")
    both = {(o["project"], o["issue"]): o for o in
            _json_by_host(_cost("--archive", _store(tmp_path), "--all-dirs", "--json"), {})}
    assert set(both) == set(live)
    for k, o in both.items():
        for f in ("calls", "main", "subagents", "total", "sessions"):
            assert o[f] == live[k][f], (k, f)
        hosts = sorted(s["host"] for s in o["sources"])
        sessions = {s["session"] for s in o["sources"]}
        assert hosts == sorted(["h1", "h2", "local"] * len(sessions)), o["sources"]
    assert both[("alpha", "Issue-4")]["subagents"] == live[("alpha", "Issue-4")]["subagents"] == 150
    summary = _cost("--archive", _store(tmp_path), "--all-dirs", "--summary")
    assert "beta/Issue-5: " in summary and "over 1 session(s)" in summary.split("beta/Issue-5: ")[1].splitlines()[0]
