"""#1125: scripts/lib/merge-forward-hunks.py, the append-only hunk checker.

Every leg builds a throwaway git repo and feeds the checker REAL
`git -c merge.conflictStyle=diff3 merge-tree --write-tree` output; no conflict
file is written by hand. The HEAD side (the operator's resolution) is fixture
text. Each refusal leg asserts the exit code AND the exact reason.
"""

import importlib.util
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "scripts" / "lib" / "merge-forward-hunks.py"

BASE = "# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n- old\n"
OURS = "# Changelog\n\n## [Unreleased]\n- ours a\n- ours b\n\n## [1.0.0]\n- old\n"
THEIRS = "# Changelog\n\n## [Unreleased]\n- theirs\n\n## [1.0.0]\n- old\n"


def _env():
    env = dict(os.environ)
    env.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="t",
        GIT_AUTHOR_EMAIL="t@example.com",
        GIT_COMMITTER_NAME="t",
        GIT_COMMITTER_EMAIL="t@example.com",
        LC_ALL="C",
    )
    return env


def _git(repo, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(repo), *args], env=_env(), check=check, capture_output=True
    )


def _commit(repo, files, msg):
    for name, data in files.items():
        p = repo / name
        p.write_bytes(data if isinstance(data, bytes) else data.encode())
        _git(repo, "add", name)
    _git(repo, "commit", "-q", "-m", msg)
    return _git(repo, "rev-parse", "HEAD").stdout.decode().strip()


def merge(tmp_path, base, ours, theirs, path="CHANGELOG.md", base_extra=None):
    """Return (merged bytes, vh40, T40, merge-tree rc) from a real merge-tree."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    files = {path: base}
    files.update(base_extra or {})
    _commit(repo, files, "base")
    _git(repo, "checkout", "-q", "-b", "ours")
    vh = _commit(repo, {path: ours}, "ours")
    _git(repo, "checkout", "-q", "main")
    t = _commit(repo, {path: theirs}, "theirs")
    r = subprocess.run(
        ["git", "-C", str(repo), "-c", "merge.conflictStyle=diff3",
         "merge-tree", "--write-tree", "-z", vh, t],
        env=_env(), capture_output=True,
    )
    assert r.returncode in (0, 1), r.stderr
    tree = r.stdout.split(b"\0", 1)[0].decode()
    blob = _git(repo, "cat-file", "-p", f"{tree}:{path}").stdout
    return blob, vh, t, r.returncode


def check(tmp_path, merged, head, vh, t):
    m = tmp_path / "merged"
    h = tmp_path / "head"
    m.write_bytes(merged)
    h.write_bytes(head if isinstance(head, bytes) else head.encode())
    r = subprocess.run(
        ["python3", "-I", str(HELPER), str(m), str(h), vh, t],
        capture_output=True,
    )
    return r.returncode, r.stdout.decode("utf-8", "replace").strip()


def head_of(*unreleased, tail="\n## [1.0.0]\n- old\n"):
    return "# Changelog\n\n## [Unreleased]\n" + "".join(l + "\n" for l in unreleased) + tail


def test_keep_both_ours_first_accepts(tmp_path):
    merged, vh, t, rc = merge(tmp_path, BASE, OURS, THEIRS)
    assert rc == 1
    assert check(tmp_path, merged, head_of("- ours a", "- ours b", "- theirs"), vh, t) == (0, "")


def test_keep_both_theirs_first_accepts(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    assert check(tmp_path, merged, head_of("- theirs", "- ours a", "- ours b"), vh, t) == (0, "")


def test_blank_lines_only_differ_accepts(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    head = head_of("", "- ours a", "- ours b", "", "- theirs", "", tail="\n## [1.0.0]\n- old\n")
    assert check(tmp_path, merged, head, vh, t) == (0, "")


def test_two_hunks_accepts(tmp_path):
    base = "# Changelog\n\n## [Unreleased]\n- a0\n- m1\n- m2\n- m3\n- z0\n\n## [1.0.0]\n- old\n"
    ours = "# Changelog\n\n## [Unreleased]\n- a0\n- o1\n- m1\n- m2\n- m3\n- z0\n- o2\n\n## [1.0.0]\n- old\n"
    theirs = "# Changelog\n\n## [Unreleased]\n- a0\n- t1\n- m1\n- m2\n- m3\n- z0\n- t2\n\n## [1.0.0]\n- old\n"
    merged, vh, t, rc = merge(tmp_path, base, ours, theirs)
    assert rc == 1
    assert merged.count(b"\n<<<<<<< ") == 2
    head = "# Changelog\n\n## [Unreleased]\n- a0\n- o1\n- t1\n- m1\n- m2\n- m3\n- z0\n- t2\n- o2\n\n## [1.0.0]\n- old\n"
    assert check(tmp_path, merged, head, vh, t) == (0, "")


def test_dropped_line_refuses(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    assert check(tmp_path, merged, head_of("- ours a", "- theirs"), vh, t) == (
        3, "hunk 1 is not both sides' lines as two contiguous runs")


def test_added_line_refuses(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    assert check(tmp_path, merged, head_of("- ours a", "- extra", "- ours b", "- theirs"), vh, t) == (
        3, "hunk 1 is not both sides' lines as two contiguous runs")


def test_interleaved_entries_refuse(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    assert check(tmp_path, merged, head_of("- ours a", "- theirs", "- ours b"), vh, t) == (
        3, "hunk 1 is not both sides' lines as two contiguous runs")


def test_branch_entry_under_release_heading_refuses(tmp_path):
    # The base cut a release: its side of the hunk carries a new `## [1.1.0]` heading.
    ours = "# Changelog\n\n## [Unreleased]\n- ours a\n\n## [1.0.0]\n- old\n"
    theirs = "# Changelog\n\n## [Unreleased]\n## [1.1.0]\n- theirs\n\n## [1.0.0]\n- old\n"
    merged, vh, t, rc = merge(tmp_path, BASE, ours, theirs)
    assert rc == 1
    head = head_of("## [1.1.0]", "- theirs", "- ours a")
    assert check(tmp_path, merged, head, vh, t) == (
        3, "hunk 1: the branch's lines are not under ## [Unreleased]")
    # Control: the branch's line first stays under [Unreleased] and passes.
    assert check(tmp_path, merged, head_of("- ours a", "## [1.1.0]", "- theirs"), vh, t) == (0, "")


def test_nonempty_base_refuses(tmp_path):
    base = "# Changelog\n\n## [Unreleased]\n- prev\n\n## [1.0.0]\n- old\n"
    ours = "# Changelog\n\n## [Unreleased]\n- prev\n- ours a\n\n## [1.0.0]\n- old\n"
    theirs = "# Changelog\n\n## [Unreleased]\n- prev, fixed\n- theirs\n\n## [1.0.0]\n- old\n"
    merged, vh, t, rc = merge(tmp_path, base, ours, theirs)
    assert rc == 1
    head = "# Changelog\n\n## [Unreleased]\n- prev, fixed\n- theirs\n- ours a\n\n## [1.0.0]\n- old\n"
    assert check(tmp_path, merged, head, vh, t) == (3, "hunk 1 has a non-empty base section")


def test_context_edit_refuses(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    head = head_of("- ours a", "- ours b", "- theirs").replace("# Changelog", "# ChangeLog")
    assert check(tmp_path, merged, head, vh, t) == (
        3, "HEAD differs from git's merge outside the conflict hunks (HEAD line 1)")


def test_context_edit_after_hunk_refuses(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    head = head_of("- ours a", "- ours b", "- theirs", tail="\n## [1.0.0]\n- old, edited\n")
    assert check(tmp_path, merged, head, vh, t) == (
        3, "HEAD differs from git's merge outside the conflict hunks (HEAD line 9)")


def test_no_hunk_refuses(tmp_path):
    # A clean merge: git's result carries no markers at all.
    theirs = "# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n- old\n- old2\n"
    merged, vh, t, rc = merge(tmp_path, BASE, OURS, theirs)
    assert rc == 0
    assert check(tmp_path, merged, merged, vh, t) == (3, "no conflict hunk found")


def test_unbalanced_markers_refuse(tmp_path):
    merged, vh, t, _ = merge(tmp_path, BASE, OURS, THEIRS)
    lines = merged.split(b"\n")
    close = lines.index(b">>>>>>> " + t.encode())
    del lines[close]                       # git's own output, its closing marker removed
    assert check(tmp_path, b"\n".join(lines), head_of("- ours a", "- ours b", "- theirs"), vh, t) == (
        3, "unbalanced conflict markers at line 4")


def test_non_utf8_bytes_compared_bytewise(tmp_path):
    ours = OURS.encode().replace(b"- ours a", b"- caf\xe9 ours")
    merged, vh, t, rc = merge(tmp_path, BASE.encode(), ours, THEIRS.encode())
    assert rc == 1
    head = head_of("- ours a", "- ours b", "- theirs").encode().replace(b"- ours a", b"- caf\xe9 ours")
    assert check(tmp_path, merged, head, vh, t) == (0, "")
    # One byte off is a different line.
    bad = head.replace(b"\xe9", b"\xe8")
    assert check(tmp_path, merged, bad, vh, t) == (
        3, "hunk 1 is not both sides' lines as two contiguous runs")


def test_first_heading_not_unreleased_skips_heading_rule(tmp_path):
    base = "# Changelog\n\n## [1.0.0]\n- old\n"
    ours = "# Changelog\n\n## [1.0.0]\n- old\n- ours a\n"
    theirs = "# Changelog\n\n## [1.0.0]\n- old\n## [0.9.0]\n- theirs\n"
    merged, vh, t, rc = merge(tmp_path, base, ours, theirs)
    assert rc == 1
    # The branch's line lands after a heading: only the [Unreleased] rule would object.
    head = "# Changelog\n\n## [1.0.0]\n- old\n## [0.9.0]\n- theirs\n- ours a\n"
    assert check(tmp_path, merged, head, vh, t) == (0, "")


def test_crlf_markers_refuse_no_hunk(tmp_path):
    crlf = lambda s: s.replace("\n", "\r\n").encode()  # noqa: E731
    merged, vh, t, rc = merge(tmp_path, crlf(BASE), crlf(OURS), crlf(THEIRS))
    assert rc == 1
    head = crlf(head_of("- ours a", "- ours b", "- theirs"))
    assert check(tmp_path, merged, head, vh, t) == (3, "no conflict hunk found")


def test_conflict_marker_size_10_refuses_no_hunk(tmp_path):
    merged, vh, t, rc = merge(
        tmp_path, BASE, OURS, THEIRS,
        base_extra={".gitattributes": "CHANGELOG.md conflict-marker-size=10\n"})
    assert rc == 1
    assert b"\n<<<<<<<<<< " in merged      # the attribute took effect
    head = head_of("- ours a", "- ours b", "- theirs")
    assert check(tmp_path, merged, head, vh, t) == (3, "no conflict hunk found")


def test_usage_error_exits_2(tmp_path):
    r = subprocess.run(["python3", "-I", str(HELPER), "only-one"], capture_output=True)
    assert r.returncode == 2


def test_uncaught_exception_exits_2(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location("mfh", HELPER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    def boom(*_a, **_k):
        raise RuntimeError("boom")

    monkeypatch.setattr(mod, "check", boom)
    m = tmp_path / "m"
    m.write_bytes(b"x\n")
    assert mod.main([str(m), str(m), "a" * 40, "b" * 40]) == 2


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__]))


def parse_only(tmp_path, merged, vh, t):
    m = tmp_path / "merged"
    m.write_bytes(merged)
    r = subprocess.run(
        ["python3", "-I", str(HELPER), "--parse-only", str(m), vh, t],
        capture_output=True,
    )
    return r.returncode, r.stdout.decode("utf-8", "replace").strip()


def test_parse_only_pure_insertions_accepts(tmp_path):
    merged, vh, t, rc = merge(tmp_path, BASE, OURS, THEIRS)
    assert rc == 1
    assert parse_only(tmp_path, merged, vh, t) == (0, "")


def test_parse_only_nonempty_base_refuses(tmp_path):
    base = "# Changelog\n\n## [Unreleased]\n- prev\n\n## [1.0.0]\n- old\n"
    ours = "# Changelog\n\n## [Unreleased]\n- prev\n- ours a\n\n## [1.0.0]\n- old\n"
    theirs = "# Changelog\n\n## [Unreleased]\n- prev, fixed\n- theirs\n\n## [1.0.0]\n- old\n"
    merged, vh, t, rc = merge(tmp_path, base, ours, theirs)
    assert rc == 1
    assert parse_only(tmp_path, merged, vh, t) == (3, "hunk 1 has a non-empty base section")


def test_parse_only_crlf_refuses_no_hunk(tmp_path):
    crlf = lambda s: s.replace("\n", "\r\n").encode()  # noqa: E731
    merged, vh, t, rc = merge(tmp_path, crlf(BASE), crlf(OURS), crlf(THEIRS))
    assert rc == 1
    assert parse_only(tmp_path, merged, vh, t) == (3, "no conflict hunk found")
