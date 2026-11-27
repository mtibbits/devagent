#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/core-tighten"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-tighten"
}

@test "core-tighten passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "core-tighten covers ordering, dependencies, file paths, test plan" {
  for k in 'ordering' 'dependenc' 'file path' 'test plan'; do
    grep -qi "$k" "$SKILL/SKILL.md" || { echo "missing: $k"; false; }
  done
}

@test "core-tighten fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/imPlan-potentialFutureEnhancements.md" ]
  [ -s "$FIXT/checklist.md" ]
}

# #738: tighten confirms the scope estimate with a marked line directly below it.
_tighten_size_block() {
  awk '/^## Output format/ { f = 1; next } f && /^## Halt and ask/ { exit } f' "$SKILL/SKILL.md" \
    | awk '/^### Size estimate/ { g = 1; next } g && /^(###|```)/ { exit } g && NF { print }'
}

@test "core-tighten has a Confirm the estimate item that always writes the confirmed line (#738)" {
  x="$(awk '/^[0-9]+\. \*\*Confirm the estimate\.\*\*/ { f = 1; print; next } f && (/^[0-9]+\. \*\*/ || /^## /) { exit } f { print }' "$SKILL/SKILL.md" | tr '\n' ' ' | tr -s ' ')"
  [ -n "$x" ]
  for s in '- Estimate (confirmed): {est: <agent time>, tok: <tokens>}' 'Estimate (scope)' 'directly below' 'Always write it'; do
    printf '%s\n' "$x" | grep -qF -- "$s" || { echo "missing: $s"; false; }
  done
}

@test "core-tighten output block shows the confirmed line directly below the scope line (#738)" {
  got="$(_tighten_size_block | awk 'p { print; exit } $0 == "- Estimate (scope): {est: <agent time>, tok: <tokens>}" { p = 1 }')"
  [ "$got" = '- Estimate (confirmed): {est: <agent time>, tok: <tokens>}' ]
}

@test "core-tighten's confirmed line is one plan-estimate reads (#738)" {
  plan="$BATS_TEST_TMPDIR/imPlan.md"
  { echo '### Size estimate'; _tighten_size_block | sed -e 's/<agent time>/3-5h/' -e 's/<tokens>/8-12M/'; } > "$plan"
  run bash "$BATS_TEST_DIRNAME/../scripts/plan-estimate.sh" --json "$plan"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert (r["status"], r["source"], r["changed"]) == ("present", "confirmed", False), r'
}
