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
  for v in push-branch merge-mr issue-mrs mr-checks mr-view branch-exists; do
    mapfile -t args < <(_verb_args "$v")
    run "$LOCAL" "$v" "${args[@]}"
    s1="$status"; o1="$output"
    [ "$s1" -eq "$(_verb_want "$v")" ] || { echo "$v: status $s1" >&2; false; }
    run "$LOCAL" "$v" "${args[@]}" --key github/o/r
    [ "$status" -eq "$s1" ] || { echo "$v: $status vs $s1" >&2; false; }
    [ "$output" = "$o1" ]
    n=$((n + 1))
  done
  [ "$n" -eq 6 ]
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
