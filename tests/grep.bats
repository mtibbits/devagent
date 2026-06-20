#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "grep finds keyword across issue.md and imPlan.md" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100/issue.md"
  echo "$output" | grep -q "Issue-100/imPlan.md"
}

@test "grep does NOT search Captures by default" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  run grep -q "Captures/" <<<"$output"
  [ "$status" -ne 0 ]
}

@test "grep --captures includes Captures" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" --captures FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Captures/"
}

@test "grep -i passes through case-insensitive" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" -i foobar
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100/issue.md"
}

@test "grep -l prints only filenames" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" -l FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "issue.md"
  run grep -q "FOOBAR" <<<"$output"
  [ "$status" -ne 0 ]
}

@test "grep prints output in <issue-dir>:<file>:<line>: form" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[^:]*Issue-100/issue\.md:[0-9]+:'
}

@test "grep exits 1 when pattern not found, 2 on usage error" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" ZZZ_NO_MATCH_ZZZ
  [ "$status" -eq 1 ]

  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh"
  [ "$status" -eq 2 ]
}

# --- #79: grep.sh devdoc resolution comes from config, end-to-end (locks #78) ---
# These strip DEVAGENT_TEST_DEVDOC so the real config path runs, with a hermetic
# DA_HOME. On pre-#78 code grep.sh (sourcing only depends.sh) would resolve
# $HOME/devdoc and miss the fixture / search the wrong tree.

@test "#79: grep.sh resolves devdoc via config, not \$HOME/devdoc" {
  local th; th="$(mktemp -d)"
  printf '[project.p79]\ndevdoc_dir = "%s"\n' "${DEVAGENT_TEST_DEVDOC}" > "${th}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${th}" \
    bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" --project p79 -l FOOBAR
  rm -rf "${th}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-100/issue.md"* ]]
}

@test "#79: grep.sh fails loud on unresolvable project (no silent \$HOME/devdoc)" {
  local th; th="$(mktemp -d)"
  printf '[project.other]\ndevdoc_dir = "%s/x"\n' "${th}" > "${th}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${th}" \
    bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" --project missing79 FOOBAR
  rm -rf "${th}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
}

@test "#239: grep.sh prints ONE error line (no redundant empty 'devdoc dir not found') on unresolvable project" {
  # die in the $(...) capture exits only the subshell; the parent used to fall
  # through to '[ ! -d "" ]' and print a 2nd, empty-path line. '|| exit 2' must
  # collapse it to a single message with rc 2.
  local th; th="$(mktemp -d)"
  printf '[project.other]\ndevdoc_dir = "%s/x"\n' "${th}" > "${th}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${th}" \
    bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" --project missing239 FOOBAR
  rm -rf "${th}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
  [[ "$output" != *"devdoc dir not found"* ]]   # no redundant second line
}
