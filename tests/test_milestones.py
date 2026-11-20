"""Tests for scripts/lib/milestones.py (#734): checklist log rows, tracker
and MR rows, scope, spans and rendering."""
import importlib.util
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "milestones.py"
FIX = REPO / "tests" / "fixtures" / "milestones"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ms = _load("milestones", LIB)


def _rows(path, issue="Issue-1"):
    return ms.checklist_rows(path, f"{path.parent.name}/checklist.md", "p", issue)


def _line(path, source):
    n = int(source.rsplit(":", 1)[1])
    return path.read_bytes().decode("utf-8").split("\n")[n - 1]


# --- Task 3: checklist log rows ------------------------------------------------

def test_rev2_rows_carry_revision_offset_and_line():
    path = FIX / "rev2" / "Issue-465" / "checklist.md"
    rows, warnings = _rows(path, "Issue-465")
    assert warnings == []
    done = {(r["step"], r["revision"]) for r in rows if r["event"] == "step_done"}
    assert done == {("pull", 1), ("draft", 1), ("branch", 1), ("implement", 1),
                    ("ship", 1), ("implement", 2), ("ship", 2)}
    assert [r["event"] for r in rows].count("revision_started") == 1
    for r in rows:
        assert r["at"].endswith("-04:00")
        assert r["tz"] == "assumed"
        assert r["source"].startswith("Issue-465/checklist.md:")
        line = _line(path, r["source"])
        assert r["at"][11:16] in line
        assert f"  {r.get('step') or r.get('name') or 'revise'}:" in line
    first = next(r for r in rows if r.get("step") == "pull")
    assert first["at"] == "2026-09-10T08:00-04:00"
    assert first["source"] == "Issue-465/checklist.md:19"


def test_real_shapes_rows():
    path = FIX / "shapes" / "Issue-700" / "checklist.md"
    rows, warnings = _rows(path, "Issue-700")
    assert warnings == []
    got = Counter((r["event"], r.get("step") or r.get("name")) for r in rows)
    assert got == Counter({
        ("step_done", "pull"): 1, ("step_done", "draft"): 1,
        ("step_done", "implement"): 2, ("step_done", "analyze"): 1,
        ("step_note", "analyze"): 1, ("step_done", "preship"): 1,
        ("log", "quality-fix"): 1, ("parked", None): 1, ("resumed", None): 1,
        ("log", "17"): 1, ("log", "real-silicon (prior session)"): 1,
        ("log", "reap"): 1, ("log", "sync"): 1, ("revision_started", None): 1,
        ("log", "-"): 1,
    })
    analyze_done = next(r for r in rows if r["event"] == "step_done" and r["step"] == "analyze")
    assert analyze_done["at"] == "2026-10-12T08:11-04:00"
    impl2 = [r for r in rows if r["event"] == "step_done" and r["step"] == "implement"]
    assert [r["revision"] for r in impl2] == [1, 2]
    dateonly = next(r for r in rows if r.get("name") == "-")
    assert dateonly["at"] == "2026-06-24"
    # the dated bullet under ## Notes (line 19) yields nothing
    assert not any(r["source"].endswith(":19") for r in rows)
    assert len(rows) == 16


def test_retier_is_a_revision_start(tmp_path):
    p = tmp_path / "Issue-1" / "checklist.md"
    p.parent.mkdir()
    p.write_text("Created: 2026-01-01T00:00:00Z\n\n## Revision 1\n\n- [x]  9. implement\n\n"
                 "## Log\n"
                 "- 2026-01-01 10:00  implement: first\n"
                 "- 2026-01-02 10:00  revise: retier: standard → oneshot (revision 2)\n"
                 "- 2026-01-02 10:05  implement: second\n"
                 "- 2026-01-02 10:06  revise: retier: oneshot → oneshot (revision 2)\n"
                 "- 2026-01-02 10:07  implement: third\n"
                 "\n## Revision 2\n\n- [x]  9. implement\n")
    rows, warnings = _rows(p)
    assert warnings == []
    assert [(r["event"], r["revision"]) for r in rows] == [
        ("step_done", 1), ("revision_started", 2), ("step_done", 2),
        ("revision_started", 2), ("step_note", 2)]
    assert rows[0]["at"] == "2026-01-01T10:00Z"


def test_retier_without_revision_suffix_is_a_log_line(tmp_path):
    p = tmp_path / "Issue-1" / "checklist.md"
    p.parent.mkdir()
    p.write_text("Created: 2026-01-01T00:00:00+00:00\n## Revision 1\n- [x]  9. implement\n## Log\n"
                 "- 2026-01-02 10:00  revise: Revision 2 opened MANUALLY by the operator\n")
    rows, _ = _rows(p)
    assert [(r["event"], r["name"], r["revision"]) for r in rows] == [("log", "revise", 1)]


def test_revision_mismatch_warns():
    path = FIX / "mismatch" / "Issue-9" / "checklist.md"
    rows, warnings = _rows(path, "Issue-9")
    assert warnings == [
        "Issue-9/checklist.md: revision starts logged {1} but ## Revision headings {1, 2}"]
    assert [r["event"] for r in rows] == ["step_done", "step_done"]


def test_no_offset_is_tz_unknown(tmp_path):
    p = tmp_path / "Issue-1" / "checklist.md"
    p.parent.mkdir()
    p.write_text("Created: 2026-01-01T00:00:00\n## Revision 1\n- [x]  9. implement\n## Log\n"
                 "- 2026-01-02 10:00  implement: done\n")
    rows, _ = _rows(p)
    assert (rows[0]["at"], rows[0]["tz"]) == ("2026-01-02T10:00", "unknown")


def test_no_created_line_is_tz_unknown(tmp_path):
    p = tmp_path / "Issue-1" / "checklist.md"
    p.parent.mkdir()
    p.write_text("## Revision 1\n- [x]  9. implement\n## Log\n- 2026-01-02 10:00  implement: done\n")
    rows, _ = _rows(p)
    assert (rows[0]["at"], rows[0]["tz"]) == ("2026-01-02T10:00", "unknown")


def test_crlf_same_rows(tmp_path):
    src = FIX / "rev2" / "Issue-465" / "checklist.md"
    p = tmp_path / "Issue-465" / "checklist.md"
    p.parent.mkdir()
    p.write_bytes(src.read_bytes().replace(b"\n", b"\r\n"))
    assert _rows(p, "Issue-465") == _rows(src, "Issue-465")


def test_revision_heading_with_suffix_counts(tmp_path):
    # volk Issue-Fork-136's shape: `## Revision 1 — SHORT-CIRCUITED (…)`
    # is revision 1's heading (portfolio.py's REVISION_HEADING prefix rule).
    p = tmp_path / "Issue-1" / "checklist.md"
    p.parent.mkdir()
    p.write_text("Created: 2026-01-01T00:00:00Z\n## Revision 1 — SHORT-CIRCUITED (trivial)\n"
                 "- [x]  9. implement\n## Log\n- 2026-01-02 10:00  implement: done\n")
    assert _rows(p)[1] == []


# --- Task 4: tracker and MR rows, scope, spans, rendering ----------------------

def _src(S="ORIGIN", backend="github", prefix="Issue-", repo="acme/testproj", keyprefix=""):
    return {"S": S, "backend": backend, "prefix": prefix, "REPO": repo,
            "keyprefix": keyprefix, "STATUS": "ok"}


def _rec(rid, state="open", created="2026-01-13", closed=None, cls=None):
    return {"id": rid, "title": "t", "body": "", "state": state,
            "class": cls or ("done" if state == "closed" else "open"),
            "created": created, "closed": closed, "milestone": None, "labels": [],
            "type": None, "parent": None, "blocked_by": [],
            "url": f"https://github.com/acme/testproj/issues/{rid}"}


def _checklist(devdoc, name, log=("- 2026-01-20 10:00  implement: done",)):
    d = devdoc / name
    d.mkdir(parents=True)
    (d / "checklist.md").write_text(
        "Created: 2026-01-01T00:00:00+00:00\n## Revision 1\n- [x]  9. implement\n## Log\n"
        + "".join(l + "\n" for l in log))


def test_two_mrs_rows():
    text = ("issue\t6\tmerged\n"
            "mr\t6\tacme/testproj#21\tmerged\t2026-06-10T04:11:31Z\t2026-06-10T04:27:27Z"
            "\thttps://github.com/acme/testproj/pull/21\tdev/all-prs\n"
            "mr\t6\tacme/testproj#22\tclosed\t2026-06-11T09:00:00Z\t-"
            "\thttps://github.com/acme/testproj/pull/22\tmaster\n")
    _, mrs = ms.mrl.parse_issue_mrs_detail(text, ["6"])
    rows = ms.mr_rows(mrs["6"], "Issue-6", "p")
    assert [(r["event"], r["at"], r["source"], r["mr"], r["base"]) for r in rows] == [
        ("mr_opened", "2026-06-10T04:11:31Z", "https://github.com/acme/testproj/pull/21",
         "acme/testproj#21", "dev/all-prs"),
        ("mr_merged", "2026-06-10T04:27:27Z", "https://github.com/acme/testproj/pull/21",
         "acme/testproj#21", "dev/all-prs"),
        ("mr_opened", "2026-06-11T09:00:00Z", "https://github.com/acme/testproj/pull/22",
         "acme/testproj#22", "master"),
    ]
    assert {r["issue"] for r in rows} == {"Issue-6"}


def test_mr_row_without_url_uses_ref():
    text = "issue\t6\topen\nmr\t6\tacme/testproj#21\topen\t2026-06-10T04:11:31Z\t-\n"
    _, mrs = ms.mrl.parse_issue_mrs_detail(text, ["6"])
    (row,) = ms.mr_rows(mrs["6"], "Issue-6", "p")
    assert (row["source"], row["base"]) == ("acme/testproj#21", None)


def test_tracker_rows_closed_reason():
    rows = ms.tracker_rows(_rec("6", "closed", "2026-01-13", "2026-02-08", "done"), _src(), "p")
    assert [(r["event"], r["at"], r.get("reason")) for r in rows] == [
        ("opened", "2026-01-13", None), ("closed", "2026-02-08", "done")]
    assert {r["source"] for r in rows} == {"https://github.com/acme/testproj/issues/6"}
    assert {r["issue"] for r in rows} == {"Issue-6"}
    assert [r["event"] for r in ms.tracker_rows(_rec("7"), _src(), "p")] == ["opened"]


def _labels(issues):
    return [i["label"] for i in issues]


def test_scope_default_is_checklists_plus_open(tmp_path):
    src = _src()
    recs = [(src, _rec("1")), (src, _rec("2", "closed", closed="2026-02-01")),
            (src, _rec("3", "closed", closed="2026-02-01"))]
    _checklist(tmp_path, "Issue-3")
    assert _labels(ms.scope_issues("default", [src], recs, tmp_path)) == ["Issue-1", "Issue-3"]
    assert _labels(ms.scope_issues("all", [src], recs, tmp_path)) == ["Issue-1", "Issue-2", "Issue-3"]
    (one,) = ms.scope_issues("issue", [src], recs, tmp_path, "Issue-3")
    assert (one["label"], one["dir"], one["record"]["id"]) == ("Issue-3", "Issue-3", "3")


def test_scope_sorts_origin_fork_unmapped_then_numeric(tmp_path):
    o, f = _src(), _src("FORK", prefix="Issue-Fork-", repo="me/testproj")
    recs = [(o, _rec("10")), (o, _rec("9")), (f, _rec("2"))]
    _checklist(tmp_path, "Scratch-1")
    _checklist(tmp_path, "Issue-Fork-1")
    assert _labels(ms.scope_issues("default", [o, f], recs, tmp_path)) == [
        "Issue-9", "Issue-10", "Issue-Fork-1", "Issue-Fork-2", "Scratch-1"]


def test_fork_and_unmapped_leaves(tmp_path):
    o, f = _src(), _src("FORK", prefix="Issue-Fork-", repo="me/testproj")
    recs = [(f, _rec("3", "closed", closed="2026-02-01"))]
    _checklist(tmp_path, "Issue-Fork-3")
    _checklist(tmp_path, "Scratch-1")
    issues = ms.scope_issues("default", [o, f], recs, tmp_path)
    fork = next(i for i in issues if i["label"] == "Issue-Fork-3")
    assert (fork["src"]["S"], fork["rid"], fork["dir"], fork["record"]["id"]) == \
        ("FORK", "3", "Issue-Fork-3", "3")
    scratch = next(i for i in issues if i["label"] == "Scratch-1")
    assert (scratch["src"], scratch["record"], scratch["dir"]) == (None, None, "Scratch-1")
    assert ms.mr_keys(issues, "github") == [("FORK", "me/testproj", "3")]


def test_mr_keys_eligibility(tmp_path):
    jira = _src(backend="jira", repo="PROJ", keyprefix="PROJ")
    issues = ms.scope_issues("all", [jira], [(jira, _rec("PROJ-12"))], tmp_path)
    assert issues and ms.mr_keys(issues, "github") == []
    gh = _src()
    issues = ms.scope_issues("all", [gh], [(gh, _rec("5")), (gh, _rec("40")), (gh, _rec("7"))], tmp_path)
    assert ms.mr_keys(issues, "gitlab") == []
    assert ms.mr_keys(issues, "") == []
    assert ms.mr_keys(issues, "github") == [("ORIGIN", "acme/testproj", "5"),
                                            ("ORIGIN", "acme/testproj", "7"),
                                            ("ORIGIN", "acme/testproj", "40")]


def test_jira_dir_and_record_are_one_issue(tmp_path):
    jira = _src(backend="jira", repo="PROJ", keyprefix="PROJ")
    rec = _rec("PROJ-12", "closed", created="2026-01-10", closed="2026-01-25")
    _checklist(tmp_path, "Issue-PROJ-12", ("- 2026-01-15 10:00  implement: done",))
    issues = ms.scope_issues("default", [jira], [(jira, rec)], tmp_path)
    assert _labels(issues) == ["Issue-12"]
    assert issues[0]["dir"] == "Issue-PROJ-12"
    rows, _ = ms.issue_rows(issues[0], tmp_path, "p", {})
    assert {r["issue"] for r in rows} == {"Issue-12"}
    assert ms.spans_line("Issue-12", rows) == \
        "Issue-12\topened->merged -\topened->closed 15\tfirst-step->closed 10\tparked 0.0d"


def test_missing_render_has_one_prefix():
    missing = [("tracker", "not configured")]
    text = ms.render_text("p", "default", missing, [])
    assert text == ["milestones: p scope: default", "missing: tracker: not configured", "(no rows)"]
    (hdr,) = ms.render_json("p", "default", missing, [])
    assert json.loads(hdr)["missing"] == [{"source": "tracker", "detail": "not configured"}]


def _r(event, at, **kw):
    return {"project": "p", "issue": "Issue-1", "event": event, "at": at, "source": "s", **kw}


def test_spans_exact():
    rows = [
        _r("opened", "2026-01-01"),
        _r("step_done", "2026-01-03T10:00-04:00", step="draft", revision=1, tz="assumed"),
        _r("parked", "2026-01-04T00:00Z", revision=1, tz="assumed"),
        _r("resumed", "2026-01-05T12:00Z", revision=1, tz="assumed"),
        _r("resumed", "2026-01-06T12:00Z", revision=1, tz="assumed"),  # no open park: ignored
        _r("mr_merged", "2026-01-09T23:59:59Z", mr="a/b#2", base="main"),
        _r("mr_merged", "2026-01-08T01:00:00Z", mr="a/b#1", base="main"),
        _r("closed", "2026-01-10", reason="done"),
        _r("parked", "2026-01-11T00:00Z", revision=1, tz="assumed"),
    ]
    assert ms.spans_line("Issue-1", ms.sort_rows(rows)) == (
        "Issue-1\topened->merged 7\topened->closed 9\tfirst-step->closed 7\tparked 1.5d+open")
    assert ms.spans_line("Issue-1", [_r("log", "2026-01-01", name="-", revision=1, tz="unknown")]) == (
        "Issue-1\topened->merged -\topened->closed -\tfirst-step->closed -\tparked 0.0d")


def test_sort_rows_by_utc_instant_then_input_order():
    rows = [
        _r("step_done", "2026-01-02T01:00+05:00", step="a", revision=1, tz="assumed"),  # 2026-01-01T20:00Z
        _r("opened", "2026-01-02"),                                                  # 00:00Z
        _r("log", "2026-01-01T21:00", name="x", revision=1, tz="unknown"),            # as UTC
        _r("log", "2026-01-01T21:00Z", name="y", revision=1, tz="assumed"),           # tie: input order
    ]
    assert [r.get("step") or r.get("name") or r["event"] for r in ms.sort_rows(rows)] == \
        ["a", "x", "y", "opened"]


ROWS = [
    _r("opened", "2026-01-13"),
    _r("closed", "2026-02-08", reason="done"),
    _r("mr_opened", "2026-01-14T00:00:00Z", mr="a/b#21", base="main"),
    _r("mr_merged", "2026-01-15T00:00:00Z", mr="a/b#21", base=None),
    _r("step_done", "2026-01-14T10:00-04:00", step="draft", revision=1, tz="assumed"),
    _r("step_note", "2026-01-14T11:00-04:00", step="draft", revision=1, tz="assumed"),
    _r("parked", "2026-01-14T12:00-04:00", revision=1, tz="assumed"),
    _r("resumed", "2026-01-14T13:00-04:00", revision=1, tz="assumed"),
    _r("revision_started", "2026-01-14T14:00-04:00", revision=2, tz="assumed"),
    _r("log", "2026-01-14T15:00", name="reap", revision=2, tz="unknown"),
]

KEYS = {
    "opened": set(),
    "closed": {"reason"},
    "mr_opened": {"mr", "base"}, "mr_merged": {"mr", "base"},
    "step_done": {"step", "revision", "tz"}, "step_note": {"step", "revision", "tz"},
    "parked": {"revision", "tz"}, "resumed": {"revision", "tz"},
    "revision_started": {"revision", "tz"},
    "log": {"name", "revision", "tz"},
}


def test_json_header_and_row_keys():
    lines = ms.render_json("p", "issue", [("mr", "no code_source.backend")], [("Issue-1", ROWS)])
    docs = [json.loads(l) for l in lines]
    assert docs[0] == {"kind": "header", "project": "p", "scope": "issue",
                       "missing": [{"source": "mr", "detail": "no code_source.backend"}]}
    assert len(docs) == 1 + len(ROWS)
    base = {"kind", "project", "issue", "event", "at", "source"}
    for d in docs[1:]:
        assert d["kind"] == "row"
        assert set(d) == base | KEYS[d["event"]], d["event"]
    assert {d["event"] for d in docs[1:]} == set(KEYS)


def test_text_rows_and_detail_column():
    lines = ms.render_text("p", "issue", [], [("Issue-1", ROWS)])
    assert lines[0] == "milestones: p scope: issue"
    body = lines[1:1 + len(ROWS)]
    assert body == [
        "Issue-1\t2026-01-13\topened\t-\ts",
        "Issue-1\t2026-02-08\tclosed\tdone\ts",
        "Issue-1\t2026-01-14T00:00:00Z\tmr_opened\ta/b#21 base=main\ts",
        "Issue-1\t2026-01-15T00:00:00Z\tmr_merged\ta/b#21 base=-\ts",
        "Issue-1\t2026-01-14T10:00-04:00\tstep_done\tdraft r1 tz=assumed\ts",
        "Issue-1\t2026-01-14T11:00-04:00\tstep_note\tdraft r1 tz=assumed\ts",
        "Issue-1\t2026-01-14T12:00-04:00\tparked\tr1 tz=assumed\ts",
        "Issue-1\t2026-01-14T13:00-04:00\tresumed\tr1 tz=assumed\ts",
        "Issue-1\t2026-01-14T14:00-04:00\trevision_started\tr2 tz=assumed\ts",
        "Issue-1\t2026-01-14T15:00\tlog\treap r2 tz=unknown\ts",
    ]
    assert lines[1 + len(ROWS):] == [
        "spans:",
        "Issue-1\topened->merged 2\topened->closed 26\tfirst-step->closed 25\tparked 0.0d"]


def test_text_empty_form():
    assert ms.render_text("p", "all", [], []) == ["milestones: p scope: all", "(no rows)"]
    assert ms.render_json("p", "all", [], []) == [
        '{"kind":"header","project":"p","scope":"all","missing":[]}']


def test_stdout_is_lf_bytes(tmp_path):
    _checklist(tmp_path, "Issue-1")
    env = {"PATH": "/usr/bin:/bin", "MS_MR_BACKEND": ""}
    for args in ([], ["--json"]):
        p = subprocess.run([sys.executable, str(LIB), "emit", str(tmp_path), "p", "default", *args],
                           capture_output=True, env=env)
        assert p.returncode == 0, p.stderr
        assert b"\r" not in p.stdout
        assert b"Issue-1\t2026-01-20T10:00+00:00\tstep_done" in p.stdout or b'"step":"implement"' in p.stdout


def test_missing_keeps_source_order(tmp_path):
    env = {"MS_TRK_ORIGIN_BACKEND": "github", "MS_TRK_ORIGIN_REPO": "a/b",
           "MS_TRK_ORIGIN_PREFIX": "Issue-", "MS_TRK_ORIGIN_STATUS": "failed",
           "MS_TRK_ORIGIN_DETAIL": "exit 1: boom",
           "MS_TRK_FORK_BACKEND": "github", "MS_TRK_FORK_REPO": "me/b",
           "MS_TRK_FORK_PREFIX": "Issue-F", "MS_TRK_FORK_STATUS": "nolookup",
           "MS_TRK_FORK_DETAIL": "gh not on PATH"}
    _, missing, failed = ms.tracker_inputs(env, ms.sources_from_env(env))
    assert missing == [("tracker", "github a/b issue-list failed (exit 1: boom)"),
                       ("fork tracker", "github has no issue-list (gh not on PATH)")]
    assert failed == missing[:1]


# --- final review: an unreadable time is reported, never fatal ------------------

def test_bad_log_time_is_skipped_with_warning(tmp_path):
    p = tmp_path / "Issue-1" / "checklist.md"
    p.parent.mkdir()
    p.write_text("Created: 2026-01-01T00:00:00+00:00\n## Revision 1\n- [x]  9. implement\n## Log\n"
                 "- 2026-02-30 10:00  sync: x\n"
                 "- 2026-01-01 24:00  implement: a\n"
                 "- 2026-02-31  closeout: by hand\n"
                 "- 2026-01-02 10:00  implement: b\n")
    rows, warnings = _rows(p)
    assert [(r["event"], r["at"]) for r in rows] == [("step_done", "2026-01-02T10:00+00:00")]
    assert warnings == [
        "Issue-1/checklist.md:5: unreadable time '2026-02-30 10:00'; line skipped",
        "Issue-1/checklist.md:6: unreadable time '2026-01-01 24:00'; line skipped",
        "Issue-1/checklist.md:7: unreadable time '2026-02-31'; line skipped",
    ]


def test_bad_log_time_cli_exits_0_with_one_warning(tmp_path):
    d = tmp_path / "Issue-1"
    d.mkdir()
    (d / "checklist.md").write_text("## Revision 1\n- [x]  9. implement\n## Log\n"
                                    "- 2026-02-30 10:00  implement: x\n")
    p = subprocess.run([sys.executable, str(LIB), "emit", str(tmp_path), "p", "default"],
                       capture_output=True, env={"PATH": "/usr/bin:/bin"})
    assert p.returncode == 0, p.stderr
    assert p.stderr.decode().splitlines() == [
        "milestones: WARNING: Issue-1/checklist.md:4: unreadable time '2026-02-30 10:00'; line skipped"]


def test_bad_mr_time_fails_the_source(tmp_path):
    out = tmp_path / "mr.out"
    out.write_text("issue\t1\topen\nmr\t1\ta/b#2\topen\t2026-13-01T00:00:00Z\t-\n")
    env = {"MS_TRK_ORIGIN_BACKEND": "github", "MS_TRK_ORIGIN_REPO": "a/b",
           "MS_TRK_ORIGIN_PREFIX": "Issue-", "MS_TRK_ORIGIN_STATUS": "ok",
           "MS_MR_BACKEND": "github", "MS_MR_STATUS": "ready",
           "MS_MR_ORIGIN_RC": "0", "MS_MR_ORIGIN_FILE": str(out)}
    sources = ms.sources_from_env(env)
    issues = ms.scope_issues("issue", sources, [], tmp_path, "Issue-1")
    details, missing, failed = ms.mr_inputs(env, sources, issues)
    assert details == {}
    assert missing == failed == [
        ("mr", "github a/b issue-mrs failed (bad time '2026-13-01T00:00:00Z')")]
