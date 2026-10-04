"""#676 — cmake-family artifacts name the tools that produced them.

Each table row whose analysis started gets an `analyzer: <row> <version>` line;
each value is the first version-shaped token of the tool's `--version` text, or
`(version unknown)`. Probes are bounded and never raise into a runner.
"""
import importlib.util
import subprocess
import types
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "static_analysis_diff", REPO / "static_analysis_diff.py"
)
sad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sad)

UNKNOWN = "(version unknown)"


@pytest.fixture(autouse=True)
def _clear_stamps():
    sad._stamps.clear()
    yield
    sad._stamps.clear()


# -- Task 1: extraction rule, bounded probe, stamp registry --------------------

# flake8/bandit texts re-captured 2026-10-04 from ~/venv/volk-dev/bin/<t> --version
# (Git Bash; CRLF as emitted). The rest are the issue's measured table rows.
_ISSUE_TABLE = [
    ("ruff", "ruff 0.15.21", "", "0.15.21"),
    ("flake8", "7.3.0 (mccabe: 0.7.0, pycodestyle: 2.14.0, pyflakes: 3.4.0) "
               "CPython 3.13.14 on\r\nWindows\r\n", "", "7.3.0"),
    ("bandit", "bandit 1.9.4\r\n  python version = 3.13.14 (tags/v3.13.14:fd17997, "
               "Jun 10 2026, 13:03:48) [MSC v.1944 64 bit (AMD64)]\r\n", "", "1.9.4"),
    ("mypy", "mypy 2.3.0 (compiled: yes)", "", "2.3.0"),
    ("cmake-lint", "0.6.13", "", "0.6.13"),
    ("codespell", "2.4.2", "", "2.4.2"),
    ("gcc", "gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0", "", "11.4.0-1ubuntu1~22.04.3"),
    ("cl", "", "Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35222 for x64\n"
               "Copyright (C) Microsoft Corporation.  All rights reserved.\n\n"
               "cl : Command line warning D9002 : ignoring unknown option '--version'\n"
               "cl : Command line error D8003 : missing source filename\n", "19.44.35222"),
    ("cmake", "cmake version 4.2.3", "", "4.2.3"),
    ("crlf", "ruff 0.15.21\r\n", "", "0.15.21"),
    ("stub", "Cppcheck 9.9.9-stub", "", "9.9.9-stub"),
    ("usage", "usage: tool [-h] [--flag]", "", UNKNOWN),
]


@pytest.mark.parametrize("stdout,stderr,expect",
                         [row[1:] for row in _ISSUE_TABLE],
                         ids=[row[0] for row in _ISSUE_TABLE])
def test_extract_version_issue_table(stdout, stderr, expect):
    got = sad.extract_version(stdout, stderr)
    assert got == expect
    assert "\r" not in got


def test_extract_version_reads_stdout_before_stderr():
    assert sad.extract_version("ruff 0.15.21", "warning: /opt/py3.12.1/x.py") == "0.15.21"


# UNVERIFIED (U5): transcribed from upstream/distro knowledge, not measured on
# either host — no real cppcheck/cpplint/clang-tidy/iwyu/clang-format/clang exists.
_UPSTREAM_TEXTS = [
    ("cppcheck", "Cppcheck 2.13.0\n", "2.13.0"),
    ("cpplint", "\ncpplint fork (https://github.com/cpplint/cpplint)\ncpplint 1.6.1\n"
                "Python 3.10.12 (main, Nov 20 2023, 15:14:05) [GCC 11.4.0]\n", "1.6.1"),
    ("clang-tidy-ubuntu", "Ubuntu LLVM version 18.1.3\n  Optimized build.\n", "18.1.3"),
    ("clang-tidy-llvm", "LLVM (http://llvm.org/):\n  LLVM version 14.0.0\n", "14.0.0"),
    ("iwyu", "include-what-you-use 0.21 based on Ubuntu clang version 17.0.6 "
             "(9ubuntu1)\n", "0.21"),
    ("clang-format", "Ubuntu clang-format version 18.1.3 (1ubuntu1)\n", "18.1.3"),
    ("clang", "Ubuntu clang version 18.1.3 (1ubuntu1)\nTarget: x86_64-pc-linux-gnu\n"
              "Thread model: posix\nInstalledDir: /usr/lib/llvm-18/bin\n", "18.1.3"),
]


@pytest.mark.parametrize("text,expect", [r[1:] for r in _UPSTREAM_TEXTS],
                         ids=[r[0] for r in _UPSTREAM_TEXTS])
def test_extract_version_upstream_texts(text, expect):
    """UNVERIFIED upstream texts (U5): the regex yields each tool's own version."""
    assert sad.extract_version(text, "") == expect


def test_probe_version_bounds_and_detaches(monkeypatch):
    calls = []

    def fake_run(argv, **kw):
        calls.append((argv, kw))
        return types.SimpleNamespace(returncode=0, stdout="tool 1.2.3\n", stderr="")

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    argv = ["/x/tool", "--version"]
    assert sad.probe_version(argv) == "1.2.3"
    assert len(calls) == 1
    got_argv, kw = calls[0]
    assert got_argv == ["/x/tool", "--version"]
    assert kw["timeout"] == sad._PROBE_TIMEOUT == 10
    assert kw["stdin"] is subprocess.DEVNULL
    assert kw["encoding"] == "utf-8"
    assert kw["capture_output"] is True


@pytest.mark.parametrize("exc", [
    FileNotFoundError("nope"),
    OSError("exec format error"),
    subprocess.TimeoutExpired(cmd="x", timeout=10),
    ValueError("embedded null byte"),
], ids=["fnfe", "oserror", "timeout", "valueerror"])
def test_probe_version_swallows(monkeypatch, exc):
    def fake_run(*a, **kw):
        raise exc

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    assert sad.probe_version(["/x/tool", "--version"]) == UNKNOWN


def test_record_stamp_swallows_compute_errors():
    def boom():
        raise TypeError("bad")

    sad._record_stamp("cppcheck", boom)
    assert sad._stamps["cppcheck"] == UNKNOWN


# -- Task 2: compiler identity reader ------------------------------------------

posix_exec = pytest.mark.skipif(
    __import__("os").name == "nt",
    reason="stub compilers are POSIX scripts; runs in CI/WSL")


def _stub(path, text, rc=0):
    """A #!/bin/sh stub printing `text` (if any) and exiting `rc`."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "#!/bin/sh\n"
    if text:
        body += f"echo '{text}'\n"
    body += f"exit {rc}\n"
    path.write_bytes(body.encode())
    path.chmod(0o755)
    return str(path)


def _cmake_tree(root, *, version="4.2.3", cache_version=None, langs=None,
                eol="\r\n", planted="1.2.3-planted"):
    """Write CMakeCache.txt and CMakeFiles/<version>/CMake<LANG>Compiler.cmake in
    CMake 4.2.3's line order: path, ARG1, ID, then the cached _VERSION line."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    cv = cache_version or version
    if cv:
        maj, mnr, pat = cv.split(".")
        cache = (f"# This is the CMakeCache file.{eol}"
                 f"CMAKE_CACHE_MAJOR_VERSION:INTERNAL={maj}{eol}"
                 f"CMAKE_CACHE_MINOR_VERSION:INTERNAL={mnr}{eol}"
                 f"CMAKE_CACHE_PATCH_VERSION:INTERNAL={pat}{eol}")
        (root / "CMakeCache.txt").write_bytes(cache.encode())
    vdir = root / "CMakeFiles" / version
    vdir.mkdir(parents=True, exist_ok=True)
    for lang, (path, arg1, cid) in (langs or {}).items():
        text = (f'set(CMAKE_{lang}_COMPILER "{path}"){eol}'
                f'set(CMAKE_{lang}_COMPILER_ARG1 "{arg1}"){eol}'
                f'set(CMAKE_{lang}_COMPILER_ID "{cid}"){eol}'
                f'set(CMAKE_{lang}_COMPILER_VERSION "{planted}"){eol}')
        (vdir / f"CMake{lang}Compiler.cmake").write_bytes(text.encode())
    return root


@posix_exec
def test_compiler_identity_crlf_ignores_planted_cached_version(tmp_path):
    cc = _stub(tmp_path / "cc" / "stubcc", "stubcc 99.1.0")
    bd = _cmake_tree(tmp_path / "bd", langs={"C": (cc, "", "GNU"), "CXX": (cc, "", "GNU")})
    for lang in ("C", "CXX"):
        f = bd / "CMakeFiles" / "4.2.3" / f"CMake{lang}Compiler.cmake"
        assert f.read_bytes().count(b"\r") == 4   # control: the fixture really is CRLF
    got = sad.compiler_identity(str(bd))
    assert got == "GNU 99.1.0 (C), GNU 99.1.0 (CXX)"
    assert "1.2.3-planted" not in got


@posix_exec
def test_compiler_identity_lf(tmp_path):
    cc = _stub(tmp_path / "cc" / "stubcc", "stubcc 99.1.0")
    bd = _cmake_tree(tmp_path / "bd", eol="\n",
                     langs={"C": (cc, "", "GNU"), "CXX": (cc, "", "GNU")})
    assert sad.compiler_identity(str(bd)) == "GNU 99.1.0 (C), GNU 99.1.0 (CXX)"


@posix_exec
def test_compiler_identity_c_only(tmp_path):
    cc = _stub(tmp_path / "cc" / "stubcc", "stubcc 99.1.0")
    bd = _cmake_tree(tmp_path / "bd", langs={"C": (cc, "", "GNU")})
    assert sad.compiler_identity(str(bd)) == "GNU 99.1.0 (C)"


def test_compiler_identity_missing_cache(tmp_path):
    bd = _cmake_tree(tmp_path / "bd", langs={"C": ("/nonexistent/cc", "", "GNU")})
    (bd / "CMakeCache.txt").unlink()
    assert sad.compiler_identity(str(bd)) == UNKNOWN


def test_compiler_identity_cache_missing_entries(tmp_path):
    bd = _cmake_tree(tmp_path / "bd", langs={"C": ("/nonexistent/cc", "", "GNU")})
    cache = bd / "CMakeCache.txt"
    kept = [ln for ln in cache.read_bytes().split(b"\r\n") if b"PATCH" not in ln]
    cache.write_bytes(b"\r\n".join(kept))
    assert sad.compiler_identity(str(bd)) == UNKNOWN


def test_compiler_identity_cache_names_absent_dir(tmp_path):
    bd = _cmake_tree(tmp_path / "bd", cache_version="4.2.4",
                     langs={"C": ("/nonexistent/cc", "", "GNU")})
    assert sad.compiler_identity(str(bd)) == UNKNOWN


@posix_exec
def test_compiler_identity_two_version_dirs_resolved_by_cache(tmp_path):
    old = _stub(tmp_path / "cc" / "old", "old 1.0.0")
    cc = _stub(tmp_path / "cc" / "stubcc", "stubcc 99.1.0")
    bd = tmp_path / "bd"
    _cmake_tree(bd, version="3.99.0", cache_version="4.2.3", langs={"C": (old, "", "Clang")})
    _cmake_tree(bd, version="4.2.3", langs={"C": (cc, "", "GNU")})
    got = sad.compiler_identity(str(bd))
    assert got == "GNU 99.1.0 (C)"
    assert "Clang" not in got and "1.0.0" not in got


def test_compiler_identity_recorded_path_gone(tmp_path):
    bd = _cmake_tree(tmp_path / "bd", langs={"C": (str(tmp_path / "gone" / "cc"), "", "GNU")})
    assert sad.compiler_identity(str(bd)) == "GNU (version unknown) (C)"


@posix_exec
def test_compiler_identity_arg1_probes_real_compiler(tmp_path, monkeypatch):
    wrapper = tmp_path / "cc" / "ccache"
    wrapper.parent.mkdir(parents=True)
    wrapper.write_bytes(b'#!/bin/sh\nif [ "$1" = "--version" ]; then echo "wrapper version 4.9.1"; '
                        b'exit 0; fi\nexec "$@"\n')
    wrapper.chmod(0o755)
    _stub(tmp_path / "pathbin" / "realcc", "realcc 99.1.0")
    monkeypatch.setenv("PATH", f"{tmp_path / 'pathbin'}:/usr/bin:/bin")
    bd = _cmake_tree(tmp_path / "bd", langs={"C": (str(wrapper), "realcc", "GNU")})
    got = sad.compiler_identity(str(bd))
    assert "99.1.0" in got
    assert "4.9.1" not in got


@posix_exec
def test_compiler_identity_failing_probe(tmp_path):
    cc = _stub(tmp_path / "cc" / "stubcc", "", rc=1)
    bd = _cmake_tree(tmp_path / "bd", langs={"C": (cc, "", "GNU")})
    assert sad.compiler_identity(str(bd)) == "GNU (version unknown) (C)"


def test_compiler_identity_no_language_file(tmp_path):
    bd = _cmake_tree(tmp_path / "bd", langs={})
    assert (bd / "CMakeFiles" / "4.2.3").is_dir()   # control: the version dir exists
    assert sad.compiler_identity(str(bd)) == UNKNOWN
