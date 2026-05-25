#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" \
      && git checkout -q -b dev/all-prs \
      && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m "feat: x" )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
teardown() { devagent_test_teardown; }

@test "mergetoall.sh squash-merges branch into all_prs_branch" {
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "dev/all-prs" ]
    ( cd "$SOURCE_DIR" && git log --oneline dev/all-prs ) | grep -q "feat: x"
    # Squash merges land as a single new commit, parent count == 1.
    parents=$( cd "$SOURCE_DIR" && git log -1 --pretty=%P dev/all-prs | wc -w )
    [ "$parents" -eq 1 ]
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh halts when merge_to_all_prs=false and non-interactive" {
    sed -i "s|^merge_to_all_prs *=.*|merge_to_all_prs = false|" "$HOME/.claude/devagent/config.toml"
    # Force closed stdin so confirm() sees non-tty regardless of how bats
    # itself was invoked. Without </dev/null this hangs when bats is run
    # from an interactive terminal (read -r -p blocks waiting for input).
    run bash -c "'$DEVAGENT_ROOT/scripts/mergetoall.sh' '$TEST_PROJECT' Issue-1 </dev/null"
    [ "$status" -ne 0 ]
    grep -qE '^- \[ \] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh backward-compat: legacy merge_mr=true still grants permission" {
    # Remove the new name, add the old one.
    sed -i "/^merge_to_all_prs *=/d" "$HOME/.claude/devagent/config.toml"
    sed -i "/^push_mr *=/a merge_mr = true" "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/mergetoall.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    grep -qE '^- \[x\] +16\. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}
