#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # run --separate-stderr: stdout and the WARNING stream apart
#
# #734: scripts/milestones.sh. Issue and code backends are the stub in
# tests/fixtures/wbs-tracker (issue-list.<backend>.<repo_> and
# issue-mrs.<backend>.<repo_> files; every call logged to backend.log),
# except in the AC1/AC5 tests, which run scripts/issue/*.sh and
# scripts/code/*.sh over recorded shapes (gh-stub, or the fixture server
# with tests/fixtures/milestones/gitlab). gh/glab/curl shims on PATH log to
# network.log, which teardown asserts absent.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"
load lib/fixture-server.sh

FIX="$REPO/tests/fixtures/milestones"

setup() {
  TMPROOT="$(mktemp -d)"
  TMPDEV="$TMPROOT/devdoc"
  mkdir -p "$TMPDEV" "$TMPROOT/src"
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"
  _config github acme/testproj no github

  export TMPROOT
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  export DEVAGENT_CODE_BACKEND_DIR="$TMPROOT/code-backends"
  wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR"
  wbs_mr_install_stub "$DEVAGENT_CODE_BACKEND_DIR"
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
  unset DEVAGENT_JIRA_PROJECT_KEY DEVAGENT_PROJECT DEVAGENT_GITHUB_LABEL_ON_DRAFT_START \
    DEVAGENT_GITLAB_LABELS_ON_DRAFT_START GH_STUB_GRAPHQL_DIR GH_STUB_ARGS_LOG \
    GH_STUB_ISSUE_LIST_FILE
}

teardown() {
  if declare -F fixture_stop >/dev/null 2>&1; then fixture_stop; fi
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

# _config <origin-backend|none> <origin-repo> <fork: yes|no> <code-backend|none>
_config() {
  local ob="$1" orepo="$2" fork="$3" cb="$4"
  {
    printf '%s\n' '[defaults]' 'checklist_template = "standard"' '' \
      '[project.testproj]' "source_dir = \"$TMPROOT/src\"" "devdoc_dir = \"$TMPDEV\""
    if [ "$ob" != none ]; then
      printf '%s\n' '' '[project.testproj.issue_source]' "backend = \"$ob\"" \
        "repo = \"$orepo\"" 'dir_prefix = "Issue-"'
    fi
    if [ "$fork" = yes ]; then
      printf '%s\n' '' '[project.testproj.issue_source_fork]' "backend = \"$ob\"" \
        'repo = "me/testproj-fork"' 'dir_prefix = "Issue-Fork-"'
    fi
    if [ "$cb" != none ]; then
      printf '%s\n' '' '[project.testproj.code_source]' "backend = \"$cb\"" \
        "upstream = \"$orepo\"" 'fork = "me/testproj-fork"'
    fi
  } > "$HOME/.claude/devagent/config.toml"
}

# _rec <id> <open|closed> <created> [closed]: one issue-list record.
_rec() {
  local closed=null cls=open
  [ "$2" = closed ] && closed="\"$4\"" cls="done"
  printf '{"id":"%s","title":"t","body":"","state":"%s","class":"%s","created":"%s","closed":%s,"milestone":null,"labels":[],"type":null,"parent":null,"blocked_by":[],"url":"https://github.com/acme/testproj/issues/%s"}\n' \
    "$1" "$2" "$cls" "$3" "$closed" "$1"
}

# _il <backend> <repo> <line>...: the stub's issue-list output for <repo>.
_il() {
  local b="$1" repo="$2"; shift 2
  printf '%s\n' "$@" > "$TMPROOT/issue-list.$b.${repo//\//_}"
}

# _mrs <repo> <line>...: the stub's github issue-mrs output for <repo>.
_mrs() {
  local repo="$1"; shift
  printf '%s\n' "$@" > "$TMPROOT/issue-mrs.github.${repo//\//_}"
}

# _cl <fixture-subdir>: copy a checklist fixture issue dir into the devdoc.
_cl() {
  cp -r "$FIX/$1" "$TMPDEV/"
}

_ms() {
  run --separate-stderr bash "$REPO/scripts/milestones.sh" "$@"
}

# _rows <jq-filter>: the --json row lines through jq -r (one per row).
_rows() {
  grep '"kind":"row"' <<<"$output" | jq -r "$1"
}

# _path_without <cmd>...: PATH minus the shim dir and any dir holding <cmd>
# (a copy of tests/wbs-mr.bats:118; kept whole, though this file passes no <cmd>).
# shellcheck disable=SC2120
_path_without() {
  local IFS=: d c out="" skip
  for d in $PATH; do
    [ "$d" = "$TMPROOT/shims" ] && continue
    skip=0
    for c in "$@"; do
      if [ -x "$d/$c" ] || [ -x "$d/$c.exe" ]; then skip=1; fi
    done
    [ "$skip" -eq 1 ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# _gh_real: the real issue/code github backends under the gh-stub (a minimal
# local copy of tests/code-github.bats:363 _gql_stub).
_gh_real() {
  unset DEVAGENT_ISSUE_BACKEND_DIR DEVAGENT_CODE_BACKEND_DIR
  mkdir -p "$TMPROOT/ghbin" "$TMPROOT/gql"
  cp "$REPO/tests/fixtures/gh-stub" "$TMPROOT/ghbin/gh"
  chmod +x "$TMPROOT/ghbin/gh"
  export PATH="$TMPROOT/ghbin:$PATH"   # the shim dir stays: a stray curl is caught
  export GH_STUB_GRAPHQL_DIR="$TMPROOT/gql" GH_STUB_ARGS_LOG="$TMPROOT/gh-args.log"
}

# _gql_batch <n>: a batch reply whose n aliases have empty timelines (a copy
# of tests/code-github.bats:386).
_gql_batch() {
  jq -n --argjson n "$1" '{data: {repository: (reduce range(0; $n) as $k ({};
        .["i\($k)"] = {timelineItems: {totalCount: 0,
          pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}))}}'
}

# _related_calls: GitLab related_merge_requests GETs (tests/code-gitlab.bats:92).
_related_calls() {
  grep -c '/related_merge_requests' "$FIXTURE_REQUEST_LOG" || true
}

_gl_real() {
  _config gitlab foo/bar no gitlab
  unset DEVAGENT_ISSUE_BACKEND_DIR DEVAGENT_CODE_BACKEND_DIR
  PATH="$(_path_without)"
  export PATH
  fixture_start "$FIX/gitlab"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4" GITLAB_TOKEN=dummy-token
}

@test "AC1 github: recorded shapes give opened, two mr_opened, one mr_merged and closed for one issue" {
  _gh_real
  export GH_STUB_ISSUE_LIST_FILE="$FIX/gh-issue-list.json"
  cp "$REPO/tests/fixtures/code-github/issue-mrs-links.json" "$TMPROOT/gql/1.json"
  _ms testproj --issue Issue-6 --json
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(_rows '[.event, .at, .source] | @tsv')" = "$(printf '%s\n' \
    $'opened\t2026-01-13\thttps://github.com/acme/testproj/issues/6' \
    $'closed\t2026-02-08\thttps://github.com/acme/testproj/issues/6' \
    $'mr_opened\t2026-06-10T04:11:31Z\thttps://github.com/acme/testproj/pull/21' \
    $'mr_merged\t2026-06-10T04:27:27Z\thttps://github.com/acme/testproj/pull/21' \
    $'mr_opened\t2026-06-11T09:00:00Z\thttps://github.com/acme/testproj/pull/22')" ]
  [ "$(_rows 'select(.event == "closed") | .reason')" = "done" ]
  [ "$(_rows 'select(.event == "mr_merged") | .base')" = chore/shellcheck-scripts-review-followups ]
  [ "$(cat "$TMPROOT/gql/count")" -eq 1 ]
  [ "$stderr" = "" ]
}

@test "AC1 gitlab: recorded shapes give the same four kinds for one issue" {
  _gl_real
  _ms testproj --issue Issue-3 --json
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(_rows '[.event, .at, .source, (.base // "")] | @tsv')" = "$(printf '%s\n' \
    $'opened\t2026-06-20\thttps://gitlab.example/foo/bar/-/issues/3\t' \
    $'mr_opened\t2026-07-01T00:00:01Z\thttps://gitlab.example/foo/bar/-/merge_requests/51\tmain' \
    $'mr_opened\t2026-07-01T00:00:02Z\thttps://gitlab.example/foo/bar/-/merge_requests/52\tmain' \
    $'mr_merged\t2026-07-04T00:00:00Z\thttps://gitlab.example/foo/bar/-/merge_requests/51\tmain' \
    $'closed\t2026-07-05\thttps://gitlab.example/foo/bar/-/issues/3\t')" ]
  [ "$(_related_calls)" -eq 1 ]
}

@test "AC2/AC3 end to end: checklist fixtures give the library's rows" {
  _config github acme/testproj no none
  _cl rev2/Issue-465
  _cl shapes/Issue-700
  _ms testproj
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "${lines[0]}" = "milestones: testproj scope: default" ]
  grep -qxF 'missing: tracker: github has no issue-list (exit 78)' <<<"$output"
  grep -qxF 'missing: mr: no code_source.backend' <<<"$output"
  grep -qxF $'Issue-465\t2026-09-18T05:09-04:00\trevision_started\tr2 tz=assumed\tIssue-465/checklist.md:24' <<<"$output"
  grep -qxF $'Issue-700\t2026-10-12T08:12-04:00\tstep_note\tanalyze r1 tz=assumed\tIssue-700/checklist.md:26' <<<"$output"
  grep -qxF $'Issue-700\t2026-10-17T09:30-04:00\tstep_done\timplement r2 tz=assumed\tIssue-700/checklist.md:36' <<<"$output"
  grep -qxF $'Issue-700\topened->merged -\topened->closed -\tfirst-step->closed -\tparked 1.5d' <<<"$output"
  [ "$stderr" = "" ]
}

@test "AC4 a tracker failure still prints checklist rows and exactly one WARNING" {
  _config github acme/testproj no none
  _cl rev2/Issue-465
  _il github acme/testproj ''
  printf '%s\n' 1 > "$TMPROOT/issue-list.github.acme_testproj.rc"
  printf '%s\n' 'gh: HTTP 502: Bad Gateway' > "$TMPROOT/issue-list.github.acme_testproj.err"
  _ms testproj
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WARNING' <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == "milestones: WARNING: tracker: github "* ]]
  [[ "$stderr" == *"issue-list failed (exit 1: gh: HTTP 502: Bad Gateway); other sources still reported" ]]
  grep -qxF $'Issue-465\t2026-09-10T08:00-04:00\tstep_done\tpull r1 tz=assumed\tIssue-465/checklist.md:19' <<<"$output"
  grep -qxF 'missing: tracker: github acme/testproj issue-list failed (exit 1: gh: HTTP 502: Bad Gateway)' <<<"$output"
}

@test "AC5 github call bound: 51 ids in scope make ceil(51/50)=2 GraphQL calls and one issue-list" {
  _gh_real
  jq '[range(1; 52) as $n | .[1] | .number = $n | .url = "https://github.com/acme/testproj/issues/\($n)"]' \
    "$FIX/gh-issue-list.json" > "$TMPROOT/il.json"
  export GH_STUB_ISSUE_LIST_FILE="$TMPROOT/il.json"
  _gql_batch 50 > "$TMPROOT/gql/1.json"
  _gql_batch 1 > "$TMPROOT/gql/2.json"
  _ms testproj
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(cat "$TMPROOT/gql/count")" -eq 2 ]
  [ "$(grep -c '^issue list ' "$GH_STUB_ARGS_LOG")" -eq 1 ]
  [ "$(grep -c $'\topened\t' <<<"$output")" -eq 51 ]
}

@test "AC5 gitlab call bound: N ids make N related_merge_requests GETs and one issues page series" {
  _gl_real
  _ms testproj --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(_related_calls)" -eq 3 ]
  [ "$(grep -c '/issues?per_page=100&page=' "$FIXTURE_REQUEST_LOG")" -eq 1 ]
}

@test "default scope looks up checklists plus open issues only" {
  _il github acme/testproj "$(_rec 1 open 2026-01-01)" "$(_rec 2 closed 2026-01-02 2026-01-05)" \
    "$(_rec 3 closed 2026-01-03 2026-01-06)"
  mkdir -p "$TMPDEV/Issue-3"
  printf '%s\n' 'Created: 2026-01-03T09:00:00+00:00' '## Revision 1' '- [x]  9. implement' \
    '## Log' '- 2026-01-04 10:00  implement: done' > "$TMPDEV/Issue-3/checklist.md"
  _mrs acme/testproj $'issue\t1\tnone' $'issue\t3\tnone'
  _ms testproj
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "${lines[0]}" = "milestones: testproj scope: default" ]
  grep -qxF '[issue-mrs] [acme/testproj] [1] [3] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  [ "$(grep -c '^\[issue-list\]' "$TMPROOT/backend.log")" -eq 1 ]
  grep -qxF $'Issue-3\topened->merged -\topened->closed 3\tfirst-step->closed 2\tparked 0.0d' <<<"$output"
  if grep -q $'^Issue-2\t' <<<"$output"; then false; fi
}

@test "--all covers closed issues and says scope: all" {
  _il github acme/testproj "$(_rec 1 open 2026-01-01)" "$(_rec 2 closed 2026-01-02 2026-01-05)" \
    "$(_rec 3 closed 2026-01-03 2026-01-06)"
  _mrs acme/testproj $'issue\t1\tnone' $'issue\t2\tnone' $'issue\t3\tnone'
  _ms testproj --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "${lines[0]}" = "milestones: testproj scope: all" ]
  grep -qxF '[issue-mrs] [acme/testproj] [1] [2] [3] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
  grep -qF $'Issue-2\t2026-01-05\tclosed\tdone\t' <<<"$output"
}

@test "usage errors exit 2 before any backend call" {
  local leg
  for leg in 'issue-empty' 'issue-eq-empty' 'issue-path' 'issue-and-all' 'bogus' 'two-positionals' 'issue-last'; do
    case "$leg" in
      issue-empty)     _ms testproj --issue ""; want="milestones: --issue needs an issue id" ;;
      issue-eq-empty)  _ms testproj --issue=; want="milestones: --issue needs an issue id" ;;
      issue-path)      _ms testproj --issue ../x/Issue-5; want="milestones: --issue '../x/Issue-5' is not one issue-id token" ;;
      issue-and-all)   _ms testproj --issue Issue-1 --all; want="milestones: --issue and --all cannot be combined" ;;
      bogus)           _ms testproj --bogus; want="milestones: unknown flag '--bogus'" ;;
      two-positionals) _ms a b; want="milestones: unexpected argument 'b'" ;;
      issue-last)      _ms testproj --issue; want="milestones: --issue needs an issue id" ;;
    esac
    [ "$status" -eq 2 ] || { echo "$leg: rc=$status $stderr"; false; }
    [ "${stderr_lines[0]}" = "$want" ] || { echo "$leg: $stderr"; false; }
    [ "${stderr_lines[1]}" = "usage: milestones.sh [project] [--issue <issue-id> | --all] [--json]" ]
    [ ! -e "$TMPROOT/backend.log" ] || { echo "$leg: backend called"; false; }
    [ "$output" = "" ]
  done
}

@test "-h prints the usage line on stdout and exits 0" {
  _ms --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: milestones.sh [project] [--issue <issue-id> | --all] [--json]" ]
}

@test "--issue naming nothing exits 2" {
  _ms testproj --issue Nope-1
  [ "$status" -eq 2 ]
  [[ "$stderr" == "milestones: --issue Nope-1 names no configured source and no "*"/Nope-1/checklist.md" ]]
  [ ! -e "$TMPROOT/backend.log" ]
}

@test "--issue names a configured source with no checklist and no record" {
  _il github acme/testproj "$(_rec 1 open 2026-01-01)"
  _mrs acme/testproj $'issue\t9\tnone'
  _ms testproj --issue Issue-9
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$output" = $'milestones: testproj scope: issue\n(no rows)' ]
  grep -qxF '[issue-mrs] [acme/testproj] [9] [DEVAGENT_PROJECT=testproj]' "$TMPROOT/backend.log"
}

@test "no tracker configured: checklist rows plus missing: tracker: not configured" {
  _config none - no none
  _cl rev2/Issue-465
  _ms testproj
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "${lines[1]}" = "missing: tracker: not configured" ]
  grep -qF $'Issue-465\t2026-09-10T08:00-04:00\tstep_done\tpull r1' <<<"$output"
  [ ! -e "$TMPROOT/backend.log" ]
}

@test "jira project: tracker rows, missing: mr: ... not the code backend" {
  _config jira PROJ no github
  printf '%s\n' '{"id":"PROJ-12","title":"t","body":"","state":"closed","class":"done","created":"2026-01-10","closed":"2026-01-25","milestone":null,"labels":[],"type":null,"parent":null,"blocked_by":[],"url":"https://jira.example/browse/PROJ-12"}' \
    > "$TMPROOT/issue-list.jira.PROJ"
  _ms testproj --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qxF 'missing: mr: tracker backend jira is not the code backend github; MRs not read' <<<"$output"
  grep -qxF $'Issue-12\t2026-01-10\topened\t-\thttps://jira.example/browse/PROJ-12' <<<"$output"
  grep -qxF $'Issue-12\t2026-01-25\tclosed\tdone\thttps://jira.example/browse/PROJ-12' <<<"$output"
  if grep -q '^\[issue-mrs\]' "$TMPROOT/backend.log"; then false; fi
}

@test "an issue-mrs failure keeps tracker and checklist rows, one WARNING, exit 0" {
  _il github acme/testproj "$(_rec 1 open 2026-01-01)"
  mkdir -p "$TMPDEV/Issue-1"
  printf '%s\n' '## Revision 1' '- [x]  9. implement' '## Log' '- 2026-01-04 10:00  implement: done' \
    > "$TMPDEV/Issue-1/checklist.md"
  _mrs acme/testproj ''
  printf '%s\n' 1 > "$TMPROOT/issue-mrs.github.acme_testproj.rc"
  printf '%s\n' 'gh: HTTP 502' > "$TMPROOT/issue-mrs.github.acme_testproj.err"
  _ms testproj
  [ "$status" -eq 0 ]
  [ "$stderr" = "milestones: WARNING: mr: github acme/testproj issue-mrs failed (exit 1: gh: HTTP 502); other sources still reported" ]
  grep -qxF 'missing: mr: github acme/testproj issue-mrs failed (exit 1: gh: HTTP 502)' <<<"$output"
  grep -qF $'Issue-1\t2026-01-01\topened\t' <<<"$output"
  grep -qxF $'Issue-1\t2026-01-04T10:00\tstep_done\timplement r1 tz=unknown\tIssue-1/checklist.md:4' <<<"$output"
}

@test "a malformed issue-list counts as failed with the parser's reason" {
  _config github acme/testproj no none
  _il github acme/testproj 'not json'
  _ms testproj
  [ "$status" -eq 0 ]
  [ "$stderr" = "milestones: WARNING: tracker: github acme/testproj issue-list failed (malformed line 1: not JSON); other sources still reported" ]
}

@test "--json stdout is JSON Lines only" {
  _config github acme/testproj no none
  _cl rev2/Issue-465
  _il github acme/testproj ''
  printf '%s\n' 1 > "$TMPROOT/issue-list.github.acme_testproj.rc"
  _ms testproj --json
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WARNING' <<<"$stderr")" -eq 1 ]
  local n=0 l
  while IFS= read -r l; do
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$l"
    n=$((n + 1))
  done <<<"$output"
  [ "$n" -eq 9 ]   # the header and Issue-465's 8 rows
  [[ "$output" != *WARNING* ]]
}
