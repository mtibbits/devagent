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
  files+=("$GEN" "$REPO"/tests/fixtures/wbs-merge/*)
  # 11 manifest files, the generator, the 3 #707 merge fixtures
  [ "${#files[@]}" -eq 15 ]
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

@test "merge fixtures: the issue list meets the issue-list contract" {
  run python3 "$REPO/scripts/lib/wbs-import.py" check < "$REPO/tests/fixtures/wbs-merge/issue-list.jsonl"
  [ "$status" -eq 0 ]
  [ "$(tr -d '\r' <<< "$output")" = 16 ]
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
  # wbs update matches the fork leaves by the longest dir_prefix: an
  # unchanged tracker changes nothing, and a reopened fork issue is seen
  "$REPO/scripts/issue/github.sh" state-list acme/testproj > "$TMPROOT/state-list.github.acme_testproj"
  printf '1\tdone\n2\tdone\n' > "$TMPROOT/state-list.github.me_testproj-fork"
  cp "$TMPDEV/WBS.md" "$TMPROOT/imported"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"not found"* ]]
  cmp "$TMPROOT/imported" "$TMPDEV/WBS.md"
  printf '1\tdone\n2\topen\n' > "$TMPROOT/state-list.github.me_testproj-fork"
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qFx -- '  - [~] Fork two {issue: Issue-Fork-2, status_src: tracker}' "$TMPDEV/WBS.md"
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
  [[ "$stderr" == *"--merge"* ]]
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
  run grep -q Unassigned "$TMPDEV/WBS.md"
  [ "$status" -eq 1 ]
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

@test "wbs show --milestone finds quote-led milestone nodes by their written form (#789)" {
  _setup_project; _stub
  cat > "$TMPROOT/issue-list.github.acme_testproj" <<'JSONL'
{"id":"1","title":"One","body":"","state":"open","class":"open","created":"2026-03-01","closed":null,"milestone":"'v1'","labels":[],"type":null,"parent":null,"blocked_by":[],"url":"https://github.com/acme/testproj/issues/1"}
{"id":"2","title":"Two","body":"","state":"open","class":"open","created":"2026-03-02","closed":null,"milestone":"\"v1\"","labels":[],"type":null,"parent":null,"blocked_by":[],"url":"https://github.com/acme/testproj/issues/2"}
JSONL
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qFx -- "- [ ] 'v1' {milestone: \"'v1'\"}" "$TMPDEV/WBS.md"
  grep -qFx -- "- [ ] \"v1\" {milestone: \"'v1'\"}" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --milestone "'v1'"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[' <<< "$output")" -eq 2 ]
  [[ "$output" == *"  - [ ] One {issue: Issue-1}"* ]]
  [[ "$output" == *"  - [ ] Two {issue: Issue-2}"* ]]
  # the stored form is the safe_meta one; the tracker's own "v1" finds nothing
  run bash "$REPO/scripts/wbs.sh" show testproj --milestone '"v1"'
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[' <<< "$output")" -eq 0 ]
}

@test "docs: spec 13.1 states how a quote-led meta value is written (#789)" {
  local spec13="$TMPROOT/spec13"
  sed -n '/^### 13\.1 /,/^### 13\.3 /p' "$REPO/docs/specs/2026-05-19-devagent-plugin-design.md" > "$spec13"
  # the literal the test above proves wbs init writes
  grep -qF -- "{milestone: \"'v1'\"}" "$spec13"
  grep -qF -- "--milestone \"'v1'\"" "$spec13"
}

# --- --merge (#707) ----------------------------------------------------------------
# tests/fixtures/wbs-merge: base.md is a hand-arranged WBS and issue-list.jsonl
# the tracker (issues 1-16). Expected placement over base.md:
#   4      child of 1 (present)       last child of the Issue-1 node (rule 2)
#   16     child of 3 (present)       child of Issue-3, after its note (rule 2)
#   5, 6   epic 5 absent, 6 its child new top-level Epic: Beta holding 6 only;
#                                     7 (present, moved by hand) stays (rules 3, 1)
#   8      milestone M1               under the existing Milestone one (rule 4)
#   9      milestone M2               new top-level M2 container (rule 4); the
#                                     fenced Issue-9 line is not a node
#   10, 13, 14, 15  no parent         new top-level Unparented (rule 5); 13 is
#                                     named only by a FENCED exclusion line; 14
#                                     depends on 4 (new), 15 on 2 (present)
#   11     [-] present                untouched
#   12     excluded                   not added
MERGE_FIX="$REPO/tests/fixtures/wbs-merge"
BYTES="$REPO/tests/helpers/wbs_bytes.py"

# _merge_setup [kind] [base]: the stub backend over the merge issue list, and
# WBS.md = that variant of base (default lf, base.md); a copy in $TMPROOT/base
_merge_setup() {
  _setup_project; _stub
  cp "$MERGE_FIX/issue-list.jsonl" "$TMPROOT/issue-list.github.acme_testproj"
  mkdir -p "$TMPDEV"
  python3 "$BYTES" variant "$MERGE_FIX/${2:-base.md}" "${1:-lf}" "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/base"
  : > "$TMPROOT/backend.log"
}

# _merge_expected <src> <dst> <lf|crlf>: base.md's expected merge, built by
# byte insertion (independently of the parser)
_merge_expected() {
  python3 "$BYTES" insert-after "$1" "$2.1" "Note: task 3 waits on the vendor." "$3" \
    "    - [ ] Task 16 {issue: Issue-16}" \
    "  - [ ] Task 4 {issue: Issue-4}"
  python3 "$BYTES" insert-after "$2.1" "$2" "  - [ ] Plan the release" "$3" \
    "  - [ ] Task 8 {issue: Issue-8}" \
    "- [ ] Epic: Beta {issue: Issue-5}" \
    "  - [x] Task 6 {issue: Issue-6, status_src: tracker}" \
    "- [ ] M2 {milestone: M2}" \
    "  - [ ] Task 9 {issue: Issue-9}" \
    "- [ ] Unparented" \
    "  - [ ] Task 10 {issue: Issue-10}" \
    "  - [ ] Task 13 {issue: Issue-13}" \
    "  - [ ] Task 14 {issue: Issue-14, depends_on: Issue-4}" \
    "  - [ ] Task 15 {issue: Issue-15, depends_on: Issue-2}"
}

# _only_inserts <old> <new>: rc 1 when diff's normal output has only `a`
# hunks (the filter keeps any other line), rc 0 otherwise
_only_inserts() {
  local rc=0
  diff "$1" "$2" > "$TMPROOT/hunks" || rc=$?
  [ "$rc" -eq 1 ] || return 2
  grep -vE '^([0-9]+a[0-9]+(,[0-9]+)?|> .*)$' "$TMPROOT/hunks"
}

# _swap <flagsA> <flagsB>: `wbs init` with each flag string (word-split), each
# from the base WBS.md; leaves rc_a/rc_b, out_a/out_b, err_a/err_b and
# $TMPROOT/wbs_a, $TMPROOT/wbs_b, and asserts the two orders agree
_swap() {
  cp "$TMPROOT/base" "$TMPDEV/WBS.md"
  # shellcheck disable=SC2086
  _init $1
  rc_a=$status; out_a=$output; err_a=$stderr
  cp "$TMPDEV/WBS.md" "$TMPROOT/wbs_a"
  cp "$TMPROOT/base" "$TMPDEV/WBS.md"
  # shellcheck disable=SC2086
  _init $2
  rc_b=$status; out_b=$output; err_b=$stderr
  cp "$TMPDEV/WBS.md" "$TMPROOT/wbs_b"
  [ "$rc_a" -eq "$rc_b" ] || { echo "'$1' -> $rc_a, '$2' -> $rc_b"; printf '%s\n--\n%s\n' "$err_a" "$err_b"; false; }
  [ "$out_a" = "$out_b" ] || { diff <(printf '%s\n' "$out_a") <(printf '%s\n' "$out_b"); false; }
  [ "$err_a" = "$err_b" ] || { diff <(printf '%s\n' "$err_a") <(printf '%s\n' "$err_b"); false; }
  cmp "$TMPROOT/wbs_a" "$TMPROOT/wbs_b"
}

@test "--merge adds exactly the missing issues under the expected nodes, inserted lines only (every variant)" {
  local kind eol rc
  for kind in lf crlf lf-nofinal crlf-nofinal; do
    _merge_setup "$kind"
    eol=lf; [[ "$kind" == crlf* ]] && eol=crlf
    _merge_expected "$TMPROOT/base" "$TMPROOT/want" "$eol"
    _init --merge --all
    [ "$status" -eq 0 ] || { echo "$kind: $stderr"; false; }
    cmp "$TMPROOT/want" "$TMPDEV/WBS.md"
    [ "$stderr" = "wbs init --merge: added 10 issues to $TMPDEV/WBS.md (3 under existing nodes, 7 in new top-level nodes); 5 already present, 1 excluded" ]
    rc=0; _only_inserts "$TMPROOT/base" "$TMPDEV/WBS.md" || rc=$?
    [ "$rc" -eq 1 ] || { echo "$kind: not inserts only"; cat "$TMPROOT/hunks"; false; }
  done
  # control: a changed line is a `c` hunk, which the filter keeps
  sed 's/^- \[ \] Misc/- [ ] Misc!/' "$TMPDEV/WBS.md" > "$TMPROOT/changed"
  rc=0; _only_inserts "$TMPROOT/base" "$TMPROOT/changed" >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
}

@test "--merge: a second run writes nothing" {
  _merge_setup lf
  _init --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  cp "$TMPDEV/WBS.md" "$TMPROOT/first"
  chmod a-w "$TMPDEV/WBS.md"
  if [ -w "$TMPDEV/WBS.md" ]; then
    skip "cannot make WBS.md read-only here"
  fi
  _init --merge --all
  [ "$status" -eq 0 ]
  [ "$stderr" = "wbs init --merge: nothing to add to $TMPDEV/WBS.md; 15 already present, 1 excluded" ]
  cmp "$TMPROOT/first" "$TMPDEV/WBS.md"
}

@test "--merge: an issue filed after the first merge is the only one added" {
  _merge_setup lf
  _init --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  cp "$TMPDEV/WBS.md" "$TMPROOT/first"
  printf '%s\n' '{"id":"17","title":"Task 17","body":"","state":"open","class":"open","created":"2026-03-17","closed":null,"milestone":null,"labels":[],"type":null,"parent":null,"blocked_by":[],"url":"https://github.com/acme/testproj/issues/17"}' \
    >> "$TMPROOT/issue-list.github.acme_testproj"
  _init --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$stderr" = "wbs init --merge: added 1 issues to $TMPDEV/WBS.md (1 under existing nodes, 0 in new top-level nodes); 15 already present, 1 excluded" ]
  local rc=0
  diff "$TMPROOT/first" "$TMPDEV/WBS.md" > "$TMPROOT/hunks" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(wc -l < "$TMPROOT/hunks")" -eq 2 ]
  grep -qE '^[0-9]+a[0-9]+$' "$TMPROOT/hunks"
  [ "$(sed -n 2p "$TMPROOT/hunks")" = "> "'  - [ ] Task 17 {issue: Issue-17}' ]
  # in the existing Unparented, after its last child
  grep -A1 -Fx -- '  - [ ] Task 15 {issue: Issue-15, depends_on: Issue-2}' "$TMPDEV/WBS.md" | tail -1 \
    | grep -qFx -- '  - [ ] Task 17 {issue: Issue-17}'
}

@test "--merge: an excluded issue is not added, a [-] leaf stays, a fenced exclusion is not read" {
  _merge_setup lf
  _init --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  run grep -c '{issue: Issue-12' "$TMPDEV/WBS.md"
  [ "$status" -eq 1 ]
  [ "$output" = 0 ]
  [ "$(grep -c 'Issue-11' "$TMPDEV/WBS.md")" -eq 1 ]
  grep -qFx -- '  - [-] Task 11 {issue: Issue-11, status_src: tracker}' "$TMPROOT/base"
  grep -qFx -- '  - [-] Task 11 {issue: Issue-11, status_src: tracker}' "$TMPDEV/WBS.md"
  grep -qFx -- '  - [ ] Task 13 {issue: Issue-13}' "$TMPDEV/WBS.md"
}

# _shaped_import_cut: a #706 --all import of the shaped fixture in
# $TMPROOT/import, and WBS.md = that import less Issue-9 and its Unparented block
_shaped_import_cut() {
  _setup_project; _stub
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  cp "$TMPDEV/WBS.md" "$TMPROOT/import"
  sed -e '/{issue: Issue-9[,}]/d' -e '/^- \[ \] Unparented$/,$d' "$TMPROOT/import" > "$TMPDEV/WBS.md"
  [ "$(( $(wc -l < "$TMPROOT/import") - $(wc -l < "$TMPDEV/WBS.md") ))" -eq 35 ]
}

@test "--merge: re-adding deleted leaves reproduces a #706 import" {
  _shaped_import_cut
  _init --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [[ "$stderr" == *"added 34 issues"* ]]
  cmp "$TMPROOT/import" "$TMPDEV/WBS.md"
}

@test "--merge --open-only adds only the open selection" {
  _shaped_import_cut
  _issues > "$TMPROOT/before"
  _init --merge --open-only
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  _issues > "$TMPROOT/after"
  comm -13 "$TMPROOT/before" "$TMPROOT/after" > "$TMPROOT/got"
  _ids 42 43 44 45 46 47 48 49 50 > "$TMPROOT/want"
  diff "$TMPROOT/want" "$TMPROOT/got"
  [ "$(comm -23 "$TMPROOT/before" "$TMPROOT/after" | wc -l)" -eq 0 ]
}

@test "--merge on a missing WBS.md dies before any tracker call" {
  _setup_project; _stub
  _init --merge --all
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"WBS.md missing; run 'wbs init --from-tracker' first"* ]]
  [ ! -e "$TMPDEV/WBS.md" ]
  [ ! -s "$TMPROOT/gh.log" ]
  [ ! -s "$TMPROOT/backend.log" ]
  # the remedy works
  _init --from-tracker --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
}

@test "--from-tracker on an existing WBS.md names --merge, and the remedy works" {
  _merge_setup lf
  _init --from-tracker --all
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"exists; pass --merge"* ]]
  cmp "$TMPROOT/base" "$TMPDEV/WBS.md"
  [ ! -s "$TMPROOT/backend.log" ]
  _init --from-tracker --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [[ "$stderr" == *"added 10 issues"* ]]
}

@test "--merge flag crossings exit 2 before any tracker call" {
  _merge_setup lf
  local args want
  for args in "--merge --force|cannot be combined with --from-tracker or --merge" \
              "--force --merge --all|cannot be combined with --from-tracker or --merge" \
              "--merge --survey|cannot be combined with --merge" \
              "--merge --all --open-only|give at most one of" \
              "--merge=x|unknown flag"; do
    want="${args#*|}"
    # shellcheck disable=SC2086
    _init ${args%%|*}
    [ "$status" -eq 2 ] || { echo "args: $args -> $status: $stderr"; false; }
    [[ "$stderr" == *"$want"* ]] || { echo "args: $args: $stderr"; false; }
  done
  cmp "$TMPROOT/base" "$TMPDEV/WBS.md"
  [ ! -s "$TMPROOT/backend.log" ]
  [ ! -s "$TMPROOT/gh.log" ]
}

@test "wbs init: order-swapped flag pairs agree, and the multi-error order holds" {
  _merge_setup lf
  # the merge pair writes, the same in both orders
  _swap "--merge --from-tracker --all" "--from-tracker --merge --all"
  [ "$rc_a" -eq 0 ] || { echo "$err_a"; false; }
  [[ "$err_a" == *"added 10 issues"* ]]
  _merge_expected "$TMPROOT/base" "$TMPROOT/want" lf
  cmp "$TMPROOT/want" "$TMPROOT/wbs_a"
  # the survey pair prints the same survey and writes nothing
  _swap "--survey --from-tracker" "--from-tracker --survey"
  [ "$rc_a" -eq 0 ] || { echo "$err_a"; false; }
  jq -e '.total == 16' <<<"$out_a" >/dev/null
  jq -e '.total == 16' <<<"$out_b" >/dev/null
  cmp "$TMPROOT/base" "$TMPROOT/wbs_a"
  cmp "$TMPROOT/base" "$TMPROOT/wbs_b"
  # from here on, no tracker call
  : > "$TMPROOT/backend.log"
  _swap "--survey --merge" "--merge --survey"
  [ "$rc_a" -eq 2 ]
  [[ "$err_a" == *"cannot be combined with --merge"* ]]
  cmp "$TMPROOT/base" "$TMPROOT/wbs_a"
  # with several errors, a parse-loop error comes first, then the range count
  _init --merge --survey --bogus
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown flag '--bogus'"* ]]
  _init --merge --survey --all --open-only
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"give at most one of"* ]]
  [ ! -s "$TMPROOT/gh.log" ]
  cmp "$TMPROOT/base" "$TMPDEV/WBS.md"
  [ ! -s "$TMPROOT/backend.log" ]
}

@test "--merge with no range at or above the threshold: survey, marker, exit 10, WBS.md unchanged" {
  _setup_project; _gh
  mkdir -p "$TMPDEV"
  printf '# mine\n\n- [ ] Hand {issue: Issue-1}\n' > "$TMPDEV/WBS.md"
  cp "$TMPDEV/WBS.md" "$TMPROOT/base"
  _init --merge
  [ "$status" -eq 10 ]
  [ "${lines[${#lines[@]}-1]}" = "WBS-INIT: choose-range" ]
  _survey_json | jq -e '.auto_import == false and .total == 62' >/dev/null
  cmp "$TMPROOT/base" "$TMPDEV/WBS.md"
}

@test "--merge reuses an existing Unassigned bucket" {
  _merge_setup lf base-unassigned.md
  _init --merge --all
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -A4 -Fx -- '  - [ ] Task 7 {issue: Issue-7}' "$TMPDEV/WBS.md" > "$TMPROOT/got"
  printf '%s\n' '  - [ ] Task 7 {issue: Issue-7}' '  - [ ] Task 10 {issue: Issue-10}' \
    '  - [ ] Task 13 {issue: Issue-13}' '  - [ ] Task 14 {issue: Issue-14, depends_on: Issue-4}' \
    '  - [ ] Task 15 {issue: Issue-15, depends_on: Issue-2}' > "$TMPROOT/want"
  diff "$TMPROOT/want" "$TMPROOT/got"
  run grep -c Unparented "$TMPDEV/WBS.md"
  [ "$output" = 0 ]
}

# --- docs (Task 10) --------------------------------------------------------------
@test "docs name the script's marker and exit code" {
  local consts marker rc spec13 home
  consts="$(cd "$REPO/scripts/lib" && python3 -c 'import importlib.util as u; s = u.spec_from_file_location("m", "wbs-import.py"); m = u.module_from_spec(s); s.loader.exec_module(m); print(m.CHOOSE_RANGE_MARKER); print(m.CHOOSE_RANGE_RC)' | tr -d '\r')"
  marker="$(sed -n 1p <<< "$consts")"; rc="$(sed -n 2p <<< "$consts")"
  [ "$marker" = "WBS-INIT: choose-range" ] && [ "$rc" = 10 ]
  spec13="$TMPROOT/spec13"
  sed -n '/^### 13\.2 /,/^### 13\.3 /p' "$REPO/docs/specs/2026-05-19-devagent-plugin-design.md" > "$spec13"
  for home in "$REPO/commands/wbs.md" "$spec13" "$REPO/scripts/wbs.sh"; do
    grep -qF "$marker" "$home" || { echo "no marker in $home"; false; }
    grep -qE "(exit|exits|code) \`?${rc}\`?([^0-9]|$)" "$home" || { echo "no exit $rc in $home"; false; }
  done
  # the verb is in both contract homes
  grep -qF '| `issue-list`' "$REPO/README.md"
  sed -n '/^### 9\.1 /,/^### 9\.2 /p' "$REPO/docs/specs/2026-05-19-devagent-plugin-design.md" | grep -qE '^issue-list +<repo>'
}

@test "docs name --merge and the exclusion line in every home" {
  local key spec spec13 home rc
  key="$(cd "$REPO/scripts/lib" && python3 -c 'import importlib.util as u; s = u.spec_from_file_location("m", "wbs-parser.py"); m = u.module_from_spec(s); s.loader.exec_module(m); print(m.EXCLUDE_KEY)' | tr -d '\r')"
  [ "$key" = "wbs-exclude:" ]
  spec="$REPO/docs/specs/2026-05-19-devagent-plugin-design.md"
  spec13="$TMPROOT/spec13"
  sed -n '/^### 13\.1 /,/^### 13\.3 /p' "$spec" > "$spec13"
  for home in "$REPO/commands/wbs.md" "$spec13" "$REPO/scripts/wbs.sh"; do
    grep -qF -- '--merge' "$home" || { echo "no --merge in $home"; false; }
  done
  for home in "$REPO/commands/wbs.md" "$spec13"; do
    grep -qF -- "<!-- $key" "$home" || { echo "no exclusion line in $home"; false; }
  done
  # no home still says merging is #707's job (control: a planted line is found)
  printf 'merging is #707\n' > "$TMPROOT/planted"
  rc=0; grep -n 'is #707' "$TMPROOT/planted" >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  rc=0; grep -n 'is #707' "$REPO/commands/wbs.md" "$spec" "$REPO/scripts/wbs-init.sh" "$REPO/CHANGELOG.md" || rc=$?
  [ "$rc" -eq 1 ]
}
