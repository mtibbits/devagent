#!/usr/bin/env bats
# #535: the optional pre-draft `22. research` step — template row, pull.sh
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
@test "checklist-standard and checklist-perf carry [-] 22. research between rows 0 and 1" {
  for t in checklist-standard checklist-perf; do
    run grep -nE '^- \[-\] 22\. research$' "$REPO/templates/$t.md"
    [ "$status" -eq 0 ]
    # flow position: research line number is AFTER pull(0) and BEFORE draft(1)
    local p r d
    p="$(grep -nE '^- \[ \]  0\. pull$' "$REPO/templates/$t.md" | cut -d: -f1)"
    r="$(grep -nE '^- \[-\] 22\. research$' "$REPO/templates/$t.md" | cut -d: -f1)"
    d="$(grep -nE '^- \[ \]  1\. draft$' "$REPO/templates/$t.md" | cut -d: -f1)"
    # split: `a && b` under bats set -e only errexits on the FINAL command, so a
    # combined form left the first half DEAD (research placed BEFORE pull passed).
    [ "$p" -lt "$r" ] || { echo "$t: research row not after pull"; false; }
    [ "$r" -lt "$d" ] || { echo "$t: research row not before draft"; false; }
  done
}

# ---- Task 3: pull.sh flag-flip (born-red without the pull.sh flip pass) ----
@test "pull flips row 22 to [ ] when the BODY carries research: required (#535)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[ \] 22\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}

@test "unflagged pull leaves row 22 [-] (no behavior change)" {
  export GH_STUB_BODY_JSON='"An ordinary issue with no flags block."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[-\] 22\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}

@test "re-pull does not reset a completed row 22 (scaffold-branch-only)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\nresearch: required\n\nBody."'
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  # operator completes research
  sed -i 's/^- \[ \] 22\. research$/- [x] 22. research/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676   # re-pull
  [ "$status" -eq 0 ]
  run grep -E '^- \[x\] 22\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]   # still [x], not reset to [ ] or [-]
}

@test "a flags block quoted in a COMMENT does not flip row 22 (body-segment only)" {
  export GH_STUB_BODY_JSON='"An ordinary body, no flags."'
  export GH_STUB_COMMENTS_JSON='[{"author":{"login":"bob"},"createdAt":"2026-05-12T08:14:22Z","body":"## Workflow flags\nresearch: required"}]'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[-\] 22\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]   # comment block is below "## Comments (" → flags_get stops → no flip
}

@test "research flag with an absent row 22 warns and no-ops (does NOT die mid-scaffold #242)" {
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
@test "commands/research.md: 3 sections, read-only, step 22, STEP≠TEMPLATE note" {
  local f="$REPO/commands/research.md"
  grep -qE '## Questions'       "$f"
  grep -qE '## Findings'        "$f"
  grep -qE 'Open unknowns'      "$f"
  grep -q  'Step 22'            "$f"
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
  grep -q 'optional research step\|research (22) is optional' "$f"
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
  run grep -E '^- \[-\] 22\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]   # NOT flipped
}

@test "pull flips row 22 when the flags block uses the blank-line-after-heading form (#535 redmr)" {
  export GH_STUB_BODY_JSON='"## Workflow flags\n\nresearch: required\n\nBody."'
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  run grep -E '^- \[ \] 22\. research$' "$DEVDOC/Issue-676/checklist.md"
  [ "$status" -eq 0 ]
}
