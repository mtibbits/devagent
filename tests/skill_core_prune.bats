#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-prune"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-prune"
  CMD="$BATS_TEST_DIRNAME/../commands/prune.md"
}

# Section body from "## <heading>" to the next "## ", joined to one line.
section() { awk -v h="## $2" '$0==h{f=1;next} /^## /{f=0} f' "$1" | tr '\n' ' ' | tr -s ' '; }
# The one-task exception paragraph inside Skipping policy: from "Exception:" to the next blank line, joined.
exception() { awk '/^## Skipping policy$/{s=1} s&&/Exception:/{f=1} f&&/^[[:space:]]*$/{exit} f' "$1" | tr '\n' ' ' | tr -s ' '; }

@test "core-prune passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-prune mentions potentialFutureEnhancements file" {
  grep -q 'imPlan-potentialFutureEnhancements.md' "$SKILL/SKILL.md"
}

@test "core-prune fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "core-prune no longer halts on fewer than 2 tasks" {
  run grep -c 'fewer than 2 tasks' "$SKILL/SKILL.md"
  [ "$status" -eq 1 ]
  [ "$output" = 0 ]
}

@test "core-prune names the one-task skip log string and still has a Halt section" {
  grep -qF 'nothing to prune: one-task plan' "$SKILL/SKILL.md"
  grep -qE '^##[[:space:]]+Halt' "$SKILL/SKILL.md"
}

@test "core-prune one-task exception states its conditions and the [-] mark" {
  s=$(exception "$SKILL/SKILL.md")
  [ -n "$s" ]
  [[ "$s" == *"exactly one task"* ]]
  [[ "$s" == *"[defer]"* ]]
  [[ "$s" == *"Out of scope"* ]]
  [[ "$s" == *'$NOTE'* ]]
  [[ "$s" == *"empty"* ]]
  [[ "$s" == *"[-]"* ]]
  [[ "$s" == *'has no `[defer]`'* ]]
  [[ "$s" == *"create it empty if it is absent, because tighten requires the file"* ]]
  [[ "$s" == *'non-empty `$NOTE`'* ]]
  p=$(section "$SKILL/SKILL.md" 'Skipping policy')
  [ -n "$p" ]
  [[ "$p" == *"Exception:"* ]]
  [[ "$p" == *"Never auto-skip a plan of two or more tasks"* ]]
}

@test "core-prune prunes a one-task plan that carries a [defer] item and marks it [x]" {
  s=$(exception "$SKILL/SKILL.md")
  [[ "$s" == *"[defer]"* ]]
  [[ "$s" == *"[x]"* ]]
  [[ "$s" == *"not skipped"* ]]
}

@test "prune.md Skipping policy names the one-task exception" {
  s=$(section "$CMD" 'Skipping policy')
  [ -n "$s" ]
  [[ "$s" == *"exactly one task"* ]]
  [[ "$s" == *"[defer]"* ]]
  [[ "$s" == *"Out of scope"* ]]
  [[ "$s" == *"nothing to prune: one-task plan"* ]]
  [[ "$s" == *"[-]"* ]]
  [[ "$s" == *"[x]"* ]]
  [[ "$s" == *'$NOTE'* ]]
  [[ "$s" == *'non-empty `$NOTE`'* ]]
  [[ "$s" == *"Never auto-skip a plan of two or more tasks"* ]]
}

@test "core-prune keeps the zero-task halts" {
  grep -qF 'fewer than 1 task remains' "$SKILL/SKILL.md"
  grep -qF 'zero tasks, halt' "$SKILL/SKILL.md"
  grep -qF 'no tasks remain' "$CMD"
}
