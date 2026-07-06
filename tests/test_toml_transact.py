"""#327 — the `transact` verb: one locked transaction composing the context
choreography's four moves in FIXED order — snapshot (top-level → table,
replace-stale), restore (table → top-level with typed defaults), set (plain
triplets), unset (idempotent deletes) — plus --print-old for the clobber-warn.

Replaces the multi-transaction save/clear/restore/displacement choreography
whose crash/interleave windows were #98/#316/#317's bug class: with ONE
_locked_rmw + atomic replace, a reader or crash sees whole-old or whole-new,
never a mix.
"""

import pathlib
import subprocess
import sys

_TOML = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "lib" / "_toml.py"

KEYS = "branch baseline_sha worktree_path mr_url revision pending_comments_file last_step last_step_name".split()


def run(*args: str, cwd=None) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(_TOML), *args],
                          capture_output=True, text=True, timeout=30)


def write(p: pathlib.Path, text: str) -> None:
    p.write_text(text, encoding="utf-8")


def get(p: pathlib.Path, key: str) -> subprocess.CompletedProcess:
    return run("get", str(p), key)


def test_snapshot_replaces_stale_table_and_skips_empty(tmp_path):
    f = tmp_path / "s.toml"
    write(f, 'branch = "fix/1"\nmr_url = ""\nrevision = 3\n'
             '[context.Issue-9]\nbranch = "STALE"\nmr_url = "STALE"\n')
    r = run("transact", str(f), "--snapshot", "context.Issue-9", *KEYS)
    assert r.returncode == 0, r.stderr
    assert get(f, "context.Issue-9.branch").stdout.strip() == "fix/1"
    # empty-string mr_url skipped; the STALE one must be GONE (replace, not merge)
    assert get(f, "context.Issue-9.mr_url").returncode == 1
    # int type preserved (not stringified)
    assert get(f, "context.Issue-9.revision").stdout.strip() == "3"
    assert 'revision = 3' in f.read_text()


def test_restore_types_defaults_and_corrupt_fallback(tmp_path):
    f = tmp_path / "r.toml"
    # snapshot holds: branch, revision as digit-STRING (legacy save form),
    # last_step corrupt (non-numeric). worktree_path absent entirely.
    write(f, 'active_issue = ""\n'
             '[context.Issue-9]\nbranch = "fix/9"\nrevision = "4"\nlast_step = "junk"\n')
    r = run("transact", str(f),
            "--restore", "context.Issue-9",
            "str", "branch", "",
            "str", "worktree_path", "",
            "int", "revision", "1",
            "int", "last_step", "0",
            "--unset", "context.Issue-9")
    assert r.returncode == 0, r.stderr
    assert get(f, "branch").stdout.strip() == "fix/9"
    assert get(f, "worktree_path").stdout.strip() == ""      # default landed
    assert 'revision = 4' in f.read_text()                    # digit-string coerced to int
    assert 'last_step = 0' in f.read_text()                   # corrupt -> per-key default
    assert get(f, "context.Issue-9.branch").returncode == 1   # table deleted same txn


def test_group_order_snapshot_sees_pre_set_values(tmp_path):
    # Displacement shape: snapshot PREV's values, then overwrite top level with
    # defaults + the NEW issue — the snapshot must capture the PRE-set values.
    f = tmp_path / "d.toml"
    write(f, 'active_issue = "Issue-1"\nbranch = "fix/prev"\nrevision = 7\n')
    r = run("transact", str(f),
            "--snapshot", "context.Issue-1", *KEYS,
            "--set", "str", "branch", "", "int", "revision", "1",
            "str", "active_issue", "Issue-2",
            "--unset", "pending_comments_file")
    assert r.returncode == 0, r.stderr
    assert get(f, "context.Issue-1.branch").stdout.strip() == "fix/prev"
    assert 'revision = 7' in get(f, "context.Issue-1.revision").stdout or \
           get(f, "context.Issue-1.revision").stdout.strip() == "7"
    assert get(f, "branch").stdout.strip() == ""
    assert get(f, "active_issue").stdout.strip() == "Issue-2"


def test_print_old_emits_pre_write_value(tmp_path):
    f = tmp_path / "p.toml"
    write(f, 'active_issue = "Issue-1"\n')
    r = run("transact", str(f), "--print-old", "active_issue",
            "--set", "str", "active_issue", "Issue-2")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "Issue-1"


def test_unset_idempotent_on_missing(tmp_path):
    f = tmp_path / "u.toml"
    write(f, 'a = "1"\n')
    r = run("transact", str(f), "--unset", "nope", "context.gone", "a")
    assert r.returncode == 0, r.stderr
    assert get(f, "a").returncode == 1


def test_validation_before_write_leaves_file_untouched(tmp_path):
    f = tmp_path / "v.toml"
    original = 'a = "1"\n'
    write(f, original)
    r = run("transact", str(f), "--set", "int", "a", "not-an-int")
    assert r.returncode == 2
    assert f.read_text() == original
    # malformed restore triplets likewise
    r = run("transact", str(f), "--restore", "context.X", "str", "only-two")
    assert r.returncode == 2
    assert f.read_text() == original
    # a group token where a value is expected fails loud (reserved tokens)
    r = run("transact", str(f), "--set", "str", "k")
    assert r.returncode == 2
    assert f.read_text() == original


def test_refuses_comment_bearing_file(tmp_path):
    f = tmp_path / "c.toml"
    write(f, '# hand comment\na = "1"\n')
    r = run("transact", str(f), "--set", "str", "a", "2")
    assert r.returncode == 1
    assert "comment" in r.stderr


def test_no_groups_is_a_usage_error(tmp_path):
    f = tmp_path / "e.toml"
    write(f, 'a = "1"\n')
    r = run("transact", str(f))
    assert r.returncode == 2


def test_empty_print_old_group_fails_loud(tmp_path):
    # A silently-ignored empty --print-old would disable a caller's
    # clobber-warn without a trace (review NIT).
    f = tmp_path / "po.toml"
    write(f, 'a = "1"\n')
    r = run("transact", str(f), "--print-old", "--set", "str", "a", "2")
    assert r.returncode == 2
    assert "print-old" in r.stderr
    assert 'a = "1"' in f.read_text()          # untouched


def test_duplicate_group_flag_fails_loud(tmp_path):
    # '--snapshot A k1 --snapshot B k2' would silently treat B/k2 as keys of A
    # (review NIT) — duplicates are rejected before any write.
    f = tmp_path / "dup.toml"
    write(f, 'a = "1"\n')
    r = run("transact", str(f),
            "--snapshot", "ctx.A", "a", "--snapshot", "ctx.B", "a")
    assert r.returncode == 2
    assert "duplicate" in r.stderr
    assert 'a = "1"' in f.read_text()          # untouched
