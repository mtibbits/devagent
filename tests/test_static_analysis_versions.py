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


# Measured 2026-10-04 (Task 3.0): real --version output of the Ubuntu 22.04 packages
# and the cpplint wheel, run from a dpkg -x / pip download extract in WSL
# (Issue-676 analysis/2026-10-04-wrapper-measurement.md). The bare-LLVM row is the
# one text still UNVERIFIED on either host.
_UPSTREAM_TEXTS = [
    ("cppcheck",
     "Cppcheck 2.7\n",
     "2.7"),
    ("cpplint",
     "Cpplint fork (https://github.com/cpplint/cpplint)\n"
     "cpplint 2.0.2\n"
     "Python 3.10.12 (main, Jul 15 2026, 23:40:17) [GCC 11.4.0]\n",
     "2.0.2"),
    ("clang-tidy-ubuntu",
     "Ubuntu LLVM version 15.0.7\n"
     "  Optimized build.\n"
     "  Default target: x86_64-pc-linux-gnu\n"
     "  Host CPU: icelake-client\n",
     "15.0.7"),
    ("clang-tidy-llvm-unverified",
     "LLVM (http://llvm.org/):\n"
     "  LLVM version 14.0.0\n",
     "14.0.0"),
    ("iwyu",
     "include-what-you-use 0.17 based on Ubuntu clang version 13.0.1-2ubuntu2.2\n",
     "0.17"),
    ("clang-format",
     "Ubuntu clang-format version 15.0.7\n",
     "15.0.7"),
    ("clang",
     "Ubuntu clang version 15.0.7\n"
     "Target: x86_64-pc-linux-gnu\n"
     "Thread model: posix\n"
     "InstalledDir: /usr/lib/llvm-15/bin\n",
     "15.0.7"),
]


@pytest.mark.parametrize("text,expect", [r[1:] for r in _UPSTREAM_TEXTS],
                         ids=[r[0] for r in _UPSTREAM_TEXTS])
def test_extract_version_upstream_texts(text, expect):
    """The regex yields each tool's own version (not its clang/python base)."""
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


# -- Task 3: PATH, wrapper and venv lookups -------------------------------------

def _probe_recorder(monkeypatch, value="7.7.7"):
    calls = []

    def fake_probe(argv):
        calls.append(list(argv))
        return value

    monkeypatch.setattr(sad, "probe_version", fake_probe)
    return calls


def test_which_version_probes_resolved_path(monkeypatch):
    monkeypatch.setattr(sad.shutil, "which", lambda name, *a, **k: "/x/cpplint")
    calls = _probe_recorder(monkeypatch)
    assert sad._which_version("cpplint") == "7.7.7"
    assert calls == [["/x/cpplint", "--version"]]


def test_which_version_unresolved_is_unknown_without_probe(monkeypatch):
    monkeypatch.setattr(sad.shutil, "which", lambda name, *a, **k: None)
    calls = _probe_recorder(monkeypatch)
    assert sad._which_version("cpplint") == UNKNOWN
    assert calls == []


def _git_config(monkeypatch, rc, stdout):
    calls = []

    def fake_run(argv, **kw):
        calls.append((list(argv), kw))
        return types.SimpleNamespace(returncode=rc, stdout=stdout, stderr="")

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    return calls


def _which_recorder(monkeypatch, answer):
    asked = []

    def fake_which(name, *a, **k):
        asked.append(name)
        return answer

    monkeypatch.setattr(sad.shutil, "which", fake_which)
    return asked


def test_clang_format_binary_from_git_config_bare(monkeypatch):
    calls = _git_config(monkeypatch, 0, "clang-format-18\n")
    asked = _which_recorder(monkeypatch, "/usr/bin/clang-format-18")
    assert sad._clang_format_binary() == "/usr/bin/clang-format-18"
    assert asked == ["clang-format-18"]
    argv, kw = calls[0]
    assert argv == ["git", "config", "--get", "clangFormat.binary"]
    assert kw["timeout"] == sad._PROBE_TIMEOUT


def test_clang_format_binary_from_git_config_with_dir(monkeypatch):
    _git_config(monkeypatch, 0, "tools/cf\n")
    asked = _which_recorder(monkeypatch, "/never")
    assert sad._clang_format_binary() == __import__("os").path.abspath("tools/cf")
    assert asked == []


def test_clang_format_binary_default(monkeypatch):
    _git_config(monkeypatch, 1, "")
    asked = _which_recorder(monkeypatch, "/usr/bin/clang-format")
    assert sad._clang_format_binary() == "/usr/bin/clang-format"
    assert asked == ["clang-format"]


def _exe(path):
    return _stub(path, "x 1.0")


@posix_exec
def test_iwyu_binary_lookup_order(tmp_path, monkeypatch):
    import os
    env_bin = _exe(tmp_path / "env" / "iwyu-env")
    earlier = _exe(tmp_path / "earlier" / "include-what-you-use")
    _exe(tmp_path / "bin1" / "iwyu_tool")
    beside = _exe(tmp_path / "bin1" / "include-what-you-use")

    # IWYU_BINARY wins
    monkeypatch.setenv("IWYU_BINARY", env_bin)
    monkeypatch.setenv("PATH", f"{tmp_path / 'earlier'}:{tmp_path / 'bin1'}")
    assert sad._iwyu_binary() == os.path.realpath(env_bin)

    # unset: the binary beside iwyu_tool beats an earlier one on PATH
    monkeypatch.delenv("IWYU_BINARY")
    assert sad._iwyu_binary() == os.path.realpath(beside)

    # neither IWYU_BINARY nor iwyu_tool: the PATH one, no exception swallowed
    monkeypatch.setenv("PATH", str(tmp_path / "earlier"))
    assert sad._iwyu_binary() == os.path.realpath(earlier)

    # symlinked iwyu_tool: the dirname of the UNRESOLVED hit is searched
    llvm = tmp_path / "llvm" / "bin"
    _exe(llvm / "iwyu_tool")
    _exe(llvm / "include-what-you-use")
    link_dir = tmp_path / "bin2"
    link_dir.mkdir()
    (link_dir / "iwyu_tool").symlink_to(llvm / "iwyu_tool")
    link_beside = _exe(link_dir / "include-what-you-use")
    monkeypatch.setenv("PATH", str(link_dir))
    assert sad._iwyu_binary() == os.path.realpath(link_beside)


@posix_exec
def test_scan_build_analyzer_lookup(tmp_path, monkeypatch):
    import os
    llvm = tmp_path / "llvm" / "bin"
    _exe(llvm / "scan-build")
    bin1 = tmp_path / "bin1"
    bin1.mkdir()
    (bin1 / "scan-build-18").symlink_to(llvm / "scan-build")
    _exe(tmp_path / "pathbin" / "clang")
    monkeypatch.setenv("PATH", f"{bin1}:{tmp_path / 'pathbin'}")
    distro = tmp_path / "usr-lib-llvm-18" / "bin" / "clang"
    monkeypatch.setattr(sad, "_SCAN_BUILD_DISTRO_CLANG", str(tmp_path / "usr-lib-llvm-{nn}" / "bin" / "clang"))

    nested = _exe(llvm / "bin" / "clang")
    flat = _exe(llvm / "clang")
    _exe(distro)
    assert sad._scan_build_analyzer() == os.path.realpath(nested)   # $RealBin/bin/clang first

    os.unlink(nested)
    assert sad._scan_build_analyzer() == os.path.realpath(flat)     # then $RealBin/clang

    os.unlink(flat)
    assert sad._scan_build_analyzer() == os.path.realpath(distro)   # then the distro default

    os.unlink(distro)
    assert sad._scan_build_analyzer() is None                       # never a PATH clang


def test_scan_build_analyzer_absent_wrapper(monkeypatch):
    monkeypatch.setattr(sad.shutil, "which", lambda name, *a, **k: None)
    assert sad._scan_build_analyzer() is None


# -- Task 4: a stamp in each of the 15 runners ----------------------------------

def _harness(monkeypatch, tmp_path):
    """Recorders for every version source plus a fake subprocess.run, all logging
    into one ordered event list, so a test can assert where each stamp is taken."""
    import os
    events = []

    def fake_probe(argv):
        events.append(("probe", list(argv)))
        return "7.7.7"

    def fake_identity(build_dir):
        events.append(("identity", build_dir))
        return "GNU 7.7.7 (C)"

    def fake_run(argv, **kw):
        events.append(("run", list(argv)))
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

    def fake_build_sanitizer(repo_root, build_dir, flags, launcher=None):
        events.append(("run", ["cmake", "-S", repo_root, "-B", build_dir]))
        return None

    monkeypatch.setattr(sad, "probe_version", fake_probe)
    monkeypatch.setattr(sad, "compiler_identity", fake_identity)
    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    monkeypatch.setattr(sad.shutil, "which", lambda name, *a, **k: f"/stub/{name}")
    monkeypatch.setattr(sad, "_iwyu_binary", lambda: "/stub/include-what-you-use")
    monkeypatch.setattr(sad, "_clang_format_binary", lambda: "/stub/clang-format")
    monkeypatch.setattr(sad, "_scan_build_analyzer", lambda: "/stub/clang")
    monkeypatch.setattr(sad, "_build_sanitizer", fake_build_sanitizer)
    monkeypatch.setattr(sad, "_run_test_kernel", lambda *a, **k: (0, "", ""))
    monkeypatch.setattr(sad, "_setarch_prefix", lambda: [])
    venv = tmp_path / "venv"
    venv.mkdir()
    real_expand = os.path.expanduser

    def fake_expand(p):
        if "venv/volk-dev/bin/" in p:
            f = venv / os.path.basename(p)
            f.write_text("")
            return str(f)
        return real_expand(p)

    monkeypatch.setattr(sad.os.path, "expanduser", fake_expand)
    bd = tmp_path / "bd"
    bd.mkdir()
    (bd / "compile_commands.json").write_text("[]")
    return events, str(bd), str(tmp_path / "repo")


# row -> (call(bd, repo), expected stamp, kind); kind "pre" = the probe precedes
# the analysis run, "post" = the identity follows the first cmake run.
RECIPES = {
    "cppcheck": (lambda bd, repo: sad.run_cppcheck(bd, ["a.cc"], repo), "7.7.7", "pre"),
    "cpplint": (lambda bd, repo: sad.run_cpplint(["a.cc"], repo), "7.7.7", "pre"),
    "clang-tidy": (lambda bd, repo: sad.run_clang_tidy(bd, ["a.cc"], repo), "7.7.7", "pre"),
    "scan-build-18": (lambda bd, repo: sad.run_scan_build(bd), "7.7.7", "pre"),
    "iwyu": (lambda bd, repo: sad.run_iwyu(bd, ["a.cc"], repo), "7.7.7", "pre"),
    "clang-format": (lambda bd, repo: sad.run_clang_format("origin/x", ["a.cc"], repo),
                     "7.7.7", "pre"),
    "cmake-lint": (lambda bd, repo: sad.run_cmake_lint(["CMakeLists.txt"], repo), "7.7.7", "pre"),
    "codespell": (lambda bd, repo: sad.run_codespell(["a.cc"], repo), "7.7.7", "pre"),
    "ruff": (lambda bd, repo: sad.run_ruff(["a.py"], repo), "7.7.7", "pre"),
    "flake8": (lambda bd, repo: sad.run_flake8(["a.py"], repo), "7.7.7", "pre"),
    "bandit": (lambda bd, repo: sad.run_bandit(["a.py"], repo), "7.7.7", "pre"),
    "mypy": (lambda bd, repo: sad.run_mypy(["a.py"], repo), "7.7.7", "pre"),
    "compiler": (lambda bd, repo: sad.run_compiler_warnings(bd, ["a.cc"], repo),
                 "GNU 7.7.7 (C)", "post"),
    "asan+ubsan": (lambda bd, repo: sad.run_asan_ubsan(repo, bd, "k"), "GNU 7.7.7 (C)", "post"),
    "tsan": (lambda bd, repo: sad.run_tsan(repo, bd, "k"), "GNU 7.7.7 (C)", "post"),
}


def test_row_recipes_cover_tool_order():
    assert set(RECIPES) == set(sad.TOOL_ORDER)
    assert len(sad.TOOL_ORDER) == 15


@pytest.mark.parametrize("row", list(RECIPES))
def test_every_row_records_a_stamp(row, tmp_path, monkeypatch):
    events, bd, repo = _harness(monkeypatch, tmp_path)
    call, expect, kind = RECIPES[row]
    r = call(bd, repo)
    assert r.tool == row
    assert sad._stamps.get(row) == expect
    kinds = [e[0] for e in events]
    assert "run" in kinds
    first_run = kinds.index("run")
    if kind == "pre":
        assert "probe" in kinds and kinds.index("probe") < first_run
    else:
        assert "identity" in kinds and kinds.index("identity") > first_run


def _pool_fake_run(monkeypatch, analysis_exc):
    def fake_run(argv, **kw):
        if list(argv[1:]) == ["--version"]:
            return types.SimpleNamespace(returncode=0, stdout="Cppcheck 9.9.9-stub\n", stderr="")
        raise analysis_exc

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    monkeypatch.setattr(sad.shutil, "which", lambda name, *a, **k: f"/stub/{name}")


def test_pool_timeout_keeps_stamp(tmp_path, monkeypatch, capsys):
    import io
    bd = tmp_path / "bd"
    bd.mkdir()
    (bd / "compile_commands.json").write_text("[]")
    _pool_fake_run(monkeypatch, subprocess.TimeoutExpired(cmd="cppcheck", timeout=300))
    r = sad._finalize_pool_result(
        "cppcheck", lambda: sad.run_cppcheck(str(bd), ["a.cc"], str(tmp_path)), {}, io.StringIO())
    assert "timed out" in r.error
    sad.print_summary([r], {})
    out = capsys.readouterr().out
    assert any(ln.startswith("| cppcheck | - | - | error: ") for ln in out.splitlines())
    assert sad.version_block_lines([r]) == ["analyzer: cppcheck 9.9.9-stub"]


def test_pool_absent_analysis_emits_no_line(tmp_path, monkeypatch):
    import io
    bd = tmp_path / "bd"
    bd.mkdir()
    (bd / "compile_commands.json").write_text("[]")
    _pool_fake_run(monkeypatch, FileNotFoundError("cppcheck"))
    r = sad._finalize_pool_result(
        "cppcheck", lambda: sad.run_cppcheck(str(bd), ["a.cc"], str(tmp_path)), {}, io.StringIO())
    assert r.skipped
    assert sad.version_block_lines([r]) == []


def _clang_format_run(monkeypatch, rc, stdout, stderr=""):
    probes = []

    def fake_run(argv, **kw):
        argv = list(argv)
        if argv[:2] == ["git", "config"]:
            return types.SimpleNamespace(returncode=1, stdout="", stderr="")
        if argv == ["/stub/clang-format", "--version"]:
            probes.append(argv)
            return types.SimpleNamespace(returncode=0, stdout="clang-format version 18.1.3\n",
                                         stderr="")
        assert argv[:2] == ["git", "clang-format"]
        return types.SimpleNamespace(returncode=rc, stdout=stdout, stderr=stderr)

    monkeypatch.setattr(sad.subprocess, "run", fake_run)
    monkeypatch.setattr(sad.shutil, "which", lambda name, *a, **k: f"/stub/{name}")
    return probes


def test_clang_format_failed_wrapper_stamps_unknown(monkeypatch, tmp_path):
    probes = _clang_format_run(monkeypatch, 1, "",
                               "git: 'clang-format' is not a git command. See 'git --help'.")
    sad.run_clang_format("origin/x", ["a.cc"], str(tmp_path))
    assert probes == [["/stub/clang-format", "--version"]]
    assert sad._stamps["clang-format"] == UNKNOWN


@pytest.mark.parametrize("rc,stdout", [
    (0, ""),
    (1, "diff --git a/x.cc b/x.cc\n--- a/x.cc\n+++ b/x.cc\n@@ -1 +1 @@\n-a\n+b\n"),
], ids=["rc0-empty", "rc1-diff"])
def test_clang_format_keeps_version(monkeypatch, tmp_path, rc, stdout):
    _clang_format_run(monkeypatch, rc, stdout)
    sad.run_clang_format("origin/x", ["a.cc"], str(tmp_path))
    assert sad._stamps["clang-format"] == "18.1.3"


def test_sanitizer_row_reads_dir_after_configure(tmp_path, monkeypatch, capsys):
    bd = tmp_path / "bd-asan"
    bd.mkdir()
    assert not (bd / "CMakeFiles").exists()

    def fake_build(repo_root, build_dir, flags, launcher=None):
        _cmake_tree(build_dir, langs={"C": (str(tmp_path / "gone" / "cc"), "", "GNU")})
        return "cmake configure failed: x"

    monkeypatch.setattr(sad, "_build_sanitizer", fake_build)
    r = sad.run_asan_ubsan(str(tmp_path), str(bd), "k")
    assert sad._stamps["asan+ubsan"] == "GNU (version unknown) (C)"
    sad.print_summary([r], {})
    # unchanged rendering: an error with no findings prints `error:` (print_summary)
    assert "| asan+ubsan | - | - | error: cmake configure failed: x |" in capsys.readouterr().out


def _raise_fnfe(*a, **k):
    raise FileNotFoundError("cmake")


@pytest.mark.parametrize("row", ["compiler", "asan+ubsan", "tsan"])
def test_compile_backed_absent_cmake_records_nothing(row, tmp_path, monkeypatch):
    monkeypatch.setattr(sad.subprocess, "run", _raise_fnfe)
    monkeypatch.setattr(sad, "_build_sanitizer", lambda *a, **k: sad._BUILD_ABSENT)
    monkeypatch.setattr(sad, "_setarch_prefix", lambda: [])
    bd = str(tmp_path / "bd")
    if row == "compiler":
        r = sad.run_compiler_warnings(bd, ["a.cc"], str(tmp_path))
    elif row == "asan+ubsan":
        r = sad.run_asan_ubsan(str(tmp_path), bd, "k")
    else:
        r = sad.run_tsan(str(tmp_path), bd, "k")
    assert r.skipped
    assert row not in sad._stamps


def test_version_block_lines_order_and_filter():
    sad._stamps.update({"cppcheck": "2.7", "iwyu": "0.17", "ruff": "0.15.21",
                        "compiler": "GNU 11.4.0 (C)"})
    results = [
        sad.ToolResult(tool="cppcheck"),
        sad.ToolResult(tool="cpplint"),                      # no stamp
        sad.ToolResult(tool="iwyu", skipped=True),           # stamped but skipped
        sad.ToolResult(tool="ruff"),
        sad.ToolResult(tool="compiler", error="build failed", passed=False),
    ]
    results.sort(key=lambda r: sad.TOOL_ORDER.index(r.tool))
    assert sad.version_block_lines(results) == [
        "analyzer: cppcheck 2.7",
        "analyzer: ruff 0.15.21",
        "analyzer: compiler GNU 11.4.0 (C)",
    ]


# -- Final review fix: a stamp must survive a cp1252 progress stream -----------

@pytest.mark.parametrize("text,expect", [
    ("Version 19.44.35222� x64", "19.44.35222"),      # errors="replace" byte
    ("tool 1.2.3é-beta", "1.2.3"),                     # non-ASCII suffix
], ids=["replacement-char", "accented-suffix"])
def test_extract_version_token_is_ascii(text, expect):
    got = sad.extract_version(text, "")
    assert got == expect
    got.encode("cp1252")   # the Windows markdown progress stream must not raise


def test_record_stamp_value_is_ascii_for_a_corrupt_compiler_id(tmp_path):
    # Review minor 1: the ID comes from the CMake file, not the version token, so
    # the whole stamp must be printable ASCII or the cp1252 progress print raises.
    (tmp_path / "CMakeCache.txt").write_text(
        "CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\n"
        "CMAKE_CACHE_MINOR_VERSION:INTERNAL=22\n"
        "CMAKE_CACHE_PATCH_VERSION:INTERNAL=1\n")
    vdir = tmp_path / "CMakeFiles" / "3.22.1"
    vdir.mkdir(parents=True)
    (vdir / "CMakeCCompiler.cmake").write_bytes(
        b'set(CMAKE_C_COMPILER "/nonexistent/cc")\n'
        b'set(CMAKE_C_COMPILER_ID "GN\xffU")\n')
    sad._record_stamp("compiler", lambda: sad.compiler_identity(str(tmp_path)))
    got = sad._stamps["compiler"]
    assert got == "GNU (version unknown) (C)"
    got.encode("cp1252")
