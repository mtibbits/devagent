# feat: ship.sh refuses to push a dirty tree (#904)

## Summary

Adds a hard gate to `ship.sh`: before push, `git status --porcelain` is checked
and the script dies if any tracked file is modified. Handles both staged and
unstaged modifications per the review finding, so a `git add`ed-but-uncommitted
fix can no longer slip past. Untracked-only trees still push.

## Changes

- `scripts/ship.sh`: dirty-tree gate before push; matches modifications in either
  status column (staged or unstaged), per the BLOCKING review finding.

## Tests

- `tests/ship.bats`: +2 cases — modified tracked file dies; untracked-only pushes.

## Evidence

suite: 1316 bats + 298 pytest
files: 2
