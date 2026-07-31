# Red-team findings — 2026-07-30-batch-restart-tuning (r1)

## Findings

- **[Blocking] Duplicate of an existing issue.** Tracker issue **#123**
  ("jittered exponential backoff for ingest worker restarts", open, filed
  2026-06-14) proposes the same backoff change with the same cap; its
  comment thread already settled the jitter bounds this draft re-opens.
  This challenges the capture's premise: the draft asks for work that is
  already tracked, not a missing capability.
- **[Recommended] The gauge name `restart_backoff_seconds` should carry the
  `ingest_` prefix used by every other worker metric.**

## Verdict: revise
