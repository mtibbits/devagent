#!/usr/bin/env bats
# #535: the optional pre-draft `1. research` step — template row, pull.sh
# table-driven flag-flip, the /devagent:research executor contract, draft.md
# consumption, spec, and flags_validate. Mirrors pull.bats's gh-stub harness.

load 'lib/bats-helpers'

REPO="${BATS_TEST_DIRNAME}/.."

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"; chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"; export GH_STUB_CASE="standard"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"; mkdir -p "$DEVDOC"
  _write_config standard
}
teardown() { teardown_tmp_devagent_home; }

_write_config() {  # $1 = checklist_template
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
checklist_template = "${1:-standard}"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
}

# ---- Task 1: template row ----
@test "checklist-standard and checklist-perf carry [-] 1. research between rows 0 and 1" {
  for t in checklist-standard checklist-perf; do
    run grep -nE '^- \[-\] +1\. research$' "$REPO/templates/$t.md"
    [ "$status" -eq 0 ]
    # flow position: research line number is AFTER pull(0) and BEFORE draft(1)
    local p r d
    p="$(grep -nE '^- \[ \]  0\. pull$' "$REPO/templates/$t.md" | cut -d: -f1)"
    r="$(grep -nE '^- \[-\] +1\. research$' "$REPO/templates/$t.md" | cut -d: -f1)"
    d="$(grep -nE '^- \[ \]  2\. draft$' "$REPO/templates/$t.md" | cut -d: -f1)"
    # split: `a && b` under bats set -e only errexits on the FINAL command, so a
    # combined form left the first half DEAD (research placed BEFORE pull passed).
    [ "$p" -lt "$r" ] || { echo "$t: research row not after pull"; false; }
    [ "$r" -lt "$d" ] || { echo "$t: research row not before draft"; false; }
  done
}

# ---- Task 3: pull.sh flag-flip (born-red without the pull.sh flip pass) ----
@test "pull flips the research row to [ ] when the BODY carries research: required (#535)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[ \] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unflagged pull leaves the research row [-] (no behavior change)" {
  export GH_STUB_BODY_JSON='"An ordinary issue with no flags block."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[-\] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}

@test "re-pull does not reset a completed research row (scaffold-branch-only)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\n\nBody."'
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  # operator completes research
  sed -i 's/^- \[ \]  1\. research$/- [x]  1. research/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676   # re-pull
  [ "$status" -eq 0 ]
  run grep -E '^- \[x\] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]   # still [x], not reset to [ ] or [-]
}

@test "a flags block quoted in a COMMENT does not flip the research row (body-segment only)" {
  export GH_STUB_BODY_JSON='"An ordinary body, no flags."'
  export GH_STUB_COMMENTS_JSON='[{"author":{"login":"bob"},"createdAt":"2026-05-12T08:14:22Z","body":"## Workflow flags\nresearch: required"}]'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[-\] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]   # comment block is below "## Comments (" → flags_get stops → no flip
}

@test "research flag with an absent research row warns and no-ops (does NOT die mid-scaffold #242)" {
  _write_config docs-only   # checklist-docs-only has no row 22
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]                                  # scaffold succeeded, no die
  [ -f "$DEVDOC/Issue-676/checklist.md" ]
  echo "$output" | grep -qi 'row 22 absent\|flag set but'  # warned
}

@test "flags_validate warns on an unknown key (block-level, deferred from #537)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\nboguskey: x\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unknown ## Workflow flags key 'boguskey'"
}

# ---- Task 4/5/6/7: contract greps ----
@test "commands/research.md: 3 sections, read-only, step 1, STEP≠TEMPLATE note" {
  local f="$REPO/commands/research.md"
  grep -qE '## Questions'       "$f"
  grep -qE '## Findings'        "$f"
  grep -qE 'Open unknowns'      "$f"
  grep -q  'Step 1'             "$f"
  grep -qi 'read-only\|read only\|builds NOTHING\|builds nothing' "$f"
  grep -qi 'distinct from the research checklist TEMPLATE\|STEP.*distinct.*TEMPLATE' "$f"
  # Write/Edit ARE granted — research.md is this step's deliverable. The read-only
  # discipline lives in PROSE (never the SOURCE tree), not in a missing tool that
  # would leave the step unable to produce its own artifact.
  grep -qE '^allowed-tools:.*\bWrite\b' "$f"
  grep -qiE 'do NOT write to the SOURCE tree|only file this step may create' "$f"
}

@test "draft.md Pre-plan inputs reads research.md and disposes open unknowns" {
  # SCOPED to the `## Pre-plan inputs` block — a whole-file grep would pass even if the
  # instruction were moved out of the block the AC names (#535 redmr).
  local block
  block="$(awk '/Pre-plan inputs/{inblk=1} inblk{print} inblk && /Pothole register/{exit}' \
           "$REPO/commands/draft.md")"
  [[ "$block" == *"research.md"* ]]
  [[ "$block" == *"Open unknowns"* ]]
}

@test "spec §6.3 carries row 22, the honest count, and the STEP-vs-TEMPLATE note" {
  local f="$REPO/docs/specs/2026-05-19-devagent-plugin-design.md"
  grep -q '/devagent:research' "$f"
  grep -q 'optional research step\|research (1) is optional' "$f"
  grep -q 'research STEP' "$f"
}

@test "all 6 templates document research: required in the flags note AND keep the no-live-example discipline" {
  for f in "$REPO"/templates/issue_template-*.md "$REPO/templates/epic_template.md"; do
    grep -q 'research: required' "$f"
    grep -q 'No live example here on purpose' "$f"   # #537 regression guard
  done
}

@test "a known flag with a non-trigger value warns and does not flip (#535 review)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: yes\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "not a recognized value for flag 'research'"
  run grep -E '^- \[-\] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]   # NOT flipped
}

@test "pull flips the research row when the flags block uses the blank-line-after-heading form (#535 redmr)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\n\nresearch: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[ \] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}

# ---- #536: the spike flag rides the SAME table-driven parser (one entry) ----
@test "pull flips the spike row to [ ] when the BODY carries spike: required (#536)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nspike: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[ \] +3\. spike$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}

@test "a spike-flagged scaffold does NOT emit an unknown-key warning (#536 B3)" {
  # flags_known_keys must list `spike`, else a correctly-flagged issue both flips the
  # row AND warns that its own flag is unknown — a self-contradicting scaffold.
  export GH_STUB_BODY_JSON='"## Workflow flags\nspike: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [[ "$output" != *"unknown ## Workflow flags key 'spike'"* ]]
}

@test "research and spike rows flip together when both flags are set (#535/#536)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\nspike: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -qE '^- \[ \] +1\. research$' "$DEVDOC/Issue-676/checklist.md"
  grep -qE '^- \[ \] +3\. spike$'    "$DEVDOC/Issue-676/checklist.md"
}
