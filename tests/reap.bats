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

@test "reap: a long-title (>=60 char) slug collision still yields two distinct drafts (#252)" {
  # #252: the #108 retry appends the disambiguator to the TITLE, but devagent_slug
  # caps the kebab at 60 chars and slices the suffix off — so two long titles with
  # an identical first-60-char kebab collide forever and the 2nd is deferred, never
  # drafted. The suffix must survive the cap. Two bullets: identical long prefix,
  # the distinguishing token (alpha/beta) sits past kebab char 60, distinct bodies.
  # Fresh Issue-996 isolates the assertion. (The #108 short-title test above passes
  # WITHOUT this fix, so it does not cover this gap.)
  mkdir -p "${TMP_DEVDOC}/Issue-996"
  printf -- '- Allocate the reap slug suffix so that it survives the sixty character truncation cap alpha. Extra alpha body detail.\n- Allocate the reap slug suffix so that it survives the sixty character truncation cap beta. Extra beta body detail.\n' \
    > "${TMP_DEVDOC}/Issue-996/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"capture.sh failed"* ]]   # neither candidate deferred
  mapfile -t drafts < <(grep -rlE 'Issue-996/imPlan-potentialFutureEnhancements\.md' "${TMP_DEVDOC}/Captures"/*/draft.md)
  [ "${#drafts[@]}" -eq 2 ]
  grep -rqE 'imPlan-potentialFutureEnhancements\.md line 1\b' "${TMP_DEVDOC}/Captures"/*/draft.md
  grep -rqE 'imPlan-potentialFutureEnhancements\.md line 2\b' "${TMP_DEVDOC}/Captures"/*/draft.md
  # Idempotent: a second run drafts nothing new (both hashes now seen).
  local before
  before="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  [ "$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)" -eq "${before}" ]
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

@test "reap: numbered-bold [actionable] lesson is titled by its claim, not the list number (#323)" {
  # Fable-era lessons use a NUMBERED bold list: '1. **[actionable] <claim>.** ...'.
  # reap's bullet strip did not match '1.', so the title truncated at the period
  # after the number → junk "1"/"2" titles. The extractor now strips the ordered
  # marker + ** first, reducing the line to the flat-inline form.
  mkdir -p "${TMP_DEVDOC}/Issue-996"
  cat > "${TMP_DEVDOC}/Issue-996/lessonsLearned.md" <<'LL'
# Issue-996 — Lessons learned

## Entries

1. **[actionable] Verify linter fixture severity before writing tests.** SC2086 is info-level, below the cutoff.
2. **[actionable] Test the committed exec bit via the real dispatch path.** The 100644 mode never mattered until the real exec.
LL
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  # titled by the real claim (up to the first period after the tag), not the number
  grep -rqF 'Verify linter fixture severity before writing tests' "${TMP_DEVDOC}/Captures"/*/draft.md
  grep -rqF 'Test the committed exec bit via the real dispatch path' "${TMP_DEVDOC}/Captures"/*/draft.md
  # NO draft is titled by just the list number (the #323 bug)
  run grep -rlE '^# [0-9]+$' "${TMP_DEVDOC}/Captures"/*/draft.md
  [ "$status" -ne 0 ]
}

@test "reap: stamps source issue checklist ## Log naming harvested slugs (#229)" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  cl="${TMP_DEVDOC}/Issue-100/checklist.md"
  run grep -E '^- .* reap: harvested [0-9]+ follow-up\(s\) -> Captures/' "${cl}"
  [ "$status" -eq 0 ]
}

@test "reap: one aggregated breadcrumb per issue, not one per candidate (#229)" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  cl="${TMP_DEVDOC}/Issue-100/checklist.md"
  # Issue-100 yields several candidates but must produce exactly ONE reap line...
  [ "$(grep -cE ' reap: harvested ' "${cl}")" -eq 1 ]
  # ...that names more than one Captures/<slug>.
  run grep -E ' reap: .*Captures/.*, *Captures/' "${cl}"
  [ "$status" -eq 0 ]
}

@test "reap: --dry-run writes no breadcrumb (#229)" {
  "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run >/dev/null
  run grep -E ' reap: ' "${TMP_DEVDOC}/Issue-100/checklist.md"
  [ "$status" -ne 0 ]
}

@test "reap: re-run adds no duplicate breadcrumb (#229)" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$(grep -cE ' reap: harvested ' "${TMP_DEVDOC}/Issue-100/checklist.md")" -eq 1 ]
}

@test "reap: issue without a checklist is harvested normally, exit 0 (#229)" {
  [ ! -f "${TMP_DEVDOC}/Issue-101/checklist.md" ]   # Issue-101 has STUCK only
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  run grep -rl 'Issue-101' "${TMP_DEVDOC}/Captures"
  [ "$status" -eq 0 ]                                # its STUCK still drafted
}

@test "reap: does not modify source artifacts -- read-only on sources (#229)" {
  local before after
  before="$(md5sum "${TMP_DEVDOC}"/Issue-100/imPlan-potentialFutureEnhancements.md \
                   "${TMP_DEVDOC}"/Issue-100/actualWork.md \
                   "${TMP_DEVDOC}"/Issue-100/lessonsLearned.md \
                   "${TMP_DEVDOC}"/Issue-101/STUCK)"
  "${REPO_ROOT}/scripts/capture/reap.sh"
  after="$(md5sum "${TMP_DEVDOC}"/Issue-100/imPlan-potentialFutureEnhancements.md \
                  "${TMP_DEVDOC}"/Issue-100/actualWork.md \
                  "${TMP_DEVDOC}"/Issue-100/lessonsLearned.md \
                  "${TMP_DEVDOC}"/Issue-101/STUCK)"
  [ "${before}" = "${after}" ]
}

@test "reap: one run stamps each source issue separately (fan-out) (#229)" {
  # Issue-100 has a checklist fixture; give Issue-102 one too, so a single run
  # must leave exactly one breadcrumb on EACH (per-issue, not global).
  cat > "${TMP_DEVDOC}/Issue-102/checklist.md" <<'CL'
# Issue-102

## Log
- 2026-05-19 09:00  pull: scaffolded
CL
  "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$(grep -cE ' reap: harvested ' "${TMP_DEVDOC}/Issue-100/checklist.md")" -eq 1 ]
  [ "$(grep -cE ' reap: harvested ' "${TMP_DEVDOC}/Issue-102/checklist.md")" -eq 1 ]
}

@test "reap: scan survives a first issue dir whose actualWork lacks the trigger phrase (#233)" {
  # #233: block 3b ran `grep 'should be its own issue' | while` with no guard.
  # Under set -euo pipefail, grep's exit-1 on no-match aborted the entire scan
  # after the FIRST issue dir that has an actualWork.md. The bundled fixture
  # masks it because Issue-100/actualWork.md happens to contain the phrase.
  # Inject a lexically-FIRST dir whose actualWork lacks the phrase, then assert
  # a LATER dir's candidates (incl. a lessonsLearned [actionable]) still surface.
  mkdir -p "${TMP_DEVDOC}/Issue-099"
  cat > "${TMP_DEVDOC}/Issue-099/actualWork.md" <<'AW'
# Issue-099 — Actual work

## What changed
Nothing notable; no follow-ups here.
AW
  run "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-100/lessonsLearned.md"* ]]
  [[ "$output" == *"Issue-102"* ]]
}

@test "reap: state dir honors DA_HOME when DEVAGENT_STATE_DIR is unset (#237)" {
  # #237: reap.sh:65 hardcoded ${HOME}, ignoring DA_HOME — the lone holdout vs
  # depends.sh (#80). With DEVAGENT_STATE_DIR unset, the reaped ledger must
  # resolve under $DA_HOME (devagent_home() returns DA_HOME as-is, so state is
  # $DA_HOME/state — matching state_path()). Point HOME and DA_HOME at distinct
  # tmp dirs so a regression writes to neither the real $HOME nor where we
  # assert success.
  unset DEVAGENT_STATE_DIR
  local fake_home da_home
  fake_home="$(mktemp -d -t devagent-home.XXXXXX)"
  da_home="$(mktemp -d -t devagent-dahome.XXXXXX)"
  export HOME="${fake_home}" DA_HOME="${da_home}"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  [ -f "${da_home}/state/fake.reaped.toml" ]
  [ ! -e "${fake_home}/.claude/devagent/state/fake.reaped.toml" ]
  rm -rf "${fake_home}" "${da_home}"
}

@test "reap: explicit DEVAGENT_STATE_DIR overrides DA_HOME (#237)" {
  # AC #2: an explicit DEVAGENT_STATE_DIR still wins over DA_HOME.
  local da_home explicit
  da_home="$(mktemp -d -t devagent-dahome.XXXXXX)"
  explicit="$(mktemp -d -t devagent-explicit.XXXXXX)"
  export DA_HOME="${da_home}" DEVAGENT_STATE_DIR="${explicit}"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  [ -f "${explicit}/fake.reaped.toml" ]
  [ ! -e "${da_home}/.claude/devagent/state/fake.reaped.toml" ]
  rm -rf "${da_home}" "${explicit}"
}
