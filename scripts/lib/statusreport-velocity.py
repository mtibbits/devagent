#!/usr/bin/env python3
"""Velocity and completion-estimate helpers for /devagent:statusreport.

Spec §14.5:
- Velocity = issues completed (step 23) per calendar week, over a
  configurable window (default 4 weeks).
- Estimate = (remaining WBS leaves) / velocity, rendered with `± X weeks`
  band based on observed variance.
- "Honest noise": no false precision; the band reflects real variance,
  not statistical confidence intervals.
"""

from __future__ import annotations

import statistics
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional


def velocity_per_week(
    completion_timestamps: Iterable[datetime],
    window_weeks: int = 4,
    now: Optional[datetime] = None,
) -> float:
    if now is None:
        now = datetime.now(timezone.utc)
    cutoff = now - timedelta(weeks=window_weeks)
    in_window = [t for t in completion_timestamps if t >= cutoff]
    return len(in_window) / window_weeks


def per_week_counts(
    completion_timestamps: Iterable[datetime],
    window_weeks: int = 4,
    now: Optional[datetime] = None,
) -> list[int]:
    if now is None:
        now = datetime.now(timezone.utc)
    buckets = [0] * window_weeks
    for t in completion_timestamps:
        delta = now - t
        weeks_back = int(delta.total_seconds() // (7 * 86400))
        if 0 <= weeks_back < window_weeks:
            buckets[window_weeks - 1 - weeks_back] += 1
    return buckets


def median_days_per_issue(start_end_pairs: list[tuple[datetime, datetime]]) -> float:
    if not start_end_pairs:
        return 0.0
    durations = [(e - s).total_seconds() / 86400.0 for s, e in start_end_pairs]
    return float(statistics.median(durations))


def estimate_completion(
    remaining_leaves: int,
    velocity: float,
    now: Optional[datetime] = None,
) -> Optional[datetime]:
    if velocity <= 0.0:
        return None
    if now is None:
        now = datetime.now(timezone.utc)
    weeks_needed = remaining_leaves / velocity
    return now + timedelta(weeks=weeks_needed)


def estimate_band_weeks(per_week_counts: list[int]) -> float:
    if len(per_week_counts) < 2:
        return 0.5
    sd = statistics.pstdev(per_week_counts)
    band = max(0.5, round(sd * 2) / 2)
    return band
