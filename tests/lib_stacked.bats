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
