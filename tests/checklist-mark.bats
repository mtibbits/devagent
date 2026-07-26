#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  ISSUE_DIR="$DA_HOME/Issue-1"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
}
teardown() { teardown_tmp_devagent_home; }

@test "mark sets a glyph" {
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 9 '~'
  [ "$status" -eq 0 ]
  run grep -E '^- \[~\]  9\. implement' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "mark refuses an invalid glyph" {
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 9 Q
  [ "$status" -ne 0 ]
}

@test "mark preserves the checklist file mode (#329)" {
  # A same-dir temp still comes from mktemp at 0600; without the mode-preserve the
  # mv resets the target. Born-red at 0644 (real checklists are 0600 and can't
  # distinguish the fix).
  chmod 644 "$ISSUE_DIR/checklist.md"
  run "$PLUGIN_ROOT/scripts/checklist-mark.sh" "$ISSUE_DIR" 7 x
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$ISSUE_DIR/checklist.md")" = "644" ]
}

@test "checklist-mark: --by-name targets the active revision block, not an aliased number (#558)" {
    local d="$BATS_TEST_TMPDIR/Issue-999"; mkdir -p "$d"
    cat > "$d/checklist.md" <<'CKEOF'
# Issue-999 — Workflow checklist

## Revision 1

- [x]  0. pull
- [ ]  1. draft
- [ ]  3. improve

## Revision 2

- [ ]  2. draft
- [ ]  5. improve
CKEOF
    run bash "$PLUGIN_ROOT/scripts/checklist-mark.sh" --by-name "$d" draft x
    [ "$status" -eq 0 ]
    grep -qE '^- \[x\]  2\. draft' "$d/checklist.md"
    # revision 1's draft must be UNTOUCHED — assert the delta, not mere presence (#318)
    grep -qE '^- \[ \]  1\. draft' "$d/checklist.md"
}

@test "checklist-mark: --by-name rejects an unknown step name (#558)" {
    local d="$BATS_TEST_TMPDIR/Issue-998"; mkdir -p "$d"
    printf '## Revision 1\n\n- [ ]  0. pull\n' > "$d/checklist.md"
    run bash "$PLUGIN_ROOT/scripts/checklist-mark.sh" --by-name "$d" nosuchstep x
    [ "$status" -ne 0 ]
}
