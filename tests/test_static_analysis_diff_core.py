"""#249 — direct pytest coverage for the pure, deterministic core of
static_analysis_diff.py (the analyze-step engine, workflow step 13).

Before this module the parsing/filtering core had no direct unit coverage: the
existing pytest only exercised subprocess timeout handling, and the integration
bats test treats parsing as a black box. A silent regression in diff-range
parsing or the novelty gate would drop real findings or mis-report pre-existing
ones as novel — failure modes a green ctest/bats run would not catch.

Hermetic: the module is loaded via importlib (it lives at repo root, not a
package), subprocess.run is monkeypatched with canned `git diff` output, and
normalize_path uses tmp_path — no real git, tools, or build.
"""
import importlib.util
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "static_analysis_diff", REPO / "static_analysis_diff.py"
)
sad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sad)


def _git_subcommand(cmd) -> str:
    """The git subcommand in `cmd`, past any leading `-C <dir>` / `-c <k=v>` pair."""
    i = 1
    while i + 1 < len(cmd) and cmd[i] in ("-C", "-c"):
        i += 2
    return cmd[i] if i < len(cmd) else ""


def _stub_git(monkeypatch, *, diff="", ls_files="", returncode=0, stderr="",
              calls=None):
    """subprocess.run fake that dispatches on the git SUBCOMMAND (#591).

    The pre-#591 fake returned ONE canned string for every call, so any code path
    making a second git call fed `git diff` text to the other parser (or an empty
    string to the diff parser). Route on the subcommand instead, and record every
    call in `calls` (subcommand -> [argv, ...]) when one is given, so a test can
    assert about the call it MEANS rather than about whichever ran last.
    """
    outputs = {"diff": diff, "ls-files": ls_files}

    def fake_run(cmd, *args, **kwargs):
        sub = _git_subcommand(cmd)
        if calls is not None:
            calls.setdefault(sub, []).append(list(cmd))
        return subprocess.CompletedProcess(
            cmd, returncode, stdout=outputs.get(sub, ""), stderr=stderr)

    monkeypatch.setattr(sad.subprocess, "run", fake_run)


def _stub_git_diff(monkeypatch, stdout, returncode=0, stderr=""):
    """Install a subprocess.run that returns canned `git diff` output.

    Kept as the four existing call sites' entry point — their bodies are unchanged
    — but now routed through _stub_git, so a `git ls-files` call reaching this fake
    gets an empty result instead of diff text.
    """
    _stub_git(monkeypatch, diff=stdout, returncode=returncode, stderr=stderr)


# --------------------------------------------------------------------------
# LineRange.end
# --------------------------------------------------------------------------

def test_linerange_end_multi_line():
    # start=10, count=3 covers lines 10,11,12 → end == 12.
    assert sad.LineRange(10, 3).end == 12


def test_linerange_end_single_line():
    assert sad.LineRange(42, 1).end == 42


def test_linerange_end_zero_count_falls_back_to_start():
    # count == 0 (a pure deletion shape) → end == start, not start-1.
    assert sad.LineRange(7, 0).end == 7


# --------------------------------------------------------------------------
# line_in_ranges
# --------------------------------------------------------------------------

def test_line_in_ranges_boundaries_inclusive():
    ranges = [sad.LineRange(10, 3)]  # 10..12 inclusive
    assert sad.line_in_ranges(10, ranges) is True   # start boundary
    assert sad.line_in_ranges(12, ranges) is True   # end boundary
    assert sad.line_in_ranges(11, ranges) is True   # interior


def test_line_in_ranges_just_outside():
    ranges = [sad.LineRange(10, 3)]  # 10..12
    assert sad.line_in_ranges(9, ranges) is False
    assert sad.line_in_ranges(13, ranges) is False


def test_line_in_ranges_empty():
    assert sad.line_in_ranges(5, []) is False


def test_line_in_ranges_multiple_ranges():
    ranges = [sad.LineRange(1, 2), sad.LineRange(100, 1)]  # 1..2 and 100
    assert sad.line_in_ranges(2, ranges) is True
    assert sad.line_in_ranges(100, ranges) is True
    assert sad.line_in_ranges(50, ranges) is False


# --------------------------------------------------------------------------
# get_changed_ranges (canned `git diff --unified=0` via monkeypatched run)
# --------------------------------------------------------------------------

def test_get_changed_ranges_multi_hunk(monkeypatch):
    diff = (
        "diff --git a/lib/foo.cc b/lib/foo.cc\n"
        "--- a/lib/foo.cc\n"
        "+++ b/lib/foo.cc\n"
        "@@ -10,0 +11,2 @@ ctx\n"
        "+added one\n"
        "+added two\n"
        "@@ -30,1 +33,1 @@ ctx\n"
        "+changed\n"
    )
    _stub_git_diff(monkeypatch, diff)
    ranges = sad.get_changed_ranges("origin/main")
    assert "lib/foo.cc" in ranges
    got = [(r.start, r.count) for r in ranges["lib/foo.cc"]]
    assert got == [(11, 2), (33, 1)]


def test_get_changed_ranges_no_count_defaults_to_one(monkeypatch):
    # `@@ ... +N @@` with no ",count" → count defaults to 1.
    diff = (
        "+++ b/a.py\n"
        "@@ -5 +5 @@\n"
        "+single line change\n"
    )
    _stub_git_diff(monkeypatch, diff)
    ranges = sad.get_changed_ranges("base")
    assert [(r.start, r.count) for r in ranges["a.py"]] == [(5, 1)]


def test_get_changed_ranges_skips_pure_deletion(monkeypatch):
    # A pure-deletion hunk is `+N,0` → must be skipped (count == 0).
    diff = (
        "+++ b/del.c\n"
        "@@ -8,3 +7,0 @@ ctx\n"
    )
    _stub_git_diff(monkeypatch, diff)
    ranges = sad.get_changed_ranges("base")
    # File header still registers the key, but no range is recorded.
    assert ranges == {"del.c": []}


def test_get_changed_ranges_exits_on_git_failure(monkeypatch):
    _stub_git_diff(monkeypatch, stdout="", returncode=1, stderr="fatal: bad revision")
    with pytest.raises(SystemExit) as exc:
        sad.get_changed_ranges("nope")
    assert exc.value.code == 1


def test_get_changed_ranges_passes_files_filter(monkeypatch):
    # When files= is given, the git command must include `-- <files>`.
    captured = {}

    def fake_run(cmd, *args, **kwargs):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    sad.get_changed_ranges("base", files=["lib/x.cc"])
    assert "--" in captured["cmd"]
    assert captured["cmd"][captured["cmd"].index("--") + 1:] == ["lib/x.cc"]


def test_get_changed_ranges_diffs_working_tree_not_head(monkeypatch):
    # #273: the diff must be scoped to the working tree (bare base_ref), NOT
    # base_ref..HEAD. The analyze step runs before commit, so a HEAD-anchored
    # diff is empty on uncommitted edits and every linter skips vacuously.
    captured = {}

    def fake_run(cmd, *args, **kwargs):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    sad.get_changed_ranges("origin/main")
    assert "origin/main..HEAD" not in captured["cmd"]
    assert "origin/main" in captured["cmd"]
    assert "HEAD" not in captured["cmd"]


def test_run_clang_format_diffs_working_tree_not_head(monkeypatch):
    # #273: run_clang_format must likewise scope to the working tree — drop the
    # `HEAD` endpoint so `git clang-format --diff base_ref -- <files>` checks
    # uncommitted edits. src_files must be non-empty or the function returns
    # early before building the command.
    captured = {}

    def fake_run(cmd, *args, **kwargs):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    sad.run_clang_format("origin/main", ["lib/x.cc"], repo_root="/repo")
    assert "HEAD" not in captured["cmd"]
    assert "origin/main" in captured["cmd"]
    assert "--" in captured["cmd"]
    assert captured["cmd"][captured["cmd"].index("--") + 1:] == ["lib/x.cc"]


# --------------------------------------------------------------------------
# get_untracked_ranges (#591 — untracked, non-ignored source files)
# --------------------------------------------------------------------------

def _nul(*paths):
    """`git ls-files -z` output: NUL-TERMINATED, no trailing newline."""
    return "".join(p + "\0" for p in paths)


def test_get_untracked_ranges_gives_a_whole_file_range(monkeypatch, tmp_path):
    (tmp_path / "new.py").write_text("a = 1\nb = 2\nc = 3\n")
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files=_nul("new.py"))
    ranges = sad.get_untracked_ranges()
    assert [(r.start, r.count) for r in ranges["new.py"]] == [(1, 3)]


def test_get_untracked_ranges_empty_file_gets_one_line_range(monkeypatch, tmp_path):
    # A 0-line file must neither crash nor produce a nonsense LineRange(1, 0).
    (tmp_path / "empty.py").write_text("")
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files=_nul("empty.py"))
    ranges = sad.get_untracked_ranges()
    assert [(r.start, r.count) for r in ranges["empty.py"]] == [(1, 1)]


def test_get_untracked_ranges_filters_to_source_suffixes(monkeypatch, tmp_path):
    # The candidate set mirrors the run_* filters; an unfiltered ls-files would
    # feed codespell a target project's build clutter and arbitrary text.
    for name in ("a.py", "b.cc", "c.h", "d.cmake", "CMakeLists.txt",
                 "notes.txt", "README.md"):
        (tmp_path / name).write_text("x\n")
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files=_nul(
        "a.py", "b.cc", "c.h", "d.cmake", "CMakeLists.txt", "notes.txt", "README.md"))
    assert sorted(sad.get_untracked_ranges()) == [
        "CMakeLists.txt", "a.py", "b.cc", "c.h", "d.cmake"]


def test_get_untracked_ranges_excludes_analyzer_build_dirs(monkeypatch, tmp_path):
    # A target project's .gitignore may not carry build-*/; a CMake configure in
    # the repo then leaves thousands of generated sources ls-files WOULD list.
    # Two exclusion keys (improve bug 1): the EXPLICIT dirs main() passes
    # (build_dir + its -asan/-ubsan/-tsan siblings) AND, unconditionally, any
    # root-level `build-*` component — analyze-sanitizers.sh builds at
    # <source_dir>/build-<project>-<issue>-{asan,ubsan,tsan} regardless of an
    # operator-configured build_dir, so `build-proj-Issue-1-ubsan` below is NOT
    # in the explicit list and must still be excluded. `builder/` (no hyphen)
    # must SURVIVE: the rejected bare build*/ proxy would have dropped it.
    (tmp_path / "new.py").write_text("x\n")
    for d in ("bd", "bd-asan", "bd-ubsan", "bd-tsan",
              "build-proj-Issue-1-ubsan", "builder"):
        (tmp_path / d).mkdir()
        (tmp_path / d / "gen.py").write_text("x\n")
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files=_nul(
        "new.py", "bd/gen.py", "bd-asan/gen.py", "bd-ubsan/gen.py",
        "bd-tsan/gen.py", "build-proj-Issue-1-ubsan/gen.py", "builder/gen.py"))
    ranges = sad.get_untracked_ranges(
        None, [str(tmp_path / "bd"), str(tmp_path / "bd-asan"),
               str(tmp_path / "bd-ubsan"), str(tmp_path / "bd-tsan")])
    # new.py and builder/gen.py are the POSITIVE controls: without them, "the
    # generated files are absent" is equally satisfied by an enumeration that
    # found nothing (Issue-337).
    assert sorted(ranges) == ["builder/gen.py", "new.py"]


def test_get_untracked_ranges_passes_files_pathspec(monkeypatch, tmp_path):
    (tmp_path / "a.py").write_text("x\n")
    monkeypatch.chdir(tmp_path)
    calls = {}
    _stub_git(monkeypatch, ls_files=_nul("a.py"), calls=calls)
    sad.get_untracked_ranges(files=["a.py"])
    cmd = calls["ls-files"][0]
    assert cmd[cmd.index("--") + 1:] == ["a.py"]


def test_get_untracked_ranges_uses_nul_and_full_name(monkeypatch, tmp_path):
    # -z: ls-files QUOTES a non-ASCII name by default ("caf\303\251.py"), which
    # would never match normalize_path()'s output in filter_novel().
    # --full-name: ls-files prints CWD-relative paths by default, unlike
    # `git diff`'s repo-root-relative `+++ b/` names (both measured, #591).
    (tmp_path / "has space.py").write_text("x\n")
    monkeypatch.chdir(tmp_path)
    calls = {}
    _stub_git(monkeypatch, ls_files=_nul("has space.py"), calls=calls)
    ranges = sad.get_untracked_ranges()
    assert "-z" in calls["ls-files"][0]
    assert "--full-name" in calls["ls-files"][0]
    assert "has space.py" in ranges          # behavioural leg: the split is on NUL


def test_get_untracked_ranges_clean_tree_adds_nothing(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files="")
    assert sad.get_untracked_ranges() == {}


def test_get_untracked_ranges_skips_a_listed_but_unreadable_path(monkeypatch, tmp_path, capsys):
    # Listed by git, gone by the time we read it (a race, a broken symlink): skip
    # it, never abort the whole analyze run — but SAY SO (improve bug 4: a silent
    # skip collapses absent / unreadable / mis-decoded into a pass with no
    # evidence). real.py is the positive control.
    (tmp_path / "real.py").write_text("x\n")
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files=_nul("real.py", "vanished.py"))
    assert sorted(sad.get_untracked_ranges()) == ["real.py"]
    assert "skipping unreadable untracked candidate: vanished.py" in capsys.readouterr().err


def test_get_untracked_ranges_exits_on_git_failure(monkeypatch, tmp_path):
    # Parity with get_changed_ranges: a swallowed enumeration failure IS an empty
    # untracked set, i.e. the vacuous pass this function removes (Issue-314).
    monkeypatch.chdir(tmp_path)
    _stub_git(monkeypatch, ls_files="", returncode=128, stderr="fatal: not a git repo")
    with pytest.raises(SystemExit) as exc:
        sad.get_untracked_ranges()
    assert exc.value.code == 1


def test_untracked_suffixes_each_reach_a_runner(monkeypatch, tmp_path):
    # improve tripwire (lawfirm Issue-7 / devagent Issue-5): the candidate suffix
    # set hand-mirrors the run_* filters. An entry no runner selects is a
    # permanently open hole, so assert each one is DETECTED — it lands in at
    # least one per-file runner's argv (read from the fake, not from the source).
    monkeypatch.chdir(tmp_path)
    # ruff / cmake-lint probe their venv binary with os.path.isfile before running;
    # make the probe succeed so the argv is built.
    monkeypatch.setattr(sad.os.path, "isfile", lambda p: True)
    for suffix in sad._UNTRACKED_SOURCE_SUFFIXES:
        name = suffix if suffix == "CMakeLists.txt" else "probe" + suffix
        (tmp_path / name).write_text("x\n")
        seen = []

        def fake_run(cmd, *args, **kwargs):
            seen.append(list(cmd))
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
        monkeypatch.setattr(sad.subprocess, "run", fake_run)
        for runner in (sad.run_cpplint, sad.run_ruff, sad.run_cmake_lint):
            runner([name], str(tmp_path))
        assert any(name in cmd for cmd in seen), f"{suffix} reaches no runner"


# --------------------------------------------------------------------------
# parse_file_line
# --------------------------------------------------------------------------

def test_parse_file_line_clang_tidy_gcc_style():
    # file:line:col: form (clang-tidy / cppcheck / gcc).
    f, ln = sad.parse_file_line("/path/file.cc:42:5: warning: something")
    assert (f, ln) == ("/path/file.cc", 42)


def test_parse_file_line_col_optional():
    # file:line: form with no column digits. NOTE: this matches the FIRST regex
    # (`...:\d*:?\s` with \d* empty and :? absent), not the second — the first
    # regex's optional column already covers it. Result is identical either way.
    f, ln = sad.parse_file_line("lib/foo.cc:13: warning: msg")
    assert (f, ln) == ("lib/foo.cc", 13)


def test_parse_file_line_cpplint_style():
    # cpplint emits `file:line:  msg  [cat] [sev]`. This too is absorbed by the
    # FIRST regex (\d* matches the empty column), so the dedicated cpplint regex
    # (the second branch) is effectively unreachable given the first's
    # permissiveness — see imPlan-potentialFutureEnhancements.md. The parsed
    # (file, line) is correct regardless, which is what this asserts.
    f, ln = sad.parse_file_line("file.cc:88:  Missing space  [whitespace] [4]")
    assert (f, ln) == ("file.cc", 88)


def test_parse_file_line_no_match_returns_none():
    assert sad.parse_file_line("just a message with no location") == (None, None)


# --------------------------------------------------------------------------
# normalize_path
# --------------------------------------------------------------------------

def test_normalize_path_absolute_to_relative(tmp_path):
    repo = tmp_path / "repo"
    (repo / "lib").mkdir(parents=True)
    target = repo / "lib" / "foo.cc"
    target.write_text("")
    assert sad.normalize_path(str(target), str(repo)) == "lib/foo.cc"


def test_normalize_path_outside_repo_returns_input(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    outside = tmp_path / "elsewhere" / "bar.cc"
    outside.parent.mkdir()
    outside.write_text("")
    # Path is not under repo_root → ValueError → returns the input unchanged.
    assert sad.normalize_path(str(outside), str(repo)) == str(outside)


# --------------------------------------------------------------------------
# filter_novel
# --------------------------------------------------------------------------

def _finding(file, line):
    return sad.Finding(tool="t", severity="warning", file=file, line=line, message="m")


def test_filter_novel_line_inside_range_is_novel():
    ranges = {"a.cc": [sad.LineRange(10, 3)]}  # 10..12
    f = _finding("a.cc", 11)
    sad.filter_novel([f], ranges)
    assert f.novel is True


def test_filter_novel_line_outside_range_not_novel():
    ranges = {"a.cc": [sad.LineRange(10, 3)]}
    f = _finding("a.cc", 99)
    sad.filter_novel([f], ranges)
    assert f.novel is False


def test_filter_novel_line_zero_novel_iff_file_in_diff():
    ranges = {"a.cc": [sad.LineRange(10, 3)]}
    in_diff = _finding("a.cc", 0)     # IWYU-style, no line number
    not_in_diff = _finding("other.cc", 0)
    sad.filter_novel([in_diff, not_in_diff], ranges)
    assert in_diff.novel is True
    assert not_in_diff.novel is False


def test_filter_novel_file_absent_from_diff_not_novel():
    # Generated/template files absent from the diff stay not-novel even with a
    # real line number (no reliable 1:1 line mapping).
    ranges = {"a.cc": [sad.LineRange(10, 3)]}
    f = _finding("generated.cc", 11)
    sad.filter_novel([f], ranges)
    assert f.novel is False


def test_filter_novel_returns_same_list():
    ranges = {"a.cc": [sad.LineRange(1, 1)]}
    findings = [_finding("a.cc", 1)]
    assert sad.filter_novel(findings, ranges) is findings


def test_filter_novel_untracked_whole_file_range_marks_interior_lines():
    # #591: an untracked file enters scope as LineRange(1, N). A finding on an
    # INTERIOR line must come out novel — a test that only checked line 1 would
    # pass against a range that was never actually whole-file.
    ranges = {"new.py": [sad.LineRange(1, 40)]}
    interior = _finding("new.py", 17)
    past_end = _finding("new.py", 41)
    sad.filter_novel([interior, past_end], ranges)
    assert interior.novel is True
    assert past_end.novel is False
