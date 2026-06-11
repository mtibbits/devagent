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

@test "code/github.sh mr-comments prints markdown from gh" {
    devagent_stub gh "## Comment from @reviewer\n\nLooks good"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42"
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

@test "code/github.sh branch-exists returns 0 when present, 1 when absent (#41)" {
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
# args: api repos/<repo>/branches/<branch> — 0 iff the path ends in /present
[[ "$*" == *"branches/present" ]] && exit 0
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo present
    [ "$status" -eq 0 ]
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo absent
    [ "$status" -eq 1 ]
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
