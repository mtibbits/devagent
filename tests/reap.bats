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

@test "reap: state file is written atomically via rename (#110)" {
  # A bare > redirect truncates the state file in place (same inode); a crash
  # mid-write leaves it truncated, and the next reap re-captures everything. The
  # mktemp+mv idiom replaces the file by atomic rename, so it is never observed
  # partial. Proxy for atomicity: the inode must change across a rewrite, and no
  # temp leftovers may remain.
  "${REPO_ROOT}/scripts/capture/reap.sh"
  state="${DEVAGENT_STATE_DIR}/fake.reaped.toml"
  [ -f "${state}" ]
  ino_before="$(stat -c %i "${state}")"
  "${REPO_ROOT}/scripts/capture/reap.sh"
  [ -f "${state}" ]
  ino_after="$(stat -c %i "${state}")"
  [ "${ino_before}" != "${ino_after}" ]
  run find "${DEVAGENT_STATE_DIR}" -name '.fake.reaped.*'
  [ -z "${output}" ]
}

@test "reap: slug-collision candidates do not clobber each other (#108)" {
  # Two future-enhancement bullets whose first-sentence titles kebab to the same
  # slug on the same day, but whose bodies differ (so both pass the seen-hash
  # gate). With --force the second capture overwrote the first's draft while both
  # hashes were recorded seen, so the first was permanently lost. Dropping --force
  # and retrying capture.sh exit 3 with a short hash suffix must yield TWO distinct
  # drafts, both citing the source issue. Fresh Issue-998 isolates the assertion.
  mkdir -p "${TMP_DEVDOC}/Issue-998"
  printf -- '- Tune the widget cache eviction policy. First variant detail alpha.\n- Tune the widget cache eviction policy. Second variant detail beta.\n' \
    > "${TMP_DEVDOC}/Issue-998/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  mapfile -t drafts < <(grep -rlE 'Issue-998/imPlan-potentialFutureEnhancements\.md' "${TMP_DEVDOC}/Captures"/*/draft.md)
  [ "${#drafts[@]}" -eq 2 ]
  # both source lines survive — line 1 (first candidate) and line 2 (second).
  grep -rqE 'imPlan-potentialFutureEnhancements\.md line 1\b' "${TMP_DEVDOC}/Captures"/*/draft.md
  grep -rqE 'imPlan-potentialFutureEnhancements\.md line 2\b' "${TMP_DEVDOC}/Captures"/*/draft.md
}

@test "reap: structured [actionable] lesson is titled by its heading, not 'Tags' (#112)" {
  # Canonical lessonsLearned: '### <claim>' heading + '- Tags: [actionable]'. reap
  # used to grep the tag line and title the draft 'Tags: [actionable]', losing the
  # claim. It must now lift the enclosing heading. A commented <!-- example --> with
  # [actionable] must NOT be harvested. Fresh Issue-997 isolates the assertion.
  mkdir -p "${TMP_DEVDOC}/Issue-997"
  cat > "${TMP_DEVDOC}/Issue-997/lessonsLearned.md" <<'LL'
# Issue-997 — Lessons learned

## Entries

### Pre-commit hook would catch the SC2314 gate before push
- Evidence: PR #201 sc2314 failure
- Consequence: add a local hook.
- Tags: [actionable]

<!--
Examples (delete before saving):
### bogus commented example must not be harvested
- Tags: [actionable]
-->
LL
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  # the real claim heading becomes a draft, titled by the claim (not "Tags")
  grep -rqF 'Pre-commit hook would catch the SC2314 gate before push' "${TMP_DEVDOC}/Captures"/*/draft.md
  run grep -rl 'Tags: \[actionable\]' "${TMP_DEVDOC}/Captures"/*/draft.md
  [ "$status" -ne 0 ]
  # the commented example was not harvested
  run grep -rl 'bogus commented example' "${TMP_DEVDOC}/Captures"/*/draft.md
  [ "$status" -ne 0 ]
}
