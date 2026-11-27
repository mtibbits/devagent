#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-scope"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-scope"
}

@test "core-scope passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-scope SKILL.md lists all 6 scope questions" {
  for q in "scope" "out of scope" "size" "ambiguity" "preconditions" "success"; do
    grep -qi "$q" "$SKILL/SKILL.md" || { echo "missing question: $q"; false; }
  done
}

@test "core-scope appends to Scope evaluation section" {
  grep -qE 'Scope evaluation' "$SKILL/SKILL.md"
}

@test "core-scope fixture: imPlan.md present" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/issue.md" ]
  [ -s "$FIXT/checklist.md" ]
}

# #738: the structured estimate line scope writes, read back by plan-estimate.sh.
_scope_size_block() {
  awk '/^## Output format/ { f = 1; next } f && /^## Halt and ask/ { exit } f' "$SKILL/SKILL.md" \
    | awk '/^### Size estimate/ { g = 1; next } g && /^###/ { exit } g && NF { print }'
}

@test "core-scope output block carries one Estimate (scope) line under Size estimate (#738)" {
  got="$(_scope_size_block)"
  want="$(printf '%s\n%s' '- ~XXX LOC across N files; ~Y hours.' '- Estimate (scope): {est: <agent time>, tok: <tokens>}')"
  [ "$got" = "$want" ]
}

@test "core-scope Size question defines the estimate's units and span (#738)" {
  x="$(awk '/^3\. \*\*Size\.\*\*/ { f = 1; print; next } f && (/^[0-9]+\. \*\*/ || /^## /) { exit } f { print }' "$SKILL/SKILL.md" | tr '\n' ' ' | tr -s ' ')"
  for s in 'agent wall' 'input-token equivalents' 'pull to cleanup' 'low-high' '300 LOC' 'Estimate (scope)'; do
    printf '%s\n' "$x" | grep -qF -- "$s" || { echo "missing: $s"; false; }
  done
}

@test "core-scope's estimate line is one plan-estimate reads (#738)" {
  plan="$BATS_TEST_TMPDIR/imPlan.md"
  { echo '### Size estimate'; _scope_size_block | sed -e 's/<agent time>/3-5h/' -e 's/<tokens>/8-12M/'; } > "$plan"
  run bash "$BATS_TEST_DIRNAME/../scripts/plan-estimate.sh" --json "$plan"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert (r["status"], r["source"]) == ("present", "scope"), r; assert (r["est"]["class"], r["est"]["low"], r["est"]["high"]) == ("time", 3, 5), r; assert r["tok"]["class"] == "tokens", r'
  grep -v 'Estimate (scope)' "$plan" > "$plan.bare"
  run bash "$BATS_TEST_DIRNAME/../scripts/plan-estimate.sh" --json "$plan.bare"
  [ "$status" -eq 1 ]
}
