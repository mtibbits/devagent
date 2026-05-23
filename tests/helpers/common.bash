# tests/helpers/common.bash
# Shared bats helpers for devAgent script tests.
#
# Every test that needs a project fixture calls:
#   load 'helpers/common'
#   setup() { devagent_test_setup; }
#   teardown() { devagent_test_teardown; }

devagent_test_setup() {
    DEVAGENT_TMP="$(mktemp -d -t devagent-bats-XXXXXX)"
    export DEVAGENT_TMP
    export HOME="$DEVAGENT_TMP/home"
    mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"

    # Project paths
    export TEST_PROJECT="testproj"
    export SOURCE_DIR="$DEVAGENT_TMP/src/testproj"
    export DEVDOC_DIR="$DEVAGENT_TMP/devdoc/testproj"
    mkdir -p "$SOURCE_DIR" "$DEVDOC_DIR/Issue-1/analysis"
    ( cd "$SOURCE_DIR" \
      && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com \
      && git config user.name Tester \
      && touch README.md \
      && git add README.md \
      && git commit -q -m "init" )

    # Default config — tests override individual keys as needed.
    cat > "$HOME/.claude/devagent/config.toml" <<EOF
[defaults]
checklist_template = "standard"
ship_as_draft      = false

[project.$TEST_PROJECT]
source_dir       = "$SOURCE_DIR"
source_remote    = "origin"
upstream_remote  = "upstream"
devdoc_dir       = "$DEVDOC_DIR"
fork_first       = false
ship_as_draft    = false
default_baseline = "origin/main"
all_prs_branch   = "dev/all-prs"
branch_prefix_map = { bug = "fix", feature = "feat", docs = "docs", perf = "perf", chore = "chore" }

[project.$TEST_PROJECT.permissions]
push_mr            = true
merge_mr           = true
commit_devdoc      = true
transition_issue   = true
cleanup_on_merge   = false

[project.$TEST_PROJECT.issue_source]
backend     = "github"
repo        = "acme/testproj"
dir_prefix  = "Issue-"

[project.$TEST_PROJECT.code_source]
backend     = "github"
upstream    = "acme/testproj"
fork        = "me/testproj"

[project.$TEST_PROJECT.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
EOF

    cat > "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" <<EOF
active_issue   = "Issue-1"
issue_dir      = "$DEVDOC_DIR/Issue-1"
branch         = ""
baseline_sha   = ""
last_step      = 5
last_step_name = "tighten"
revision       = 1
updated_at     = "2026-05-19T14:00:00-04:00"

[parked]
EOF

    # Minimal checklist scaffolded for active issue.
    cat > "$DEVDOC_DIR/Issue-1/checklist.md" <<'EOF'
# Issue-1 — Workflow checklist

Template: standard
Created: 2026-05-19 14:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
- [x]  3. improve
- [x]  4. prune
- [x]  5. tighten
- [ ]  6. branch
- [ ]  7. implement
- [ ]  8. quality
- [ ]  9. document
- [ ] 10. commit
- [ ] 11. analyze
- [ ] 12. draftmr
- [ ] 13. review
- [ ] 14. redmr
- [ ] 15. ship
- [ ] 16. mergetoall
- [ ] 17. updatewbs
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
- 2026-05-19 14:00  pull: fixture seed
EOF

    # PATH shim dir
    export DEVAGENT_STUB_BIN="$DEVAGENT_TMP/bin"
    mkdir -p "$DEVAGENT_STUB_BIN"
    export PATH="$DEVAGENT_STUB_BIN:$PATH"

    # Argv log for stubs.
    export DEVAGENT_STUB_LOG="$DEVAGENT_TMP/stub.log"
    : > "$DEVAGENT_STUB_LOG"

    # Plugin root used by scripts under test.
    export DEVAGENT_ROOT="${BATS_TEST_DIRNAME%/tests}"
}

devagent_test_teardown() {
    if [ -n "${DEVAGENT_TMP:-}" ] && [ -d "$DEVAGENT_TMP" ]; then
        rm -rf "$DEVAGENT_TMP"
    fi
}

# Create a stub for `cmd_name` that logs argv to $DEVAGENT_STUB_LOG and
# emits the given stdout. Subsequent invocations all return the same.
devagent_stub() {
    local cmd="$1"
    local stdout="${2:-}"
    local exitcode="${3:-0}"
    cat > "$DEVAGENT_STUB_BIN/$cmd" <<STUB
#!/usr/bin/env bash
printf '%s' "$cmd" >> "$DEVAGENT_STUB_LOG"
for a in "\$@"; do printf ' %s' "\$a" >> "$DEVAGENT_STUB_LOG"; done
printf '\n' >> "$DEVAGENT_STUB_LOG"
printf '%s' "$stdout"
exit $exitcode
STUB
    chmod +x "$DEVAGENT_STUB_BIN/$cmd"
}

# Assert the stub log contains a line matching the given fixed substring.
devagent_assert_logged() {
    local needle="$1"
    if ! grep -F -q -- "$needle" "$DEVAGENT_STUB_LOG"; then
        echo "stub log did not contain: $needle" >&2
        echo "--- stub log ---" >&2
        cat "$DEVAGENT_STUB_LOG" >&2
        return 1
    fi
}
