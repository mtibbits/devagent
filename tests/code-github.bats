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

# #84: gh stub that emulates `--jq` by piping $GH_STUB_JSON through real jq.
# jq 1.7 is a valid proxy for gh's built-in gojq here: output byte-identical
# for this filter, validated against real gh 2.45.0 (see Issue-84 analysis/).
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
    [ "$status" -eq 1 ]
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
