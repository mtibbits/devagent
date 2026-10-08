"""#295/#683 — absent tools are *skipped*, never crash the run and never spuriously
fail it; a tool that ran and failed reads `error:`, never clean/pass (#683).

`static_analysis_diff.py` is a Linux gate. On a box missing a tool (Windows, a
lean CI image) an absent executable used to raise an uncaught FileNotFoundError
out of `run_scan_build` (the first sequential build tool), aborting `main()` —
which `analyze-static.sh`'s `set -euo pipefail` turned into a red workflow step.
These tests pin the fix: a FileNotFoundError from the tool's executable becomes
`ToolResult(skipped=True, passed=True)`, a *missing test binary on a built
project* stays a distinct real error (not masked as skip), the `os.uname()` TSan
launcher is guarded on non-Linux, and `print_summary` renders "skipped"
distinctly from "error:".

Framework-agnostic: no pytest fixtures, so it runs under bare `python3` on
Windows (where pytest isn't installed) AND is collected normally by pytest on
Linux CI. subprocess.run / os.makedirs are patched via a tiny save/restore
context manager — no real tools, build, or disk writes.
"""
import importlib.util
import io
import os
import re
import subprocess
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "static_analysis_diff", REPO / "static_analysis_diff.py"
)
sad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sad)


class _patch:
    """Minimal monkeypatch (save/restore one attribute). Usable as a context
    manager without pytest's fixture, so the module runs under bare python3."""

    def __init__(self, obj, name, value):
        self.obj, self.name, self.value = obj, name, value

    def __enter__(self):
        self._orig = getattr(self.obj, self.name)
        setattr(self.obj, self.name, self.value)
        return self

    def __exit__(self, *exc):
        setattr(self.obj, self.name, self._orig)
        return False


def _raise_fnfe(*_a, **_k):
    raise FileNotFoundError(2, "The system cannot find the file specified")


def _completed(stdout="", stderr="", returncode=0):
    def fake_run(cmd, *_a, **_k):
        return subprocess.CompletedProcess(cmd, returncode, stdout=stdout, stderr=stderr)
    return fake_run


# --------------------------------------------------------------------------
# Sequential build tools: absent executable → skipped, not a crash / not a FAIL
# --------------------------------------------------------------------------

def test_run_scan_build_absent_tool_skips():
    with _patch(sad.subprocess, "run", _raise_fnfe):
        r = sad.run_scan_build("/no/such/build")  # must NOT raise
    assert r.skipped is True
    assert r.passed is True              # absence is not failure
    assert "scan-build-18" in r.error


def test_run_compiler_warnings_absent_cmake_skips():
    with _patch(sad.subprocess, "run", _raise_fnfe):
        # changed_files=[] so no os.utime touches; the cmake build raises FNFE.
        r = sad.run_compiler_warnings("/no/such/build", [], "/repo")
    assert r.skipped is True
    assert r.passed is True
    assert "cmake" in r.error


def test_build_sanitizer_absent_cmake_returns_skip_marker():
    # _build_sanitizer signals "build tool absent" via a marker suffix on its
    # returned error string (its only channel). os.makedirs is stubbed so the
    # test writes nothing to disk.
    with _patch(sad.subprocess, "run", _raise_fnfe), \
         _patch(sad.os, "makedirs", lambda *_a, **_k: None):
        err = sad._build_sanitizer("/repo", "/no/such/build", "-fsanitize=address")
    assert err is not None
    assert err.endswith(sad._SKIP_MARK)


def test_run_asan_ubsan_absent_cmake_skips_marker_stripped():
    with _patch(sad.subprocess, "run", _raise_fnfe), \
         _patch(sad.os, "makedirs", lambda *_a, **_k: None):
        r = sad.run_asan_ubsan("/repo", "/no/such/build-asan", "some_kernel")
    assert r.skipped is True
    assert r.passed is True
    assert r.error == "cmake not found"          # marker stripped for display
    assert not r.error.endswith(sad._SKIP_MARK)


def test_run_tsan_absent_cmake_skips():
    # setarch is Linux-only; force it absent so _setarch_prefix() returns []
    # (and never touches os.uname, which doesn't exist on Windows).
    with _patch(sad.shutil, "which", lambda _n: None), \
         _patch(sad.subprocess, "run", _raise_fnfe), \
         _patch(sad.os, "makedirs", lambda *_a, **_k: None):
        r = sad.run_tsan("/repo", "/no/such/build-tsan", "some_kernel")
    assert r.skipped is True
    assert r.passed is True
    assert r.error == "cmake not found"


# --------------------------------------------------------------------------
# A missing test binary on a *built* project is a real error, NOT a skip
# --------------------------------------------------------------------------

def test_run_test_kernel_absent_binary_is_distinct_error_not_skip():
    with _patch(sad.subprocess, "run", _raise_fnfe):
        rc, out, err = sad._run_test_kernel("/built/dir", "some_kernel")
    assert rc == 127                     # "command not found", not a skip
    assert "volk_profile not found" in err


# --------------------------------------------------------------------------
# _setarch_prefix guards os.uname() behind the setarch presence check
# --------------------------------------------------------------------------

def test_setarch_prefix_empty_when_setarch_absent():
    with _patch(sad.shutil, "which", lambda _n: None):
        assert sad._setarch_prefix() == []   # never evaluates os.uname()


def test_setarch_prefix_present_when_setarch_available():
    # Only meaningful where os.uname exists (POSIX / Linux CI). On Windows it is
    # a genuine SkipTest (not a silent vacuous PASS): pytest reports it skipped,
    # and the bare runner prints SKIP — the guard's whole point is that this
    # branch is never reached where os.uname is absent.
    if not hasattr(os, "uname"):
        raise unittest.SkipTest("os.uname absent (non-POSIX); guarded branch unreachable here")
    with _patch(sad.shutil, "which", lambda _n: "/usr/bin/setarch"):
        pref = sad._setarch_prefix()
    assert pref[0] == "setarch" and pref[-1] == "--addr-no-randomize"


# --------------------------------------------------------------------------
# Present tool still detects / gates — absence handling didn't neuter it
# --------------------------------------------------------------------------

def test_present_scan_build_clean_passes():
    with _patch(sad.subprocess, "run", _completed(stdout="No bugs found")):
        r = sad.run_scan_build("/build")
    assert r.passed is True and r.skipped is False and r.error is None


def test_present_scan_build_with_bug_fails_not_skips():
    with _patch(sad.subprocess, "run", _completed(stdout="1 bug found")):
        r = sad.run_scan_build("/build")
    assert r.passed is False             # a real finding still fails
    assert r.skipped is False            # and is NOT mistaken for absence
    assert "1 bug" in r.verdict and r.error is None   # #683: a completed analysis's FAIL


def test_present_compiler_warning_still_reported():
    warn = "lib/foo.cc:42:5: warning: unused variable 'x' [-Wunused-variable]\n"
    with _patch(sad.subprocess, "run", _completed(stdout=warn)):
        r = sad.run_compiler_warnings("/build", [], "/repo")
    assert r.skipped is False
    assert any(f.line == 42 and "unused variable" in f.message for f in r.findings)


# --------------------------------------------------------------------------
# The parallel pool: absent executable → skipped, real error → FAILED
# --------------------------------------------------------------------------

def test_finalize_pool_absent_tool_skips():
    def produce():
        raise FileNotFoundError(2, "The system cannot find the file specified")
    r = sad._finalize_pool_result("codespell", produce, {}, io.StringIO())
    assert r.skipped is True and r.passed is True   # absence is not failure
    assert r.error == "codespell not found"


def test_finalize_pool_real_error_fails_not_skips():
    def produce():
        raise ValueError("boom")                    # a genuine tool error
    r = sad._finalize_pool_result("cppcheck", produce, {}, io.StringIO())
    assert r.skipped is False and r.passed is False
    assert "boom" in r.error


def test_finalize_pool_success_filters_findings():
    # A present tool returning a finding passes through and gets diff-filtered.
    def produce():
        res = sad.ToolResult(tool="ruff")
        res.findings = [sad.Finding(tool="ruff", severity="E", file="a.py",
                                    line=11, message="x")]
        return res
    ranges = {"a.py": [sad.LineRange(10, 3)]}        # 10..12 → line 11 is novel
    r = sad._finalize_pool_result("ruff", produce, ranges, io.StringIO())
    assert r.skipped is False and r.passed is True
    assert r.findings[0].novel is True


# --------------------------------------------------------------------------
# print_summary renders a skipped tool distinctly from a real error row
# --------------------------------------------------------------------------

def test_print_summary_renders_skipped_distinctly():
    results = [
        sad.ToolResult(tool="scan-build-18", error="scan-build-18 not found",
                       passed=True, skipped=True),
        sad.ToolResult(tool="cppcheck", error="compile_commands.json not found",
                       passed=False),
    ]
    buf = io.StringIO()
    with redirect_stdout(buf):
        sad.print_summary(results, {})
    out = buf.getvalue()
    lines = [ln for ln in out.splitlines() if ln.startswith("| ")]
    scan = next(ln for ln in lines if ln.startswith("| scan-build-18 "))
    cpp = next(ln for ln in lines if ln.startswith("| cppcheck "))
    assert "skipped" in scan and "error:" not in scan    # skipped, not error
    assert "error:" in cpp                                # a real error stays error


# --------------------------------------------------------------------------
# #683 — a failed tool reads error:, never clean/pass
# --------------------------------------------------------------------------

def _tool_run(rc, stdout="", stderr=""):
    """A fake subprocess.run that dispatches on argv, so a `--version` probe or a
    `git config` lookup never receives the case's output."""
    def fake_run(cmd, *_a, **_k):
        argv = list(cmd)
        if argv[-1:] == ["--version"]:
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
        if argv[:2] == ["git", "config"]:
            return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")
        return _completed(stdout, stderr, rc)(argv)
    return fake_run


def _row(results, tool, ranges=None):
    """The rendered `| <tool> |` summary line, whole."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        sad.print_summary(results, ranges or {})
    return next(ln for ln in buf.getvalue().splitlines() if ln.startswith(f"| {tool} |"))


def _finding(tool, file="a.c", line=1, novel=False):
    return sad.Finding(tool=tool, severity="style", file=file, line=line,
                       message="m", novel=novel)


def test_683_sanitizer_rows_render_as_today():
    def kernel(rc, err):
        return lambda *_a, **_k: (rc, "", err)
    with _patch(sad, "_build_sanitizer", lambda *_a, **_k: None), \
         _patch(sad, "_setarch_prefix", lambda: []):
        with _patch(sad, "_run_test_kernel",
                    kernel(1, "==1==ERROR: AddressSanitizer: heap-use-after-free")):
            asan = sad.run_asan_ubsan("/repo", "/b-asan", "k")
        with _patch(sad, "_run_test_kernel", kernel(1, "")):
            tsan_fail = sad.run_tsan("/repo", "/b-tsan", "k")
        with _patch(sad, "_run_test_kernel", kernel(0, "")):
            tsan_ok = sad.run_tsan("/repo", "/b-tsan", "k")
    assert _row([asan], "asan+ubsan") == "| asan+ubsan | - | - | **FAIL: 1 issue(s)** |"
    assert _row([tsan_fail], "tsan") == \
        "| tsan | - | - | error: exited with code 1 (no sanitizer output captured) |"
    assert _row([tsan_ok], "tsan") == "| tsan | - | - | pass |"


def _compiler_timeout():
    def raise_timeout(cmd, *_a, **_k):
        if list(cmd)[-1:] == ["--version"]:
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=300)
    with _patch(sad.subprocess, "run", raise_timeout):
        return sad.run_compiler_warnings("/build", [], "/repo")


def test_683_timeout_row_prefix():
    r = _compiler_timeout()
    assert _row([r], "compiler") == "| compiler | - | - | error: timed out after 300s |"


def test_683_timeout_row_json_failed():
    row = sad.json_rows([_compiler_timeout()])[0]
    assert row["failed"] is True and row["passed"] is False


def test_683_json_failed_matches_markdown_prefix():
    T = sad.ToolResult
    cases = [   # (row, expected failed, expected passed)
        (T(tool="scan-build-18", error="scan-build-18 not found", skipped=True), False, True),
        (T(tool="cppcheck", error="compile_commands.json not found", passed=False), True, False),
        (T(tool="scan-build-18", verdict="1 bug(s) found (see /tmp/scan-build-out/)",
           passed=False), False, False),
        (T(tool="asan+ubsan", findings=[_finding("asan+ubsan")], passed=False), False, False),
        (T(tool="cpplint"), False, True),
        (T(tool="ruff", findings=[_finding("ruff", novel=True)]), False, True),
        (T(tool="compiler", findings=[_finding("compiler"), _finding("compiler")],
           error="compiler exit=1: build failed", exit_status=1, passed=False), True, False),
    ]
    for r, failed, passed in cases:
        row = sad.json_rows([r])[0]
        assert row["failed"] is failed, (r.tool, row)
        assert row["passed"] is passed, (r.tool, row)
        assert row["failed"] == sad.row_cells(r)[2].startswith("error:"), r.tool
    assert sum(1 for r, _, _ in cases if sad.json_rows([r])[0]["failed"]) == 2


def test_683_json_row_key_set():
    r = sad.ToolResult(tool="compiler", findings=[_finding("compiler")])
    sad._exit_failure(r, 1, "build failed")
    row = sad.json_rows([r])[0]
    assert list(row) == ["tool", "passed", "skipped", "failed", "error", "findings"]
    assert row["error"] == "compiler exit=1: build failed"   # no `; N finding(s)` tail


def test_683_cell_reason_controls_become_spaces():
    assert sad._cell_reason("a\rb\tc\x7fd\ne") == "a b c d e"
    assert sad._cell_reason("x|y") == "x\\|y"
    assert len("\\|") == 2                     # one backslash + one pipe at runtime
    assert sad._cell_reason("é" * 300) == "é" * 200   # non-ASCII kept, raw length capped


def test_683_pool_progress_line_names_skip():
    def produce():
        return sad.ToolResult(tool="cppcheck", error="no compilable files in diff",
                              skipped=True)
    progress = io.StringIO()
    sad._finalize_pool_result("cppcheck", produce, {}, progress)
    assert progress.getvalue() == "  cppcheck: skipped (no compilable files in diff)\n"


_CF_RANGES = {"a.c": [sad.LineRange(1, 5)]}


def _cf(rc, stdout="", stderr=""):
    """run_clang_format against a faked git-clang-format, findings diff-filtered."""
    with _patch(sad.subprocess, "run", _tool_run(rc, stdout, stderr)):
        r = sad.run_clang_format("HEAD", ["a.c"], "/repo")
    r.findings = sad.filter_novel(r.findings, _CF_RANGES)
    return r


def _cf_row(r):
    return _row([r], "clang-format", _CF_RANGES)


def test_683_clang_format_absent_wrapper_skips():
    r = _cf(1, stderr="git: 'clang-format' is not a git command. See 'git --help'.\n")
    assert _cf_row(r) == "| clang-format | - | - | skipped (git-clang-format not found) |"


def test_683_clang_format_missing_binary_skips():
    r = _cf(2, stderr='error: cannot find executable "/nonexistent/clang-format"\n')
    assert _cf_row(r) == "| clang-format | - | - | skipped (clang-format binary not found) |"


def test_683_clang_format_bad_ref_is_error():
    r = _cf(2, stderr="error: 'nosuchref' is not a commit\n")
    assert _cf_row(r) == \
        "| clang-format | 0 | 0 | error: clang-format exit=2: error: 'nosuchref' is not a commit |"


def test_683_clang_format_rc1_unrecognized_stderr_is_error():
    # A localized git message is not the measured English one: it fails closed.
    r = _cf(1, stderr="git: 'clang-format' ist kein Git-Befehl.\n")
    assert _cf_row(r) == \
        "| clang-format | 0 | 0 | error: clang-format exit=1: git: 'clang-format' ist kein Git-Befehl. |"


def test_683_clang_format_diff_is_findings():
    diff = ("diff --git a/a.c b/a.c\n--- a/a.c\n+++ b/a.c\n"
            "@@ -2 +2 @@\n-int   f( void ){return 1;}\n+int f(void) { return 1; }\n")
    r = _cf(1, stdout=diff)
    assert _cf_row(r) == "| clang-format | 1 | 1 | **1 novel** |"
    assert sad.json_rows([r])[0]["failed"] is False


def test_683_clang_format_rc1_without_hunks_is_error():
    # rc 1 means "a diff was printed"; stdout with no hunk is unexplained.
    for out in ("some unexpected text on stdout\n", "clang-format did not modify any files\n"):
        r = _cf(1, stdout=out, stderr="error: something went wrong\n")
        assert _cf_row(r) == \
            "| clang-format | 0 | 0 | error: clang-format exit=1: error: something went wrong |", out


def test_683_clang_format_clean():
    r = _cf(0, stdout="no modified files to format\n")
    assert _cf_row(r) == "| clang-format | 0 | 0 | clean |"


def test_683_reason_pipe_escaped():
    row = _cf_row(_cf(2, stderr="error: 'a|b' is not a commit\n"))
    assert "'a\\|b'" in row
    assert len(re.split(r"(?<!\\)\|", row)) == 6


def test_683_reason_truncated_to_200():
    row = _cf_row(_cf(2, stderr="x" * 300 + "\n"))
    head = "| clang-format | 0 | 0 | error: clang-format exit=2: "
    assert row.startswith(head) and row.endswith(" |")
    assert row[len(head):-2] == "x" * 200


def _marker(r):
    row = sad.json_rows([r])[0]
    return sad.row_cells(r)[2].split(":")[0].split(" ")[0], row["failed"], row["passed"]


def test_683_marker_new_route_bad_ref():
    assert _marker(_cf(2, stderr="error: 'nosuchref' is not a commit\n")) == \
        ("error", True, False)


def test_683_marker_existing_route_timeout():
    assert _marker(_compiler_timeout()) == ("error", True, False)


def test_683_marker_success_clean():
    assert _marker(_cf(0, stdout="no modified files to format\n")) == ("clean", False, True)


_IW_REPO = os.path.abspath("/r683")
_IW_DB_ERR = ("error: failed to parse compilation database: [Errno 2] "
              "No such file or directory: '/x/compile_commands.json'")


def _iw_a_block():
    a = os.path.join(_IW_REPO, "a.c")   # absolute, as CMake writes it
    return (f"{a} should add these lines:\n\n"
            f"{a} should remove these lines:\n"
            "- #include <stdio.h>  // lines 1-1\n"
            "- #include <string.h>  // lines 2-2\n\n"
            f"The full include-list for {a}:\n---\n\n")


def _iw(rc, stdout, files, stderr=""):
    with _patch(sad.subprocess, "run", _tool_run(rc, stdout, stderr)):
        return sad.run_iwyu("/build", files, _IW_REPO)


def test_683_iwyu_unreadable_database_is_error():
    r = _iw(1, "", ["a.c"], stderr=_IW_DB_ERR + "\n")
    assert _row([r], "iwyu") == \
        f"| iwyu | 0 | 0 | error: iwyu exit=1: not analyzed: a.c; {_IW_DB_ERR} |"


def test_683_iwyu_one_tu_fails_names_it_and_keeps_counts():
    out = _iw_a_block() + "b.c:1:25: error: use of undeclared identifier 'undeclared_x'\n"
    r = _iw(1, out, ["a.c", "b.c"])
    assert _row([r], "iwyu") == (
        "| iwyu | 2 | 0 | error: iwyu exit=1: not analyzed: b.c; "
        "b.c:1:25: error: use of undeclared identifier 'undeclared_x'; 2 finding(s) |")


def _iw_all_verdicted():
    b = os.path.join(_IW_REPO, "b.c")
    return _iw_a_block() + f"({b} has correct #includes/fwd-decls)\n"


def test_683_iwyu_rc0_with_verdicts_parses_as_today():
    r = _iw(0, _iw_all_verdicted(), ["a.c", "b.c"])
    assert _row([r], "iwyu") == "| iwyu | 2 | 0 | clean |"


def test_683_iwyu_nonzero_all_verdicted_parses_as_today():
    r = _iw(1, _iw_all_verdicted(), ["a.c", "b.c"])
    assert _row([r], "iwyu") == "| iwyu | 2 | 0 | clean |"


def test_683_iwyu_many_files_keeps_diagnostic():
    files = [f"src/file_number_{i:02d}.c" for i in range(15)]
    r = _iw(1, "", files, stderr=_IW_DB_ERR + "\n")
    status = sad.row_cells(r)[2]
    assert "and 12 more" in status
    assert "failed to parse compilation database" in status


def test_683_iwyu_long_names_never_cut_the_diagnostic():
    # Three 70-char names would fill the 200-char cap before the diagnostic: the
    # names yield, the tool's own diagnostic survives whole.
    files = [f"src/{c * 62}.c" for c in "abc"]
    diag = "error: failed to parse compilation database: [Errno 2] No such file or directory"
    r = _iw(1, "", files, stderr=diag + "\n")
    assert r.error.endswith("; " + diag)
    assert len(r.error) - len("iwyu exit=1: ") <= sad._REASON_MAX
    assert "more" in r.error            # the dropped names are still counted


def test_683_iwyu_long_diagnostic_fills_the_cap():
    # The diagnostic's budget is what the shortest prefix leaves, not a fixed
    # margin: a long database path keeps its tail up to the cap.
    diag = "error: failed to parse compilation database: '/" + "p" * 200 + "/cc.json'"
    r = _iw(1, "", ["a.c"], stderr=diag + "\n")
    reason = r.error[len("iwyu exit=1: "):]
    assert reason.startswith("not analyzed: a.c; error: failed to parse")
    assert len(reason) == len("not analyzed: a.c; ") + sad._REASON_MAX - len(
        "not analyzed: 1 file(s); ")


def _sb(rc, stdout="", stderr=""):
    with _patch(sad.subprocess, "run", _tool_run(rc, stdout, stderr)):
        return sad.run_scan_build("/build")


def test_683_scan_build_failed_build_is_error():
    r = _sb(2, stdout="scan-build: No bugs found.\n",
            stderr="a.c:1:31: error: use of undeclared identifier 'syntax'\n"
                   "gmake[2]: *** [CMakeFiles/a.dir/build.make:76: a.o] Error 1")
    assert _row([r], "scan-build-18") == (
        "| scan-build-18 | - | - | error: scan-build-18 exit=2: build failed: "
        "a.c:1:31: error: use of undeclared identifier 'syntax' |")


def test_683_scan_build_reason_prefers_the_error_colon_line():
    r = _sb(2, stderr="cc1: warnings being treated as errors with -Werror\n"
                      "a.c:1:31: error: use of undeclared identifier 'syntax'\n")
    assert sad.row_cells(r)[2] == (
        "error: scan-build-18 exit=2: build failed: "
        "a.c:1:31: error: use of undeclared identifier 'syntax'")


def test_683_scan_build_failed_build_keeps_bug_count():
    r = _sb(2, stdout="scan-build: 1 bug found.\n",
            stderr="b.c:1:31: error: use of undeclared identifier 'syntax'\n")
    status = sad.row_cells(r)[2]
    assert status.startswith("error: scan-build-18 exit=2: build failed: b.c:")
    assert status.endswith("; 1 bug(s) found")
    assert r.passed is False


def test_683_scan_build_bug_count_is_FAIL():
    r = _sb(0, stdout="scan-build: 1 bug found.\n")
    assert _row([r], "scan-build-18") == \
        "| scan-build-18 | - | - | FAIL: 1 bug(s) found (see /tmp/scan-build-out/) |"
    row = sad.json_rows([r])[0]
    assert row["failed"] is False and row["passed"] is False


def test_683_scan_build_clean_passes():
    r = _sb(0, stdout="scan-build: No bugs found.\n")
    assert _row([r], "scan-build-18") == "| scan-build-18 | - | - | pass |"


_CC_STUB = ("lib/old.c:10:5: error: 'y' undeclared (first use in this function)\n"
            "lib/new.c:3:9: warning: unused variable 'x' [-Wunused-variable]\n")
_CC_RANGES = {"lib/new.c": [sad.LineRange(1, 1)]}


def _cc(rc, stdout):
    with _patch(sad.subprocess, "run", _tool_run(rc, stdout)):
        r = sad.run_compiler_warnings("/build", [], "/repo")
    r.findings = sad.filter_novel(r.findings, _CC_RANGES)
    return r


def test_683_compiler_failed_build_with_findings_is_error():
    r = _cc(1, _CC_STUB)
    assert _row([r], "compiler", _CC_RANGES) == \
        "| compiler | 2 | 0 | error: compiler exit=1: build failed; 2 finding(s) |"
    assert r.passed is False


def test_683_compiler_rc0_same_stub_renders_as_today():
    r = _cc(0, _CC_STUB)
    assert _row([r], "compiler", _CC_RANGES) == "| compiler | 2 | 0 | clean |"


def test_683_compiler_failed_build_no_findings():
    r = _cc(2, "")
    assert _row([r], "compiler", _CC_RANGES) == \
        "| compiler | 0 | 0 | error: compiler exit=2: build failed |"


def test_683_cppcheck_no_compilable_files_is_skipped():
    with _patch(sad.os.path, "isfile", lambda p: True):
        r = sad.run_cppcheck("/b", [], "/r")
    assert _row([r], "cppcheck") == "| cppcheck | - | - | skipped (no compilable files in diff) |"
    assert sad.json_rows([r])[0]["failed"] is False


def test_683_docs_name_the_marker():
    doc = " ".join(sad.__doc__.split())
    assert "Failure semantics (#683)" in doc and "`failed`" in doc
    analyze_md = " ".join((REPO / "commands" / "analyze.md").read_text(encoding="utf-8").split())
    assert "#683" in analyze_md


def test_683_docs_scope_the_unread_rows_to_nine():
    # The sanitizer rows do read the test kernel's rc: the "do not read" claim
    # is written to the width of the diff (the nine static rows), not "other rows".
    doc = " ".join(sad.__doc__.split())
    assert "The other nine static rows" in doc


# --------------------------------------------------------------------------
# Bare-python3 runner (Windows, where pytest isn't installed)
# --------------------------------------------------------------------------

if __name__ == "__main__":
    import sys
    tests = sorted(
        (n, o) for n, o in globals().items() if n.startswith("test_") and callable(o)
    )
    failures = skipped = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except unittest.SkipTest as e:
            skipped += 1
            print(f"SKIP {name}: {e}")
        except Exception as e:  # noqa: BLE001 — test runner surfaces any failure
            failures += 1
            print(f"FAIL {name}: {type(e).__name__}: {e}")
    passed = len(tests) - failures - skipped
    print(f"\n{passed} passed, {skipped} skipped, {failures} failed")
    sys.exit(1 if failures else 0)
