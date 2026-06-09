#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    . "$DEVAGENT_ROOT/scripts/lib/paths.sh"
    . "$DEVAGENT_ROOT/scripts/lib/io.sh"
    . "$DEVAGENT_ROOT/scripts/lib/stacked.sh"
    # A real repo: main → feat/parent → feat/child (stacked); feat/solo off main.
    REPO="$DEVAGENT_TMP/repo"
    git -c init.defaultBranch=main init -q "$REPO"
    ( cd "$REPO"
      git config user.email t@e.com && git config user.name T
      echo base > base.txt && git add . && git commit -q -m base
      git checkout -q -b feat/parent && echo p > p.txt && git add . && git commit -q -m parent
      git checkout -q -b feat/child && echo c > c.txt && git add . && git commit -q -m child
      git checkout -q -b feat/solo main && echo s > s.txt && git add . && git commit -q -m solo )
    PARENT_TIP="$( git -C "$REPO" rev-parse feat/parent )"
    MAIN_TIP="$( git -C "$REPO" rev-parse main )"
}
teardown() { devagent_test_teardown; }

@test "stacked_parent_branch returns the parent branch for a stacked child" {
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main
    [ "$status" -eq 0 ]
    [ "$output" = "feat/parent" ]
}

@test "stacked_parent_branch returns empty for a non-stacked child (baseline = default base tip)" {
    run stacked_parent_branch "$REPO" "$MAIN_TIP" main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stacked_parent_branch returns empty when the parent advanced past baseline_sha" {
    ( cd "$REPO" && git checkout -q feat/parent && echo p2 > p2.txt && git add . && git commit -q -m parent2 )
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stacked_parent_branch returns empty when baseline_sha is empty" {
    run stacked_parent_branch "$REPO" "" main
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "stacked_parent_branch resolves the parent from the remote when the local branch is gone (#41)" {
    ( cd "$REPO"
      git init -q --bare "$DEVAGENT_TMP/remote.git"
      git remote add origin "$DEVAGENT_TMP/remote.git"
      git push -q origin feat/parent
      git checkout -q feat/child
      git branch -q -D feat/parent )            # local parent gone; origin/feat/parent remains
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main origin
    [ "$status" -eq 0 ]
    [ "$output" = "feat/parent" ]               # prefix stripped, not "origin/feat/parent"
}

@test "stacked_parent_branch prefers the local branch over the remote (#41)" {
    ( cd "$REPO"
      git init -q --bare "$DEVAGENT_TMP/remote.git"
      git remote add origin "$DEVAGENT_TMP/remote.git"
      git push -q origin feat/parent )          # both local feat/parent and origin/feat/parent exist
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main origin
    [ "$status" -eq 0 ]
    [ "$output" = "feat/parent" ]
}

@test "stacked_parent_branch without a remote arg keeps local-only behavior (#41 backward compat)" {
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main
    [ "$status" -eq 0 ]
    [ "$output" = "feat/parent" ]
}

@test "stacked_parent_branch (#48) resolves an advanced parent via merge-base when no tip matches baseline" {
    # Parent moves forward after the child was cut: no branch tips at baseline,
    # but merge-base(child, parent) still equals baseline. Requires the child arg.
    ( cd "$REPO" && git checkout -q feat/parent && echo p2 > p2.txt && git add . && git commit -q -m parent2 )
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main "" feat/child
    [ "$status" -eq 0 ]
    [ "$output" = "feat/parent" ]
}

@test "stacked_parent_branch (#48) picks the ancestor parent over a divergent sibling sharing the baseline" {
    # Rule under test (AC2): among several branches that resolve to baseline, the
    # actual parent is the unique ANCESTOR of the child. feat/sibling forks from
    # the same baseline (merge-base == baseline) so it is a candidate, but it is
    # NOT an ancestor of the child; feat/parent (tip == baseline) is. No-regression
    # guard for the new merge-base predicate — see imPlan Task 3 framing note.
    ( cd "$REPO" && git checkout -q -b feat/sibling feat/parent && echo q > q.txt && git add . && git commit -q -m sibling )
    run stacked_parent_branch "$REPO" "$PARENT_TIP" main "" feat/child
    [ "$status" -eq 0 ]
    [ "$output" = "feat/parent" ]
}

@test "stacked_parent_branch (#48 B1) does not mis-base a non-stacked child onto a sibling when local default base lags the remote" {
    # Non-stacked: child and sibling both fork from origin/main's tip (= baseline),
    # while local main lags behind it. The remote-aware non-stacked guard must fire
    # (baseline == tip(origin/main)) and return empty — NOT resolve the sibling via
    # merge-base. This is the production hazard once ship.sh passes the child.
    ( cd "$REPO"
      git init -q --bare "$DEVAGENT_TMP/remote.git"
      git remote add origin "$DEVAGENT_TMP/remote.git"
      git checkout -q -b adv main && echo b1 > b1.txt && git add . && git commit -q -m b1
      git push -q origin adv:main          # origin/main advances to B1
      git fetch -q origin                   # refs/remotes/origin/main = B1; local main still lags
      git checkout -q main                   # off adv so it can be deleted; local main stays at B0 (lagging)
      git branch -q -D adv                   # ensure NO local branch tips at B1
      git checkout -q -b nstk/child origin/main && echo c > nc.txt && git add . && git commit -q -m nc
      git checkout -q -b nstk/sib   origin/main && echo s > ns.txt && git add . && git commit -q -m ns )
    B1="$( git -C "$REPO" rev-parse origin/main )"
    run stacked_parent_branch "$REPO" "$B1" main origin nstk/child
    [ "$status" -eq 0 ]
    [ -z "$output" ]                          # must NOT return nstk/sib (or anything)
}

@test "stacked_parent_branch (#48) advanced parent vs divergent sibling: no ancestor → refname order + audible warning" {
    # Documented residual ambiguity (design-note §residual): when the parent has
    # ADVANCED and a sibling shares the baseline fork-point, NEITHER is an ancestor
    # of the child, so ancestor-of-child cannot discriminate. The result is then
    # deterministic by refname order (here feat/aaa-sibling sorts before feat/parent,
    # so the SIBLING wins — the pick is NOT parent-detection) and MUST warn so a
    # mis-base is audible rather than silent.
    ( cd "$REPO"
      git checkout -q feat/parent && echo p2 > p2.txt && git add . && git commit -q -m parent2          # parent advances past baseline
      git checkout -q -b feat/aaa-sibling "$PARENT_TIP" && echo s > sib.txt && git add . && git commit -q -m sib )  # sibling forks at baseline
    local errf="$DEVAGENT_TMP/spb-ambig.err"
    out="$(stacked_parent_branch "$REPO" "$PARENT_TIP" main "" feat/child 2>"$errf")"
    [ "$out" = "feat/aaa-sibling" ]              # refname-first among {feat/aaa-sibling, feat/parent}; NOT ancestor-resolved
    grep -q "refname order" "$errf"              # ambiguity is warned, never silent
}
