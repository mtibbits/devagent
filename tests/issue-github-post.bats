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

# --- post-comment -------------------------------------------------------------
# The fixture is an owned GitHub tracker (whoami 1001 = owner 1001), alpha with
# push_mr = true, a clean post and a matching review record: a post that passes.

GATE_PASS="post-gate: permission pass
post-gate: tracker pass
post-gate: names pass
post-gate: review pass"

# _ready: the clean post and its review record.
_ready() { pg_post; pg_record; }
# _post [<repo> [<num> [<flags>…]]]: post-comment on the fixture post.
# shellcheck disable=SC2120  # called through `run _post …`, which shellcheck cannot see
_post() {
  local repo="${1:-acme/widgets}" num="${2:-7}"
  if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
  pg_run "$PG_GITHUB" post-comment "$repo" "$num" --project alpha --issue Issue-7 --file "$POST" --review "$RECORD" "$@"
}
# _no_write: the stub saw no comment POST, and nothing reached stdout.
_no_write() {
  [ ! -e "$GH_STUB_GATE_DIR/comment.posts" ] || { echo "a comment was posted" >&2; return 1; }
  [ ! -e "$GH_STUB_GATE_DIR/comment.body" ] || { echo "a body was written" >&2; return 1; }
  [ -z "$output" ] || { echo "stdout: $output" >&2; return 1; }
  if grep -qF -- '[--method] [POST]' "$GH_STUB_ARGV_LOG" 2>/dev/null; then echo "a POST was made" >&2; return 1; fi
}
# _held <check> <cause…>: exit leak-held, that hold as the last gate line, only
# pass lines before it, and no write.
_held() {
  local check="$1"; shift
  [ "$status" -eq "$(pg_held)" ] || { echo "rc=$status: $stderr" >&2; return 1; }
  [ "$(pg_gate_lines | tail -n 1)" = "post-gate: $check hold $*" ] || { echo "$stderr" >&2; return 1; }
  [ -z "$(pg_gate_lines | sed '$d' | grep -v ' pass$' || true)" ] || { echo "$stderr" >&2; return 1; }
  _no_write
}

@test "[gh post-comment] a clean post posts once and prints the comment URL" {
  _ready
  _post
  [ "$status" -eq 0 ] || { echo "rc=$status: $stderr" >&2; false; }
  [ "$output" = "https://github.com/acme/widgets/issues/7#issuecomment-1" ]
  [ "$stderr" = "$GATE_PASS" ]
  [ "$(grep -c '' "$GH_STUB_GATE_DIR/comment.posts")" -eq 1 ]
  cmp "$POST" "$GH_STUB_GATE_DIR/comment.body"
  # one POST, on the repo's host with GH_HOST unset, after the two tracker lookups.
  [ "$(grep -cF -- '[--method] [POST]' "$GH_STUB_ARGV_LOG")" -eq 1 ]
  [ "$(tail -n 1 "$GH_STUB_ARGV_LOG")" = \
    "[api] [--hostname] [github.com] [--method] [POST] [repos/acme/widgets/issues/7/comments] [-F] [body=@-] GH_HOST=<unset>" ]
  [ "$(pg_gh_calls)" -eq 3 ]
  # a capture's post, a host-qualified repo, and a body with no final newline.
  rm "$GH_STUB_GATE_DIR"/comment.*
  printf 'no final newline' > "$POST"; pg_record
  GH_HOST=github.com pg_run "$PG_GITHUB" post-comment ghe.example/acme/widgets 12 \
    --review "$RECORD" --file "$POST" --capture 2026-11-24-some-slug --project alpha
  [ "$status" -eq 0 ] || { echo "rc=$status: $stderr" >&2; false; }
  [ "$output" = "https://ghe.example/acme/widgets/issues/12#issuecomment-1" ]
  cmp "$POST" "$GH_STUB_GATE_DIR/comment.body"
  [ "$(tail -n 1 "$GH_STUB_ARGV_LOG")" = \
    "[api] [--hostname] [ghe.example] [--method] [POST] [repos/acme/widgets/issues/12/comments] [-F] [body=@-] GH_HOST=<unset>" ]
}

@test "[gh post-comment] a sentinel exits leak-held with names-hit and the stub sees no write" {
  printf '%s\n' 'first line' "this names $PG_SENTINEL" 'third' "and ${PG_SENTINEL^^} again" > "$POST"
  pg_record
  _post
  _held names names-hit hits=2 lines=2,4
  [ "$(pg_gate_lines | head -n 2)" = "post-gate: permission pass
post-gate: tracker pass" ]
  # the same under bash -x: pg_run fails the test if stderr holds the sentinel.
  rm -f "$GH_STUB_ARGV_LOG"
  pg_run bash -x "$PG_GITHUB" post-comment acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  _held names names-hit hits=2 lines=2,4
  grep -q '^+ ' <<<"$stderr"
  # a clean post under bash -x posts, and its trace carries no sentinel either.
  _ready
  pg_run bash -x "$PG_GITHUB" post-comment acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/acme/widgets/issues/7#issuecomment-1" ]
}

@test "[gh post-comment] every other hold writes nothing" {
  _ready
  # push-mr
  PG_ALPHA_PUSH=false pg_config
  _post
  _held permission push-mr project=alpha
  pg_config
  # trust: the project is in scope
  trust_fixture_policy "$HOME/.config/devagent/trust"
  _post
  _held permission trust
  # trust: an out-of-scope project names a scoped target
  PG_EXTRA=$'[project.beta.permissions]\npush_mr = true' pg_config
  pg_run "$PG_GITHUB" post-comment github.com/Acme/Widgets 7 --project beta --issue Issue-7 --file "$POST" --review "$RECORD"
  _held permission trust
  rm -rf "$HOME/.config/devagent"
  pg_config
  # unowned
  printf '{"owner":{"login":"acme","id":2002}}\n' > "$GH_STUB_GATE_DIR/repo.json"
  _post
  _held tracker unowned
  [ "$(pg_gate_lines | head -n 1)" = "post-gate: permission pass" ]
  # tracker-unavailable
  echo 1 > "$GH_STUB_GATE_DIR/repo.rc"
  _post
  _held tracker tracker-unavailable
  rm "$GH_STUB_GATE_DIR/repo.rc"
  printf '{"owner":{"login":"acme","id":1001}}\n' > "$GH_STUB_GATE_DIR/repo.json"
  # review-stale, review-blocking, review-missing
  echo 'edited after the review' >> "$POST"
  _post
  _held review review-stale
  [ "$(pg_gate_lines | head -n 3)" = "post-gate: permission pass
post-gate: tracker pass
post-gate: names pass" ]
  pg_record "$POST" "$RECORD" 1
  _post
  _held review review-blocking
  rm "$RECORD"
  _post
  _held review review-missing
  # a denylist that is not there
  pg_record
  rm "$PG_LIST"
  _post
  _held names denylist-missing
  # control: with nothing held the same call posts.
  printf '%s\n' "$PG_SENTINEL" > "$PG_LIST"
  _post
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$GH_STUB_GATE_DIR/comment.posts")" -eq 1 ]
}

@test "[gh post-comment] a policy that fails to load exits 9 and writes nothing" {
  _ready
  mkdir -p "$HOME/.config/devagent/trust"
  printf 'scopes = [\n' > "$HOME/.config/devagent/trust/policy.toml"
  _post
  [ "$status" -eq 9 ]
  [ -z "$(pg_gate_lines)" ]
  [[ "$stderr" == *"github.sh: trust: policy "*" — host-level refusal (exit 9): stop and fix the host; do not retry or work around it" ]]
  _no_write
  [ "$(pg_gh_calls)" -eq 0 ]
  # the snapshot of the post did not outlive the refusal.
  mkdir "$BATS_TEST_TMPDIR/tmp"
  TMPDIR="$BATS_TEST_TMPDIR/tmp" _post
  [ "$status" -eq 9 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

@test "[gh post-comment] usage faults exit 2 before any gate line" {
  _ready
  local base=(--project alpha --issue Issue-7 --file "$POST" --review "$RECORD")
  # _usage <args…>: exit 2, the verb's usage line, no gate line, no call, no write.
  _usage() {
    pg_run "$PG_GITHUB" post-comment "$@"
    [ "$status" -eq 2 ] || { echo "rc=$status for: $*: $stderr" >&2; return 1; }
    [ -z "$(pg_gate_lines)" ] || { echo "a gate line for: $*" >&2; return 1; }
    [[ "$stderr" == *"usage: "* ]] || { echo "no usage line for: $*: $stderr" >&2; return 1; }
    [ "$(pg_gh_calls)" -eq 0 ] || { echo "a gh call for: $*" >&2; return 1; }
    _no_write
  }
  _usage                                                         # no arguments
  _usage acme/widgets 7                                          # no flags
  _usage acme/widgets
  _usage acme/widgets 0 "${base[@]}"                             # a bad <num>
  _usage acme/widgets 07 "${base[@]}"
  _usage acme/widgets 7x "${base[@]}"
  _usage acme/widgets 12345678901 "${base[@]}"
  _usage acme "${base[@]}"                                       # <num> missing
  _usage acme 7 "${base[@]}"                                     # a malformed repo
  _usage a/b/c/d 7 "${base[@]}"
  _usage acme/widgets 7 "${base[@]}" --bogus x                   # an unknown flag
  _usage acme/widgets 7 "${base[@]}" --draft
  _usage acme/widgets 7 --project=alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  _usage acme/widgets 7 "${base[@]}" --file "$POST"              # a repeated flag
  _usage acme/widgets 7 "${base[@]}" --capture some-slug         # both --issue and --capture
  _usage acme/widgets 7 --project alpha --file "$POST" --review "$RECORD"          # neither
  _usage acme/widgets 7 --project alpha --issue Issue-7 --file "$POST"             # no --review
  _usage acme/widgets 7 --project alpha --issue Issue-7 --review "$RECORD"         # no --file
  _usage acme/widgets 7 --issue Issue-7 --file "$POST" --review "$RECORD"          # no --project
  _usage acme/widgets 7 --project alpha --issue Issue-7 --file "" --review "$RECORD"   # an empty value
  _usage acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review        # a flag with no value
  # the work item is the gate's to check: its usage is this verb's usage.
  _usage acme/widgets 7 --project gamma --issue Issue-7 --file "$POST" --review "$RECORD"
  _usage acme/widgets 7 --project alpha --issue 'Issue 7' --file "$POST" --review "$RECORD"
}

@test "[gh post-comment] a wrong-host repo, a missing gh or jq, or no snapshot exit 2 before any gate line" {
  _ready
  # _pre <args…>: exit 2 (not posted, the call cannot run here), no gate line, no write.
  _pre() {
    pg_run "$PG_GITHUB" post-comment "$@"
    [ "$status" -eq 2 ] || { echo "rc=$status for: $*: $stderr" >&2; return 1; }
    [ -z "$(pg_gate_lines)" ] || { echo "a gate line for: $*" >&2; return 1; }
    [ -n "$stderr" ]
    [ "$(pg_gh_calls)" -eq 0 ] || { echo "a gh call for: $*" >&2; return 1; }
    _no_write
  }
  # a bare repo while GH_HOST names another host
  GH_HOST=ghe.example _pre acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  [[ "$stderr" == *"host-qualify the repo"* ]]
  # gh, then jq, missing from PATH: a PATH holding only what bash needs.
  local bin="$BATS_TEST_TMPDIR/minpath" t
  mkdir "$bin"
  for t in bash cat sed grep env dirname basename mktemp rm tr cut sort python3 sha256sum mv; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  PATH="$bin" _pre acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  [[ "$stderr" == *"gh not found on PATH"* ]]
  ln -s "$(command -v gh)" "$bin/gh"
  PATH="$bin" _pre acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  [[ "$stderr" == *"jq not found on PATH"* ]]
  # a readable --file that cannot be snapshotted (no usable TMPDIR): exit 2, no gate run.
  TMPDIR="$BATS_TEST_TMPDIR/no-such-dir" _pre acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  [[ "$stderr" == *"private snapshot"* ]]
}

@test "[gh post-comment] an unreadable --file is held by the gate, never exit 1" {
  _ready
  # a --file that is not there, and one that is a directory: the gate holds
  # names gate-error file-unreadable after permission and tracker pass.
  _post_file() {
    pg_run "$PG_GITHUB" post-comment acme/widgets 7 --project alpha --issue Issue-7 --file "$1" --review "$RECORD"
  }
  _post_file "$BATS_TEST_TMPDIR/no-such-post.md"
  _held names gate-error file-unreadable
  _post_file "$BATS_TEST_TMPDIR"
  _held names gate-error file-unreadable
}

@test "[gh post-comment] a mode-000 --file is held by the gate, never exit 1" {
  skip_on_git_bash "chmod 000"
  skip_if_root
  _ready
  chmod 000 "$POST"
  pg_run "$PG_GITHUB" post-comment acme/widgets 7 --project alpha --issue Issue-7 --file "$POST" --review "$RECORD"
  chmod 600 "$POST"
  _held names gate-error file-unreadable
}

@test "[gh post-comment] a failed POST exits 1; an answer without html_url exits 5" {
  _ready
  local row
  # the POST itself fails: exit 1, nothing on stdout, after all four pass lines.
  echo 1 > "$GH_STUB_GATE_DIR/comment.rc"
  echo 'gh: Bad Gateway (HTTP 502)' > "$GH_STUB_GATE_DIR/comment.err"
  _post
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(pg_gate_lines)" = "$GATE_PASS" ]
  [[ "$stderr" == *"HTTP 502"* ]]
  rm "$GH_STUB_GATE_DIR/comment.rc" "$GH_STUB_GATE_DIR/comment.err"
  # gh exits 0 and the answer carries no usable html_url: exit 5.
  while IFS= read -r row; do
    printf '%s\n' "$row" > "$GH_STUB_GATE_DIR/comment.json"
    _post
    [ "$status" -eq 5 ] || { echo "rc=$status for answer: $row" >&2; false; }
    [ -z "$output" ]
    [ "$(pg_gate_lines)" = "$GATE_PASS" ]
  done <<'ROWS'
{}
{"id": 1}
{"html_url": null}
{"html_url": 7}
{"html_url": "http://github.com/acme/widgets/issues/7#issuecomment-1"}
{"html_url": ""}
[]
not json
ROWS
  # control: a well-formed answer prints its URL.
  printf '%s\n' '{"id": 99, "html_url": "https://github.com/acme/widgets/issues/7#issuecomment-99"}' > "$GH_STUB_GATE_DIR/comment.json"
  _post
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/acme/widgets/issues/7#issuecomment-99" ]
}

@test "[gh post-comment] the bytes gated are the bytes posted" {
  _ready
  local at_call="$BATS_TEST_TMPDIR/post-at-call.md" shim="$BATS_TEST_TMPDIR/shim"
  cp "$POST" "$at_call"
  # A gh shim, first on PATH, that appends a sentinel to the post file while the
  # tracker check runs (its first call), then hands every call to the stub.
  mkdir -p "$shim"
  cat > "$shim/gh" <<SHIM
#!/usr/bin/env bash
if [ ! -e "$BATS_TEST_TMPDIR/shim-fired" ]; then
  : > "$BATS_TEST_TMPDIR/shim-fired"
  printf 'appended during the gate: %s\n' "$PG_SENTINEL" >> "$POST"
fi
exec "$STUB_BIN/gh" "\$@"
SHIM
  chmod +x "$shim/gh"
  PATH="$shim:$PATH" _post
  [ "$status" -eq 0 ] || { echo "rc=$status: $stderr" >&2; false; }
  [ -e "$BATS_TEST_TMPDIR/shim-fired" ]
  # the file did change under the verb …
  if cmp -s "$POST" "$at_call"; then echo "the shim did not change the post file" >&2; false; fi
  grep -q "$PG_SENTINEL" "$POST"
  # … and what was gated and posted is the file as it was at the call.
  cmp "$at_call" "$GH_STUB_GATE_DIR/comment.body"
  [ "$stderr" = "$GATE_PASS" ]
}

@test "[gh post-comment] the snapshot is removed on every exit" {
  _ready
  mkdir "$BATS_TEST_TMPDIR/tmp"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  _post                                              # posted
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
  printf 'has %s\n' "$PG_SENTINEL" > "$POST"; pg_record
  _post                                              # held
  [ "$status" -eq "$(pg_held)" ]
  [ -z "$(ls -A "$TMPDIR")" ]
  _ready
  echo 1 > "$GH_STUB_GATE_DIR/comment.rc"
  _post                                              # the POST failed
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
