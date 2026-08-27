#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "template.sh list shows all keys with their layer" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "mr_template"
  echo "$output" | grep -q "layer=plugin"
}

@test "template resolves the project via the documented chain with no --project/env (#331)" {
  DEVAGENT_ACTIVE_PROJECT='' run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
}

@test "template.sh list resolves plugin layer without env injection (#81)" {
  # Drop the test-only env vars that previously masked broken resolution;
  # config_get_project_field + plugin_root (self-sourced) must carry it.
  run env -u DEVAGENT_PLUGIN_TEMPLATES -u DEVAGENT_REPO_ROOT -u DEVAGENT_TEST_DEVDOC \
    bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=plugin"
  # mr_template resolved (it reported MISSING in real use before the fix)
  echo "$output" | grep mr_template | grep -vq MISSING
}

@test "template.sh show prints layer banner and content" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show coding_standards
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "devdoc override"
}

@test "template.sh show on missing template exits non-zero" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show no_such_thing
  [ "$status" -ne 0 ]
}

@test "template.sh: project override wins over devdoc, shown in banner" {
  override="${TEST_TMP}/proj_standards.md"
  printf '# project layer override\n' > "${override}"
  export TEMPLATE_PATHS_OVERRIDE_coding_standards="${override}"
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show coding_standards
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=project"
  echo "$output" | grep -q "project layer override"
}

@test "template list includes the checklist + revision_block keys (#120)" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh"     --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  [[ "$output" == *checklist-standard* ]]
  [[ "$output" == *checklist-research* ]]
  [[ "$output" == *revision_block* ]]
}

@test "intent_template key resolves at the plugin layer (#284)" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh"     --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  [[ "$output" == *intent_template* ]]
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh"     --project "${DEVAGENT_TEST_PROJECT}" show intent_template
  [ "$status" -eq 0 ]
  [[ "$output" != *MISSING* ]]
}

@test "potholes register key resolves at the plugin layer (#286)" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh"     --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  [[ "$output" == *potholes* ]]
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh"     --project "${DEVAGENT_TEST_PROJECT}" show potholes
  [ "$status" -eq 0 ]
  [[ "$output" != *MISSING* ]]
}

@test "imPlan_template carries the Potholes considered section (#286)" {
  grep -q '^## Potholes considered' "${DEVAGENT_REPO_ROOT}/templates/imPlan_template.md"
}

@test "global [paths] table is a fallback for potholes_workflow only, absolute paths only (#611)" {
  printf '\n[paths]\nmr_template = "%s/mr.md"\npotholes_workflow = "%s/wf.md"\n' "${TEST_TMP}" "${TEST_TMP}" >> "${TEST_TMP}/config.toml"
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; template_project_paths_override testproj mr_template"
  [ "$status" -eq 0 ]
  [ -z "$output" ]                                      # other keys never read the global table
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; template_project_paths_override testproj potholes_workflow"
  [ "$status" -eq 0 ]
  [ "$output" = "${TEST_TMP}/wf.md" ]
  printf '\n[project.testproj.paths]\npotholes_workflow = "%s/proj-wf.md"\n' "${TEST_TMP}" >> "${TEST_TMP}/config.toml"
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; template_project_paths_override testproj potholes_workflow"
  [ "$output" = "${TEST_TMP}/proj-wf.md" ]          # project wins over global
  printf '[project.testproj]\ndevdoc_dir = "%s/devdoc"\nsource_dir = "%s/src"\n\n[paths]\npotholes_workflow = "relative/wf.md"\n' "${TEST_TMP}" "${TEST_TMP}" > "${TEST_TMP}/config.toml"
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; template_project_paths_override testproj potholes_workflow"
  [ "$status" -ne 0 ]
  [[ "$output" == *ABSOLUTE* ]]
}

@test "no [paths] table → template_project_paths_override is empty, as today (#611 back-compat)" {
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; template_project_paths_override testproj potholes_workflow"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- #611: the layered potholes register ---------------------------------------

seed_layers() {   # workflow + project layer files with a shared heading and one overlapping line
  mkdir -p "${TEST_TMP}/devdoc/templates"
  printf '%s\n' '# WF' '' '## Shared heading' '- only in workflow (testproj Issue-3).' '- overlap line (testproj Issue-4).' > "${TEST_TMP}/wf.md"
  printf '%s\n' '# PR' '' '## Shared heading' '- only in project (Issue-5).' '- overlap line (Issue-6).' '' '## Project-only heading' '- p (Issue-7).' > "${TEST_TMP}/devdoc/templates/potholes.md"
}

@test "show potholes: seed-only project is byte-identical to today (#611 back-compat)" {
  seed="${DEVAGENT_PLUGIN_TEMPLATES}/potholes.md"
  { printf '# === template potholes (layer=plugin) ===\n# source: %s\n\n' "$seed"; cat "$seed"; } > "${TEST_TMP}/expected"
  bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" show potholes > "${TEST_TMP}/got"
  cmp "${TEST_TMP}/expected" "${TEST_TMP}/got"
}

@test "show potholes: union of seed + workflow + project with layer markers and citation-stripped dedupe (#611)" {
  seed_layers
  export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="${TEST_TMP}/wf.md"
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" show potholes
  [ "$status" -eq 0 ]
  [[ "$output" == *"# layer: seed"* ]]
  [[ "$output" == *"# layer: workflow"* ]]
  [[ "$output" == *"# layer: project"* ]]
  [[ "$output" == *"only in workflow (testproj Issue-3)."* ]]      # an entry present in ONE layer fires
  [[ "$output" == *"only in project (Issue-5)."* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'overlap line')" -eq 1 ]   # deduped
  [[ "$output" == *"overlap line (testproj Issue-4)."* ]]           # first copy (workflow) kept
  s=$(printf '%s\n' "$output" | grep -n '^# layer: seed' | cut -d: -f1)
  w=$(printf '%s\n' "$output" | grep -n '^# layer: workflow' | cut -d: -f1)
  p=$(printf '%s\n' "$output" | grep -n '^# layer: project' | cut -d: -f1)
  [ "$s" -lt "$w" ] && [ "$w" -lt "$p" ]
}

@test "show potholes: only a project layer → two layers, markers present, workflow absent (#611)" {
  seed_layers
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" show potholes
  [ "$status" -eq 0 ]
  [[ "$output" == *"# layer: project"* ]]
  [[ "$output" != *"# layer: workflow"* ]]
}

@test "template list: potholes_workflow is its own row kind, never MISSING (#611)" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  row="$(printf '%s\n' "$output" | grep '^potholes_workflow ')"
  [[ "$row" == *"layer=unset"* ]]
  [[ "$row" != *MISSING* ]]
  export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="${TEST_TMP}/wf.md"
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" list
  row="$(printf '%s\n' "$output" | grep '^potholes_workflow ')"
  [[ "$row" == *"layer=absent"* ]]
  printf '# WF\n' > "${TEST_TMP}/wf.md"
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" list
  row="$(printf '%s\n' "$output" | grep '^potholes_workflow ')"
  [[ "$row" == *"layer=workflow"* ]] && [[ "$row" != *absent* ]]
}

@test "potholes_union_headings / potholes_cited_union span every existing layer (#611)" {
  seed_layers
  export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="${TEST_TMP}/wf.md"
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; potholes_union_headings testproj"
  [[ "$output" == *"## Shared heading"* ]]
  [[ "$output" == *"## Project-only heading"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^## Shared heading$')" -eq 1 ]
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; potholes_cited_union testproj Issue-3"   # workflow only
  [ "$status" -eq 0 ]
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; potholes_cited_union testproj Issue-7"   # project only
  [ "$status" -eq 0 ]
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; potholes_cited_union testproj Issue-30"  # Issue-3 must not prefix-match
  [ "$status" -eq 1 ]
  printf '%s\n' '- bare in the shared file (Issue-40).' >> "${TEST_TMP}/wf.md"
  run bash -c ". '${DEVAGENT_LIB}/template_resolve.sh'; potholes_cited_union testproj Issue-40"  # bare form in the WORKFLOW file does not count
  [ "$status" -eq 1 ]
}

@test "a zero-byte layer file counts as ABSENT (markers cannot desynchronise) (#611)" {
  seed_layers
  : > "${TEST_TMP}/wf.md"
  export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="${TEST_TMP}/wf.md"
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" --project "${DEVAGENT_TEST_PROJECT}" show potholes
  [ "$status" -eq 0 ]
  [[ "$output" != *"# layer: workflow"* ]]
  [[ "$output" == *"layers=seed,project"* ]]
}
