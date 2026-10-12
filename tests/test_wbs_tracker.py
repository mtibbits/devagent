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
    (" ", "other", "x", None, ("x", "checklist")),
    (" ", "none", "x", None, ("x", "checklist")),
    (" ", "other", None, None, None),
    (" ", "none", None, None, None),
    (" ", "missing", "x", None, None),
    (" ", "unmatched", "x", "tracker", None),
]


@pytest.mark.parametrize("current,cls,local,cur_src,expected", PRECEDENCE)
def test_resolve_precedence_table(current, cls, local, cur_src, expected):
    assert wbs_tracker.resolve(current, cls, local, cur_src) == expected


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
