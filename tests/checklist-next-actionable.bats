#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  F="$BATS_TEST_TMPDIR/c.md"
  cat > "$F" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [~]  2. scope
- [ ]  3. improve
- [-]  4. prune
- [ ]  5. tighten
EOF
}

@test "after step 2, next actionable is 3" {
  run checklist_next_actionable "$F" 2
  [ "$output" = "3" ]
}
@test "after step 3, skips [-] and returns 5" {
  run checklist_next_actionable "$F" 3
  [ "$output" = "5" ]
}
@test "after step 5, returns empty" {
  run checklist_next_actionable "$F" 5
  [ -z "$output" ]
}

@test "follows file order not step number: after 11 (listed before 10) returns 10 [#77]" {
  # The pre-#116 11-before-10 layout (analyze before commit), still live in
  # checklists cut before the reorder. The next
  # actionable after 11 is 10 on the NEXT line — not 12, which a step-number
  # comparison (n > 11) would wrongly pick while silently skipping commit.
  cat > "$F" <<'EOF'
- [x]  9. document
- [ ] 11. analyze
- [ ] 10. commit
- [ ] 12. draftmr
EOF
  run checklist_next_actionable "$F" 11
  [ "$output" = "10" ]
}
