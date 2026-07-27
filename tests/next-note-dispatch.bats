#!/usr/bin/env bats
# next.sh note passing (#123).
#
# Notes given to /devagent:next via `-- <note>` must reach the dispatched
# workflow script through the NOTE *environment* variable — never appended as a
# positional `-- <note>`. The workflow scripts (branch/commit/ship/...) read
# $2 as the issue arg and do NOT source the §6.1 `--` parser, so a positional
# `--` corrupts the issue (e.g. branch.sh builds feat/---<slug>) and the note
# is silently dropped.
#
# Load-bearing: dispatches the REAL branch.sh and checks both the created
# branch name (proves `--` did not land in $2) and the NOTE log suffix
# (proves NOTE reached the script's environment).

load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

# Make `branch` (step 8) the current actionable step and give branch.sh the
# marker files it needs.
_seed_branch_current() {
  echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
  echo "note passing" > "$DEVDOC_DIR/Issue-1/.devagent-title"
  cat > "$DEVDOC_DIR/Issue-1/checklist.md" <<'EOF'
# Issue-1 — Workflow checklist

## Revision 1

- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [x]  5. improve
- [x]  6. prune
- [x]  7. tighten
- [ ]  8. branch

## Log
- 2026-05-19 14:00  pull: fixture seed
EOF
}

@test "next.sh passes the note via NOTE env, not as a positional issue arg (#123)" {
  _seed_branch_current
  run "$DEVAGENT_ROOT/scripts/next.sh" "$TEST_PROJECT" -- "tail-loop note"
  [ "$status" -eq 0 ]
  # Branch was cut for issue 1 — proves the `--` separator did NOT become
  # branch.sh's $2 (the pre-fix bug produced feat/---note-passing).
  ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "feat/1-note-passing"
  # The note reached branch.sh's environment → log_append's NOTE suffix present.
  grep -q 'branch: created .* — tail-loop note' "$DEVDOC_DIR/Issue-1/checklist.md"
}
