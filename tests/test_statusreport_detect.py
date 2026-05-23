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


def test_poorly_scoped_by_ambiguity_keyword(tmp_path):
    cl = tmp_path / "checklist.md"
    cl.write_text(
        "## Log\n"
        "- 2026-05-19 10:00  scope: ambiguity in step 3 of implementation\n",
        encoding="utf-8",
    )
    assert sr.poorly_scoped(tmp_path)


def test_idle_when_no_log_entry_in_7d_and_step_below_20(monkeypatch):
    from datetime import datetime, timezone
    monkeypatch.setattr(
        sr, "_now", lambda: datetime(2026, 5, 19, 12, 0, tzinfo=timezone.utc)
    )
    assert sr.is_idle(ISSUES / "Issue-103", last_step=7)
    assert not sr.is_idle(ISSUES / "Issue-104", last_step=20)


def test_completed_detection():
    assert sr.is_completed(ISSUES / "Issue-104")
    assert not sr.is_completed(ISSUES / "Issue-103")


def test_completion_timestamp_returns_log_ts_of_step_20():
    ts = sr.completion_timestamp(ISSUES / "Issue-104")
    assert ts.year == 2026 and ts.month == 5 and ts.day == 15
