#!/usr/bin/env bats
# #116: commit (12) before analyze (13) — canonical order + doctrine.
#
# Decision: spec §6.3/§11/§18 order commit → analyze. The checklist templates
# carried an 11-before-10 swap plus "Do NOT commit yet" doctrine in five
# command files, which contradicted the spec and implement.md's own per-task
# commits, and ran the analyze gate against an uncommitted tree — a vacuous
# pass until #276 hardened the analyzer. These tests lock the restored order
# and the reworded doctrine.

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

REPO="${BATS_TEST_DIRNAME}/.."

# Line number of a step entry in a checklist template (empty if absent).
_step_line() { grep -n "^- \[ \] *$2\." "$1" | head -1 | cut -d: -f1; }

# Both steps present AND commit (12) on an earlier line than analyze (13).
_assert_commit_before_analyze() {
  local c a; c="$(_step_line "$1" 10)"; a="$(_step_line "$1" 11)"
  [ -n "$c" ] && [ -n "$a" ] && [ "$c" -lt "$a" ]
}

@test "checklist-standard.md orders commit (12) before analyze (13) (#116)" {
  _assert_commit_before_analyze "$REPO/templates/checklist-standard.md"
}

@test "checklist-perf.md orders commit (12) before analyze (13) (#116)" {
  _assert_commit_before_analyze "$REPO/templates/checklist-perf.md"
}

@test "revision_block.md keeps commit (12) before analyze (13) (#116 regression lock)" {
  _assert_commit_before_analyze "$REPO/templates/revision_block.md"
}

# NB: tests 4-5 are canaries pinning the OLD wording only — a fresh rewording
# of analyze-before-commit doctrine would pass them. The structural invariant
# is carried by the line-order tests above plus the commit.bats #116 cases.
@test "no command file claims analyze-before-commit doctrine (#116)" {
  # Old blocks asserted: 'The commit step (10) follows analyze (13)',
  # 'finally commit (12)', 'defers commit until AFTER static analysis';
  # review.md quoted the 'Do NOT commit yet' rule by name.
  run grep -rlE 'commit step \(10\) follows analyze|finally commit \(10\)|defers commit until AFTER static analysis|Do NOT commit yet' "$REPO/commands"
  [ -z "$output" ]
}

@test "implement.md keeps per-task commit discipline (#116)" {
  grep -q 'own commit' "$REPO/commands/implement.md"
}
