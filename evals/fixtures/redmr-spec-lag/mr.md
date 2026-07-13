# feat: parallelize the analyze step across changed files (#902)

## Summary

The step-11 analyze family runs serially over changed files. This adds an
`analyze_parallelism` config key (default 1) so large diffs analyze concurrently.
When set > 1, `scripts/analyze.sh` fans the per-file shellcheck/cmake invocations
out over that many workers.

## Changes

- `scripts/analyze.sh`: read `analyze_parallelism` (default 1); when > 1, run the
  per-file analyzer pool with `xargs -P`.
- `scripts/lib/config.sh`: no change (generic getter already handles the key).

## Tests

- `tests/analyze.bats`: +2 cases (parallelism=1 serial unchanged; parallelism=3
  processes all files, count asserted).

## Evidence

suite: 1316 bats + 298 pytest
files: 2
