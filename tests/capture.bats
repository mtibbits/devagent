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

# --- #559 U4: promote-loop collision pins. crrf promotes each scaffolded
# child into its own top-level capture; two children of one epic filed the
# same day can collide on the date-plus-title slug. The worst failure is not a
# crash but a WRONG BODY under a reused slug (Issue-558's fail-open class) —
# pin both directions: collisions are detectable (rc 3, first draft intact),
# and --slug-suffix (#252) mints a distinct slug.

@test "capture: a colliding title exits 3 and does NOT overwrite (#559 U4)" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
  printf 'SENTINEL\n' >> "${draft}"
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -eq 3 ]                       # detectable, not silent
  grep -qF 'SENTINEL' "${draft}"            # first body byte-intact
}

@test "capture: --slug-suffix disambiguates a promoted child (#559 U4)" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --slug-suffix 02
  [ "$status" -eq 0 ]
  [ "$output" != "2026-05-19-corn-planting" ]
  [ -f "${TMP_DEVDOC}/Captures/${output}/draft.md" ]
}
