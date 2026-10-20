"""Tests for scripts/lib/wbs-import.py (#706)."""
import ast
import difflib
import importlib.util
import inspect
import json
import re
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
    ("bad_id", rec("2}/x")),
])
def test_contract_parse_issue_list_rejects(name, bad):
    with pytest.raises(ValueError, match=r"^malformed line 2: "):
        wbs_import.parse_issue_list(lines(rec("1"), bad))


@pytest.mark.parametrize("sep", [chr(0x2028), chr(0x2029), chr(0x85)])
def test_contract_line_separators_inside_a_string_stay_in_the_record(sep):
    # jq writes U+2028, U+2029 and NEL raw inside a JSON string; only LF ends a record
    text = json.dumps(rec("1", body="a" + sep + "b"), ensure_ascii=False) + "\r\n"
    assert [r["body"] for r in wbs_import.parse_issue_list(text)] == ["a" + sep + "b"]


def test_contract_error_names_the_issue():
    with pytest.raises(ValueError, match=r"^malformed line 1: bad date in closed \(issue 7\)$"):
        wbs_import.parse_issue_list(lines(rec("7", state="closed", **{"class": "done"}, closed="")))


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
    # forms from real issue bodies (#706 review)
    ("Parent epic: #238. Tracker: this fork, `o/r`.", ("num", "238")),
    ("**Parent epic:** o/r#85. Child 6 of 6.", ("ref", "o/r#85")),
    ("**Parent epic:** [#68 " + chr(0x2014) + " Stage 1 work](" + GH + "68).", ("url", GH + "68")),
    ("Parent epic: #83 " + chr(0x2014) + " Tuning", ("num", "83")),
    ("Parent epic: " + GH + "3.", ("url", GH + "3")),
    ("**Parent epic**: #3", ("num", "3")),
    ("Parent epic: Data pipeline " + chr(0x2014) + " " + GH + "3", ("url", GH + "3")),
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


def test_parent_line_skips_a_body_without_the_key_fast():
    # wbs-parser's fence pairing is quadratic in unclosed openers; a body that
    # cannot hold the key is never classified
    import time
    t = time.monotonic()
    assert wbs_import.parent_line("```x\n" * 4000) is None
    assert time.monotonic() - t < 1.0


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


def test_owner_repo_number_resolves():
    m = wbs_import.build([src([rec("1", labels=["epic"])]),
                          src([rec("5", body="**Parent epic:** o/r#1. Child 1 of 1.",
                                   url="https://github.com/me/f/issues/5")],
                              name="fork", repo="me/f", prefix="Issue-Fork-")])
    assert tree_of(m)["Issue-Fork-5"] == "Issue-1"


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


def test_unresolved_entries_do_not_leak_a_prior_parent_line():
    # Issue-2 resolves first, so a parent line from it is live when the roots are visited.
    m = wbs_import.build([src([rec("1"), rec("2", body="Parent epic: #1"),
                               rec("3", parent=GH + "99"),
                               rec("4"),
                               rec("5", parent=GH + "98", body="Parent epic: #97")])])
    assert tree_of(m) == {"Issue-1": None, "Issue-2": "Issue-1", "Issue-3": None,
                          "Issue-4": None, "Issue-5": None}
    assert m.unresolved == [
        {"issue": "Issue-3", "line": "parent: " + GH + "99", "reason": "not-found"},
        {"issue": "Issue-5", "line": "parent: " + GH + "98", "reason": "not-found"},
        {"issue": "Issue-5", "line": "Parent epic: #97", "reason": "not-found"}]


def test_cycle_entry_carries_the_resolving_parent_line():
    m = wbs_import.build([src([rec("1", parent=GH + "2"), rec("2", body="Parent epic: #1"),
                               rec("3", body="Parent epic: #4"), rec("4", parent=GH + "3")])])
    assert m.unresolved == [
        {"issue": "Issue-2", "line": "Parent epic: #1", "reason": "cycle"},
        {"issue": "Issue-4", "line": "parent: " + GH + "3", "reason": "cycle"}]


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


# (backend, dir_prefix, keyprefix, record id, leaf): the leaf a writer gives a
# record (#792 moves this rule into wbs-tracker.py's leaf_for; these rows pin it)
LEAF_RULE = [
    ("jira", "Issue-", "PROJ", "PROJ-12", "Issue-12"),
    ("jira", "Issue-", "PROJ", "OLD-4", "Issue-OLD-4"),
    ("jira", "Issue-", "PROJ", "FOO-1", "Issue-FOO-1"),
    ("jira", "Issue-", "PROJ", "PX-5", "Issue-PX-5"),
    ("jira", "Issue-P", "PK", "X-5", "Issue-PX-5"),
    ("github", "Issue-F", "", "7", "Issue-F7"),
    ("gitlab", "Issue-", "", "3", "Issue-3"),
    ("custom", "Issue-", "", "abc", "Issue-abc"),
    ("custom", "Issue-", "", "T-3", "Issue-T-3"),
    ("custom", "Issue-", "", "F1", "Issue-F1"),
]


@pytest.mark.parametrize("backend, prefix, kp, rid, leaf", LEAF_RULE)
def test_node_leaf_rule_characterized(backend, prefix, kp, rid, leaf):
    m = wbs_import.build([src([rec(rid)], backend=backend, repo=kp or "o/r",
                              prefix=prefix, keyprefix=kp)])
    assert m.nodes[0].leaf == leaf


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


def jira_epic_model():
    """One Jira source (keyprefix PROJ): epic PROJ-1 with child PROJ-2."""
    return wbs_import.build([src([rec("PROJ-1", labels=["epic"], url=J + "PROJ-1"),
                                  rec("PROJ-2", parent=J + "PROJ-1", url=J + "PROJ-2")],
                                 backend="jira", repo="PROJ", keyprefix="PROJ")])


@pytest.mark.parametrize("which, rng, want", [
    ("demo", "all", "all"),
    ("demo", "open-only", "open-only"),
    ("demo", "since:2026-03-01", "since:2026-03-01"),
    ("demo", "epic:1", "epic:Issue-1"),
    ("demo", "epic:Issue-1", "epic:Issue-1"),
    ("demo", "since:40", "since:40"),
    ("demo", "since:Issue-40", "since:Issue-40"),
    ("jira", "epic:PROJ-1", "epic:Issue-1"),
    ("jira", "epic:1", "epic:Issue-1"),
    ("jira", "all", "all"),
])
def test_scope_value_forms_round_trip(which, rng, want):
    # #797: the seed's scope line reads back, through select, as the range it wrote
    m = demo_model() if which == "demo" else jira_epic_model()
    assert wbs_import.scope_value(m, rng) == want
    assert wbs_import.select(m, wbs_import.scope_value(m, rng)) == wbs_import.select(m, rng)


def test_render_writes_the_scope_line_after_the_note():
    m = demo_model()
    sel = wbs_import.select(m, "all")
    plain = wbs_import.render(m, sel, "# p WBS\n\n", Path("/nonexistent"), "n")
    scoped = wbs_import.render(m, sel, "# p WBS\n\n", Path("/nonexistent"), "n", scope="all")
    assert "<!-- n -->\n<!-- wbs-scope: all -->\n\n" in scoped
    assert scoped == plain.replace("<!-- n -->\n", "<!-- n -->\n<!-- wbs-scope: all -->\n")
    assert wbs_import.render(m, sel, "# p WBS\n\n", Path("/nonexistent"), "n",
                             scope=None) == plain == render(m)


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


@pytest.mark.parametrize(
    "raw,want",
    [
        ("- [x]", "(no title)"),
        ("- [x]foo", "foo"),
        ("- [ ]", "(no title)"),
        ("- [x]- [y]z", "z"),
        ("- [ab] x", "ab] x"),
    ],
    ids=["x-bare", "x-glued", "space-bare", "x-chain", "two-char"],
)
def test_safe_title_strips_a_checkbox_with_no_space_after(raw, want):
    assert wbs_import.safe_title(raw) == want


@pytest.mark.parametrize(
    "title,want",
    [
        ("'v1'", "'v1'"),
        ('"v1"', "'v1'"),
        ("'beta", "'beta"),
        ("v1'", "v1'"),
        ("'v1' beta", "'v1' beta"),
    ],
    ids=["sq-wrapped", "dq-wrapped", "sq-led", "sq-trailing", "sq-spaced"],
)
def test_quote_led_milestone_container_parses_to_its_safe_meta(title, want):
    # #789: a container written for a quote-led milestone reads back as safe_meta
    m = wbs_import.build([src([rec("1", milestone=title)])])
    ms, = parser.parse_text(render(m))["children"]
    assert ms["meta"] == {"milestone": want}
    assert want == wbs_import.safe_meta(title)


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


# --- merge into an existing WBS (#707) -----------------------------------------
MERGE_FIX = REPO / "tests" / "fixtures" / "wbs-merge"
wbs_bytes = _load("wbs_bytes", REPO / "tests" / "helpers" / "wbs_bytes.py")
J = "https://j.example/browse/"


def merged(base, model, rng="all", excluded=None):
    """(rendered text, stats) of a merge over parse_text(base); the exclusion
    ids come from the base's own exclusion lines unless given."""
    tree = parser.parse_text(base)
    if excluded is None:
        excluded = [i for _ln, i in wbs_import.exclusions(tree, model)[0]]
    stats = wbs_import.merge(model, wbs_import.select(model, rng), tree,
                             Path("/nonexistent"), excluded)
    return parser.render_markdown(tree), stats


def test_merge_resolves_wbs_ids_like_ranges():
    m = wbs_import.build([src([rec("3"), rec("7")]),
                          src([rec("3", url="https://github.com/me/f/issues/3")],
                              name="fork", repo="me/f", prefix="Issue-Fork-")])

    def leaves(iid):
        return [n.leaf for n in wbs_import.resolve_id(m, iid)]
    assert leaves("Issue-3") == ["Issue-3"]
    assert leaves("Issue-Fork-3") == ["Issue-Fork-3"]
    # leaf_lookup's rule: a dir_prefix is required (the range flags keep bare N)
    for none in ("TODO", "Issue-x", "Issue-", "Issue-Fork-", "7", "Issue-99"):
        assert leaves(none) == [], none
    jm = wbs_import.build([src([rec("PK-12", url=J + "PK-12")],
                               backend="jira", repo="PK", keyprefix="PK")])
    assert [n.rec["id"] for n in wbs_import.resolve_id(jm, "Issue-12")] == ["PK-12"]
    assert [n.rec["id"] for n in wbs_import.resolve_id(jm, "Issue-PK-12")] == ["PK-12"]
    assert wbs_import.resolve_id(jm, "PK-12") == []
    assert wbs_import.resolve_id(jm, "12") == []


def test_exclusions_parse_one_line_union():
    m = wbs_import.build([src([rec(str(i)) for i in range(1, 14)])])
    text = ("<!-- wbs-exclude: Issue-1, Issue-2 -->\n"          # 1
            "  <!-- wbs-exclude: Issue-5 Issue-6,Issue-7 -->\n"  # 2 indented, mixed separators
            "```\n<!-- wbs-exclude: Issue-9 -->\n```\n"          # 3-5 fenced: not read
            "<!-- wbs-exclude: #4, Issue-8 -->\n"                # 6 a bad token
            "<!-- wbs-exclude: Issue-3\n-->\n"                   # 7-8 two lines
            "<!-- wbs-exclude Issue-5 -->\n"                     # 9 no colon
            "<!-- WBS-Exclude: Issue-5 -->\n"                    # 10 wrong case
            "Prose names the wbs-exclude: Issue-11 convention.\n"  # 11 silent
            "<!-- wbs-exclude: 12 -->\n"                         # 12 a bare id
            "<!-- wbs-exclude: Issue-5. Issue-x Issue-99 -->\n")  # 13 bad shapes; 99 well formed
    ids, warns = wbs_import.exclusions(parser.parse_text(text), m)
    assert ids == [(1, "Issue-1"), (1, "Issue-2"), (2, "Issue-5"), (2, "Issue-6"),
                   (2, "Issue-7"), (6, "Issue-8"), (13, "Issue-99")]
    near = "not an exclusion line (want '<!-- wbs-exclude: <id>, ... -->' on one line); ignored"
    assert warns == [
        "line 6: '#4' is not an issue id; ignored",
        f"line 7: {near}",
        f"line 9: {near}",
        f"line 10: {near}",
        "line 12: '12' is not an issue id; ignored",
        "line 13: 'Issue-5.' is not an issue id; ignored",
        "line 13: 'Issue-x' is not an issue id; ignored",
    ]
    # merge's composed output: today's text with `W.md line` now `W.md: line`
    assert [f"wbs init --merge: W.md: {w}" for w in warns] == [
        "wbs init --merge: W.md: line 6: '#4' is not an issue id; ignored",
        f"wbs init --merge: W.md: line 7: {near}",
        f"wbs init --merge: W.md: line 9: {near}",
        f"wbs init --merge: W.md: line 10: {near}",
        "wbs init --merge: W.md: line 12: '12' is not an issue id; ignored",
        "wbs init --merge: W.md: line 13: 'Issue-5.' is not an issue id; ignored",
        "wbs init --merge: W.md: line 13: 'Issue-x' is not an issue id; ignored",
    ]
    hit = {n.leaf for _ln, i in ids for n in wbs_import.resolve_id(m, i)}
    assert hit == {"Issue-1", "Issue-2", "Issue-5", "Issue-6", "Issue-7", "Issue-8"}
    # Issue-1 names neither Issue-10 nor Issue-13 (a control sharing the token)
    assert "Issue-10" not in hit and "Issue-13" not in hit


def test_merge_parent_present_appends_last_child():
    base = "# W\n\n- [ ] Epic {issue: Issue-1}\n  - [ ] Two {issue: Issue-2}\n\nTail.\n"
    m = wbs_import.build([src([rec("1", labels=["epic"]), rec("2", parent=GH + "1"),
                               rec("3", title="Three", parent=GH + "1")])])
    out, stats = merged(base, m)
    assert out == base.replace("Issue-2}\n", "Issue-2}\n  - [ ] Three {issue: Issue-3}\n")
    assert stats == {"added": ["Issue-3"], "under_existing": 1, "new_tops": 0,
                     "present": 2, "excluded": 0, "warnings": []}


def test_merge_new_epic_nests_new_children_only():
    base = "- [ ] Misc\n  - [ ] Seven {issue: Issue-7}\n"
    m = wbs_import.build([src([rec("5", title="Epic: Beta", labels=["epic"]),
                               done("6", title="Six", parent=GH + "5"),
                               rec("7", title="Seven", parent=GH + "5")])])
    out, stats = merged(base, m)
    assert out == base + ("- [ ] Epic: Beta {issue: Issue-5}\n"
                          "  - [x] Six {issue: Issue-6, status_src: tracker}\n")
    assert (stats["under_existing"], stats["new_tops"]) == (0, 2)


def test_merge_milestone_existing_container_then_new():
    # a node with milestone AND issue meta is not a container
    base = ("- [ ] Release {issue: Issue-1, milestone: M1}\n"
            "- [ ] Milestone one {milestone: M1}\n  - [ ] Plan\n")
    m = wbs_import.build([src([rec("1", title="Release"),
                               rec("8", title="Eight", milestone="M1"),
                               rec("9", title="Nine", milestone="M2")])])
    out, stats = merged(base, m)
    assert out == base + ("  - [ ] Eight {issue: Issue-8}\n"
                          "- [ ] M2 {milestone: M2}\n  - [ ] Nine {issue: Issue-9}\n")
    assert (stats["under_existing"], stats["new_tops"]) == (1, 1)


def test_merge_milestone_tie_first_in_document_order():
    # the first container wins, at any depth
    base = ("- [ ] Top\n  - [ ] A {milestone: M1}\n    - [ ] a\n"
            "- [ ] B {milestone: M1}\n  - [ ] b\n")
    m = wbs_import.build([src([rec("8", title="Eight", milestone="M1"),
                               rec("9", title="Nine", milestone="M1")])])
    out, stats = merged(base, m)
    assert out == base.replace("    - [ ] a\n", "    - [ ] a\n    - [ ] Eight {issue: Issue-8}\n"
                                                "    - [ ] Nine {issue: Issue-9}\n")
    # the tie is named once per milestone; one candidate is silent
    assert stats["warnings"] == [
        "milestone 'M1' has 2 candidate nodes (lines 2, 4); its issues go under the first"]
    assert merged("- [ ] A {milestone: M1}\n", m)[1]["warnings"] == []


@pytest.mark.parametrize("title", ["'v1'", '"v1"', "'beta"],
                         ids=["sq-wrapped", "dq-wrapped", "sq-led"])
def test_merge_quoted_milestone_reuses_its_container(title):
    # #789: the second merge finds the container the first one wrote
    base = "# p WBS\n\n- [ ] Root\n"
    first, s1 = merged(base, wbs_import.build([src([rec("1", title="One", milestone=title)])]))
    assert s1["new_tops"] == 1
    m2 = wbs_import.build([src([rec("1", title="One", milestone=title),
                                rec("2", title="Two", milestone=title)])])
    out, s2 = merged(first, m2)
    assert (s2["under_existing"], s2["new_tops"]) == (1, 0)
    assert out == first + "  - [ ] Two {issue: Issue-2}\n"


def test_merge_unparented_reused_or_created():
    m = wbs_import.build([src([rec("1"), rec("2"), rec("3", title="Three")])])
    three = "  - [ ] Three {issue: Issue-3}\n"
    # an existing top-level Unparented wins over an earlier Unassigned
    base = ("- [ ] Unassigned\n  - [ ] One {issue: Issue-1}\n"
            "- [ ] Unparented\n  - [ ] Two {issue: Issue-2}\n")
    assert merged(base, m)[0] == base + three
    # else a top-level Unassigned (wbs update's bucket)
    base = "- [ ] Unassigned\n  - [ ] One {issue: Issue-1}\n  - [ ] Two {issue: Issue-2}\n"
    assert merged(base, m)[0] == base + three
    # else a new Unparented: a nested bucket, or one with an issue, is not reused
    base = ("- [ ] Unparented {issue: Issue-1}\n"
            "- [ ] Group\n  - [ ] Unparented\n  - [ ] Unassigned\n  - [ ] Two {issue: Issue-2}\n")
    out, stats = merged(base, m)
    assert out == base + "- [ ] Unparented\n" + three
    assert (stats["under_existing"], stats["new_tops"]) == (0, 1)


def test_merge_new_tops_order():
    base = "- [ ] Hand {issue: Issue-1}\n\nTail.\n"
    m = wbs_import.build([src([rec("1"), rec("2", title="Loose"),
                               rec("3", title="Bee", milestone="beta"),
                               rec("4", title="Ay", milestone="Alpha"),
                               rec("5", title="Epic: E", labels=["epic"])])])
    out, stats = merged(base, m)
    assert out == ("- [ ] Hand {issue: Issue-1}\n"
                   "- [ ] Epic: E {issue: Issue-5}\n"
                   "- [ ] Alpha {milestone: Alpha}\n  - [ ] Ay {issue: Issue-4}\n"
                   "- [ ] beta {milestone: beta}\n  - [ ] Bee {issue: Issue-3}\n"
                   "- [ ] Unparented\n  - [ ] Loose {issue: Issue-2}\n"
                   "\nTail.\n")
    assert stats["new_tops"] == 4


def test_merge_excluded_parent_children_fall_through():
    base = "<!-- wbs-exclude: Issue-5 -->\n- [ ] Hand {issue: Issue-1}\n"
    m = wbs_import.build([src([rec("1"), rec("5", title="Epic: Beta", labels=["epic"]),
                               rec("6", title="Six", parent=GH + "5"),
                               rec("7", title="Seven", milestone="M1", parent=GH + "5")])])
    out, stats = merged(base, m)
    assert out == base + ("- [ ] M1 {milestone: M1}\n  - [ ] Seven {issue: Issue-7}\n"
                          "- [ ] Unparented\n  - [ ] Six {issue: Issue-6}\n")
    assert (stats["added"], stats["excluded"]) == (["Issue-6", "Issue-7"], 1)


def test_merge_depends_on_includes_present():
    base = "- [ ] Twelve {issue: Issue-PK-12}\n"
    m = wbs_import.build([src([rec("PK-12", url=J + "PK-12"),
                               rec("PK-13", title="Thirteen", url=J + "PK-13",
                                   blocked_by=[J + "PK-12"]),
                               rec("PK-14", title="Fourteen", url=J + "PK-14",
                                   blocked_by=[J + "PK-13"])],
                              backend="jira", repo="PK", keyprefix="PK")])
    out, _stats = merged(base, m)
    # a present blocker keeps its own spelling; a new one is the leaf form
    assert out == base + ("- [ ] Unparented\n"
                          "  - [ ] Thirteen {issue: Issue-13, depends_on: Issue-PK-12}\n"
                          "  - [ ] Fourteen {issue: Issue-14, depends_on: Issue-13}\n")


def test_merge_depth_follows_last_sibling():
    base = "- [ ] Epic {issue: Issue-1}\n    - [ ] Two {issue: Issue-2}\n"
    m = wbs_import.build([src([rec("1", labels=["epic"]), rec("2", parent=GH + "1"),
                               rec("3", title="Three", parent=GH + "1"),
                               rec("4", title="Four", parent=GH + "3")])])
    out, _stats = merged(base, m)
    assert out == base + ("    - [ ] Three {issue: Issue-3}\n"
                          "      - [ ] Four {issue: Issue-4}\n")
    epic, = parser.parse_text(out)["children"]
    assert [c["meta"]["issue"] for c in epic["children"]] == ["Issue-2", "Issue-3"]
    assert [c["meta"]["issue"] for c in epic["children"][1]["children"]] == ["Issue-4"]


def _fixture_model():
    text = (MERGE_FIX / "issue-list.jsonl").read_text(encoding="utf-8")
    return wbs_import.build([src(wbs_import.parse_issue_list(text), repo="acme/testproj")])


def test_merge_present_and_excluded_counts():
    base = (MERGE_FIX / "base.md").read_text(encoding="utf-8")
    _out, stats = merged(base, _fixture_model())
    assert stats == {"added": [f"Issue-{i}" for i in (4, 5, 6, 8, 9, 10, 13, 14, 15, 16)],
                     "under_existing": 3, "new_tops": 7, "present": 5, "excluded": 1,
                     "warnings": []}
    # P and K count the selection only
    _out, stats = merged(base, _fixture_model(), rng="epic:5")
    assert stats == {"added": ["Issue-5", "Issue-6"], "under_existing": 0, "new_tops": 2,
                     "present": 1, "excluded": 0, "warnings": []}


def test_merge_after_unterminated_last_line():
    m = wbs_import.build([src([rec("1"), rec("2", title="Two")])])
    for eol in ("\n", "\r\n"):
        base = f"# W{eol}{eol}- [ ] Hand {{issue: Issue-1}}"
        out, _stats = merged(base, m)
        assert out == (f"# W{eol}{eol}- [ ] Hand {{issue: Issue-1}}{eol}"
                       f"- [ ] Unparented{eol}  - [ ] Two {{issue: Issue-2}}")
        assert parser.inserted_only(base, out)


def test_merge_existing_lines_untouched(tmp_path):
    # preserve.md: 1, 2, 3 present; 4 under Leaf A (after its note), 7 under
    # the M1 container Epic one, 10 under Leaf D, 5 in a new Unparented
    m = wbs_import.build([src([rec("1"), rec("2"), rec("3"),
                               rec("4", parent=GH + "1"), rec("5"),
                               rec("7", milestone="M1"), rec("10", parent=GH + "3")])])
    for kind in wbs_bytes.KINDS:
        dst = tmp_path / f"{kind}.md"
        assert wbs_bytes.variant(str(REPO / "tests" / "fixtures" / "wbs" / "preserve.md"),
                                 kind, str(dst)) == 0
        with open(dst, encoding="utf-8", newline="") as f:
            base = f.read()
        out, stats = merged(base, m)
        assert len(stats["added"]) == 4
        old, new = base.splitlines(keepends=True), out.splitlines(keepends=True)
        ops = difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes()
        assert {op for op, *_ in ops} == {"equal", "insert"}, kind
        assert sum(j2 - j1 for op, _i1, _i2, j1, j2 in ops if op == "insert") == 5, kind


# --- the unflagged merge's default set (#797) ---------------------------------------
def _wbs(*leaves):
    return parser.parse_text("".join(f"- [ ] H {{issue: {leaf}}}\n" for leaf in leaves))


def default_set(model, tree, rng="all", excluded=()):
    return wbs_import.default_set(model, tree, wbs_import.select(model, rng), list(excluded))


def fork_src(records):
    return src([dict(r, url=f"https://github.com/me/f/issues/{r['id']}") for r in records],
               name="fork", repo="me/f", prefix="Issue-Fork-")


def test_default_set_jira_marks_by_project():
    def model(*ids):
        return wbs_import.build([src([rec(i, url=J + i) for i in ids], backend="jira",
                                     repo="PROJ", keyprefix="PROJ")])
    m = model("PROJ-40", "PROJ-41", "PROJ-12")
    ds = default_set(m, _wbs("Issue-40"))
    assert ds["add"] == {"Issue-41"}
    assert ds["older_absent"] == 1
    assert ds["new_since_newest"] == 1
    assert ds["newest_present"] == {"origin": "Issue-40", "fork": None}
    # a foreign-project key neither sets a mark nor is above one (#765's rule)
    m = model("PROJ-40", "PROJ-41", "PROJ-12", "OLD-50")
    ds = default_set(m, _wbs("Issue-40"))
    assert ds["add"] == {"Issue-41"}
    assert ds["older_absent"] == 2


def test_default_set_mark_is_per_source():
    m = wbs_import.build([src([rec("3"), rec("5"), rec("10"), rec("11")]),
                          fork_src([rec("2"), rec("4"), rec("7")])])
    ds = default_set(m, _wbs("Issue-10", "Issue-Fork-4"))
    # one shared mark (10) would drop Issue-Fork-7
    assert ds["add"] == {"Issue-11", "Issue-Fork-7"}
    assert ds["older_absent"] == 3
    assert ds["newest_present"] == {"origin": "Issue-10", "fork": "Issue-Fork-4"}
    assert ds["unmarked"] == []


def test_default_set_excluded_split_both_sides_of_the_mark():
    m = wbs_import.build([src([rec(str(i)) for i in range(1, 7)])])
    ds = default_set(m, _wbs("Issue-3"), excluded=["Issue-2", "Issue-5"])
    assert ds["excluded"] == 2
    assert ds["older_absent"] == 1
    assert ds["new_since_newest"] == 2
    assert ds["add"] == {"Issue-4", "Issue-6"}
    assert ds["present"] == 1
    assert ds["excluded"] + ds["older_absent"] + ds["new_since_newest"] == 5


def test_default_set_source_with_no_present_issue():
    m = wbs_import.build([src([rec("1"), rec("2")]),
                          fork_src([rec("1"), rec("2"), rec("3")])])
    ds = default_set(m, _wbs("Issue-1"))
    assert ds["unmarked"] == ["fork"]
    assert ds["older_absent"] == 3
    assert ds["add"] == {"Issue-2"}
    assert ds["newest_present"] == {"origin": "Issue-1", "fork": None}


def test_default_set_scope_limits_every_count():
    m = wbs_import.build([src([rec("1", labels=["epic"]), rec("2", parent=GH + "1"),
                               rec("3", parent=GH + "1"), rec("9")])])
    ds = default_set(m, _wbs("Issue-2"), rng="epic:1")
    # Issue-9 is absent and above the mark, but outside the scope: in no count
    assert ds["add"] == {"Issue-3"}
    assert (ds["present"], ds["excluded"], ds["older_absent"], ds["new_since_newest"]) == (1, 0, 1, 1)


def test_default_set_notice_only_for_a_source_with_nothing_present():
    # a present issue with no number to compare gives no mark, but the
    # source is not "no issue is in WBS.md": no notice, its absent count older
    m = wbs_import.build([src([rec(i, url=J + i) for i in ("OLD-5", "PROJ-1", "PROJ-2")],
                              backend="jira", repo="PROJ", keyprefix="PROJ")])
    ds = default_set(m, _wbs("Issue-OLD-5"))
    assert (ds["present"], ds["unmarked"], ds["older_absent"], ds["add"]) == (1, [], 2, set())
    m = wbs_import.build([src([rec("abc"), rec("def")], backend="custom")])
    ds = default_set(m, _wbs("Issue-abc"))
    assert (ds["present"], ds["unmarked"], ds["older_absent"], ds["add"]) == (1, [], 1, set())


def _ac10():
    m = wbs_import.build([src([rec(str(i)) for i in range(1, 7)])])
    return m, ["Issue-2", "Issue-5"]


def test_merge_only_restricts_adds_not_counts():
    m, excl = _ac10()
    sel = wbs_import.select(m, "all")
    full = wbs_import.merge(m, sel, _wbs("Issue-3"), Path("/nonexistent"), excl)
    only = wbs_import.merge(m, sel, _wbs("Issue-3"), Path("/nonexistent"), excl,
                            only={"Issue-4"})
    assert only["added"] == ["Issue-4"]
    assert (only["present"], only["excluded"]) == (full["present"], full["excluded"])


def test_default_set_counts_agree_with_merge():
    m, excl = _ac10()
    ds = default_set(m, _wbs("Issue-3"), excluded=excl)
    stats = wbs_import.merge(m, wbs_import.select(m, "all"), _wbs("Issue-3"),
                             Path("/nonexistent"), excl, only=ds["add"])
    assert ds["present"] == stats["present"]
    assert ds["excluded"] == stats["excluded"]
    assert set(stats["added"]) == ds["add"]


def test_default_set_unnumbered_other_backend():
    m = wbs_import.build([src([rec("T-12"), rec("T-13")], backend="custom")])
    ds = default_set(m, _wbs("Issue-T-12"))
    assert ds["add"] == {"Issue-T-13"}
    assert ds["unmarked"] == []


def _merge_env(tmp_path, records, data, rng=""):
    """A `wbs init --merge` run env over one GitHub source; dest holds data."""
    dest = tmp_path / "WBS.md"
    dest.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)
    env = {"WBS_IMP_ORIGIN_FILE": _jsonl(tmp_path / "o.jsonl", records),
           "WBS_IMP_ORIGIN_BACKEND": "github", "WBS_IMP_ORIGIN_REPO": "o/r",
           "WBS_IMP_ORIGIN_PREFIX": "Issue-", "WBS_IMP_MODE": "merge",
           "WBS_IMP_RANGE": rng, "WBS_IMP_PROJECT": "p", "WBS_IMP_DEST": str(dest),
           "DEVDOC_DIR": str(tmp_path)}
    return env, dest


HAND = "- [ ] Hand {issue: Issue-1}\n"
SCOPE_TWICE = "# W\n\n<!-- wbs-scope: all -->\n" + HAND + "<!-- wbs-scope: all -->\n"
SCOPE_999 = "# W\n\n<!-- wbs-scope: epic:Issue-999 -->\n" + HAND
FIX_IT = "fix it, or pass a range flag; nothing written"


def test_unflagged_merge_scope_line_errors(tmp_path, capsys):
    recs = [rec(str(i)) for i in range(1, 4)]
    m = wbs_import.build([src(recs)])
    cases = [
        (SCOPE_TWICE, "wbs-scope is on lines 3, 5; keep one line, or pass a range flag; "
                      "nothing written"),
        ("# W\n\n<!-- WBS-Scope: all -->\n" + HAND,
         "line 3: not a scope line (want '<!-- wbs-scope: <range> -->' on one line); " + FIX_IT),
    ]
    for value in ("epic:Issue-999", ""):
        with pytest.raises(wbs_import.RangeError) as e:
            wbs_import.select(m, value)
        cases.append((f"# W\n\n<!-- wbs-scope: {value} -->\n" + HAND,
                      f"line 3: wbs-scope '{value}' names nothing ({e.value}); " + FIX_IT))
    for text, msg in cases:
        env, dest = _merge_env(tmp_path, recs, text)
        before = dest.read_bytes()
        assert wbs_import.run(env) == 2, text
        assert capsys.readouterr().err == f"wbs init --merge: {dest}: {msg}\n"
        assert dest.read_bytes() == before
    # (e) a comment that only mentions the key is no second scope line
    env, dest = _merge_env(tmp_path, recs, "# W\n\n<!-- the wbs-scope line below was "
                           "written by wbs init -->\n<!-- wbs-scope: all -->\n" + HAND)
    assert wbs_import.run(env) == 0
    # (d) the parse comes first: an unreadable WBS.md exits 1 before any survey
    env, dest = _merge_env(tmp_path, [done(str(i)) for i in range(1, 61)], b"# W\n\xff\n")
    assert wbs_import.run(env) == 1
    out = capsys.readouterr()
    assert "WBS-INIT:" not in out.out
    assert f"cannot read {dest}" in out.err


def test_flagged_merge_never_reads_the_scope_line(tmp_path, capsys):
    recs = [rec(str(i)) for i in range(1, 4)]
    for text in (SCOPE_TWICE, SCOPE_999):
        env, dest = _merge_env(tmp_path, recs, text, rng="all")
        assert wbs_import.run(env) == 0
        got = dest.read_text(encoding="utf-8")
        assert parser.inserted_only(text, got)
        assert "{issue: Issue-2}" in got and "{issue: Issue-3}" in got
        assert [ln for ln in got.splitlines() if "wbs-scope" in ln] == \
            [ln for ln in text.splitlines() if "wbs-scope" in ln]
        capsys.readouterr()


CAP_LINE = ("wbs init --merge: {n} issues are newer than the newest in {dest} (cap 50); "
            "pass --all, --since <date|issue-id>, --open-only or --epic <issue-id>")


def test_unflagged_merge_cap_boundary(tmp_path, capsys):
    assert wbs_import.MERGE_CAP == 50
    env, dest = _merge_env(tmp_path, [rec(str(i)) for i in range(1, 52)], "# W\n\n" + HAND)
    assert wbs_import.run(env) == 0
    assert "added 50 issues" in capsys.readouterr().err
    (tmp_path / "b").mkdir()
    env, dest = _merge_env(tmp_path / "b", [rec(str(i)) for i in range(1, 53)], "# W\n\n" + HAND)
    before = dest.read_bytes()
    assert wbs_import.run(env) == wbs_import.CHOOSE_RANGE_RC
    out = capsys.readouterr()
    assert out.out.splitlines()[-1] == wbs_import.CHOOSE_RANGE_MARKER
    sv = json.loads(out.out[:out.out.rindex(wbs_import.CHOOSE_RANGE_MARKER)])
    assert sv["merge"]["new_since_newest"] == 51
    assert sv["merge"]["older_absent"] == 0
    assert sv["merge"]["scope"] is None
    assert out.err == CAP_LINE.format(n=51, dest=dest) + "\n"
    assert dest.read_bytes() == before


def test_unflagged_merge_tail_counts_older(tmp_path, capsys):
    env, dest = _merge_env(tmp_path, [rec(str(i)) for i in range(1, 6)],
                           "# W\n\n- [ ] A {issue: Issue-3}\n- [ ] B {issue: Issue-5}\n")
    assert wbs_import.run(env) == 0
    assert capsys.readouterr().err == (
        f"wbs init --merge: nothing to add to {dest}; 2 already present, 0 excluded; "
        "3 older issues not added (pass --since <id> or --all)\n")


def test_unflagged_merge_prints_each_exclusion_warning_once(tmp_path, capsys):
    env, dest = _merge_env(tmp_path, [rec(str(i)) for i in range(1, 6)],
                           "# W\n\n<!-- WBS-Exclude: Issue-5 -->\n" + HAND)
    assert wbs_import.run(env) == 0
    assert capsys.readouterr().err.count("line 3: not an exclusion line") == 1


def _run_merge(dest):
    m = _fixture_model()
    return wbs_import._run_merge(m, wbs_import.select(m, "all"), dest, dest.parent)


def test_run_merge_refusal_writes_nothing(tmp_path, monkeypatch, capsys):
    data = (MERGE_FIX / "base.md").read_bytes()
    dest = tmp_path / "WBS.md"
    dest.write_bytes(data)
    monkeypatch.setattr(wbs_import._wbs_parser(), "inserted_only", lambda old, new: False)
    rc = _run_merge(dest)
    assert rc == 1
    assert "refusing to write" in capsys.readouterr().err
    assert dest.read_bytes() == data


def test_run_merge_unreadable_dest(tmp_path, capsys):
    dest = tmp_path / "WBS.md"
    dest.write_bytes(b"# W\n\xff\n")
    rc = _run_merge(dest)
    assert rc == 1
    assert f"cannot read {dest}" in capsys.readouterr().err


def test_run_merge_write_failure(tmp_path, monkeypatch, capsys):
    data = (MERGE_FIX / "base.md").read_bytes()

    def deny(self, _data):
        raise PermissionError(13, "Permission denied")

    dest = tmp_path / "WBS.md"
    dest.write_bytes(data)
    monkeypatch.setattr(Path, "write_bytes", deny)
    rc = _run_merge(dest)
    assert rc == 1
    assert f"cannot write {dest}" in capsys.readouterr().err
    assert dest.read_bytes() == data


# --- the shared leaf <-> issue-id codec (#792) ---------------------------------
trk = wbs_import.trk


def _named(node):
    return (node.source["source"], node.rec["id"])


def worked_model():
    """The issue's worked example: a Jira origin `Issue-` (key prefix PROJ)
    with FOO-1 and PROJ-12, and a GitHub fork `Issue-F` with 7."""
    return wbs_import.build([
        src([rec("FOO-1", url=J + "FOO-1"), rec("PROJ-12", url=J + "PROJ-12")],
            backend="jira", repo="PROJ", keyprefix="PROJ"),
        src([rec("7", url="https://github.com/me/f/issues/7")],
            name="fork", repo="me/f", prefix="Issue-F")])


@pytest.mark.parametrize("iid, want", [
    ("Issue-FOO-1", ("origin", "FOO-1")),
    ("Issue-F7", ("fork", "7")),
    ("Issue-12", ("origin", "PROJ-12")),
    ("Issue-PROJ-12", ("origin", "PROJ-12")),
])
def test_resolve_id_agrees_with_parse_leaf_worked_example(iid, want):
    m = worked_model()
    got = trk.parse_leaf(m.sources, iid)
    assert (got[0]["source"], got[1]) == want
    assert [_named(n) for n in wbs_import.resolve_id(m, iid)] == [want]


def custom_model(ids=("abc", "T-3")):
    return wbs_import.build([src([rec(i) for i in ids], backend="custom", repo="c/r")])


@pytest.mark.parametrize("leg", ["present", "excluded"])
def test_custom_ids_present_and_excluded_without_warning(leg):
    m = custom_model()
    if leg == "present":
        base = "# W\n\n- [ ] A {issue: Issue-abc}\n- [ ] T {issue: Issue-T-3}\n"
        _out, stats = merged(base, m)
        assert stats["added"] == []
        assert stats["present"] == 2
    else:
        base = "# W\n\n<!-- wbs-exclude: Issue-abc, Issue-T-3 -->\n\n- [ ] Other\n"
        assert wbs_import.exclusions(parser.parse_text(base), m)[1] == []
        _out, stats = merged(base, m)
        assert stats["added"] == []
        assert stats["excluded"] == 2


def test_issue_todo_names_nothing():
    m = wbs_import.build([src([rec("1")])])
    assert wbs_import.resolve_id(m, "Issue-TODO") == []
    _ids, warns = wbs_import.exclusions(parser.parse_text("<!-- wbs-exclude: Issue-TODO -->\n"), m)
    assert warns == ["line 1: 'Issue-TODO' is not an issue id; ignored"]


def test_exclusion_warnings_keep_todays_line_order():
    # A source-check warning (line 1) above a grammar warning (line 2) keeps
    # today's single-pass line order.
    m = wbs_import.build([src([rec("1")])])
    text = "<!-- wbs-exclude: Issue-x -->\n<!-- WBS-Exclude: Issue-1 -->\n"
    _ids, warns = wbs_import.exclusions(parser.parse_text(text), m)
    near = f"not an exclusion line ({parser.EXCLUDE_WANT}); ignored"
    assert warns == ["line 1: 'Issue-x' is not an issue id; ignored", f"line 2: {near}"]


def test_exclusions_takes_no_dest():
    assert list(inspect.signature(wbs_import.exclusions).parameters) == ["tree", "model"]
    for name in ("EXCLUDE_KEY", "ID_TOKEN_RE", "EXCLUDE_WANT"):
        assert not hasattr(wbs_import, name), name


def test_run_merge_prefixes_every_exclusion_and_placement_warning(tmp_path, capsys):
    dest = tmp_path / "WBS.md"
    dest.write_bytes(b"# W\n\n"
                     b"- [ ] One {milestone: M1}\n"            # 3
                     b"- [ ] Two {milestone: M1}\n"            # 4
                     b"<!-- WBS-Exclude: Issue-5 -->\n"        # 5 malformed
                     b"<!-- wbs-exclude: Issue-TODO -->\n")    # 6 an unknown id
    m = wbs_import.build([src([rec("3", milestone="M1")])])
    assert wbs_import._run_merge(m, wbs_import.select(m, "all"), dest, tmp_path) == 0
    err = capsys.readouterr().err.splitlines()
    head = f"wbs init --merge: {dest}: "
    near = f"not an exclusion line ({parser.EXCLUDE_WANT}); ignored"
    assert f"{head}line 5: {near}" in err
    assert f"{head}line 6: 'Issue-TODO' is not an issue id; ignored" in err
    assert (f"{head}milestone 'M1' has 2 candidate nodes (lines 3, 4); "
            "its issues go under the first") in err
    assert not [ln for ln in err if f"{dest} line " in ln]


def collision_sources():
    """A custom origin `Issue-` with F1 and a GitHub fork `Issue-F` with 1:
    both records are written as the leaf Issue-F1."""
    return [src([rec("F1")], backend="custom", repo="c/r"),
            src([rec("1", url="https://github.com/me/f/issues/1")],
                name="fork", repo="me/f", prefix="Issue-F")]


COLLISION = "leaf Issue-F1 names origin F1 and fork 1; it resolves to fork 1"


def _jsonl(path, records):
    path.write_text(lines(*records), encoding="utf-8")
    return str(path)


def test_leaf_collision_warns_once_and_keys_by_leaf(tmp_path, capsys):
    m = wbs_import.build(collision_sources())
    # (a) one line, prefixed by the run's mode
    assert wbs_import.leaf_collisions(m, "wbs init") == [f"wbs init: {COLLISION}"]
    assert wbs_import.leaf_collisions(m, "wbs init --merge") == [f"wbs init --merge: {COLLISION}"]
    # (b) present by the leaf
    _out, stats = merged("# W\n\n- [ ] X {issue: Issue-F1}\n", m)
    assert stats["added"] == []
    # (c) excluded by the leaf
    _out, stats = merged("# W\n\n<!-- wbs-exclude: Issue-F1 -->\n\n- [ ] Other\n", m)
    assert stats["added"] == []
    # (d) through run(): run 1 adds, run 2 adds nothing; one warning per run
    origin, fork = collision_sources()
    dest = tmp_path / "WBS.md"
    base = "# W\n\n- [ ] Other\n"
    dest.write_text(base, encoding="utf-8")
    env = {"WBS_IMP_ORIGIN_FILE": _jsonl(tmp_path / "o.jsonl", origin["records"]),
           "WBS_IMP_ORIGIN_BACKEND": "custom", "WBS_IMP_ORIGIN_REPO": "c/r",
           "WBS_IMP_ORIGIN_PREFIX": "Issue-",
           "WBS_IMP_FORK_FILE": _jsonl(tmp_path / "f.jsonl", fork["records"]),
           "WBS_IMP_FORK_BACKEND": "github", "WBS_IMP_FORK_REPO": "me/f",
           "WBS_IMP_FORK_PREFIX": "Issue-F",
           "WBS_IMP_MODE": "merge", "WBS_IMP_RANGE": "all",
           "WBS_IMP_DEST": str(dest), "DEVDOC_DIR": str(tmp_path)}
    capsys.readouterr()
    assert wbs_import.run(env) == 0
    err1 = capsys.readouterr().err
    after1 = dest.read_bytes()
    assert after1 != base.encode("utf-8")
    assert err1.count(f"wbs init --merge: {COLLISION}") == 1
    assert wbs_import.run(env) == 0
    err2 = capsys.readouterr().err
    assert dest.read_bytes() == after1
    assert "nothing to add" in err2
    assert err2.count(f"wbs init --merge: {COLLISION}") == 1


def test_equal_dir_prefixes_resolve_to_the_origin(tmp_path, capsys):
    # The wbs-import side of the tie-break wbs-update.sh pins in bats ("equal
    # dir_prefixes: update reads the origin, as wbs init does"): run() lists
    # the origin first, and resolve_id keeps that order on a tie.
    fork_rec = rec("1", url="https://github.com/me/f/issues/1")
    env = {"WBS_IMP_ORIGIN_FILE": _jsonl(tmp_path / "o.jsonl", [rec("1")]),
           "WBS_IMP_ORIGIN_BACKEND": "github", "WBS_IMP_ORIGIN_REPO": "o/r",
           "WBS_IMP_ORIGIN_PREFIX": "Issue-",
           "WBS_IMP_FORK_FILE": _jsonl(tmp_path / "f.jsonl", [fork_rec]),
           "WBS_IMP_FORK_BACKEND": "github", "WBS_IMP_FORK_REPO": "me/f",
           "WBS_IMP_FORK_PREFIX": "Issue-", "WBS_IMP_MODE": "survey"}
    assert wbs_import.run(env) == 0
    sv = json.loads(capsys.readouterr().out)
    assert [s["source"] for s in sv["sources"]] == ["origin", "fork"]
    m = wbs_import.build([src([rec("1")]), src([fork_rec], name="fork", repo="me/f")])
    assert [_named(n) for n in wbs_import.resolve_id(m, "Issue-1")] == [("origin", "1")]


def test_presence_unions_codec_and_exact_leaf():
    # origin FOO-1 is written Issue-FOO-1, which the codec reads as fork OO-1
    # (Issue-F + key OO-1); fork OO-1 is written Issue-F1. With "codec, else
    # exact", origin FOO-1 would be re-added on every merge.
    m = wbs_import.build([
        src([rec("FOO-1", url=J + "FOO-1")], backend="jira", repo="PROJ", keyprefix="PROJ"),
        src([rec("OO-1", url=J + "OO-1")], name="fork", backend="jira", repo="OO",
            prefix="Issue-F", keyprefix="OO")])
    assert sorted(n.leaf for n in m.nodes) == ["Issue-F1", "Issue-FOO-1"]
    base = "# W\n\n- [ ] A {issue: Issue-FOO-1}\n- [ ] B {issue: Issue-F1}\n"
    _out, stats = merged(base, m)
    assert stats["added"] == []


FIXTURES = REPO / "tests" / "fixtures"


def _fixture_ids():
    """Each backend's issue ids as its issue-list verb emits them, and the
    count each set must have (an empty set must not pass)."""
    def load(*parts):
        return json.loads((FIXTURES.joinpath(*parts)).read_text(encoding="utf-8"))
    gh = [str(i["number"]) for i in load("issue-github", "issue-list-shaped.json")]
    gl = [str(i["iid"]) for i in load("gitlab", "issues-shaped.json")]
    jira = [i["key"] for n in (1, 2) for i in load("jira", f"search-shaped-{n}.json")["issues"]]
    text = (FIXTURES / "wbs-merge" / "issue-list.jsonl").read_text(encoding="utf-8")
    merge_ids = [json.loads(ln)["id"] for ln in text.splitlines() if ln.strip()]
    return {"github": (gh, 62), "gitlab": (gl, 62), "jira": (jira, 62),
            "merge": (merge_ids, 16), "custom": (["abc", "T-3"], 2)}


def _set_source(kind, ids, name, prefix):
    if kind == "jira":
        kw = {"backend": "jira", "repo": "SHAPED", "keyprefix": "SHAPED"}
    else:
        kw = {"backend": "github" if kind == "merge" else kind, "repo": f"{kind}/r"}
    return src([rec(i) for i in ids], name=name, prefix=prefix, **kw)


KINDS = ("github", "gitlab", "jira", "merge", "custom")
ROUND_TRIP = ([[(k, "origin", "Issue-")] for k in KINDS]
              + [[("github", "origin", "Issue-"), (k, "fork", "Issue-Fork-")] for k in KINDS]
              + [[("jira", "origin", "Issue-"), ("github", "fork", "Issue-F")]])


@pytest.mark.parametrize("config", ROUND_TRIP,
                         ids=["+".join(f"{k}@{p}" for k, _n, p in c) for c in ROUND_TRIP])
def test_leaf_codec_round_trips_non_colliding_records(config):
    sets = _fixture_ids()
    m = wbs_import.build([_set_source(k, sets[k][0], name, prefix) for k, name, prefix in config])
    for si, (k, _name, _prefix) in enumerate(config):
        assert sum(1 for n in m.nodes if n.si == si) == sets[k][1], k
    assert wbs_import.leaf_collisions(m, "wbs init") == []
    # Writer -> reader only: a key-form leaf such as Issue-SHAPED-1 is not
    # leaf_for's spelling, so the inverse direction is not a round trip.
    for n in m.nodes:
        got = trk.parse_leaf(m.sources, n.leaf)
        assert got is not None, n.leaf
        assert got[0] is n.source, n.leaf
        assert got[1] == n.rec["id"], n.leaf


def test_range_since_reads_a_custom_id_by_the_codec():
    m = wbs_import.build([src([done(i) for i in ("T-1", "T-2", "T-3", "T-4")],
                              backend="custom", repo="c/r")])
    assert wbs_import.select(m, "since:Issue-T-3") == {"Issue-T-3", "Issue-T-4"}


def test_range_since_a_custom_id_without_a_number_is_refused():
    # a custom source reads any rest, so `Issue-TODO` names it; with no
    # trailing number there is nothing to compare, not "from 0"
    m = wbs_import.build([src([done(i) for i in ("T-1", "T-2")], backend="custom", repo="c/r")])
    with pytest.raises(wbs_import.RangeError, match="no trailing number"):
        wbs_import.select(m, "since:Issue-TODO")


def _jira_env(tmp_path, records, mode, **extra):
    env = {"WBS_IMP_ORIGIN_FILE": _jsonl(tmp_path / "o.jsonl", records),
           "WBS_IMP_ORIGIN_BACKEND": "jira", "WBS_IMP_ORIGIN_REPO": "PROJ",
           "WBS_IMP_ORIGIN_PREFIX": "Issue-", "WBS_IMP_ORIGIN_KEYPREFIX": "WRONG",
           "WBS_IMP_MODE": mode, "WBS_IMP_RANGE": "all", "WBS_IMP_PROJECT": "p",
           "DEVDOC_DIR": str(tmp_path)}
    env.update(extra)
    return env


def test_run_derives_jira_keyprefix_from_env(tmp_path, capsys):
    epic = rec("ALT-1", title="Epic", labels=["epic"], url=J + "ALT-1")
    for var, want in (({"DEVAGENT_JIRA_PROJECT_KEY": "ALT"}, "Issue-1"), ({}, "Issue-ALT-1")):
        assert wbs_import.run(_jira_env(tmp_path, [epic], "survey", **var)) == 0
        sv = json.loads(capsys.readouterr().out)
        assert sv["epics"][0]["issue"] == want


def test_run_derived_jira_keyprefix_resolves_a_parent_line(tmp_path):
    # wbs-import.py's _resolve_line -> _node_for reads `#1` as <keyprefix>-1
    epic = rec("ALT-1", title="Epic", labels=["epic"], url=J + "ALT-1")
    child = rec("ALT-2", title="Child", body="Parent epic: #1", url=J + "ALT-2")
    (tmp_path / "t.md").write_text("# {project} WBS\n\n", encoding="utf-8")
    dest = tmp_path / "out" / "WBS.md"
    env = _jira_env(tmp_path, [epic, child], "import", DEVAGENT_JIRA_PROJECT_KEY="ALT",
                    WBS_IMP_TEMPLATE=str(tmp_path / "t.md"), WBS_IMP_DEST=str(dest))
    assert wbs_import.run(env) == 0
    body = dest.read_text(encoding="utf-8")
    assert "- [ ] Epic {issue: Issue-1}\n  - [ ] Child {issue: Issue-2}\n" in body


# --- #764: every WBS.md writer goes through write_document ---------------------
@pytest.fixture
def writes(monkeypatch):
    """Record each write_document call of the parser module wbs_import uses."""
    p = wbs_import._wbs_parser()
    real = p.write_document
    calls = []

    def recorder(path, text, *, exclusive=False):
        calls.append((Path(path), text, exclusive))
        return real(path, text, exclusive=exclusive)

    monkeypatch.setattr(p, "write_document", recorder)
    return calls


def _write_via(entry, tmp_path):
    """Drive one writer entry point; return its dest."""
    p = wbs_import._wbs_parser()
    dest = tmp_path / "WBS.md"
    if entry == "update":
        # stands in for scripts/wbs-update.sh's heredoc, which loads its own copy
        dest.write_bytes((REPO / "tests" / "fixtures" / "wbs" / "preserve.md").read_bytes())
        tree = p.parse_file(dest)
        tree["children"][0]["children"][0]["glyph"] = "x"
        assert p.write_update(dest, tree, order=True) == []
    elif entry == "order":
        # stands in for scripts/wbs-order.sh's heredoc (#803)
        dest.write_bytes(b"- [ ] E\n  - [ ] S {depends_on: T}\n  - [ ] T {issue: T}\n")
        rc, _report, _diff = p.order_file(dest)
        assert rc == 0
    elif entry == "merge":
        dest.write_bytes((MERGE_FIX / "base.md").read_bytes())
        assert _run_merge(dest) == 0
    elif entry == "import":
        epic = rec("ALT-1", title="Epic", labels=["epic"], url=J + "ALT-1")
        (tmp_path / "t.md").write_text("# {project} WBS\n\n", encoding="utf-8")
        env = _jira_env(tmp_path, [epic], "import", DEVAGENT_JIRA_PROJECT_KEY="ALT",
                        WBS_IMP_TEMPLATE=str(tmp_path / "t.md"), WBS_IMP_DEST=str(dest))
        assert wbs_import.run(env) == 0
    else:
        force = "1" if entry == "template-force" else "0"
        env, dest = _template_env(tmp_path, b"# {{PROJECT}} WBS\n", "p", force)
        if force == "1":
            dest.write_bytes(b"hand-edited\n")
        assert wbs_import.write_template(env) == 0
    return dest


@pytest.mark.parametrize("entry, exclusive", [
    ("update", False), ("order", False), ("merge", False), ("import", True),
    ("template", True), ("template-force", False),
])
def test_every_writer_calls_write_document_once(entry, exclusive, tmp_path, writes):
    dest = _write_via(entry, tmp_path)
    assert len(writes) == 1
    assert writes[0][0] == dest
    assert writes[0][2] is exclusive
    assert dest.read_bytes() == writes[0][1].encode("utf-8")


def test_run_merge_veto_message_is_unchanged(tmp_path, monkeypatch, capsys):
    data = (MERGE_FIX / "base.md").read_bytes()
    dest = tmp_path / "WBS.md"
    dest.write_bytes(data)
    monkeypatch.setattr(wbs_import._wbs_parser(), "inserted_only", lambda old, new: False)
    assert _run_merge(dest) == 1
    assert (f"wbs init --merge: refusing to write {dest}: an existing line would change "
            "(a bug; please report); nothing written") in capsys.readouterr().err.splitlines()
    assert dest.read_bytes() == data


def test_run_import_refuses_an_existing_dest(tmp_path, capsys):
    dest = tmp_path / "out" / "WBS.md"
    dest.parent.mkdir()
    dest.write_bytes(b"hand-edited\n")
    epic = rec("ALT-1", title="Epic", labels=["epic"], url=J + "ALT-1")
    (tmp_path / "t.md").write_text("# {project} WBS\n\n", encoding="utf-8")
    env = _jira_env(tmp_path, [epic], "import", DEVAGENT_JIRA_PROJECT_KEY="ALT",
                    WBS_IMP_TEMPLATE=str(tmp_path / "t.md"), WBS_IMP_DEST=str(dest))
    assert wbs_import.run(env) == 1
    assert f"wbs init: {dest} exists" in capsys.readouterr().err.splitlines()
    assert dest.read_bytes() == b"hand-edited\n"


def _template_env(tmp_path, data, project="proj", force=None):
    t = tmp_path / "wbs_template.md"
    t.write_bytes(data)
    env = {"WBS_IMP_TEMPLATE": str(t), "WBS_IMP_PROJECT": project,
           "WBS_IMP_DEST": str(tmp_path / "WBS.md")}
    if force is not None:
        env["WBS_IMP_FORCE"] = force
    return env, tmp_path / "WBS.md"


@pytest.mark.parametrize("data", [
    b"# {{PROJECT}} WBS\n\nfor {{PROJECT}}\n",
    b"# {{PROJECT}} WBS\r\n\r\nfor {{PROJECT}}\r\n",
    b"# {{PROJECT}} WBS\n\nfor {{PROJECT}}",
], ids=["lf", "crlf", "nofinal"])
@pytest.mark.parametrize("project", ["proj", "a&b|c\\d"], ids=["plain", "sed-specials"])
def test_write_template_substitutes_and_keeps_bytes(data, project, tmp_path):
    env, dest = _template_env(tmp_path, data, project)
    assert wbs_import.write_template(env) == 0
    assert dest.read_bytes() == data.replace(b"{{PROJECT}}", project.encode("utf-8"))


@pytest.mark.parametrize("force", [None, "0", "true"], ids=["unset", "0", "true"])
def test_write_template_refuses_an_existing_dest_without_force(force, tmp_path, capsys):
    env, dest = _template_env(tmp_path, b"# {{PROJECT}} WBS\n", force=force)
    dest.write_bytes(b"hand-edited\n")
    assert wbs_import.write_template(env) == 1
    assert capsys.readouterr().err == f"wbs init: {dest} exists; pass --force to overwrite\n"
    assert dest.read_bytes() == b"hand-edited\n"


def test_write_template_refuses_a_non_utf8_template(tmp_path, capsys):
    env, dest = _template_env(tmp_path, b"# {{PROJECT}} \xff\n")
    assert wbs_import.write_template(env) == 1
    assert capsys.readouterr().err.startswith(f"wbs init: cannot read {env['WBS_IMP_TEMPLATE']}: ")
    assert not dest.exists()


_PATH_WRITES = ("write_bytes", "write_text", "touch", "rename", "symlink_to", "hardlink_to")
# only on an `os.` / `shutil.` receiver: `str.replace` would otherwise match
_OS_WRITES = ("replace", "rename", "renames", "copy", "copyfile", "copy2", "move",
              "link", "symlink")


def _direct_writes(src):
    """Calls in Python source that write a file other than via write_document."""
    hits = []
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        recv = f.value.id if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) else None
        if isinstance(f, ast.Attribute) and (f.attr in _PATH_WRITES or (
                recv in ("os", "shutil") and f.attr in _OS_WRITES)
                or (recv == "os" and f.attr == "open")):  # os.open's flags: fail closed
            hits.append(f"{node.lineno}: {f.attr}")
        elif (isinstance(f, ast.Name) and f.id == "open") or (
                isinstance(f, ast.Attribute) and f.attr == "open"):
            # open(path, mode) and io.open(path, mode); Path(p).open(mode)
            at = 1 if isinstance(f, ast.Name) or recv == "io" else 0
            mode = node.args[at] if len(node.args) > at else next(
                (k.value for k in node.keywords if k.arg == "mode"), None)
            if mode is None:
                continue
            literal = isinstance(mode, ast.Constant) and isinstance(mode.value, str)
            if not literal or set(mode.value) & set("wxa+"):  # non-literal fails closed
                hits.append(f"{node.lineno}: open")
    return hits


def _dest_redirects(sh, name):
    """Uncommented shell lines redirecting any fd to $name / ${name}, or naming
    it in a cp, mv, install, tee, dd, truncate, `sed -i` or `perl -i` command
    (a read there fails closed)."""
    var = r'"?\$\{?' + name + r'\b\}?"?'
    pat = re.compile(r'[0-9]?>[>|]?\s*' + var
                     + r'|\b(cp|mv|install|tee|dd|truncate)\b.*' + var
                     + r'|\b(sed|perl)\b.*\s-\w*i.*' + var)
    return [f"{i}: {line.strip()}" for i, line in enumerate(sh.splitlines(), 1)
            if not line.lstrip().startswith("#") and pat.search(line)]


def _calls_to(src, attr):
    return sum(1 for n in ast.walk(ast.parse(src))
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
               and n.func.attr == attr)


def _heredoc(sh, delim="PY"):
    lines_ = sh.splitlines()
    start = next(i for i, line in enumerate(lines_) if line.rstrip().endswith(f"<<'{delim}'"))
    end = lines_.index(delim, start)
    return "\n".join(lines_[start + 1:end]) + "\n"


def test_no_writer_bypasses_write_document():
    """The guard's universe is the four WBS.md writer files: wbs-import.py,
    wbs-init.sh, wbs-update.sh and wbs-order.sh (each script's heredoc
    Python, plus redirects to its path variables), and the parser's own
    writers (`write_markdown`, and #803's `write_update` and `order_file`),
    whose only direct write is inside `write_document`. A new WBS.md writer
    file must join this list."""
    imp = LIB.read_text(encoding="utf-8")
    init = (REPO / "scripts" / "wbs-init.sh").read_text(encoding="utf-8")
    update = (REPO / "scripts" / "wbs-update.sh").read_text(encoding="utf-8")
    order_sh = (REPO / "scripts" / "wbs-order.sh").read_text(encoding="utf-8")
    parser_src = (REPO / "scripts" / "lib" / "wbs-parser.py").read_text(encoding="utf-8")
    body = _heredoc(update)
    order_body = _heredoc(order_sh)
    # the redirect legs check by name: pin that those names still hold WBS.md
    assert 'dest="$devdoc_dir/WBS.md"' in init
    assert 'wbs="$devdoc_dir/WBS.md"' in update
    assert 'WBS_PATH="$wbs"' in update
    assert 'wbs="$devdoc_dir/WBS.md"' in order_sh
    assert _direct_writes(imp) == []
    assert _dest_redirects(init, "dest") == []
    assert _direct_writes(body) == []
    assert _dest_redirects(update, "wbs") + _dest_redirects(update, "WBS_PATH") == []
    assert _direct_writes(order_body) == []
    assert _dest_redirects(order_sh, "wbs") == []
    assert _calls_to(imp, "write_document") == 2
    assert _calls_to(imp, "write_markdown") == 1
    assert _calls_to(body, "write_update") == 1
    assert _calls_to(body, "write_markdown") == 0
    assert _calls_to(order_body, "order_file") == 1
    # the parser writes bytes only inside write_document
    tree = ast.parse(parser_src)
    span = next((n.lineno, n.end_lineno) for n in tree.body
                if isinstance(n, ast.FunctionDef) and n.name == "write_document")
    hits = _direct_writes(parser_src)
    assert hits
    assert [h for h in hits if not span[0] <= int(h.split(":")[0]) <= span[1]] == []
    # planted controls through the same predicates
    for py in ('Path(d).write_bytes(b"")', 'open(d, "xb")', "open(d, m)",
               'open(d, mode=f"{m}")', 'open(d, mode="a")', 'open(d, "r+b")',
               "os.replace(t, d)", "shutil.copyfile(t, d)", "Path(t).rename(d)",
               "Path(d).touch()", 'Path(d).open("wb")', 'Path(d).open(mode="w")',
               'io.open(d, "wb")', "os.open(d, os.O_WRONLY | os.O_CREAT)"):
        assert _direct_writes(py), py
    for sh, name in (('sed x "$t" > "$dest"', "dest"), ('printf x 2>"$dest"', "dest"),
                     ("echo >> ${dest}", "dest"), ('echo > "$wbs"', "wbs"),
                     ('cp "$t" "$dest"', "dest"), ('mv "$t" "$dest"', "dest"),
                     ('printf x | tee "$dest"', "dest"), ('dd if=x of="$dest"', "dest"),
                     ('install -m 644 "$t" "$WBS_PATH"', "WBS_PATH"),
                     ('sed -i "s/a/b/" "$dest"', "dest"), ('perl -pi -e x "$dest"', "dest"),
                     ('truncate -s0 "$dest"', "dest"), ('echo >| "$dest"', "dest")):
        assert _dest_redirects(sh, name), sh
    assert _direct_writes('"""uses write_bytes"""\nopen(d)\nopen(d, "rb")\n'
                          's.replace("a", "b")\nPath(d).open()\nio.open(d, "r")\n') == []
    assert _dest_redirects('sed -n "1p" "$dest"\n', "dest") == []
    assert _dest_redirects('  # sed x > "$dest"\n', "dest") == []
    assert _dest_redirects('echo > "$destdir/x"\n', "dest") == []
    assert _dest_redirects('echo > "$wbs_dir/x"\n', "wbs") == []
    assert _dest_redirects('cp "$t" "$destdir/x"\n', "dest") == []
