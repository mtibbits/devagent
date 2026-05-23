#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # Pre-stage a change in the working tree.
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x \
      && echo hello > a.txt && git add a.txt )
    # Active issue marker for commit body.
    echo "feature" > "$DEVDOC_DIR/Issue-1/.devagent-type"
    echo "add a.txt" > "$DEVDOC_DIR/Issue-1/.devagent-title"
    # Pre-populate state.branch via direct edit (simulates branch.sh having run).
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
teardown() { devagent_test_teardown; }

@test "commit.sh writes commit using commit_template body with -s" {
    # Provide a minimal commit_template.md via plugin templates dir.
    mkdir -p "$DEVAGENT_ROOT/templates"
    cp "$DEVAGENT_ROOT/templates/commit_template.md" \
       "$DEVAGENT_ROOT/templates/commit_template.md.bak" 2>/dev/null || true
    printf '%s\n' '{{type}}: {{title}}' '' 'Issue: {{issue}}' \
        > "$DEVAGENT_ROOT/templates/commit_template.md"

    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    echo "$msg" | grep -qx "feat: add a.txt"
    echo "$msg" | grep -q "Issue: Issue-1"
    echo "$msg" | grep -q "^Signed-off-by:"
    grep -qE '^- \[x\] +10\. commit' "$DEVDOC_DIR/Issue-1/checklist.md"

    # Restore the original template so other tests don't see our edit.
    [ -f "$DEVAGENT_ROOT/templates/commit_template.md.bak" ] \
        && mv "$DEVAGENT_ROOT/templates/commit_template.md.bak" \
              "$DEVAGENT_ROOT/templates/commit_template.md"
}

@test "commit.sh strips (1M context) substring from message" {
    mkdir -p "$DEVAGENT_ROOT/templates"
    cp "$DEVAGENT_ROOT/templates/commit_template.md" \
       "$DEVAGENT_ROOT/templates/commit_template.md.bak" 2>/dev/null || true
    printf '%s\n' '{{type}}: {{title}} (1M context)' '' 'body (1M context) trailing' \
        > "$DEVAGENT_ROOT/templates/commit_template.md"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    ! echo "$msg" | grep -q "1M context"

    [ -f "$DEVAGENT_ROOT/templates/commit_template.md.bak" ] \
        && mv "$DEVAGENT_ROOT/templates/commit_template.md.bak" \
              "$DEVAGENT_ROOT/templates/commit_template.md"
}
