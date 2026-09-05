#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  ISSUE_DIR="$DA_HOME/Issue-1"
  mkdir -p "$ISSUE_DIR"
}

teardown() { teardown_tmp_devagent_home; }

@test "checklist_init writes a checklist from the standard template" {
  checklist_init "$ISSUE_DIR" standard
  [ -f "$ISSUE_DIR/checklist.md" ]
  run grep -q '0. pull' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep -q '23. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  run grep -q '## Log' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist_init substitutes placeholders" {
  ISSUE_ID=Issue-42 checklist_init "$ISSUE_DIR" standard
  run head -1 "$ISSUE_DIR/checklist.md"
  [[ "$output" == *"Issue-42"* ]]
}

@test "checklist_init refuses unknown template" {
  run checklist_init "$ISSUE_DIR" no-such-template
  [ "$status" -ne 0 ]
}

@test "checklist_init dies when a project is passed without config.sh sourced" {
  # artifact.sh alone gets past the #120 guard (its own config_get calls are
  # ||-true-swallowed), so the mergetoall filter's guard is the one that must
  # fail loud instead of silently scaffolding row 19 skipped (redmr MINOR).
  source "$PLUGIN_ROOT/scripts/lib/artifact.sh"
  run checklist_init "$ISSUE_DIR" standard someproject
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.sh is not sourced"* ]]
}

@test "checklist_current_step is 0 on a fresh standard" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "checklist_step_name maps numbers to names" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_step_name "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "pull" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 9
  [ "$output" = "implement" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 23
  [ "$output" = "cleanup" ]
}

@test "checklist_mark flips a glyph" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

# --- checklist_steps_with_glyph (#313): mawk-safe glyph→number scan ---------
@test "checklist_steps_with_glyph lists step numbers for a glyph, in file order" {
  cat > "$ISSUE_DIR/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [~]  4. scope
- [ ]  5. improve
- [P] 16. redmr
- [!] 17. preship
EOF
  run checklist_steps_with_glyph "$ISSUE_DIR/checklist.md" x
  [ "$output" = "0
2" ]                                    # both [x] steps, in order
  run checklist_steps_with_glyph "$ISSUE_DIR/checklist.md" P
  [ "$output" = "16" ]                     # double-digit extracted correctly
  run checklist_steps_with_glyph "$ISSUE_DIR/checklist.md" '!'
  [ "$output" = "17" ]
  run checklist_steps_with_glyph "$ISSUE_DIR/checklist.md" Z
  [ -z "$output" ]                         # no such glyph → empty
}

@test "checklist_steps_with_glyph dies on a missing file" {
  run checklist_steps_with_glyph "$ISSUE_DIR/nope.md" x
  [ "$status" -ne 0 ]
}

@test "checklist_mark refuses an unknown glyph" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_mark "$ISSUE_DIR/checklist.md" 0 Q
  [ "$status" -ne 0 ]
}

@test "checklist_advance marks current done and returns new current" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_advance "$ISSUE_DIR/checklist.md"
  [ "$output" = "2" ]   # 1 research ships [-]; next actionable is 2 draft
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_current_step echoes 'done' when all done" {
  checklist_init "$ISSUE_DIR" docs-only
  # docs-only has 11 steps; mark them all done
  for s in 0 2 8 11 12 14 15 17 18 19 23; do
    checklist_mark "$ISSUE_DIR/checklist.md" "$s" x
  done
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "done" ]
}

@test "checklist_current_step skips x, returns first non-x" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  checklist_mark "$ISSUE_DIR/checklist.md" 2 x
  checklist_mark "$ISSUE_DIR/checklist.md" 4 '~'
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "4" ]
}

# --- #73: gawk-only 3-arg match() and unguarded mv ---

# Shim `awk` -> a chosen real interpreter so the checklist awk runs under it.
_shim_awk() {
  local impl="$1"
  SHIM_DIR="$BATS_TEST_TMPDIR/awkshim"
  mkdir -p "$SHIM_DIR"
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$impl" > "$SHIM_DIR/awk"
  chmod +x "$SHIM_DIR/awk"
}

@test "checklist_mark runs under mawk (no gawk-only 3-arg match)" {
  command -v mawk >/dev/null || skip "mawk not installed"
  checklist_init "$ISSUE_DIR" standard
  _shim_awk mawk
  PATH="$SHIM_DIR:$PATH" checklist_mark "$ISSUE_DIR/checklist.md" 9 '~'
  run checklist_step_state "$ISSUE_DIR/checklist.md" 9
  [ "$output" = "~" ]
}

@test "checklist_next_actionable runs under mawk (no gawk-only 3-arg match)" {
  command -v mawk >/dev/null || skip "mawk not installed"
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  _shim_awk mawk
  run env PATH="$SHIM_DIR:$PATH" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/checklist.sh'; checklist_next_actionable '$ISSUE_DIR/checklist.md'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "checklist_mark does not truncate the file when awk fails" {
  checklist_init "$ISSUE_DIR" standard
  local before
  before="$(cat "$ISSUE_DIR/checklist.md")"
  # awk shim that fails with empty output, simulating a parse error / ENOSPC.
  SHIM_DIR="$BATS_TEST_TMPDIR/awkshim"
  mkdir -p "$SHIM_DIR"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM_DIR/awk"
  chmod +x "$SHIM_DIR/awk"
  run env PATH="$SHIM_DIR:$PATH" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/checklist.sh'; checklist_mark '$ISSUE_DIR/checklist.md' 7 x"
  [ "$status" -ne 0 ]
  [ "$(cat "$ISSUE_DIR/checklist.md")" = "$before" ]
}

# --- #74: scope mark/read to the active `## Revision` block ---

# Append a second revision block reusing step numbers 2,4..23 (#558).
_append_rev2() {
  cat >> "$1" <<'EOF'

## Revision 2

- [ ]  2. draft
- [ ]  4. scope
- [ ]  9. implement
EOF
}

@test "checklist_mark scopes to the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  checklist_mark "$f" 9 x          # revision 1, step 9 -> done
  _append_rev2 "$f"
  checklist_mark "$f" 9 '~'        # must land in revision 2 only
  run grep -c '^- \[x\]  9\.' "$f"
  [ "$output" = "1" ]             # revision 1 still done
  run grep -c '^- \[~\]  9\.' "$f"
  [ "$output" = "1" ]             # revision 2 now in-progress
}

@test "checklist_step_state reads the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  checklist_mark "$f" 9 x
  _append_rev2 "$f"
  run checklist_step_state "$f" 9
  [ "$output" = " " ]             # revision 2's glyph, not revision 1's x
}

@test "checklist_current_step reflects the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  _append_rev2 "$f"
  checklist_mark "$f" 2 x         # rev 2 draft done
  run checklist_current_step "$f"
  [ "$output" = "4" ]            # first non-x in rev 2, not rev 1's step 0
}

@test "checklist_next_actionable reflects the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  _append_rev2 "$f"
  checklist_mark "$f" 2 x
  run checklist_next_actionable "$f"
  [ "$output" = "4" ]
}

@test "checklist_mark falls back to whole file for steps not in active revision" {
  checklist_init "$ISSUE_DIR" standard   # standard rev 1 carries all 24 rows (#558)
  local f="$ISSUE_DIR/checklist.md"
  _append_rev2 "$f"                       # rev 2 has only rows 2/4/9
  checklist_mark "$f" 23 x                # 23 lives only in revision 1
  run checklist_step_state "$f" 23
  [ "$output" = "x" ]
}

@test "checklist_step_state_by_name returns the glyph for a named step" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 22 x
  run checklist_step_state_by_name "$ISSUE_DIR/checklist.md" lessonslearned
  [ "$status" -eq 0 ]
  [ "$output" = "x" ]
}

@test "checklist_step_state_by_name returns non-zero for an absent step name" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_step_state_by_name "$ISSUE_DIR/checklist.md" nonexistentstep
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- #76: by-name gate helpers scope to the ACTIVE revision block -----------
# revision_block.md now reuses the closeout names 19-23 (#76/#558), so the #149/#242
# gates must read the active revision's copy, not revision 1's stale glyph.

_append_real_rev2() {   # append the SHIPPED revision_block.md (N=2) to $1
  local repo; repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  sed 's/{{N}}/2/' "$repo/templates/revision_block.md" >> "$1"
}

@test "the #242 gate reads the ACTIVE revision's closeout, not revision 1's stale copy (#76)" {
  checklist_init "$ISSUE_DIR" standard          # rev1 closeout still [ ] (MR open — why we revise)
  local f="$ISSUE_DIR/checklist.md"
  _append_real_rev2 "$f"
  checklist_mark "$f" 20 x                       # active=rev2 → rev2 closeout done
  checklist_mark "$f" 21 x
  checklist_mark "$f" 22 x
  # Gate must see rev2 (terminal) → empty, NOT rev1's pending copies.
  run checklist_nonterminal_by_names "$f" updatewbs impact lessonslearned
  [ -z "$output" ]
}

@test "the #242 gate FIRES on the active revision's own pending closeout, ignoring a done rev1 (#76)" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  checklist_mark "$f" 20 x                       # active=rev1 → rev1 closeout done
  checklist_mark "$f" 21 x
  checklist_mark "$f" 22 x
  _append_real_rev2 "$f"                          # rev2 closeout pending
  # Gate must report rev2's pending steps (not read rev1's done copy first).
  run checklist_nonterminal_by_names "$f" updatewbs impact lessonslearned
  [[ "$output" == *"updatewbs:[ ]"* ]]
  [[ "$output" == *"impact:[ ]"* ]]
  [[ "$output" == *"lessonslearned:[ ]"* ]]
}

@test "the #149 preship gate reads the active revision's preship (#76)" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  checklist_mark "$f" 17 x                       # rev1 preship done (as at ship time)
  _append_real_rev2 "$f"                          # rev2 preship pending
  run checklist_nonterminal_by_names "$f" preship
  [[ "$output" == *"preship:[ ]"* ]]              # gate fires on rev2, not rev1's [x]
}

# --- #242: checklist_nonterminal_by_names ----------------------------------

_seed_242() {
  checklist_init "$ISSUE_DIR" standard
  F="$ISSUE_DIR/checklist.md"
}

@test "checklist_nonterminal_by_names lists offenders with glyphs (#242)" {
  _seed_242
  checklist_mark "$F" 21 '~'
  checklist_mark "$F" 22 x
  run checklist_nonterminal_by_names "$F" updatewbs impact lessonslearned
  [ "$status" -eq 0 ]
  [[ "$output" == *"updatewbs:[ ]"* ]]
  [[ "$output" == *"impact:[~]"* ]]
  [[ "$output" != *lessonslearned* ]]
}

@test "checklist_nonterminal_by_names: [-] is terminal, absent is no-gate (#242)" {
  _seed_242
  sed -i '/20\. updatewbs/d' "$F"
  checklist_mark "$F" 21 -
  checklist_mark "$F" 22 x
  run checklist_nonterminal_by_names "$F" updatewbs impact lessonslearned
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "checklist_nonterminal_by_names: empty name list is empty output (#242)" {
  _seed_242
  run checklist_nonterminal_by_names "$F"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- checklist_find_glyph_line / _mark_line / _step_name_at_line (#587) -----
@test "checklist_find_glyph_line returns line:num for an old-block-only glyph" {
  cat > "$ISSUE_DIR/checklist.md" <<'EOC'
- [x]  0. pull
- [!]  2. draft

## Revision 2

- [ ]  2. draft
EOC
  run checklist_find_glyph_line "$ISSUE_DIR/checklist.md" '!'
  [ "$output" = "2:2" ]
}

@test "checklist_find_glyph_line prefers the ACTIVE revision block" {
  cat > "$ISSUE_DIR/checklist.md" <<'EOC'
- [!]  2. draft

## Revision 2

- [x]  2. draft
- [!] 23. cleanup
EOC
  run checklist_find_glyph_line "$ISSUE_DIR/checklist.md" '!'
  [ "$output" = "6:23" ]                # double-digit number survives
}

@test "checklist_find_glyph_line falls back file-wide with no revision headings" {
  printf '%s\n' '- [x]  0. pull' '- [P]  2. draft' > "$ISSUE_DIR/checklist.md"
  run checklist_find_glyph_line "$ISSUE_DIR/checklist.md" P
  [ "$output" = "2:2" ]
  run checklist_find_glyph_line "$ISSUE_DIR/checklist.md" '!'
  [ "$status" -eq 0 ]
  [ -z "$output" ]                      # absent glyph -> empty, rc 0
}

@test "checklist_find_glyph_line matches metacharacter glyphs literally" {
  # '?' and '.' are regex metacharacters; the glyph is compared as the column-4
  # CHARACTER, never interpolated into a pattern.
  printf '%s\n' '- [?]  4. scope' '- [x]  5. improve' > "$ISSUE_DIR/checklist.md"
  run checklist_find_glyph_line "$ISSUE_DIR/checklist.md" '?'
  [ "$output" = "1:4" ]
  run checklist_find_glyph_line "$ISSUE_DIR/checklist.md" '.'
  [ -z "$output" ]                      # '.' must NOT match '?' or 'x'
}

@test "checklist_mark_line marks the named line and nothing else" {
  cat > "$ISSUE_DIR/checklist.md" <<'EOC'
- [!]  2. draft

## Revision 2

- [ ]  2. draft
EOC
  checklist_mark_line "$ISSUE_DIR/checklist.md" 1 '~'
  run grep -cE '^- \[~\][[:space:]]+2\. draft' "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
  run grep -cE '^- \[ \][[:space:]]+2\. draft' "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
}

@test "checklist_mark_line refuses a non-step line and a bad glyph" {
  printf '%s\n' '## Log' '- [ ]  2. draft' > "$ISSUE_DIR/checklist.md"
  run checklist_mark_line "$ISSUE_DIR/checklist.md" 1 '~'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a checklist step row"* ]]
  run checklist_mark_line "$ISSUE_DIR/checklist.md" 2 Q
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad glyph"* ]]
  grep -qE '^- \[ \][[:space:]]+2\. draft' "$ISSUE_DIR/checklist.md"   # unchanged
}

@test "checklist_step_name_at_line reads the name off any glyph, and refuses a non-row" {
  printf '%s\n' '## Log' '- [P] 23. cleanup' > "$ISSUE_DIR/checklist.md"
  run checklist_step_name_at_line "$ISSUE_DIR/checklist.md" 2
  [ "$output" = "cleanup" ]
  run checklist_step_name_at_line "$ISSUE_DIR/checklist.md" 1
  [ "$status" -ne 0 ]
  # Pin the MESSAGE, not just the rc. A bare `-ne 0` is satisfied by a missing
  # function's 127 (Issue-572) and by any unrelated failure (Issue-Fork-132),
  # so the refusal must be attributable to THIS path. The helper emits this
  # token on stderr (never stdout — Issue-583) before returning 1.
  [[ "$output" == *"not a checklist step row"* ]]
}

# --- #589: the WRITERS fail closed; the resolvers keep their 0=file-wide contract
@test "checklist_mark dies on a name-less mark of a number absent from the active revision (#589)" {
  # G1/AC1. At the unfixed baseline this returns 0 and flips revision 1's row.
  cat > "$ISSUE_DIR/checklist.md" <<'EOC'
## Revision 1

- [ ]  0. pull
- [ ] 23. cleanup

## Revision 2

- [ ]  2. draft
EOC
  run checklist_mark "$ISSUE_DIR/checklist.md" 23 x
  [ "$status" -ne 0 ]
  # Pin the MESSAGE, not the bare rc: a negative assertion is vacuously satisfied
  # by a missing function's 127 (Issue-572) and by any unrelated failure
  # (Issue-Fork-132). The token lives on STDERR (Issue-583).
  [[ "$output" == *"refusing a name-less mark"* ]]
  # ... and the remedy the message names must be the one that works (lawFirm
  # Issue-8: a refusal naming a call that cannot recover is as bad as naming none).
  [[ "$output" == *"4th argument"* ]]
  [[ "$output" == *"--by-name"* ]]
  # Assert the DELTA, not mere absence of an [x] (Issue-318): the rev-1 row is
  # still exactly as the fixture wrote it, and NO row anywhere took the glyph.
  run grep -cE '^- \[x\]' "$ISSUE_DIR/checklist.md"
  [ "$output" = "0" ]
  grep -qE '^- \[ \] 23\. cleanup' "$ISSUE_DIR/checklist.md"
}

@test "checklist_mark: the refused mark succeeds via the remedies the message names (#589)" {
  # Execute the diagnostic's own instructions end to end and assert the RECOVERED
  # state (lawFirm Issue-8). Two remedies, one test, because they are one claim.
  cat > "$ISSUE_DIR/checklist.md" <<'EOC'
## Revision 1

- [ ] 23. cleanup

## Revision 2

- [ ]  2. draft
EOC
  # Remedy 1: pass the step name as the 4th argument.
  checklist_mark "$ISSUE_DIR/checklist.md" 23 x cleanup
  grep -qE '^- \[x\] 23\. cleanup' "$ISSUE_DIR/checklist.md"
  # Remedy 2: mark by NAME.
  checklist_mark_by_name "$ISSUE_DIR/checklist.md" cleanup '~'
  grep -qE '^- \[~\] 23\. cleanup' "$ISSUE_DIR/checklist.md"
}

@test "checklist_mark: a number absent EVERYWHERE still dies not-found, not with the #589 message (#589)" {
  # The #589 predicate (start == 0 && active > 0) is also true for a typo: a
  # number NO block carries. That case must keep the pre-existing `not found`
  # die, because a diagnostic must never assert a row that does not exist
  # (Issue-Fork-225; improve 2026-09-05, Bugs item 2).
  cat > "$ISSUE_DIR/checklist.md" <<'EOC'
## Revision 1

- [ ] 23. cleanup

## Revision 2

- [ ]  2. draft
EOC
  run checklist_mark "$ISSUE_DIR/checklist.md" 99 x
  [ "$status" -ne 0 ]
  [[ "$output" == *"step 99 not found"* ]]
  [[ "$output" != *"refusing a name-less mark"* ]]
  run grep -cE '^- \[x\]' "$ISSUE_DIR/checklist.md"
  [ "$output" = "0" ]
}
