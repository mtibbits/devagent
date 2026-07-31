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

# --- #559 U1: rc-precise gate pins. crrf's gate-closed behavior is "run
# file.sh without --yes and branch on exit code 4"; these pin the exit map at
# the SOURCE so the signal crrf depends on cannot drift (Issue-458: two
# same-exit-code states a caller must distinguish get distinct codes minted at
# the source — and a `-ne 0` assertion cannot see them drift together).

@test "file: push_mr closed exits 4, the gate signal crrf branches on (#559)" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 4 ]          # NOT -ne 0: 4 is the contract
}

@test "file: missing draft exits 3, bad target exits 2, distinct from 4 (#559)" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "no-such-slug" --target origin
  [ "$status" -eq 3 ]
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target bogus
  [ "$status" -eq 2 ]
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

@test "file: a stale .pending marker blocks a re-file with no duplicate create (#113)" {
  # A prior filing died after the remote create but before filed.toml — the
  # .pending marker survives. A re-run must refuse rather than file a duplicate.
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  : >"${CAP_DIR}/.pending"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"pending"* ]]
  # the backend create must NOT have run (no duplicate remote issue)
  run grep -c "^verb=create$" "${MOCK_INVOCATION_LOG}"
  [ "$output" -eq 0 ]
  [ ! -f "${CAP_DIR}/filed.toml" ]
}

@test "file: a successful filing clears the .pending marker (#113)" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ -f "${CAP_DIR}/filed.toml" ]
  [ ! -e "${CAP_DIR}/.pending" ]
}

@test "file: a backend create failure retains .pending (#113)" {
  # create fails after being invoked → file.sh aborts before filed.toml; the
  # window stays guarded so a re-run cannot silently duplicate.
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  export MOCK_FORCE_FAIL=1
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [ -e "${CAP_DIR}/.pending" ]
  [ ! -f "${CAP_DIR}/filed.toml" ]
}

@test "file: records the per-backend canonical URL for gitlab, not github (#113)" {
  # file.sh must build the URL from the active backend, not hardcode github.
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_ISSUE_BACKEND=gitlab
  export DEVAGENT_GITLAB_API="https://gitlab.example.com/api/v4"
  export DEVAGENT_REPO_ORIGIN="grp/proj"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  assert_file_grep "${CAP_DIR}/filed.toml" '^url = "https://gitlab.example.com/grp/proj/-/issues/4242"$'
  run grep -q 'github\.com' "${CAP_DIR}/filed.toml"
  [ "$status" -ne 0 ]
}

@test "file: rejects a backend that returns a non-id (URL) and writes no filed.toml (#199)" {
  # A contract-violating backend that emits a full URL instead of a bare number must
  # be caught at the consumer boundary: fail closed, no corrupt filed.toml, and the
  # .pending marker preserved (#113 — the remote create already ran, may exist).
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  export MOCK_RESPONSE_NUM="https://github.com/fakeorg/fake/issues/4242"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* ]]
  [ ! -f "${CAP_DIR}/filed.toml" ]
  [ -e "${CAP_DIR}/.pending" ]
}
