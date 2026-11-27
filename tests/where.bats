#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$DEVDOC/Issue-676"
EOF
  # Minimal checklist: step 2 done, step 3 in-progress
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
# Issue-676 — Workflow checklist

## Revision 1

- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [~]  5. improve
- [ ]  6. prune
- [ ]  7. tighten

## Log
- 2026-05-19 14:32  improve: started analyzing edge cases
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "where reports active issue, last step, next step" {
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project: volk"* ]]
  [[ "$output" == *"Active issue: Issue-676"* ]]
  [[ "$output" == *"Current step: 5 (improve) [~]"* ]]
  [[ "$output" == *"Next step: 6 (prune)"* ]]
  [[ "$output" == *"Run /devagent:next to execute"* ]]
}

@test "where prints idle banner when no active issue" {
  rm "$DA_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active issue"* ]]
}

@test "where surfaces STUCK file when present" {
  cat > "$DEVDOC/Issue-676/STUCK" <<'EOF'
Step: 5 improve
Reason: needs upstream API clarification
EOF
  # Mark step 3 as stuck
  sed -i 's/^- \[~\]  5\. improve/- [!]  5. improve/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"needs upstream API clarification"* ]]
  [[ "$output" == *"/devagent:unstuck"* ]]
}

@test "where reports parked issues" {
  cat >> "$DA_HOME/state/volk.toml" <<'EOF'

[parked]
"Issue-203"     = true
"Issue-Fork-12" = true
EOF
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parked:"* ]]
  [[ "$output" == *"Issue-203"* ]]
  [[ "$output" == *"Issue-Fork-12"* ]]
}

@test "where errors when project unknown" {
  run "$PLUGIN_ROOT/scripts/where.sh" nosuch
  [ "$status" -ne 0 ]
}

# --- #880: a STUCK [!] outside the active revision block ---------------------
# Revision 1's 5. improve carries [!]; Revision 2 (appended after ## Log) is active.
_older_stall() {
  local f="$DEVDOC/Issue-676/checklist.md"
  sed -i 's/^- \[~\]  5\. improve/- [!]  5. improve/' "$f"
  printf '%s\n' '' '## Revision 2' '' '- [x]  2. draft' '- [x]  4. scope' \
    '- [ ]  5. improve' '- [ ]  6. prune' >> "$f"
}

_where_stuck() {
  cat > "$DEVDOC/Issue-676/STUCK" <<'EOF2'
Step: 5 improve
Reason: needs upstream API clarification
EOF2
}

@test "#880 where shows the STUCK section for a [!] in an older revision block" {
  _older_stall; _where_stuck
  local bang
  bang="$(grep -nE '^- \[!\]' "$DEVDOC/Issue-676/checklist.md" | head -1 | cut -d: -f1)"
  [ -n "$bang" ]
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK:"* ]]
  [[ "$output" == *"  [!] step 5 (improve) at line $bang, Revision 1 (an older block; the active block is Revision 2)"* ]]
  [[ "$output" == *"needs upstream API clarification"* ]]
  [[ "$output" == *"Run /devagent:unstuck to clear."* ]]
  [[ "$output" != *"Next step:"* ]]
  [[ "$output" != *"Run /devagent:next"* ]]
}

@test "#880 where shows an older-block stall when the active block is complete" {
  _older_stall; _where_stuck
  sed -i -e 's/^- \[ \]  5\. improve/- [x]  5. improve/' -e 's/^- \[ \]  6\. prune/- [x]  6. prune/' \
    "$DEVDOC/Issue-676/checklist.md"
  local bang
  bang="$(grep -nE '^- \[!\]' "$DEVDOC/Issue-676/checklist.md" | head -1 | cut -d: -f1)"
  [ -n "$bang" ]
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"All steps complete."* ]]
  [[ "$output" == *"STUCK:"* ]]
  [[ "$output" == *"  [!] step 5 (improve) at line $bang, Revision 1 (an older block; the active block is Revision 2)"* ]]
  [[ "$output" == *"Run /devagent:unstuck to clear."* ]]
}

@test "#880 where without a STUCK file shows no STUCK section for an orphan older-block [!]" {
  # Preservation leg: green at HEAD by design.
  _older_stall
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"STUCK:"* ]]
  [[ "$output" == *"Next step:"* ]]
}

@test "#880 where on a completed issue with no stall prints All steps complete and exits 0" {
  # Preservation leg: green at HEAD by design (guards the done-branch call under set -e).
  sed -i -e 's/^- \[~\]  5\. improve/- [x]  5. improve/' -e 's/^- \[ \]  6\. prune/- [x]  6. prune/' \
    -e 's/^- \[ \]  7\. tighten/- [x]  7. tighten/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"All steps complete."* ]]
  [[ "$output" != *"STUCK:"* ]]
}

@test "#880 where shows no STUCK section for a question STUCK beside an orphan [!]" {
  # Preservation leg: a #962 question STUCK is a hold, not a stall unstuck clears.
  _older_stall
  printf 'Kind:        question\nStep:        5 improve\n\n' > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"STUCK:"* ]]
  [[ "$output" != *"/devagent:unstuck"* ]]
}
