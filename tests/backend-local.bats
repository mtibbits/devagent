#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/backend-local.bats — #1016: the local code backend, scripts/code/local.sh.
# Every verb and every cell of its exit table (spec §9.2), over real git in a
# scratch repo per test. Run on its own or nested by tests/backend-contract.bats.
# The caller-level tests (ship, comments, mergemr, trust) are tests/local-callers.bats.
bats_require_minimum_version 1.5.0   # run --separate-stderr wherever stdout or stderr is pinned

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  LOCAL="$PLUGIN_ROOT/scripts/code/local.sh"
  R="$BATS_TEST_TMPDIR/repo one"
  _mkrepo "$R"
  MARKER="$BATS_TEST_TMPDIR/git-called"
}

teardown() { teardown_tmp_devagent_home; }

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# _mkrepo <dir>: a repo on `main` with one commit and a branch `feat` one commit ahead.
_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" checkout -q -b feat
  git -C "$1" commit -q --allow-empty -m feat
  git -C "$1" checkout -q main
}

# _git_shim: a DEVAGENT_GIT that records each call in $MARKER, then runs git.
_git_shim() {
  local s="$BATS_TEST_TMPDIR/gitshim"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nexec git "$@"\n' "$MARKER" > "$s"
  chmod +x "$s"
  echo "$s"
}

@test "local: the script is tracked with mode 100755" {
  run git -C "$PLUGIN_ROOT" ls-files -s scripts/code/local.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755\ * ]]
}

@test "local: push-branch does nothing, exits 0 and prints the push line on stderr" {
  DEVAGENT_GIT="$(_git_shim)" run --separate-stderr "$LOCAL" push-branch origin feat
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "push: not applicable (local code backend)" ]
  [ ! -e "$MARKER" ]
}

@test "local: merge-mr, issue-mrs, mr-checks and mr-view exit 78" {
  local v n=0
  for v in merge-mr issue-mrs mr-checks mr-view; do
    run --separate-stderr "$LOCAL" "$v"
    [ "$status" -eq 78 ]; [ -z "$output" ]
    [ "$stderr" = "$v: not implemented by the local code backend" ]
    n=$((n + 1))
    run --separate-stderr "$LOCAL" "$v" "local:%2Fx#feat" --method squash 12
    [ "$status" -eq 78 ]; [ -z "$output" ]
    [ "$stderr" = "$v: not implemented by the local code backend" ]
    n=$((n + 1))
  done
  [ "$n" -eq 8 ]
}

@test "local: branch-exists answers 0, 1 and 2" {
  run --separate-stderr "$LOCAL" branch-exists "$R" feat
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run --separate-stderr "$LOCAL" branch-exists "$R" nope
  [ "$status" -eq 1 ]; [ -z "$output" ]
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr "$LOCAL" branch-exists "$BATS_TEST_TMPDIR/plain" feat
  [ "$status" -eq 2 ]; [ -z "$output" ]
}

# _verb_args <verb>: positional arguments for <verb> in $R.
_verb_args() {
  case "$1" in
    push-branch) echo origin; echo feat ;;
    branch-exists) echo "$R"; echo feat ;;
    create-mr) echo "$R"; echo t; echo /dev/null; echo feat; echo main ;;
    *) ;;
  esac
}

# _verb_want <verb>: the exit _verb_args' arguments give.
_verb_want() {
  case "$1" in
    merge-mr|issue-mrs|mr-checks|mr-view) echo 78 ;;
    *) echo 0 ;;
  esac
}

@test "local: every verb accepts and ignores --key <value>" {
  local v n=0 a1 a2 s1 o1
  for v in push-branch merge-mr issue-mrs mr-checks mr-view branch-exists create-mr; do
    mapfile -t args < <(_verb_args "$v")
    run "$LOCAL" "$v" "${args[@]}"
    s1="$status"; o1="$output"
    [ "$s1" -eq "$(_verb_want "$v")" ] || { echo "$v: status $s1" >&2; false; }
    run "$LOCAL" "$v" "${args[@]}" --key github/o/r
    [ "$status" -eq "$s1" ] || { echo "$v: $status vs $s1" >&2; false; }
    [ "$output" = "$o1" ]
    n=$((n + 1))
  done
  [ "$n" -eq 7 ]
}

@test "local: a bad --key, an unknown option, a wrong argument count and an unknown verb exit 2" {
  local n=0
  _two() { run --separate-stderr "$LOCAL" "$@"; [ "$status" -eq 2 ] || { echo "$*: $status" >&2; return 1; }; [ -z "$output" ]; n=$((n + 1)); }
  _two branch-exists "$R" feat --key                 # --key with no value
  _two branch-exists "$R" feat --key ''              # --key with an empty value
  _two branch-exists "$R" feat --key=x               # --key=<v>
  _two branch-exists "$R" feat --key a --key b       # a second --key
  _two branch-exists "$R" feat --draft               # any other argument there
  _two branch-exists "$R"                            # a wrong argument count
  _two frob                                          # an unknown verb
  _two                                               # no verb
  _two merge-mr --key                                # D-key first, even on a 78 verb
  _two mr-checks --key=x
  [ "$n" -eq 10 ]
  run --separate-stderr "$LOCAL" push-branch origin  # push-branch: 0 whatever its positionals
  [ "$status" -eq 0 ]
}

# --- create-mr, the reference and the record (Task 3) ------------------------

# _cdir <repo>: git's own common-dir line for <repo>, CR stripped.
_cdir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir | tr -d '\r'; }

# _ref <repo> <branch>: the reference D-ref builds, by an independent encoder.
_ref() {
  python3 -X utf8 -c 'import sys,urllib.parse as u; q=lambda s: u.quote(s, safe="~"); print("local:" + q(sys.argv[1]) + "#" + q(sys.argv[2]))' "$(_cdir "$1")" "$2"
}

# _rec <repo> <branch>: the record's path.
_rec() {
  printf '%s/devagent/local-mr/%s' "$(_cdir "$1")" \
    "$(python3 -X utf8 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe="~"))' "$2")"
}

# _snap <repo>: refs, index and working tree as git reports them.
_snap() { git -C "$1" status --porcelain=v2 --branch; git -C "$1" for-each-ref; }

@test "local: create-mr writes the record and prints the reference" {
  local body="$BATS_TEST_TMPDIR/body.md"; echo body > "$body"
  run --separate-stderr "$LOCAL" create-mr "$R" "Add a thing" "$body" feat main
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$(_ref "$R" feat)" ]
  local f; f="$(_rec "$R" feat)"
  [ -f "$f" ]
  local want
  want="$(printf '%s\n' 'version: 1' 'state: open' 'head: feat' 'base: main' \
    "head_sha: $(git -C "$R" rev-parse feat)" 'merge_commit: -' 'title: Add a thing')"
  [ "$(cat "$f")" = "$want" ]
  [ "$(wc -l < "$f")" -eq 7 ]
}

@test "local: a head feat/12-a#b%c.d in a repo path with a space round-trips through the reference (AC 3)" {
  local b='feat/12-a#b%c.d' r2 dir n=0
  r2="$BATS_TEST_TMPDIR/caf""é repo"
  _mkrepo "$r2"
  for dir in "$R" "$r2"; do
    local tip; tip="$(git -C "$dir" rev-parse feat)"
    git -C "$dir" branch -q -D feat           # refs/heads/feat would block feat/…
    git -C "$dir" branch "$b" "$tip"
    run --separate-stderr "$LOCAL" create-mr "$dir" "t" /dev/null "$b" main
    [ "$status" -eq 0 ]
    [ "${output##*#}" = 'feat%2F12-a%23b%25c.d' ]
    local half="${output#local:}"; half="${half%#*}"
    [ "$(python3 -X utf8 -c 'import sys,urllib.parse as u; print(u.unquote(sys.argv[1]))' "$half" | tr -d '\r')" = "$(_cdir "$dir")" ]
    [ "$output" = "$(_ref "$dir" "$b")" ]
    grep -qxF "head: $b" "$(_rec "$dir" "$b")"
    n=$((n + 1))
  done
  [ "$n" -eq 2 ]
  [[ "$(_ref "$r2" "$b")" == *%C3%A9* ]]
}

@test "local: the root, a subdirectory, a linked worktree and a symlink give one reference" {
  local want n=0
  mkdir -p "$R/sub/dir"
  git -C "$R" worktree add -q "$BATS_TEST_TMPDIR/wt" -b other main
  want="$(_ref "$R" feat)"
  for spelling in "$R" "$R/sub/dir" "$BATS_TEST_TMPDIR/wt"; do
    run --separate-stderr "$LOCAL" create-mr "$spelling" t /dev/null feat main
    [ "$status" -eq 0 ]; [ "$output" = "$want" ] || { echo "$spelling: $output" >&2; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
  is_git_bash && skip "Git Bash: ln -s copies instead of linking by default"
  ln -s "$R" "$BATS_TEST_TMPDIR/link"
  run --separate-stderr "$LOCAL" create-mr "$BATS_TEST_TMPDIR/link" t /dev/null feat main
  [ "$status" -eq 0 ]; [ "$output" = "$want" ]
}

@test "local: Git Bash slash, mixed and backslash spellings of one repo give the same reference (AC 3)" {
  is_git_bash || skip "Git Bash only (drive-letter forms are relative paths elsewhere)"
  local posix mixed win lower want n=0
  posix="$(cd "$R" && pwd)"
  mixed="$(cygpath -m "$R")"
  win="$(cygpath -w "$R")"
  lower="$(printf '%s' "${mixed:0:1}" | tr 'A-Z' 'a-z')${mixed:1}"
  run --separate-stderr "$LOCAL" create-mr "$posix" t /dev/null feat main
  [ "$status" -eq 0 ]
  want="$output"
  [[ "$want" == local:[A-Z]%3A%2F* ]]
  for spelling in "$mixed" "$win" "$lower"; do
    run --separate-stderr "$LOCAL" create-mr "$spelling" t /dev/null feat main
    [ "$status" -eq 0 ]; [ "$output" = "$want" ] || { echo "$spelling: $output" >&2; false; }
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "local: create-mr ignores the cwd and an exported GIT_DIR, and records the named head, not HEAD" {
  local other="$BATS_TEST_TMPDIR/other"
  _mkrepo "$other"
  git -C "$R" checkout -q main
  cd "$other"
  GIT_DIR="$other/.git" run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 0 ]
  [ "$output" = "$(_ref "$R" feat)" ]
  grep -qxF "head_sha: $(git -C "$R" rev-parse feat)" "$(_rec "$R" feat)"
  [ "$(git -C "$R" rev-parse feat)" != "$(git -C "$R" rev-parse HEAD)" ]
  [ ! -e "$other/.git/devagent" ]
}

@test "local: create-mr --draft records open and prints the draft line" {
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main --draft
  [ "$status" -eq 0 ]
  [ "$output" = "$(_ref "$R" feat)" ]
  [ "$stderr" = "draft: not applicable (local code backend)" ]
  grep -qxF "state: open" "$(_rec "$R" feat)"
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main --key k --draft
  [ "$status" -eq 0 ]
}

@test "local: create-mr changes no ref, no index and no working-tree file" {
  echo x > "$R/untracked"
  local before; before="$(_snap "$R")"
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 0 ]
  [ "$(_snap "$R")" = "$before" ]
}

@test "local: create-mr refuses a non-repository, a missing head or base and an old git, and writes nothing" {
  local plain="$BATS_TEST_TMPDIR/plain" n=0 old="$BATS_TEST_TMPDIR/oldgit"
  mkdir -p "$plain"
  run --separate-stderr "$LOCAL" create-mr "$plain" t /dev/null feat main
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "not a git repository: $plain" ]; n=$((n + 1))
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null nope main
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "not a local branch: nope" ]; n=$((n + 1))
  run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat nobase
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "not a local branch: nobase" ]; n=$((n + 1))
  # An old git echoes the unknown option back: two lines, the first not a path.
  printf '#!/usr/bin/env bash\nfor a; do [ "$a" = --path-format=absolute ] && { echo "$a"; echo .git; exit 0; }; done\nexec git "$@"\n' > "$old"
  chmod +x "$old"
  DEVAGENT_GIT="$old" run --separate-stderr "$LOCAL" create-mr "$R" t /dev/null feat main
  [ "$status" -eq 1 ]; [ -z "$output" ]
  [ "${stderr##*$'\n'}" = "git 2.31 or newer is needed (rev-parse --path-format)" ]; n=$((n + 1))
  [ "$n" -eq 4 ]
  [ ! -e "$(_cdir "$R")/devagent" ]
}
