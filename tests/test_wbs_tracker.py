"""Tests for scripts/lib/wbs-tracker.py (#703)."""
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib" / "wbs-tracker.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wbs_tracker = _load("wbs_tracker", LIB)


# One row per cell of the plan's D3 precedence table:
# (current glyph, class, local checklist glyph, current status_src, expected)
PRECEDENCE = [
    ("P", "done", "~", None, ("x", "tracker")),
    ("!", "not_planned", "~", None, ("-", "tracker")),
    ("P", "in_progress", "~", None, None),
    ("!", "in_progress", "~", None, None),
    ("?", "in_progress", "~", None, None),
    ("x", "in_progress", None, None, ("~", "tracker")),
    (" ", "in_progress", None, None, ("~", "tracker")),
    (" ", "open", "x", None, ("~", "tracker")),
    ("~", "open", " ", None, (" ", "checklist")),
    ("x", "open", None, None, None),
    ("x", "open", None, "tracker", ("~", "tracker")),
    ("x", "open", None, "checklist", None),
    ("P", "open", None, "tracker", None),
    ("!", "open", None, "tracker", None),
    ("?", "open", None, "tracker", None),
    (" ", "other", "x", None, ("x", "checklist")),
    (" ", "none", "x", None, ("x", "checklist")),
    (" ", "other", None, None, None),
    (" ", "none", None, None, None),
    (" ", "missing", "x", None, None),
    (" ", "unmatched", "x", "tracker", None),
    # #704 hold rule: an MR-set glyph survives a tracker that only says open
    ("~", "open", None, "mr", None),
    ("~", "open", " ", "mr", None),
    ("~", "open", "x", "mr", None),
    ("~", "in_progress", None, "mr", None),
    ("~", "none", "x", "mr", None),
    ("~", "done", "~", "mr", ("x", "tracker")),
    ("~", "not_planned", None, "mr", ("-", "tracker")),
    ("~", "other", "x", "mr", ("x", "checklist")),
]


@pytest.mark.parametrize("current,cls,local,cur_src,expected", PRECEDENCE)
def test_resolve_precedence_table(current, cls, local, cur_src, expected):
    assert wbs_tracker.resolve(current, cls, local, cur_src) == expected


# mr_hold=False (no code backend): MR leaves fall through to #703's rules.
@pytest.mark.parametrize("current,cls,local,cur_src,expected", [
    ("~", "open", None, "mr", None),
    ("~", "open", " ", "mr", (" ", "checklist")),
    ("~", "in_progress", None, "mr", ("~", "tracker")),
    ("~", "none", "x", "mr", ("x", "checklist")),
])
def test_resolve_without_mr_hold(current, cls, local, cur_src, expected):
    assert wbs_tracker.resolve(current, cls, local, cur_src, mr_hold=False) == expected


# #704 mr_effect: (glyph, status_src, cls, local, mr) -> (glyph, status_src
# or None = remove, mr or None = remove), or None = untouched.
MR_EFFECT = [
    # closing classes drop mr: only
    ("x", "tracker", "done", None, None, ("x", "tracker", None)),
    ("-", "tracker", "not_planned", None, "open", ("-", "tracker", None)),
    ("~", "checklist", "other", "~", None, ("~", "checklist", None)),
    # no MR lookup for the leaf
    ("~", "mr", "missing", None, "open", None),
    ("~", "mr", "none", None, "open", None),
    ("~", "mr", "unmatched", None, "open", None),
    ("~", "mr", "open", None, None, None),
    ("~", "mr", "open", None, "missing", None),
    # linked MR state
    (" ", None, "open", None, "open", ("~", "mr", "open")),
    ("x", "checklist", "open", "x", "draft", ("~", "mr", "draft")),
    (" ", "tracker", "in_progress", None, "merged", ("~", "mr", "merged")),
    ("P", None, "open", None, "open", ("P", None, "open")),
    ("!", "checklist", "open", None, "draft", ("!", "checklist", "draft")),
    ("?", "mr", "in_progress", None, "merged", ("?", "mr", "merged")),
    # none: a leaf the MR did not set only loses mr:
    ("~", "checklist", "open", "~", "none", ("~", "checklist", None)),
    (" ", None, "open", None, "none", (" ", None, None)),
    # none: an MR-set leaf takes #703's result
    ("~", "mr", "open", " ", "none", (" ", "checklist", None)),
    ("~", "mr", "open", "x", "none", ("~", "tracker", None)),
    ("~", "mr", "in_progress", None, "none", ("~", "tracker", None)),
    # none, no #703 signal (OQ2 as revised): [ ] and status_src removed
    ("~", "mr", "open", None, "none", (" ", None, None)),
    ("P", "mr", "open", None, "none", ("P", "mr", None)),
    ("!", "mr", "open", None, "none", ("!", "mr", None)),
    ("?", "mr", "open", None, "none", ("?", "mr", None)),
]


@pytest.mark.parametrize("glyph,src,cls,local,mr,expected", MR_EFFECT)
def test_mr_effect_table(glyph, src, cls, local, mr, expected):
    assert wbs_tracker.mr_effect(glyph, src, cls, local, mr) == expected


def test_oq2_fixed_point():
    # the abandoned-MR leaf, run again: neither phase touches it
    assert wbs_tracker.resolve(" ", "open", None, None) is None
    assert wbs_tracker.mr_effect(" ", None, "open", None, "none") == (" ", None, None)


def test_parse_state_list_ok():
    text = "1\tdone\r\n\r\n2\topen\r\nPROJ-3\tin_progress\n\n4\tnot_planned\n5\tother"
    assert wbs_tracker.parse_state_list(text) == {
        "1": "done",
        "2": "open",
        "PROJ-3": "in_progress",
        "4": "not_planned",
        "5": "other",
    }
    assert wbs_tracker.parse_state_list("") == {}


@pytest.mark.parametrize(
    "text,lineno",
    [
        ("1\tdone\n2 open\n", 2),
        ("1\tdone\n\n3\tclosed\n", 3),
        ("7\topen\n7\tdone\n", 2),
    ],
)
def test_parse_state_list_rejects(text, lineno):
    with pytest.raises(ValueError) as exc:
        wbs_tracker.parse_state_list(text)
    assert f"malformed line {lineno}" in str(exc.value)


def test_parse_state_list_same_class_duplicate_is_ok():
    assert wbs_tracker.parse_state_list("7\topen\n7\topen\n") == {"7": "open"}


def _cli(stdin):
    return subprocess.run(
        [sys.executable, str(LIB), "check"],
        input=stdin.encode(),
        capture_output=True,
    )


def test_cli_check_uses_parse():
    bad = _cli("1\tdone\nbad line\n")
    assert bad.returncode == 1
    assert b"malformed line 2" in bad.stderr
    good = _cli("1\tdone\n2\topen\n3\tother\n")
    assert good.returncode == 0
    assert good.stdout.strip() == b"3"


# --- checklist_state (lifted from wbs-update.sh, #706) -----------------------
def _checklist(tmp_path, body, iid="Issue-1", newline=True):
    d = tmp_path / iid
    d.mkdir()
    (d / "checklist.md").write_text(body + ("\n" if newline else ""), encoding="utf-8")
    return tmp_path


def test_checklist_state_missing_is_none(tmp_path):
    assert wbs_tracker.checklist_state(tmp_path, "Issue-1") is None


def test_checklist_state_no_rows_is_none(tmp_path):
    _checklist(tmp_path, "# Issue-1\n\n## Log\n- note")
    assert wbs_tracker.checklist_state(tmp_path, "Issue-1") is None


def test_checklist_state_active_revision_done(tmp_path):
    _checklist(tmp_path, "## Revision 1\n- [ ]  0. pull\n- [ ]  1. draft\n"
               "## Revision 2\n- [x]  0. pull\n- [-]  1. draft")
    assert wbs_tracker.checklist_state(tmp_path, "Issue-1") == "x"


def test_checklist_state_progress_anywhere(tmp_path):
    _checklist(tmp_path, "## Revision 1\n- [x]  0. pull\n"
               "## Revision 2\n- [ ]  0. pull\n- [ ]  1. draft")
    assert wbs_tracker.checklist_state(tmp_path, "Issue-1") == "~"


def test_checklist_state_pending(tmp_path):
    _checklist(tmp_path, "- [ ]  0. pull\n- [ ]  1. draft")
    assert wbs_tracker.checklist_state(tmp_path, "Issue-1") == " "


def test_checklist_state_unterminated_last_row_counts(tmp_path):
    _checklist(tmp_path, "- [x]  0. pull\n- [x]  1. draft", newline=False)
    assert wbs_tracker.checklist_state(tmp_path, "Issue-1") == "x"
