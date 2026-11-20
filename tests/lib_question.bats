#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/lib_question.bats — #962: the STUCK kind reader (stuck_kind in
# scripts/lib/checklist.sh) and the question library
# (scripts/lib/question-actions.sh): grammar, renderer, number, open-record
# finder, lock, no-clobber publish and the option-tag registry.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  D="$BATS_TEST_TMPDIR/Issue-7"
  mkdir -p "$D"
}
teardown() { teardown_tmp_devagent_home; }

# ---- stuck_kind (Task 1) ----

@test "kind: prints none when there is no STUCK" {
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "kind: a STUCK with no Kind line reads stuck" {
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$D"
  "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$D" "needs help" >/dev/null
  [ -f "$D/STUCK" ]
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = stuck ]
}

@test "kind: question, watchdog and an unknown value print as written" {
  local n=0 k
  for k in question watchdog frobnicate; do
    printf 'Kind:        %s\nStep:        5 improve\n' "$k" > "$D/STUCK"
    run stuck_kind "$D"
    [ "$status" -eq 0 ]
    [ "$output" = "$k" ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "kind: a Kind line after the first blank line or a heading is ignored" {
  printf 'Step:        5 improve\n\nKind:        question\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$output" = stuck ]
  printf 'Step:        5 improve\n## Question\nKind:        question\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$output" = stuck ]
}

@test "kind: a CRLF STUCK reads the same as LF" {
  printf 'Kind:        question\r\nStep:        5 improve\r\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = question ]
}

@test "kind: an empty Kind value and a STUCK that is a directory read stuck" {
  printf 'Kind:   \nStep:        5 improve\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = stuck ]
  rm -f "$D/STUCK"; mkdir "$D/STUCK"
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = stuck ]
}
