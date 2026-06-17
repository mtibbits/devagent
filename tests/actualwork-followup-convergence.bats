#!/usr/bin/env bats
# actualWork `### Follow-up` convergence (#115).
#
# The core-document-actual-work skill, the actualWork_template.md template, and
# reap.sh must agree on ONE actualWork.md structure that includes an exact
# `### Follow-up` section (what reap harvests). Option 1 = template-canonical:
#   # Actual Work — {{ISSUE_ID}} / ## Summary / ## Deviations from plan /
#   ## Verification / ### Follow-up   (Follow-up LAST).
#
# Follow-up MUST be the last bulleted section: reap's awk resets only on another
# `### ` h3, not on an `## ` h2, so a `### Follow-up` placed before a bulleted
# `## Verification` would mis-harvest the Verification bullets.

load 'helpers'

REPO="${BATS_TEST_DIRNAME}/.."
TEMPLATE="${REPO}/templates/actualWork_template.md"
SKILL="${REPO}/skills/core-document-actual-work/SKILL.md"

# --- B: template structural contract --------------------------------------

@test "template carries an exact '### Follow-up' section after '## Verification' (#115)" {
  grep -qx '### Follow-up' "$TEMPLATE"
  # ordering: Verification line precedes the Follow-up line
  local v f
  v="$(grep -n '^## Verification$' "$TEMPLATE" | head -1 | cut -d: -f1)"
  f="$(grep -n '^### Follow-up$'  "$TEMPLATE" | head -1 | cut -d: -f1)"
  [ -n "$v" ] && [ -n "$f" ]
  [ "$f" -gt "$v" ]
}

# --- C: skill output-template contract ------------------------------------

@test "skill output template aligns to the template headings + Follow-up last (#115)" {
  grep -qx '## Verification' "$SKILL"
  grep -qx '### Follow-up' "$SKILL"
  grep -qx '## Deviations from plan' "$SKILL"
  # In the skill's example, Follow-up comes after Verification.
  local v f
  v="$(grep -n '^## Verification$' "$SKILL" | head -1 | cut -d: -f1)"
  f="$(grep -n '^### Follow-up$'  "$SKILL" | tail -1 | cut -d: -f1)"
  [ -n "$v" ] && [ -n "$f" ]
  [ "$f" -gt "$v" ]
}

# --- A: reap ordering-safety (behavioral) ---------------------------------

@test "reap harvests Follow-up bullets but NOT Verification bullets in canonical shape (#115)" {
  setup_tmp_devdoc
  setup_tmp_state
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"

  mkdir -p "${TMP_DEVDOC}/Issue-700"
  cat > "${TMP_DEVDOC}/Issue-700/actualWork.md" <<'EOF'
# Actual Work — Issue-700

**Branch:** `fix/700-x` based on `origin/main` (`abc123`)

## Summary
- Task 1: [done as planned]

## Deviations from plan
(none)

## Verification
- Build VERIFYBULLET passed clean
- Tests VERIFYBULLET 700/700

### Follow-up
- FollowupHarvestMe deserves a dedicated follow-up later.
EOF

  run "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ]
  # The follow-up bullet is harvested...
  [[ "$output" == *"FollowupHarvestMe"* ]]
  # ...and the Verification bullets are NOT mis-harvested as follow-ups.
  [[ "$output" != *"VERIFYBULLET"* ]]

  teardown_tmp_devdoc
  teardown_tmp_state
}
