#!/usr/bin/env bash
# contract-helpers.bash — shared by every backend-<name>.bats file.
#
# #338: source the shared hermetic-env guard (#322) so this setup layer can't
# leave its tests exposed to host git-config / TZ / locale / session pins.
. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"
#
# Each backend bats file sets:
#   BACKEND_NAME      e.g. "gitlab"
#   ISSUE_SCRIPT      e.g. scripts/issue/gitlab.sh
#   CODE_SCRIPT       e.g. scripts/code/gitlab.sh (or empty if N/A)
#   FIXTURE_SUBDIR    e.g. "gitlab"
#   REPO_ARG          e.g. "foo/bar"
#   ISSUE_NUM_OK      e.g. "42" or "PROJ-42"
#   ISSUE_NUM_404     e.g. "404" or "PROJ-404"
#   ISSUE_NUM_401     e.g. "401" or "PROJ-401"
#   MR_URL_OK         e.g. "https://gitlab.example/foo/bar/-/merge_requests/7"
#   EXPECTED_AUTHOR   e.g. "alice"
#   EXPECTED_LABELS   e.g. "bug,performance"

contract_load_fixtures() {
  load lib/fixture-server.sh
  fixture_start "${BATS_TEST_DIRNAME}/fixtures/${FIXTURE_SUBDIR}"
}

contract_teardown() {
  # fixture_stop is only available after contract_load_fixtures has run;
  # skip-on-setup paths never call it, so guard the call.
  if declare -F fixture_stop >/dev/null 2>&1; then
    fixture_stop
  fi
}

# --- shared assertions -------------------------------------------------------

assert_fetch_shape() {
  local out="$1"
  [[ "$out" == "# "*"#"*" — "* ]]
  [[ "$out" == *"- State: "* ]]
  [[ "$out" == *"- Author: @"* ]]
  [[ "$out" == *"- Labels: "* ]]
  [[ "$out" == *"- URL: "* ]]
  [[ "$out" == *"---"* ]]
  [[ "$out" == *"## Comments ("* ]]
  [[ "$out" == *"### @"*" · "* ]]
}

assert_comment_list_shape() {
  local out="$1"
  [[ "$out" == *"## Comments ("* ]]
  [[ "$out" == *"### @"*" · "* ]]
}
