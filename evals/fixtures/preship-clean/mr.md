# fix: checklist-mark rejects an out-of-range step number (#905)

## Summary

`checklist-mark.sh` now greps for the target step line and dies before the sed
write when the step number is absent from the checklist, closing the silent
no-op on a typo like `mark 99 x`. The guard runs BEFORE the sed per the review
finding. Valid step numbers mark exactly as before.

## Changes

- `scripts/checklist-mark.sh`: presence guard (`grep '^- \[.\] *<N>\.'`) with a
  die-on-no-match placed before the sed mark write.

## Tests

- `tests/checklist-mark.bats`: +2 cases — absent step dies (mutation-proven RED);
  valid step still marks.

## Evidence

suite: 1316 bats + 298 pytest
files: 2
