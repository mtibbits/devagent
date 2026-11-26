#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-impact"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-impact"
}

@test "core-impact passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-impact distinguishes quantifiable vs qualitative" {
  grep -qi 'quantif' "$SKILL/SKILL.md"
  grep -qi 'qualitat' "$SKILL/SKILL.md"
}

@test "core-impact writes to issue dir" {
  grep -q 'impact.md' "$SKILL/SKILL.md"
}

@test "core-impact fixture exists" {
  [ -s "$FIXT/issue.md" ]
  [ -s "$FIXT/actualWork.md" ]
  [ -s "$FIXT/checklist.md" ]
}

@test "core-impact step 6 runs cost-report with --project and --issue and records both line labels (#730)" {
  cmd="$(awk '/^6\. \*\*Workflow cost\.\*\*/ { f = 1 } f && /cost-report\.sh/ { print; exit }' "$SKILL/SKILL.md")"
  [ -n "$cmd" ]
  printf '%s\n' "$cmd" | grep -qF -- '--project <project>'
  printf '%s\n' "$cmd" | grep -qF -- '--issue <Issue-N>'
  grep -qF -- '- Workflow cost: <line>' "$SKILL/SKILL.md"
  grep -qF -- "- Workflow cost (unattributed to a project, may include other projects' work): <line>" "$SKILL/SKILL.md"
  grep -qF -- '(N transcript file(s) skipped; undercount)' "$SKILL/SKILL.md"
}

@test "core-impact step 6 passes --time and records the Workflow time line (#733)" {
  cmd="$(awk '/^6\. \*\*Workflow cost\.\*\*/ { f = 1 } f && /cost-report\.sh/ { print; exit }' "$SKILL/SKILL.md")"
  [ -n "$cmd" ]
  printf '%s\n' "$cmd" | grep -qF -- '--time'
  printf '%s\n' "$cmd" | grep -qF -- '--project <project>'
  printf '%s\n' "$cmd" | grep -qF -- '--issue <Issue-N>'
  grep -qF -- '- Workflow time: <time line> (<rule line>)' "$SKILL/SKILL.md"
  grep -qF -- '<project>/<Issue-N> time:' "$SKILL/SKILL.md"
  grep -qF -- 'time rule:' "$SKILL/SKILL.md"
  grep -qF -- "- Workflow time (unattributed to a project, may include other projects' work): <time line> (<rule line>)" "$SKILL/SKILL.md"
  grep -qF -- '- Workflow time: not measured' "$SKILL/SKILL.md"
}

@test "core-impact step 6 says per-issue cost excludes overhead and names --overhead (#732)" {
  x="$(awk '/^6\. \*\*Workflow cost\.\*\*/ { f = 1; print; next } f && (/^[0-9]+\. \*\*/ || /^## /) { exit } f { print }' "$SKILL/SKILL.md" | tr '\n' ' ' | tr -s ' ')"
  [ "${#x}" -ge 200 ]
  printf '%s\n' "$x" | grep -qF -- 'excludes overhead'
  printf '%s\n' "$x" | grep -qF -- 'cost-report.sh --overhead --project <project> --summary'
}

# #738: item 7 sets the plan's estimate beside step 6's actuals.
_item7() {
  awk '/^7\. \*\*Estimate vs actual\.\*\*/ { f = 1; print; next } f && (/^[0-9]+\. \*\*/ || /^## /) { exit } f { print }' "$SKILL/SKILL.md"
}
_norm() { tr '\n' ' ' | tr -s ' '; }
PE_FIX="$BATS_TEST_DIRNAME/fixtures/plan-estimate"
PE_NOTE='interim: actuals stop at the impact step and count only the transcripts cost-report read'

@test "core-impact item 7 runs plan-estimate --impact-line on the issue's plan (#738)" {
  cmd="$(_item7 | awk '/plan-estimate\.sh/ { print; exit }' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  # shellcheck disable=SC2016
  [ "$cmd" = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-estimate.sh" --impact-line "$ISSUE_DIR/imPlan.md"' ]
  dir="$BATS_TEST_TMPDIR/issue dir*"
  mkdir -p "$dir"
  cp "$PE_FIX/confirmed-changed.md" "$dir/imPlan.md"
  run env CLAUDE_PLUGIN_ROOT="$BATS_TEST_DIRNAME/.." ISSUE_DIR="$dir" bash -c "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "- Estimate vs actual (interim): agent time est 4-6h vs actual <agent wall>; tokens est 10-14M vs actual <cost> [estimate confirmed, changed from scope; $PE_NOTE]" ]
}

@test "core-impact item 7 names every printed form and the slot rule (#738)" {
  x="$(_item7 | _norm)"
  for s in '- Estimate vs actual (interim): no structured estimate' 'not measured (<reason>)' '<agent wall>' '<cost>' 'agent wall' 'input-token equivalents' 'unattributed'; do
    printf '%s\n' "$x" | grep -qF -- "$s" || { echo "missing: $s"; false; }
  done
}

@test "core-impact output example carries the comparison line the reader prints (#738)" {
  block="$(awk '/^## Output format/ { f = 1; next } f && /^## Halt and ask/ { exit } f' "$SKILL/SKILL.md" | _norm)"
  printf '%s\n' "$block" | grep -qF -- 'agent wall 2.41h'
  printf '%s\n' "$block" | grep -qF -- '12.4M input-token equivalents'
  line="$(bash "$BATS_TEST_DIRNAME/../scripts/plan-estimate.sh" --impact-line "$PE_FIX/confirmed-changed.md")"
  filled="${line/<agent wall>/agent wall 2.41h}"
  filled="${filled/<cost>/12.4M input-token equivalents}"
  printf '%s\n' "$block" | grep -qF -- "$filled" || { echo "missing filled line: $filled"; false; }
}

@test "core-impact item 7 records a failed reader as not measured (#738)" {
  x="$(_item7 | _norm)"
  for s in 'plan-estimate failed: exit <N>' 'Workflow cost not measured' 'Workflow time not measured'; do
    printf '%s\n' "$x" | grep -qF -- "$s" || { echo "missing: $s"; false; }
  done
}
