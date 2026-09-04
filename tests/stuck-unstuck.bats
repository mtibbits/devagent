#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  2. draft
- [ ]  4. scope
## Log
EOF
}

teardown() { teardown_tmp_devagent_home; }

@test "stuck marks current step [!] and writes STUCK file" {
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk "needs upstream API clarification"
  [ "$status" -eq 0 ]
  grep -E '^\- \[!\]  2\. draft' "$DEVDOC/Issue-676/checklist.md"
  [ -f "$DEVDOC/Issue-676/STUCK" ]
  grep -q "needs upstream API clarification" "$DEVDOC/Issue-676/STUCK"
  grep -q "Step: *2 draft" "$DEVDOC/Issue-676/STUCK"
}

@test "stuck appends a log entry" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  grep -E 'draft: stuck — blocked' "$DEVDOC/Issue-676/checklist.md"
}

@test "stuck requires a reason" {
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"reason"* ]]
}

@test "unstuck removes STUCK file and flips [!] back to [~] by default" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
  grep -E '^\- \[~\]  2\. draft' "$DEVDOC/Issue-676/checklist.md"
}

@test "unstuck --pending flips to [ ]" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk --pending
  [ "$status" -eq 0 ]
  grep -E '^\- \[ \]  2\. draft' "$DEVDOC/Issue-676/checklist.md"
}

@test "unstuck is a no-op (with warning) when no STUCK file" {
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"no STUCK"* ]]
}

@test "unstuck flips the [!] row in an OLDER revision block, not the active block's twin (#587)" {
  # #558 r3 BLOCKING-2's shape at unstuck.sh: the file-wide scan finds rev-1's
  # [!], carries out only its NUMBER, and checklist_mark re-resolves that number
  # into the ACTIVE block — flipping rev-2's pending twin while the real [!]
  # survives and STUCK is deleted anyway. Closeout numbers are REUSED in every
  # revision block (#76), so this is the normal revise-then-unstuck shape.
  f="$DEVDOC/Issue-676/checklist.md"
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"        # -> rev-1 `- [!]  2. draft`
  cat >> "$f" <<'EOC'

## Revision 2

- [ ]  2. draft
- [ ]  4. scope
EOC
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  # NO ABSOLUTE LINE NUMBERS. unstuck.sh calls log_append AFTER the mark, and
  # scripts/lib/log.sh inserts the entry at the END of the `## Log` section —
  # i.e. BEFORE `## Revision 2` — shifting every row below it. The heading and
  # the rows shift TOGETHER, so position is asserted RELATIVE to
  # `grep -n '^## Revision 2'` and is invariant under that insertion.
  rev2="$(grep -n '^## Revision 2' "$f" | cut -d: -f1)"
  [ -n "$rev2" ]
  # Exactly one row flipped, and it sits ABOVE the revision-2 heading — i.e. it
  # is the rev-1 row that actually CARRIED [!], not the active block's twin.
  run grep -cE '^- \[~\][[:space:]]+2\. draft' "$f"
  [ "$output" = "1" ]
  hit="$(grep -nE '^- \[~\][[:space:]]+2\. draft' "$f" | cut -d: -f1)"
  [ "$hit" -lt "$rev2" ]
  # rev-2's twin is untouched and still BELOW the heading (delta, not presence).
  run grep -cE '^- \[ \][[:space:]]+2\. draft' "$f"
  [ "$output" = "1" ]
  twin="$(grep -nE '^- \[ \][[:space:]]+2\. draft' "$f" | cut -d: -f1)"
  [ "$twin" -gt "$rev2" ]
  # No [!] survives, which is what makes the STUCK removal legitimate here.
  run grep -cE '^- \[!\]' "$f"
  [ "$output" = "0" ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
}

@test "unstuck prefers a [!] in the ACTIVE revision block over an older one (#587 regression)" {
  # Guards the OTHER branch of the new scan (Issue-558: a rewrite that fixes one
  # direction can turn a fail-closed error into a fail-open wrong write).
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOC'
- [x]  0. pull
- [!]  2. draft
- [ ]  4. scope

## Log

## Revision 2

- [x]  2. draft
- [!]  4. scope
EOC
  echo "scope: planted failure" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk --pending
  [ "$status" -eq 0 ]
  # rev-2's row cleared: rev-1's pending copy + rev-2's cleared row == 2.
  run grep -cE '^- \[ \][[:space:]]+4\. scope' "$DEVDOC/Issue-676/checklist.md"
  [ "$output" = "2" ]
  # rev-2's DONE row is not collateral. Before #587 the file-wide scan took
  # rev-1's `- [!]  2. draft` FIRST and checklist_mark re-scoped number 2 into
  # the active block, REGRESSING `- [x]  2. draft` to `- [ ]  2. draft` — a
  # completed step silently un-done, and STUCK deleted over it. This leg pins
  # that the done row survives untouched.
  run grep -cE '^- \[x\][[:space:]]+2\. draft' "$DEVDOC/Issue-676/checklist.md"
  [ "$output" = "1" ]
  # The older block's stale [!] is NOT the target and is left alone.
  run grep -cE '^- \[!\][[:space:]]+2\. draft' "$DEVDOC/Issue-676/checklist.md"
  [ "$output" = "1" ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
}

@test "unstuck leaves STUCK on disk when no row carries [!] (#587)" {
  # AC "STUCK is never deleted when the [!] row was not flipped", limb 2: the
  # refusal must live in the shipped code path, not only in the suite.
  echo "planted: sentinel with no [!] row" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"no [!] step"* ]]     # attribute the red to THIS path
  [ -f "$DEVDOC/Issue-676/STUCK" ]
}
