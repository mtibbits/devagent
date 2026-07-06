"""#315 — _dump must preserve the destination file's mode across the
tmp-write + atomic-replace cycle, instead of letting the temp file's
umask-derived mode leak onto the destination via the rename.

Root cause: _dump writes the temp file with Path.write_text, which creates
it at 0666 & ~umask (whatever the invoking process's umask is), then does
tmp.replace(path). The atomic rename carries tmp's mode onto path,
discarding the 0600 that state_init set (`install -m 600 /dev/null <f>`).
Under umask 0007 (the value in the bug report) the state file ends up
0660 after the very first mutation; doctor.sh's hard `mode == "600"` check
then fails, and a manual `chmod 600` is reverted by the next write.

Both tests force a permissive umask *in a subprocess child only* (via
preexec_fn, which runs after fork()/before exec()) so this test process's
own umask — process-global — is never mutated and can't leak into other
tests. umask 0077 is deliberately AVOIDED as the "permissive" value: for a
freshly-created 0666 file, 0666 & ~0077 == 0600 by coincidence, which
would make even the unfixed code pass vacuously.

Skipped on non-POSIX (chmod/mode bits are not meaningfully comparable to
0600 on Windows) and on any filesystem that doesn't round-trip exact mode
bits (e.g. some overlay/network mounts).
"""

import os
import pathlib
import subprocess
import sys
import tempfile

import pytest

_TOML = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "lib" / "_toml.py"

pytestmark = pytest.mark.skipif(os.name != "posix", reason="POSIX file-mode bits only (#315)")


def _mode(p: pathlib.Path) -> int:
    return p.stat().st_mode & 0o777


def _fs_preserves_modes(d: pathlib.Path) -> bool:
    # Guard against a mount that silently coerces modes so a "green" result
    # can't come from a filesystem that can't even represent 0o600.
    probe = d / ".mode_probe"
    probe.write_text("x")
    probe.chmod(0o614)
    ok = _mode(probe) == 0o614
    probe.unlink()
    return ok


def _run_child(umask: int, *args: str) -> subprocess.CompletedProcess:
    """Run the _toml.py CLI with `umask` set in the CHILD only.

    preexec_fn runs after fork(), before exec() — it mutates only the
    forked child's umask, never this test process's (umask is otherwise
    process-global and would bleed into every other test in the run).
    """
    return subprocess.run(
        [sys.executable, str(_TOML), *args],
        capture_output=True, timeout=30,
        preexec_fn=lambda: os.umask(umask),
    )


def test_preserve_existing_mode_across_mutation():
    # Mirrors state_init's real sequence: an empty file is created at 0600
    # (install -m 600 /dev/null) *before* the first mutation ever runs.
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        if not _fs_preserves_modes(d):
            pytest.skip("filesystem does not preserve exact mode bits")
        f = d / "state.toml"
        f.write_text('k0 = "x"\n')
        f.chmod(0o600)
        assert _mode(f) == 0o600  # sanity on the setup itself

        # umask 0007: the exact value from the #315 bug report
        # (0666 & ~0007 == 0660). NOT 0077 -- 0666 & ~0077 == 0600 by
        # coincidence, which would pass even on the unfixed code.
        r = _run_child(0o007, "set", str(f), "k1", "v1")
        assert r.returncode == 0, f"_toml.py set failed: {r.stderr!r}"

        assert _mode(f) == 0o600, (
            f"expected mode 0o600 preserved across the mutation, got {oct(_mode(f))} "
            "-- _dump's replace() is carrying the tmp file's umask-derived mode "
            "onto the destination (#315)"
        )


def test_fresh_create_lands_0600():
    # The CLI's mutation verbs (set/set-bool/set-int/unset/set-many/set-if)
    # all read-modify-write via _locked_rmw -> _load(path), which requires
    # `path` to already exist (tomllib can't open a missing file) -- in
    # practice state_init always pre-creates the empty 0600 stub before the
    # first `set` ever runs, so the CLI can't actually be driven against a
    # truly-absent destination (verified empirically: it raises
    # FileNotFoundError before ever reaching _dump). Exercise _dump
    # directly instead -- the same convention test_toml_windows_retry.py
    # already uses (test_dump_survives_transient_replace calls
    # toml._dump() on a path in an empty tmp dir) -- still under a
    # permissive CHILD umask via subprocess so this test process's umask
    # stays untouched.
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        if not _fs_preserves_modes(d):
            pytest.skip("filesystem does not preserve exact mode bits")
        f = d / "state.toml"
        assert not f.exists()

        script = (
            "import importlib.util, pathlib, sys\n"
            f"spec = importlib.util.spec_from_file_location('_toml_under_test', {str(_TOML)!r})\n"
            "toml = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(toml)\n"
            "toml._dump(pathlib.Path(sys.argv[1]), {'k': 'v'})\n"
        )
        r = subprocess.run(
            [sys.executable, "-c", script, str(f)],
            capture_output=True, timeout=30,
            preexec_fn=lambda: os.umask(0o022),  # 0666 & ~0022 == 0644 pre-fix
        )
        assert r.returncode == 0, f"_dump() raised: {r.stderr!r}"
        assert f.exists()
        assert _mode(f) == 0o600, (
            f"expected a freshly-created state file to default to 0o600, got {oct(_mode(f))}"
        )
