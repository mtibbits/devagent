#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "branch.sh creates feat/<num>-<slug> for a feature issue" {
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "make widgets faster" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    export NOTE=""
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    ( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD ) | grep -qx "feat/1-make-widgets-faster"
    grep -q '^branch *= *"feat/1-make-widgets-faster"' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -q '\[x\]  6. branch' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q 'branch: created feat/1-make-widgets-faster' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "branch.sh creates a git worktree when use_worktree=true" {
    # Insert use_worktree + worktree_root into the [project.testproj] block.
    python3 - "$HOME/.claude/devagent/config.toml" "$TEST_PROJECT" "$DEVAGENT_TMP/wtroot" <<'PY'
import sys, re
path, proj, root = sys.argv[1:]
text = open(path).read()
insert = f'use_worktree   = true\nworktree_root  = "{root}"\n'
text = re.sub(rf'(\[project\.{re.escape(proj)}\]\n)', r'\1' + insert, text, count=1)
open(path, 'w').write(text)
PY

    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "wt test" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    run "$DEVAGENT_ROOT/scripts/branch.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -d "$DEVAGENT_TMP/wtroot/issue-1/.git" ] || [ -f "$DEVAGENT_TMP/wtroot/issue-1/.git" ]
    grep -q "worktree_path *= *\"$DEVAGENT_TMP/wtroot/issue-1\"" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
