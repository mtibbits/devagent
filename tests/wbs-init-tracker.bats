#!/usr/bin/env bats
#
# #706: `wbs init --from-tracker` seeds a fresh WBS.md from the project's
# tracker history. The tracker data is the synthesized fixture set that
# tests/fixtures/wbs-import/make-fixtures.py generates (its header is the
# provenance block). Real backends run over it: the gh-stub on PATH for
# GitHub, the fixture server for GitLab and Jira; gh/glab/curl shims log any
# other call to network.log, which teardown asserts absent.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
. "$(dirname "$BATS_TEST_FILENAME")/helpers/wbs-tracker.bash"
load lib/fixture-server.sh
bats_require_minimum_version 1.5.0

GEN="$REPO/tests/fixtures/wbs-import/make-fixtures.py"

setup() {
  TMPROOT="$(mktemp -d)"
  export TMPROOT
}

teardown() {
  if declare -F fixture_stop >/dev/null 2>&1; then fixture_stop; fi
  [ ! -e "$TMPROOT/network.log" ]
  rm -rf "$TMPROOT"
}

@test "fixtures: regenerating reproduces the committed bytes" {
  python3 "$GEN" "$TMPROOT/regen"
  local n=0 p
  while IFS= read -r p; do
    cmp "$TMPROOT/regen/$p" "$REPO/tests/fixtures/$p"
    n=$((n + 1))
  done < <(python3 "$GEN" --manifest)
  [ "$n" -eq 11 ]
}

@test "fixtures: no private project name appears in the import fixtures" {
  . "$REPO/scripts/lib/template_resolve.sh"
  local names files=() p name rc
  names="$(potholes_fixture_private_names "$REPO/tests/fixtures/private-project-names.txt")"
  [ -n "$names" ]
  while IFS= read -r p; do files+=("$REPO/tests/fixtures/$p"); done < <(python3 "$GEN" --manifest)
  files+=("$GEN")
  # control: a planted name is found, so rc 1 below means "no match"
  name="$(printf '%s\n' "$names" | head -1)"
  printf 'x %s y\n' "$name" > "$TMPROOT/planted"
  rc=0; grep -liwF -- "$name" "$TMPROOT/planted" "${files[@]}" >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  while IFS= read -r name; do
    rc=0; grep -liwF -- "$name" "${files[@]}" || rc=$?
    [ "$rc" -eq 1 ]
  done <<< "$names"
}

# --- wbs init --from-tracker (Task 9) ------------------------------------------
# Every test starts from an EMPTY devdoc. _gh / _gitlab / _jira point the
# project at one real backend over the shaped fixtures; _stub at the
# wbs-tracker stub backend.

TMPDEV_REL=devdoc
SHAPED_GH="$REPO/tests/fixtures/issue-github/issue-list-shaped.json"

_setup_project() {
  TMPDEV="$TMPROOT/$TMPDEV_REL"
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets" "$TMPROOT/src"
  wbs_tracker_install_shims "$TMPROOT/shims" "$TMPROOT/network.log"
  export PATH="$TMPROOT/shims:$PATH"
  unset DEVAGENT_ISSUE_BACKEND_DIR DEVAGENT_JIRA_PROJECT_KEY DEVAGENT_GITHUB_LABEL_IN_PROGRESS \
    DEVAGENT_GITLAB_LABELS_IN_PROGRESS DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS DEVAGENT_PROJECT \
    DEVAGENT_WBS_OFFLINE
}

# _config <backend> <repo> [fork: yes|no|noprefix] [extra toml line under [project.testproj.wbs]]
_config() {
  local b="$1" repo="$2" fork="${3:-no}" wbs="${4:-}"
  {
    printf '%s\n' '[defaults]' 'checklist_template = "standard"' '' \
      '[project.testproj]' "source_dir = \"$TMPROOT/src\"" "devdoc_dir = \"$TMPDEV\"" '' \
      '[project.testproj.issue_source]' "backend = \"$b\"" "repo = \"$repo\"" 'dir_prefix = "Issue-"'
    case "$fork" in
      yes) printf '%s\n' '' '[project.testproj.issue_source_fork]' 'backend = "github"' \
             'repo = "me/testproj-fork"' 'dir_prefix = "Issue-Fork-"' ;;
      noprefix) printf '%s\n' '' '[project.testproj.issue_source_fork]' 'backend = "github"' \
             'repo = "me/testproj-fork"' ;;
    esac
    [ -z "$wbs" ] || printf '%s\n' '' '[project.testproj.wbs]' "$wbs"
  } > "$HOME/.claude/devagent/config.toml"
}

# PATH without the shim dir (a real curl is needed for the fixture server).
_path_without_shims() {
  local IFS=: d out=""
  for d in $PATH; do
    [ "$d" = "$TMPROOT/shims" ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

_gh() {
  _config github acme/testproj "${1:-no}" "${2:-}"
  mkdir -p "$TMPROOT/ghbin"
  cp "$REPO/tests/fixtures/gh-stub" "$TMPROOT/ghbin/gh"
  chmod +x "$TMPROOT/ghbin/gh"
  export PATH="$TMPROOT/ghbin:$PATH"   # ahead of the shims: a stray curl is still caught
  export GH_STUB_ISSUE_LIST_FILE="$SHAPED_GH" GH_STUB_ARGS_LOG="$TMPROOT/gh.log" GH_TOKEN=dummy
}

_gitlab() {
  _config gitlab foo/shaped no "${1:-}"
  PATH="$(_path_without_shims)"; export PATH
  fixture_start "$REPO/tests/fixtures/gitlab"
  export DEVAGENT_GITLAB_API="$FIXTURE_URL/api/v4" GITLAB_TOKEN=dummy-token
}

_jira() {
  _config jira SHAPED no "${1:-}"
  PATH="$(_path_without_shims)"; export PATH
  fixture_start "$REPO/tests/fixtures/jira"
  export DEVAGENT_JIRA_BASE="$FIXTURE_URL" JIRA_USER=dummy@example.com JIRA_TOKEN=dummy-token
  export DEVAGENT_JIRA_NOT_PLANNED_RESOLUTIONS="Won't Do"
}

# _stub [fork]: the stub backend; the origin list is the real github.sh output
# over the shaped fixture.
_stub() {
  _gh "${1:-no}"
  "$REPO/scripts/issue/github.sh" issue-list acme/testproj > "$TMPROOT/issue-list.github.acme_testproj"
  : > "$TMPROOT/gh.log"
  export DEVAGENT_ISSUE_BACKEND_DIR="$TMPROOT/backends"
  wbs_tracker_install_stub "$DEVAGENT_ISSUE_BACKEND_DIR" github
}

_init() { run --separate-stderr bash "$REPO/scripts/wbs.sh" init testproj "$@"; }

# _issues: the issue ids in WBS.md, one per line, sorted
_issues() { grep -o '{issue: Issue-[A-Za-z0-9-]*' "$TMPDEV/WBS.md" | sed 's/{issue: //' | sort; }
# _ids <n>...: Issue-<n> lines, sorted
_ids() { printf 'Issue-%s\n' "$@" | sort; }

_survey_json() { printf '%s\n' "$output" | sed '/^WBS-INIT: /d'; }

@test "survey counts: github shaped fixture" {
  _setup_project; _gh
  _init --from-tracker --survey
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ ! -e "$TMPDEV/WBS.md" ]
  run jq -c '[.total, .open, .closed, .not_planned, .closed_share_pct, (.epics | length), .no_parent, .unresolved_parents]' <<< "$output"
  [ "$(tr -d '\r' <<< "$output")" = '[62,17,44,1,72,5,33,[{"issue":"Issue-20","line":"Parent epic: data-pipeline","reason":"slug-only"}]]' ]
}

@test "survey counts: gitlab shaped fixture" {
  _setup_project; _gitlab
  _init --survey
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ ! -e "$TMPDEV/WBS.md" ]
  run jq -c '[.total, .open, .closed, .not_planned, .closed_share_pct, (.epics | length), .no_parent, (.unresolved_parents | map(.issue))]' <<< "$output"
  [ "$(tr -d '\r' <<< "$output")" = '[62,17,45,0,72,5,33,["Issue-20"]]' ]
}

@test "survey counts: jira shaped fixture" {
  _setup_project; _jira
  _init --survey
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  run jq -c '[.total, .open, .closed, .not_planned, .closed_share_pct, (.epics | map(.issue)), .no_parent, (.unresolved_parents | map(.issue))]' <<< "$output"
  [ "$(tr -d '\r' <<< "$output")" = '[62,17,44,1,72,["Issue-1","Issue-2","Issue-3","Issue-83","Issue-84"],33,["Issue-20"]]' ]
}

@test "at or above the threshold with no range flag: survey, marker, exit 10, nothing written" {
  _setup_project; _gh
  _init --from-tracker
  [ "$status" -eq 10 ]
  [ "${lines[${#lines[@]}-1]}" = "WBS-INIT: choose-range" ]
  _survey_json | jq -e '.auto_import == false and .total == 62' >/dev/null
  [ ! -e "$TMPDEV/WBS.md" ]
  [ "$(grep -c '^issue list ' "$TMPROOT/gh.log")" -eq 1 ]
}

@test "below the threshold imports everything" {
  _setup_project; _gh no 'auto_import_below_pct = 80'
  _init --from-tracker
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [[ "$stderr" == *"62 issues (5 epics, 33 unparented)"*"closed share 72% < 80%"* ]]
  [ "$(grep -c '{issue: ' "$TMPDEV/WBS.md")" -eq 62 ]
  [ "$(python3 "$REPO/scripts/lib/wbs-parser.py" leaves "$TMPDEV/WBS.md" | wc -l)" -eq 57 ]
}

# _leaf <depth> <n> <glyph> [title] [extra meta]: one expected node line
_leaf() {
  local pad="" title="${4:-Task $2}" extra="${5:-}" src=""
  [ "$1" -eq 2 ] && pad="  "
  case "$3" in x|-) src=", status_src: tracker" ;; esac
  printf '%s- [%s] %s {issue: Issue-%s%s%s}\n' "$pad" "$3" "$title" "$2" "$extra" "$src"
}

_expected_all() {
  local n g
  sed -e 's/{{PROJECT}}/testproj/g' -e '/^- \[/,$d' "$REPO/templates/wbs_template.md"
  printf '%s\n' '<!-- wbs init --from-tracker DATE all: 62 issues from github acme/testproj -->' ''
  _leaf 1 1 x "Data pipeline"; for n in 4 5 6 7 8 9; do _leaf 2 "$n" x; done
  _leaf 1 2 x "Reporting"; for n in 10 11 12 13 14; do _leaf 2 "$n" x; done
  _leaf 1 3 x "Storage layer"; for n in 15 16 17 18; do _leaf 2 "$n" x; done
  _leaf 1 83 " " "Epic: Search"; for n in 85 86 87; do _leaf 2 "$n" x; done; _leaf 2 88 " "; _leaf 2 89 " "
  _leaf 1 84 " " "Epic: Notifications"; for n in 90 91 92 93; do _leaf 2 "$n" " "; done
  printf '%s\n' '- [ ] Unparented'
  for n in $(seq 19 50) 82; do
    g=x; [ "$n" -ge 42 ] && g=" "; [ "$n" = 82 ] && g=-
    if [ "$n" = 22 ]; then _leaf 2 22 x "Task 22" ", depends_on: Issue-21"
    else _leaf 2 "$n" "$g"; fi
  done
}

@test "--all writes the demo shape" {
  _setup_project; _gh
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _expected_all > "$TMPROOT/expected"
  sed -E 's/^(<!-- wbs init --from-tracker )[0-9]{4}-[0-9]{2}-[0-9]{2} /\1DATE /' "$TMPDEV/WBS.md" > "$TMPROOT/got"
  diff "$TMPROOT/expected" "$TMPROOT/got"
  [ "$(grep -c '^ *- \[x\] .*{issue: ' "$TMPDEV/WBS.md")" -eq 44 ]
  [ "$(grep -c '^ *- \[-\] .*{issue: ' "$TMPDEV/WBS.md")" -eq 1 ]
  [ "$(grep -cE '^ *- \[[ ~]\] .*\{issue: ' "$TMPDEV/WBS.md")" -eq 17 ]
}

@test "--open-only brings closed children of every imported epic" {
  _setup_project; _gh
  _init --from-tracker --open-only
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _issues > "$TMPROOT/got"
  _ids 83 84 85 86 87 88 89 90 91 92 93 42 43 44 45 46 47 48 49 50 > "$TMPROOT/want"
  diff "$TMPROOT/want" "$TMPROOT/got"
}

@test "--open-only: an open child of a closed epic lands under that epic" {
  _setup_project; _stub
  jq -c 'if .id == "9" then .state = "open" | .class = "open" | .closed = null else . end' \
    "$TMPROOT/issue-list.github.acme_testproj" > "$TMPROOT/v" && mv "$TMPROOT/v" "$TMPROOT/issue-list.github.acme_testproj"
  _init --from-tracker --open-only
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qFx -- '- [x] Data pipeline {issue: Issue-1, status_src: tracker}' "$TMPDEV/WBS.md"
  grep -qFx -- '  - [ ] Task 9 {issue: Issue-9}' "$TMPDEV/WBS.md"
  grep -qFx -- '  - [x] Task 4 {issue: Issue-4, status_src: tracker}' "$TMPDEV/WBS.md"
  run grep -c 'Issue-2,' "$TMPDEV/WBS.md"
  [ "$output" = 0 ]
}

@test "--since 2026-06-01 imports open issues and those closed since" {
  _setup_project; _gh
  _init --from-tracker --since 2026-06-01
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _issues > "$TMPROOT/got"
  _ids 83 84 85 86 87 88 89 90 91 92 93 42 43 44 45 46 47 48 49 50 82 > "$TMPROOT/want"
  diff "$TMPROOT/want" "$TMPROOT/got"
}

@test "--since 40 and --since Issue-40 import open issues and those numbered from 40" {
  _setup_project; _gh
  _ids 83 84 85 86 87 88 89 90 91 92 93 40 41 42 43 44 45 46 47 48 49 50 82 > "$TMPROOT/want"
  _init --from-tracker --since 40
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _issues > "$TMPROOT/got"
  diff "$TMPROOT/want" "$TMPROOT/got"
  rm "$TMPDEV/WBS.md"
  _init --from-tracker --since=Issue-40
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _issues > "$TMPROOT/got"
  diff "$TMPROOT/want" "$TMPROOT/got"
}

@test "--epic 83 imports one subtree" {
  _setup_project; _gh
  _init --from-tracker --epic 83
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _issues > "$TMPROOT/got"
  _ids 83 85 86 87 88 89 > "$TMPROOT/want"
  diff "$TMPROOT/want" "$TMPROOT/got"
  run grep -c Unparented "$TMPDEV/WBS.md"
  [ "$output" = 0 ]
}

@test "--epic 19 exits 2 listing the epics" {
  _setup_project; _gh
  _init --from-tracker --epic 19
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Issue-1, Issue-2, Issue-3, Issue-83, Issue-84"* ]]
  [ ! -e "$TMPDEV/WBS.md" ]
}

@test "fork: leaves carry the fork prefix and the share is combined" {
  _setup_project; _stub yes
  local u=https://github.com/me/testproj-fork/issues
  printf '%s\n' \
    "{\"id\":\"1\",\"title\":\"Fork one\",\"body\":\"\",\"state\":\"closed\",\"class\":\"done\",\"created\":\"2026-02-01\",\"closed\":\"2026-02-02\",\"milestone\":null,\"labels\":[],\"type\":null,\"parent\":null,\"blocked_by\":[],\"url\":\"$u/1\"}" \
    "{\"id\":\"2\",\"title\":\"Fork two\",\"body\":\"Parent epic: https://github.com/acme/testproj/issues/1\",\"state\":\"closed\",\"class\":\"done\",\"created\":\"2026-02-01\",\"closed\":\"2026-02-03\",\"milestone\":null,\"labels\":[],\"type\":null,\"parent\":null,\"blocked_by\":[],\"url\":\"$u/2\"}" \
    > "$TMPROOT/issue-list.github.me_testproj-fork"
  _init --survey
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  run jq -c '[.total, .closed_share_pct, (.sources | map(.issues))]' <<< "$output"
  [ "$(tr -d '\r' <<< "$output")" = '[64,73,[62,2]]' ]
  : > "$TMPROOT/backend.log"
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qFx -- '  - [x] Fork two {issue: Issue-Fork-2, status_src: tracker}' "$TMPDEV/WBS.md"
  grep -qFx -- '  - [x] Fork one {issue: Issue-Fork-1, status_src: tracker}' "$TMPDEV/WBS.md"
  grep -c '^\[issue-list\]' "$TMPROOT/backend.log" | grep -qx 2
}

@test "fork with backend and repo but no dir_prefix dies" {
  _setup_project; _stub noprefix
  _init --survey
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"issue_source_fork"*"dir_prefix"* ]]
}

@test "existing WBS.md is refused for --from-tracker, survey still runs" {
  _setup_project; _gh
  mkdir -p "$TMPDEV"; printf '# mine\n' > "$TMPDEV/WBS.md"
  _init --from-tracker --all
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"exists"* ]]
  [[ "$stderr" != *"--force"* ]]
  [ "$(cat "$TMPDEV/WBS.md")" = "# mine" ]
  [ ! -s "$TMPROOT/gh.log" ]
  _init --survey
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDEV/WBS.md")" = "# mine" ]
}

@test "--force with --from-tracker exits 2 and writes nothing" {
  _setup_project; _gh
  _init --force --from-tracker
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"#707"* ]]
  [ ! -e "$TMPDEV/WBS.md" ]
  _init --survey --force
  [ "$status" -eq 2 ]
  _init --all --force
  [ "$status" -eq 2 ]
}

@test "usage errors exit 2 before any tracker call" {
  _setup_project; _gh
  local args
  for args in "--from-tracker --all --open-only" "--from-tracker --since 2026-13-01" \
              "--from-tracker --since=" "--from-tracker --bogus" "--bogus" \
              "--all" "--survey --all" "--from-tracker --epic" "--from-tracker --since --all" \
              "--from-tracker --epic not-an-id!"; do
    # shellcheck disable=SC2086
    _init $args
    [ "$status" -eq 2 ] || { echo "args: $args -> $status: $stderr"; false; }
  done
  _init --from-tracker --since ""
  [ "$status" -eq 2 ]
  [ ! -s "$TMPROOT/gh.log" ]
  [ ! -e "$TMPDEV/WBS.md" ]
}

@test "a bad auto_import_below_pct dies naming the key" {
  _setup_project
  local v
  for v in true 101 -1 20.5; do
    _gh no "auto_import_below_pct = $v"
    _init --survey
    [ "$status" -eq 1 ] || { echo "value $v -> $status"; false; }
    [[ "$stderr" == *"auto_import_below_pct"* ]]
  done
}

@test "a backend without issue-list (78) dies naming the verb" {
  _setup_project; _stub
  rm "$TMPROOT/issue-list.github.acme_testproj"
  _init --survey
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"github has no issue-list (exit 78)"* ]]
}

@test "a failing issue-list dies with the backend's last stderr line" {
  _setup_project; _stub
  printf '%s\n' 3 > "$TMPROOT/issue-list.github.acme_testproj.rc"
  printf '%s\n' 'HTTP 401 from the tracker' > "$TMPROOT/issue-list.github.acme_testproj.err"
  _init --survey
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"exit 3"*"HTTP 401 from the tracker"* ]]
}

@test "malformed issue-list output dies naming the source" {
  _setup_project; _stub
  printf 'null\n' > "$TMPROOT/issue-list.github.acme_testproj"
  _init --survey
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"github acme/testproj"*"malformed line 1"* ]]
}

@test "round trip: wbs update after an import changes nothing (github)" {
  _setup_project; _gh
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  cp "$TMPDEV/WBS.md" "$TMPROOT/imported"
  : > "$TMPROOT/gh.log"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cmp "$TMPROOT/imported" "$TMPDEV/WBS.md"
  # the tracker phase ran (the real state-list), and nothing else did:
  # no code_source (no MR phase) and no active issue (no auto-add)
  grep -qFx 'issue list --repo acme/testproj --state all --limit 5000 --json number,state,stateReason,labels' "$TMPROOT/gh.log"
  [ "$(wc -l < "$TMPROOT/gh.log")" -eq 1 ]
  ! grep -q Unassigned "$TMPDEV/WBS.md"
}

@test "round trip: wbs update after an import changes nothing (jira)" {
  _setup_project; _jira
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qF '{issue: Issue-82, status_src: tracker}' "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/imported"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cmp "$TMPROOT/imported" "$TMPDEV/WBS.md"
}
