"""#294 — _toml.py console/file I/O must be UTF-8 + LF, not the Windows
text-mode defaults (cp1252 + CRLF).

MUST run the CLI as a SUBPROCESS: the fix reconfigures the real
sys.stdout, so an in-process `redirect_stdout(StringIO())` (which lacks
`reconfigure`) would no-op the guard and pass without the fix even on
Windows. We assert on raw pipe bytes.

Framework-agnostic: pytest collects `test_*` in CI; a `__main__` runner
runs it under bare `python3` on the pytest-less Windows box. On Linux
there is no newline translation and UTF-8 is the default, so these are
trivially green there — their teeth are on Windows (and armed for a
future windows-latest CI job).
"""

import contextlib
import pathlib
import subprocess
import sys
import tempfile

_TOML = str(pathlib.Path(__file__).resolve().parent.parent / "scripts" / "lib" / "_toml.py")


def _run(*args):
    # timeout so a hung _toml.py (e.g. an orphaned .lock holder spinning the
    # #293 msvcrt retry) fails this one test instead of hanging the suite.
    return subprocess.run([sys.executable, _TOML, *args], capture_output=True, timeout=30)


@contextlib.contextmanager
def _seeded():
    # set needs an existing file to _load; TemporaryDirectory so we don't
    # leak a dir per call (matches the sibling #293 test's style).
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d) / "state.toml"
        f.write_bytes(b'k0 = "x"\n')
        yield f


def test_multiline_get_is_lf_bytes():
    with _seeded() as f:
        assert _run("set", str(f), "k", "line1\nline2").returncode == 0
        r = _run("get", str(f), "k")
        assert r.returncode == 0
        assert r.stdout == b"line1\nline2\n", repr(r.stdout)
        assert b"\r" not in r.stdout


def test_single_line_get_has_no_trailing_cr():
    with _seeded() as f:
        assert _run("set", str(f), "k", "value").returncode == 0
        r = _run("get", str(f), "k")
        assert r.stdout == b"value\n", repr(r.stdout)   # no "value\r\n"


def test_non_ascii_round_trips_and_does_not_brick():
    # café—端 all break the pre-fix cp1252 write path: é and — encode in
    # cp1252 (0xE9 / 0x97) but are invalid UTF-8 for the next tomllib read
    # (brick); 端 is not in cp1252 at all, so the write itself raises
    # UnicodeEncodeError. UTF-8 write + read makes it round-trip.
    val = "café—端"
    with _seeded() as f:
        assert _run("set", str(f), "k", val).returncode == 0
        r = _run("get", str(f), "k")
        assert r.returncode == 0
        assert r.stdout == (val + "\n").encode("utf-8"), repr(r.stdout)
        # A non-ASCII set must not brick the file for the next reader.
        assert _run("validate", str(f)).returncode == 0


def test_dump_file_has_no_cr_bytes():
    with _seeded() as f:
        assert _run("set", str(f), "k", "line1\nline2").returncode == 0
        assert b"\r" not in f.read_bytes()


if __name__ == "__main__":
    import traceback
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"ok   {t.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {t.__name__}")
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    raise SystemExit(1 if failed else 0)
