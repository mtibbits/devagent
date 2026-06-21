"""#249 — direct pytest coverage for the pure, deterministic core of
static_analysis_diff.py (the analyze-step engine, workflow step 11).

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


def _stub_git_diff(monkeypatch, stdout, returncode=0, stderr=""):
    """Install a subprocess.run that returns canned `git diff` output."""
    def fake_run(cmd, *args, **kwargs):
        return subprocess.CompletedProcess(cmd, returncode, stdout=stdout, stderr=stderr)
    monkeypatch.setattr(sad.subprocess, "run", fake_run)


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


# --------------------------------------------------------------------------
# parse_file_line
# --------------------------------------------------------------------------

def test_parse_file_line_clang_tidy_gcc_style():
    # file:line:col: form (clang-tidy / cppcheck / gcc).
    f, ln = sad.parse_file_line("/path/file.cc:42:5: warning: something")
    assert (f, ln) == ("/path/file.cc", 42)


def test_parse_file_line_col_optional():
    # file:line:: form (no column digits before the second colon).
    f, ln = sad.parse_file_line("lib/foo.cc:13: warning: msg")
    assert (f, ln) == ("lib/foo.cc", 13)


def test_parse_file_line_cpplint_style():
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
