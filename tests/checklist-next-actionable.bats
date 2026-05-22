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
