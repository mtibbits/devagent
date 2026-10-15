"""Tests for scripts/lib/wbs-import.py (#706)."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "wbs-import.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_import = _load("wbs_import", LIB)


def rec(id_="1", **kw):
    r = {"id": id_, "title": "t", "body": "", "state": "open", "class": "open",
         "created": "2026-01-02", "closed": None, "milestone": None,
         "labels": [], "type": None, "parent": None, "blocked_by": [],
         "url": f"https://github.com/o/r/issues/{id_}"}
    r.update(kw)
    return r


def lines(*recs):
    return "".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in recs)


# --- the record contract (Task 2) -------------------------------------------
def test_contract_parse_issue_list_ok_and_empty():
    closed = rec("2", state="closed", **{"class": "done"}, closed="2026-02-01")
    assert len(wbs_import.parse_issue_list(lines(rec("1"), closed))) == 2
    assert wbs_import.parse_issue_list("") == []


@pytest.mark.parametrize("name, bad", [
    ("null_line", "null"),
    ("list_line", "[]"),
    ("non_json", "{not json"),
    ("missing_key", {k: v for k, v in rec("2").items() if k != "url"}),
    ("wrong_type", rec("2", labels="epic")),
    ("bad_class", rec("2", **{"class": "closed"})),
    ("bad_date", rec("2", created="2026-02-30")),
    ("closed_on_open", rec("2", closed="2026-02-01")),
    ("no_closed_date", rec("2", state="closed", **{"class": "done"})),
    ("duplicate_id", rec("1")),
])
def test_contract_parse_issue_list_rejects(name, bad):
    with pytest.raises(ValueError, match=r"^malformed line 2: "):
        wbs_import.parse_issue_list(lines(rec("1"), bad))


def test_contract_check_cli():
    ok = subprocess.run([sys.executable, str(LIB), "check"], input=lines(rec("1"), rec("2")),
                        capture_output=True, text=True)
    assert (ok.returncode, ok.stdout) == (0, "2\n")
    bad = subprocess.run([sys.executable, str(LIB), "check"], input="null\n",
                         capture_output=True, text=True)
    assert bad.returncode == 1 and "malformed line 1" in bad.stderr


# --- parent lines (Task 8) ---------------------------------------------------
GH = "https://github.com/o/r/issues/"


@pytest.mark.parametrize("body, want", [
    ("Parent epic: #3\n\nText.", ("num", "3")),                       # first
    ("Text.\n\nMore.\n\nParent epic: #3", ("num", "3")),              # last
    ("Parent epic: " + GH + "3", ("url", GH + "3")),                 # url
    ("Parent epic: data-pipeline " + chr(0x2014) + " " + GH + "3", ("url", GH + "3")),
    ("Parent epic: data-pipeline " + GH + "3", ("url", GH + "3")),    # space only
    ("Parent epic: data-pipeline -- <" + GH + "3>", ("url", GH + "3")),
    ("- **Parent epic:** #3", ("num", "3")),                          # bold wrapper
    ("__Parent epic:__ #3", ("num", "3")),
    ("parent EPIC: #3", ("num", "3")),                                # key case
    ("Parent epic: [the epic](" + GH + "3)", ("url", GH + "3")),      # markdown link
    ("Parent epic: data-pipeline", ("slug", "data-pipeline")),
    ("Parent epic: the data pipeline one", ("other", "the data pipeline one")),
    ("Parent epic: #3   " + chr(13) + chr(10), ("num", "3")),
])
def test_parent_line_forms(body, want):
    got = wbs_import.parent_line(body)
    assert got is not None and got[:2] == want


def test_parent_line_raw_is_the_stripped_line():
    assert wbs_import.parent_line("  - Parent epic: x-y  \n")[2] == "- Parent epic: x-y"


@pytest.mark.parametrize("body", [
    "Text.\n\n```\nParent epic: #1\n```\n",
    "Text.\n\n~~~~\nParent epic: #1\n~~~~\n",
    "No parent here.",
    "Parent epic:   ",
])
def test_parent_line_none(body):
    assert wbs_import.parent_line(body) is None


def test_parent_line_unclosed_fence_is_not_a_fence():
    # #701: an opener with no closer is not a fence
    assert wbs_import.parent_line("```\nParent epic: #1\n")[:2] == ("num", "1")


def test_parent_line_first_match_wins():
    assert wbs_import.parent_line("Parent epic: #3\nParent epic: #4")[:2] == ("num", "3")


def test_parent_line_jira_bare_key():
    assert wbs_import.parent_line("Parent epic: PROJ-12", jira=True)[:2] == ("key", "PROJ-12")
    assert wbs_import.parent_line("Parent epic: PROJ-12")[:2] == ("slug", "PROJ-12")


def test_parent_line_no_backtracking_on_long_whitespace():
    import time
    body = "Parent epic: a" + " " * 60000 + "b"
    t = time.monotonic()
    got = wbs_import.parent_line(body)
    assert time.monotonic() - t < 1.0
    assert got[0] == "other"


@pytest.mark.parametrize("url, want", [
    (GH + "12", ("o/r", "12")),
    ("https://ghe.example/Acme/Repo/issues/7/?x=1#c", ("Acme/Repo", "7")),
    ("https://gitlab.example/g/sub/p/-/issues/5", ("g/sub/p", "5")),
    ("https://gitlab.com/g/p/-/work_items/9", ("g/p", "9")),
    ("https://acme.atlassian.net/browse/PROJ-4", (None, "PROJ-4")),
    ("https://example.com/docs/page", None),
])
def test_parse_ref(url, want):
    assert wbs_import.parse_ref(url) == want


# --- structure ---------------------------------------------------------------
def src(records, name="origin", backend="github", repo="o/r", prefix="Issue-", keyprefix=""):
    return {"source": name, "backend": backend, "repo": repo, "prefix": prefix,
            "keyprefix": keyprefix, "records": records}


def done(id_, **kw):
    return rec(id_, state="closed", **{"class": "done"}, closed=kw.pop("closed", "2026-03-01"), **kw)


def tree_of(model):
    """{leaf: parent-leaf or None}"""
    return {n.leaf: (n.parent.leaf if n.parent else None) for n in model.nodes}


def test_native_parent_beats_body_line():
    m = wbs_import.build([src([rec("1", labels=["epic"]), rec("2", labels=["epic"]),
                               rec("3", body="Parent epic: #2", parent=GH + "1")])])
    assert tree_of(m)["Issue-3"] == "Issue-1"


def test_unresolvable_native_parent_falls_through_to_body_line():
    m = wbs_import.build([src([rec("2"), rec("3", body="Parent epic: #2", parent=GH + "99")])])
    assert tree_of(m)["Issue-3"] == "Issue-2"


def test_fork_child_resolves_origin_url():
    m = wbs_import.build([src([rec("1", labels=["epic"])]),
                          src([rec("5", body="Parent epic: " + GH + "1",
                                   url="https://github.com/me/f/issues/5")],
                              name="fork", repo="me/f", prefix="Issue-Fork-")])
    assert tree_of(m)["Issue-Fork-5"] == "Issue-1"


def test_same_source_number_stays_in_its_source():
    m = wbs_import.build([src([rec("1")]),
                          src([rec("1", url="https://github.com/me/f/issues/1"),
                               rec("5", body="Parent epic: #1", url="https://github.com/me/f/issues/5")],
                              name="fork", repo="me/f", prefix="Issue-Fork-")])
    assert tree_of(m)["Issue-Fork-5"] == "Issue-Fork-1"


def test_foreign_url_unresolved():
    m = wbs_import.build([src([rec("3", body="Parent epic: https://github.com/x/y/issues/1")])])
    assert tree_of(m)["Issue-3"] is None
    assert m.unresolved == [{"issue": "Issue-3",
                             "line": "Parent epic: https://github.com/x/y/issues/1",
                             "reason": "foreign"}]


def test_unresolved_reasons():
    m = wbs_import.build([src([rec("3", body="Parent epic: #99"),
                               rec("4", body="Parent epic: data-pipeline"),
                               rec("5", body="Parent epic: see the board"),
                               rec("6", body="Parent epic: https://example.com/x")])])
    assert [u["reason"] for u in m.unresolved] == [
        "not-found", "slug-only", "unrecognised-form", "unrecognised-form"]


def test_cycle_broken_and_reported():
    m = wbs_import.build([src([rec("1", body="Parent epic: #2"), rec("2", body="Parent epic: #1"),
                               rec("3", body="Parent epic: #3")])])
    t = tree_of(m)
    assert t["Issue-1"] == "Issue-2"          # the first edge stands
    assert t["Issue-2"] is None               # the edge that closes the cycle is dropped
    assert t["Issue-3"] is None               # a self-parent is a cycle
    assert [(u["issue"], u["reason"]) for u in m.unresolved] == [
        ("Issue-2", "cycle"), ("Issue-3", "cycle")]


def test_is_epic_type_label_title():
    assert wbs_import.is_epic(rec("1", type="Epic"))
    assert wbs_import.is_epic(rec("1", labels=["EPIC"]))
    assert wbs_import.is_epic(rec("1", title="  Epic: Search"))
    assert not wbs_import.is_epic(rec("1", title="Epics are fun", labels=["epics"], type="Task"))


def test_jira_leaf_ids_and_number_refs():
    J = "https://j.example/browse/"
    recs = [rec("PROJ-1", labels=["epic"], url=J + "PROJ-1"),
            rec("PROJ-2", body="Parent epic: #1", url=J + "PROJ-2"),
            rec("PROJ-3", body="Parent epic: PROJ-1", url=J + "PROJ-3"),
            rec("OLD-4", parent=J + "PROJ-1", url=J + "OLD-4")]
    m = wbs_import.build([src(recs, backend="jira", repo="PROJ", keyprefix="PROJ")])
    assert tree_of(m) == {"Issue-1": None, "Issue-2": "Issue-1", "Issue-3": "Issue-1",
                          "Issue-OLD-4": "Issue-1"}


# --- selection ---------------------------------------------------------------
def demo_model():
    """1 epic (closed) with closed 2 and open 3; 4 epic (closed) with closed
    5; unparented closed 6 (closed 2026-06-10) and open 7 (milestone M1)."""
    return wbs_import.build([src([
        done("1", labels=["epic"]), done("2", body="Parent epic: #1"),
        rec("3", body="Parent epic: #1"), done("4", title="Epic: Four"),
        done("5", body="Parent epic: #4"), done("6", closed="2026-06-10"),
        rec("7", milestone="M1")])])


def test_select_all():
    assert wbs_import.select(demo_model(), "all") == {f"Issue-{i}" for i in range(1, 8)}


def test_select_open_only_brings_closed_epic_and_its_closed_children():
    assert wbs_import.select(demo_model(), "open-only") == {"Issue-1", "Issue-2", "Issue-3", "Issue-7"}


def test_select_since_date():
    assert wbs_import.select(demo_model(), "since:2026-06-01") == {
        "Issue-1", "Issue-2", "Issue-3", "Issue-6", "Issue-7"}


def test_select_since_id():
    assert wbs_import.select(demo_model(), "since:5") == {
        "Issue-1", "Issue-2", "Issue-3", "Issue-4", "Issue-5", "Issue-6", "Issue-7"}
    assert wbs_import.select(demo_model(), "since:6") == {
        "Issue-1", "Issue-2", "Issue-3", "Issue-6", "Issue-7"}


def test_select_since_id_prefixed_scopes_one_source():
    m = wbs_import.build([src([done("1"), done("9")]),
                          src([done("1", url="https://github.com/me/f/issues/1"),
                               done("9", url="https://github.com/me/f/issues/9"),
                               rec("2", url="https://github.com/me/f/issues/2")],
                              name="fork", repo="me/f", prefix="Issue-Fork-")])
    assert wbs_import.select(m, "since:Issue-Fork-5") == {"Issue-Fork-9", "Issue-Fork-2"}
    assert wbs_import.select(m, "since:5") == {"Issue-9", "Issue-Fork-9", "Issue-Fork-2"}


def test_select_epic_ancestors_path_only():
    m = wbs_import.build([src([
        done("1", labels=["epic"]), done("2", labels=["epic"], body="Parent epic: #1"),
        done("3", body="Parent epic: #2"), done("4", body="Parent epic: #1")])])
    assert wbs_import.select(m, "epic:2") == {"Issue-1", "Issue-2", "Issue-3"}
    assert wbs_import.select(m, "epic:Issue-2") == {"Issue-1", "Issue-2", "Issue-3"}


def test_select_epic_rejects_a_leaf_and_lists_epics():
    with pytest.raises(wbs_import.RangeError) as e:
        wbs_import.select(demo_model(), "epic:6")
    assert "Issue-1" in str(e.value) and "Issue-4" in str(e.value)


def test_select_epic_bare_number_in_two_sources_is_ambiguous():
    m = wbs_import.build([src([done("1", labels=["epic"])]),
                          src([done("1", labels=["epic"], url="https://github.com/me/f/issues/1")],
                              name="fork", repo="me/f", prefix="Issue-Fork-")])
    with pytest.raises(wbs_import.RangeError, match="Issue-Fork-1"):
        wbs_import.select(m, "epic:1")


def test_select_bad_values():
    for rng in ("since:2026-02-30", "since:PROJ-4", "epic:99"):
        with pytest.raises(wbs_import.RangeError):
            wbs_import.select(demo_model(), rng)


# --- rendering ---------------------------------------------------------------
parser = _load("wbs_parser", REPO / "scripts" / "lib" / "wbs-parser.py")


def render(model, selected=None, preamble="# p WBS\n\n", devdoc=None, note="n"):
    sel = selected if selected is not None else wbs_import.select(model, "all")
    return wbs_import.render(model, sel, preamble, devdoc or Path("/nonexistent"), note)


def test_unparented_by_milestone_then_unparented():
    out = render(demo_model())
    assert out == (
        "# p WBS\n\n<!-- n -->\n\n"
        "- [x] t {issue: Issue-1, status_src: tracker}\n"
        "  - [x] t {issue: Issue-2, status_src: tracker}\n"
        "  - [ ] t {issue: Issue-3}\n"
        "- [x] Epic: Four {issue: Issue-4, status_src: tracker}\n"
        "  - [x] t {issue: Issue-5, status_src: tracker}\n"
        "- [ ] M1 {milestone: M1}\n"
        "  - [ ] t {issue: Issue-7}\n"
        "- [ ] Unparented\n"
        "  - [x] t {issue: Issue-6, status_src: tracker}\n")


def test_containers_only_when_non_empty():
    m = demo_model()
    out = render(m, wbs_import.select(m, "epic:1"))
    assert "Unparented" not in out and "M1" not in out


def test_render_glyphs_from_resolver(tmp_path):
    (tmp_path / "Issue-3").mkdir()
    (tmp_path / "Issue-3" / "checklist.md").write_text("- [x]  0. pull\n- [ ]  1. draft\n", encoding="utf-8")
    m = wbs_import.build([src([
        done("1"), rec("2", state="closed", **{"class": "not_planned"}, closed="2026-01-05"),
        rec("3"), rec("4"), rec("5", **{"class": "in_progress"})])])
    out = render(m, devdoc=tmp_path)
    assert "- [x] t {issue: Issue-1, status_src: tracker}\n" in out
    assert "- [-] t {issue: Issue-2, status_src: tracker}\n" in out
    assert "- [~] t {issue: Issue-3, status_src: checklist}\n" in out
    assert "- [ ] t {issue: Issue-4}\n" in out
    assert "- [~] t {issue: Issue-5, status_src: tracker}\n" in out


def test_render_depends_on_selected_only():
    m = wbs_import.build([src([
        rec("1"), rec("2"), done("3"),
        rec("4", blocked_by=[GH + "1", GH + "2", GH + "3", GH + "99"]),
        rec("5", blocked_by=[GH + "1"])])])
    out = render(m, wbs_import.select(m, "open-only"))
    assert "{issue: Issue-4, depends_on: [Issue-1, Issue-2]}" in out
    assert "{issue: Issue-5, depends_on: Issue-1}" in out
    assert wbs_import.survey(m, 20)["dropped_dependencies"] == 1   # #99 resolves to nothing


def test_safe_title_braces_newlines_leading_bullet():
    bad = "- [x] - [ Fix {braces}" + chr(13) + chr(10) + chr(9) + "and\nlines "
    assert wbs_import.safe_title(bad) == "Fix (braces) and lines"
    assert wbs_import.safe_title(" \n ") == "(no title)"
    assert wbs_import.safe_meta('M "1" [beta]') == "M '1' (beta)"
    m = wbs_import.build([src([rec("1", title=bad, milestone='M, "x": [y]')])])
    tree = parser.parse_text(render(m))
    ms, = tree["children"]
    assert ms["meta"] == {"milestone": "M, 'x': (y)"}
    leaf, = ms["children"]
    assert leaf["text"] == "Fix (braces) and lines" and leaf["meta"] == {"issue": "Issue-1"}


def test_render_preamble_is_kept_and_title_not_repeated():
    out = render(demo_model(), preamble="# p WBS\n\n> note\n\n")
    assert out.startswith("# p WBS\n\n> note\n\n<!-- n -->\n\n- [x] ")
    assert out.count("# p WBS") == 1


def test_template_preamble():
    t = "# {{PROJECT}} WBS\n\n> x\n\n- [ ] Top {est: 0w}\n  - [ ] leaf\n"
    assert wbs_import.template_preamble(t, "acme") == "# acme WBS\n\n> x\n\n"
    assert wbs_import.template_preamble("# {{PROJECT}}\n\nno nodes\n", "acme") == "# acme\n\nno nodes\n"


# --- survey ------------------------------------------------------------------
def test_survey_share_threshold_strict_below():
    m = wbs_import.build([src([done("1"), rec("2"), rec("3"), rec("4"), rec("5")])])
    assert wbs_import.survey(m, 20)["auto_import"] is False      # 20% is not below 20
    assert wbs_import.survey(m, 21)["auto_import"] is True
    assert wbs_import.survey(m, 20)["closed_share_pct"] == 20


def test_survey_counts():
    s = wbs_import.survey(demo_model(), 20, project="p")
    assert {k: s[k] for k in ("project", "total", "open", "closed", "not_planned",
                              "closed_share_pct", "auto_import", "no_parent")} == {
        "project": "p", "total": 7, "open": 2, "closed": 5, "not_planned": 0,
        "closed_share_pct": 71, "auto_import": False, "no_parent": 2}
    assert s["epics"] == [
        {"issue": "Issue-1", "title": "t", "state": "closed", "children": 2, "open_children": 1},
        {"issue": "Issue-4", "title": "Epic: Four", "state": "closed", "children": 1, "open_children": 0}]
    assert s["milestones"] == [{"title": "M1", "issues": 1}]
    assert s["options"] == {"all": 7, "open_only": 4, "epic": {"Issue-1": 3, "Issue-4": 2}}
    assert s["closed_on"]["by_month"] == {"2026-03": 4, "2026-06": 1}
    assert s["sources"] == [{"source": "origin", "backend": "github", "repo": "o/r",
                             "prefix": "Issue-", "issues": 7}]


def test_survey_empty_project():
    s = wbs_import.survey(wbs_import.build([src([])]), 20, project="p")
    assert (s["total"], s["closed_share_pct"], s["auto_import"]) == (0, 0, True)
    assert s["epics"] == [] and s["milestones"] == [] and s["unresolved_parents"] == []
    assert s["created"] == {"first": None, "last": None}
    assert s["closed_on"] == {"first": None, "last": None, "by_month": {}}
