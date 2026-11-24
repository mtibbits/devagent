#!/usr/bin/env bats
# #966: the two verbs scripts/issue/github.sh gains for the leak gate —
# repo-owner (the tracker check's owner lookup) and post-comment (the one gated
# write). Every test runs under pg_setup: its own DA_HOME and HOME, the gh-stub
# first on PATH, GH_HOST unset. No test posts to a real tracker.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/post-gate-fixture'
load 'lib/trust-fixture'

setup() {
  pg_setup
}

_gh() { pg_run "$PG_GITHUB" "$@"; }
# _owner_json <json>: the gh-stub's repos/<owner>/<repo> answer.
_owner_json() { printf '%s\n' "$1" > "$GH_STUB_GATE_DIR/repo.json"; }

@test "[gh repo-owner] prints the owner id and login from one repos/<owner>/<repo> call" {
  _gh repo-owner acme/widgets
  [ "$status" -eq 0 ]
  [ "$output" = $'1001\tacme' ]
  [ -z "$stderr" ]
  [ "$(pg_gh_calls)" -eq 1 ]
  [ "$(cat "$GH_STUB_ARGV_LOG")" = "[api] [--hostname] [github.com] [repos/acme/widgets] GH_HOST=<unset>" ]
  # the host comes from the repo; GH_HOST is unset for the call either way.
  rm "$GH_STUB_ARGV_LOG"
  _owner_json '{"owner":{"login":"Big-Org_1","id":424242,"type":"Organization"}}'
  GH_HOST=github.com _gh repo-owner ghe.example/Big-Org_1/Widgets
  [ "$status" -eq 0 ]
  [ "$output" = $'424242\tBig-Org_1' ]
  [ "$(cat "$GH_STUB_ARGV_LOG")" = "[api] [--hostname] [ghe.example] [repos/Big-Org_1/Widgets] GH_HOST=<unset>" ]
}

@test "[gh repo-owner] failures leave stdout empty and never exit 2" {
  # _fails <rc> <args…>
  _fails() {
    local want="$1"; shift
    _gh repo-owner "$@"
    [ "$status" -eq "$want" ] || { echo "rc=$status, want $want, for: $*: $stderr" >&2; return 1; }
    [ -z "$output" ] || { echo "stdout for: $*" >&2; return 1; }
    [ -n "$stderr" ]
  }
  # bad arguments, and a malformed repo: exit 1 before any call
  _fails 1
  _fails 1 acme/widgets extra
  _fails 1 ''
  _fails 1 --kinds
  _fails 1 acme
  _fails 1 a/b/c/d
  # a bare repo while GH_HOST names another host
  GH_HOST=ghe.example _fails 1 acme/widgets
  [ "$(pg_gh_calls)" -eq 0 ]
  # a failed call
  echo 1 > "$GH_STUB_GATE_DIR/repo.rc"
  echo 'gh: Not Found (HTTP 404)' > "$GH_STUB_GATE_DIR/repo.err"
  _fails 1 acme/widgets
  [[ "$stderr" == *"HTTP 404"* ]]
  rm "$GH_STUB_GATE_DIR/repo.rc" "$GH_STUB_GATE_DIR/repo.err"
  # an answer with no numeric owner.id, or no usable login: exit 5
  local json
  for json in '{}' '[]' 'not json' '{"owner":null}' '{"owner":{"login":"acme"}}' \
              '{"owner":{"id":"1001","login":"acme"}}' '{"owner":{"id":0,"login":"acme"}}' \
              '{"owner":{"id":-5,"login":"acme"}}' '{"owner":{"id":1001}}' \
              '{"owner":{"id":1001,"login":"-acme"}}' '{"owner":{"id":1001,"login":"ac me"}}'; do
    _owner_json "$json"
    _fails 5 acme/widgets || { echo "answer: $json" >&2; false; }
  done
}
