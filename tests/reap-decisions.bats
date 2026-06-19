#!/usr/bin/env bats
# reap.sh --decisions: consume core-reap keep/discard/override decisions (#111).
#
# Pre-fix, reap.sh ignored the skill's DECISIONS entirely: every candidate was
# drafted with the heuristic subtype/title and every body-hash burned, so a
# discard both still drafted the item AND permanently blocked re-triage. The fix
# (Option A + discard-(ii)): dry-run surfaces the body hash; `--decisions <file>`
# (TSV hash/action/subtype/title) drives drafting; discarded hashes land in a
# separate `[discarded]` table (skipped on future runs, but re-triageable by
# clearing the entry).

load 'helpers'

setup() {
  setup_tmp_devdoc
  setup_tmp_state
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
  STATE_FILE="${DEVAGENT_STATE_DIR}/fake.reaped.toml"
  # Two distinct-body candidates in a fresh issue.
  mkdir -p "${TMP_DEVDOC}/Issue-900"
  printf -- '- Alpha candidate body one. extra alpha detail.\n- Beta candidate body two. extra beta detail.\n' \
    > "${TMP_DEVDOC}/Issue-900/imPlan-potentialFutureEnhancements.md"
}
teardown() { teardown_tmp_devdoc; teardown_tmp_state; }

_hash_for() {  # $1 = title substring → its 12-char hash from dry-run
  "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run | grep -F "$1" | cut -f1
}

@test "reap --dry-run surfaces the 12-char body hash as leading column (#111)" {
  run "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^[0-9a-f]{12}$(printf '\t')"
}

@test "reap --decisions: discard not drafted + recorded in [discarded]; keep override applied (#111)" {
  local alpha beta dec
  alpha="$(_hash_for 'Alpha candidate body one')"
  beta="$(_hash_for 'Beta candidate body two')"
  [ -n "$alpha" ] && [ -n "$beta" ]
  dec="${BATS_TEST_TMPDIR}/dec.tsv"
  printf '%s\tdiscard\t\t\n%s\tkeep\tbug\tBeta override title\n' "$alpha" "$beta" > "$dec"

  run "${REPO_ROOT}/scripts/capture/reap.sh" --decisions "$dec"
  [ "$status" -eq 0 ]

  # Alpha (discard): no draft cites it.
  run grep -rl 'Alpha candidate body one' "${TMP_DEVDOC}/Captures"
  [ "$status" -ne 0 ]
  # Beta (keep): drafted with the OVERRIDE title and OVERRIDE subtype (bug).
  grep -rqF 'Beta override title' "${TMP_DEVDOC}/Captures"
  run grep -rl 'Beta candidate body two' "${TMP_DEVDOC}/Captures"   # heuristic title NOT used
  [ "$status" -ne 0 ]
  grep -rqF '## Reproduction' "${TMP_DEVDOC}/Captures"               # bug template (override)
  run grep -rl '## Motivation' "${TMP_DEVDOC}/Captures"              # NOT the feature heuristic
  [ "$status" -ne 0 ]

  # State: alpha in [discarded], NOT in [hashes]; beta in [hashes].
  awk '/^\[discarded\]/{d=1;next} /^\[/{d=0} d' "$STATE_FILE" | grep -qF "$alpha"
  awk '/^\[hashes\]/{h=1;next} /^\[/{h=0} h' "$STATE_FILE" | grep -qF "$beta"
  run sh -c "awk '/^\\[hashes\\]/{h=1;next} /^\\[/{h=0} h' '$STATE_FILE' | grep -qF '$alpha'"
  [ "$status" -ne 0 ]
}

@test "reap: a discarded candidate is skipped next run, but re-surfaces once cleared (#111)" {
  local alpha dec
  alpha="$(_hash_for 'Alpha candidate body one')"
  dec="${BATS_TEST_TMPDIR}/dec.tsv"
  printf '%s\tdiscard\t\t\n' "$alpha" > "$dec"
  "${REPO_ROOT}/scripts/capture/reap.sh" --decisions "$dec"

  # Next plain run: alpha stays skipped (still not drafted).
  "${REPO_ROOT}/scripts/capture/reap.sh"
  run grep -rl 'Alpha candidate body one' "${TMP_DEVDOC}/Captures"
  [ "$status" -ne 0 ]

  # Clear the [discarded] entry → alpha re-surfaces in dry-run (re-triageable).
  grep -vF "$alpha" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  run "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Alpha candidate body one"* ]]
}

@test "reap --decisions: title override with EMPTY subtype keeps heuristic subtype (#111 tab-coalesce)" {
  # Empty interior field: `<hash>\tkeep\t\t<title>`. A naive `IFS=$'\t' read`
  # coalesces the tabs and slides the title into the subtype slot → capture
  # rejects it and the candidate is lost. The override title must apply while the
  # heuristic subtype (feature, from imPlan-*) is retained.
  local alpha dec
  alpha="$(_hash_for 'Alpha candidate body one')"
  dec="${BATS_TEST_TMPDIR}/dec.tsv"
  printf '%s\tkeep\t\tAlpha better title\n' "$alpha" > "$dec"
  run "${REPO_ROOT}/scripts/capture/reap.sh" --decisions "$dec"
  [ "$status" -eq 0 ]
  grep -rqF 'Alpha better title' "${TMP_DEVDOC}/Captures"        # override title applied
  grep -rqF '## Motivation' "${TMP_DEVDOC}/Captures"             # heuristic subtype (feature) kept
  run grep -rl '## Reproduction' "${TMP_DEVDOC}/Captures"        # NOT bug
  [ "$status" -ne 0 ]
}

@test "reap --decisions: a last line with no trailing newline is still honored (#111)" {
  # The decisions file is LLM-generated; a missing final newline must not drop
  # the last (only) decision. Discard with NO trailing newline → not drafted.
  local alpha dec
  alpha="$(_hash_for 'Alpha candidate body one')"
  dec="${BATS_TEST_TMPDIR}/dec.tsv"
  printf '%s\tdiscard\t\t' "$alpha" > "$dec"   # NOTE: no trailing \n
  run "${REPO_ROOT}/scripts/capture/reap.sh" --decisions "$dec"
  [ "$status" -eq 0 ]
  run grep -rl 'Alpha candidate body one' "${TMP_DEVDOC}/Captures"
  [ "$status" -ne 0 ]
  awk '/^\[discarded\]/{d=1;next} /^\[/{d=0} d' "$STATE_FILE" | grep -qF "$alpha"
}

@test "reap --decisions: an unknown action fails loud (warns) and defaults to keep (#111)" {
  local beta dec
  beta="$(_hash_for 'Beta candidate body two')"
  dec="${BATS_TEST_TMPDIR}/dec.tsv"
  printf '%s\tDISCARD?typo\t\t\n' "$beta" > "$dec"
  run "${REPO_ROOT}/scripts/capture/reap.sh" --decisions "$dec"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown action"* ]]            # warned, not silent
  grep -rqF 'Beta candidate body two' "${TMP_DEVDOC}/Captures"   # fail-safe: kept
}

@test "reap back-compat: plain run with no --decisions drafts every candidate (#111)" {
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  grep -rqF 'Alpha candidate body one' "${TMP_DEVDOC}/Captures"
  grep -rqF 'Beta candidate body two' "${TMP_DEVDOC}/Captures"
}

@test "reap --decisions: breadcrumb names only kept candidates, not discarded (#229)" {
  # Give Issue-900 a checklist journal so a breadcrumb COULD be written.
  cat > "${TMP_DEVDOC}/Issue-900/checklist.md" <<'CL'
# Issue-900

## Log
- 2026-05-19 09:00  pull: scaffolded
CL
  local alpha beta dec
  alpha="$(_hash_for 'Alpha candidate body one')"
  beta="$(_hash_for 'Beta candidate body two')"
  [ -n "$alpha" ] && [ -n "$beta" ]
  dec="${BATS_TEST_TMPDIR}/dec.tsv"
  # discard alpha, keep beta → breadcrumb must name exactly ONE follow-up.
  printf '%s\tdiscard\t\t\n%s\tkeep\t\t\n' "$alpha" "$beta" > "$dec"
  run "${REPO_ROOT}/scripts/capture/reap.sh" --decisions "$dec"
  [ "$status" -eq 0 ]
  local cl="${TMP_DEVDOC}/Issue-900/checklist.md"
  [ "$(grep -cE ' reap: harvested ' "$cl")" -eq 1 ]
  run grep -E ' reap: harvested 1 follow-up' "$cl"
  [ "$status" -eq 0 ]
}
