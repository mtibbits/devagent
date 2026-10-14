#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "code/github.sh push-branch invokes git push remote branch" {
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" push-branch origin fix/1-foo
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push --set-upstream origin fix/1-foo"
}

@test "code/github.sh create-mr calls gh pr create with body file" {
    devagent_stub gh "https://github.com/acme/testproj/pull/42"
    body="$DEVAGENT_TMP/body.md"
    echo "the body" > "$body"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" create-mr acme/testproj "T" "$body" feat/1 main
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/acme/testproj/pull/42" ]
    devagent_assert_logged "gh pr create --repo acme/testproj --title T --body-file $body --head feat/1 --base main"
}

@test "code/github.sh create-mr --draft adds --draft flag" {
    devagent_stub gh "https://github.com/acme/testproj/pull/43"
    body="$DEVAGENT_TMP/body.md"
    echo "the body" > "$body"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" create-mr acme/testproj "T" "$body" feat/1 main --draft
    [ "$status" -eq 0 ]
    devagent_assert_logged "--draft"
}

@test "code/github.sh mr-state queries gh and prints state" {
    devagent_stub gh "open"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-state https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [ "$output" = "open" ]
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42 --json state --jq .state"
}

# #84: gh stub that emulates `--jq` by piping $GH_STUB_JSON (`pr view`) or
# $GH_STUB_API_JSON (`api`, #592) through real jq. jq 1.7 stands in for gh's
# built-in gojq: byte-identity was validated against real gh 2.45.0 for the #84
# conversation filter (Issue-84 analysis/); the #592 review/inline filters
# (`def entry($…)`, `@base64`, `tostring`, `if … then … end`) only by a live
# read-only smoke on gnuradio/volk#878 (Issue-592 actualWork).
_jq_gh_stub() {
    cat > "$DEVAGENT_STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
printf 'gh' >> "$DEVAGENT_STUB_LOG"
for a in "\$@"; do printf ' %s' "\$a" >> "$DEVAGENT_STUB_LOG"; done
printf '\n' >> "$DEVAGENT_STUB_LOG"
filter=""; prev=""
for a in "\$@"; do [ "\$prev" = "--jq" ] && filter="\$a"; prev="\$a"; done
[ -n "\$filter" ] || { echo "stub-gh: no --jq filter seen" >&2; exit 1; }
if [ "\$1" = api ]; then
    [ "\${GH_STUB_API_RC:-0}" -eq 0 ] || { echo "HTTP 403" >&2; exit "\$GH_STUB_API_RC"; }
    printf '%s' "\${GH_STUB_API_JSON:-[]}" | jq -r "\$filter"
else
    [ "\${GH_STUB_PR_RC:-0}" -eq 0 ] || { echo "GraphQL: Could not resolve to a PullRequest" >&2; exit "\$GH_STUB_PR_RC"; }
    printf '%s' "\$GH_STUB_JSON" | jq -r "\$filter"
fi
STUB
    chmod +x "$DEVAGENT_STUB_BIN/gh"
}

@test "code/github.sh mr-comments emits §9.3 shape from --json comments (#84)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[{"author":{"login":"reviewer"},"createdAt":"2026-06-12T10:00:00Z","body":"Looks good"},{"author":{"login":"alice"},"createdAt":"2026-06-11T09:00:00Z","body":"One nit"}]}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    # Needle deliberately stops at --jq: the filter body is an implementation
    # detail tests must not pin verbatim (multiline filter shares the log line).
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42 --json comments,reviews --jq"
    [[ "$output" == *"## Comments (2)"* ]]
    [[ "$output" == *"### @reviewer · 2026-06-12"* ]]
    [[ "$output" == *"### @alice · 2026-06-11"* ]]
    [[ "$output" == *"Looks good"* ]]
}

@test "code/github.sh mr-comments emits empty header for zero comments (#84)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[]}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Comments (0)"* ]]
    [[ "$output" != *"### @"* ]]
}

@test "code/github.sh mr-comments propagates gh failure (#84)" {
    devagent_stub gh "" 1
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -ne 0 ]
}

@test "code/github.sh merge-mr defaults to squash" {
    devagent_stub gh ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" merge-mr https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr merge https://github.com/acme/testproj/pull/42 --squash"
}

@test "code/github.sh merge-mr --method merge passes --merge" {
    devagent_stub gh ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" merge-mr https://github.com/acme/testproj/pull/42 --method merge
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr merge https://github.com/acme/testproj/pull/42 --merge"
}

@test "code/github.sh merge-mr --method rebase passes --rebase" {
    devagent_stub gh ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" merge-mr https://github.com/acme/testproj/pull/42 --method rebase
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr merge https://github.com/acme/testproj/pull/42 --rebase"
}

@test "code/github.sh merge-mr rejects unknown --method" {
    devagent_stub gh ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" merge-mr https://github.com/acme/testproj/pull/42 --method nonsense
    [ "$status" -ne 0 ]
}

@test "code/github.sh branch-exists returns 0 when present, 1 on a real HTTP 404 (#41, #85)" {
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
# Two endpoints (#243): the branch probe `api repos/<repo>/branches/<branch>`
# (0 iff it ends in /present, else a real "Branch not found (HTTP 404)"), and
# the repo-readability probe `api repos/<repo>` (no /branches/) which succeeds
# here — this repo IS readable, so an absent branch is a genuine rc 1, not rc 2.
case "$*" in
  *"branches/present") exit 0 ;;
  *"branches/"*)       echo "gh: Branch not found (HTTP 404)" >&2; exit 1 ;;
  *)                   exit 0 ;;   # repo-readability probe: readable
esac
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo present
    [ "$status" -eq 0 ]
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo absent
    [ "$status" -eq 1 ]
}

@test "code/github.sh branch-exists exits 2 when a 404 masks an unreadable private repo (#243)" {
    # GitHub returns HTTP 404 for an AUTHORIZATION failure on a private repo (it
    # hides existence rather than 403). A branch-endpoint 404 is "branch absent"
    # only if the repo itself is readable; when the repo probe also 404s (token
    # can't read the repo at all), branch-exists must fail closed to rc 2 — never
    # rc 1 — so ship.sh does not silently drop a live parent base.
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
# Token cannot read the repo: every endpoint (branch probe AND repo probe) 404s.
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/private feat/x
    [ "$status" -eq 2 ]
}

@test "code/github.sh branch-exists exits 2 (can't determine) on a network failure, not 1 (#85)" {
    # A transient (no "HTTP 404" in the error) must NOT read as "absent" (1) —
    # ship.sh treats rc 1 as confirmed-absent and would discard the parent base.
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: error connecting to api.github.com" >&2
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo whatever
    [ "$status" -eq 2 ]
    # #269: rc 2 carries a network-classified diagnostic on stderr.
    echo "$output" | grep -qi "network"
}

@test "code/github.sh branch-exists exits 2 on a 403 rate-limit, not 1 (#85); rate-limit diagnosed (#269)" {
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: API rate limit exceeded (HTTP 403)" >&2
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo whatever
    [ "$status" -eq 2 ]
    # #269: a 403 that names a rate limit must read as rate-limit, never auth.
    echo "$output" | grep -qi "rate-limited"
    run grep -qi "authentication" <<<"$output"
    [ "$status" -ne 0 ]
}

@test "code/github.sh branch-exists exits 2 on an auth failure, distinctly diagnosed (#269)" {
    # A 401/403 with NO rate-limit text is an auth/authz problem (bad/under-scoped
    # token). Both the branch probe and the repo probe fail the same way.
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: HTTP 401: Bad credentials" >&2
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo whatever
    [ "$status" -eq 2 ]
    echo "$output" | grep -qi "authentication"
    run grep -qi "network" <<<"$output"
    [ "$status" -ne 0 ]
}

@test "code/github.sh merged-pr-head exits 0 when a merged PR has the head, 1 when none (#154)" {
    # Stub gh's `pr list … --jq length`: echo the count of merged PRs for the head.
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do [ "$1" = "--head" ] && head="$2"; shift; done
[ "$head" = "dead" ] && { echo 1; exit 0; }   # a merged PR has this head
echo 0; exit 0                                  # no merged PR
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" merged-pr-head me/repo dead
    [ "$status" -eq 0 ]
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" merged-pr-head me/repo live
    [ "$status" -eq 1 ]
}

@test "code/github.sh merged-pr-head exits >=2 (can't determine) when gh errors (#154)" {
    # gh failure (auth/network/bad repo) must NOT read as "no merged PR" — it is
    # "can't determine", so ship.sh leaves the parent base unchanged (fail-open).
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: network error" >&2; exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" merged-pr-head me/repo whatever
    [ "$status" -ge 2 ]
}

@test "code/github.sh merged-pr-head treats empty/non-numeric stdout as can't-determine, not none (#154)" {
    # gh exits 0 but prints nothing (or a stray notice): an unparseable count is NOT
    # "no merged PR" (rc 1) — it is "can't determine" (rc >= 2), so ship leaves the
    # parent base unchanged rather than trusting an unprovable parent as live.
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
exit 0      # success, but no stdout at all
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" merged-pr-head me/repo whatever
    [ "$status" -ge 2 ]
}

@test "code/github.sh mr-comments conversation-only output is byte-identical to the #84 filter (#592 AC3)" {
    _jq_gh_stub
    GH_STUB_JSON="$(cat "$BATS_TEST_DIRNAME/fixtures/code-github/mr-comments-conversation.json")"
    export GH_STUB_JSON
    "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42 > "$DEVAGENT_TMP/out"
    cmp "$DEVAGENT_TMP/out" "$BATS_TEST_DIRNAME/fixtures/code-github/mr-comments-conversation.golden"
}

@test "code/github.sh mr-comments empty output is byte-exact (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[],"reviews":[]}'
    "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42 > "$DEVAGENT_TMP/out"
    printf '## Comments (0)\n\n' | cmp - "$DEVAGENT_TMP/out"
}

@test "code/github.sh mr-comments surfaces an inline comment when there are no conversation comments (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[],"reviews":[{"author":{"login":"jdemel"},"state":"COMMENTED","submittedAt":"2026-09-11T19:24:51Z","body":""}]}'
    export GH_STUB_API_JSON='[{"user":{"login":"jdemel"},"created_at":"2026-09-11T19:24:33Z","path":"kernels/volk/x.h","line":324,"original_line":334,"body":"Use the fast path here."}]'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Comments (1)"* ]]
    [[ "$output" == *"### @jdemel · 2026-09-11 · kernels/volk/x.h:324"* ]]
    [[ "$output" == *"Use the fast path here."* ]]
    [[ "$output" != *"review:"* ]]          # empty COMMENTED container is dropped
    [ "$(grep -c '^### @' <<<"$output")" -eq 1 ]
    devagent_assert_logged "gh api --hostname github.com --paginate repos/acme/testproj/pulls/42/comments?per_page=100 --jq"
}

@test "code/github.sh mr-comments review entries carry their verdict; COMMENTED containers and PENDING are dropped (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[{"author":{"login":"alice"},"createdAt":"2026-06-10T00:00:00Z","body":"conv"}],"reviews":[{"author":{"login":"bob"},"state":"CHANGES_REQUESTED","submittedAt":"2026-06-11T00:00:00Z","body":"split it"},{"author":{"login":"carol"},"state":"APPROVED","submittedAt":"2026-06-12T00:00:00Z","body":""},{"author":{"login":"dan"},"state":"COMMENTED","submittedAt":"2026-06-12T00:00:00Z","body":""},{"author":{"login":"erin"},"state":"COMMENTED","submittedAt":"2026-06-13T00:00:00Z","body":"summary note"},{"author":{"login":"me"},"state":"PENDING","submittedAt":null,"body":"my draft"}]}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Comments (4)"* ]]
    [[ "$output" == *"### @bob · 2026-06-11 · review: CHANGES_REQUESTED"* ]]
    [[ "$output" == *"### @carol · 2026-06-12 · review: APPROVED"* ]]
    [[ "$output" == *"### @erin · 2026-06-13 · review: COMMENTED"* ]]
    [[ "$output" != *"@dan"* ]]
    [[ "$output" != *"my draft"* ]]
    [[ "$output" == *"### @alice"*"### @bob"* ]]   # conversation before reviews
}

@test "code/github.sh mr-comments anchors outdated inline comments to original_line and file-level ones to the path (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[],"reviews":[]}'
    export GH_STUB_API_JSON='[{"user":{"login":"u1"},"created_at":"2026-06-01T00:00:00Z","path":"a.sh","line":null,"original_line":334,"body":"outdated"},{"user":{"login":"u2"},"created_at":"2026-06-02T00:00:00Z","path":"b.sh","line":null,"original_line":null,"body":"file-level"}]'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [[ "$output" == *"### @u1 · 2026-06-01 · a.sh:334"* ]]
    grep -qx '### @u2 · 2026-06-02 · b.sh' <<<"$output"
}

@test "code/github.sh mr-comments fails closed when the inline-comments call fails, naming the remedy (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[{"author":{"login":"a"},"createdAt":"2026-06-01T00:00:00Z","body":"x"}],"reviews":[]}'
    export GH_STUB_API_RC=1
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -ne 0 ]                                        # gh's rc, passed through as every verb here does
    [[ "$output" == *"HTTP 403"* ]]                            # the api call itself failed, not the stub guard
    [[ "$output" == *"DEVAGENT_MR_COMMENTS_SKIP_INLINE=1"* ]]
    [[ "$output" != *"## Comments"* ]]
}

@test "code/github.sh mr-comments DEVAGENT_MR_COMMENTS_SKIP_INLINE=1 skips the inline call and marks the gap (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[{"author":{"login":"a"},"createdAt":"2026-06-01T00:00:00Z","body":"x"}],"reviews":[]}'
    export GH_STUB_API_RC=1
    DEVAGENT_MR_COMMENTS_SKIP_INLINE=1 run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Comments (1)"* ]]
    grep -qx '> inline review comments not fetched (DEVAGENT_MR_COMMENTS_SKIP_INLINE=1)' <<<"$output"
    run grep -q '^gh api' "$DEVAGENT_STUB_LOG"
    [ "$status" -eq 1 ]
}

@test "code/github.sh mr-comments passes a GHE host and strips a URL fragment (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[],"reviews":[]}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments 'https://ghe.example.com/org/repo/pull/7#discussion_r1'
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh api --hostname ghe.example.com --paginate repos/org/repo/pulls/7/comments?per_page=100 --jq"
}

@test "code/github.sh mr-comments refuses a non-PR URL without calling gh (#592)" {
    _jq_gh_stub
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/issues/7
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot parse PR URL"* ]]
    [ ! -s "$DEVAGENT_STUB_LOG" ]
}

@test "code/github.sh mr-comments fails closed when the pr view call fails (#592)" {
    _jq_gh_stub
    export GH_STUB_PR_RC=1
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve to a PullRequest"* ]]  # gh's own failure, not the stub guard
    [[ "$output" != *"## Comments"* ]]
}

@test "code/github.sh mr-comments hands gh the parsed URL, so a scheme-less one is not read as a cwd branch (#592)" {
    _jq_gh_stub
    export GH_STUB_JSON='{"comments":[],"reviews":[]}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments github.com/acme/testproj/pull/42/files
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42 --json comments,reviews --jq"
    devagent_assert_logged "gh api --hostname github.com --paginate repos/acme/testproj/pulls/42/comments?per_page=100 --jq"
}

# --- issue-mrs (#704) --------------------------------------------------------
# The gh-stub's `api graphql` arm replays tests/fixtures/code-github/
# issue-mrs-*.json (provenance: issue-mrs-README.md), one file per call.
GQL_FIX="$BATS_TEST_DIRNAME/fixtures/code-github"

_gql_stub() {
    cp "$BATS_TEST_DIRNAME/fixtures/gh-stub" "$DEVAGENT_STUB_BIN/gh"
    chmod +x "$DEVAGENT_STUB_BIN/gh"
    export GH_STUB_GRAPHQL_DIR="$DEVAGENT_TMP/gql"
    export GH_STUB_ARGS_LOG="$DEVAGENT_TMP/gh-args.log"
    mkdir -p "$GH_STUB_GRAPHQL_DIR"
}

# _gql_serve <k> <response-file> [rc] [stderr]: the k-th graphql call's reply.
_gql_serve() {
    cp "$2" "$GH_STUB_GRAPHQL_DIR/$1.json"
    [ -z "${3:-}" ] || printf '%s\n' "$3" > "$GH_STUB_GRAPHQL_DIR/$1.rc"
    [ -z "${4:-}" ] || printf '%s\n' "$4" > "$GH_STUB_GRAPHQL_DIR/$1.err"
}

_gql_calls() {
    cat "$GH_STUB_GRAPHQL_DIR/count" 2>/dev/null || echo 0
}

_issue_mrs() {
    run "$DEVAGENT_ROOT/scripts/code/github.sh" issue-mrs "$@"
}

# _gql_batch <n>: a batch reply whose n aliases have empty timelines.
_gql_batch() {
    jq -n --argjson n "$1" '{data: {repository: (reduce range(0; $n) as $k ({};
        .["i\($k)"] = {timelineItems: {totalCount: 0,
          pageInfo: {hasNextPage: false, endCursor: null}, nodes: []}}))}}'
}

# _gql_page <cursor> <hasNextPage> [totalCount]: a page reply holding one PR
# that closes #1.
_gql_page() {
    jq -n --arg c "$1" --argjson more "$2" --argjson total "${3:-2}" '{data: {repository: {issue: {timelineItems: {
        totalCount: $total, pageInfo: {hasNextPage: $more, endCursor: $c},
        nodes: [{source: {__typename: "PullRequest", number: 7, title: "t",
          body: "Closes #1", state: "OPEN", isDraft: false,
          createdAt: "2026-07-01T00:00:00Z", mergedAt: null,
          repository: {nameWithOwner: "acme/testproj"}}}]}}}}}'
}

# _gql_truncate <file>: alias i0 reports 2 cross-references, holds 1, has more.
_gql_truncate() {
    jq '.data.repository.i0.timelineItems = {totalCount: 2,
        pageInfo: {hasNextPage: true, endCursor: "C1"},
        nodes: [{source: {__typename: "Issue"}}]}' "$1" > "$1.t"
    mv "$1.t" "$1"
}

# Every issue(number: takes a $variable; no literal number, owner or name.
_query_shape_ok() {
    local q="$1" calls
    [[ "$q" == *'issue(number:'* ]] || return 1
    if grep -qE 'number:[0-9]|owner:"|name:"' <<<"$q"; then return 1; fi
    calls="$(grep -oE 'issue\(number:[^)]*\)' <<<"$q")"
    if grep -vqE '^issue\(number:\$n[0-9]*\)$' <<<"$calls"; then return 1; fi
    return 0
}

@test "issue-mrs links closing-keyword PRs whatever their base; mention-only PRs do not link (#704)" {
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-links.json"
    _issue_mrs acme/testproj 6
    [ "$status" -eq 0 ]
    [ "$output" = $'issue\t6\tmerged\nmr\t6\tacme/testproj#21\tmerged\t2026-06-10T04:11:31Z\t2026-06-10T04:27:27Z\nmr\t6\tacme/testproj#22\tclosed\t2026-06-11T09:00:00Z\t-' ]
    [[ "$output" != *"#99"* ]]
    [ "$(_gql_calls)" -eq 1 ]
}

@test "issue-mrs aggregation rows on recorded shapes (#704)" {
    local issues
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-aggregate.json"
    _issue_mrs acme/testproj 1 2 3 4 5
    [ "$status" -eq 0 ]
    issues="$(grep '^issue' <<<"$output")"
    [ "$issues" = $'issue\t1\topen\nissue\t2\tdraft\nissue\t3\tmerged\nissue\t4\tnone\nissue\t5\tnone' ]
    grep -qxF $'mr\t1\tacme/testproj#32\tdraft\t2026-07-01T00:00:02Z\t-' <<<"$output"
    grep -qxF $'mr\t5\tacme/testproj#61\tclosed\t2026-07-01T00:00:01Z\t-' <<<"$output"
}

@test "a fork-repo PR \"Closes #5\" links the fork's 5, not upstream 5 (#704)" {
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-fork.json"
    _gql_serve 2 "$GQL_FIX/issue-mrs-fork.json"
    _issue_mrs me/testproj-fork 5
    [ "$status" -eq 0 ]
    [ "$output" = $'issue\t5\topen\nmr\t5\tme/testproj-fork#3\topen\t2026-08-01T12:00:00Z\t-' ]
    _issue_mrs acme/testproj 5
    [ "$status" -eq 0 ]
    [ "$output" = $'issue\t5\tnone' ]
}

@test "issue-mrs passes repo and ids as variables, never in the query text (#704)" {
    local q
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-fork.json"
    _issue_mrs acme/testproj 12
    [ "$status" -eq 0 ]
    grep -qF '[-F] [n0=12]' "$GH_STUB_ARGS_LOG"
    grep -qF '[-f] [owner=acme]' "$GH_STUB_ARGS_LOG"
    grep -qF '[-f] [name=testproj]' "$GH_STUB_ARGS_LOG"
    q="$(sed -n 's/.*\[query=\(.*\)\] \[-f\] \[owner=.*/\1/p' "$GH_STUB_ARGS_LOG")"
    [ -n "$q" ]
    _query_shape_ok "$q"
    # planted controls: a literal id or owner reddens the shape check
    run _query_shape_ok 'query{repository(owner:$owner,name:$name){i0: issue(number:12){id}}}'
    [ "$status" -ne 0 ]
    run _query_shape_ok 'query{repository(owner:"acme",name:$name){i0: issue(number:$n0){id}}}'
    [ "$status" -ne 0 ]
}

@test "issue-mrs: HTTP 401 from gh exits 3 (auth) (#704)" {
    _gql_stub
    printf '{"message":"Bad credentials","documentation_url":"https://docs.github.com/graphql"}\n' > "$DEVAGENT_TMP/401.json"
    _gql_serve 1 "$DEVAGENT_TMP/401.json" 1 "gh: Bad credentials (HTTP 401)"
    _issue_mrs acme/testproj 6
    [ "$status" -eq 3 ]
}

@test "2B+1 ids take 3 calls; a truncated timeline adds 1 page call (#704)" {
    local B i ids=() line2 n
    B="$(sed -n 's/^GH_ISSUE_MRS_BATCH=\([0-9][0-9]*\)$/\1/p' "$DEVAGENT_ROOT/scripts/code/github.sh")"
    [ "$B" -eq 50 ]   # guard: a silent change to the constant reddens
    for ((i = 1; i <= 2 * B + 1; i++)); do ids+=("$i"); done
    _gql_stub
    _gql_batch "$B" > "$GH_STUB_GRAPHQL_DIR/1.json"
    _gql_truncate "$GH_STUB_GRAPHQL_DIR/1.json"
    _gql_page C2 false > "$GH_STUB_GRAPHQL_DIR/2.json"
    _gql_batch "$B" > "$GH_STUB_GRAPHQL_DIR/3.json"
    _gql_batch 1 > "$GH_STUB_GRAPHQL_DIR/4.json"
    _issue_mrs acme/testproj "${ids[@]}"
    [ "$status" -eq 0 ]
    [ "$(_gql_calls)" -eq 4 ]
    [ "$(wc -l < "$GH_STUB_ARGS_LOG")" -eq 4 ]
    line2="$(sed -n 2p "$GH_STUB_ARGS_LOG")"
    [[ "$line2" == *'[-f] [after=C1]'* ]]
    [[ "$line2" == *'[-F] [n=1]'* ]]
    sed -n 3p "$GH_STUB_ARGS_LOG" | grep -qF '[-F] [n0=51]'
    sed -n 4p "$GH_STUB_ARGS_LOG" | grep -qF '[-F] [n0=101]'
    n="$(grep -c '^issue' <<<"$output")"
    [ "$n" -eq $((2 * B + 1)) ]
    [ "$(head -n 1 <<<"$output")" = $'issue\t1\topen' ]
}

@test "a repeated cursor exits 5 (#704)" {
    _gql_stub
    _gql_batch 1 > "$GH_STUB_GRAPHQL_DIR/1.json"
    _gql_truncate "$GH_STUB_GRAPHQL_DIR/1.json"
    _gql_page C1 true 3 > "$GH_STUB_GRAPHQL_DIR/2.json"
    _issue_mrs acme/testproj 1
    [ "$status" -eq 5 ]
    [ "$(_gql_calls)" -eq 2 ]
}

@test "per-issue NOT_FOUND is missing; other GraphQL errors exit 1 (#704)" {
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-notfound.json" 1 "gh: Could not resolve to an Issue with the number of 9."
    _issue_mrs acme/testproj 6 9
    [ "$status" -eq 0 ]
    [ "$output" = $'issue\t6\topen\nmr\t6\tacme/testproj#21\topen\t2026-06-10T04:11:31Z\t-\nissue\t9\tmissing' ]
    rm -f "$GH_STUB_GRAPHQL_DIR"/*
    _gql_serve 1 "$GQL_FIX/issue-mrs-ratelimited.json" 1 "gh: API rate limit exceeded for user ID 1."
    _issue_mrs acme/testproj 6 9
    [ "$status" -eq 1 ]
}

@test "an unrecognised PR state exits 5 (#704)" {
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-badstate.json"
    _issue_mrs acme/testproj 7
    [ "$status" -eq 5 ]
    [[ "$output" != *$'issue\t'* ]]
}

@test "issue-mrs emits created/merged per MR in UTC seconds (#704)" {
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-timestamps.json"
    _issue_mrs acme/testproj 8
    [ "$status" -eq 0 ]
    grep -qxF $'mr\t8\tacme/testproj#80\tmerged\t2026-10-07T03:24:16Z\t2026-10-07T05:00:59Z' <<<"$output"
}

@test "issue-mrs output passes mr-link.py check (#704)" {
    _gql_stub
    _gql_serve 1 "$GQL_FIX/issue-mrs-aggregate.json"
    _issue_mrs acme/testproj 1 2 3 4 5
    [ "$status" -eq 0 ]
    run python3 "$DEVAGENT_ROOT/scripts/lib/mr-link.py" check 1 2 3 4 5 <<<"$output"
    [ "$status" -eq 0 ]
    [ "$output" = 5 ]
}

@test "issue-mrs rejects a non-numeric id with exit 1 and no call; no ids make no call (#704)" {
    _gql_stub
    _issue_mrs acme/testproj 6 x7
    [ "$status" -eq 1 ]
    _issue_mrs acme/testproj
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    _issue_mrs
    [ "$status" -eq 1 ]
    [ "$(_gql_calls)" -eq 0 ]
}
