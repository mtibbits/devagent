"""Tests for scripts/lib/mr-link.py (#704): the closing-keyword link rule,
the aggregation table and the `issue-mrs` line grammar."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "mr-link.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mr_link = _load("mr_link", LIB)

R = "acme/testproj"
KEYWORDS = ["close", "closes", "closed", "fix", "fixes", "fixed",
            "resolve", "resolves", "resolved"]


@pytest.mark.parametrize("host", ["github", "gitlab"])
@pytest.mark.parametrize("kw", KEYWORDS + [k.upper() for k in KEYWORDS]
                         + [k.capitalize() for k in KEYWORDS])
def test_github_keywords_link(host, kw):
    if host == "gitlab" and kw.isupper():
        pytest.skip("GitLab's default pattern is case-sensitive past the first letter")
    assert mr_link.linked(host, f"{kw} #5", R) == {(R, 5)}
    assert mr_link.linked(host, f"{kw}: #5", R) == {(R, 5)}


@pytest.mark.parametrize("host", ["github", "gitlab"])
@pytest.mark.parametrize("text", [
    "Related: #5",
    "see #5",
    "Unclosed #5",
    "Closes #5abc",
    "<!-- Link issues: \"Closes #NNN\" auto-closes on merge. -->",
    "Closes\n#5",
    "Closes https://github.com/acme/testproj/issues/5",
    "#5 closes",
])
def test_must_not_link(host, text):
    assert mr_link.linked(host, text, R) == set()


def test_must_not_link_host_differences():
    assert mr_link.linked("github", "fixing #5", R) == set()
    assert mr_link.linked("gitlab", "fixing #5", R) == {(R, 5)}
    assert mr_link.linked("gitlab", "Implements #5", R) == {(R, 5)}
    assert mr_link.linked("github", "Implements #5", R) == set()
    assert mr_link.linked("gitlab", "Closes project#5", R) == set()


def test_mention_only_links_neither():
    # Shaped like a real PR that mentions two neighbouring issues with no
    # closing keyword: it links neither.
    body = ("Follow-up to #98; the same parser also feeds #100.\n\n"
            "Related: #100")
    for host in ("github", "gitlab"):
        assert mr_link.linked(host, body, R) == set()


def test_three_prs_close_one_issue():
    for body in ("Closes #6", "Fixes #6", "fixes #6\n\nmore text"):
        assert (R, 6) in mr_link.linked("github", body, R)


def test_ref_resolution():
    assert mr_link.linked("github", "Closes #7", "Me/Fork") == {("me/fork", 7)}
    assert mr_link.linked("github", "Closes Other/Repo#7", R) == {("other/repo", 7)}
    assert mr_link.linked("gitlab", "Closes grp/sub/proj#7", "foo/bar") == {("grp/sub/proj", 7)}


def test_gitlab_lists():
    text = "Closes #5, #6 and #7"
    assert mr_link.linked("gitlab", text, R) == {(R, 5), (R, 6), (R, 7)}
    assert mr_link.linked("github", text, R) == {(R, 5)}
    assert mr_link.linked("gitlab", "Fixes issue #5 and grp/sub/bar#8", R) == {(R, 5), ("grp/sub/bar", 8)}


def test_gitlab_lists_follow_the_default_pattern():
    # GitLab's continuation `(?: *,? +and +| *,? *)` with `issues? +` per reference
    assert mr_link.linked("gitlab", "Closes #5 #6", R) == {(R, 5), (R, 6)}
    assert mr_link.linked("gitlab", "Closes issue #5 and issue #6", R) == {(R, 5), (R, 6)}
    assert mr_link.linked("gitlab", "Fixes #5,#6, issues #7", R) == {(R, 5), (R, 6), (R, 7)}
    assert mr_link.linked("gitlab", "Closes #5 then see #6", R) == {(R, 5)}
    assert mr_link.linked("github", "Closes #5 #6", R) == {(R, 5)}


def test_title_and_body_do_not_join():
    assert mr_link.link_text("Fix the parser", "#5 was the report") == "Fix the parser\n#5 was the report"
    assert mr_link.linked("github", mr_link.link_text("Fix the parser", "#5"), R) == set()


@pytest.mark.parametrize("states,want", [
    (["open", "draft", "merged", "closed"], "open"),
    (["draft", "merged", "closed"], "draft"),
    (["merged", "closed"], "merged"),
    (["closed"], "none"),
    ([], "none"),
])
def test_aggregate_table(states, want):
    assert mr_link.aggregate(states) == want


def test_norm_ts():
    assert mr_link.norm_ts("2026-10-07T03:24:16.575Z") == "2026-10-07T03:24:16Z"
    assert mr_link.norm_ts("2026-10-07T03:24:16Z") == "2026-10-07T03:24:16Z"
    assert mr_link.norm_ts("2026-10-07T03:24:16.5+02:00") == "2026-10-07T01:24:16Z"
    assert mr_link.norm_ts("2026-01-01T00:30:00-01:00") == "2026-01-01T01:30:00Z"
    for bad in ("2026-10-07", "garbage", "2026-10-07T03:24:16", "2026-13-07T03:24:16Z"):
        with pytest.raises(ValueError):
            mr_link.norm_ts(bad)


GOOD = ("issue\t5\tmerged\n"
        "mr\t5\tacme/testproj#21\tmerged\t2026-10-01T00:00:00Z\t2026-10-02T00:00:00Z\n"
        "mr\t5\tacme/testproj#22\tclosed\t2026-10-03T00:00:00Z\t-\n"
        "issue\t6\tnone\n"
        "issue\t7\tmissing\n")


def test_parse_good():
    assert mr_link.parse_issue_mrs(GOOD, ["5", "6", "7"]) == {"5": "merged", "6": "none", "7": "missing"}
    assert mr_link.parse_issue_mrs(GOOD.replace("\n", "\r\n") + "\n\n", ["5", "6", "7"])["5"] == "merged"


@pytest.mark.parametrize("text,ids", [
    ("issue\t5\tbogus\n", ["5"]),                                    # bad state
    ("issue\t5\topen\textra\n", ["5"]),                              # malformed line
    ("issue\t5\tnone\n", ["5", "6"]),                                # id missing
    ("issue\t5\tnone\nissue\t5\tnone\n", ["5"]),                     # id repeated
    ("issue\t5\tnone\nissue\t6\tnone\n", ["5"]),                     # extra id
    ("mr\t5\ta/b#1\topen\t2026-10-01T00:00:00Z\t-\nissue\t5\topen\n", ["5"]),  # mr first
    ("issue\t5\tmissing\nmr\t5\ta/b#1\topen\t2026-10-01T00:00:00Z\t-\n", ["5"]),  # missing + mr
    ("issue\t5\tnone\nmr\t5\ta/b#1\topen\t2026-10-01T00:00:00Z\t-\n", ["5"]),  # aggregate mismatch
    ("issue\t5\topen\nmr\t6\ta/b#1\topen\t2026-10-01T00:00:00Z\t-\n", ["5"]),  # mr for another id
    ("issue\t5\topen\nmr\t5\ta/b#1\topen\t2026-10-01\t-\n", ["5"]),  # bad created
    ("issue\t5\tmerged\nmr\t5\ta/b#1\tmerged\t2026-10-01T00:00:00Z\tnever\n", ["5"]),  # bad merged
    ("issue\t5\topen\nmr\t5\tnot-a-ref\topen\t2026-10-01T00:00:00Z\t-\n", ["5"]),  # bad ref
    ("issue\t5\topen\nmr\t5\ta/b#1\tlocked\t2026-10-01T00:00:00Z\t-\n", ["5"]),  # bad mr state
])
def test_parse_rejects(text, ids):
    with pytest.raises(ValueError):
        mr_link.parse_issue_mrs(text, ids)


def _emit(host, repo, records):
    stdin = "".join(json.dumps(r) + "\n" for r in records)
    return subprocess.run([sys.executable, str(LIB), "emit", host, repo],
                          input=stdin, capture_output=True, text=True)


def _pr(ref, state, body, created="2026-10-01T00:00:00Z", merged=None, draft=False,
        title="t", repo=R):
    return {"repo": repo, "ref": ref, "state": state, "draft": draft,
            "created": created, "merged": merged, "title": title, "body": body}


def test_emit_then_check_roundtrip():
    recs = [
        {"id": "6", "status": "ok", "mrs": [
            _pr(f"{R}#22", "open", "Fixes #6", created="2026-10-05T00:00:00.1Z"),
            _pr(f"{R}#21", "merged", "Closes #6", merged="2026-10-02T10:00:00+02:00"),
            _pr(f"{R}#21", "merged", "Closes #6", merged="2026-10-02T10:00:00+02:00"),  # dup
            _pr(f"{R}#99", "open", "mentions #6"),
            _pr(f"{R}#30", "open", "Closes #6", draft=True, created="2026-10-06T00:00:00Z"),
        ]},
        {"id": "7", "status": "missing", "mrs": []},
        {"id": "8", "status": "ok", "mrs": [_pr(f"{R}#40", "closed", "Closes #8")]},
    ]
    p = _emit("github", R, recs)
    assert p.returncode == 0, p.stderr
    assert p.stdout.splitlines() == [
        "issue\t6\topen",
        f"mr\t6\t{R}#21\tmerged\t2026-10-01T00:00:00Z\t2026-10-02T08:00:00Z",
        f"mr\t6\t{R}#22\topen\t2026-10-05T00:00:00Z\t-",
        f"mr\t6\t{R}#30\tdraft\t2026-10-06T00:00:00Z\t-",
        "issue\t7\tmissing",
        "issue\t8\tnone",
        f"mr\t8\t{R}#40\tclosed\t2026-10-01T00:00:00Z\t-",
    ]
    assert mr_link.parse_issue_mrs(p.stdout, ["6", "7", "8"]) == {"6": "open", "7": "missing", "8": "none"}
    c = subprocess.run([sys.executable, str(LIB), "check", "6", "7", "8"],
                       input=p.stdout, capture_output=True, text=True)
    assert c.returncode == 0, c.stderr
    assert c.stdout.strip() == "3"


def test_emit_writes_lf_only():
    # §9.2's lines end LF on every platform: Windows text-mode stdout would add CR.
    stdin = json.dumps({"id": "6", "status": "ok", "mrs": [_pr(f"{R}#21", "open", "Closes #6")]})
    p = subprocess.run([sys.executable, str(LIB), "emit", "github", R],
                       input=(stdin + "\n").encode(), capture_output=True)
    assert p.returncode == 0, p.stderr
    assert b"\r" not in p.stdout
    assert p.stdout == f"issue\t6\topen\nmr\t6\t{R}#21\topen\t2026-10-01T00:00:00Z\t-\n".encode()


def test_emit_fork_pr_links_fork_only():
    fork_pr = _pr("me/testproj-fork#3", "open", "Closes #5", repo="me/testproj-fork")
    up = _emit("github", R, [{"id": "5", "status": "ok", "mrs": [fork_pr]}])
    fk = _emit("github", "me/testproj-fork", [{"id": "5", "status": "ok", "mrs": [fork_pr]}])
    assert up.stdout.splitlines() == ["issue\t5\tnone"]
    assert fk.stdout.splitlines()[0] == "issue\t5\topen"


@pytest.mark.parametrize("stdin", [
    "not json\n",
    json.dumps({"id": "5", "status": "ok", "mrs": [_pr(f"{R}#1", "weird", "Closes #5")]}) + "\n",
    json.dumps({"id": "5", "status": "ok", "mrs": [_pr(f"{R}#1", "open", "Closes #5", created="x")]}) + "\n",
    json.dumps({"id": "5", "status": "bogus", "mrs": []}) + "\n",
    json.dumps({"id": "5"}) + "\n",
])
def test_emit_bad_input_exits_5(stdin):
    p = subprocess.run([sys.executable, str(LIB), "emit", "github", R],
                       input=stdin, capture_output=True, text=True)
    assert p.returncode == 5
    assert p.stdout == ""


def test_check_cli_uses_parse():
    bad = "issue\t5\tnone\nmr\t5\ta/b#1\topen\t2026-10-01T00:00:00Z\t-\n"
    with pytest.raises(ValueError) as e:
        mr_link.parse_issue_mrs(bad, ["5"])
    c = subprocess.run([sys.executable, str(LIB), "check", "5"],
                       input=bad, capture_output=True, text=True)
    assert c.returncode == 1
    assert str(e.value) in c.stderr
