#!/usr/bin/env bats
# #712: issue/github.sh events, events --kinds (and, below, whoami and
# comment-records) replayed through tests/fixtures/gh-stub.
#
# Fixtures: tests/fixtures/issue-github/ev/<n>/
#   events.json, comments.json   REST `gh api --paginate …?per_page=100` stdout
#   gql/<k>.json                 the k-th `gh api graphql` stdout (W1 issue
#                                edits, W2 timeline, W3 comments, then nested)
#   *.rc / *.err                 the call's exit code / stderr (stub knobs)
# Recorded 2026-10-31 with gh 2.95.0 (2026-06-17), read-only, by running
#   github.sh events mtibbits/devagent <n>
# for n in 66 561 705 122 684 725 through a `gh` wrapper on PATH that teed
# each call's stdout to a numbered file. REST payloads were projected at
# record time to the fields events reads: events {id node_id event created_at
# actor{id type} performed_via_github_app{id} label{name} assignee{id}
# rename}, comments {id node_id created_at updated_at user{id type}
# performed_via_github_app{id} body}; GraphQL pages are verbatim.
# Hand-built, derived from those recordings (and schema-validated only by
# the live U3 probe of the same queries on #66):
#   s1          #725 + a TAB/LF/space label labeled then unlabeled, an
#               assign/unassign pair, close/reopen, a deleted comment
#               (CommentDeletedEvent; no real one exists, U3) and a comment
#               body with TAB, CR, LF and a backslash
#   rest2p      #561 with REST events and comments each served as two pages
#   fail-rest2  #66 whose second REST events page fails after page 1
#   fail-gql2   #725 whose W3 comments walk fails on page 2
#   nest        #725 with one comment's edits split across a nested page
#   fail-nested nest whose nested node() page fails
#   gqlerr      W1 answers `errors`, gh exits 1 (gh 2.95.0, measured)
#   gqlerr0     the same body with exit 0 (stub-only)
#   crosscheck  #561 with lastEditedAt later than its newest edit
#   join        #66 with a REST label event and no GraphQL twin
#   joinrev     #66 with a GraphQL label event and no REST twin

load 'lib/bats-helpers'

setup() {
  bats_require_minimum_version 1.5.0
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  unset GH_HOST GH_STUB_EVENTS_DIR GH_STUB_GRAPHQL_DIR
  EV="$PLUGIN_ROOT/tests/fixtures/issue-github/ev"
  GHB="$PLUGIN_ROOT/scripts/issue/github.sh"
  export GH_STUB_GRAPHQL_COUNT="$BATS_TEST_TMPDIR/count"
}

teardown() { teardown_tmp_devagent_home; }

# _ev <fixture> <github.sh args…>: run github.sh against one fixture dir.
_ev() {
  export GH_STUB_EVENTS_DIR="$EV/$1" GH_STUB_GRAPHQL_DIR="$EV/$1/gql"
  rm -f "$GH_STUB_GRAPHQL_COUNT"
  shift
  run --separate-stderr "$GHB" "$@"
}

# _line <tsv-fields…>: 0 iff that exact record line is in $output.
_line() {
  local want l
  want="$(printf '%s\t' "$@")"
  want="${want%$'\t'}"
  for l in "${lines[@]}"; do [ "$l" = "$want" ] && return 0; done
  echo "missing line: $want" >&2
  return 1
}

# _n <regex>: the number of $output lines matching <regex> (grep -E).
_n() { printf '%s\n' "$output" | grep -cE "$1" || true; }

_KINDS="$(printf '%s\t%s\n' created full edited-title full edited-body full \
  edited-comment full deleted-comment detail-unknown labeled full \
  unlabeled full transitioned full assigned full unassigned full commented full)"

@test "[gh events] #561: edited-title and two edited-body records, none at creation" {
  _ev 561 events mtibbits/devagent 561
  [ "$status" -eq 0 ]
  _line 2026-07-29T16:22:14Z 28672894375 894144 user edited-title ""
  _line 2026-07-29T16:22:14Z "?" 894144 user edited-body ""
  _line 2026-07-29T16:32:52Z "?" 894144 user edited-body ""
  [ "$(_n $'\tedited-body\t')" -eq 2 ]
  [ "$(_n $'^2026-07-29T15:10:39Z\t.*\tedited-body\t')" -eq 0 ]
  _line 2026-07-29T15:10:39Z "?" 894144 user created ""
}

@test "[gh events] #561: lastEditedAt equal to the newest edit passes the cross-check" {
  run jq -r '.data.repository.issue.lastEditedAt' "$EV/561/gql/1.json"
  [ "$output" = "2026-07-29T16:32:52Z" ]
  _ev 561 events mtibbits/devagent 561
  [ "$status" -eq 0 ]
}

@test "[gh events] #66: two labeled epic records, distinct by seq and ordered by it" {
  _ev 66 events mtibbits/devagent 66
  [ "$status" -eq 0 ]
  local epic
  epic="$(printf '%s\n' "$output" | grep -E $'\tlabeled\tLA_kwDOSoThfM8AAAACmuE2GA epic$')"
  [ "$(printf '%s\n' "$epic" | wc -l)" -eq 2 ]
  [ "$(printf '%s\n' "$epic" | cut -f2 | tr '\n' ' ')" = "26544439624 26544439914 " ]
  _line 2026-06-09T21:40:07Z "?" 894144 user edited-body ""
  _line 2026-06-10T03:56:38Z "?" 894144 user edited-body ""
  [ "$(_n $'^2026-06-09T21:35:49Z\t.*\tedited-body\t')" -eq 0 ]
}

@test "[gh events] #122: edited-title with no edited-body; a null lastEditedAt passes" {
  _ev 122 events mtibbits/devagent 122
  [ "$status" -eq 0 ]
  _line 2026-07-02T11:46:16Z 27476628221 894144 user edited-title ""
  [ "$(_n $'\tedited-body\t')" -eq 0 ]
}

@test "[gh events] #705: the original body node is dropped" {
  _ev 705 events mtibbits/devagent 705
  [ "$status" -eq 0 ]
  [ "$(_n $'\tedited-body\t')" -eq 1 ]
  _line 2026-10-08T02:07:59Z "?" 894144 user edited-body ""
}

@test "[gh events] #725: the commented id equals the edited-comment detail" {
  _ev 725 events mtibbits/devagent 725
  [ "$status" -eq 0 ]
  _line 2026-10-24T17:21:16Z 6387235597 894144 user commented 6387235597
  _line 2026-10-24T22:22:43Z "?" 894144 user edited-comment 6387235597
  [ "$(_n $'\tedited-comment\t')" -eq 1 ]
}

@test "[gh events] #684: three commented records, no edited-comment" {
  _ev 684 events mtibbits/devagent 684
  [ "$status" -eq 0 ]
  [ "$(_n $'\tcommented\t')" -eq 3 ]
  _line 2026-10-04T18:53:23Z 5983269623 894144 user commented 5983269623
  [ "$(_n $'\tedited-comment\t')" -eq 0 ]
}

@test "[gh events] a nested userContentEdits page joins its comment's edits" {
  _ev nest events mtibbits/devagent 725
  [ "$status" -eq 0 ]
  _line 2026-10-24T22:22:43Z "?" 894144 user edited-comment 6387235597
  [ "$(_n $'\tedited-comment\t')" -eq 1 ]
}

@test "[gh events] s1: a deleted comment yields ? and the deleted author's id" {
  _ev s1 events mtibbits/devagent 725
  [ "$status" -eq 0 ]
  _line 2026-10-13T09:00:00Z "?" 894144 user deleted-comment "? 583231"
}

@test "[gh events] s1: a TAB/LF/space label is one six-field record with its GraphQL id" {
  _ev s1 events mtibbits/devagent 725
  [ "$status" -eq 0 ]
  source "$PLUGIN_ROOT/scripts/lib/issue-events.sh"
  local lab
  lab="$(printf '%s\n' "$output" | grep -F $'\tlabeled\tLA_s1odd ')"
  [ "$(printf '%s\n' "$lab" | wc -l)" -eq 1 ]
  [ "$(printf '%s\n' "$lab" | awk -F'\t' 'NF==6' | wc -l)" -eq 1 ]
  run bc_rec_parse <<< "$lab"
  [ "$(jq -r .id <<< "$output" | tr -d '\r')" = "LA_s1odd" ]
  [ "$(jq -c .rest <<< "$output" | tr -d '\r')" = '"a\tb\nc d  e"' ]
}

@test "[gh events] s1: assign, unassign, close and reopen records" {
  _ev s1 events mtibbits/devagent 725
  [ "$status" -eq 0 ]
  _line 2026-10-12T16:21:00Z 900000002 894144 user assigned 894144
  _line 2026-10-12T16:22:00Z 900000003 894144 user unassigned 894144
  _line 2026-10-12T16:24:00Z 900000005 894144 user transitioned "? closed"
  _line 2026-10-12T16:25:00Z 900000006 894144 user transitioned "? open"
}

@test "[gh events] the union of the replays' kinds equals --kinds, both ways" {
  local fx all="" declared got
  for fx in 66 561 705 122 684 725 s1; do
    _ev "$fx" events mtibbits/devagent 1
    [ "$status" -eq 0 ]
    all+="$(printf '%s\n' "$output" | cut -f5)"$'\n'
  done
  got="$(printf '%s' "$all" | sort -u)"
  run --separate-stderr "$GHB" events --kinds mtibbits/devagent
  [ "$status" -eq 0 ]
  declared="$(printf '%s\n' "$output" | cut -f1 | sort -u)"
  [ "$got" = "$declared" ]
}

@test "[gh events] rest2p: records from the second REST page are present" {
  _ev rest2p events mtibbits/devagent 561
  [ "$status" -eq 0 ]
  _line 2026-07-30T20:55:21Z 28744701740 894144 user transitioned "? closed"
  _line 2026-07-29T16:33:14Z 5120703672 894144 user commented 5120703672
}

@test "[gh events] a failing second REST page exits 1 with empty stdout" {
  _ev fail-rest2 events mtibbits/devagent 66
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "[gh events] a failing second GraphQL comments page exits 1 with empty stdout" {
  _ev fail-gql2 events mtibbits/devagent 725
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "[gh events] a failing nested userContentEdits page exits 1 with empty stdout" {
  _ev fail-nested events mtibbits/devagent 725
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "[gh events] a GraphQL errors answer (gh exit 1) exits 1 with empty stdout" {
  _ev gqlerr events mtibbits/devagent 66
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "[gh events] a GraphQL errors body with exit 0 exits 5 with empty stdout" {
  _ev gqlerr0 events mtibbits/devagent 66
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "[gh events] lastEditedAt later than the newest edited-body exits 5" {
  _ev crosscheck events mtibbits/devagent 561
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "[gh events] a REST label event with no GraphQL twin exits 5" {
  _ev join events mtibbits/devagent 66
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "[gh events] a GraphQL label event with no REST twin exits 5" {
  _ev joinrev events mtibbits/devagent 66
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "[gh events] REST calls carry --paginate, --hostname github.com and per_page=100" {
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  _ev 66 events mtibbits/devagent 66
  [ "$status" -eq 0 ]
  grep -qxF '[api] [--hostname] [github.com] [--paginate] [repos/mtibbits/devagent/issues/66/events?per_page=100] GH_HOST=<unset>' "$GH_STUB_ARGV_LOG"
  grep -qxF '[api] [--hostname] [github.com] [--paginate] [repos/mtibbits/devagent/issues/66/comments?per_page=100] GH_HOST=<unset>' "$GH_STUB_ARGV_LOG"
}

@test "[gh events] HOST/OWNER/REPO sends --hostname HOST with GH_HOST unset on every call" {
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_HOST=other.example
  _ev 66 events GHE.Example.com/mtibbits/devagent 66
  [ "$status" -eq 0 ]
  # A GraphQL entry spans lines (its query has newlines): count entries by
  # their [api] prefix and GH_HOST suffix.
  [ "$(grep -c '^\[api\] ' "$GH_STUB_ARGV_LOG")" -eq 5 ]
  [ "$(grep -c ' GH_HOST=' "$GH_STUB_ARGV_LOG")" -eq 5 ]
  [ "$(grep -c ' GH_HOST=<unset>$' "$GH_STUB_ARGV_LOG")" -eq 5 ]
  [ "$(grep -cF '[--hostname] [ghe.example.com]' "$GH_STUB_ARGV_LOG")" -eq 5 ]
  [ "$(grep -c '^\[api\] \[graphql\] ' "$GH_STUB_ARGV_LOG")" -eq 3 ]
}

@test "[gh events] a bare repo under a foreign GH_HOST exits 1 and makes no call" {
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_HOST=ghe.example
  _ev 66 events mtibbits/devagent 66
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"host-qualify the repo as HOST/OWNER/REPO"* ]]
  [ ! -e "$GH_STUB_ARGV_LOG" ]
}

@test "[gh events] a bare repo under GH_HOST=github.com proceeds" {
  export GH_HOST=github.com
  _ev 66 events mtibbits/devagent 66
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "[gh events] the GraphQL page cap is a function argument and exits 5" {
  local g="$BATS_TEST_TMPDIR/gql"
  mkdir -p "$g"
  printf '%s\n' '{"data":{"node":{"userContentEdits":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[]}}}}' > "$g/1.json"
  printf '%s\n' '{"data":{"node":{"userContentEdits":{"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[]}}}}' > "$g/2.json"
  export GH_STUB_GRAPHQL_DIR="$g"
  # shellcheck disable=SC2016  # expanded by the inner bash
  local walk='source "$1"; GT_HOST=github.com; _gh_gql_walk "$2" .data.node.userContentEdits "" "q" -f id=x'
  rm -f "$GH_STUB_GRAPHQL_COUNT"
  run --separate-stderr bash -c "$walk" _ "$GHB" 1
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"reached its cap of 1 pages"* ]]
  rm -f "$GH_STUB_GRAPHQL_COUNT"
  run --separate-stderr bash -c "$walk" _ "$GHB" 2
  [ "$status" -eq 0 ]
}

@test "[gh events] a repeated GraphQL cursor exits 5" {
  local g="$BATS_TEST_TMPDIR/gql"
  mkdir -p "$g"
  printf '%s\n' '{"data":{"node":{"userContentEdits":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[]}}}}' > "$g/1.json"
  cp "$g/1.json" "$g/2.json"
  export GH_STUB_GRAPHQL_DIR="$g"
  rm -f "$GH_STUB_GRAPHQL_COUNT"
  # shellcheck disable=SC2016
  run --separate-stderr bash -c 'source "$1"; GT_HOST=github.com; _gh_gql_walk 100 .data.node.userContentEdits "" "q"' _ "$GHB"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"repeated"* ]]
}

@test "[gh events] bad arguments exit 1, never 2" {
  local args
  for args in "events" "events mtibbits/devagent" "events --kind mtibbits/devagent" \
              "events --kinds=x mtibbits/devagent" "events mtibbits/devagent 0" \
              "events mtibbits/devagent 12345678901" "events mtibbits/devagent --kinds" \
              "events --kinds" "events --kinds mtibbits/devagent extra" \
              "events mtibbits/devagent 1 2" "events not-a-repo 1" "events ../x 1"; do
    # shellcheck disable=SC2086  # word-split on purpose
    run --separate-stderr "$GHB" $args
    [ "$status" -eq 1 ] || { echo "args: $args → $status" >&2; return 1; }
    [ -z "$output" ]
  done
  run --separate-stderr "$GHB" events "" 1
  [ "$status" -eq 1 ]
}

@test "[gh events] --kinds prints the GitHub coverage column and makes no gh call" {
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  run --separate-stderr "$GHB" events --kinds mtibbits/devagent
  [ "$status" -eq 0 ]
  [ "$output" = "$_KINDS" ]
  [[ "$output" == *$'transitioned\tfull'* ]]
  [[ "$output" == *$'deleted-comment\tdetail-unknown'* ]]
  [ ! -e "$GH_STUB_ARGV_LOG" ]
  export GH_HOST=ghe.example
  run --separate-stderr "$GHB" events --kinds mtibbits/devagent
  [ "$status" -eq 0 ]
  [ "$output" = "$_KINDS" ]
}

# --- whoami (#712 Task 6). ev/561/user.json is the live `gh api user` answer
# of 2026-10-31, projected to {login,id,type}; u403 (an App token, U2), u401
# and unoid (a 200 without a numeric id) are hand-built.

@test "[gh whoami] prints 894144, the actor id #561 events report" {
  _ev 561 events mtibbits/devagent 561
  [ "$status" -eq 0 ]
  source "$PLUGIN_ROOT/scripts/lib/issue-events.sh"
  local title actor
  title="$(printf '%s\n' "$output" | grep -F $'\tedited-title\t')"
  actor="$(bc_rec_parse <<< "$title" | jq -r .actor | tr -d '\r')"
  [ "$actor" = 894144 ]
  _ev 561 whoami mtibbits/devagent
  [ "$status" -eq 0 ]
  [ "$output" = "$actor" ]
}

@test "[gh whoami] an App-token 403 exits 1 with empty stdout" {
  _ev u403 whoami mtibbits/devagent
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"HTTP 403"* ]]
}

@test "[gh whoami] an expired-token 401 exits 1 with empty stdout" {
  _ev u401 whoami mtibbits/devagent
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "[gh whoami] a 200 without a numeric id exits 5 with empty stdout" {
  _ev unoid whoami mtibbits/devagent
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "[gh whoami] ghe.example.com/o/r sends --hostname ghe.example.com with GH_HOST unset" {
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_HOST=other.example
  _ev 561 whoami ghe.example.com/o/r
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_STUB_ARGV_LOG")" = "[api] [--hostname] [ghe.example.com] [user] GH_HOST=<unset>" ]
}

@test "[gh whoami] bad arguments exit 1, never 2" {
  local args
  for args in "whoami" "whoami o/r extra" "whoami --x" "whoami not-a-repo"; do
    # shellcheck disable=SC2086  # word-split on purpose
    run --separate-stderr "$GHB" $args
    [ "$status" -eq 1 ] || { echo "args: $args → $status" >&2; return 1; }
  done
}

# --- comment-records (#712 Task 7). ccross is #725 with comment
# 6387235597's lastEditedAt moved past its newest edit (hand-built).

@test "[gh comment-records] #684: three comments, each with an empty last-edited" {
  _ev 684 comment-records mtibbits/devagent 684
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = "5983269623 6039209608 6070341857 " ]
  [ "$(printf '%s\n' "$output" | cut -f5 | tr -d '\n')" = "" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' 'NF==6' | wc -l)" -eq 3 ]
  [ "$(printf '%s\n' "$output" | cut -f2,3 | sort -u)" = "$(printf '894144\tuser')" ]
  [ "$(printf '%s\n' "$output" | head -1 | cut -f4)" = 2026-10-04T18:53:23Z ]
}

@test "[gh comment-records] #725: the edited comment's last-edited equals its edited-comment time" {
  _ev 725 events mtibbits/devagent 725
  [ "$status" -eq 0 ]
  local edited
  edited="$(printf '%s\n' "$output" | grep -E $'\tedited-comment\t6387235597$' | cut -f1)"
  [ "$edited" = 2026-10-24T22:22:43Z ]
  _ev 725 comment-records mtibbits/devagent 725
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$1 == "6387235597" { print $5 }')" = "$edited" ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '$1 == "6387235597" { print $4 }')" = 2026-10-24T17:21:16Z ]
}

@test "[gh comment-records] s1: a body with TAB, CR, LF and a backslash parses back byte-exact" {
  _ev s1 comment-records mtibbits/devagent 725
  [ "$status" -eq 0 ]
  source "$PLUGIN_ROOT/scripts/lib/issue-events.sh"
  local line
  line="$(printf '%s\n' "$output" | grep '^6128903409'$'\t')"
  [ "$(printf '%s\n' "$line" | awk -F'\t' 'NF==6' | wc -l)" -eq 1 ]
  run jq -nr --arg l "$line" "$BC_EVENTS_JQ"' $l | split("\t") | map(bc_tsv_unescape) | .[5] == "tab\there\r\nline two back\\slash"'
  [ "$(printf '%s' "$output" | tr -d '\r')" = "true" ]
}

@test "[gh comment-records] a last-edited later than the newest edited-comment exits 5" {
  _ev ccross comment-records mtibbits/devagent 725
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "[gh comment-records] a failing nested page exits 1 with empty stdout" {
  _ev fail-nested comment-records mtibbits/devagent 725
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "[gh comment-records] no comments prints nothing and exits 0" {
  _ev 705 comment-records mtibbits/devagent 705
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "[gh comment-records] bad arguments exit 1, never 2" {
  local args
  for args in "comment-records" "comment-records o/r" "comment-records o/r 0" \
              "comment-records --kinds o/r" "comment-records o/r 1 2"; do
    # shellcheck disable=SC2086  # word-split on purpose
    run --separate-stderr "$GHB" $args
    [ "$status" -eq 1 ] || { echo "args: $args → $status" >&2; return 1; }
  done
}

@test "all three call-making verbs refuse a bare repo under GH_HOST=ghe.example with exit 1" {
  export GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_HOST=ghe.example
  local v
  for v in "events mtibbits/devagent 66" "comment-records mtibbits/devagent 66" "whoami mtibbits/devagent"; do
    # shellcheck disable=SC2086  # word-split on purpose
    _ev 66 $v
    [ "$status" -eq 1 ] || { echo "$v → $status" >&2; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == *"host-qualify"* ]]
  done
  [ ! -e "$GH_STUB_ARGV_LOG" ]
}
