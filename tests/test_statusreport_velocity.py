"""Tests for scripts/lib/statusreport-velocity.py."""
import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "sr_velocity", REPO / "scripts" / "lib" / "statusreport-velocity.py"
)
sv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sv)


def _ts(y, m, d):
    return datetime(y, m, d, 12, 0, tzinfo=timezone.utc)


def test_velocity_zero_when_no_completions():
    now = _ts(2026, 5, 19)
    v = sv.velocity_per_week([], window_weeks=4, now=now)
    assert v == 0.0


def test_velocity_simple_case():
    now = _ts(2026, 5, 19)
    completions = [_ts(2026, 4, 21 + i) for i in range(8)]
    v = sv.velocity_per_week(completions, window_weeks=4, now=now)
    assert abs(v - 2.0) < 1e-6


def test_velocity_excludes_completions_before_window():
    now = _ts(2026, 5, 19)
    completions = [_ts(2026, 1, 1), _ts(2026, 1, 5), _ts(2026, 1, 9),
                   _ts(2026, 1, 13), _ts(2026, 1, 17),
                   _ts(2026, 5, 10), _ts(2026, 5, 15)]
    v = sv.velocity_per_week(completions, window_weeks=4, now=now)
    assert abs(v - 0.5) < 1e-6


def test_median_days_per_issue():
    starts = [_ts(2026, 5, 1), _ts(2026, 5, 1), _ts(2026, 5, 1)]
    ends   = [_ts(2026, 5, 4), _ts(2026, 5, 6), _ts(2026, 5, 8)]
    pairs = list(zip(starts, ends))
    assert sv.median_days_per_issue(pairs) == 5.0


def test_estimate_completion_date():
    now = _ts(2026, 5, 19)
    est = sv.estimate_completion(remaining_leaves=10, velocity=2.0, now=now)
    assert est.date().isoformat() == "2026-06-23"


def test_estimate_band_widens_with_variance():
    band_low = sv.estimate_band_weeks(per_week_counts=[2, 2, 2, 2])
    band_high = sv.estimate_band_weeks(per_week_counts=[0, 0, 4, 4])
    assert band_high > band_low


def test_estimate_when_zero_velocity_returns_none():
    now = _ts(2026, 5, 19)
    est = sv.estimate_completion(remaining_leaves=10, velocity=0.0, now=now)
    assert est is None
