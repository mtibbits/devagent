#!/usr/bin/env bats
# #116: commit (10) before analyze (11) — canonical order + doctrine.
#
# Decision: spec §6.3/§11/§18 order commit → analyze. The checklist templates
# carried an 11-before-10 swap plus "Do NOT commit yet" doctrine in five
# command files, which contradicted the spec and implement.md's own per-task
# commits, and ran the analyze gate against an uncommitted tree — a vacuous
# pass until #276 hardened the analyzer. These tests lock the restored order
# and the reworded doctrine.

REPO="${BATS_TEST_DIRNAME}/.."

# Line number of a step entry in a checklist template (empty if absent).
_step_line() { grep -n "^- \[ \] *$2\." "$1" | head -1 | cut -d: -f1; }

@test "checklist-standard.md orders commit (10) before analyze (11) (#116)" {
  local t="$REPO/templates/checklist-standard.md"
  local c a; c="$(_step_line "$t" 10)"; a="$(_step_line "$t" 11)"
  [ -n "$c" ]; [ -n "$a" ]
  [ "$c" -lt "$a" ]
}

@test "checklist-perf.md orders commit (10) before analyze (11) (#116)" {
  local t="$REPO/templates/checklist-perf.md"
  local c a; c="$(_step_line "$t" 10)"; a="$(_step_line "$t" 11)"
  [ -n "$c" ]; [ -n "$a" ]
  [ "$c" -lt "$a" ]
}

@test "revision_block.md keeps commit (10) before analyze (11) (#116 regression lock)" {
  local t="$REPO/templates/revision_block.md"
  local c a; c="$(_step_line "$t" 10)"; a="$(_step_line "$t" 11)"
  [ -n "$c" ]; [ -n "$a" ]
  [ "$c" -lt "$a" ]
}

@test "no command file claims analyze-before-commit doctrine (#116)" {
  # Old blocks asserted: 'The commit step (10) follows analyze (11)',
  # 'finally commit (10)', 'defers commit until AFTER static analysis';
  # review.md quoted the 'Do NOT commit yet' rule by name.
  run grep -rlE 'commit step \(10\) follows analyze|finally commit \(10\)|defers commit until AFTER static analysis|Do NOT commit yet' "$REPO/commands"
  [ -z "$output" ]
}

@test "implement.md keeps per-task commit discipline (#116)" {
  grep -q 'own commit' "$REPO/commands/implement.md"
}
