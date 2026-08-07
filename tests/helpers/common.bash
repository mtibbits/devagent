# tests/helpers/common.bash
# Shared bats helpers for devAgent script tests.
#
# Every test that needs a project fixture calls:
#   load 'helpers/common'
#   setup() { devagent_test_setup; }
#   teardown() { devagent_test_teardown; }

# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hermetic-env.bash"

devagent_test_setup() {
    # #240: a developer shell may pin project/issue (settings.local.json);
    # fixtures must be hermetic against both.
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
merge_to_all_prs           = true
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
- [x]  2. draft
- [x]  4. scope
- [x]  5. improve
- [x]  6. prune
- [x]  7. tighten
- [ ]  8. branch
- [ ]  9. implement
- [ ] 10. quality
- [ ] 11. document
- [ ] 12. commit
- [ ] 13. analyze
- [ ] 14. draftmr
- [ ] 15. review
- [ ] 16. redmr
- [ ] 18. ship
- [ ] 19. mergetoall
- [ ] 20. updatewbs
- [ ] 21. impact
- [ ] 22. lessonslearned
- [ ] 23. cleanup

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

# #572: second-project fixture — the scope-guard MISMATCH shape (work in
# $TEST_PROJECT's tree, global pointer on projB). Creates SRC_B / DOC_B /
# ISSUE_B (exported), appends a minimal [project.projB] to the config —
# callers append extra keys/tables AFTERWARDS (the table stays open at EOF) —
# writes state/projB.toml naming Issue-9 (callers needing richer state
# overwrite the file), points _active.toml at projB, and unsets the env pins.
# Pass 1 to also make SRC_B a one-commit git repo (only tests that run git
# against projB need it — the guard itself only stats the directory).
devagent_fixture_projB() {
    local git_init="${1:-0}"
    SRC_B="$DEVAGENT_TMP/src/projB"
    DOC_B="$DEVAGENT_TMP/devdoc/projB"
    ISSUE_B="$DOC_B/Issue-9"
    export SRC_B DOC_B ISSUE_B
    mkdir -p "$SRC_B" "$ISSUE_B"
    if [ "$git_init" = "1" ]; then
        ( cd "$SRC_B" && git -c init.defaultBranch=main init -q \
          && git config user.email b@example.com && git config user.name B \
          && echo one > f.txt && git add f.txt && git commit -q -m c1 )
    fi
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.projB]
source_dir = "$SRC_B"
devdoc_dir = "$DOC_B"
EOF
    printf 'active_issue = "Issue-9"\nissue_dir = "%s"\n' "$ISSUE_B" \
      > "$HOME/.claude/devagent/state/projB.toml"
    printf 'active_project = "projB"\n' \
      > "$HOME/.claude/devagent/state/_active.toml"
    unset DEVAGENT_ACTIVE_PROJECT DEVAGENT_ACTIVE_ISSUE
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

# Negative counterpart of devagent_assert_logged (#44): fixed-string; fails if
# the needle IS present. Plain grep (no `run`), so it does not clobber bats'
# $output/$status.
devagent_refute_logged() {
    local needle="$1"
    if grep -F -q -- "$needle" "$DEVAGENT_STUB_LOG"; then
        echo "stub log unexpectedly contained: $needle" >&2
        echo "--- stub log ---" >&2
        cat "$DEVAGENT_STUB_LOG" >&2
        return 1
    fi
}

# --- #335: shared .toml mutation helpers -------------------------------------
# All delegate to the production _toml.py shim (parses via tomllib; unlike
# `sed -i`, it CANNOT silently no-op on a regex miss). Resolve _toml.py from
# this file's own location so the helpers work under any fixture setup (not
# just devagent_test_setup, which is the only thing that sets $DEVAGENT_ROOT).
_DEVAGENT_TOML_PY="$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/_toml.py"

_devagent_toml() {
    # <verb> <toml-file> <key> [value]
    python3 "$_DEVAGENT_TOML_PY" "$@"
}

# State toml (flat keys). String scalar, quoted for _toml.py's `set`.
devagent_state_set()  { _devagent_toml set "$1" "$2" "\"$3\""; }

# Config toml. Dotted keys address nested tables, e.g.
# project.<proj>.permissions.push_mr.
devagent_config_set()      { _devagent_toml set      "$1" "$2" "\"$3\""; }
devagent_config_set_bool() { _devagent_toml set-bool "$1" "$2" "$3"; }
devagent_config_unset()    { _devagent_toml unset    "$1" "$2"; }

# --- #335: checklist step helpers --------------------------------------------
# checklist.md is not a toml, so sed is allowed internally (outside the AC
# canary); the grep guard supplies the fail-loud property a bare `sed -i` lacks.
#
# #420: mark/assert/delete_step must be REVISION-SCOPED exactly like production.
# revise.sh appends a `## Revision N` block reusing step numbers 2,4..23 + closeout
# 16-21; unscoped helpers would flip/read EVERY block (mask a revision bug) or
# pass off revision-1's stale glyph — the masking class #335 killed for the
# production checklist_mark_by_name. Rather than re-implement (and re-drift) the
# scoping, reuse the production resolver `_checklist_scope_start` (membership-
# based: active-block start iff the step number is in it, else 0 = file-wide, so
# step 0 stays file-wide). Sourced lazily so `load 'helpers/common'` stays cheap.
_ensure_checklist_lib() {
    declare -F _checklist_scope_start >/dev/null 2>&1 && return 0
    local _lib; _lib="$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib"
    . "$_lib/io.sh"
    . "$_lib/checklist.sh"
}

mark_step() {
    # <checklist-md> <step-num> <glyph>
    local file="$1" step="$2" glyph="$3" start
    if ! grep -qE "^- \[.\] +${step}\. " "$file"; then
        echo "mark_step: no step ${step} in $file" >&2; return 1
    fi
    _ensure_checklist_lib
    start="$(_checklist_scope_start "$file" "$step")"
    if [ "$start" -gt 0 ]; then
        sed -i -E "$((start+1)),\$ {/^- \[.\] +${step}\. / s/\[.\]/[${glyph}]/}" "$file"
    else
        sed -i -E "/^- \[.\] +${step}\. / s/\[.\]/[${glyph}]/" "$file"
    fi
}

assert_step() {
    # <checklist-md> <step-num> <glyph> [name]
    # Glyph wrapped in a bracket CLASS so regex-special glyphs match
    # literally: [?] [.] [!] [ ] [-] [~] are all safe inside []. (A bare
    # \[${glyph}\] would make glyph='?' optional-quantify the '[' and make
    # glyph='.' match any glyph.)
    local file="$1" step="$2" glyph="$3" name="${4:-}" start scoped
    _ensure_checklist_lib
    start="$(_checklist_scope_start "$file" "$step")"
    local pat="^- \[[${glyph}]\] +${step}\. ${name}"
    if [ "$start" -gt 0 ]; then
        scoped="$(awk -v s="$start" 'NR>s' "$file")"
    else
        scoped="$(cat "$file")"
    fi
    if ! printf '%s\n' "$scoped" | grep -qE "$pat"; then
        echo "assert_step: step ${step} not [${glyph}] ${name} in the active revision of $file" >&2
        echo "--- checklist ---" >&2; cat "$file" >&2
        return 1
    fi
}

delete_step() {
    # <checklist-md> <step-num>
    local file="$1" step="$2" start
    if ! grep -qE "^- \[.\] +${step}\. " "$file"; then
        echo "delete_step: no step ${step} in $file" >&2; return 1
    fi
    _ensure_checklist_lib
    start="$(_checklist_scope_start "$file" "$step")"
    if [ "$start" -gt 0 ]; then
        sed -i -E "$((start+1)),\$ {/^- \[.\] +${step}\. /d}" "$file"
    else
        sed -i -E "/^- \[.\] +${step}\. /d" "$file"
    fi
}
