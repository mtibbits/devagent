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

# ---- #660: upstream_branch_tip, the bounded FRESHNESS question -----------------------
# Origins are LOCAL bare repos under $DEVAGENT_TMP: no network, no DNS.
_origin660() {
    git -c init.defaultBranch=main init -q --bare "$DEVAGENT_TMP/o660.git"
    git -C "$REPO" remote add origin "$DEVAGENT_TMP/o660.git"
    git -C "$REPO" push -q origin main
}
# Move origin's <branch> (default main) one commit past its tip, inside the bare repo (no
# second clone). The new object exists only at origin. Prints the new tip.
_move660() {
    local b="${1:-main}" o="$DEVAGENT_TMP/o660.git" p new
    p="$(git -C "$o" rev-parse -q --verify "refs/heads/$b" || git -C "$o" rev-parse refs/heads/main)"
    new="$(git -C "$o" -c user.email=m@e -c user.name=M commit-tree "$p^{tree}" -p "$p" -m "origin moves $b")"
    git -C "$o" update-ref "refs/heads/$b" "$new"
    printf '%s\n' "$new"
}
_hang660() {   # a git whose network calls hang; `exec` so timeout(1) kills the sleeper itself
    printf '%s\n' '#!/usr/bin/env bash' 'case " $* " in *" fetch "*|*" ls-remote "*) exec sleep 30 ;; esac' 'exec git "$@"' \
        > "$DEVAGENT_TMP/hang-git"
    chmod +x "$DEVAGENT_TMP/hang-git"
}
_argv660() {   # a git that records its argv ELEMENT-delimited (register Issue-593), then runs
    printf '%s\n' '#!/usr/bin/env bash' 'printf "[%s]" "$@" >> "$DEVAGENT_STUB_LOG"; echo >> "$DEVAGENT_STUB_LOG"' 'exec git "$@"' \
        > "$DEVAGENT_STUB_BIN/git-argv660"
    chmod +x "$DEVAGENT_STUB_BIN/git-argv660"
}

@test "#660 upstream_branch_tip and upstream_remote_configured exist (a 127 must not satisfy the legs below)" {
    type upstream_branch_tip
    type upstream_remote_configured
}

@test "#660 upstream_branch_tip: no origin gives (no-origin) and fetches nothing" {
    _argv660
    DEVAGENT_GIT="$DEVAGENT_STUB_BIN/git-argv660" upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "(no-origin)" ]
    devagent_assert_logged "[remote][get-url][origin]"     # the recording git WAS used (non-vacuous)
    devagent_refute_logged "[fetch]"
    devagent_refute_logged "[ls-remote]"
    [ -z "$UPSTREAM_TIP_WHY" ]                               # no remotes at all: nothing to name
}

@test "#660 upstream_branch_tip: remotes present but none named origin give (no-origin) and name them" {
    # Step-15 review (Important 1): `git clone -o upstream`, or a renamed remote, must not
    # read as the silent single-tree case.
    git -C "$REPO" remote add upstream "$DEVAGENT_TMP/elsewhere.git"
    upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "(no-origin)" ]
    [[ "$UPSTREAM_TIP_WHY" == *"no remote is named origin"* ]]
    [[ "$UPSTREAM_TIP_WHY" == *"upstream"* ]]
}

@test "#660 upstream_branch_tip: up to date and ahead both give origin's tip, not HEAD" {
    _origin660
    local tip; tip="$(git -C "$REPO" rev-parse HEAD)"
    upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "$tip" ]
    ( cd "$REPO" && echo a >> f && git commit -qam ahead )
    [ "$(git -C "$REPO" rev-parse HEAD)" != "$tip" ]       # discriminating: HEAD moved past origin
    upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "$tip" ]
}

@test "#660 upstream_branch_tip: a branch origin lacks gives (unpushed)" {
    _origin660
    git -C "$REPO" checkout -q -b feat/x
    upstream_branch_tip "$REPO" feat/x 5
    [ "$UPSTREAM_TIP" = "(unpushed)" ]
}

@test "#660 upstream_branch_tip: a tracking ref for a branch deleted at origin gives (unpushed), not its stale sha" {
    _origin660
    git -C "$REPO" update-ref refs/remotes/origin/gone HEAD             # a tracking ref for a branch origin lacks
    upstream_branch_tip "$REPO" gone 5
    [ "$UPSTREAM_TIP" = "(unpushed)" ]
}

@test "#660 upstream_branch_tip: a narrowed fetch refspec cannot leave a stale tip, and the config is untouched" {
    _origin660
    git -C "$REPO" push -q origin main:feat
    git -C "$REPO" fetch -q origin                                   # refs/remotes/origin/feat now exists
    git -C "$REPO" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
    local tip; tip="$(_move660 feat)"
    upstream_branch_tip "$REPO" feat 5
    [ "$UPSTREAM_TIP" = "$tip" ]
    # HEAD (main) lacks the tip, so the one branch was fetched: the printed remedy's
    # origin/feat is current, where the configured narrowed refspec leaves the OLD sha.
    [ "$(git -C "$REPO" rev-parse refs/remotes/origin/feat)" = "$tip" ]
    [ "$(git -C "$REPO" config --get-all remote.origin.fetch)" = '+refs/heads/main:refs/remotes/origin/main' ]
}

@test "#660 upstream_branch_tip: an origin that cannot be reached gives (unreachable) naming git's exit" {
    git -C "$REPO" remote add origin "$DEVAGENT_TMP/no-such.git"
    upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "(unreachable)" ]
    [[ "$UPSTREAM_TIP_WHY" == "git ls-remote exited "* ]]
}

@test "#660 upstream_branch_tip: a hung fetch is cut off at the bound and reported as timed out" {
    _origin660
    _hang660
    local t0=$SECONDS
    DEVAGENT_GIT="$DEVAGENT_TMP/hang-git" upstream_branch_tip "$REPO" main 1
    [ "$UPSTREAM_TIP" = "(unreachable)" ]
    [ "$UPSTREAM_TIP_WHY" = "timed out after 1s" ]
    [ $((SECONDS - t0)) -lt 15 ]                                     # the shim would hang 30 s
}

@test "#660 upstream_branch_tip: an origin with no timeout(1) on PATH returns 3 and never fetches unbounded" {
    _origin660
    local g rc=0
    g="$(command -v git)"
    mkdir -p "$DEVAGENT_TMP/emptybin"
    PATH="$DEVAGENT_TMP/emptybin" DEVAGENT_GIT="$g" upstream_branch_tip "$REPO" main 5 || rc=$?
    [ "$rc" -eq 3 ]
    [ -z "$UPSTREAM_TIP" ]
}

@test "#660 upstream_branch_tip: origin is asked with ONE bounded ls-remote; a fetch runs only when HEAD lacks the tip, and is narrow" {
    _origin660
    _argv660
    DEVAGENT_GIT="$DEVAGENT_STUB_BIN/git-argv660" upstream_branch_tip "$REPO" main 7
    [ "$UPSTREAM_TIP" = "$(git -C "$REPO" rev-parse HEAD)" ]
    devagent_assert_logged "[-C][$REPO][ls-remote][--exit-code][origin][refs/heads/main]"
    devagent_refute_logged "[fetch]"                                 # up to date: nothing fetched
    : > "$DEVAGENT_STUB_LOG"
    local tip; tip="$(_move660)"
    DEVAGENT_GIT="$DEVAGENT_STUB_BIN/git-argv660" upstream_branch_tip "$REPO" main 7
    [ "$UPSTREAM_TIP" = "$tip" ]
    devagent_assert_logged "[-C][$REPO][fetch][--quiet][--no-write-fetch-head][origin][+refs/heads/main:refs/remotes/origin/main]"
    devagent_refute_logged "[--prune]"
}

@test "#660 upstream_branch_tip: the fetch touches only origin/<branch> - other origin refs survive, no FETCH_HEAD" {
    # Whole-branch review (Important 2, measured): a pruned all-heads fetch deleted a
    # refs/remotes/origin/pr/* ref another refspec wrote, dropped the user's own tracking
    # ref for a branch deleted at origin, and rewrote FETCH_HEAD, which a concurrent
    # `git pull` in a shared tree reads.
    _origin660
    git -C "$REPO" update-ref refs/remotes/origin/pr/7 HEAD             # a pull-request ref
    git -C "$REPO" update-ref refs/remotes/origin/gone HEAD             # kept after its branch went at origin
    rm -f "$REPO/.git/FETCH_HEAD"
    local tip; tip="$(_move660)"                                      # HEAD lacks the tip: the fetch path runs
    upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "$tip" ]
    [ "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" = "$tip" ]   # the fetch DID run (non-vacuous)
    git -C "$REPO" rev-parse -q --verify refs/remotes/origin/pr/7          # not pruned
    git -C "$REPO" rev-parse -q --verify refs/remotes/origin/gone          # the user's prune policy decides, not run-suite
    [ ! -e "$REPO/.git/FETCH_HEAD" ]
}

@test "#660 upstream_branch_tip: a tree that already contains origin's tip writes nothing, not even its lagging tracking ref" {
    _origin660
    local old tip; old="$(git -C "$REPO" rev-parse HEAD)"
    tip="$(_move660)"
    git -C "$REPO" fetch -q origin main                              # the object is here...
    git -C "$REPO" merge -q --ff-only FETCH_HEAD                      # ...and HEAD contains it
    git -C "$REPO" update-ref refs/remotes/origin/main "$old"        # the tracking ref lags, on purpose
    rm -f "$REPO/.git/FETCH_HEAD"
    upstream_branch_tip "$REPO" main 5
    [ "$UPSTREAM_TIP" = "$tip" ]
    [ "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" = "$old" ]   # not written
    [ ! -e "$REPO/.git/FETCH_HEAD" ]
}
