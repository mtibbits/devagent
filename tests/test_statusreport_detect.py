"""Tests for scripts/lib/statusreport-detect.py."""
import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ISSUES = REPO / "tests" / "fixtures" / "issues"

spec = importlib.util.spec_from_file_location(
    "sr_detect", REPO / "scripts" / "lib" / "statusreport-detect.py"
)
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)


def test_stuck_detected_by_stuck_file():
    assert sr.is_stuck(ISSUES / "Issue-100")
    assert not sr.is_stuck(ISSUES / "Issue-101")
    assert not sr.is_stuck(ISSUES / "Issue-104")


def test_failed_redteam_when_recent_blocking_no_recovery():
    assert sr.failed_redteam(ISSUES / "Issue-101")
    assert sr.failed_redteam(ISSUES / "Issue-100")
    assert not sr.failed_redteam(ISSUES / "Issue-104")


def test_failed_redteam_recovers_after_passing_entry(tmp_path):
    cl = tmp_path / "checklist.md"
    cl.write_text(
        "# x\n"
        "## Log\n"
        "- 2026-05-19 10:00  redmr: 3 blocking findings\n"
        "- 2026-05-19 14:00  redmr: 0 blocking findings, ship-ready\n",
        encoding="utf-8",
    )
    assert not sr.failed_redteam(tmp_path)


def test_poorly_scoped_by_recommendation_count():
    assert sr.poorly_scoped(ISSUES / "Issue-102")
    assert not sr.poorly_scoped(ISSUES / "Issue-104")


def _scope_log(tmp_path, msg):
    cl = tmp_path / "checklist.md"
    cl.write_text(f"## Log\n- 2026-05-19 10:00  scope: {msg}\n", encoding="utf-8")
    return tmp_path


def test_poorly_scoped_by_ambiguity_count_plural(tmp_path):
    # #132: the canonical core-scope line is plural ("N ambiguities"); the old
    # substring match on "ambiguity" could never fire on it. Now count-gated > 3.
    d = _scope_log(
        tmp_path,
        "Scope evaluation appended; 4 ambiguities, 2 preconditions, size=80 LOC; note: x",
    )
    assert sr.poorly_scoped(d)


def test_not_poorly_scoped_at_threshold_or_below(tmp_path):
    # #132: > 3 is the bar (matches SKILL.md "More than 3 ambiguities").
    assert not sr.poorly_scoped(
        _scope_log(tmp_path, "Scope evaluation appended; 3 ambiguities, 1 preconditions, size=40 LOC")
    )


def test_not_poorly_scoped_single_ambiguity(tmp_path):
    # #132: "1 ambiguity" must NOT mis-flag a well-scoped issue.
    assert not sr.poorly_scoped(
        _scope_log(tmp_path, "Scope evaluation appended; 1 ambiguity, 0 preconditions, size=10 LOC")
    )


def test_not_poorly_scoped_zero_ambiguities(tmp_path):
    assert not sr.poorly_scoped(
        _scope_log(tmp_path, "Scope evaluation appended; 0 ambiguities, 0 preconditions, size=5 LOC")
    )


def test_not_poorly_scoped_keyword_without_count(tmp_path):
    # #132: the contract is count-gated; a bare keyword with no count no longer fires.
    assert not sr.poorly_scoped(
        _scope_log(tmp_path, "ambiguity in step 3 of implementation")
    )


def test_idle_when_no_log_entry_in_7d_and_step_below_20(monkeypatch):
    from datetime import datetime, timezone
    monkeypatch.setattr(
        sr, "_now", lambda: datetime(2026, 5, 19, 12, 0, tzinfo=timezone.utc)
    )
    assert sr.is_idle(ISSUES / "Issue-103", last_step=7)
    assert not sr.is_idle(ISSUES / "Issue-104", last_step=23)


def test_completed_detection():
    assert sr.is_completed(ISSUES / "Issue-104")
    assert not sr.is_completed(ISSUES / "Issue-103")


def test_completion_timestamp_returns_log_ts_of_step_20():
    ts = sr.completion_timestamp(ISSUES / "Issue-104")
    assert ts.year == 2026 and ts.month == 5 and ts.day == 15


# ---- #134: the `N blocking` log-line contract that single-sources the ----
# ---- red-team output format (core-redmr's documented log line is the ----
# ---- machine-parsed surface; template vocabulary must never replace it) ----

def _one_entry_checklist(tmp_path, msg):
    cl = tmp_path / "checklist.md"
    cl.write_text(
        "# x\n"
        "## Log\n"
        f"- 2026-07-02 12:00  redmr: {msg}\n",
        encoding="utf-8",
    )
    # Parse guard: a malformed fixture would make negative asserts vacuous.
    assert len(sr._parse_log_entries(cl)) == 1, "fixture failed _LOG_RE"
    return tmp_path


def test_skill_log_format_with_blocking_flags(tmp_path):
    # core-redmr SKILL.md's documented format, nonzero count.
    d = _one_entry_checklist(tmp_path, "Red-team: 3 blocking, 1 major, 2 minor, 0 info")
    assert sr.failed_redteam(d)


def test_skill_log_format_zero_blocking_does_not_flag(tmp_path):
    d = _one_entry_checklist(tmp_path, "Red-team: 0 blocking, 1 major, 2 minor, 0 info")
    assert not sr.failed_redteam(d)


def test_template_vocabulary_is_invisible_to_the_parser(tmp_path):
    # redteam_mr.md's OLD vocabulary ("3 block") does NOT satisfy
    # `\d+\s+blocking` — a real failure logged this way would silently
    # never flag. This is WHY the skill's format is the single source.
    d = _one_entry_checklist(tmp_path, "Red-team: 3 block, 1 request-changes, 2 nit")
    assert not sr.failed_redteam(d)


def test_inline_artifacts_scans_root_and_analysis(tmp_path):
    (tmp_path / "analysis").mkdir()
    (tmp_path / "preship.md").write_text(
        "context: inline\nmodel: opus\nverdict SHIP\n", encoding="utf-8")
    (tmp_path / "analysis" / "2026-07-09-review.md").write_text(
        "context: inline\nmodel: opus\nbody\n", encoding="utf-8")
    (tmp_path / "analysis" / "2026-07-09-improve.md").write_text(
        "context: subagent\nmodel: opus\nbody\n", encoding="utf-8")
    (tmp_path / "mr.md").write_text("## Summary\nx\n", encoding="utf-8")
    hits = sr.inline_artifacts(tmp_path)
    assert "preship.md" in hits                          # #360: root is where inline lives
    assert "analysis/2026-07-09-review.md" in hits       # and analysis/
    assert "analysis/2026-07-09-improve.md" not in hits  # subagent, not inline
    assert "mr.md" not in hits                            # not a context: header


def test_inline_artifacts_empty_when_none(tmp_path):
    (tmp_path / "mr.md").write_text("## Summary\nx\n", encoding="utf-8")
    assert sr.inline_artifacts(tmp_path) == []
