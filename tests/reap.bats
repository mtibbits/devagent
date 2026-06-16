#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  setup_tmp_state
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
  cp -R "${REPO_ROOT}/tests/fixtures/reap-devdoc/." "${TMP_DEVDOC}/"
}

teardown() {
  teardown_tmp_devdoc
  teardown_tmp_state
}

@test "reap: first run produces drafts for each candidate" {
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  found="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  [ "${found}" -ge 4 ]
}

@test "reap: each draft cites its source" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  for d in "${TMP_DEVDOC}"/Captures/*/draft.md; do
    grep -qE 'Issue-(100|101|102)' "${d}"
  done
}

@test "reap: idempotent — second run produces no new drafts" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  first="$(find "${TMP_DEVDOC}/Captures" -name draft.md | sort)"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  second="$(find "${TMP_DEVDOC}/Captures" -name draft.md | sort)"
  [ "${first}" = "${second}" ]
}

@test "reap: state file records content hashes" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  state="${DEVAGENT_STATE_DIR}/fake.reaped.toml"
  [ -f "${state}" ]
  grep -qE '^[0-9a-f]{12} = ' "${state}"
}

@test "reap: editing a source's wording (cosmetic) does NOT re-reap" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  before="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  sed -i 's/Add benchmark for the alternative AVX-512 dispatch./  add  benchmark  for  the  alternative  AVX-512  DISPATCH.  /' \
    "${TMP_DEVDOC}/Issue-100/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  after="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  [ "${before}" = "${after}" ]
}

@test "reap: adding a NEW item to a source produces exactly one new draft" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  before="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  printf -- '- Brand new follow-up item never seen before.\n' \
    >>"${TMP_DEVDOC}/Issue-102/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  after="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  [ "$((after - before))" -eq 1 ]
}

@test "reap: --dry-run reports candidates without writing anything" {
  run "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-100"* ]]
  found="$(find "${TMP_DEVDOC}/Captures" -name draft.md 2>/dev/null | wc -l)"
  [ "${found}" -eq 0 ]
  [ ! -f "${DEVAGENT_STATE_DIR}/fake.reaped.toml" ]
}

@test "reap: missing DEVAGENT_PROJECT is an error" {
  unset DEVAGENT_PROJECT
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVAGENT_PROJECT"* ]]
}

@test "reap: a literal tab in a source bullet does not corrupt the TSV fields (#109)" {
  # A future-enhancements bullet with a literal tab (pasted/aligned text). On the
  # raw (unflattened) emitter the tab shifts the TAB-separated fields, corrupting
  # the source citation; the flatten must keep it intact. Fresh Issue-999 so the
  # bullet's draft is the only thing that can cite Issue-999.
  mkdir -p "${TMP_DEVDOC}/Issue-999"
  printf -- '- Refactor\tthe widget cache for clarity. Some detail.\n' \
    > "${TMP_DEVDOC}/Issue-999/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  grep -rqE 'Issue-999/imPlan-potentialFutureEnhancements\.md' "${TMP_DEVDOC}/Captures"/*/draft.md
}
