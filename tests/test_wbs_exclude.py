"""Tests for scripts/lib/wbs-exclude.py, `wbs exclude`'s entry point (#761)."""
import importlib.util
import io
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "wbs-exclude.py"
MERGE_BASE = REPO / "tests" / "fixtures" / "wbs-merge" / "base.md"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_exclude = _load("wbs_exclude", LIB)
P = wbs_exclude.psr


def _src(prefix, backend, keyprefix=""):
    return {"prefix": prefix, "backend": backend, "keyprefix": keyprefix}


GH = [_src("Issue-", "github")]
JIRA = [_src("Issue-", "jira", "PROJ")]
BASE = "# W\n\n- [ ] One {issue: Issue-1}\n\nTail prose.\n"
REFUSED_EFFECT = ("refusing to write {}: the new line would not take effect "
                  "(a bug; please report); nothing written")
REFUSED_CHANGE = ("refusing to write {}: an existing line would change "
                  "(a bug; please report); nothing written")


def _wbs(tmp_path, text):
    p = tmp_path / "WBS.md"
    p.write_bytes(text.encode("utf-8"))
    return p


@pytest.fixture
def writes(monkeypatch):
    """Every write_document call, as (path, text, exclusive); the real one runs."""
    calls = []
    real = P.write_document

    def record(path, text, *, exclusive=False):
        calls.append((str(path), text, exclusive))
        return real(path, text, exclusive=exclusive)

    monkeypatch.setattr(P, "write_document", record)
    return calls


def _main_env(monkeypatch, wbs, ids, backend="github", repo="acme/p", prefix="Issue-"):
    for s in ("ORIGIN", "FORK"):
        for k in ("BACKEND", "REPO", "PREFIX"):
            monkeypatch.delenv(f"WBS_EXCL_{s}_{k}", raising=False)
    monkeypatch.delenv("DEVAGENT_JIRA_PROJECT_KEY", raising=False)
    monkeypatch.setenv("WBS_EXCL_ORIGIN_BACKEND", backend)
    monkeypatch.setenv("WBS_EXCL_ORIGIN_REPO", repo)
    monkeypatch.setenv("WBS_EXCL_ORIGIN_PREFIX", prefix)
    monkeypatch.setenv("WBS_EXCL_PROJECT", "p")
    if wbs is None:
        monkeypatch.delenv("WBS_PATH", raising=False)
    else:
        monkeypatch.setenv("WBS_PATH", str(wbs))
    data = b"".join(i.encode("utf-8") + b"\0" for i in ids)
    monkeypatch.setattr(sys, "stdin", io.TextIOWrapper(io.BytesIO(data)))


# --- config_sources ---------------------------------------------------------------
def test_config_sources_needs_all_three_fields_origin_first():
    env = {"WBS_EXCL_ORIGIN_BACKEND": "github", "WBS_EXCL_ORIGIN_REPO": "",
           "WBS_EXCL_ORIGIN_PREFIX": "Issue-",
           "WBS_EXCL_FORK_BACKEND": "github", "WBS_EXCL_FORK_REPO": "me/p-fork",
           "WBS_EXCL_FORK_PREFIX": "Issue-F"}
    assert wbs_exclude.config_sources(env) == [_src("Issue-F", "github")]
    env["WBS_EXCL_ORIGIN_REPO"] = "acme/p"
    assert wbs_exclude.config_sources(env) == [_src("Issue-", "github"),
                                               _src("Issue-F", "github")]
    env["WBS_EXCL_FORK_PREFIX"] = ""
    assert wbs_exclude.config_sources(env) == [_src("Issue-", "github")]
    env["WBS_EXCL_ORIGIN_BACKEND"] = ""
    assert wbs_exclude.config_sources(env) == []


def test_config_sources_jira_keyprefix_follows_the_env():
    env = {"WBS_EXCL_ORIGIN_BACKEND": "jira", "WBS_EXCL_ORIGIN_REPO": "PROJ",
           "WBS_EXCL_ORIGIN_PREFIX": "Issue-"}
    assert [s["keyprefix"] for s in wbs_exclude.config_sources(env)] == ["PROJ"]
    env["DEVAGENT_JIRA_PROJECT_KEY"] = "ALT"
    assert [s["keyprefix"] for s in wbs_exclude.config_sources(env)] == ["ALT"]
    env = {"WBS_EXCL_ORIGIN_BACKEND": "github", "WBS_EXCL_ORIGIN_REPO": "acme/p",
           "WBS_EXCL_ORIGIN_PREFIX": "Issue-", "DEVAGENT_JIRA_PROJECT_KEY": "ALT"}
    assert [s["keyprefix"] for s in wbs_exclude.config_sources(env)] == [""]


# --- read_ids, check_ids, fold ----------------------------------------------------
def test_read_ids_splits_on_nul_and_keeps_an_empty_id():
    assert wbs_exclude.read_ids(b"a\0\0b c\0") == ["a", "", "b c"]
    assert wbs_exclude.read_ids(b"") == []
    assert wbs_exclude.read_ids(b"Issue-1\nIssue-2\0") == ["Issue-1\nIssue-2"]


def test_check_ids_names_every_bad_id_in_order():
    ids = ["Issue 12", "Issue-1\nIssue-2", "Issue-1,Issue-2", "Issue-x-->", "", "Foo-12",
           "Issue-12"]
    assert wbs_exclude.check_ids(GH, ids, "p") == [
        "'Issue 12' is not an issue id",
        "'Issue-1\\nIssue-2' is not an issue id",
        "'Issue-1,Issue-2' is not an issue id",
        "'Issue-x-->' is not an issue id",
        "'' is not an issue id",
        "'Foo-12' names no configured issue source",
    ]
    assert wbs_exclude.check_ids(GH, ["Issue-12", "Issue-40"], "p") == []


GAP = "no issue source of p has backend, repo and dir_prefix set"


def test_check_ids_reports_a_config_gap_once():
    assert wbs_exclude.check_ids([], ["Issue-12", "Issue-13"], "p") == [GAP]


def test_check_ids_mixed_bad_grammar_and_config_gap():
    assert wbs_exclude.check_ids([], ["Issue 12", "Issue-13"], "p") == [
        "'Issue 12' is not an issue id", GAP]
    # no id passed the grammar: the gap is not reached
    assert wbs_exclude.check_ids([], ["Issue 12"], "p") == ["'Issue 12' is not an issue id"]


def test_fold_keeps_the_first_spelling_of_each_issue():
    assert wbs_exclude.fold(JIRA, ["Issue-13", "Issue-PROJ-13", "Issue-13", "Issue-14"]) == [
        "Issue-13", "Issue-14"]


# --- exclude ---------------------------------------------------------------------
def test_exclude_skips_ids_already_listed_by_the_resolver(tmp_path, monkeypatch, writes):
    base = "# W\n\n<!-- wbs-exclude: Issue-PROJ-12 -->\n"
    p = _wbs(tmp_path, base)

    def boom(*_a, **_k):
        raise AssertionError("rendered on the nothing-to-do path")

    with monkeypatch.context() as m:
        m.setattr(P, "insert_exclusion", boom)
        assert wbs_exclude.exclude(str(p), ["Issue-12"], JIRA) == (
            0, ["nothing to exclude; Issue-12 already listed"])
    assert p.read_bytes() == base.encode("utf-8")
    assert writes == []
    assert wbs_exclude.exclude(str(p), ["Issue-12", "Issue-13"], JIRA) == (
        0, [f"excluded Issue-13 in {p}; Issue-12 already listed"])
    assert p.read_bytes() == (base + "<!-- wbs-exclude: Issue-13 -->\n").encode("utf-8")


def test_exclude_fenced_line_neither_anchors_nor_lists(tmp_path, writes):
    text = MERGE_BASE.read_bytes()
    p = tmp_path / "WBS.md"
    p.write_bytes(text)
    assert wbs_exclude.exclude(str(p), ["Issue-13"], GH) == (0, [f"excluded Issue-13 in {p}"])
    lines = p.read_bytes().decode("utf-8").splitlines()
    assert lines[22] == "<!-- wbs-exclude: Issue-12, Issue-1 -->"
    assert lines[23] == "<!-- wbs-exclude: Issue-13 -->"
    assert len(lines) == len(text.decode("utf-8").splitlines()) + 1


def _drop_the_ids(real):
    def render(text, ids):
        line = f"<!-- wbs-exclude: {', '.join(ids)} -->"
        return real(text, ids).replace(line, "<!-- wbs-exclude:  -->")
    return render


def _drop_the_first_id(real):
    def render(text, ids):
        return real(text, ids[1:])
    return render


@pytest.mark.parametrize("ids, wrap", [
    (["Issue-12"], _drop_the_ids),
    (["Issue-12", "Issue-13"], _drop_the_first_id),
], ids=["one-id", "two-ids"])
def test_renderer_dropping_an_id_fails_the_reparse_check(tmp_path, monkeypatch, writes, capsys,
                                                         ids, wrap):
    p = _wbs(tmp_path, BASE)
    monkeypatch.setattr(P, "insert_exclusion", wrap(P.insert_exclusion))
    _main_env(monkeypatch, p, ids)
    assert wbs_exclude.main(["wbs-exclude.py", "write"]) == 1
    got = capsys.readouterr()
    assert got.err == "wbs exclude: " + REFUSED_EFFECT.format(p) + "\n"
    assert got.out == ""
    assert p.read_bytes() == BASE.encode("utf-8")
    assert writes == []


def test_a_new_warning_fails_the_reparse_check(tmp_path, monkeypatch, writes):
    p = _wbs(tmp_path, BASE)
    real = P.insert_exclusion

    def render(text, ids):
        return real(text, ids).replace("Issue-12 -->", "Issue-12, x>y -->")

    monkeypatch.setattr(P, "insert_exclusion", render)
    assert wbs_exclude.exclude(str(p), ["Issue-12"], GH) == (1, [REFUSED_EFFECT.format(p)])
    assert p.read_bytes() == BASE.encode("utf-8")
    assert writes == []


def test_inserted_only_veto_exits_1_and_writes_nothing(tmp_path, monkeypatch, writes):
    p = _wbs(tmp_path, BASE)
    monkeypatch.setattr(P, "inserted_only", lambda old, new: False)
    assert wbs_exclude.exclude(str(p), ["Issue-12"], GH) == (1, [REFUSED_CHANGE.format(p)])
    assert p.read_bytes() == BASE.encode("utf-8")
    assert writes == []


def test_exclude_writes_once_through_write_document(tmp_path, writes):
    p = _wbs(tmp_path, BASE)
    assert wbs_exclude.exclude(str(p), ["Issue-12", "Issue-40"], GH) == (
        0, [f"excluded Issue-12, Issue-40 in {p}"])
    assert len(writes) == 1
    path, text, exclusive = writes[0]
    assert (path, exclusive) == (str(p), False)
    assert p.read_bytes() == text.encode("utf-8")
    assert text == BASE + "<!-- wbs-exclude: Issue-12, Issue-40 -->\n"


def test_unreadable_or_non_utf8_wbs_exits_1(tmp_path, writes):
    missing = tmp_path / "WBS.md"
    rc, report = wbs_exclude.exclude(str(missing), ["Issue-12"], GH)
    assert rc == 1 and len(report) == 1
    assert report[0].startswith(f"cannot read {missing}: ")
    assert not missing.exists()
    bad = tmp_path / "bad.md"
    bad.write_bytes(b"\xff\n")
    rc, report = wbs_exclude.exclude(str(bad), ["Issue-12"], GH)
    assert rc == 1 and len(report) == 1
    assert report[0].startswith(f"cannot read {bad}: ")
    assert bad.read_bytes() == b"\xff\n"
    assert sorted(tmp_path.iterdir()) == [bad]
    assert writes == []


def test_exhausted_replace_exits_1_and_keeps_the_file(tmp_path, monkeypatch):
    monkeypatch.setenv("DEVAGENT_TEST_WBS_REPLACE_FAILS", "20")
    p = _wbs(tmp_path, BASE)
    rc, report = wbs_exclude.exclude(str(p), ["Issue-12"], GH)
    assert rc == 1 and len(report) == 1
    assert report[0].startswith(f"cannot write {p}: ")
    assert p.read_bytes() == BASE.encode("utf-8")
    assert not (tmp_path / ".devagent-wbs-tmp.WBS.md").exists()


def test_unclosed_fence_line_prints_once(tmp_path, capsys):
    text = "# W\n```\n<!-- wbs-exclude: Issue-1 -->\nend\n"
    p = _wbs(tmp_path, text)
    assert wbs_exclude.exclude(str(p), ["Issue-12"], GH) == (0, [f"excluded Issue-12 in {p}"])
    err = capsys.readouterr().err
    assert err.count("wbs-parser: unclosed code fence") == 1
    assert p.read_bytes().decode("utf-8") == text.replace(
        "Issue-1 -->\n", "Issue-1 -->\n<!-- wbs-exclude: Issue-12 -->\n")


# --- main --------------------------------------------------------------------------
def test_main_validate_never_reads_wbs(monkeypatch, capsys):
    _main_env(monkeypatch, None, ["Issue-12"])
    assert wbs_exclude.main(["wbs-exclude.py", "validate"]) == 0
    assert capsys.readouterr() == ("", "")
    _main_env(monkeypatch, None, ["Issue 12"])
    assert wbs_exclude.main(["wbs-exclude.py", "validate"]) == 2
    got = capsys.readouterr()
    assert got.out == ""
    assert got.err.endswith("wbs exclude: nothing written\n")
    assert got.err == "wbs exclude: 'Issue 12' is not an issue id\nwbs exclude: nothing written\n"


def test_main_write_refuses_a_bad_id_before_reading(tmp_path, monkeypatch, capsys, writes):
    p = _wbs(tmp_path, BASE)
    _main_env(monkeypatch, p, ["Issue-12", "Foo-12"])
    assert wbs_exclude.main(["wbs-exclude.py", "write"]) == 2
    assert capsys.readouterr().err == (
        "wbs exclude: 'Foo-12' names no configured issue source\n"
        "wbs exclude: nothing written\n")
    assert p.read_bytes() == BASE.encode("utf-8")
    assert writes == []


def test_main_refuses_an_empty_id_list(tmp_path, monkeypatch, capsys, writes):
    p = _wbs(tmp_path, BASE)
    _main_env(monkeypatch, p, [])
    assert wbs_exclude.main(["wbs-exclude.py", "write"]) == 2
    assert capsys.readouterr().err == "wbs exclude: no issue id given\n"
    assert p.read_bytes() == BASE.encode("utf-8")
    assert writes == []


def test_main_rejects_an_unknown_mode(monkeypatch, capsys):
    usage = "usage: wbs-exclude.py validate|write  (NUL-terminated ids on stdin)\n"
    assert wbs_exclude.main(["x", "frob"]) == 2
    assert capsys.readouterr().err == usage
    _main_env(monkeypatch, None, ["Issue-12"])
    assert wbs_exclude.main(["x", "write"]) == 2
    assert capsys.readouterr().err == usage
