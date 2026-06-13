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
printf '%s' "\$GH_STUB_JSON" | jq -r "\$filter"
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
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42 --json comments --jq"
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
# args: api repos/<repo>/branches/<branch> — 0 iff the path ends in /present;
# a missing branch is a real 404 (gh writes "Not Found (HTTP 404)" to stderr).
[[ "$*" == *"branches/present" ]] && exit 0
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo present
    [ "$status" -eq 0 ]
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo absent
    [ "$status" -eq 1 ]
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
}

@test "code/github.sh branch-exists exits 2 on a 403 rate-limit, not 1 (#85)" {
    cat > "$DEVAGENT_TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: API rate limit exceeded (HTTP 403)" >&2
exit 1
EOF
    chmod +x "$DEVAGENT_TMP/gh"
    DEVAGENT_GH="$DEVAGENT_TMP/gh" run bash "$DEVAGENT_ROOT/scripts/code/github.sh" branch-exists me/repo whatever
    [ "$status" -eq 2 ]
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
