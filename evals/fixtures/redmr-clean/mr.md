# fix: doctor mislabels an empty devdoc_dir as a fatal error (#903)

## Summary

`/devagent:doctor` reports a missing-but-optional `devdoc_dir` as FAIL when the
directory simply hasn't been created yet. It should report WARN (advisory) and
only FAIL when the path exists but is not writable. One-line predicate fix in
`scripts/doctor.sh`; no config keys, commands, hooks, or directories added.

## Changes

- `scripts/doctor.sh`: the `devdoc_dir` check distinguishes "absent" (WARN) from
  "present-but-unwritable" (FAIL). No other behavior changes.

## Tests

- `tests/doctor.bats`: +2 cases — absent dir → WARN + rc 0; unwritable dir →
  FAIL + rc 1. The FAIL case is mutation-proven RED against the current predicate.

## Evidence

suite: 1316 bats + 298 pytest
files: 2
