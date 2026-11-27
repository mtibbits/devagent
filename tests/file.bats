#!/usr/bin/env bats

load 'helpers'
load 'helpers/devdoc-repo'
bats_require_minimum_version 1.5.0

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
  # #1055: helpers/devdoc-repo writes its git wrappers under DEVAGENT_TMP.
  export DEVAGENT_TMP="${TMP_HOME}"
  unset DEVAGENT_DEVDOC_LOCK_TOKEN DEVAGENT_DEVDOC_LOCK_DEADLINE
}

teardown() {
  rm -f "${MOCK_INVOCATION_LOG:-}"
  teardown_tmp_devdoc
}

@test "file: with push_mr=false, refuses without --yes" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 4 ]   # NOT -ne 0: 4 is the gate signal crrf branches on (#559 U1)
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

# #559 U1: the exit map is pinned rc-precise at the SOURCE (4 = gate, 3 =
# draft/state, 2 = usage) because crrf branches on it — tightened into the
# existing gate and missing-draft tests rather than duplicated (Issue-458:
# a surviving `-ne 0` twin cannot see the codes drift). 9 = refused by a trust
# policy (#713) needs a policy fixture, so it is pinned rc-precise in
# tests/trust-gates.bats ("file.sh --yes under trust exits 9") and
# tests/trust-entry.bats. Only the bad-target case is new:

@test "file: bad --target exits 2, distinct from gate 4 and draft 3 (#559)" {
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
  [ "$status" -eq 3 ]   # NOT -ne 0: 3 = draft/state, distinct from gate 4 (#559 U1)
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

# ---------------------------------------------------------------------------
# #1055: with commit_devdoc = true in the config of the project that owns
# DEVAGENT_DEVDOC_DIR, a filing commits Captures/<slug>/ alone, under the devDoc
# lock; best effort (a failure warns, the exit stays 0).
# ---------------------------------------------------------------------------

# _owner_config <true|false> — a config whose project `fake` owns TMP_DEVDOC.
_owner_config() {
  mkdir -p "${HOME}/.claude/devagent"
  cat > "${HOME}/.claude/devagent/config.toml" <<EOF
[project.fake]
source_dir = "${TMP_HOME}/src"
devdoc_dir = "${TMP_DEVDOC}"

[project.fake.issue_source]
backend = "github"
repo    = "fakeorg/fake"

[project.fake.permissions]
commit_devdoc = $1
EOF
}

# _git_devdoc — TMP_DEVDOC as a git repository: another issue and another
# capture are committed, then both are left modified; the setup's capture stays
# untracked, as in real use.
_git_devdoc() {
  mkdir -p "${TMP_DEVDOC}/Issue-7" "${TMP_DEVDOC}/Captures/other"
  printf '# Issue-7\n' > "${TMP_DEVDOC}/Issue-7/checklist.md"
  printf '# other\n' > "${TMP_DEVDOC}/Captures/other/draft.md"
  ( cd "${TMP_DEVDOC}" && git -c init.defaultBranch=main init -q \
    && git add -A -- Issue-7 Captures/other \
    && git -c user.email=t@example.com -c user.name=Test commit -q -m seed )
  printf 'edit\n' >> "${TMP_DEVDOC}/Issue-7/checklist.md"
  printf 'edit\n' >> "${TMP_DEVDOC}/Captures/other/draft.md"
}

_dd_count() { git -C "${TMP_DEVDOC}" rev-list --count HEAD; }

@test "file: commit_devdoc=true commits only Captures/<slug>/ after filing (#1055)" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  _owner_config true; _git_devdoc
  DEVAGENT_GIT="$(devdoc_git_logging_wrapper "${TMP_HOME}/git.log")"; export DEVAGENT_GIT
  before="$(_dd_count)"
  run --separate-stderr "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/fakeorg/fake/issues/4242" ]
  [ "$(_dd_count)" -eq $((before + 1)) ]
  [ "$(git -C "${TMP_DEVDOC}" log -1 --format=%s)" = "devdoc: file ${SLUG} as fakeorg/fake#4242" ]
  run git -C "${TMP_DEVDOC}" log -1 --name-only --format=
  while IFS= read -r p; do [[ -z "$p" || "$p" == "Captures/${SLUG}/"* ]]; done <<< "$output"
  [[ "$output" == *"Captures/${SLUG}/filed.toml"* ]]
  [[ "$output" == *"Captures/${SLUG}/draft.md"* ]]
  [[ "$output" != *".pending"* ]]
  run git -C "${TMP_DEVDOC}" status --porcelain
  [[ "$output" == *" M Issue-7/checklist.md"* ]]
  [[ "$output" == *" M Captures/other/draft.md"* ]]
  # the commit ran under the devDoc lock, held by file.sh
  run awk -F'\t' '$1 == "commit" { print $6 "\t" $8 }' "${TMP_HOME}/git.log"
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" != "-"* ]]
  [[ "${lines[0]}" == *$'\t'"file.sh" ]]
}

@test "file: commit_devdoc=false makes no devDoc commit and takes no lock (#1055)" {
  export DEVAGENT_PERMISSION_PUSH_MR=true DEVAGENT_DEVDOC_LOCK_TIMEOUT=0
  _owner_config false; _git_devdoc
  DEVAGENT_GIT="$(devdoc_git_logging_wrapper "${TMP_HOME}/git.log")"; export DEVAGENT_GIT
  hp="$(devdoc_lock_stub_holder "${TMP_DEVDOC}" Issue-5)"
  cp "${hp}/holder" "${TMP_HOME}/holder.before"
  before="$(_dd_count)"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  [ -f "${CAP_DIR}/filed.toml" ]
  [ "$(_dd_count)" -eq "$before" ]
  [ "$(awk -F'\t' '$1 == "add" || $1 == "commit"' "${TMP_HOME}/git.log" 2>/dev/null | wc -l)" -eq 0 ]
  [[ "$output" != *"devdoc lock"* ]]
  cmp "${hp}/holder" "${TMP_HOME}/holder.before"
}

@test "file: a devDoc outside git makes no commit and takes no lock (#1055)" {
  export DEVAGENT_PERMISSION_PUSH_MR=true DEVAGENT_DEVDOC_LOCK_TIMEOUT=0
  _owner_config true
  hp="$(devdoc_lock_stub_holder "${TMP_DEVDOC}" Issue-5)"
  [ "$hp" = "$(cd "${TMP_DEVDOC}" && pwd -P)/.devagent-wbs.lock" ]
  cp "${hp}/holder" "${TMP_HOME}/holder.before"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  [ -f "${CAP_DIR}/filed.toml" ]
  [[ "$output" != *"devdoc lock"* ]]
  [[ "$output" != *"WARNING"* ]]
  cmp "${hp}/holder" "${TMP_HOME}/holder.before"
}

@test "file: a held devDoc lock warns, exits 0 and keeps the filed issue (#1055)" {
  export DEVAGENT_PERMISSION_PUSH_MR=true DEVAGENT_DEVDOC_LOCK_TIMEOUT=0
  _owner_config true; _git_devdoc
  hp="$(devdoc_lock_stub_holder "${TMP_DEVDOC}" Issue-5)"
  cp "${hp}/holder" "${TMP_HOME}/holder.before"
  before="$(_dd_count)"
  run --separate-stderr "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/fakeorg/fake/issues/4242" ]
  [[ "$stderr" == *"file.sh: WARNING: devdoc commit of ${CAP_DIR} skipped - devdoc lock timeout; commit it by hand:"* ]]
  [ -f "${CAP_DIR}/filed.toml" ]
  [ "$(grep -c '^verb=create$' "${MOCK_INVOCATION_LOG}")" -eq 1 ]
  [ "$(_dd_count)" -eq "$before" ]
  cmp "${hp}/holder" "${TMP_HOME}/holder.before"
  grep -qx 'pid=4242' "${hp}/holder"
}
