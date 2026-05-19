# devAgent Plan 03 — Workflow Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the script-type workflow steps from spec §6.3 (branch, commit, analyze, ship, mergetoall, cleanup, sync) plus the `code/github.sh` backend they depend on, with full permission-gate enforcement and TDD-driven bats coverage.

**Architecture:** Each verb is a stand-alone shell script under `scripts/`, sourcing the shared libraries delivered by Plan 1 (`scripts/lib/config.sh`, `scripts/lib/state.sh`, `scripts/lib/checklist.sh`, `scripts/lib/log.sh`, `scripts/lib/permission.sh`, `scripts/lib/artifact.sh`). Forge calls funnel through a `code/<backend>.sh` contract (push-branch, create-mr, mr-state, mr-comments, merge-mr) so a future GitLab/JIRA backend slots in without touching the workflow scripts. Tests stub `gh` and `git` via `PATH` shims (no live API, no real branches).

**Tech Stack:** POSIX `bash`, `gh` CLI, `git`, `bats-core`, optional `bats-assert`/`bats-mock` (vendored), `python3` (only for invoking the pre-existing `static_analysis_diff.py`).

---

## Dependencies on prior plans

- **Plan 1** must deliver:
  - `scripts/lib/config.sh` exposing `config_get <project> <dotted.key>` and `config_get_map <project> <key>` (returning shell-eval'able `key=value` pairs).
  - `scripts/lib/state.sh` exposing `state_get <project> <key>`, `state_set <project> <key> <value>`, `state_clear <project> <key>`.
  - `scripts/lib/checklist.sh` exposing `checklist_mark <issue-dir> <step-num> <glyph>` and `checklist_advance <issue-dir> <step-num>`.
  - `scripts/lib/log.sh` exposing `log_append <issue-dir> <step-name> <one-line-msg>`.
  - `scripts/lib/permission.sh` exposing `permission_gate <project> <gate-name> <plan-text>` (silent if true; prints plan + reads `y/N` from stdin if false; exits 10 on decline).
  - `scripts/lib/artifact.sh` exposing `artifact_resolve <project> <key>` (returns absolute path per §12 resolution order).
  - Templates `templates/commit_template.md` and `templates/mr_template.md` migrated per §12.
- **Plan 2** must deliver:
  - `scripts/issue/github.sh` with at minimum the `transition <repo> <num> <semantic-stage>` verb (called by `ship.sh` and `sync.sh`).
  - Active-issue selection helpers used by `where`/`next` are not needed here; this plan reads state directly.

If `issue/<backend>.sh transition` is not yet implemented by Plan 2 at execution time, the scripts in this plan still call it; the script must tolerate the verb being absent by treating it as a non-fatal warning per spec §11 ("tracker-state failures do not block real work"). This is implemented in Task 4 Step 3.

## Files created or modified

- Create: `scripts/code/github.sh` — github code backend (verbs: push-branch, create-mr, mr-state, mr-comments, merge-mr).
- Create: `scripts/branch.sh` — step 6.
- Create: `scripts/commit.sh` — step 10.
- Create: `scripts/analyze-static.sh` — wraps `static_analysis_diff.py`.
- Create: `scripts/analyze-sanitizers.sh` — runs ASan/UBSan/TSan against diff scope.
- Create: `scripts/analyze.sh` — sequences static then sanitizers for step 11.
- Create: `scripts/ship.sh` — step 15.
- Create: `scripts/mergetoall.sh` — step 16.
- Create: `scripts/cleanup.sh` — step 20.
- Create: `scripts/sync.sh` — async merge detection.
- Create: `commands/branch.md`, `commands/commit.md`, `commands/analyze.md`, `commands/ship.md`, `commands/mergetoall.md`, `commands/cleanup.md`, `commands/sync.md` — slash command markdown files.
- Create: `tests/helpers/common.bash` — bats helpers (PATH shim setup, fake project fixture, gh/git stub generators).
- Create: `tests/code-github.bats`, `tests/branch.bats`, `tests/commit.bats`, `tests/analyze-static.bats`, `tests/analyze-sanitizers.bats`, `tests/analyze.bats`, `tests/ship.bats`, `tests/mergetoall.bats`, `tests/cleanup.bats`, `tests/sync.bats`.

No files outside `scripts/`, `commands/`, `tests/`, and (per the user instruction) the plan file itself are written by this plan.

## Conventions for every script

- `#!/usr/bin/env bash`
- `set -euo pipefail`
- First line of logic: `DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"` then source the libs.
- Honor `$NOTE` env var (set by the chaining layer per spec §6.1) and pass it to `log_append`.
- Project resolved from `$1` if present, else from `state` (single configured project shortcut left to Plan 1).
- Issue dir resolved from `$2` if present, else from `state_get <project> issue_dir`.
- All `git` and `gh` invocations go through `$DEVAGENT_GIT` / `$DEVAGENT_GH` (default `git` / `gh`) so tests can stub.
- All scripts end with `checklist_advance` + `log_append` on success; on `permission_gate` decline they exit non-zero without mutating checklist (callers can retry).

## Conventions for every test

- Each `.bats` file sets up a temp `HOME`, temp project fixture (config.toml + state.toml + fake devdoc dir + fake source dir initialized as a git repo), and a temp `bin/` prepended to `PATH` containing stub `gh` / `git` (when needed) that log argv to a file and emit canned output.
- A test that verifies a permission-gate prompt sets `permissions.push_mr=false` in the fixture, feeds `n\n` on stdin, and asserts (a) the script prints the plan, (b) exits non-zero, (c) leaves checklist and log untouched.
- Tests assert on side-effect files (the argv log, state.toml after-image, checklist.md after-image, log lines) — never on terminal colour, never on timing.

---

## Task 1: bats helpers (PATH-shim fixture)

**Files:**
- Create: `tests/helpers/common.bash`

- [ ] **Step 1: Write the helper file**

```bash
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
parked         = []
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
```

- [ ] **Step 2: Verify the helper sources without error**

Create a throwaway smoke test `tests/_helpers_smoke.bats`:

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "helper sets up project fixture" {
    [ -f "$HOME/.claude/devagent/config.toml" ]
    [ -f "$DEVDOC_DIR/Issue-1/checklist.md" ]
    [ -d "$SOURCE_DIR/.git" ]
}

@test "stub helper logs argv" {
    devagent_stub mytool "hello"
    run mytool a b "c d"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
    devagent_assert_logged "mytool a b c d"
}
```

Run: `bats tests/_helpers_smoke.bats`
Expected: 2 tests pass.

- [ ] **Step 3: Delete the smoke test and commit**

```bash
rm tests/_helpers_smoke.bats
git add tests/helpers/common.bash
git commit -s -m "$(cat <<'EOF'
test: add bats helpers for workflow-script tests

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: code/github.sh — push-branch verb

**Files:**
- Create: `scripts/code/github.sh`
- Test:  `tests/code-github.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "code/github.sh push-branch invokes git push remote branch" {
    devagent_stub git ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" push-branch origin fix/1-foo
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push --set-upstream origin fix/1-foo"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/code-github.bats -f "push-branch"`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# scripts/code/github.sh — github code backend (push-branch, create-mr, mr-state,
# mr-comments, merge-mr). All gh/git calls go through $DEVAGENT_GH / $DEVAGENT_GIT
# so tests can stub.
set -euo pipefail

: "${DEVAGENT_GH:=gh}"
: "${DEVAGENT_GIT:=git}"

usage() {
    cat >&2 <<'EOF'
usage: code/github.sh <verb> [args...]
verbs:
  push-branch  <remote> <branch>
  create-mr    <repo> <title> <body-file> <head> <base> [--draft]
  mr-state     <mr-url>
  mr-comments  <mr-url>
  merge-mr     <mr-url> [--method squash|merge|rebase]
EOF
    exit 64
}

verb="${1:-}"; shift || usage
case "$verb" in
    push-branch)
        [ $# -eq 2 ] || usage
        "$DEVAGENT_GIT" push --set-upstream "$1" "$2"
        ;;
    *) usage ;;
esac
```

`chmod +x scripts/code/github.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/code-github.bats -f "push-branch"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/code/github.sh tests/code-github.bats
git commit -s -m "$(cat <<'EOF'
scripts: add code/github.sh with push-branch verb

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: code/github.sh — create-mr verb

**Files:**
- Modify: `scripts/code/github.sh`
- Modify: `tests/code-github.bats`

- [ ] **Step 1: Append failing test**

```bash
@test "code/github.sh create-mr calls gh pr create with body file" {
    devagent_stub gh "https://github.com/acme/testproj/pull/42"
    body="$DEVAGENT_TMP/body.md"
    echo "the body" > "$body"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" create-mr acme/testproj "T" "$body" feat/1 main
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/acme/testproj/pull/42" ]
    devagent_assert_logged "gh pr create --repo acme/testproj --title T --body-file $body --head feat/1 --base main"
}

@test "code/github.sh create-mr --draft adds --draft flag" {
    devagent_stub gh "https://github.com/acme/testproj/pull/43"
    body="$DEVAGENT_TMP/body.md"
    echo "the body" > "$body"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" create-mr acme/testproj "T" "$body" feat/1 main --draft
    [ "$status" -eq 0 ]
    devagent_assert_logged "--draft"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/code-github.bats -f "create-mr"`
Expected: FAIL — verb returns usage error.

- [ ] **Step 3: Add the verb**

Replace the `case` block in `scripts/code/github.sh`:

```bash
case "$verb" in
    push-branch)
        [ $# -eq 2 ] || usage
        "$DEVAGENT_GIT" push --set-upstream "$1" "$2"
        ;;
    create-mr)
        [ $# -ge 5 ] || usage
        repo="$1"; title="$2"; body="$3"; head="$4"; base="$5"; shift 5
        draft=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --draft) draft=(--draft); shift ;;
                *) usage ;;
            esac
        done
        "$DEVAGENT_GH" pr create --repo "$repo" --title "$title" \
            --body-file "$body" --head "$head" --base "$base" "${draft[@]}"
        ;;
    *) usage ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/code-github.bats`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/code/github.sh tests/code-github.bats
git commit -s -m "$(cat <<'EOF'
scripts: add create-mr verb to code/github.sh

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: code/github.sh — mr-state, mr-comments, merge-mr verbs

**Files:**
- Modify: `scripts/code/github.sh`
- Modify: `tests/code-github.bats`

- [ ] **Step 1: Append failing tests**

```bash
@test "code/github.sh mr-state prints normalized state" {
    devagent_stub gh '{"state":"MERGED","isDraft":false}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-state https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    [ "$output" = "merged" ]
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42 --json state,isDraft"
}

@test "code/github.sh mr-state returns draft when isDraft=true" {
    devagent_stub gh '{"state":"OPEN","isDraft":true}'
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-state https://github.com/acme/testproj/pull/42
    [ "$output" = "draft" ]
}

@test "code/github.sh mr-comments prints body markdown" {
    devagent_stub gh "## @rev · 2026-05-19\n\nbody"
    run "$DEVAGENT_ROOT/scripts/code/github.sh" mr-comments https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr view https://github.com/acme/testproj/pull/42 --comments"
}

@test "code/github.sh merge-mr defaults to squash" {
    devagent_stub gh ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" merge-mr https://github.com/acme/testproj/pull/42
    [ "$status" -eq 0 ]
    devagent_assert_logged "gh pr merge https://github.com/acme/testproj/pull/42 --squash"
}

@test "code/github.sh merge-mr --method rebase honors flag" {
    devagent_stub gh ""
    run "$DEVAGENT_ROOT/scripts/code/github.sh" merge-mr https://github.com/acme/testproj/pull/42 --method rebase
    devagent_assert_logged "--rebase"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/code-github.bats`
Expected: 5 new tests fail.

- [ ] **Step 3: Extend the case block**

Add these branches before `*)`:

```bash
    mr-state)
        [ $# -eq 1 ] || usage
        json="$("$DEVAGENT_GH" pr view "$1" --json state,isDraft)"
        state="$(printf '%s' "$json" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p' | tr '[:upper:]' '[:lower:]')"
        is_draft="$(printf '%s' "$json" | sed -n 's/.*"isDraft":\(true\|false\).*/\1/p')"
        if [ "$is_draft" = "true" ] && [ "$state" = "open" ]; then
            echo "draft"
        else
            echo "$state"
        fi
        ;;
    mr-comments)
        [ $# -eq 1 ] || usage
        "$DEVAGENT_GH" pr view "$1" --comments
        ;;
    merge-mr)
        [ $# -ge 1 ] || usage
        url="$1"; shift
        method=squash
        while [ $# -gt 0 ]; do
            case "$1" in
                --method) method="$2"; shift 2 ;;
                *) usage ;;
            esac
        done
        case "$method" in
            squash|merge|rebase) ;;
            *) echo "unknown method: $method" >&2; exit 64 ;;
        esac
        "$DEVAGENT_GH" pr merge "$url" "--$method"
        ;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/code-github.bats`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/code/github.sh tests/code-github.bats
git commit -s -m "$(cat <<'EOF'
scripts: add mr-state, mr-comments, merge-mr verbs to code/github.sh

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: branch.sh — happy-path branch creation

**Files:**
- Create: `scripts/branch.sh`
- Test:  `tests/branch.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() { devagent_test_setup; }
teardown() { devagent_test_teardown; }

@test "branch.sh creates feat/<num>-<slug> for a feature issue" {
    # Mark issue type=feature via $NOTE convention: first word of NOTE is type.
    # Real type comes from issue.md frontmatter (Plan 2). For this test we
    # short-circuit by writing a marker file branch.sh consults.
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/branch.bats`
Expected: FAIL — `branch.sh` does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/branch.sh — step 6. Compute prefix from branch_prefix_map, baseline
# on default_baseline, optionally create a git worktree if config requests it.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/config.sh
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
# shellcheck source=lib/state.sh
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
# shellcheck source=lib/checklist.sh
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
# shellcheck source=lib/log.sh
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_num="${issue_arg#Issue-}"
issue_num="${issue_num#Fork-}"
issue_dir="$(state_get "$project" issue_dir)"
[ -d "$issue_dir" ] || { echo "issue dir not found: $issue_dir" >&2; exit 1; }

# Resolve issue type and title. v1 reads marker files written by step 1/2
# of the workflow. (Plan 4's draft skill writes these; tests preseed them.)
type_file="$issue_dir/.devagent-type"
title_file="$issue_dir/.devagent-title"
[ -r "$type_file" ]  || { echo "missing $type_file (issue type not classified)" >&2; exit 1; }
[ -r "$title_file" ] || { echo "missing $title_file (issue title not captured)" >&2; exit 1; }
issue_type="$(tr -d '\n' < "$type_file")"
title="$(tr -d '\n' < "$title_file")"

# Slugify: lowercase, non-alnum -> '-', collapse, trim, cap at 40 chars.
slug="$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//' \
    | cut -c1-40 \
    | sed 's/-$//')"

# Prefix lookup.
eval "$(config_get_map "$project" branch_prefix_map)"
prefix_var="$issue_type"
prefix="${!prefix_var:-}"
[ -n "$prefix" ] || { echo "no prefix mapped for type '$issue_type'" >&2; exit 1; }

branch="$prefix/$issue_num-$slug"
baseline="$(config_get "$project" default_baseline)"
source_dir="$(config_get "$project" source_dir)"

cd "$source_dir"
# Fetch baseline; absorb network failure as "already up to date" for offline tests.
"$DEVAGENT_GIT" fetch --quiet "$(echo "$baseline" | cut -d/ -f1)" 2>/dev/null || true
baseline_sha="$("$DEVAGENT_GIT" rev-parse "$baseline" 2>/dev/null || "$DEVAGENT_GIT" rev-parse HEAD)"

worktree_dir=""
use_worktree="$(config_get "$project" use_worktree 2>/dev/null || echo false)"
if [ "$use_worktree" = "true" ]; then
    worktree_root="$(config_get "$project" worktree_root 2>/dev/null || echo "$source_dir-wt")"
    worktree_dir="$worktree_root/issue-$issue_num"
    "$DEVAGENT_GIT" worktree add -b "$branch" "$worktree_dir" "$baseline_sha"
else
    "$DEVAGENT_GIT" checkout -b "$branch" "$baseline_sha"
fi

state_set "$project" branch        "$branch"
state_set "$project" baseline_sha  "$baseline_sha"
state_set "$project" worktree_path "$worktree_dir"
state_set "$project" last_step      6
state_set "$project" last_step_name branch

checklist_mark "$issue_dir" 6 x
log_append "$issue_dir" branch "created $branch from $baseline ($baseline_sha)${NOTE:+ — $NOTE}"
echo "$branch"
```

`chmod +x scripts/branch.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/branch.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/branch.sh tests/branch.bats
git commit -s -m "$(cat <<'EOF'
scripts: add branch.sh (step 6 — create issue branch)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: branch.sh — worktree mode

**Files:**
- Modify: `tests/branch.bats`

- [ ] **Step 1: Append failing test**

```bash
@test "branch.sh creates a git worktree when use_worktree=true" {
    # Re-write config so use_worktree is true and a worktree_root is set.
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

# overrides for worktree test
EOF
    # Replace use_worktree key (config_get prefers later definitions per Plan 1
    # contract — if not, edit the original block instead).
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
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bats tests/branch.bats -f "worktree"`
Expected: PASS (`branch.sh` already supports worktrees from Task 5).

If the test fails because Plan 1's `config_get` does not honor a later-defined key, the inline `python3` patch replaces the original block instead. Adjust the fixture-edit code rather than the script.

- [ ] **Step 3: Commit**

```bash
git add tests/branch.bats
git commit -s -m "$(cat <<'EOF'
test: cover worktree mode for branch.sh

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: commit.sh — happy path

**Files:**
- Create: `scripts/commit.sh`
- Test:  `tests/commit.bats`

- [ ] **Step 1: Write the failing test**

```bash
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
    state_set_inline() { sed -i "s|^$1 *=.*|$1 = \"$2\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"; }
    state_set_inline branch "feat/1-x"
}
teardown() { devagent_test_teardown; }

@test "commit.sh writes commit using commit_template body with -s" {
    # Provide a minimal commit_template.md via plugin templates dir.
    mkdir -p "$DEVAGENT_ROOT/templates"
    [ -f "$DEVAGENT_ROOT/templates/commit_template.md" ] || \
        printf '%s\n' '{{type}}: {{title}}' '' 'Issue: {{issue}}' \
            > "$DEVAGENT_ROOT/templates/commit_template.md"

    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    echo "$msg" | grep -qx "feat: add a.txt"
    echo "$msg" | grep -q "Issue: Issue-1"
    echo "$msg" | grep -q "^Signed-off-by:"
    grep -q '\[x\] 10. commit' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "commit.sh strips (1M context) substring from message" {
    mkdir -p "$DEVAGENT_ROOT/templates"
    printf '%s\n' '{{type}}: {{title}} (1M context)' '' 'body (1M context) trailing' \
        > "$DEVAGENT_ROOT/templates/commit_template.md"
    run "$DEVAGENT_ROOT/scripts/commit.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    msg="$( cd "$SOURCE_DIR" && git log -1 --pretty=%B )"
    ! echo "$msg" | grep -q "1M context"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/commit.bats`
Expected: FAIL — `commit.sh` does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/commit.sh — step 10. Compose commit message from commit_template,
# substitute placeholders, strip "(1M context)" patterns, commit with -s.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/artifact.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"
[ -d "$issue_dir" ] || { echo "issue dir not found: $issue_dir" >&2; exit 1; }

type_file="$issue_dir/.devagent-type"
title_file="$issue_dir/.devagent-title"
issue_type="$(tr -d '\n' < "$type_file")"
title="$(tr -d '\n' < "$title_file")"

# Prefix lookup (re-use the same map as branch.sh so the commit subject prefix
# matches the branch prefix).
eval "$(config_get_map "$project" branch_prefix_map)"
prefix_var="$issue_type"
prefix="${!prefix_var:-$issue_type}"

template="$(artifact_resolve "$project" commit_template)"
[ -r "$template" ] || { echo "commit_template not resolvable" >&2; exit 1; }

body="$(mktemp)"
trap 'rm -f "$body"' EXIT
sed \
    -e "s|{{type}}|$prefix|g" \
    -e "s|{{title}}|$title|g" \
    -e "s|{{issue}}|$issue_arg|g" \
    -e "s|{{note}}|${NOTE:-}|g" \
    "$template" > "$body"

# Strip any "(1M context)" or " (1M context)" patterns (case-insensitive).
# Trims trailing whitespace left behind.
sed -i -E 's/[[:space:]]*\(1M context\)//gI; s/[[:space:]]+$//' "$body"

source_dir="$(config_get "$project" source_dir)"
worktree="$(state_get "$project" worktree_path 2>/dev/null || true)"
work_dir="${worktree:-$source_dir}"

cd "$work_dir"
"$DEVAGENT_GIT" commit -s -F "$body"

state_set "$project" last_step      10
state_set "$project" last_step_name commit
checklist_mark "$issue_dir" 10 x
log_append "$issue_dir" commit "committed $("$DEVAGENT_GIT" rev-parse --short HEAD)${NOTE:+ — $NOTE}"
```

`chmod +x scripts/commit.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/commit.bats`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/commit.sh tests/commit.bats
git commit -s -m "$(cat <<'EOF'
scripts: add commit.sh (step 10 — DCO sign-off, strip 1M-context)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: analyze-static.sh — wraps static_analysis_diff.py

**Files:**
- Create: `scripts/analyze-static.sh`
- Test:  `tests/analyze-static.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    sed -i "s|^branch *=.*|branch = \"fix/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"HEAD\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Override the python3 binary the script uses, by exporting an env var
    # the script reads (DEVAGENT_PYTHON). Tests use a stub that records argv.
    cat > "$DEVAGENT_STUB_BIN/fake-python" <<EOF
#!/usr/bin/env bash
printf 'python' >> "$DEVAGENT_STUB_LOG"
for a in "\$@"; do printf ' %s' "\$a" >> "$DEVAGENT_STUB_LOG"; done
printf '\n' >> "$DEVAGENT_STUB_LOG"
echo "cppcheck: clean"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/fake-python"
    export DEVAGENT_PYTHON="$DEVAGENT_STUB_BIN/fake-python"
}
teardown() { devagent_test_teardown; }

@test "analyze-static.sh invokes static_analysis_diff.py with baseline + build dir" {
    run "$DEVAGENT_ROOT/scripts/analyze-static.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "$DEVAGENT_ROOT/static_analysis_diff.py HEAD"
    out_file="$(ls "$DEVDOC_DIR/Issue-1/analysis"/*-static.txt | head -1)"
    [ -s "$out_file" ]
    grep -q "cppcheck: clean" "$out_file"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/analyze-static.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/analyze-static.sh — thin wrapper around the existing
# static_analysis_diff.py. Writes timestamped output under
# <issue-dir>/analysis/. Build dir is resolved from config or defaulted.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"

: "${DEVAGENT_PYTHON:=python3}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"
baseline="$(state_get "$project" baseline_sha)"
[ -n "$baseline" ] || baseline="$(config_get "$project" default_baseline)"

build_dir="$(config_get "$project" build_dir 2>/dev/null || true)"
if [ -z "$build_dir" ]; then
    source_dir="$(config_get "$project" source_dir)"
    build_dir="$source_dir/build"
fi

mkdir -p "$issue_dir/analysis"
out="$issue_dir/analysis/$(date +%Y-%m-%d)-static.txt"

"$DEVAGENT_PYTHON" "$DEVAGENT_ROOT/static_analysis_diff.py" "$baseline" "$build_dir" \
    | tee "$out"
```

`chmod +x scripts/analyze-static.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/analyze-static.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/analyze-static.sh tests/analyze-static.bats
git commit -s -m "$(cat <<'EOF'
scripts: add analyze-static.sh wrapping static_analysis_diff.py

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: analyze-sanitizers.sh — ASan/UBSan/TSan against diff scope

**Files:**
- Create: `scripts/analyze-sanitizers.sh`
- Test:  `tests/analyze-sanitizers.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x \
      && echo a > a.cc && git add a.cc \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m base )
    sed -i "s|^branch *=.*|branch = \"fix/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"HEAD~0\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Stub cmake + ctest used by sanitizer runner.
    devagent_stub cmake ""
    devagent_stub ctest "PASS: 2/2"
}
teardown() { devagent_test_teardown; }

@test "analyze-sanitizers.sh runs three sanitizer profiles and writes one file each" {
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-asan.txt" ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-ubsan.txt" ]
    [ -f "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-tsan.txt" ]
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=address' "$DEVAGENT_STUB_LOG"
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=undefined' "$DEVAGENT_STUB_LOG"
    grep -q '\-DCMAKE_C_FLAGS=-fsanitize=thread' "$DEVAGENT_STUB_LOG"
}

@test "analyze-sanitizers.sh records a non-zero ctest exit in the output" {
    devagent_stub ctest "FAIL: 1/2" 1
    run "$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh" "$TEST_PROJECT" Issue-1
    # Script must not abort on sanitizer test failure — it records & moves on.
    [ "$status" -eq 0 ]
    grep -q "FAIL: 1/2" "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-asan.txt"
    grep -q "exit=1" "$DEVDOC_DIR/Issue-1/analysis/$(date +%Y-%m-%d)-asan.txt"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/analyze-sanitizers.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/analyze-sanitizers.sh — run ASan, UBSan, TSan against changed-line
# scope. Uses a separate build dir per sanitizer to avoid contaminating the
# main build. Per spec §18: no sub-step tracking in checklist; analyze.sh
# (Task 10) calls this and writes the step-11 checklist entry.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"

: "${DEVAGENT_CMAKE:=cmake}"
: "${DEVAGENT_CTEST:=ctest}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"
source_dir="$(config_get "$project" source_dir)"
mkdir -p "$issue_dir/analysis"

date_tag="$(date +%Y-%m-%d)"
run_one() {
    local tag="$1" flag="$2"
    local out="$issue_dir/analysis/$date_tag-$tag.txt"
    local build="$source_dir/build-$tag"
    mkdir -p "$build"
    {
        echo "=== $tag ==="
        "$DEVAGENT_CMAKE" -S "$source_dir" -B "$build" \
            "-DCMAKE_BUILD_TYPE=Debug" \
            "-DCMAKE_C_FLAGS=-fsanitize=$flag" \
            "-DCMAKE_CXX_FLAGS=-fsanitize=$flag" 2>&1 || true
        "$DEVAGENT_CMAKE" --build "$build" 2>&1 || true
        set +e
        ( cd "$build" && "$DEVAGENT_CTEST" --output-on-failure )
        local rc=$?
        set -e
        echo "exit=$rc"
    } > "$out"
}

run_one asan  address
run_one ubsan undefined
run_one tsan  thread
```

`chmod +x scripts/analyze-sanitizers.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/analyze-sanitizers.bats`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/analyze-sanitizers.sh tests/analyze-sanitizers.bats
git commit -s -m "$(cat <<'EOF'
scripts: add analyze-sanitizers.sh (asan/ubsan/tsan against diff scope)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: analyze.sh — sequences static then sanitizers for step 11

**Files:**
- Create: `scripts/analyze.sh`
- Test:  `tests/analyze.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b fix/1-x )
    sed -i "s|^branch *=.*|branch = \"fix/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    sed -i "s|^baseline_sha *=.*|baseline_sha = \"HEAD\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Stub both inner scripts so we can assert order without running them.
    mkdir -p "$DEVAGENT_TMP/fake-scripts"
    cat > "$DEVAGENT_TMP/fake-scripts/analyze-static.sh" <<EOF
#!/usr/bin/env bash
echo "static \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    cat > "$DEVAGENT_TMP/fake-scripts/analyze-sanitizers.sh" <<EOF
#!/usr/bin/env bash
echo "san \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-scripts/"*.sh
    export DEVAGENT_ANALYZE_STATIC="$DEVAGENT_TMP/fake-scripts/analyze-static.sh"
    export DEVAGENT_ANALYZE_SANITIZERS="$DEVAGENT_TMP/fake-scripts/analyze-sanitizers.sh"
}
teardown() { devagent_test_teardown; }

@test "analyze.sh runs static then sanitizers and marks step 11 done" {
    run "$DEVAGENT_ROOT/scripts/analyze.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    # Order: static appears before sanitizer line.
    static_line=$(grep -n '^static ' "$DEVAGENT_STUB_LOG" | head -1 | cut -d: -f1)
    san_line=$(grep -n '^san '    "$DEVAGENT_STUB_LOG" | head -1 | cut -d: -f1)
    [ "$static_line" -lt "$san_line" ]
    grep -q '\[x\] 11. analyze' "$DEVDOC_DIR/Issue-1/checklist.md"
    grep -q 'analyze: static + sanitizers complete' "$DEVDOC_DIR/Issue-1/checklist.md"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/analyze.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/analyze.sh — step 11. Sequences static then sanitizers per spec §6.3.
# No sub-step tracking in the checklist (spec §18).
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_ANALYZE_STATIC:=$DEVAGENT_ROOT/scripts/analyze-static.sh}"
: "${DEVAGENT_ANALYZE_SANITIZERS:=$DEVAGENT_ROOT/scripts/analyze-sanitizers.sh}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"

"$DEVAGENT_ANALYZE_STATIC"     "$project" "$issue_arg"
"$DEVAGENT_ANALYZE_SANITIZERS" "$project" "$issue_arg"

state_set "$project" last_step      11
state_set "$project" last_step_name analyze
checklist_mark "$issue_dir" 11 x
log_append "$issue_dir" analyze "static + sanitizers complete${NOTE:+ — $NOTE}"
```

`chmod +x scripts/analyze.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/analyze.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/analyze.sh tests/analyze.bats
git commit -s -m "$(cat <<'EOF'
scripts: add analyze.sh (step 11 — sequences static + sanitizers)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: ship.sh — happy path, permission allowed

**Files:**
- Create: `scripts/ship.sh`
- Test:  `tests/ship.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x \
      && echo hi > a.txt && git add a.txt \
      && git -c user.email=t@example.com -c user.name=Test commit -q -m s )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Ensure mr.md exists (Plan 4's draftmr writes it; we preseed).
    echo "MR body" > "$DEVDOC_DIR/Issue-1/mr.md"
    # Stubs for backends used by ship.
    devagent_stub git ""                     # push-branch will shell to git
    cat > "$DEVAGENT_STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "https://github.com/acme/testproj/pull/77"
EOF
    chmod +x "$DEVAGENT_STUB_BIN/gh"
    # Issue backend transition: succeed silently.
    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

@test "ship.sh pushes branch, creates MR, fires on_ship transition, stores mr_url" {
    run "$DEVAGENT_ROOT/scripts/ship.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    devagent_assert_logged "git push --set-upstream origin feat/1-x"
    devagent_assert_logged "gh pr create --repo acme/testproj"
    devagent_assert_logged "issue/github transition acme/testproj 1 on_ship"
    grep -q 'mr_url *= *"https://github.com/acme/testproj/pull/77"' \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -q '\[x\] 15. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/ship.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/ship.sh — step 15. Push branch, create MR, fire on_ship transition.
# Honors permissions.push_mr and ship_as_draft. If fork_first=true, files MR
# on the fork before referencing upstream.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"
. "$DEVAGENT_ROOT/scripts/lib/artifact.sh"

: "${DEVAGENT_CODE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/code}"
: "${DEVAGENT_ISSUE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/issue}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"
branch="$(state_get "$project" branch)"
[ -n "$branch" ] || { echo "no branch in state" >&2; exit 1; }

code_backend="$(config_get "$project" code_source.backend)"
upstream_repo="$(config_get "$project" code_source.upstream)"
fork_repo="$(config_get "$project" code_source.fork 2>/dev/null || true)"
fork_first="$(config_get "$project" fork_first 2>/dev/null || echo false)"
ship_as_draft_global="$(config_get defaults ship_as_draft 2>/dev/null || echo false)"
ship_as_draft_proj="$(config_get "$project" ship_as_draft 2>/dev/null || echo "$ship_as_draft_global")"

push_remote="$(config_get "$project" source_remote 2>/dev/null || echo origin)"

issue_backend="$(config_get "$project" issue_source.backend)"
issue_repo="$(config_get "$project" issue_source.repo)"
issue_num="${issue_arg#Issue-}"
issue_num="${issue_num#Fork-}"

mr_body="$issue_dir/mr.md"
[ -r "$mr_body" ] || { echo "missing $mr_body — run /devagent:draftmr first" >&2; exit 1; }

# Permission gate.
plan="$(cat <<EOF
ship plan
  branch:     $branch
  push to:    $push_remote
  MR repo:    $( [ "$fork_first" = "true" ] && echo "$fork_repo (fork)" || echo "$upstream_repo" )
  draft?:     $ship_as_draft_proj
  issue:      $issue_arg → on_ship
EOF
)"
permission_gate "$project" push_mr "$plan"

code_sh="$DEVAGENT_CODE_BACKEND_DIR/$code_backend.sh"
[ -x "$code_sh" ] || { echo "missing code backend $code_sh" >&2; exit 1; }

# Push branch.
( cd "$(config_get "$project" source_dir)" \
  && "$code_sh" push-branch "$push_remote" "$branch" )

# Resolve target repo. fork_first → fork; else upstream.
target_repo="$upstream_repo"
if [ "$fork_first" = "true" ] && [ -n "$fork_repo" ]; then
    target_repo="$fork_repo"
fi

base_branch="$(config_get "$project" default_baseline | sed 's|^[^/]*/||')"
[ -n "$base_branch" ] || base_branch="main"

title="$(head -1 "$mr_body")"
title="${title#\# }"   # strip leading "# "

draft_flag=()
[ "$ship_as_draft_proj" = "true" ] && draft_flag=(--draft)

mr_url="$("$code_sh" create-mr "$target_repo" "$title" "$mr_body" "$branch" "$base_branch" "${draft_flag[@]}")"
[ -n "$mr_url" ] || { echo "create-mr returned empty URL" >&2; exit 1; }

# Fire on_ship transition. Tolerate missing transition verb / failures per §11.
issue_sh="$DEVAGENT_ISSUE_BACKEND_DIR/$issue_backend.sh"
if [ -x "$issue_sh" ]; then
    if ! "$issue_sh" transition "$issue_repo" "$issue_num" on_ship; then
        echo "warning: issue transition failed — continuing per spec §11" >&2
    fi
fi

state_set "$project" mr_url         "$mr_url"
state_set "$project" last_step      15
state_set "$project" last_step_name ship
checklist_mark "$issue_dir" 15 x
log_append "$issue_dir" ship "MR $mr_url${NOTE:+ — $NOTE}"
echo "$mr_url"
```

`chmod +x scripts/ship.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/ship.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/ship.sh tests/ship.bats
git commit -s -m "$(cat <<'EOF'
scripts: add ship.sh (step 15 — push, create MR, fire on_ship)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: ship.sh — permission denied gate

**Files:**
- Modify: `tests/ship.bats`

- [ ] **Step 1: Append failing test**

```bash
@test "ship.sh halts and prompts when push_mr=false; declining preserves state" {
    sed -i "s|^push_mr *=.*|push_mr = false|" "$HOME/.claude/devagent/config.toml"
    # Decline.
    run bash -c "echo n | '$DEVAGENT_ROOT/scripts/ship.sh' '$TEST_PROJECT' Issue-1"
    [ "$status" -ne 0 ]
    # No MR url recorded.
    ! grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Checklist unchanged for step 15.
    grep -q '\[ \] 15. ship' "$DEVDOC_DIR/Issue-1/checklist.md"
    # Plan was printed (the permission gate text).
    [[ "$output" == *"ship plan"* ]]
}

@test "ship.sh proceeds when push_mr=false but operator accepts" {
    sed -i "s|^push_mr *=.*|push_mr = false|" "$HOME/.claude/devagent/config.toml"
    run bash -c "echo y | '$DEVAGENT_ROOT/scripts/ship.sh' '$TEST_PROJECT' Issue-1"
    [ "$status" -eq 0 ]
    grep -q '^mr_url' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `bats tests/ship.bats`
Expected: all tests pass (`permission_gate` from Plan 1 handles prompting).

- [ ] **Step 3: Commit**

```bash
git add tests/ship.bats
git commit -s -m "$(cat <<'EOF'
test: cover push_mr permission gate in ship.sh

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: mergetoall.sh — squash into dev/all-prs

**Files:**
- Create: `scripts/mergetoall.sh`
- Test:  `tests/mergetoall.bats`

- [ ] **Step 1: Write the failing test**

```bash
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
    grep -q '\[x\] 16. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "mergetoall.sh halts on merge_mr=false decline" {
    sed -i "s|^merge_mr *=.*|merge_mr = false|" "$HOME/.claude/devagent/config.toml"
    run bash -c "echo n | '$DEVAGENT_ROOT/scripts/mergetoall.sh' '$TEST_PROJECT' Issue-1"
    [ "$status" -ne 0 ]
    grep -q '\[ \] 16. mergetoall' "$DEVDOC_DIR/Issue-1/checklist.md"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/mergetoall.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/mergetoall.sh — step 16. Squash-merge active branch into the
# all_prs_branch. Honors permissions.merge_mr.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"
branch="$(state_get "$project" branch)"
[ -n "$branch" ] || { echo "no branch in state" >&2; exit 1; }
all_prs="$(config_get "$project" all_prs_branch)"
source_dir="$(config_get "$project" source_dir)"

plan="$(cat <<EOF
mergetoall plan
  squash-merge $branch into $all_prs
  in           $source_dir
EOF
)"
permission_gate "$project" merge_mr "$plan"

cd "$source_dir"
"$DEVAGENT_GIT" checkout "$all_prs"
"$DEVAGENT_GIT" merge --squash "$branch"
# Use a deterministic commit message — single-line subject + branch ref.
subject="merge $branch into $all_prs"
"$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
    commit -m "$subject"

state_set "$project" last_step      16
state_set "$project" last_step_name mergetoall
checklist_mark "$issue_dir" 16 x
log_append "$issue_dir" mergetoall "squashed $branch → $all_prs${NOTE:+ — $NOTE}"
```

`chmod +x scripts/mergetoall.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/mergetoall.bats`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/mergetoall.sh tests/mergetoall.bats
git commit -s -m "$(cat <<'EOF'
scripts: add mergetoall.sh (step 16 — squash into dev/all-prs)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: cleanup.sh — restore tree, commit devdoc, clear active_issue

**Files:**
- Create: `scripts/cleanup.sh`
- Test:  `tests/cleanup.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x )
    sed -i "s|^branch *=.*|branch = \"feat/1-x\"|" "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Initialize devdoc dir as a git repo with a remote stub.
    ( cd "$DEVDOC_DIR" \
      && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com \
      && git config user.name Test \
      && git add . \
      && git commit -q -m "seed" )
    # origin/main reference for source repo: create it as a local branch.
    ( cd "$SOURCE_DIR" && git branch -f main )
    # Stub `git` only for the *push* calls cleanup may make on devdoc; we
    # intercept by remote name "origin" not being defined → harmless skip.
}
teardown() { devagent_test_teardown; }

@test "cleanup.sh switches source tree to main, commits devdoc, clears active_issue" {
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    cur="$( cd "$SOURCE_DIR" && git rev-parse --abbrev-ref HEAD )"
    [ "$cur" = "main" ]
    # Devdoc commit happened (commit count > 1).
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -ge 2 ]
    # active_issue cleared.
    grep -q '^active_issue *= *""' "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    grep -q '\[x\] 20. cleanup' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "cleanup.sh skips devdoc commit when commit_devdoc=false" {
    sed -i "s|^commit_devdoc *=.*|commit_devdoc = false|" "$HOME/.claude/devagent/config.toml"
    run "$DEVAGENT_ROOT/scripts/cleanup.sh" "$TEST_PROJECT" Issue-1
    [ "$status" -eq 0 ]
    n=$( cd "$DEVDOC_DIR" && git rev-list --count HEAD )
    [ "$n" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cleanup.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/cleanup.sh — step 20. Switch source tree back to origin/main (or
# default_baseline), commit/push devdoc if permissions.commit_devdoc=true,
# clear active_issue in state.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"
. "$DEVAGENT_ROOT/scripts/lib/permission.sh"

: "${DEVAGENT_GIT:=git}"

project="${1:?project required}"
issue_arg="${2:-}"
[ -n "$issue_arg" ] || issue_arg="$(state_get "$project" active_issue)"
issue_dir="$(state_get "$project" issue_dir)"
source_dir="$(config_get "$project" source_dir)"
devdoc_dir="$(config_get "$project" devdoc_dir)"
baseline="$(config_get "$project" default_baseline)"
base_branch="${baseline##*/}"

# Restore source tree.
( cd "$source_dir" && "$DEVAGENT_GIT" checkout "$base_branch" )

# Commit + push devdoc if permitted.
commit_devdoc="$(config_get "$project" permissions.commit_devdoc 2>/dev/null || echo false)"
if [ "$commit_devdoc" = "true" ]; then
    plan="cleanup plan: commit + push devdoc updates for $issue_arg"
    permission_gate "$project" commit_devdoc "$plan"
    cd "$devdoc_dir"
    if ! "$DEVAGENT_GIT" diff --quiet || ! "$DEVAGENT_GIT" diff --cached --quiet; then
        "$DEVAGENT_GIT" add -A
        "$DEVAGENT_GIT" -c user.email=devagent@local -c user.name=devagent \
            commit -m "devdoc: $issue_arg cleanup"
        # Push if origin is configured; tolerate missing.
        if "$DEVAGENT_GIT" remote get-url origin >/dev/null 2>&1; then
            "$DEVAGENT_GIT" push origin HEAD 2>/dev/null || \
                echo "warning: devdoc push failed; commit retained locally" >&2
        fi
    fi
fi

state_set "$project" last_step      20
state_set "$project" last_step_name cleanup
state_set "$project" active_issue   ""
state_set "$project" branch         ""
state_set "$project" worktree_path  ""

checklist_mark "$issue_dir" 20 x
log_append "$issue_dir" cleanup "tree restored, active_issue cleared${NOTE:+ — $NOTE}"
```

`chmod +x scripts/cleanup.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cleanup.bats`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/cleanup.sh tests/cleanup.bats
git commit -s -m "$(cat <<'EOF'
scripts: add cleanup.sh (step 20 — restore tree, clear active_issue)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: sync.sh — async merge detection, fires on_merge

**Files:**
- Create: `scripts/sync.sh`
- Test:  `tests/sync.bats`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bats
load 'helpers/common'

setup() {
    devagent_test_setup
    # Pretend Issue-1 was shipped and has an MR URL stored.
    sed -i 's|^mr_url *=.*|mr_url = "https://github.com/acme/testproj/pull/77"|' \
        "$HOME/.claude/devagent/state/$TEST_PROJECT.toml" \
        || echo 'mr_url = "https://github.com/acme/testproj/pull/77"' \
            >> "$HOME/.claude/devagent/state/$TEST_PROJECT.toml"
    # Mark step 15 done so sync considers this issue.
    sed -i 's|^- \[ \] 15. ship.*|- [x] 15. ship|' "$DEVDOC_DIR/Issue-1/checklist.md"

    # Stub code/github.sh mr-state to return "merged".
    mkdir -p "$DEVAGENT_TMP/fake-code"
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<EOF
#!/usr/bin/env bash
echo "code/github \$@" >> "$DEVAGENT_STUB_LOG"
[ "\$1" = "mr-state" ] && echo merged
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    export DEVAGENT_CODE_BACKEND_DIR="$DEVAGENT_TMP/fake-code"

    mkdir -p "$DEVAGENT_TMP/fake-issue"
    cat > "$DEVAGENT_TMP/fake-issue/github.sh" <<EOF
#!/usr/bin/env bash
echo "issue/github \$@" >> "$DEVAGENT_STUB_LOG"
EOF
    chmod +x "$DEVAGENT_TMP/fake-issue/github.sh"
    export DEVAGENT_ISSUE_BACKEND_DIR="$DEVAGENT_TMP/fake-issue"
}
teardown() { devagent_test_teardown; }

@test "sync.sh detects merged MR and fires on_merge transition" {
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    devagent_assert_logged "code/github mr-state https://github.com/acme/testproj/pull/77"
    devagent_assert_logged "issue/github transition acme/testproj 1 on_merge"
    grep -q 'sync: Issue-1 merged' "$DEVDOC_DIR/Issue-1/checklist.md"
}

@test "sync.sh skips issues whose MR is still open" {
    cat > "$DEVAGENT_TMP/fake-code/github.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "mr-state" ] && echo open
EOF
    chmod +x "$DEVAGENT_TMP/fake-code/github.sh"
    run "$DEVAGENT_ROOT/scripts/sync.sh" "$TEST_PROJECT"
    [ "$status" -eq 0 ]
    ! grep -q 'on_merge' "$DEVAGENT_STUB_LOG"
}

@test "sync.sh --all iterates every configured project" {
    # Add a second project block.
    cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.other]
source_dir       = "$DEVAGENT_TMP/src/other"
devdoc_dir       = "$DEVAGENT_TMP/devdoc/other"
default_baseline = "origin/main"
all_prs_branch   = "dev/all-prs"
branch_prefix_map = { bug = "fix", feature = "feat" }

[project.other.permissions]
push_mr = true
merge_mr = true
commit_devdoc = false
transition_issue = true
cleanup_on_merge = false

[project.other.issue_source]
backend = "github"
repo    = "acme/other"
dir_prefix = "Issue-"

[project.other.code_source]
backend  = "github"
upstream = "acme/other"
fork     = "me/other"

[project.other.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
EOF
    mkdir -p "$DEVAGENT_TMP/devdoc/other"
    cat > "$HOME/.claude/devagent/state/other.toml" <<EOF
active_issue = ""
issue_dir = ""
branch = ""

[parked]
EOF
    run "$DEVAGENT_ROOT/scripts/sync.sh" --all
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/sync.bats`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# scripts/sync.sh — async merge detection. For each shipped issue (step 15
# done, mr_url set), call code/<backend>.sh mr-state and if "merged", fire
# the on_merge transition exactly once.
set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$DEVAGENT_ROOT/scripts/lib/config.sh"
. "$DEVAGENT_ROOT/scripts/lib/state.sh"
. "$DEVAGENT_ROOT/scripts/lib/checklist.sh"
. "$DEVAGENT_ROOT/scripts/lib/log.sh"

: "${DEVAGENT_CODE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/code}"
: "${DEVAGENT_ISSUE_BACKEND_DIR:=$DEVAGENT_ROOT/scripts/issue}"

# Plan 1 must expose `config_projects` returning project names one per line.
# If it doesn't, this script greps the config file directly as a fallback.
list_projects() {
    if declare -F config_projects >/dev/null 2>&1; then
        config_projects
    else
        grep -E '^\[project\.[a-zA-Z0-9_-]+\]$' "$HOME/.claude/devagent/config.toml" \
            | sed -E 's/^\[project\.([^.]+)\]$/\1/'
    fi
}

sync_one_project() {
    local project="$1"
    local state_file="$HOME/.claude/devagent/state/$project.toml"
    [ -r "$state_file" ] || return 0

    local issue_dir mr_url
    issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
    mr_url="$(state_get   "$project" mr_url    2>/dev/null || true)"
    [ -n "$issue_dir" ] && [ -d "$issue_dir" ] || return 0
    [ -n "$mr_url" ] || return 0

    # Has step 15 been marked done?
    grep -q '^- \[x\] 15. ship'   "$issue_dir/checklist.md" || return 0
    # Has on_merge already fired? (Idempotence — log entry would exist.)
    grep -q 'sync: .* merged'     "$issue_dir/checklist.md" && return 0

    local code_backend issue_backend issue_repo issue_arg issue_num
    code_backend="$(config_get  "$project" code_source.backend)"
    issue_backend="$(config_get "$project" issue_source.backend)"
    issue_repo="$(config_get    "$project" issue_source.repo)"
    issue_arg="$(state_get      "$project" active_issue)"
    issue_num="${issue_arg#Issue-}"; issue_num="${issue_num#Fork-}"

    local code_sh issue_sh state
    code_sh="$DEVAGENT_CODE_BACKEND_DIR/$code_backend.sh"
    issue_sh="$DEVAGENT_ISSUE_BACKEND_DIR/$issue_backend.sh"
    state="$("$code_sh" mr-state "$mr_url")"
    [ "$state" = "merged" ] || return 0

    if [ -x "$issue_sh" ]; then
        if ! "$issue_sh" transition "$issue_repo" "$issue_num" on_merge; then
            echo "warning: on_merge transition failed for $project/$issue_arg" >&2
        fi
    fi
    log_append "$issue_dir" sync "$issue_arg merged → on_merge fired"
}

if [ "${1:-}" = "--all" ]; then
    while read -r p; do sync_one_project "$p"; done < <(list_projects)
else
    project="${1:?project or --all required}"
    sync_one_project "$project"
fi
```

`chmod +x scripts/sync.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/sync.bats`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync.sh tests/sync.bats
git commit -s -m "$(cat <<'EOF'
scripts: add sync.sh (async merge detection, fires on_merge)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Slash-command markdown files

**Files:**
- Create: `commands/branch.md`
- Create: `commands/commit.md`
- Create: `commands/analyze.md`
- Create: `commands/ship.md`
- Create: `commands/mergetoall.md`
- Create: `commands/cleanup.md`
- Create: `commands/sync.md`

- [ ] **Step 1: Write all seven command files**

Each command file follows the same shape so the harness recognises it as a thin shell wrapper. Replace `<verb>` and the description per row of the table below:

| File | Verb | One-line description |
|---|---|---|
| `commands/branch.md`     | `branch`     | Step 6: create issue branch from default_baseline. |
| `commands/commit.md`     | `commit`     | Step 10: commit staged changes with DCO sign-off using commit_template. |
| `commands/analyze.md`    | `analyze`    | Step 11: run static analysis then sanitizers against changed-line scope. |
| `commands/ship.md`       | `ship`       | Step 15: push branch and open MR, fire on_ship issue transition. |
| `commands/mergetoall.md` | `mergetoall` | Step 16: squash-merge the issue branch into dev/all-prs. |
| `commands/cleanup.md`    | `cleanup`    | Step 20: restore tree, commit devdoc, clear active_issue. |
| `commands/sync.md`       | `sync`       | Async merge detection: fires on_merge for shipped issues that merged outside this session. |

Template body for each (substitute `<verb>` and `<description>`):

```markdown
---
description: <description>
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:<verb>

Invokes `scripts/<verb>.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

!`bash {{plugin_root}}/scripts/<verb>.sh $ARGUMENTS`
```

For `analyze`, the `!` line invokes `scripts/analyze.sh` (the sequencer), not
`analyze-static.sh` or `analyze-sanitizers.sh` directly.

- [ ] **Step 2: Smoke-test that each file parses as YAML frontmatter + body**

Run:

```bash
for f in commands/branch.md commands/commit.md commands/analyze.md commands/ship.md commands/mergetoall.md commands/cleanup.md commands/sync.md; do
    head -1 "$f" | grep -qx '---' || { echo "missing frontmatter: $f"; exit 1; }
    grep -q '^description:' "$f" || { echo "missing description: $f"; exit 1; }
done
echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add commands/branch.md commands/commit.md commands/analyze.md commands/ship.md commands/mergetoall.md commands/cleanup.md commands/sync.md
git commit -s -m "$(cat <<'EOF'
commands: add slash-command files for workflow script steps

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Full-suite green run

- [ ] **Step 1: Run every bats file**

```bash
bats tests/code-github.bats tests/branch.bats tests/commit.bats \
     tests/analyze-static.bats tests/analyze-sanitizers.bats \
     tests/analyze.bats tests/ship.bats tests/mergetoall.bats \
     tests/cleanup.bats tests/sync.bats
```

Expected: all tests pass.

- [ ] **Step 2: Verify no plan placeholder left behind**

```bash
! grep -RInE 'TBD|TODO|FIXME|placeholder' scripts/ commands/ tests/
```

Expected: no matches (the leading `!` inverts; the command should exit 0).

- [ ] **Step 3: Final commit of any test-isolation tweaks**

Only if Step 1 or 2 surfaced fixes. Otherwise skip.

```bash
git status
git diff
# If clean, no commit needed.
```

---

## Self-review notes

Mapping spec → tasks, performed after drafting:

- §6.3 step 6 (branch)         → Tasks 5–6
- §6.3 step 10 (commit)        → Task 7
- §6.3 step 11 (analyze)       → Tasks 8–10
- §6.3 step 15 (ship)          → Tasks 11–12
- §6.3 step 16 (mergetoall)    → Task 13
- §6.3 step 20 (cleanup)       → Task 14
- §6.5 `/devagent:sync`        → Task 15
- §8 permission gates          → Tasks 11–14 each exercise their gate
- §9.2 code backend contract   → Tasks 2–4
- §11 transitions (on_ship, on_merge) → Tasks 11, 15
- §18 analyzers ordering       → Task 10 (`analyze.sh` calls static before sanitizers)
- §6.1 invocation grammar      → All scripts accept `[project] [issue-dir]` positional args with state-driven defaults

## Open questions

1. **`config_projects` helper.** Plan 1 may or may not expose `config_projects` (returning project names from `config.toml`). `sync.sh` falls back to `grep` when the helper is absent. If Plan 1 standardises the helper, the fallback can be removed in a future tidy-up commit.
2. **Issue type / title source for `branch.sh` and `commit.sh`.** This plan reads `<issue-dir>/.devagent-type` and `.devagent-title` marker files. Plan 4's `draft` skill is expected to write them. If Plan 4 chooses a different schema (e.g. YAML frontmatter inside `imPlan.md`), `branch.sh` and `commit.sh` will need a single-line edit to the resolver. Test fixtures preseed the marker files, so they will keep working either way.
3. **`issue/<backend>.sh transition` arity.** Spec §9.1 shows `transition <repo> <num> <semantic-stage>`. This plan passes the semantic-stage *key* (`on_ship`, `on_merge`) rather than the human-readable value (`"In Review"`, `"Done"`) from `[issue_workflow]`. If Plan 2 expects the value, the call sites in `ship.sh` and `sync.sh` need to map the key → value via `config_get "$project" issue_workflow.on_ship`. The marker-test stub here checks the literal `on_ship` token, so changing the convention requires updating both the script and the test in the same commit.
4. **`default_baseline` parsing in `cleanup.sh`.** Cleanup assumes `default_baseline` has the form `origin/<branch>` and strips the remote with `${baseline##*/}`. Bare-branch values like `main` already collapse correctly; multi-slash refs (`origin/release/2026.05`) would break. Worth confirming with Plan 1 whether validation is performed there.
5. **Plan 1 `permission_gate` exit code.** Tests in Tasks 12, 13 assert `status -ne 0` on decline; if Plan 1 picks a specific exit code (e.g., 10), this plan should align to that exact value for future grepability.
