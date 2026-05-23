#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
}

teardown() { teardown_tmp_devdoc; }

@test "capture: --type issue writes draft.md with bug template by default" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -eq 0 ]
  slug="2026-05-19-corn-planting"
  draft="${TMP_DEVDOC}/Captures/${slug}/draft.md"
  [ -f "${draft}" ]
  assert_file_grep "${draft}" "^# Corn planting$"
  assert_file_grep "${draft}" "## Acceptance criteria"
  [[ "$output" == *"${slug}"* ]]
}

@test "capture: --type epic uses epic template" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type epic --title "Performance overhaul"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-performance-overhaul/draft.md"
  assert_file_grep "${draft}" "^# Epic: Performance overhaul$"
  assert_file_grep "${draft}" "## Estimated children"
}

@test "capture: refuses to overwrite an existing draft without --force" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "capture: --force overwrites existing draft" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --force
  [ "$status" -eq 0 ]
}

@test "capture: --source records source citation in {{source}} slot" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --source "Issue-676/imPlan-potentialFutureEnhancements.md line 42"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
  assert_file_grep "${draft}" "Issue-676/imPlan-potentialFutureEnhancements.md line 42"
}

@test "capture: missing --title is an error" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" --type issue --subtype bug
  [ "$status" -ne 0 ]
  [[ "$output" == *"--title"* ]]
}

@test "capture: unknown --subtype is an error" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype nonesuch --title "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subtype"* ]]
}
