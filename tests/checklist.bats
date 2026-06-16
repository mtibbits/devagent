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
  run grep -q '20. cleanup' "$ISSUE_DIR/checklist.md"
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
  run checklist_step_name "$ISSUE_DIR/checklist.md" 7
  [ "$output" = "implement" ]
  run checklist_step_name "$ISSUE_DIR/checklist.md" 20
  [ "$output" = "cleanup" ]
}

@test "checklist_mark flips a glyph" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_mark refuses an unknown glyph" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_mark "$ISSUE_DIR/checklist.md" 0 Q
  [ "$status" -ne 0 ]
}

@test "checklist_advance marks current done and returns new current" {
  checklist_init "$ISSUE_DIR" standard
  run checklist_advance "$ISSUE_DIR/checklist.md"
  [ "$output" = "1" ]
  run checklist_step_state "$ISSUE_DIR/checklist.md" 0
  [ "$output" = "x" ]
}

@test "checklist_current_step echoes 'done' when all done" {
  checklist_init "$ISSUE_DIR" docs-only
  # docs-only has 10 steps; mark them all done
  for s in 0 1 6 9 10 12 13 15 16 20; do
    checklist_mark "$ISSUE_DIR/checklist.md" "$s" x
  done
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "done" ]
}

@test "checklist_current_step skips x, returns first non-x" {
  checklist_init "$ISSUE_DIR" standard
  checklist_mark "$ISSUE_DIR/checklist.md" 0 x
  checklist_mark "$ISSUE_DIR/checklist.md" 1 x
  checklist_mark "$ISSUE_DIR/checklist.md" 2 '~'
  run checklist_current_step "$ISSUE_DIR/checklist.md"
  [ "$output" = "2" ]
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
  PATH="$SHIM_DIR:$PATH" checklist_mark "$ISSUE_DIR/checklist.md" 7 '~'
  run checklist_step_state "$ISSUE_DIR/checklist.md" 7
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
  [ "$output" = "1" ]
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

# Append a second revision block reusing step numbers 1-15.
_append_rev2() {
  cat >> "$1" <<'EOF'

## Revision 2

- [ ]  1. draft
- [ ]  2. scope
- [ ]  7. implement
EOF
}

@test "checklist_mark scopes to the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  checklist_mark "$f" 7 x          # revision 1, step 7 -> done
  _append_rev2 "$f"
  checklist_mark "$f" 7 '~'        # must land in revision 2 only
  run grep -c '^- \[x\]  7\.' "$f"
  [ "$output" = "1" ]             # revision 1 still done
  run grep -c '^- \[~\]  7\.' "$f"
  [ "$output" = "1" ]             # revision 2 now in-progress
}

@test "checklist_step_state reads the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  checklist_mark "$f" 7 x
  _append_rev2 "$f"
  run checklist_step_state "$f" 7
  [ "$output" = " " ]             # revision 2's glyph, not revision 1's x
}

@test "checklist_current_step reflects the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  _append_rev2 "$f"
  checklist_mark "$f" 1 x         # rev 2 step 1 done
  run checklist_current_step "$f"
  [ "$output" = "2" ]            # first non-x in rev 2, not rev 1's step 0
}

@test "checklist_next_actionable reflects the active revision block" {
  checklist_init "$ISSUE_DIR" standard
  local f="$ISSUE_DIR/checklist.md"
  _append_rev2 "$f"
  checklist_mark "$f" 1 x
  run checklist_next_actionable "$f"
  [ "$output" = "2" ]
}

@test "checklist_mark falls back to whole file for steps not in active revision" {
  checklist_init "$ISSUE_DIR" standard   # standard has steps 0..20 in rev 1
  local f="$ISSUE_DIR/checklist.md"
  _append_rev2 "$f"                       # rev 2 has only 1-15
  checklist_mark "$f" 20 x                # 20 lives only in revision 1
  run checklist_step_state "$f" 20
  [ "$output" = "x" ]
}
