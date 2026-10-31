#!/usr/bin/env bats
# #712 trust-off guard: the new read-only verbs (events, comment-records,
# whoami) are added with no caller. Two standing guards:
#   - a call-shape census over the caller surface, with a positive control
#     (a known caller verb, state-class) and a planted negative control;
#   - the gh-stub tripwire: a new-verb REST path exits 3 unless a test sets
#     GH_STUB_EVENTS_DIR, so any of the gh-stub consumers that reached one
#     would go red.

load 'lib/bats-helpers'

# _trust_off_hits <root> [verb-alternation]: git grep the caller surface for a
# backend invocation whose verb argument is one of the new verbs, plus any
# reference to the record library. 0 = hit(s) printed, 1 = none, 2 = error.
# Call shape, not the bare word, so prose about "events" is not a hit.
# The backends themselves (scripts/issue) and the library are their homes.
# Allow-list a legitimate prose hit with one more ':!<path>' pathspec and a
# comment naming the path and the reason (none today).
_trust_off_hits() {
  local root="$1" verbs="${2:-events|comment-records|whoami}" re rc1=0 rc2=0
  re='(["'"'"')}]|\.sh)[[:space:]]+('"$verbs"')[[:space:]]+["$]'
  # cd, not git -C: MSYS_NO_PATHCONV would also stop a /c/… root translating.
  cd "$root" || return 2
  MSYS_NO_PATHCONV=1 git grep -nE "$re" \
    -- scripts hooks commands skills agents ':!scripts/issue' ':!scripts/lib/issue-events.sh' \
    || rc1=$?
  MSYS_NO_PATHCONV=1 git grep -nwE 'bc_events_coverage|issue-events' \
    -- scripts hooks commands skills agents ':!scripts/issue' ':!scripts/lib/issue-events.sh' \
    || rc2=$?
  if [ "$rc1" -gt 1 ] || [ "$rc2" -gt 1 ]; then return 2; fi
  if [ "$rc1" -eq 0 ] || [ "$rc2" -eq 0 ]; then return 0; fi
  return 1
}

_stub_setup() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  unset GH_STUB_EVENTS_DIR
}

@test "trust-off: no caller surface invokes a new verb" {
  run _trust_off_hits "$PLUGIN_ROOT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "trust-off: the census predicate sees a known caller verb" {
  run _trust_off_hits "$PLUGIN_ROOT" state-class
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/mergemr.sh:253:"* ]]
}

@test "trust-off: a planted backend call reddens the census" {
  local r="$BATS_TEST_TMPDIR/r"
  mkdir -p "$r/scripts/issue"
  git -C "$r" init -q
  # shellcheck disable=SC2016  # literal shell text planted in a scratch repo
  printf '%s\n' '"$be" events "$repo" "$num"' > "$r/scripts/x.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '"$be" events "$repo" "$num"' > "$r/scripts/issue/y.sh"
  git -C "$r" add -A
  run _trust_off_hits "$r"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/x.sh:1:"* ]]
  [[ "$output" != *"scripts/issue/y.sh"* ]]
}

@test "trust-off: each allow-listed home exists and carries a new-verb token" {
  # The census excludes these paths; an exclusion that names nothing (a
  # rename) would silently widen nothing and hide a typo (W266).
  local home
  for home in scripts/issue scripts/lib/issue-events.sh; do
    [ -e "$PLUGIN_ROOT/$home" ]
    run grep -rlwE 'events|comment-records|whoami' "$PLUGIN_ROOT/$home"
    [ "$status" -eq 0 ]
  done
}

@test "gh-stub api: an unknown path exits 3 naming it" {
  _stub_setup
  run "$STUB_BIN/gh" api --hostname github.com repos/o/r/pulls/1/reviews
  [ "$status" -eq 3 ]
  [[ "$output" == *"stub-gh: api: unknown path repos/o/r/pulls/1/reviews"* ]]
}

@test "gh-stub api: branches, repos/<r> and pulls comments keep their answers" {
  _stub_setup
  run "$STUB_BIN/gh" api repos/o/r/branches/feat/x
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  run "$STUB_BIN/gh" api repos/o/r --jq .default_branch
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  run "$STUB_BIN/gh" api --hostname github.com --paginate "repos/o/r/pulls/7/comments?per_page=100" --jq '.[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$STUB_BIN/gh" api --hostname github.com --paginate "repos/o/r/pulls/7/comments?per_page=100" --jq 'length'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "gh-stub api: each new-verb path exits 3 while GH_STUB_EVENTS_DIR is unset" {
  _stub_setup
  local p
  for p in "repos/o/r/issues/5/events?per_page=100" "repos/o/r/issues/5/comments?per_page=100" user; do
    run "$STUB_BIN/gh" api --hostname github.com --paginate "$p"
    [ "$status" -eq 3 ]
    [[ "$output" == *"new-verb call with GH_STUB_EVENTS_DIR unset: ${p%%\?*}"* ]]
  done
}

@test "gh-stub api: events and comments without --paginate exit 3" {
  _stub_setup
  export GH_STUB_EVENTS_DIR="$BATS_TEST_TMPDIR/ev"
  mkdir -p "$GH_STUB_EVENTS_DIR"
  echo '[]' > "$GH_STUB_EVENTS_DIR/events.json"
  echo '[]' > "$GH_STUB_EVENTS_DIR/comments.json"
  run "$STUB_BIN/gh" api --hostname github.com "repos/o/r/issues/5/events?per_page=100"
  [ "$status" -eq 3 ]
  [[ "$output" == *"without --paginate"* ]]
  run "$STUB_BIN/gh" api --hostname github.com "repos/o/r/issues/5/comments?per_page=100"
  [ "$status" -eq 3 ]
  [[ "$output" == *"without --paginate"* ]]
  run "$STUB_BIN/gh" api --hostname github.com --paginate "repos/o/r/issues/5/events?per_page=100"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "gh-stub api: api and api graphql both log argv with GH_HOST" {
  _stub_setup
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_STUB_GRAPHQL_DIR="$BATS_TEST_TMPDIR/gql"
  export GH_STUB_GRAPHQL_COUNT="$BATS_TEST_TMPDIR/count"
  mkdir -p "$GH_STUB_GRAPHQL_DIR"
  echo '{}' > "$GH_STUB_GRAPHQL_DIR/1.json"
  ( unset GH_HOST; "$STUB_BIN/gh" api repos/o/r >/dev/null )
  GH_HOST=ghe.example "$STUB_BIN/gh" api graphql --hostname x -f query=q >/dev/null
  run cat "$GH_STUB_ARGV_LOG"
  [ "${lines[0]}" = "[api] [repos/o/r] GH_HOST=<unset>" ]
  [ "${lines[1]}" = "[api] [graphql] [--hostname] [x] [-f] [query=q] GH_HOST=ghe.example" ]
  [ "${#lines[@]}" -eq 2 ]
}
