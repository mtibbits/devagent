#!/usr/bin/env bats
# Unit tests for scripts/lib/upstream.sh — behind-upstream detection (#26).
# Real local git repos, no network.
load 'helpers/common'

setup() {
    devagent_test_setup
    REPO="$DEVAGENT_TMP/up"; mkdir -p "$REPO"
    ( cd "$REPO" && git -c init.defaultBranch=main init -q \
      && git config user.email t@e && git config user.name T \
      && echo base > f && git add f && git commit -q -m base )
    . "$DEVAGENT_ROOT/scripts/lib/upstream.sh"
}
teardown() { devagent_test_teardown; }

@test "upstream_behind_count: 0 when base == upstream" {
    ( cd "$REPO" && git branch up )
    run upstream_behind_count "$REPO" main up
    [ "$status" -eq 0 ]; [ "$output" = "0" ]
}

@test "upstream_behind_count: N when base is behind" {
    ( cd "$REPO" && git branch base && echo a >> f && git commit -qam a \
      && echo b >> f && git commit -qam b && git branch up )
    run upstream_behind_count "$REPO" base up
    [ "$output" = "2" ]
}

@test "upstream_behind_count: empty when a ref is missing" {
    run upstream_behind_count "$REPO" main no-such-ref
    [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "is_fast_forward: true when from is an ancestor of to" {
    ( cd "$REPO" && git branch from && echo a >> f && git commit -qam a && git branch to )
    run is_fast_forward "$REPO" from to
    [ "$status" -eq 0 ]   # from (C0) is an ancestor of to (C1) → FF possible
}

@test "is_fast_forward: false when from has diverged from to" {
    ( cd "$REPO" && git checkout -q -b from && echo F > g && git add g && git commit -qam from \
      && git checkout -q -b to main && echo T > h && git add h && git commit -qam to )
    run is_fast_forward "$REPO" from to
    [ "$status" -ne 0 ]   # divergent → not a fast-forward
}

@test "is_fast_forward: false (fail safe) when a ref is missing" {
    run is_fast_forward "$REPO" main no-such-ref
    [ "$status" -ne 0 ]
}

@test "branch_conflicts_upstream: false when branch merges cleanly" {
    ( cd "$REPO" && git checkout -q -b feat && echo x > g && git add g && git commit -qam g \
      && git checkout -q main && echo y > h && git add h && git commit -qam h )
    run branch_conflicts_upstream "$REPO" feat main
    [ "$status" -ne 0 ]   # non-zero = no conflict
}

@test "branch_conflicts_upstream: true when both edit the same line" {
    ( cd "$REPO" && git checkout -q -b feat && echo FEAT > f && git commit -qam f \
      && git checkout -q main && echo MAIN > f && git commit -qam m )
    run branch_conflicts_upstream "$REPO" feat main
    [ "$status" -eq 0 ]   # zero = conflict detected
}

@test "upstream_fetch: silent no-op (exit 0, no warning) when remote not configured" {
    run upstream_fetch "$REPO" no-such-remote
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "branch_conflicts_upstream: fail-safe (no conflict) when merge-tree is unsupported" {
    # Simulate git < 2.38: merge-tree exits 129 (unknown --write-tree flag). The
    # helper must NOT report a (false) conflict — a real same-line conflict here
    # would hard-stop ship if mis-detected.
    local fakegit="$DEVAGENT_TMP/fakegit"
    cat > "$fakegit" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" merge-tree "*) exit 129 ;;
  *) exec git "\$@" ;;
esac
EOF
    chmod +x "$fakegit"
    ( cd "$REPO" && git checkout -q -b feat && echo FEAT > f && git commit -qam f \
      && git checkout -q main && echo MAIN > f && git commit -qam m )
    DEVAGENT_GIT="$fakegit" run branch_conflicts_upstream "$REPO" feat main
    [ "$status" -ne 0 ]   # fail-safe: no conflict reported, no hard-stop
}

@test "upstream_fetch: UPSTREAM_FETCH_STATUS records skipped / ok / failed (#590)" {
    # No remote configured → skipped (the silent no-op branch).
    upstream_fetch "$REPO" origin
    [ "$UPSTREAM_FETCH_STATUS" = "skipped" ]
    # Empty remote name → skipped.
    upstream_fetch "$REPO" ""
    [ "$UPSTREAM_FETCH_STATUS" = "skipped" ]
    # A reachable local bare remote → ok.
    git init -q --bare "$DEVAGENT_TMP/bare.git"
    ( cd "$REPO" && git remote add origin "$DEVAGENT_TMP/bare.git" && git push -q origin main )
    upstream_fetch "$REPO" origin
    [ "$UPSTREAM_FETCH_STATUS" = "ok" ]
    # Configured but unreachable → failed; the call still returns 0 (bats would
    # fail this test on a non-zero return, so the line below IS the rc assert).
    ( cd "$REPO" && git remote set-url origin "$DEVAGENT_TMP/does-not-exist.git" )
    upstream_fetch "$REPO" origin 2>/dev/null
    [ "$UPSTREAM_FETCH_STATUS" = "failed" ]
}

@test "upstream_fetch: the fetch runs with GIT_TERMINAL_PROMPT=0 — a credential prompt fails, never hangs (#590)" {
    # A recording git shim: answers every subcommand with rc 0 and logs the
    # prompt guard it saw on the fetch call.
    printf '%s\n' '#!/usr/bin/env bash' \
      'case " $* " in *" fetch "*) echo "prompt=${GIT_TERMINAL_PROMPT:-unset}" >> "$DEVAGENT_STUB_LOG" ;; esac' \
      'exit 0' > "$DEVAGENT_STUB_BIN/git-rec"
    chmod +x "$DEVAGENT_STUB_BIN/git-rec"
    DEVAGENT_GIT="$DEVAGENT_STUB_BIN/git-rec" upstream_fetch "$REPO" origin
    [ "$UPSTREAM_FETCH_STATUS" = "ok" ]
    devagent_assert_logged "prompt=0"
}
