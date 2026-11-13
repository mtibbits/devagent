#!/usr/bin/env bats
# Issue-989: the starter checklist tier (docs-only plus implement, row 9).

load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; }
teardown() { teardown_tmp_devagent_home; }

STARTER_ROWS='0 2 8 9 11 12 14 15 17 18 19 20 24'

# Row numbers of a checklist file, in file order, space-joined.
_row_nums() {
  grep -E '^- \[.\] +[0-9]+\.' "$1" | sed -E 's/^- \[.\] +([0-9]+)\..*/\1/' | tr '\n' ' ' | sed 's/ $//'
}

# --- Task 2: template shape ---------------------------------------------------

@test "checklist-starter carries exactly rows 0/2/8/9/11/12/14/15/17/18/19/20/24 (#989)" {
  tpl="$PLUGIN_ROOT/templates/checklist-starter.md"
  [ -f "$tpl" ]
  [ "$(grep -cE '^- \[.\] +[0-9]+\.' "$tpl")" -eq 13 ]
  [ "$(_row_nums "$tpl")" = "$STARTER_ROWS" ]
  grep -qE '^- \[-\] 19\. mergetoall$' "$tpl"
  [ "$(grep -cE '^- \[ \] +[0-9]+\.' "$tpl")" -eq 12 ]
}

@test "starter is docs-only plus implement (9) (#989)" {
  tpl="$PLUGIN_ROOT/templates/checklist-starter.md"
  derived="$BATS_TEST_TMPDIR/derived.md"
  grep -vxF -- '- [ ]  9. implement' "$tpl" \
    | sed 's/^Template: starter$/Template: docs-only/' > "$derived"
  if ! cmp -s "$derived" "$PLUGIN_ROOT/templates/checklist-docs-only.md"; then
    echo "checklist-starter.md must equal checklist-docs-only.md plus row 9; update both together" >&2
    return 1
  fi
}

@test "starter is §12-resolvable through checklist_init (#989)" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  d="$BATS_TEST_TMPDIR/issue"
  mkdir -p "$d"
  ISSUE_ID="Issue-999" checklist_init "$d" starter
  grep -q '^Template: starter$' "$d/checklist.md"
}

# --- Task 3: spec tier table ---------------------------------------------------

@test "spec tier table carries the starter row beside the reserved simple row (#989)" {
  spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
  [ "$(grep -cE '^\| starter \| 0, 2, 8, 9, 11, 12, 14, 15, 17, 18, 19, 20, 24 \|' "$spec")" -eq 1 ]
  next="$(grep -A1 -E '^\| starter \| ' "$spec" | sed -n 2p)"
  [[ "$next" == '| simple | RESERVED'* ]]
}

# --- Task 4: spec §12 registry ---------------------------------------------------

@test "spec §12 registry carries checklist-starter (#989)" {
  spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"
  grep -qE '^\| `checklist-starter` \| checklist-init' "$spec"
}
