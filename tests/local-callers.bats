#!/usr/bin/env bats
# tests/local-callers.bats — #1016: the local code backend's callers. The
# backend's own verbs are tests/backend-local.bats (run by backend-contract.bats);
# this file holds what the callers do with it, over the real scripts/code/local.sh:
# comments, mergemr, ship, and the trust entry check.
#
# _local_project makes the fixture project local: code_source.backend = "local"
# with no upstream or fork, default_baseline = "main", no source_remote, and a
# mergemr row. The issue backend is a logging stub (DEVAGENT_ISSUE_BACKEND_DIR).
# PATH shims for git and gh exec the real tool, except that a git push or fetch,
# or any gh call, writes a line to $REMOTE_MARKER and exits 97.
bats_require_minimum_version 1.5.0
load 'helpers/common'

setup() {
    devagent_test_setup
    export CFG="$HOME/.claude/devagent/config.toml"
    export STATE="$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    export ISSUE_DIR="$DEVDOC_DIR/Issue-1"
    export CL="$ISSUE_DIR/checklist.md"
    export LOCAL="$DEVAGENT_ROOT/scripts/code/local.sh"
    export REMOTE_MARKER="$DEVAGENT_TMP/remote-called"
    _local_project
}

teardown() { devagent_test_teardown; }

_local_project() {
    devagent_config_set "$CFG" "project.$TEST_PROJECT.code_source.backend" local
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.upstream"
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.code_source.fork"
    devagent_config_unset "$CFG" "project.$TEST_PROJECT.source_remote"
    devagent_config_set "$CFG" "project.$TEST_PROJECT.default_baseline" main

    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<'EOF'
#!/usr/bin/env bash
echo "issue/github $*" >> "$DEVAGENT_STUB_LOG"
exit 0
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"

    local real_git; real_git="$(command -v git)"
    cat > "$DEVAGENT_STUB_BIN/git" <<EOF
#!/usr/bin/env bash
# The subcommand is the first argument that is not an option or an option's value.
skip=0
for a in "\$@"; do
    if [ "\$skip" = 1 ]; then skip=0; continue; fi
    case "\$a" in
        -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
        -*) ;;
        push|fetch) echo "git \$*" >> "$REMOTE_MARKER"; exit 97 ;;
        *) break ;;
    esac
done
exec "$real_git" "\$@"
EOF
    cat > "$DEVAGENT_STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$REMOTE_MARKER"
exit 97
EOF
    chmod +x "$DEVAGENT_STUB_BIN/git" "$DEVAGENT_STUB_BIN/gh"

    cat > "$CL" <<'EOF'
# Issue-1 — Workflow checklist

Template: standard
Created: 2026-05-19 14:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [x]  5. improve
- [x]  6. prune
- [x]  7. tighten
- [x]  8. branch
- [x]  9. implement
- [x] 10. quality
- [x] 11. document
- [x] 12. commit
- [x] 13. analyze
- [x] 14. draftmr
- [x] 15. review
- [x] 16. redmr
- [x] 17. preship
- [ ] 18. ship
- [-] 19. mergetoall
- [ ] 20. mergemr
- [ ] 21. updatewbs
- [ ] 22. impact
- [ ] 23. lessonslearned
- [ ] 24. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
EOF
}

# _issue_branch: an issue branch feat/1-x one commit ahead of main, checked out
# on main again (HEAD differs from the branch).
_issue_branch() {
    git -C "$SOURCE_DIR" checkout -q -b feat/1-x
    echo f1 > "$SOURCE_DIR/f1.txt"
    git -C "$SOURCE_DIR" add f1.txt
    git -C "$SOURCE_DIR" commit -q -m f1
    git -C "$SOURCE_DIR" checkout -q main
    devagent_state_set "$STATE" branch feat/1-x
    devagent_state_set "$STATE" baseline_sha "$(git -C "$SOURCE_DIR" rev-parse main)"
}

# _shipped_by_hand: a record made by local.sh create-mr, its reference as mr_url,
# and the ship row [x].
_shipped_by_hand() {
    _issue_branch
    REF="$("$LOCAL" create-mr "$SOURCE_DIR" "Issue 1" /dev/null feat/1-x main)"
    devagent_state_set "$STATE" mr_url "$REF"
    mark_step "$CL" 18 x
}

_no_remote_calls() {
    [ ! -e "$REMOTE_MARKER" ] || { echo "remote reached: $(cat "$REMOTE_MARKER")" >&2; return 1; }
}

_row() { grep -E "^- \[.\] +$1\. " "$CL" | sed -E 's/^- \[(.)\].*/\1/'; }

@test "comments (local): writes ## Comments (0) (AC 7)" {
    _shipped_by_hand
    run bash "$DEVAGENT_ROOT/scripts/comments.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ "$(cat "$ISSUE_DIR/revisions/r1/comments.md")" = "## Comments (0)" ]
    grep -qE '^- [0-9-]+ [0-9:]+  comments: fetched 0 comments$' "$CL"
    _no_remote_calls
}

@test "mergemr (local): waits with today's message, then marks [x] after a hand merge --no-ff (AC 11)" {
    _shipped_by_hand
    devagent_config_set_bool "$CFG" "project.$TEST_PROJECT.permissions.merge_mr" true
    run "$DEVAGENT_ROOT/scripts/mergemr.sh" "$TEST_PROJECT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"mergemr: waiting (8): waiting for merge (merge step supports github only)"* ]]
    [ "$(_row 20)" = "?" ]
    ! printf '%s\n' "$output" | grep -q '^CI '
    git -C "$SOURCE_DIR" merge -q --no-ff -m "merge feat/1-x" feat/1-x
    run "$DEVAGENT_ROOT/scripts/mergemr.sh" "$TEST_PROJECT" </dev/null
    [ "$status" -eq 0 ]
    [ "$(_row 20)" = "x" ]
    grep -qF "mergemr: PR $REF merged (merge commit -)" "$CL"
    ! printf '%s\n' "$output" | grep -q '^CI '
    _no_remote_calls
}
