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

@test "capture-family setup redirects HOME to a throwaway tree (#106 F12)" {
  # setup_tmp_devdoc must point HOME at a tmp dir so a capture script that fell back
  # to paths.sh defaults ($HOME/.claude/devagent) can never touch real user state.
  [ -n "${TMP_HOME:-}" ]
  [ "${HOME}" = "${TMP_HOME}" ]
  [ -d "${HOME}" ]
}

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
  draft="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
  printf 'SENTINEL\n' >> "${draft}"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  # #559 U4: rc-precise — 3 is the collision signal crrf's promote loop
  # branches on, and the first body must survive byte-intact (a --force here
  # would be Issue-558's fail-open wrong-body write).
  [ "$status" -eq 3 ]
  [[ "$output" == *"already exists"* ]]
  grep -qF 'SENTINEL' "${draft}"
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

# --- #424: capture template chain routes through the §12 registry --------------
# Helper: write a HOME config with a [project.fake.paths] override for KEY→PATH.
_capture_set_paths_override() {
  local key="$1" path="$2"
  mkdir -p "$HOME/.claude/devagent"
  cat > "$HOME/.claude/devagent/config.toml" <<EOF
[project.fake]
devdoc_dir = "${TMP_DEVDOC}"

[project.fake.paths]
${key} = "${path}"
EOF
}

@test "capture: honors [project.X.paths].issue_template-bug config-paths override (layer 1)" {
  # Seed a devdoc template (layer 2) that would win under the pre-fix chain...
  mkdir -p "${TMP_DEVDOC}/templates"
  printf '# %s — CAPTURE_DEVDOC_424\n' '{{title}}' \
    > "${TMP_DEVDOC}/templates/issue_template-bug.md"
  # ...and a config-paths override (layer 1) with a UNIQUE sentinel.
  printf '# %s — CAPTURE_SENTINEL_424\n' '{{title}}' \
    > "${TMP_HOME}/custom_bug_template.md"
  _capture_set_paths_override "issue_template-bug" "${TMP_HOME}/custom_bug_template.md"

  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Weeds"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-weeds/draft.md"
  grep -q "CAPTURE_SENTINEL_424" "${draft}"          # layer 1 rendered
  run grep -q "CAPTURE_DEVDOC_424" "${draft}"
  [ "$status" -ne 0 ]                                 # layer 2 did NOT win
}

@test "capture: DEVAGENT_TEMPLATE_OVERRIDE_* env still wins over a config-paths override" {
  printf '# %s — CAPTURE_CONFIG_424\n' '{{title}}' \
    > "${TMP_HOME}/config_bug_template.md"
  _capture_set_paths_override "issue_template-bug" "${TMP_HOME}/config_bug_template.md"
  printf '# %s — CAPTURE_ENV_424\n' '{{title}}' \
    > "${TMP_HOME}/env_bug_template.md"
  export DEVAGENT_TEMPLATE_OVERRIDE_issue_template_bug="${TMP_HOME}/env_bug_template.md"

  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Aphids"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-aphids/draft.md"
  grep -q "CAPTURE_ENV_424" "${draft}"               # env layer (highest) rendered
  run grep -q "CAPTURE_CONFIG_424" "${draft}"
  [ "$status" -ne 0 ]                                 # config-paths did NOT win
}

@test "capture: warns and falls through when the configured override file is missing" {
  _capture_set_paths_override "issue_template-bug" "${TMP_HOME}/does_not_exist_424.md"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Locusts"
  [ "$status" -eq 0 ]                                 # falls through to plugin layer
  [[ "$output" == *"configured override for 'issue_template-bug' not found"* ]]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-locusts/draft.md"
  [ -f "${draft}" ]                                   # draft still rendered
}

# #559 U4: the collision half of the promote-loop pin was tightened into the
# existing overwrite-refusal test above (rc 3 + SENTINEL); only --slug-suffix
# coverage is new (#252 — the disambiguator crrf's promote loop mandates).

@test "capture: --slug-suffix disambiguates a promoted child (#559 U4)" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --slug-suffix 02
  [ "$status" -eq 0 ]
  [ "$output" != "2026-05-19-corn-planting" ]
  [ -f "${TMP_DEVDOC}/Captures/${output}/draft.md" ]
}

# --- #597: --body-file writes a supplied body instead of the template -------

_597_body() {   # $1 = H1 text; writes "${BODY}" and echoes nothing
  BODY="${BATS_TEST_TMPDIR}/body-${BATS_TEST_NUMBER}.md"
  printf '# %s\n\nHarvested body, not the template.\n' "$1" > "${BODY}"
}

@test "capture: --body-file writes the supplied body verbatim (#597 AC1)" {
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-corn-planting" ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
  cmp "${BODY}" "${draft}"                       # byte-identical, not "contains"
  run grep -F 'Acceptance criteria' "${draft}"   # the template did NOT render
  [ "$status" -eq 1 ]
}

@test "capture: --body-file H1 != --title exits 5 and writes nothing (#597 AC1)" {
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Soy planting" --body-file "${BODY}"
  [ "$status" -eq 5 ]                            # rc-precise: not 2, not 3
  [[ "$output" == *"H1"* ]]
  [[ "$output" == *"Soy planting"* ]]
  # fail BEFORE any side effect: no capture dir, no draft
  [ ! -e "${TMP_DEVDOC}/Captures/2026-05-19-soy-planting" ]
}

@test "capture: --body-file with no '# ' heading exits 5 (#597 AC1)" {
  BODY="${BATS_TEST_TMPDIR}/noh1.md"
  printf 'Corn planting\n=====\n' > "${BODY}"    # setext H1: file.sh cannot read it either
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}"
  [ "$status" -eq 5 ]
  [[ "$output" == *"H1"* ]]
}

@test "capture: --body-file that does not exist is a usage error (#597 AC1)" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${BATS_TEST_TMPDIR}/absent.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--body-file not found"* ]]   # NOT "--body-file": HEAD's "unknown arg" has it
}

@test "capture: --body-file H1 equality is what file.sh will read (#597 AC1)" {
  # Delegation pin: the accepted body's H1, read by the SAME function file.sh
  # calls for the tracker title, equals --title. No re-spelled awk here
  # (register: devagent Issue-94 equivalence by construction; Issue-585).
  source "${REPO_ROOT}/scripts/capture/lib/draft.sh"
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/${output}/draft.md"
  [ "$(devagent_draft_h1 "${draft}")" = "Corn planting" ]
}

@test "capture: --body-file --type epic accepts '# Epic: <title>' (#597 AC1, A2)" {
  _597_body "Epic: Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type epic --title "Corn planting" --body-file "${BODY}"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-corn-planting" ]
  cmp "${BODY}" "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
}

@test "capture: --body-file --type epic with a bare '# <title>' exits 5 (#597 AC1, A2)" {
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type epic --title "Corn planting" --body-file "${BODY}"
  [ "$status" -eq 5 ]
  [[ "$output" == *"Epic: Corn planting"* ]]     # the message shows the EXPECTED H1
  [ ! -e "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting" ]
}

# --- #597: --on-collision suffix resolves a sibling slug collision ----------

_597_seed_sibling() {   # captures _597_body at the base slug; writes a DIFFERENT same-title body to "${B2}"
  _597_body "Corn planting"
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}" >/dev/null
  B2="${BATS_TEST_TMPDIR}/b2.md"
  printf '# Corn planting\n\nA DIFFERENT sibling.\n' > "${B2}"
}

_597_ndirs() {   # how many corn-planting capture dirs exist
  ls -1d "${TMP_DEVDOC}"/Captures/2026-05-19-corn-planting* | wc -l
}

@test "capture: default collision behavior is unchanged by the new flags (#597 AC3)" {
  _597_seed_sibling
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${B2}"
  [ "$status" -eq 3 ]                            # no --on-collision ⇒ the #559 U4 signal
  [[ "$output" == *"already exists"* ]]
  grep -qF 'not the template' \
    "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"   # first body intact
}

@test "capture: --on-collision suffix resolves a DIFFERENT-body collision (#597 AC2)" {
  _597_seed_sibling
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${B2}" --on-collision suffix
  [ "$status" -eq 0 ]
  [ "$output" != "2026-05-19-corn-planting" ]
  [ -f "${TMP_DEVDOC}/Captures/${output}/draft.md" ]
  cmp "${B2}" "${TMP_DEVDOC}/Captures/${output}/draft.md"
  # the SIBLING was not overwritten (crrf's "never pass --force" invariant)
  grep -qF 'not the template' \
    "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
}

@test "capture: the collision suffix IS the #252 content-derived one (#597 AC2)" {
  # Delegation pin: the suffix equals reap.sh's ${h:0:6}, not a second scheme.
  source "${REPO_ROOT}/scripts/capture/lib/hash.sh"
  _597_seed_sibling
  h="$(devagent_hash_text "$(cat "${B2}")")"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${B2}" --on-collision suffix
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-corn-planting-${h:0:6}" ]
}

@test "capture: an identical-body re-run is idempotent (#597 AC2)" {
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${BODY}" --on-collision suffix
  [ "$status" -eq 0 ]
  first="$output"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${BODY}" --on-collision suffix
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$first" ]                  # same slug printed
  [[ "$output" == *"nothing written"* ]]         # and the no-op says so (#597 redmr)
  [ "$(_597_ndirs)" -eq 1 ]                      # and no second directory was minted
}

@test "capture: --on-collision suffix requires --body-file (#597 AC2)" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --on-collision suffix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--on-collision suffix requires --body-file"* ]]   # the specific message
}

@test "capture: an unknown --on-collision value is a usage error (#597 AC2)" {
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${BODY}" --on-collision clobber
  [ "$status" -eq 2 ]
  [[ "$output" == *"--on-collision must be fail|suffix"* ]]
}

@test "capture: re-running a suffixed (different) body is idempotent too (#597 AC2)" {
  _597_seed_sibling
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${B2}" --on-collision suffix
  [ "$status" -eq 0 ]
  first="$output"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${B2}" --on-collision suffix
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$first" ]                  # the SAME suffixed slug
  [[ "$output" == *"nothing written"* ]]
  [ "$(_597_ndirs)" -eq 2 ]                      # base + one suffixed, no third
}

@test "capture: a whitespace/case variant of an existing body is that body (#597 AC2, A5)" {
  _597_body "Corn planting"
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}" >/dev/null
  V="${BATS_TEST_TMPDIR}/variant.md"
  printf '# Corn planting\n\n  HARVESTED   body, not the TEMPLATE.\n\n\n' > "${V}"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${V}" --on-collision suffix
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "2026-05-19-corn-planting" ] # the existing slug
  [[ "$output" == *"nothing written"* ]]         # an edited-but-equivalent body is not silently dropped
  cmp "${BODY}" "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"  # untouched
  [ "$(_597_ndirs)" -eq 1 ]
}

@test "capture: --slug-suffix with --on-collision suffix is a usage error (#597 A3)" {
  _597_body "Corn planting"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --slug-suffix 02 \
    --body-file "${BODY}" --on-collision suffix
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]      # NOT "--slug-suffix": HEAD's usage has it
  [ ! -e "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting-02" ]
}

@test "capture: --force with --on-collision suffix is a usage error (#597 review I1)" {
  _597_seed_sibling
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --force \
    --body-file "${B2}" --on-collision suffix
  [ "$status" -eq 2 ]
  [[ "$output" == *"--force and --on-collision suffix are mutually exclusive"* ]]
  grep -qF 'not the template' \
    "${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"   # the sibling survives
  [ "$(_597_ndirs)" -eq 1 ]
}

@test "capture: a --body-file collision names --on-collision suffix before --force (#597 review M2)" {
  _597_seed_sibling
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${B2}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"--on-collision suffix"*"--force"* ]]   # the sanctioned remedy first (volk Fork-132)
}

@test "capture: the flag-less collision message is byte-unchanged (#597 review M2)" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -eq 3 ]
  [ "$output" = "draft already exists: ${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md (use --force to overwrite)" ]
}

@test "capture: --body-file naming the destination draft is refused, draft intact (#597 redmr)" {
  _597_body "Corn planting"
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}" >/dev/null
  draft="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
  cp "${draft}" "${BATS_TEST_TMPDIR}/before.md"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${draft}" --force
  [ "$status" -eq 2 ]
  [[ "$output" == *"--body-file is the destination draft"* ]]
  cmp "${BATS_TEST_TMPDIR}/before.md" "${draft}"   # cat > would have truncated it (Issue-558)
}

@test "capture: --body-file with an empty '# ' heading exits 5 naming it empty (#597 review M3)" {
  BODY="${BATS_TEST_TMPDIR}/emptyh1.md"
  printf '# \n\nBody under an empty heading.\n' > "${BODY}"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --body-file "${BODY}"
  [ "$status" -eq 5 ]
  [[ "$output" == *"no non-empty '# ' H1 heading"* ]]
}

@test "capture: an occupied suffixed slug exits 3 with a remedy, never --force (#597 AC2)" {
  # Branch 6: a genuine 6-hex collision is contrived, so PLANT a different
  # draft at the suffixed slug the real body would take.
  source "${REPO_ROOT}/scripts/capture/lib/hash.sh"
  _597_seed_sibling
  h="$(devagent_hash_text "$(cat "${B2}")")"
  occupied="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting-${h:0:6}"
  mkdir -p "${occupied}"
  printf '# Corn planting\n\nA third, unrelated body.\n' > "${occupied}/draft.md"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --body-file "${B2}" --on-collision suffix
  [ "$status" -eq 3 ]
  [[ "$output" == *"distinct --title"* ]]        # the printed remedy (volk Fork-132)
  [[ "$output" != *"--force"* ]]                 # never the sibling-overwriting bypass
  grep -qF 'third, unrelated' "${occupied}/draft.md"   # the occupant survives
}

# --- #597: crrf.md's promote-loop fence is EXECUTED, not just read ----------
# Coupling: commands/crrf.md's "## 2. Capture" bash fence is extracted and run
# here. Editing that fence's flags edits this test (register: Issue-461/583).

_597_fence() {   # the first bash fence under crrf.md's "## 2. Capture" heading
  awk '/^## 2\. Capture/{s=1;next} s&&/^## /{exit} s&&/^```bash$/{f=1;next} f&&/^```$/{exit} f' \
    "${REPO_ROOT}/commands/crrf.md"
}

@test "capture: crrf.md's promote fence names the #597 flags (#597 AC4)" {
  FENCE="$(_597_fence)"
  [ -n "$FENCE" ]                                # anti-vacuous (register: Issue-151)
  [[ "$FENCE" == *"--body-file"* ]]
  [[ "$FENCE" == *"--on-collision suffix"* ]]
  run grep -F -- '--slug-suffix' "${REPO_ROOT}/commands/crrf.md"
  [ "$status" -eq 1 ]                            # the manual retry prose is gone
}

@test "capture: crrf.md's promote fence actually runs (#597 AC4)" {
  FENCE="$(_597_fence)"
  [ -n "$FENCE" ]
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
  CHILD="${BATS_TEST_TMPDIR}/epic dir/children/01-corn-planting.md"   # a space, as real devdoc paths have
  mkdir -p "$(dirname "${CHILD}")"
  printf '# Corn planting\n\nScaffolded child body.\n' > "${CHILD}"
  CMD="${FENCE//<bug|feature|docs|perf|chore>/bug}"
  CMD="${CMD//\"<child title>\"/\"Corn planting\"}"
  CMD="${CMD//\"<epic-dir>\/children\/NN-<kebab-title>.md\"/\"${CHILD}\"}"
  run bash -c "$CMD"
  [ "$status" -eq 0 ]
  [ -f "${TMP_DEVDOC}/Captures/${output}/draft.md" ]
  cmp "${CHILD}" "${TMP_DEVDOC}/Captures/${output}/draft.md"
}
