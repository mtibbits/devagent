#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
# #703: stub issue backends + network shims (no real tracker call)
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"

setup() {
  TMPROOT="$(mktemp -d)"
  TMPDEV="$TMPROOT/devdoc"
  mkdir -p "$TMPDEV"
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"

  # Minimum config: testproj points devdoc at $TMPDEV.
  cat > "$HOME/.claude/devagent/config.toml" <<EOF
[defaults]
checklist_template = "standard"

[project.testproj]
source_dir = "$TMPROOT/src"
devdoc_dir = "$TMPDEV"

[project.testproj.issue_source]
backend = "github"
repo    = "acme/testproj"

[project.testproj.code_source]
backend  = "github"
upstream = "acme/testproj"

[project.testproj.permissions]
push_mr            = true
merge_to_all_prs   = true
commit_devdoc      = false
transition_issue   = true
cleanup_on_merge   = false
EOF
  mkdir -p "$TMPROOT/src"

  # #703: wbs update asks the tracker for leaf state. Every backend here is a
  # stub, and gh/glab/curl are shims that log to network.log, which teardown
  # asserts absent. The config above sets no dir_prefix, so the tracker
  # sources stay unconfigured unless a test calls _with_dir_prefix.
  export TMPROOT
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
}

teardown() {
  # #703: no test may reach a real tracker CLI (U6: a failing teardown fails)
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

# #703: configure the origin tracker source (issue_source gains dir_prefix).
_with_dir_prefix() {
  sed -i 's|^repo    = "acme/testproj"$|&\ndir_prefix = "Issue-"|' \
    "$HOME/.claude/devagent/config.toml"
  grep -q '^dir_prefix = "Issue-"$' "$HOME/.claude/devagent/config.toml"
}

# Helper: write an arbitrary scalar to the project state via the
# production toml helper (the script reads via state_get).
_state_set() {
  local key="$1" value="$2"
  python3 "$REPO/scripts/lib/_toml.py" set \
    "$HOME/.claude/devagent/state/testproj.toml" "$key" "\"$value\""
}
_state_set_int() {
  local key="$1" value="$2"
  python3 "$REPO/scripts/lib/_toml.py" set-int \
    "$HOME/.claude/devagent/state/testproj.toml" "$key" "$value"
}
_init_state() {
  # state_init from lib/state.sh handles the touch + initial keys.
  bash -c "source $REPO/scripts/lib/paths.sh; \
           source $REPO/scripts/lib/io.sh; \
           source $REPO/scripts/lib/state.sh; \
           state_init testproj"
}

@test "wbs init scaffolds WBS.md from template" {
  run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -eq 0 ]
  [ -f "$TMPDEV/WBS.md" ]
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
  grep -q "Recognized keys" "$TMPDEV/WBS.md"
}

@test "wbs init resolves project from single-project config when no arg" {
  run bash "$REPO/scripts/wbs.sh" init
  [ "$status" -eq 0 ]
  [ -f "$TMPDEV/WBS.md" ]
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
}

@test "wbs init is idempotent (refuses to overwrite without --force)" {
  bash "$REPO/scripts/wbs.sh" init testproj
  echo "hand-edited content" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -ne 0 ]
  grep -q "hand-edited content" "$TMPDEV/WBS.md"
}

@test "wbs init --force overwrites existing file" {
  bash "$REPO/scripts/wbs.sh" init testproj
  echo "hand-edited" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init testproj --force
  [ "$status" -eq 0 ]
  run grep -q "hand-edited" "$TMPDEV/WBS.md"
  [ "$status" -ne 0 ]
}

@test "wbs init honors an L2 devdoc wbs_template override (#341)" {
  mkdir -p "$TMPDEV/templates"
  printf '# {{PROJECT}} WBS\nCUSTOM-L2-MARKER\n' > "$TMPDEV/templates/wbs_template.md"
  run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -eq 0 ]
  grep -q "CUSTOM-L2-MARKER" "$TMPDEV/WBS.md"
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
}

@test "wbs init honors an L1 [project.paths].wbs_template override, shadowing devdoc (#341)" {
  # The pre-#341 hand-rolled loop skipped layer 1 entirely — this is the bug.
  mkdir -p "$TMPDEV/templates"
  printf '# {{PROJECT}} WBS\nCUSTOM-L2-MARKER\n' > "$TMPDEV/templates/wbs_template.md"
  local override="$TMPROOT/my_wbs.md"
  printf '# {{PROJECT}} WBS\nCUSTOM-L1-MARKER\n' > "$override"
  cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.testproj.paths]
wbs_template = "$override"
EOF
  run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -eq 0 ]
  grep -q "CUSTOM-L1-MARKER" "$TMPDEV/WBS.md"
  run grep -q "CUSTOM-L2-MARKER" "$TMPDEV/WBS.md"
  [ "$status" -ne 0 ]
}

@test "wbs init dies with a clear message when no wbs_template resolves (#341 set -e)" {
  # No devdoc/L1 override AND an empty plugin templates dir → template_resolve
  # returns rc 1. Under set -euo pipefail the command-substitution must not abort
  # the script before the explicit die — the operator gets a diagnostic, not a
  # bare silent exit.
  local emptytpl="$TMPROOT/empty-templates"; mkdir -p "$emptytpl"
  DEVAGENT_PLUGIN_TEMPLATES="$emptytpl" run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -ne 0 ]
  [[ "$output" == *"no wbs_template.md found"* ]]
}

@test "wbs show prints WBS.md contents" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj
  [ "$status" -eq 0 ]
  [[ "$output" == *"Top"* ]]
  [[ "$output" == *"Leaf A"* ]]
  [[ "$output" == *"Leaf B"* ]]
}

@test "wbs show --depth 1 hides children below depth 1" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --depth 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
  [[ "$output" == *"Subgoal A"* ]]
  [[ "$output" != *"Subsubgoal A1"* ]]
}

@test "wbs show --milestone M2 filters to that milestone subtree" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --milestone M2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
}

@test "wbs show errors when WBS.md missing" {
  run bash "$REPO/scripts/wbs.sh" show testproj
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "wbs show --depth with no value fails with a clear message (A22)" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --depth
  [ "$status" -ne 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"--depth"* ]]
}

@test "wbs show --milestone with no value fails with a clear message (A22)" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --milestone
  [ "$status" -ne 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"--milestone"* ]]
}

@test "wbs update appends a new entry for an active issue not yet in WBS" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Existing milestone {est: 2w, milestone: M1}
  - [x] Old leaf {issue: Issue-1, est: 1w}
EOF
  _init_state
  _state_set active_issue "Issue-2"
  _state_set issue_dir "$TMPDEV/Issue-2"
  _state_set_int last_step 3
  _state_set last_step_name "improve"
  mkdir -p "$TMPDEV/Issue-2"
  cat > "$TMPDEV/Issue-2/checklist.md" <<'EOF'
# Issue-2 — Workflow checklist
Template: standard

## Revision 1
- [x] 0. pull
- [~] 5. improve

## Log
- 2026-05-19 10:00  pull: fetched
EOF
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  grep -q "Issue-2" "$TMPDEV/WBS.md"
}

@test "wbs update is idempotent (running twice produces same file)" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  _init_state
  _state_set active_issue "Issue-1"
  _state_set issue_dir "$TMPDEV/Issue-1"
  _state_set_int last_step 0
  _state_set last_step_name "pull"
  mkdir -p "$TMPDEV/Issue-1"
  echo "# Issue-1 — Workflow checklist" > "$TMPDEV/Issue-1/checklist.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.input"
  bash "$REPO/scripts/wbs.sh" update testproj
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
  cmp "$TMPDEV/WBS.md.input" "$TMPDEV/WBS.md.first"
  bash "$REPO/scripts/wbs.sh" update testproj
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
}

@test "updatewbs.md command file exists and references wbs.sh update" {
  [ -f "$REPO/commands/updatewbs.md" ]
  # #446: the invocation now goes through ${CLAUDE_PLUGIN_ROOT}, so the path is
  # quoted (`scripts/wbs.sh" update`); tolerate both the bare and quoted forms.
  grep -qE 'scripts/wbs\.sh"? update' "$REPO/commands/updatewbs.md"
}

@test "wbs update reconciles in-progress leaf from checklist truth" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [ ] Working leaf {issue: Issue-9, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-9"
  cat > "$TMPDEV/Issue-9/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [~]  9. implement
- [ ] 13. analyze
EOF
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  grep -q "\[~\] Working leaf" "$TMPDEV/WBS.md"
}

@test "wbs update reconciles done leaf when all steps complete (works AFTER active_issue cleared)" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [~] Working leaf {issue: Issue-9, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-9"
  cat > "$TMPDEV/Issue-9/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [x]  9. implement
- [x] 13. analyze
- [x] 23. cleanup
EOF
  # Note: NO active_issue set. Mimics the post-cleanup state where the
  # operator runs wbs update and the issue's leaf must still flip to [x].
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  grep -q "\[x\] Working leaf" "$TMPDEV/WBS.md"
}

@test "wbs update is idempotent (no spurious diff on a fully-reconciled WBS)" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [x] Done leaf {issue: Issue-3, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-3"
  cat > "$TMPDEV/Issue-3/checklist.md" <<'EOF'
- [x]  0. pull
- [x] 23. cleanup
EOF
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.input"
  bash "$REPO/scripts/wbs.sh" update testproj
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
  cmp "$TMPDEV/WBS.md.input" "$TMPDEV/WBS.md.first"
  bash "$REPO/scripts/wbs.sh" update testproj
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
}

@test "wbs update --if-exists silently no-ops when WBS.md missing" {
  # No WBS.md created.
  run bash "$REPO/scripts/wbs.sh" update testproj --if-exists
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wbs update (no --if-exists) errors when WBS.md missing" {
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
}

# #702 — no local checklist is no signal
#
# A leaf whose Issue-N/checklist.md is missing, or has no step rows, keeps
# its glyph. Fixtures are in canonical rendered form, so an unchanged file
# round-trips byte-identical and one whole-file diff checks every leg. The
# Issue-9 control leaf proves reconcile still runs in the same invocation.
# Only the auto-add test sets active_issue. Elsewhere the scan fallback can
# select only a checklist that is already a WBS leaf, so nothing is auto-added.

_reconciled_control_issue() {
  mkdir -p "$TMPDEV/Issue-9"
  cat > "$TMPDEV/Issue-9/checklist.md" <<'EOF'
- [x]  0. pull
- [x] 23. cleanup
EOF
}

# Run update and diff WBS.md against its pre-run copy edited by sed expr $1.
_update_expecting() {
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.expected"
  sed -i "$1" "$TMPDEV/WBS.expected"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.expected"
}

@test "wbs update keeps every non-pending glyph on a leaf with no Issue-N directory (#702)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [x] Closed on tracker {issue: Issue-25, est: 1w}
  - [~] Mid-flight elsewhere {issue: Issue-26, est: 1w}
  - [-] Skipped leaf {issue: Issue-27, est: 1w}
  - [P] Parked leaf {issue: Issue-28, est: 1w}
  - [!] Stuck leaf {issue: Issue-29, est: 1w}
  - [?] Blocked leaf {issue: Issue-30, est: 1w}
  - [ ] Reconciled control {issue: Issue-9, est: 1w}
EOF
  _reconciled_control_issue
  _update_expecting 's/^  - \[ \] Reconciled control /  - [x] Reconciled control /'
}

@test "wbs update keeps the glyph on a leaf whose checklist has no step rows (#702)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [x] Header-only checklist {issue: Issue-31, est: 1w}
  - [P] Empty checklist {issue: Issue-32, est: 1w}
  - [ ] Reconciled control {issue: Issue-9, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-31" "$TMPDEV/Issue-32"
  cat > "$TMPDEV/Issue-31/checklist.md" <<'EOF'
# Issue-31 — Workflow checklist
Template: standard

## Revision 1

## Log
- 2026-10-07 10:00  pull: fetched
EOF
  : > "$TMPDEV/Issue-32/checklist.md"
  _reconciled_control_issue
  _update_expecting 's/^  - \[ \] Reconciled control /  - [x] Reconciled control /'
}

@test "wbs update still sets [ ] from a checklist whose step rows show no progress (#702 control)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [x] Stale local checklist {issue: Issue-33, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-33"
  cat > "$TMPDEV/Issue-33/checklist.md" <<'EOF'
- [ ]  0. pull
- [ ]  2. draft
EOF
  _update_expecting 's/^  - \[x\] Stale local checklist /  - [ ] Stale local checklist /'
}

@test "wbs update auto-adds an active issue with no checklist as [ ] (#702)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Existing milestone {est: 2w, milestone: M1}
  - [x] Old leaf {issue: Issue-1, est: 1w}
EOF
  _init_state
  _state_set active_issue "Issue-7"
  _update_expecting '$a- [ ] Unassigned\n  - [ ] Issue-7 {issue: Issue-7, est: ?w}'
}

# #700 — active revision block decides [x]
#
# A leaf is [x] when checklist_current_step reports done (the differences
# are in the scripts/wbs-update.sh header): only the step rows after the last
# `## Revision` heading count, matched the way _checklist_line_re matches
# them. Progress ([~]) and no signal (#702) still
# read every row in the file. Each fixture helper writes one checklist and
# nothing else, so the agreement test runs the real reader on the same bytes.

# Run a function from the real libs (revision.sh sources paths, io, config,
# artifact, state and checklist).
_lib700() {
  bash -c 'source "$1/scripts/lib/revision.sh"; shift; "$@"' _ "$REPO" "$@"
}

# Write stdin to $TMPDEV/<id>/checklist.md.
_cl700() {
  mkdir -p "$TMPDEV/$1"
  cat > "$TMPDEV/$1/checklist.md"
}

# F1: the issue's minimal repro. Revision 1 abandoned, Revision 2 done.
_f700_repro() {
  _cl700 "$1" <<'EOF'
## Revision 1
- [x]  0. pull
- [x]  2. draft
- [ ]  7. tighten
- [ ] 23. cleanup

## Log
- 2026-10-07 10:00  pull: fetched

## Revision 2
- [x]  2. draft
- [x]  7. tighten
- [x] 23. cleanup
EOF
}

# F2: factor-ai Issue-85 shape. Pre-#558 numbering, Revision 1 stopped at
# tighten, Revision 2 ran to cleanup; `Active revision:` still reads 1.
_f700_issue85() {
  _cl700 "$1" <<'EOF'
# Issue-85 — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: standard
Created: 2026-07-27T00:57:14-04:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [-] 22. research
- [x]  1. draft
- [x] 23. spike
- [x]  2. scope
- [x]  3. improve
- [x]  4. prune
- [ ]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ]  8. quality
- [ ]  9. document
- [ ] 10. commit
- [ ] 11. analyze
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 14. redmr
- [ ] 21. preship
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 17. updatewbs
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
- 2026-07-27 00:57  pull: fetched mtibbits/factorAI#85, scaffold created
- 2026-07-27 14:25  revise: revision 2 started, 0 comments to address

## Revision 2

- [x]  1. draft
- [x]  2. scope
- [x]  3. improve
- [x]  4. prune
- [x]  5. tighten
- [x]  6. branch
- [x]  7. implement
- [x]  8. quality
- [x]  9. document
- [-] 10. commit
- [-] 11. analyze
- [x] 12. draftmr
- [x] 13. review
- [x] 14. redmr
- [-] 21. preship
- [-] 15. ship
- [-] 16. mergetoall
- [x] 17. updatewbs
- [x] 18. impact
- [x] 19. lessonslearned
- [x] 20. cleanup
EOF
}

# F3: real producers. Revision 1 all [x] except spike [ ] (a row only
# Revision 1 carries) and mergetoall [-]; Revision 2 all [x], mergetoall [-].
# Glyphs are set while the file has one block, then the new block is set in
# the append pipe; checklist_mark is never used (it re-scopes to the last
# block once a second heading exists).
_f700_spike_only_rev1() {
  local cl="$TMPDEV/$1/checklist.md"
  _lib700 checklist_init "$TMPDEV/$1"
  sed -i -e 's/^- \[.\]/- [x]/' \
         -e 's/^- \[x\]  3\. spike$/- [ ]  3. spike/' \
         -e 's/^- \[x\] 19\. mergetoall$/- [-] 19. mergetoall/' "$cl"
  _lib700 revision_block_text 2 \
    | sed -e 's/^- \[.\]/- [x]/' \
          -e 's/^- \[x\] 19\. mergetoall$/- [-] 19. mergetoall/' >> "$cl"
}

# F4: real producers. Revision 1 done from pull through prune, the rest as
# scaffolded; Revision 2 freshly appended, all pending.
_f700_fresh_rev2() {
  local cl="$TMPDEV/$1/checklist.md"
  _lib700 checklist_init "$TMPDEV/$1"
  sed -i 's/^- \[.\]\(  [0-6]\. \)/- [x]\1/' "$cl"
  _lib700 revision_block_text 2 >> "$cl"
}

# F5: a bare `## Revision 2` heading with no rows after a finished Revision 1.
_f700_empty_rev2() {
  _cl700 "$1" <<'EOF'
## Revision 1

- [x]  0. pull
- [-]  1. research
- [x] 23. cleanup

## Log
- 2026-10-11 10:00  revise: revision 2 started

## Revision 2
EOF
}

# F6: Revision 2 done except one stuck, one blocked and one parked row.
_f700_stuck_rev2() {
  _cl700 "$1" <<'EOF'
## Revision 1

- [x]  0. pull
- [x]  2. draft

## Log

## Revision 2

- [x]  2. draft
- [!]  4. scope
- [?]  5. improve
- [P]  6. prune
- [x] 23. cleanup
EOF
}

# F7: one heading (standard checklist_init), with an optional sed edit:
# fresh, partly done, all done.
_f700_one_heading() {
  _lib700 checklist_init "$TMPDEV/$1"
  [ -z "${2:-}" ] || sed -i "$2" "$TMPDEV/$1/checklist.md"
}
_F700_PARTIAL='s/^- \[ \]  0\. pull$/- [x]  0. pull/'
_F700_DONE='s/^- \[ \]/- [x]/'

# F8a: Revision 2 rows tab-separated, all done; Revision 1 partly done.
_f700_tab_rev2() {
  {
    printf '%s\n' '## Revision 1' '' '- [x]  0. pull' '- [ ]  2. draft' '' \
      '## Revision 2' ''
    printf -- '- [x]\t%s.\t%s\n' 2 draft 23 cleanup
  } | _cl700 "$1"
}

# F8b: one heading, every row done except an unknown `[X]` glyph.
_f700_unknown_glyph() {
  _cl700 "$1" <<'EOF'
## Revision 1

- [x]  0. pull
- [x]  2. draft
- [X] 23. cleanup
EOF
}

# F9: F1 with CRLF line endings.
_f700_repro_crlf() {
  _f700_repro "$1"
  sed -i 's/$/\r/' "$TMPDEV/$1/checklist.md"
}

@test "wbs update marks a revisioned checklist done from its active block (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [ ] Minimal repro {issue: Issue-40, est: 1w}
EOF
  _f700_repro Issue-40
  _update_expecting 's/^  - \[ \] Minimal repro /  - [x] Minimal repro /'
}

@test "wbs update marks a factor-ai Issue-85 shaped checklist done (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [~] Issue-85 shape {issue: Issue-41, est: 1w}
EOF
  _f700_issue85 Issue-41
  _update_expecting 's/^  - \[~\] Issue-85 shape /  - [x] Issue-85 shape /'
}

@test "wbs update ignores a pending row only revision 1 carries (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [ ] Spike only in revision 1 {issue: Issue-42, est: 1w}
EOF
  _f700_spike_only_rev1 Issue-42
  local cl="$TMPDEV/Issue-42/checklist.md" active
  active="$(tail -n +"$(_lib700 _checklist_active_start "$cl")" "$cl")"
  [[ "$active" == "## Revision 2"$'\n'* ]]
  [[ "$active" == *$'\n- [x]  2. draft\n'* ]]
  [[ "$active" != *". spike"* ]]
  grep -qxF -- '- [ ]  3. spike' "$cl"
  _update_expecting 's/^  - \[ \] Spike only in revision 1 /  - [x] Spike only in revision 1 /'
}

@test "wbs update keeps a just-started revision in progress (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [x] Fresh revision 2 {issue: Issue-43, est: 1w}
EOF
  _f700_fresh_rev2 Issue-43
  _update_expecting 's/^  - \[x\] Fresh revision 2 /  - [~] Fresh revision 2 /'
}

@test "wbs update reads an empty active revision block as not done (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [x] Empty revision 2 {issue: Issue-44, est: 1w}
EOF
  _f700_empty_rev2 Issue-44
  _update_expecting 's/^  - \[x\] Empty revision 2 /  - [~] Empty revision 2 /'
}

@test "wbs update treats stuck, blocked and parked active rows as not done (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [ ] Stuck in revision 2 {issue: Issue-45, est: 1w}
EOF
  _f700_stuck_rev2 Issue-45
  _update_expecting 's/^  - \[ \] Stuck in revision 2 /  - [~] Stuck in revision 2 /'
}

@test "wbs update reconciles zero- and one-heading checklists as before (#700)" {
  # Zero headings: the Issue-9 control here, plus the earlier no-heading tests.
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [x] One heading fresh {issue: Issue-46, est: 1w}
  - [ ] One heading partial {issue: Issue-47, est: 1w}
  - [ ] One heading done {issue: Issue-48, est: 1w}
  - [ ] Reconciled control {issue: Issue-9, est: 1w}
EOF
  _f700_one_heading Issue-46
  _f700_one_heading Issue-47 "$_F700_PARTIAL"
  _f700_one_heading Issue-48 "$_F700_DONE"
  _reconciled_control_issue
  _update_expecting 's/^  - \[x\] One heading fresh /  - [ ] One heading fresh /; s/^  - \[ \] One heading partial /  - [~] One heading partial /; s/^  - \[ \] One heading done /  - [x] One heading done /; s/^  - \[ \] Reconciled control /  - [x] Reconciled control /'
}

@test "wbs update matches step rows the way checklist_current_step does (#700)" {
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [~] Epic {est: 4w}
  - [ ] Tab-separated rows {issue: Issue-49, est: 1w}
  - [x] Unknown glyph {issue: Issue-50, est: 1w}
EOF
  _f700_tab_rev2 Issue-49
  _f700_unknown_glyph Issue-50
  _update_expecting 's/^  - \[ \] Tab-separated rows /  - [x] Tab-separated rows /; s/^  - \[x\] Unknown glyph /  - [~] Unknown glyph /'
}

@test "wbs update [x] agrees with checklist_current_step done on every #700 fixture" {
  _f700_repro Issue-40
  _f700_issue85 Issue-41
  _f700_spike_only_rev1 Issue-42
  _f700_fresh_rev2 Issue-43
  _f700_empty_rev2 Issue-44
  _f700_stuck_rev2 Issue-45
  _f700_one_heading Issue-46
  _f700_one_heading Issue-47 "$_F700_PARTIAL"
  _f700_one_heading Issue-48 "$_F700_DONE"
  _f700_tab_rev2 Issue-49
  _f700_unknown_glyph Issue-50
  _f700_repro_crlf Issue-51
  local id glyph bash_done wbs_done done_count=0
  {
    printf '# testproj WBS\n\n- [P] Fixtures {est: 4w}\n'
    for id in Issue-{40..51}; do
      printf '  - [P] %s {issue: %s, est: 1w}\n' "$id" "$id"
    done
  } > "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for id in Issue-{40..51}; do
    [ -f "$TMPDEV/$id/checklist.md" ]
    glyph="$(sed -n "s/^  - \[\(.\)\] $id {issue: .*/\1/p" "$TMPDEV/WBS.md")"
    [ -n "$glyph" ] || { echo "$id: leaf missing from WBS.md"; false; }
    [ "$glyph" != P ] || { echo "$id: leaf not reconciled"; false; }
    run _lib700 checklist_current_step "$TMPDEV/$id/checklist.md"
    bash_done=0 wbs_done=0
    [ "$status" -ne 0 ] || [ "$output" != "done" ] || bash_done=1
    [ "$glyph" != x ] || wbs_done=1
    [ "$bash_done" -eq "$wbs_done" ] || {
      echo "$id: checklist_current_step done=$bash_done (status $status, output: $output); wbs [x]=$wbs_done (glyph '$glyph')"
      false
    }
    done_count=$((done_count + bash_done))
  done
  # The bash reader ran: some fixtures are done.
  [ "$done_count" -ge 1 ]
}

@test "wbs-update header states the active-block status rule (#700)" {
  local header
  header="$(sed -n '1,/^set -euo/p' "$REPO/scripts/wbs-update.sh")"
  [[ "$header" == *checklist_current_step* ]]
  [[ "$header" == *"## Revision"* ]]
}

# #701 — line-local WBS writes
#
# Every leg derives from tests/fixtures/wbs/preserve.md (prose, comments, a
# fenced block, odd meta formatting). Byte facts are checked only with cmp /
# cmp -l: Git Bash grep and sed hide CR.

# The variants tests/helpers/wbs_bytes.py builds (its KINDS).
WBS701_KINDS="lf crlf lf-nofinal crlf-nofinal"

# Write the <kind> variant of preserve.md to WBS.md, and a copy to WBS.input.
_wbs701() {
  python3 "$REPO/tests/helpers/wbs_bytes.py" variant \
    "$REPO/tests/fixtures/wbs/preserve.md" "$1" "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.input"
}

# Issue-1 checklist showing progress: Leaf A reconciles [ ] -> [~].
_wbs701_progress() {
  mkdir -p "$TMPDEV/Issue-1"
  printf '%s\n' '- [x]  0. pull' '- [~]  9. implement' > "$TMPDEV/Issue-1/checklist.md"
}

@test "wbs update leaves an unchanged WBS.md byte-identical in every variant (#701)" {
  local kind
  for kind in $WBS701_KINDS; do
    _wbs701 "$kind"
    run bash "$REPO/scripts/wbs.sh" update testproj
    [ "$status" -eq 0 ]
    cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
  done
}

@test "wbs update changes only the glyph byte of a reconciled leaf (#701)" {
  local kind off cmpout
  _wbs701_progress
  for kind in $WBS701_KINDS; do
    _wbs701 "$kind"
    run bash "$REPO/scripts/wbs.sh" update testproj
    [ "$status" -eq 0 ]
    off="$(python3 "$REPO/tests/helpers/wbs_bytes.py" glyph-offset "$TMPDEV/WBS.input" "Leaf A")"
    run cmp -l "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
    cmpout="$(printf '%s\n' "$output" | awk '{print $1, $2, $3}')"
    [ "$cmpout" = "$off 40 176" ]
  done
}

@test "wbs update ignores node-shaped lines inside a fenced block (#701)" {
  _wbs701 lf
  mkdir -p "$TMPDEV/Issue-9"
  printf '%s\n' '- [x]  0. pull' '- [x] 23. cleanup' > "$TMPDEV/Issue-9/checklist.md"
  _init_state
  _state_set active_issue "Issue-9"
  python3 "$REPO/tests/helpers/wbs_bytes.py" insert-after \
    "$TMPDEV/WBS.input" "$TMPDEV/expected" "    Note under the last leaf." lf \
    "- [ ] Unassigned" "  - [x] Issue-9 {issue: Issue-9, est: ?w}"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
}

@test "wbs update auto-add keeps notes with their leaf and the file's line endings (#701)" {
  _wbs701 crlf-nofinal
  _init_state
  _state_set active_issue "Issue-7"
  python3 "$REPO/tests/helpers/wbs_bytes.py" insert-after \
    "$TMPDEV/WBS.input" "$TMPDEV/expected" "    Note under the last leaf." crlf \
    "- [ ] Unassigned" "  - [ ] Issue-7 {issue: Issue-7, est: ?w}"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/expected" "$TMPDEV/WBS.md"
}

@test "wbs update does not rewrite a file it did not change (#701)" {
  _wbs701 lf
  chmod a-w "$TMPDEV/WBS.md"
  if [ -w "$TMPDEV/WBS.md" ]; then
    skip "cannot make WBS.md read-only here"
  fi
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  cmp "$TMPDEV/WBS.input" "$TMPDEV/WBS.md"
}

@test "wbs show with no filter prints WBS.md byte-for-byte (#701)" {
  local kind
  for kind in $WBS701_KINDS; do
    _wbs701 "$kind"
    bash "$REPO/scripts/wbs.sh" show testproj > "$TMPROOT/out"
    cmp "$TMPROOT/out" "$TMPDEV/WBS.md"
  done
}

@test "wbs show --milestone prints the matching nodes only, as before (#701)" {
  _wbs701 lf
  bash "$REPO/scripts/wbs.sh" show testproj --milestone M1 > "$TMPROOT/m1.out"
  cmp "$TMPROOT/m1.out" "$REPO/tests/fixtures/wbs/preserve-m1.expected"
}

@test "wbs show --depth leaves fenced and prose lines out (#701)" {
  _wbs701 lf
  run bash "$REPO/scripts/wbs.sh" show testproj --depth 9
  [ "$status" -eq 0 ]
  [[ "$output" == *"Leaf D"* ]]
  [[ "$output" != *"Fenced example"* ]]
  [[ "$output" != *"Note under"* ]]
  [[ "$output" != *"Prose paragraph"* ]]
  [[ "$output" != *"## Notes"* ]]
}

@test "wbs update is idempotent on a WBS with prose (#701)" {
  _wbs701 crlf
  _wbs701_progress
  bash "$REPO/scripts/wbs.sh" update testproj
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.run1"
  bash "$REPO/scripts/wbs.sh" update testproj
  cmp "$TMPDEV/WBS.run1" "$TMPDEV/WBS.md"
  run cmp -l "$TMPDEV/WBS.input" "$TMPDEV/WBS.run1"
  [ "${#lines[@]}" -eq 1 ]
}

@test "WBS docs state that non-node lines are kept byte-for-byte (#701)" {
  local spec131
  grep -qF 'byte-for-byte' "$REPO/templates/wbs_template.md"
  grep -qF 'byte-for-byte' "$REPO/commands/wbs.md"
  spec131="$(sed -n '/^### 13.1 /,/^### 13.2 /p' "$REPO/docs/specs/2026-05-19-devagent-plugin-design.md")"
  [[ "$spec131" == *byte-for-byte* ]]
}

@test "wbs.bats network shim catches a real backend call (#703 control)" {
  skip "wbs update has no tracker phase yet"
  _with_dir_prefix
  unset DEVAGENT_ISSUE_BACKEND_DIR
  cat > "$TMPDEV/WBS.md" <<'EOF'
# testproj WBS

- [ ] Leaf {issue: Issue-9, est: 1w}
EOF
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  # the real github.sh reached the gh shim: the guard would have caught it
  [ -e "$TMPROOT/network.log" ]
  grep -q '^gh issue list' "$TMPROOT/network.log"
  rm -f "$TMPROOT/network.log"
}
