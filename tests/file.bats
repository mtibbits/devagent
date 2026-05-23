#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
  export DEVAGENT_ISSUE_BACKEND_DIR="${REPO_ROOT}/tests/fixtures/mock-backend/issue"
  export MOCK_INVOCATION_LOG
  MOCK_INVOCATION_LOG="$(mktemp -t devagent-mock.XXXXXX.log)"
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  SLUG="2026-05-19-corn-planting"
  CAP_DIR="${TMP_DEVDOC}/Captures/${SLUG}"
}

teardown() {
  rm -f "${MOCK_INVOCATION_LOG:-}"
  teardown_tmp_devdoc
}

@test "file: with push_mr=false, refuses without --yes" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"push_mr"* ]] || [[ "$output" == *"permission"* ]]
}

@test "file: with push_mr=false and --yes, proceeds and writes filed.toml" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin --yes
  [ "$status" -eq 0 ]
  filed="${CAP_DIR}/filed.toml"
  [ -f "${filed}" ]
  assert_file_grep "${filed}" '^issue_num = "4242"$'
  assert_file_grep "${filed}" '^url = "https://github.com/fakeorg/fake/issues/4242"$'
  assert_file_grep "${filed}" '^repo = "fakeorg/fake"$'
  assert_file_grep "${filed}" '^target = "origin"$'
}

@test "file: with push_mr=true, proceeds silently" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  [ -f "${CAP_DIR}/filed.toml" ]
}

@test "file: target fork uses DEVAGENT_REPO_FORK" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_FORK="me/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target fork
  [ "$status" -eq 0 ]
  assert_file_grep "${CAP_DIR}/filed.toml" '^repo = "me/fake"$'
}

@test "file: invokes backend create with the draft body" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  grep -q "^verb=create$" "${MOCK_INVOCATION_LOG}"
  grep -q "^repo=fakeorg/fake$" "${MOCK_INVOCATION_LOG}"
  grep -q "^title=Corn planting$" "${MOCK_INVOCATION_LOG}"
}

@test "file: refuses to file an already-filed capture" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"already filed"* ]]
}

@test "file: --refile re-files after filed.toml exists" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  export MOCK_RESPONSE_NUM=9999
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin --refile
  [ "$status" -eq 0 ]
  assert_file_grep "${CAP_DIR}/filed.toml" '^issue_num = "9999"$'
}

@test "file: missing draft.md is an error" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "nope-2026-05-19-x" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"draft.md"* ]]
}
