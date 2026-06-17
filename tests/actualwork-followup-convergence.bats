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
DRAFTMR_SKILL="${REPO}/skills/core-draft-mr/SKILL.md"

# Clean up the reap test's tmp trees even if an assertion fails mid-test
# (in-body teardown would be skipped on failure → leaked /tmp dirs).
teardown() {
  [ -n "${TMP_DEVDOC:-}" ] && teardown_tmp_devdoc || true
  [ -n "${TMP_STATE:-}" ] && teardown_tmp_state || true
}

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
}

# --- D: consumer + terse-case convergence (review findings) ---------------

@test "draft-mr consumer skill names the post-rename '## Deviations from plan' (#115)" {
  # The canonical heading was renamed from '## Deviations'; the consumer that
  # reads it must name the new heading, else the convergence leaks a stale ref.
  grep -q 'Deviations from plan' "$DRAFTMR_SKILL"
}

@test "skill terse (no-deviation) case is a reduction of the canonical structure (#115)" {
  # The terse example must use the canonical '## Summary' heading (not a
  # headingless 3-line blob), so terse is a strict subset of the canonical
  # structure rather than a competing shape. Both the deviation example and
  # the terse example carry '## Summary' → at least 2 occurrences (the pre-fix
  # headingless terse case had only the deviation one).
  [ "$(grep -cE '^[[:space:]]*## Summary$' "$SKILL")" -ge 2 ]
  # And the template documents the same no-deviation reduction.
  grep -qi 'no-deviation case' "$TEMPLATE"
}
