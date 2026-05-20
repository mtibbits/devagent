# devAgent Phase 6 — Revision Family Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `/devagent:comments` and `/devagent:revise` so an operator can pull MR feedback into the issue dir, increment the revision counter, append a fresh `## Revision N` block to `checklist.md`, and resume the workflow from `draft` with the comments file in context.

**Architecture:**
- `comments` is a pure script (`scripts/comments.sh`) that resolves the active issue, reads `mr_url` from per-project state, invokes `code/<backend>.sh mr-comments`, and writes the output to `<issue-dir>/revisions/r<N>/comments.md` where `N` is the *current* `revision` (not incremented). Idempotent — overwrites the file on re-run, never duplicates.
- `revise` is a script (`scripts/revise.sh`) that requires `revisions/r<N>/comments.md` to exist (the file produced by `comments`), increments `revision` in the state file, creates `revisions/r<N+1>/`, appends a new `## Revision <N+1>` block to `checklist.md` (steps 1-15 re-listed as `[ ]`; step 0 and steps 16-20 are *not* re-listed), appends a single log entry, and — unless `--no-chain` is passed — invokes `/devagent:next` to resume from step 1 (`draft`). The new revision's `comments.md` path is recorded in state as `last_comments_file` so the `draft` skill picks it up as user-intent context on the next pass.
- Plumbing for "comments as draft context" works by `draft.sh` (Phase 4 plan, not this one) reading `last_comments_file` from state when present and passing the file contents into `$NOTE` for the `superpowers:writing-plans` skill. This plan documents the contract and writes the state field; the consumer is out of scope.

**Tech Stack:**
- bash (scripts), bats-core (shell tests)
- `tq` (TOML query) or a shared `lib/state.sh` helper from Phase 1 — assumed present
- `lib/checklist.sh` from Phase 1 — assumed present, provides `checklist_append_block` and `checklist_log`
- `code/github.sh mr-comments` from Phase 3 — referenced, not modified

---

## Assumed prerequisites (delivered by earlier phases)

These exist and have stable contracts before this plan starts. Do not re-implement them.

- `scripts/lib/config.sh` — `config_get <project> <key>` reads `~/.claude/devagent/config.toml`
- `scripts/lib/state.sh` — `state_get <project> <key>`, `state_set <project> <key> <value>`, `state_path <project>` (returns `~/.claude/devagent/state/<project>.toml`)
- `scripts/lib/checklist.sh` — `checklist_log <issue-dir> <step> <message>` appends a `YYYY-MM-DD HH:MM  step: message` line under the `## Log` section
- `scripts/lib/log.sh` — `log_info`, `log_warn`, `log_error` (stderr, no token leakage)
- `scripts/code/github.sh mr-comments <mr-url>` — emits markdown to stdout
- `scripts/lib/resolve.sh` — `resolve_project <argv...>`, `resolve_issue <project> <argv...>` (positional grammar from spec §6.1)
- `commands/next.md` — the `/devagent:next` slash command exists and can be invoked by writing a sentinel file or by printing a `CHAIN: /devagent:next` line that the harness recognizes (Phase 2 plan)

If any helper above is missing when this plan executes, stop and add it to its owning phase rather than inlining it here.

---

## File Structure

**Created in this phase:**

- `commands/comments.md` — slash command frontmatter + body for `/devagent:comments`
- `commands/revise.md` — slash command frontmatter + body for `/devagent:revise`
- `scripts/comments.sh` — fetches MR comments to `revisions/r<N>/comments.md`
- `scripts/revise.sh` — increments revision, appends checklist block, sets `last_comments_file`, chains to `next`
- `scripts/lib/revision.sh` — small shared helpers: `revision_current`, `revision_dir`, `revision_block_text`
- `templates/revision_block.md` — the canonical "steps 1-15 as `[ ]`" template appended to `checklist.md`
- `tests/comments.bats` — bats tests for `scripts/comments.sh`
- `tests/revise.bats` — bats tests for `scripts/revise.sh`
- `tests/revision_lib.bats` — bats tests for `scripts/lib/revision.sh`
- `tests/helpers/fixtures.bash` — shared bats helpers for building a fake project/issue/state

**Modified in this phase:**

- None. All earlier-phase files (`state.sh`, `checklist.sh`, `code/github.sh`) are consumed read-only.

---

## Task 1: Shared bats fixture helpers

**Files:**
- Create: `/home/user/src/devAgent/tests/helpers/fixtures.bash`

Reused by every test in this phase. Builds a throwaway `$BATS_TEST_TMPDIR/home/.claude/devagent/...` tree and a throwaway `$BATS_TEST_TMPDIR/devdoc/<project>/<issue>/` tree, points `HOME` and `DEVAGENT_CONFIG` at them, and stubs `code/github.sh` so tests never hit the network.

- [ ] **Step 1: Create the fixtures file**

Create `/home/user/src/devAgent/tests/helpers/fixtures.bash`:

```bash
# Shared bats helpers for devAgent Phase 6 tests.
#
# Usage in a .bats file:
#   load 'helpers/fixtures'
#   setup() { fixture_init volk Issue-676; }

# Absolute repo root, resolved once.
DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# fixture_init <project> <issue-dir-name>
#
# Builds a self-contained HOME with:
#   $HOME/.claude/devagent/config.toml
#   $HOME/.claude/devagent/state/<project>.toml
#   $HOME/devdoc/<project>/<issue-dir-name>/checklist.md
#
# Exports:
#   FIX_PROJECT, FIX_ISSUE, FIX_ISSUE_DIR, FIX_STATE_FILE, FIX_CONFIG_FILE
#   PATH (prepended with $BATS_TEST_TMPDIR/bin so stub commands win)
fixture_init() {
  local project="$1"
  local issue="$2"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/devagent/state"
  mkdir -p "$HOME/.claude/devagent/secrets"

  local devdoc="$BATS_TEST_TMPDIR/devdoc/$project"
  mkdir -p "$devdoc/$issue/revisions"

  FIX_PROJECT="$project"
  FIX_ISSUE="$issue"
  FIX_ISSUE_DIR="$devdoc/$issue"
  FIX_STATE_FILE="$HOME/.claude/devagent/state/${project}.toml"
  FIX_CONFIG_FILE="$HOME/.claude/devagent/config.toml"

  cat >"$FIX_CONFIG_FILE" <<EOF
[defaults]
checklist_template = "standard"

[project.${project}]
source_dir   = "$BATS_TEST_TMPDIR/src/${project}"
devdoc_dir   = "$devdoc"

[project.${project}.code_source]
backend  = "github"
upstream = "example/${project}"
fork     = "fork/${project}"
EOF

  cat >"$FIX_STATE_FILE" <<EOF
active_issue   = "$issue"
issue_dir      = "$FIX_ISSUE_DIR"
branch         = "fix/0-stub"
last_step      = 15
last_step_name = "ship"
mr_url         = "https://github.com/example/${project}/pull/842"
revision       = 1
updated_at     = "2026-05-19T14:32:00-04:00"
EOF

  cat >"$FIX_ISSUE_DIR/checklist.md" <<'EOF'
# Issue — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: standard
Created: 2026-05-19 14:01
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
- [x]  3. improve
- [x]  4. prune
- [x]  5. tighten
- [x]  6. branch
- [x]  7. implement
- [x]  8. quality
- [x]  9. document
- [x] 10. commit
- [x] 11. analyze
- [x] 12. draftmr
- [x] 13. review
- [x] 14. redmr
- [x] 15. ship
- [ ] 16. mergetoall
- [ ] 17. updatewbs
- [ ] 18. impact
- [ ] 19. lessonslearned
- [ ] 20. cleanup

## Log
- 2026-05-19 14:01  pull: fetched example/stub#0, scaffold created
- 2026-05-19 17:10  ship: MR #842 opened
EOF

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# stub_mr_comments <text>
#
# Installs a stub at $BATS_TEST_TMPDIR/bin/code-github.sh-mr-comments that
# prints <text> on stdout for any invocation. The real backend is at
# scripts/code/github.sh; tests stub it via $DEVAGENT_CODE_BACKEND_CMD.
stub_mr_comments() {
  local text="$1"
  local stub="$BATS_TEST_TMPDIR/bin/devagent-code-github"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
# Stub for code/github.sh used by tests.
# Usage: devagent-code-github mr-comments <url>
if [[ "\$1" == "mr-comments" ]]; then
  cat <<'PAYLOAD'
$text
PAYLOAD
  exit 0
fi
echo "stub: unknown verb \$1" >&2
exit 2
EOF
  chmod +x "$stub"
  export DEVAGENT_CODE_BACKEND_CMD="$stub"
}

# stub_chain_recorder
#
# Replaces /devagent:next chaining with a sentinel write so tests can assert
# whether revise.sh attempted to chain. Sets DEVAGENT_CHAIN_CMD to a script
# that records its argv to $BATS_TEST_TMPDIR/chain.log.
stub_chain_recorder() {
  local stub="$BATS_TEST_TMPDIR/bin/devagent-chain"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/chain.log"
EOF
  chmod +x "$stub"
  export DEVAGENT_CHAIN_CMD="$stub"
}
```

- [ ] **Step 2: Smoke-test the fixture by writing a trivial bats file**

Create `/home/user/src/devAgent/tests/fixtures_smoke.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
}

@test "fixture_init creates expected files" {
  [ -f "$FIX_CONFIG_FILE" ]
  [ -f "$FIX_STATE_FILE" ]
  [ -f "$FIX_ISSUE_DIR/checklist.md" ]
  [ -d "$FIX_ISSUE_DIR/revisions" ]
}

@test "fixture state file has revision = 1" {
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}
```

- [ ] **Step 3: Run the smoke test and verify it passes**

Run: `cd /home/user/src/devAgent && bats tests/fixtures_smoke.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 4: Commit**

```bash
cd /home/user/src/devAgent
git add tests/helpers/fixtures.bash tests/fixtures_smoke.bats
git commit -s -m "$(cat <<'EOF'
test(phase6): add bats fixture helpers for revision-family tests

Builds a throwaway HOME + devdoc tree and stubs the code backend and
chain command so revision tests never touch the network or fire a real
/devagent:next.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `scripts/lib/revision.sh` — shared revision helpers

**Files:**
- Create: `/home/user/src/devAgent/scripts/lib/revision.sh`
- Create: `/home/user/src/devAgent/templates/revision_block.md`
- Test: `/home/user/src/devAgent/tests/revision_lib.bats`

Three small pure functions consumed by `comments.sh` and `revise.sh`:

- `revision_current <project>` — print the current `revision` integer from state, default 1 if unset
- `revision_dir <issue-dir> <N>` — print absolute path `<issue-dir>/revisions/r<N>`
- `revision_block_text <N>` — print the markdown block to append to `checklist.md` for revision `<N>`, sourced from `templates/revision_block.md` with `{{N}}` substituted

- [ ] **Step 1: Write the failing test**

Create `/home/user/src/devAgent/tests/revision_lib.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  # shellcheck source=/dev/null
  source "$DEVAGENT_ROOT/scripts/lib/revision.sh"
}

@test "revision_current returns 1 from fixture state" {
  run revision_current volk
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "revision_current defaults to 1 when state file has no revision key" {
  printf 'active_issue = "Issue-1"\n' >"$FIX_STATE_FILE"
  run revision_current volk
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "revision_dir composes <issue-dir>/revisions/r<N>" {
  run revision_dir "$FIX_ISSUE_DIR" 3
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_ISSUE_DIR/revisions/r3" ]
}

@test "revision_block_text substitutes {{N}} and lists steps 1-15 as pending" {
  run revision_block_text 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Revision 2"* ]]
  [[ "$output" == *"[ ]  1. draft"* ]]
  [[ "$output" == *"[ ] 15. ship"* ]]
  # Step 0 (pull) and steps 16-20 must NOT appear in the block.
  [[ "$output" != *"0. pull"* ]]
  [[ "$output" != *"16. mergetoall"* ]]
  [[ "$output" != *"20. cleanup"* ]]
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd /home/user/src/devAgent && bats tests/revision_lib.bats`
Expected: FAIL — `scripts/lib/revision.sh` does not exist.

- [ ] **Step 3: Create the template**

Create `/home/user/src/devAgent/templates/revision_block.md`:

```markdown

## Revision {{N}}

- [ ]  1. draft
- [ ]  2. scope
- [ ]  3. improve
- [ ]  4. prune
- [ ]  5. tighten
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
```

Note the leading blank line — it provides the separator between the prior block and the new one when appended to `checklist.md`.

- [ ] **Step 4: Implement `scripts/lib/revision.sh`**

Create `/home/user/src/devAgent/scripts/lib/revision.sh`:

```bash
# Revision helpers for devAgent Phase 6.
#
# All functions are pure (no global mutation). Source-only file: do not
# execute directly.

# Resolve plugin root once. Allows override for tests.
: "${DEVAGENT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# revision_current <project>
#
# Print the current `revision` integer from the per-project state file.
# Defaults to 1 if the key is absent or the file does not exist.
revision_current() {
  local project="$1"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  local n
  if [[ -f "$state" ]]; then
    n=$(awk -F'=' '
      $1 ~ /^[[:space:]]*revision[[:space:]]*$/ {
        gsub(/[[:space:]"]/, "", $2)
        print $2
        exit
      }
    ' "$state")
  fi
  if [[ -z "$n" ]]; then
    n=1
  fi
  printf '%s\n' "$n"
}

# revision_dir <issue-dir> <N>
#
# Print the absolute path of the revision directory for revision N.
revision_dir() {
  local issue_dir="$1"
  local n="$2"
  printf '%s/revisions/r%s\n' "$issue_dir" "$n"
}

# revision_block_text <N>
#
# Print the checklist block for revision N. Reads templates/revision_block.md
# and substitutes {{N}}.
revision_block_text() {
  local n="$1"
  local tmpl="$DEVAGENT_ROOT/templates/revision_block.md"
  if [[ ! -f "$tmpl" ]]; then
    printf 'revision_block_text: template not found: %s\n' "$tmpl" >&2
    return 1
  fi
  sed "s/{{N}}/${n}/g" "$tmpl"
}
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `cd /home/user/src/devAgent && bats tests/revision_lib.bats`
Expected: `4 tests, 0 failures`

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/lib/revision.sh templates/revision_block.md tests/revision_lib.bats
git commit -s -m "$(cat <<'EOF'
feat(phase6): add revision helpers and checklist block template

scripts/lib/revision.sh exposes revision_current, revision_dir, and
revision_block_text. templates/revision_block.md is the canonical
steps-1-15 block appended to checklist.md by /devagent:revise.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `scripts/comments.sh` — fetch MR comments to `revisions/r<N>/comments.md`

**Files:**
- Create: `/home/user/src/devAgent/scripts/comments.sh`
- Test: `/home/user/src/devAgent/tests/comments.bats`

Contract:

- Argv: `[project] [issue]` (positional, both optional; defaults from active state)
- Reads `mr_url` from state; errors if absent ("run /devagent:ship first")
- Computes `N = revision_current <project>` (does NOT increment)
- Creates `<issue-dir>/revisions/r<N>/` if missing
- Invokes `${DEVAGENT_CODE_BACKEND_CMD:-$DEVAGENT_ROOT/scripts/code/<backend>.sh} mr-comments <mr-url>` and writes stdout to `<issue-dir>/revisions/r<N>/comments.md`
- Overwrites on re-run (idempotent — same file path, fresh content)
- Logs `comments: fetched K comments` where K is the count of `### @` author headings in the output
- Exit 0 on success, non-zero on backend failure (with the partial file removed)

- [ ] **Step 1: Write the failing tests**

Create `/home/user/src/devAgent/tests/comments.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  stub_mr_comments "$(cat <<'PAYLOAD'
# example/volk#842 — Comments

## Comments (2)

### @alice · 2026-05-20

Please add a test for the boundary case.

### @bob · 2026-05-20

Nit: rename `foo` to `foo_count`.
PAYLOAD
)"
}

run_comments() {
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" "$@"
}

@test "comments writes revisions/r1/comments.md from stub backend" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]
  grep -q "alice" "$FIX_ISSUE_DIR/revisions/r1/comments.md"
  grep -q "bob"   "$FIX_ISSUE_DIR/revisions/r1/comments.md"
}

@test "comments does NOT increment the revision counter" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}

@test "comments is idempotent — second run overwrites, never duplicates" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  local first_size
  first_size=$(wc -c <"$FIX_ISSUE_DIR/revisions/r1/comments.md")

  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  local second_size
  second_size=$(wc -c <"$FIX_ISSUE_DIR/revisions/r1/comments.md")

  [ "$first_size" = "$second_size" ]
  # Exactly one comments.md, no comments.md.1 or similar.
  local count
  count=$(find "$FIX_ISSUE_DIR/revisions" -name 'comments*' | wc -l)
  [ "$count" -eq 1 ]
}

@test "comments errors when mr_url is missing from state" {
  # Rewrite state without mr_url.
  cat >"$FIX_STATE_FILE" <<EOF
active_issue = "Issue-676"
issue_dir    = "$FIX_ISSUE_DIR"
revision     = 1
EOF
  run_comments volk Issue-676
  [ "$status" -ne 0 ]
  [[ "$output" == *"mr_url"* ]]
  [[ "$output" == *"ship"* ]]
}

@test "comments appends a log entry naming the step" {
  run_comments volk Issue-676
  [ "$status" -eq 0 ]
  grep -q 'comments: fetched' "$FIX_ISSUE_DIR/checklist.md"
}

@test "comments cleans up the partial file when backend exits non-zero" {
  cat >"$DEVAGENT_CODE_BACKEND_CMD" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
EOF
  chmod +x "$DEVAGENT_CODE_BACKEND_CMD"

  run_comments volk Issue-676
  [ "$status" -ne 0 ]
  [ ! -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]
}
```

- [ ] **Step 2: Run the test, verify all fail**

Run: `cd /home/user/src/devAgent && bats tests/comments.bats`
Expected: FAIL — `scripts/comments.sh` does not exist.

- [ ] **Step 3: Implement `scripts/comments.sh`**

Create `/home/user/src/devAgent/scripts/comments.sh`:

```bash
#!/usr/bin/env bash
#
# /devagent:comments — fetch MR comments to <issue-dir>/revisions/r<N>/comments.md.
#
# Usage:  comments.sh [project] [issue]
#
# Reads `mr_url` from per-project state, invokes the code backend's
# mr-comments verb, and writes the output without incrementing the
# revision counter. Idempotent: a re-run overwrites the same file.

set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/revision.sh"

die() {
  printf 'comments: %s\n' "$*" >&2
  exit 1
}

state_value() {
  # state_value <project> <key>
  local project="$1" key="$2"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  [[ -f "$state" ]] || return 1
  awk -F'=' -v key="$key" '
    $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$state"
}

config_value() {
  # config_value <project> <dotted-key> — minimalist TOML lookup.
  local project="$1" key="$2"
  local cfg="$HOME/.claude/devagent/config.toml"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" "$project" "$key" <<'PY'
import sys, re
cfg, project, key = sys.argv[1], sys.argv[2], sys.argv[3]
section = None
target_section = f"project.{project}.code_source"
target_key = key
with open(cfg) as f:
    for line in f:
        line = line.strip()
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            section = m.group(1)
            continue
        if section == target_section and "=" in line:
            k, _, v = line.partition("=")
            if k.strip() == target_key:
                v = v.strip().strip('"').strip("'")
                print(v)
                sys.exit(0)
sys.exit(1)
PY
}

resolve_project_arg() {
  # Trivial: first positional or DEVAGENT_PROJECT or "default"
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return
  fi
  printf '%s\n' "${DEVAGENT_PROJECT:-default}"
}

main() {
  local project
  project=$(resolve_project_arg "$@")
  [[ $# -ge 1 ]] && shift || true
  # second positional is issue dir name; we trust state for the dir path
  # but accept the issue name for parity with the CLI grammar.
  local issue_arg="${1:-}"

  local issue_dir
  issue_dir=$(state_value "$project" issue_dir) \
    || die "no active_issue for project '$project' (state file missing or empty)"
  [[ -n "$issue_dir" ]] || die "issue_dir empty in state for project '$project'"

  if [[ -n "$issue_arg" ]]; then
    # Sanity-check the caller's intent matches state.
    case "$issue_dir" in
      */"$issue_arg") : ;;
      *) die "requested issue '$issue_arg' does not match active issue_dir '$issue_dir'" ;;
    esac
  fi

  local mr_url
  mr_url=$(state_value "$project" mr_url) || true
  [[ -n "$mr_url" ]] || die "mr_url not set in state — run /devagent:ship first"

  local n
  n=$(revision_current "$project")

  local rdir
  rdir=$(revision_dir "$issue_dir" "$n")
  mkdir -p "$rdir"

  local out="$rdir/comments.md"

  # Resolve backend command. Tests inject DEVAGENT_CODE_BACKEND_CMD.
  local backend_cmd="${DEVAGENT_CODE_BACKEND_CMD:-}"
  if [[ -z "$backend_cmd" ]]; then
    local backend
    backend=$(config_value "$project" backend) || die "code_source.backend missing in config"
    backend_cmd="$DEVAGENT_ROOT/scripts/code/${backend}.sh"
    [[ -x "$backend_cmd" ]] || die "backend script not executable: $backend_cmd"
  fi

  local tmp
  tmp="$(mktemp)"
  if ! "$backend_cmd" mr-comments "$mr_url" >"$tmp"; then
    rm -f "$tmp"
    die "backend mr-comments failed for $mr_url"
  fi
  mv "$tmp" "$out"

  local k
  k=$(grep -c '^### @' "$out" || true)

  # Log to checklist.md. Append a single line under ## Log.
  local stamp
  stamp=$(date '+%Y-%m-%d %H:%M')
  printf -- '- %s  comments: fetched %s comments\n' "$stamp" "$k" \
    >>"$issue_dir/checklist.md"

  printf 'comments: wrote %s (%s comments)\n' "$out" "$k"
}

main "$@"
```

- [ ] **Step 4: Make it executable**

```bash
chmod +x /home/user/src/devAgent/scripts/comments.sh
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `cd /home/user/src/devAgent && bats tests/comments.bats`
Expected: `6 tests, 0 failures`

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/comments.sh tests/comments.bats
git commit -s -m "$(cat <<'EOF'
feat(phase6): add /devagent:comments script

Fetches MR comments from the code backend and writes them to
<issue-dir>/revisions/r<N>/comments.md. Does not increment the revision
counter. Idempotent: overwrites the same path on re-run; cleans up the
partial file on backend failure.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `scripts/revise.sh` — increment revision, append checklist block, chain to `next`

**Files:**
- Create: `/home/user/src/devAgent/scripts/revise.sh`
- Test: `/home/user/src/devAgent/tests/revise.bats`

Contract:

- Argv: `[project] [issue] [--no-chain]`
- Requires `<issue-dir>/revisions/r<N>/comments.md` to exist (where `N = revision_current`); errors with "run /devagent:comments first" otherwise
- Increments `revision` in state file: `N → N+1`
- Creates `<issue-dir>/revisions/r<N+1>/`
- Appends `revision_block_text N+1` to `<issue-dir>/checklist.md` (preserves all prior content)
- Sets `last_comments_file = "<issue-dir>/revisions/r<N+1>/comments.md"` in state — note: the *new* revision's comments file path, which does not yet exist. Rationale: the operator runs `/devagent:comments` again at the end of the new revision cycle if reviewers post more feedback; meanwhile the `draft` skill on the new revision reads the *previous* revision's comments (N), which the script also records as `pending_comments_file = "<issue-dir>/revisions/r<N>/comments.md"`. This is the field consumed by `draft.sh` to populate `$NOTE`.
- Appends a log entry: `revise: revision <N+1> started, <K> comments to address`, where K is the count of `### @` headings in the *old* `r<N>/comments.md`
- Unless `--no-chain`: invokes `${DEVAGENT_CHAIN_CMD:-/devagent:next}` so the next session resumes from `draft`. Tests inject `DEVAGENT_CHAIN_CMD` to capture the call.

- [ ] **Step 1: Write the failing tests**

Create `/home/user/src/devAgent/tests/revise.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  # Seed a prior revision's comments.md so revise can proceed.
  mkdir -p "$FIX_ISSUE_DIR/revisions/r1"
  cat >"$FIX_ISSUE_DIR/revisions/r1/comments.md" <<'EOF'
# example/volk#842 — Comments

## Comments (3)

### @alice · 2026-05-20
nit
### @bob · 2026-05-20
nit
### @carol · 2026-05-21
nit
EOF
  stub_chain_recorder
}

run_revise() {
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" "$@"
}

@test "revise increments revision from 1 to 2 in state" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"
}

@test "revise creates revisions/r2 directory" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ -d "$FIX_ISSUE_DIR/revisions/r2" ]
}

@test "revise appends a new ## Revision 2 block to checklist.md" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^## Revision 2$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \]  1\. draft' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \] 15\. ship' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise preserves the original ## Revision 1 block" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^## Revision 1$' "$FIX_ISSUE_DIR/checklist.md"
  # Both blocks present; counts independent.
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 2 ]
}

@test "revise records the previous revision's comments as pending_comments_file" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q "^pending_comments_file[[:space:]]*=[[:space:]]*\"$FIX_ISSUE_DIR/revisions/r1/comments.md\"$" \
    "$FIX_STATE_FILE"
}

@test "revise logs the revision start with the comment count" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q 'revise: revision 2 started, 3 comments to address' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise errors when revisions/r<N>/comments.md is missing" {
  rm -f "$FIX_ISSUE_DIR/revisions/r1/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -ne 0 ]
  [[ "$output" == *"/devagent:comments"* ]]
  # State must not have advanced.
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}

@test "revise chains to /devagent:next by default" {
  run_revise volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/chain.log" ]
  grep -q '/devagent:next' "$BATS_TEST_TMPDIR/chain.log"
}

@test "revise does NOT chain when --no-chain is passed" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/chain.log" ]
}

@test "monotonic counter — two revisions advances 1->2->3" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  # Seed comments for revision 2 to allow a second revise.
  cp "$FIX_ISSUE_DIR/revisions/r1/comments.md" "$FIX_ISSUE_DIR/revisions/r2/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*3$' "$FIX_STATE_FILE"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 3 ]
}
```

- [ ] **Step 2: Run the tests, verify all fail**

Run: `cd /home/user/src/devAgent && bats tests/revise.bats`
Expected: FAIL — `scripts/revise.sh` does not exist.

- [ ] **Step 3: Implement `scripts/revise.sh`**

Create `/home/user/src/devAgent/scripts/revise.sh`:

```bash
#!/usr/bin/env bash
#
# /devagent:revise — start a new revision pass after MR feedback.
#
# Usage:  revise.sh [project] [issue] [--no-chain]
#
# Preconditions: revisions/r<N>/comments.md must exist (run /devagent:comments).
#
# Effects:
#   - revision in state: N -> N+1
#   - mkdir -p <issue-dir>/revisions/r<N+1>
#   - append "## Revision <N+1>" block to checklist.md
#   - set pending_comments_file = <issue-dir>/revisions/r<N>/comments.md
#   - append log entry naming step "revise"
#   - unless --no-chain, exec ${DEVAGENT_CHAIN_CMD:-/devagent:next}

set -euo pipefail

DEVAGENT_ROOT="${DEVAGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=/dev/null
source "$DEVAGENT_ROOT/scripts/lib/revision.sh"

die() {
  printf 'revise: %s\n' "$*" >&2
  exit 1
}

state_value() {
  local project="$1" key="$2"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  [[ -f "$state" ]] || return 1
  awk -F'=' -v key="$key" '
    $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$state"
}

state_set() {
  # state_set <project> <key> <value>
  # Replaces existing key or appends. Quotes <value>.
  local project="$1" key="$2" value="$3"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  local tmp
  tmp="$(mktemp)"
  local found=0
  if [[ -f "$state" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
        printf '%s = "%s"\n' "$key" "$value" >>"$tmp"
        found=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$state"
  fi
  if [[ $found -eq 0 ]]; then
    printf '%s = "%s"\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$state"
}

state_set_int() {
  # state_set_int <project> <key> <int> — like state_set but no quotes.
  local project="$1" key="$2" value="$3"
  local state="$HOME/.claude/devagent/state/${project}.toml"
  local tmp
  tmp="$(mktemp)"
  local found=0
  if [[ -f "$state" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
        printf '%s = %s\n' "$key" "$value" >>"$tmp"
        found=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$state"
  fi
  if [[ $found -eq 0 ]]; then
    printf '%s = %s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$state"
}

# Parse argv: optional project, optional issue, optional --no-chain.
PROJECT=""
ISSUE=""
NO_CHAIN=0
for arg in "$@"; do
  case "$arg" in
    --no-chain) NO_CHAIN=1 ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$arg"
      elif [[ -z "$ISSUE" ]]; then
        ISSUE="$arg"
      fi
      ;;
  esac
done
[[ -n "$PROJECT" ]] || PROJECT="${DEVAGENT_PROJECT:-default}"

issue_dir=$(state_value "$PROJECT" issue_dir) \
  || die "no active_issue for project '$PROJECT'"
[[ -n "$issue_dir" ]] || die "issue_dir empty in state for project '$PROJECT'"

if [[ -n "$ISSUE" ]]; then
  case "$issue_dir" in
    */"$ISSUE") : ;;
    *) die "requested issue '$ISSUE' does not match active issue_dir '$issue_dir'" ;;
  esac
fi

n_cur=$(revision_current "$PROJECT")
prev_rdir=$(revision_dir "$issue_dir" "$n_cur")
prev_comments="$prev_rdir/comments.md"

if [[ ! -f "$prev_comments" ]]; then
  die "missing $prev_comments — run /devagent:comments first"
fi

n_new=$((n_cur + 1))
new_rdir=$(revision_dir "$issue_dir" "$n_new")
mkdir -p "$new_rdir"

# Append the new revision block (template includes its own leading blank line).
revision_block_text "$n_new" >>"$issue_dir/checklist.md"

# Record state.
state_set_int "$PROJECT" revision "$n_new"
state_set "$PROJECT" pending_comments_file "$prev_comments"

# Log entry — count comments in the *previous* file (the work to address).
k=$(grep -c '^### @' "$prev_comments" || true)
stamp=$(date '+%Y-%m-%d %H:%M')
printf -- '- %s  revise: revision %s started, %s comments to address\n' \
  "$stamp" "$n_new" "$k" >>"$issue_dir/checklist.md"

printf 'revise: advanced to revision %s (%s comments pending)\n' "$n_new" "$k"

if [[ "$NO_CHAIN" -eq 0 ]]; then
  chain_cmd="${DEVAGENT_CHAIN_CMD:-/devagent:next}"
  # If chain_cmd looks like a slash command, emit a sentinel line the harness
  # consumes. If it's a path to an executable (tests), exec it.
  if [[ -x "$chain_cmd" ]]; then
    "$chain_cmd" /devagent:next
  else
    printf 'CHAIN: %s\n' "$chain_cmd"
  fi
fi
```

- [ ] **Step 4: Make it executable**

```bash
chmod +x /home/user/src/devAgent/scripts/revise.sh
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `cd /home/user/src/devAgent && bats tests/revise.bats`
Expected: `10 tests, 0 failures`

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/revise.sh tests/revise.bats
git commit -s -m "$(cat <<'EOF'
feat(phase6): add /devagent:revise script

Increments revision counter, appends a fresh "## Revision N" block to
checklist.md (steps 1-15 only; 0 and 16-20 are not re-run), records the
previous revision's comments.md as pending_comments_file for the draft
skill to consume, logs the start, and chains to /devagent:next unless
--no-chain is passed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Slash command files

**Files:**
- Create: `/home/user/src/devAgent/commands/comments.md`
- Create: `/home/user/src/devAgent/commands/revise.md`

Two thin Markdown wrappers per Claude Code plugin convention. They invoke the scripts and pass through `$ARGUMENTS`.

- [ ] **Step 1: Create `commands/comments.md`**

Create `/home/user/src/devAgent/commands/comments.md`:

````markdown
---
description: Fetch MR comments to <issue-dir>/revisions/r<N>/comments.md
argument-hint: "[project] [issue]"
allowed-tools: Bash
---

Run the comments script and report the result.

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/comments.sh" $ARGUMENTS
```

After it runs:
- Confirm `<issue-dir>/revisions/r<N>/comments.md` exists and report the comment count.
- If the script exited non-zero because `mr_url` is unset, tell the user to run `/devagent:ship` first.
- Do not invoke any other commands — `comments` does not chain.
````

- [ ] **Step 2: Create `commands/revise.md`**

Create `/home/user/src/devAgent/commands/revise.md`:

````markdown
---
description: Start a new revision pass; appends "## Revision N" to checklist and chains to /devagent:next
argument-hint: "[project] [issue] [--no-chain]"
allowed-tools: Bash
---

Run the revise script and report the result.

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/revise.sh" $ARGUMENTS
```

Then:
- If the script prints a line starting with `CHAIN: `, treat the remainder as the next slash command to invoke. Per spec §7, the same `--auto` semantics that govern `/devagent:next` apply transitively here: if the operator passed `--auto` upstream, continue chaining; otherwise pause and ask.
- If the script exited non-zero because `revisions/r<N>/comments.md` is missing, tell the user to run `/devagent:comments` first.
- The next step on the new revision is `draft` (step 1). The `draft` skill reads `pending_comments_file` from per-project state and includes those comments as user-intent context in the new plan.
````

- [ ] **Step 3: Verify both files exist and have frontmatter**

Run:
```bash
cd /home/user/src/devAgent
head -5 commands/comments.md commands/revise.md
```
Expected: each file begins with `---` and a `description:` line.

- [ ] **Step 4: Commit**

```bash
cd /home/user/src/devAgent
git add commands/comments.md commands/revise.md
git commit -s -m "$(cat <<'EOF'
feat(phase6): add /devagent:comments and /devagent:revise slash commands

Thin Markdown wrappers around scripts/comments.sh and scripts/revise.sh.
revise emits a CHAIN: line that the harness translates into a chained
/devagent:next invocation when --auto is in effect.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Full-cycle integration test (comments → revise → comments → revise)

**Files:**
- Test: `/home/user/src/devAgent/tests/revision_cycle.bats`

End-to-end test that exercises a two-revision cycle and asserts the invariants from the plan brief: idempotence of comments, monotonic revision counter, and checklist history preservation.

- [ ] **Step 1: Write the integration test**

Create `/home/user/src/devAgent/tests/revision_cycle.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/fixtures'

setup() {
  fixture_init volk Issue-676
  stub_chain_recorder
}

@test "two-cycle: comments,revise,comments,revise leaves state revision=3 and 3 ## Revision blocks" {
  # Cycle 1 — comments lands in r1, revise advances to r2.
  stub_mr_comments "$(cat <<'P1'
### @alice · 2026-05-20
first round nit
P1
)"
  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$FIX_ISSUE_DIR/revisions/r1/comments.md" ]

  # Re-run comments — must be idempotent, no r1.1 or r2 created yet.
  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [ ! -d "$FIX_ISSUE_DIR/revisions/r2" ]
  [ "$(find "$FIX_ISSUE_DIR/revisions" -name 'comments*' | wc -l)" -eq 1 ]

  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"

  # Cycle 2 — new reviewer feedback in r2, revise advances to r3.
  stub_mr_comments "$(cat <<'P2'
### @alice · 2026-05-21
second round
### @bob · 2026-05-21
also second round
P2
)"
  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CODE_BACKEND_CMD="$DEVAGENT_CODE_BACKEND_CMD" \
    bash "$DEVAGENT_ROOT/scripts/comments.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$FIX_ISSUE_DIR/revisions/r2/comments.md" ]

  run env HOME="$HOME" DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" volk Issue-676 --no-chain
  [ "$status" -eq 0 ]

  # Invariant: monotonic counter.
  grep -q '^revision[[:space:]]*=[[:space:]]*3$' "$FIX_STATE_FILE"

  # Invariant: history preservation — original Revision 1 still present,
  # plus the two appended blocks.
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 3 ]
  grep -q '^## Revision 1$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '^## Revision 2$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '^## Revision 3$' "$FIX_ISSUE_DIR/checklist.md"

  # Invariant: log is shared (chronological), not split per revision.
  # Both revise log lines appear under the single ## Log section.
  local log_section
  log_section=$(awk '/^## Log/{flag=1; next} /^## /{flag=0} flag' "$FIX_ISSUE_DIR/checklist.md")
  printf '%s\n' "$log_section" | grep -q 'revise: revision 2 started'
  printf '%s\n' "$log_section" | grep -q 'revise: revision 3 started'

  # Invariant: pending_comments_file points at the most recent prior comments.
  grep -q "^pending_comments_file[[:space:]]*=[[:space:]]*\"$FIX_ISSUE_DIR/revisions/r2/comments.md\"$" \
    "$FIX_STATE_FILE"
}
```

- [ ] **Step 2: Run the integration test**

Run: `cd /home/user/src/devAgent && bats tests/revision_cycle.bats`
Expected: `1 test, 0 failures`

- [ ] **Step 3: Run the full Phase 6 test suite**

Run: `cd /home/user/src/devAgent && bats tests/fixtures_smoke.bats tests/revision_lib.bats tests/comments.bats tests/revise.bats tests/revision_cycle.bats`
Expected: all tests pass (22 total: 2 + 4 + 6 + 10 + 1, though the final number depends on actual implementations).

- [ ] **Step 4: Commit**

```bash
cd /home/user/src/devAgent
git add tests/revision_cycle.bats
git commit -s -m "$(cat <<'EOF'
test(phase6): add two-cycle integration test for revision family

Exercises comments -> revise -> comments -> revise end-to-end and
asserts the three invariants from the plan brief: comments is
idempotent, the revision counter is monotonic, and checklist.md
preserves Revision 1 across revisions with a shared chronological log.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes (for the executor)

The following spec requirements were checked against this plan:

- §3.5 (`revisions/r<N>/`) — covered by Tasks 3 and 4 (mkdir; comments.md path).
- §6.4 (Family C table) — both commands implemented in Tasks 3-5.
- §7 (`--auto` chaining) — Task 4 implementation emits `CHAIN: /devagent:next` line; Task 5 `revise.md` documents that the same `--auto` semantics flow through.
- §16 (Revision flow) — explicit: comments first; revise increments + appends + chains; original Revision 1 entries remain; log shared across revisions. All asserted in Task 6.

Known plumbing dependency:

- The `pending_comments_file` field is the contract `draft.sh` (Phase 4) consumes. This plan writes it; the consumer is *not* in scope here. If Phase 4 has already shipped without that consumer, file a follow-up to add the read; do not edit `draft.sh` from this phase.

## Open questions

1. **`pending_comments_file` field name** — chose this over `last_comments_file` because "last" is ambiguous (last of which revision?). If Phase 4's plan already references a different name, rename in this plan rather than fork.
2. **Chain mechanism** — the `CHAIN: <cmd>` stdout convention is a guess at how Phase 2's harness will detect chain requests. If Phase 2 settled on a different mechanism (exit code, sentinel file, JSON line), adjust Task 4 Step 3 accordingly. The behavior contract (revise *attempts* to chain to `/devagent:next` unless `--no-chain`) does not change.
3. **`config.toml` lookup in `comments.sh`** — uses an inline Python TOML reader because Phase 1's `config_get` helper signature is not pinned in this spec. If Phase 1 ships `config_get`, replace the Python block with a one-line call.
4. **Step 0 (pull) on revision** — spec §16 says "steps 1–15 re-listed"; step 0 is intentionally omitted (no need to re-fetch the issue body on revision). Confirm with the spec author that the comments fetch satisfies the "what changed since last pass" need on revisions.
