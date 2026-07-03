"""#295 — absent tools are *skipped*, never crash the run and never spuriously
fail it.

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
    assert "1 bug" in r.error


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
