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
