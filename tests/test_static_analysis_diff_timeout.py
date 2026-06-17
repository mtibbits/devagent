"""#118 — static_analysis_diff phases 2/3 must catch subprocess.TimeoutExpired.

A cold sanitizer build can exceed its timeout; before this fix the bare
subprocess.run raised TimeoutExpired, killed the script after phase 1, and left an
incomplete artifact. Each function must instead record a 'timed out' outcome and
return normally (mirroring run_scan_build).
"""
import importlib.util
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "static_analysis_diff", REPO / "static_analysis_diff.py"
)
sad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sad)


def _raise_timeout(*args, **kwargs):
    raise subprocess.TimeoutExpired(cmd=(args[0] if args else "cmd"),
                                    timeout=kwargs.get("timeout", 0))


def test_run_compiler_warnings_times_out_gracefully(monkeypatch):
    monkeypatch.setattr(sad.subprocess, "run", _raise_timeout)
    result = sad.run_compiler_warnings("/nonexistent/build", [], "/nonexistent/repo")
    assert result.passed is False
    assert result.error and "timed out" in result.error


def test_build_sanitizer_rebuild_times_out_gracefully(tmp_path, monkeypatch):
    # build.ninja present → the rebuild path (the 600s call) is exercised.
    (tmp_path / "build.ninja").write_text("")
    monkeypatch.setattr(sad.subprocess, "run", _raise_timeout)
    err = sad._build_sanitizer("/nonexistent/repo", str(tmp_path), "-fsanitize=address")
    assert err is not None and "timed out" in err


def test_build_sanitizer_configure_times_out_gracefully(tmp_path, monkeypatch):
    # no build.ninja → the configure path (the 120s call) is exercised.
    monkeypatch.setattr(sad.subprocess, "run", _raise_timeout)
    err = sad._build_sanitizer("/nonexistent/repo", str(tmp_path / "b"), "-fsanitize=address")
    assert err is not None and "timed out" in err


def test_run_test_kernel_times_out_gracefully(monkeypatch):
    monkeypatch.setattr(sad.subprocess, "run", _raise_timeout)
    rc, out, err = sad._run_test_kernel("/nonexistent/build", "some_kernel")
    assert rc != 0
    assert "timed out" in err


def test_run_asan_ubsan_surfaces_kernel_timeout(monkeypatch):
    # build succeeds, the test-kernel run times out → the result must report the
    # timeout, not "exited with code 124".
    monkeypatch.setattr(sad, "_build_sanitizer", lambda *a, **k: None)
    monkeypatch.setattr(sad, "_run_test_kernel", lambda *a, **k: (124, "", "timed out after 120s"))
    result = sad.run_asan_ubsan("/repo", "/build", "some_kernel")
    assert result.passed is False
    assert result.error == "timed out after 120s"


def test_run_tsan_surfaces_kernel_timeout(monkeypatch):
    monkeypatch.setattr(sad, "_build_sanitizer", lambda *a, **k: None)
    monkeypatch.setattr(sad, "_run_test_kernel", lambda *a, **k: (124, "", "timed out after 120s"))
    result = sad.run_tsan("/repo", "/build", "some_kernel")
    assert result.passed is False
    assert result.error == "timed out after 120s"
