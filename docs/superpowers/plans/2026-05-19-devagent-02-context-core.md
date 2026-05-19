# devAgent Plan 02 — Context Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the "context preservation" value prop (spec §1, item 1) — slash commands and scripts that let an operator drop an issue, work elsewhere for a week, and resume with no loss of state.

**Architecture:** Bash scripts under `scripts/` provide the executable surface (positional-arg parser, pull, where, next, status, catchup, stuck/unstuck, park/resume/switch). Each script consumes the foundation libraries from Plan 1 (config loader, state, checklist, log). One slash-command markdown file per verb under `commands/` wraps each script. Issue backend `github.sh fetch` verb is the single backend Plan 2 ships; other backends are Plan 10.

**Tech Stack:** Bash 5+, `gh` CLI (stubbed in tests), `bats-core` for shell tests, `pytest` for any Python helpers, TOML state files consumed via Plan 1's `state` library.

**Dependencies on Plan 1 (`2026-05-19-devagent-01-foundation.md`):**

- `scripts/lib/config.sh` — `config_get_project_field <project> <key>`, `config_list_projects`, `config_active_project`
- `scripts/lib/state.sh` — `state_get <project> <key>`, `state_set <project> <key> <value>`, `state_unset <project> <key>`, `state_list_parked <project>`, `state_add_parked <project> <issue>`, `state_remove_parked <project> <issue>`
- `scripts/lib/checklist.sh` — `checklist_init <issue-dir> <template>`, `checklist_current_step <file>`, `checklist_step_state <file> <step-num>`, `checklist_mark <file> <step-num> <glyph>`, `checklist_step_name <file> <step-num>`
- `scripts/lib/log.sh` — `log_append <issue-dir> <step-name> <message>`, `log_tail <issue-dir> <N>`
- `scripts/lib/io.sh` — `die <msg>`, `info <msg>`, `warn <msg>`, `confirm <prompt>` (returns 0 on Y/Enter)
- `templates/checklist-standard.md` — 21-step checklist body Plan 1 ships at `templates/` root; this plan references it but does not create it
- `tests/lib/bats-helpers.bash` — `setup_tmp_devagent_home` (creates ephemeral `~/.claude/devagent/` tree)

**Forward references:**

- Plan 3 implements `branch.sh`, `commit.sh`, `analyze-static.sh`, `ship.sh`, `mergetoall.sh`, `cleanup.sh`, `sync.sh`. Plan 2's `next.sh` dispatches by step name; for steps Plan 3 owns, it prints "step <N> is a Plan 3 verb — not yet wired" until Plan 3 lands.
- Plan 4 implements skill-type workflow verbs (draft, scope, …). `next.sh` handles those identically until Plan 4 lands.
- Plan 10 implements `issue/gitlab.sh`, `issue/jira.sh`, `issue/custom.sh`. Plan 2 ships `issue/github.sh fetch` only.

**Out of scope for Plan 2:** any workflow-execution work beyond dispatching to step scripts; capture/reap family; revisions; auth subsystem; backends other than GitHub; the `fetch` verb's `create`/`transition`/`state`/`comment-list` subcommands.

---

## File Structure

**Create:**
- `scripts/lib/parse-args.sh` — invocation grammar parser (spec §6.1)
- `scripts/issue/github.sh` — issue backend, `fetch` verb only in this plan
- `scripts/pull.sh` — workflow step 0
- `scripts/where.sh` — Family D
- `scripts/next.sh` — Family D
- `scripts/status.sh` — Family D
- `scripts/catchup.sh` — Family D
- `scripts/stuck.sh` — Family D
- `scripts/unstuck.sh` — Family D
- `scripts/park.sh` — Family D
- `scripts/resume.sh` — Family D
- `scripts/switch.sh` — Family D (sugar)
- `commands/devagent:pull.md`
- `commands/devagent:where.md`
- `commands/devagent:next.md`
- `commands/devagent:status.md`
- `commands/devagent:catchup.md`
- `commands/devagent:stuck.md`
- `commands/devagent:unstuck.md`
- `commands/devagent:park.md`
- `commands/devagent:resume.md`
- `commands/devagent:switch.md`
- `templates/issue.md.skel` — empty-issue-dir skeleton
- `tests/parse-args.bats`
- `tests/issue-github.bats`
- `tests/pull.bats`
- `tests/where.bats`
- `tests/next.bats`
- `tests/status.bats`
- `tests/catchup.bats`
- `tests/stuck-unstuck.bats`
- `tests/park-resume-switch.bats`
- `tests/fixtures/gh-stub` — fake `gh` CLI binary used by `issue/github.sh` tests
- `tests/fixtures/config-twoproject.toml` — minimal two-project fixture

**Modify:** none. Plan 2 does not edit Plan 1 files; if a missing helper is discovered, the task adds it under `scripts/lib/` with a test.

---

## Task 1: Invocation grammar parser

**Files:**
- Create: `scripts/lib/parse-args.sh`
- Test: `tests/parse-args.bats`

Implements spec §6.1: positional `[project] [issue-dir] [note...]`, `--` escape hatch, defaults from state.

- [ ] **Step 1.1: Write the failing test**

Create `tests/parse-args.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  # Fixture config with two projects
  cp "$PLUGIN_ROOT/tests/fixtures/config-twoproject.toml" \
     "$DEVAGENT_HOME/config.toml"
  source "$PLUGIN_ROOT/scripts/lib/parse-args.sh"
}

@test "parses bare project name" {
  parse_devagent_args volk
  [ "$DA_PROJECT" = "volk" ]
  [ -z "$DA_ISSUE" ]
  [ -z "$DA_NOTE" ]
}

@test "parses project + issue + note" {
  parse_devagent_args volk Issue-676 ship despite lint warning
  [ "$DA_PROJECT" = "volk" ]
  [ "$DA_ISSUE" = "Issue-676" ]
  [ "$DA_NOTE" = "ship despite lint warning" ]
}

@test "parses Issue-Fork-N form" {
  parse_devagent_args volk Issue-Fork-42
  [ "$DA_ISSUE" = "Issue-Fork-42" ]
}

@test "-- separator stops positional consumption" {
  parse_devagent_args volk -- please ship despite the lint warning
  [ "$DA_PROJECT" = "volk" ]
  [ -z "$DA_ISSUE" ]
  [ "$DA_NOTE" = "please ship despite the lint warning" ]
}

@test "unknown first token becomes note when only one project configured" {
  # Trim fixture to one project
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
source_dir = "/tmp/volk"
EOF
  parse_devagent_args random words here
  [ "$DA_PROJECT" = "volk" ]
  [ "$DA_NOTE" = "random words here" ]
}

@test "no args with one configured project picks that project" {
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
source_dir = "/tmp/volk"
EOF
  parse_devagent_args
  [ "$DA_PROJECT" = "volk" ]
}

@test "no args with multiple projects and no active falls back to empty" {
  parse_devagent_args
  [ -z "$DA_PROJECT" ]
}

@test "no args with active project uses active" {
  echo 'active_project = "other"' > "$DEVAGENT_HOME/state/_global.toml"
  parse_devagent_args
  [ "$DA_PROJECT" = "other" ]
}
```

- [ ] **Step 1.2: Run test to verify it fails**

Run: `bats tests/parse-args.bats`
Expected: every test FAILs with `parse-args.sh: No such file or directory` (or `parse_devagent_args: command not found`).

- [ ] **Step 1.3: Write minimal implementation**

Create `scripts/lib/parse-args.sh`:

```bash
#!/usr/bin/env bash
# parse-args.sh — invocation grammar for /devagent:<verb> [project] [issue] [note...]
# Spec §6.1. Sets DA_PROJECT, DA_ISSUE, DA_NOTE in caller's scope.
# Requires scripts/lib/config.sh and scripts/lib/state.sh sourced or on PATH.

# Resolve sibling lib files relative to this script
_PA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_PA_LIB_DIR/config.sh"
# shellcheck source=/dev/null
source "$_PA_LIB_DIR/state.sh"

parse_devagent_args() {
  DA_PROJECT=""
  DA_ISSUE=""
  DA_NOTE=""

  local -a positional=()
  local seen_sep=0
  while (( $# > 0 )); do
    if [[ "$1" == "--" && $seen_sep -eq 0 ]]; then
      seen_sep=1
      shift
      continue
    fi
    positional+=("$1")
    shift
  done

  local idx=0
  # Token 1: project?
  if (( ${#positional[@]} > idx )) && [[ $seen_sep -eq 0 ]]; then
    if config_is_project "${positional[$idx]}"; then
      DA_PROJECT="${positional[$idx]}"
      idx=$((idx + 1))
    fi
  fi

  # Token 2: issue?
  if (( ${#positional[@]} > idx )) && [[ $seen_sep -eq 0 ]]; then
    if [[ "${positional[$idx]}" =~ ^Issue(-Fork)?-[0-9]+$ ]]; then
      DA_ISSUE="${positional[$idx]}"
      idx=$((idx + 1))
    fi
  fi

  # Remaining tokens → note
  if (( ${#positional[@]} > idx )); then
    DA_NOTE="${positional[*]:$idx}"
  fi

  # Default project when omitted
  if [[ -z "$DA_PROJECT" ]]; then
    local active
    active="$(state_active_project 2>/dev/null || true)"
    if [[ -n "$active" ]]; then
      DA_PROJECT="$active"
    else
      local -a all
      mapfile -t all < <(config_list_projects)
      if (( ${#all[@]} == 1 )); then
        DA_PROJECT="${all[0]}"
      fi
    fi
  fi

  # Default issue from active_issue for the resolved project
  if [[ -z "$DA_ISSUE" && -n "$DA_PROJECT" ]]; then
    local ai
    ai="$(state_get "$DA_PROJECT" active_issue 2>/dev/null || true)"
    [[ -n "$ai" && "$ai" != "null" ]] && DA_ISSUE="$ai"
  fi
}
```

- [ ] **Step 1.4: Add the helper used by the parser if Plan 1 did not ship them**

If `config_is_project` or `state_active_project` does not exist in Plan 1, add them with their own tests. Inspect Plan 1's `scripts/lib/config.sh` first:

```bash
grep -n 'config_is_project\|state_active_project' scripts/lib/*.sh tests/lib/*.bash 2>&1 || true
```

If absent, append to `scripts/lib/config.sh`:

```bash
# True if the given name is a configured project in config.toml.
config_is_project() {
  local name="$1"
  local -a all
  mapfile -t all < <(config_list_projects)
  local p
  for p in "${all[@]}"; do
    [[ "$p" == "$name" ]] && return 0
  done
  return 1
}
```

And append to `scripts/lib/state.sh`:

```bash
# Active *project* (not active_issue). Stored in state/_global.toml.
state_active_project() {
  local f="${DEVAGENT_HOME:-$HOME/.claude/devagent}/state/_global.toml"
  [[ -f "$f" ]] || return 0
  awk -F' *= *' '/^active_project[[:space:]]*=/ { gsub(/"/, "", $2); print $2; exit }' "$f"
}
```

- [ ] **Step 1.5: Create the two-project fixture**

Create `tests/fixtures/config-twoproject.toml`:

```toml
[defaults]
checklist_template = "standard"

[project.volk]
source_dir = "/tmp/volk"
devdoc_dir = "/tmp/devDoc/volk"

[project.other]
source_dir = "/tmp/other"
devdoc_dir = "/tmp/devDoc/other"
```

- [ ] **Step 1.6: Run tests to verify they pass**

Run: `bats tests/parse-args.bats`
Expected: 8 tests PASS.

- [ ] **Step 1.7: Commit**

```bash
git add scripts/lib/parse-args.sh scripts/lib/config.sh scripts/lib/state.sh \
        tests/parse-args.bats tests/fixtures/config-twoproject.toml
git commit -s -m "$(cat <<'EOF'
feat(parse-args): add /devagent invocation grammar parser

Implements spec §6.1: positional [project] [issue] [note...] with --
escape hatch, defaults from active project / active_issue state.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Issue backend — `github.sh fetch`

**Files:**
- Create: `scripts/issue/github.sh`
- Create: `tests/issue-github.bats`
- Create: `tests/fixtures/gh-stub`

Spec §9.1 (contract), §9.3 (markdown shape), §9.4 (wraps `gh`). Plan 2 ships only the `fetch` verb. Other verbs print "not implemented in Plan 2" and exit 64.

- [ ] **Step 2.1: Write the failing test**

Create `tests/issue-github.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  # Put stub gh on PATH
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  # Tell stub what fixture to print
  export GH_STUB_CASE="standard"
}

@test "fetch prints the spec-shaped markdown" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"# gnuradio/volk#676 — Demo issue title"* ]]
  [[ "$output" == *"- State: open"* ]]
  [[ "$output" == *"- Author: @alice"* ]]
  [[ "$output" == *"- Labels: bug, performance"* ]]
  [[ "$output" == *"- URL: https://github.com/gnuradio/volk/issues/676"* ]]
  [[ "$output" == *"Body line one."* ]]
  [[ "$output" == *"## Comments (1)"* ]]
  [[ "$output" == *"### @bob · 2026-05-12"* ]]
  [[ "$output" == *"First comment."* ]]
}

@test "fetch with zero comments still prints Comments (0) header" {
  export GH_STUB_CASE="nocomments"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 676
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Comments (0)"* ]]
}

@test "fetch propagates gh failure" {
  export GH_STUB_CASE="fail"
  run "$PLUGIN_ROOT/scripts/issue/github.sh" fetch gnuradio/volk 999
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh issue view failed"* ]]
}

@test "unimplemented verb returns 64 with helpful message" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" create gnuradio/volk "title" /tmp/b
  [ "$status" -eq 64 ]
  [[ "$output" == *"not implemented"* ]]
}

@test "unknown verb returns 64" {
  run "$PLUGIN_ROOT/scripts/issue/github.sh" nonsense
  [ "$status" -eq 64 ]
}
```

- [ ] **Step 2.2: Create the gh stub fixture**

Create `tests/fixtures/gh-stub`:

```bash
#!/usr/bin/env bash
# Stub `gh` for tests. Honors GH_STUB_CASE env var.
# Supported: standard, nocomments, fail.

case "$GH_STUB_CASE" in
  fail)
    echo "stub-gh: simulated failure" >&2
    exit 1
    ;;
  nocomments)
    cat <<'JSON'
{
  "title": "Demo issue title",
  "state": "OPEN",
  "author": {"login": "alice"},
  "labels": [{"name": "bug"}, {"name": "performance"}],
  "url": "https://github.com/gnuradio/volk/issues/676",
  "body": "Body line one.\n\nBody line two.",
  "comments": []
}
JSON
    ;;
  *)
    cat <<'JSON'
{
  "title": "Demo issue title",
  "state": "OPEN",
  "author": {"login": "alice"},
  "labels": [{"name": "bug"}, {"name": "performance"}],
  "url": "https://github.com/gnuradio/volk/issues/676",
  "body": "Body line one.\n\nBody line two.",
  "comments": [
    {"author": {"login": "bob"}, "createdAt": "2026-05-12T08:14:22Z", "body": "First comment."}
  ]
}
JSON
    ;;
esac
```

- [ ] **Step 2.3: Run tests to verify they fail**

Run: `bats tests/issue-github.bats`
Expected: all 5 tests FAIL with "github.sh: No such file or directory".

- [ ] **Step 2.4: Write the implementation**

Create `scripts/issue/github.sh`:

```bash
#!/usr/bin/env bash
# scripts/issue/github.sh — GitHub issue backend.
# Plan 2 implements only the `fetch` verb. Other verbs land in later plans.
# Spec §9.1 (contract), §9.3 (markdown shape).

set -euo pipefail

_die() { echo "$*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "$1 not found on PATH"; }

cmd_fetch() {
  local repo="${1:?repo required}"
  local num="${2:?issue number required}"
  _need gh
  _need jq

  local json
  if ! json="$(gh issue view "$num" --repo "$repo" --json \
    title,state,author,labels,url,body,comments 2>&1)"; then
    echo "gh issue view failed: $json" >&2
    return 1
  fi

  # Render with jq into the spec §9.3 shape.
  printf '%s' "$json" | jq -r --arg repo "$repo" --arg num "$num" '
    def label_csv:
      if (.labels|length) == 0 then "" else
        (.labels | map(.name) | join(", "))
      end;
    def comment_block:
      .comments | map(
        "### @" + (.author.login // "unknown")
        + " · " + ((.createdAt // "") | split("T")[0])
        + "\n\n" + (.body // "")
      ) | join("\n\n");

    "# " + $repo + "#" + $num + " — " + (.title // "(no title)") + "\n\n"
    + "- State: " + ((.state // "unknown") | ascii_downcase) + "\n"
    + "- Author: @" + (.author.login // "unknown") + "\n"
    + "- Labels: " + label_csv + "\n"
    + "- URL: " + (.url // "") + "\n\n"
    + "---\n\n"
    + (.body // "") + "\n\n"
    + "---\n\n"
    + "## Comments (" + ((.comments | length) | tostring) + ")\n"
    + (if (.comments | length) > 0 then "\n" + comment_block + "\n" else "" end)
  '
}

main() {
  local verb="${1:-}"
  shift || true
  case "$verb" in
    fetch)        cmd_fetch "$@" ;;
    create|transition|state|comment-list)
      echo "issue/github.sh: '$verb' not implemented in Plan 2 (lands in later plan)" >&2
      exit 64
      ;;
    *)
      echo "issue/github.sh: unknown verb '${verb:-<none>}'" >&2
      exit 64
      ;;
  esac
}

main "$@"
```

- [ ] **Step 2.5: Run tests to verify they pass**

Run: `bats tests/issue-github.bats`
Expected: 5 tests PASS.

- [ ] **Step 2.6: Commit**

```bash
git add scripts/issue/github.sh tests/issue-github.bats tests/fixtures/gh-stub
git commit -s -m "$(cat <<'EOF'
feat(issue/github): add fetch verb wrapping gh CLI

Implements spec §9.1 fetch contract and §9.3 markdown shape via gh +
jq. Other verbs (create, transition, state, comment-list) deferred to
later plans; they exit 64 with a helpful message.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `scripts/pull.sh` — workflow step 0

**Files:**
- Create: `scripts/pull.sh`
- Create: `templates/issue.md.skel`
- Create: `tests/pull.bats`
- Create: `commands/devagent:pull.md`

Spec §6.3 row 0: scaffolds the per-issue directory (spec §3.5), calls `issue/<backend>.sh fetch`, writes `issue.md`, marks step 0 done in checklist, logs.

Argument form per task brief: `/devagent:pull [project] origin|fork <num>`. The `origin|fork` token selects between `[project.<n>.issue_source]` and `[project.<n>.issue_source_fork]`.

- [ ] **Step 3.1: Write the failing test**

Create `tests/pull.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"

  # Config with both origin and fork issue sources
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.issue_source_fork]
backend = "github"
repo = "mtibbits/volk"
dir_prefix = "Issue-Fork-"
EOF
}

@test "pull origin scaffolds Issue-N dir and writes issue.md" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-676" ]
  [ -f "$DEVDOC/Issue-676/issue.md" ]
  [ -f "$DEVDOC/Issue-676/checklist.md" ]
  grep -q "gnuradio/volk#676" "$DEVDOC/Issue-676/issue.md"
}

@test "pull fork uses dir_prefix Issue-Fork-" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk fork 42
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-Fork-42" ]
}

@test "pull marks step 0 done in checklist" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -E '^\- \[x\] +0\. pull' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull appends a log entry naming the source and issue" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -E 'pull: fetched gnuradio/volk#676' "$DEVDOC/Issue-676/checklist.md"
}

@test "pull sets state.active_issue and state.issue_dir" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -q 'active_issue *= *"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
  grep -q "issue_dir *= *\"$DEVDOC/Issue-676\"" "$DEVAGENT_HOME/state/volk.toml"
}

@test "pull is idempotent on issue.md (refetch overwrites, checklist preserved)" {
  "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  # Tamper with the checklist so we can prove it wasn't blown away
  printf '\nUSER-EDIT\n' >> "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]
  grep -q "USER-EDIT" "$DEVDOC/Issue-676/checklist.md"
}

@test "pull rejects missing origin|fork token" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk 676
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin|fork"* ]]
}

@test "pull rejects non-numeric issue number" {
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin notanumber
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3.2: Run tests to verify they fail**

Run: `bats tests/pull.bats`
Expected: 8 tests FAIL with "pull.sh: No such file or directory".

- [ ] **Step 3.3: Create the empty-issue-dir skeleton**

Create `templates/issue.md.skel`:

```markdown
# (issue.md placeholder)

This file is replaced by `scripts/pull.sh` with the fetched issue body.
If you are reading this, `pull` failed mid-flight; rerun `/devagent:pull`.
```

- [ ] **Step 3.4: Write `scripts/pull.sh`**

Create `scripts/pull.sh`:

```bash
#!/usr/bin/env bash
# scripts/pull.sh — workflow step 0: fetch issue, scaffold Issue dir.
# Spec §3.5, §6.3 row 0.
# Usage: pull.sh <project> <origin|fork> <issue-num>

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

main() {
  local project="${1:-}"
  local source="${2:-}"
  local num="${3:-}"

  [[ -n "$project" ]] || die "pull.sh: project required"
  [[ "$source" == "origin" || "$source" == "fork" ]] \
    || die "pull.sh: second arg must be origin|fork, got: '${source:-<none>}'"
  [[ "$num" =~ ^[0-9]+$ ]] \
    || die "pull.sh: issue number must be numeric, got: '${num:-<none>}'"

  local section
  if [[ "$source" == "origin" ]]; then
    section="issue_source"
  else
    section="issue_source_fork"
  fi

  local backend repo dir_prefix devdoc template
  backend="$(config_get_project_field "$project" "${section}.backend")"
  repo="$(config_get_project_field "$project" "${section}.repo")"
  dir_prefix="$(config_get_project_field "$project" "${section}.dir_prefix")"
  devdoc="$(config_get_project_field "$project" "devdoc_dir")"
  template="$(config_get_project_field "$project" "checklist_template" || echo standard)"
  [[ -n "$template" ]] || template="standard"

  [[ -n "$backend" ]]    || die "pull.sh: $section.backend not configured for $project"
  [[ -n "$repo" ]]       || die "pull.sh: $section.repo not configured for $project"
  [[ -n "$dir_prefix" ]] || die "pull.sh: $section.dir_prefix not configured for $project"
  [[ -n "$devdoc" ]]     || die "pull.sh: devdoc_dir not configured for $project"

  local issue_id="${dir_prefix}${num}"
  local issue_dir="${devdoc%/}/${issue_id}"
  mkdir -p "$issue_dir"

  # Fetch issue body
  local backend_script="$PLUGIN_ROOT/scripts/issue/${backend}.sh"
  [[ -x "$backend_script" ]] || die "pull.sh: backend script not executable: $backend_script"
  if ! "$backend_script" fetch "$repo" "$num" > "$issue_dir/issue.md.tmp"; then
    rm -f "$issue_dir/issue.md.tmp"
    die "pull.sh: ${backend}.sh fetch failed for ${repo}#${num}"
  fi
  mv "$issue_dir/issue.md.tmp" "$issue_dir/issue.md"

  # Scaffold checklist if missing; do not stomp on user edits
  if [[ ! -f "$issue_dir/checklist.md" ]]; then
    checklist_init "$issue_dir" "$template"
  fi

  # Mark step 0 done; log
  checklist_mark "$issue_dir/checklist.md" 0 x
  log_append "$issue_dir" "pull" "fetched ${repo}#${num}, scaffold created"

  # Promote to active issue
  state_set "$project" active_issue "$issue_id"
  state_set "$project" issue_dir   "$issue_dir"

  info "pulled ${repo}#${num} into ${issue_dir}"
}

main "$@"
```

- [ ] **Step 3.5: Run tests to verify they pass**

Run: `bats tests/pull.bats`
Expected: 8 tests PASS.

- [ ] **Step 3.6: Write the slash command wrapper**

Create `commands/devagent:pull.md`:

```markdown
---
description: Fetch an issue from origin or fork and scaffold its workflow directory
---

# /devagent:pull

**Usage:** `/devagent:pull [project] origin|fork <issue-num>`

Runs `scripts/pull.sh` to fetch issue `<num>` from the configured
backend, write `<devdoc>/<dir_prefix><num>/issue.md`, initialise
`checklist.md`, mark step 0 done, and promote the issue to active.

Implements workflow step 0 per spec §6.3.

## Behavior

- `origin` reads `[project.<name>.issue_source]` from config.toml
- `fork`   reads `[project.<name>.issue_source_fork]`
- Existing `checklist.md` is preserved; `issue.md` is overwritten on refetch

## Run the script

Execute, substituting positional args. Pass through `$NOTE` only as
documentation — `pull` does not consume notes.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pull.sh" <project> <origin|fork> <num>
```
```

- [ ] **Step 3.7: Commit**

```bash
git add scripts/pull.sh templates/issue.md.skel tests/pull.bats commands/devagent:pull.md
git commit -s -m "$(cat <<'EOF'
feat(pull): add /devagent:pull workflow step 0

Fetches issue via backend script, scaffolds Issue-<N>/ per spec §3.5,
marks step 0 done, promotes issue to active_issue. Preserves
checklist.md on refetch to protect user edits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `scripts/where.sh` — reports active issue + last/next step

**Files:**
- Create: `scripts/where.sh`
- Create: `tests/where.bats`
- Create: `commands/devagent:where.md`

Spec §6.5: "Reports active issue + last step + next step; offers 'Continue?' but does **not** execute." Plan 2's `where.sh` does the reporting; the "Continue?" prompt invites the operator to type `/devagent:next` — we do not auto-invoke it.

- [ ] **Step 4.1: Write the failing test**

Create `tests/where.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DEVAGENT_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$DEVDOC/Issue-676"
EOF
  # Minimal checklist: step 2 done, step 3 in-progress
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
# Issue-676 — Workflow checklist

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
- [~]  3. improve
- [ ]  4. prune
- [ ]  5. tighten

## Log
- 2026-05-19 14:32  improve: started analyzing edge cases
EOF
}

@test "where reports active issue, last step, next step" {
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project: volk"* ]]
  [[ "$output" == *"Active issue: Issue-676"* ]]
  [[ "$output" == *"Current step: 3 (improve) [~]"* ]]
  [[ "$output" == *"Next step: 4 (prune)"* ]]
  [[ "$output" == *"Run /devagent:next to execute"* ]]
}

@test "where prints idle banner when no active issue" {
  rm "$DEVAGENT_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active issue"* ]]
}

@test "where surfaces STUCK file when present" {
  cat > "$DEVDOC/Issue-676/STUCK" <<'EOF'
Step: 3 improve
Reason: needs upstream API clarification
EOF
  # Mark step 3 as stuck
  sed -i 's/^- \[~\]  3\. improve/- [!]  3. improve/' "$DEVDOC/Issue-676/checklist.md"
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"needs upstream API clarification"* ]]
  [[ "$output" == *"/devagent:unstuck"* ]]
}

@test "where reports parked issues" {
  cat >> "$DEVAGENT_HOME/state/volk.toml" <<'EOF'
parked = ["Issue-203", "Issue-Fork-12"]
EOF
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parked: Issue-203, Issue-Fork-12"* ]]
}

@test "where errors when project unknown" {
  run "$PLUGIN_ROOT/scripts/where.sh" nosuch
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

Run: `bats tests/where.bats`
Expected: 5 tests FAIL.

- [ ] **Step 4.3: Write `scripts/where.sh`**

Create `scripts/where.sh`:

```bash
#!/usr/bin/env bash
# scripts/where.sh — reports active issue + last/next step. Does NOT execute.
# Spec §6.5.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

main() {
  local project="${1:-}"
  [[ -n "$project" ]] || die "where.sh: project required"
  config_is_project "$project" || die "where.sh: unknown project '$project'"

  echo "Project: $project"

  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"

  if [[ -z "$active" || "$active" == "null" ]]; then
    echo "Active issue: (none)"
    echo "No active issue. Use /devagent:resume <issue> or /devagent:pull to begin."
    _report_parked "$project"
    return 0
  fi

  echo "Active issue: $active"
  [[ -n "$issue_dir" ]] || die "where.sh: state.issue_dir missing for active issue"
  local checklist="$issue_dir/checklist.md"
  [[ -f "$checklist" ]] || die "where.sh: checklist.md missing at $checklist"

  local cur_step cur_state cur_name next_step next_name
  cur_step="$(checklist_current_step "$checklist")"
  if [[ -z "$cur_step" ]]; then
    echo "All steps complete."
    _report_parked "$project"
    return 0
  fi
  cur_state="$(checklist_step_state "$checklist" "$cur_step")"
  cur_name="$(checklist_step_name "$checklist" "$cur_step")"
  echo "Current step: ${cur_step} (${cur_name}) [${cur_state}]"

  # If stuck, surface STUCK
  if [[ "$cur_state" == "!" && -f "$issue_dir/STUCK" ]]; then
    echo
    echo "STUCK:"
    sed 's/^/  /' "$issue_dir/STUCK"
    echo
    echo "Run /devagent:unstuck to clear."
    _report_parked "$project"
    return 0
  fi

  # Compute next actionable step
  next_step="$(checklist_next_actionable "$checklist" "$cur_step")"
  if [[ -n "$next_step" ]]; then
    next_name="$(checklist_step_name "$checklist" "$next_step")"
    echo "Next step: ${next_step} (${next_name})"
  fi

  echo
  echo "Run /devagent:next to execute the next step."
  _report_parked "$project"
}

_report_parked() {
  local project="$1"
  local parked
  parked="$(state_list_parked "$project" | paste -sd, -)"
  [[ -n "$parked" ]] && echo "Parked: $parked"
  return 0
}

main "$@"
```

- [ ] **Step 4.4: Add `checklist_next_actionable` if Plan 1 did not ship it**

Inspect Plan 1:

```bash
grep -n 'checklist_next_actionable' scripts/lib/checklist.sh 2>/dev/null || echo "missing"
```

If missing, append to `scripts/lib/checklist.sh`:

```bash
# Returns the next step number whose state is one of [ ] [~] starting
# AFTER the given step number. Skips [x] [-] [?] [P]. Empty if none.
checklist_next_actionable() {
  local file="$1"
  local after="${2:-0}"
  awk -v after="$after" '
    match($0, /^\- \[([ x~?P!-])\] +([0-9]+)\./, m) {
      n = m[2] + 0
      g = m[1]
      if (n > after && (g == " " || g == "~")) { print n; exit }
    }
  ' "$file"
}
```

Add a quick bats test in `tests/checklist-next-actionable.bats` (3 cases: skips done, stops at next pending, returns empty when none).

```bash
#!/usr/bin/env bats
setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  F="$BATS_TEST_TMPDIR/c.md"
  cat > "$F" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [~]  2. scope
- [ ]  3. improve
- [-]  4. prune
- [ ]  5. tighten
EOF
}
@test "after step 2, next actionable is 3" {
  run checklist_next_actionable "$F" 2
  [ "$output" = "3" ]
}
@test "after step 3, skips [-] and returns 5" {
  run checklist_next_actionable "$F" 3
  [ "$output" = "5" ]
}
@test "after step 5, returns empty" {
  run checklist_next_actionable "$F" 5
  [ -z "$output" ]
}
```

- [ ] **Step 4.5: Run tests to verify they pass**

Run: `bats tests/where.bats tests/checklist-next-actionable.bats`
Expected: all PASS.

- [ ] **Step 4.6: Write the slash command wrapper**

Create `commands/devagent:where.md`:

```markdown
---
description: Show active issue, current/next step, parked issues, and STUCK status
---

# /devagent:where

**Usage:** `/devagent:where [project]`

Reports the active issue, the current step, the next actionable step,
any STUCK file contents, and any parked issues for the project. Does
**not** execute the next step — invites the operator to run
`/devagent:next` instead.

Implements spec §6.5.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/where.sh" <project>
```
```

- [ ] **Step 4.7: Commit**

```bash
git add scripts/where.sh tests/where.bats tests/checklist-next-actionable.bats \
        scripts/lib/checklist.sh commands/devagent:where.md
git commit -s -m "$(cat <<'EOF'
feat(where): add /devagent:where reporter

Reports active issue, current/next step, STUCK file, parked list.
Pure reporter; does not execute. Adds checklist_next_actionable helper.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `scripts/next.sh` — execute next actionable step

**Files:**
- Create: `scripts/next.sh`
- Create: `tests/next.bats`
- Create: `commands/devagent:next.md`

Spec §6.5, §7 (chaining), §8 (permission gates). `next.sh` dispatches to per-step scripts/skills. Plan 2 dispatches by step name; for steps Plan 3 or Plan 4 own, it prints a deferral message and exits 0 without advancing. This lets `next` be tested today without faking the missing steps.

`--auto` and `--through <step>` flags per spec §7.1.

- [ ] **Step 5.1: Write the failing test**

Create `tests/next.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DEVAGENT_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir    = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [ ]  2. scope
- [ ]  3. improve
EOF
}

@test "next on step owned by later plan prints deferral and exits 0" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"step 2 (scope)"* ]]
  [[ "$output" == *"deferred"* ]] || [[ "$output" == *"not yet wired"* ]]
}

@test "next refuses to advance when current step is [!]" {
  sed -i 's/^- \[ \]  2\. scope/- [!]  2. scope/' "$DEVDOC/Issue-676/checklist.md"
  echo "Reason: blocked" > "$DEVDOC/Issue-676/STUCK"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"/devagent:unstuck"* ]]
}

@test "next refuses without active issue" {
  rm "$DEVAGENT_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"No active issue"* ]]
}

@test "--through accepts a step name" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through tighten
  [ "$status" -eq 0 ]
  [[ "$output" == *"chain target: tighten"* ]]
}

@test "--auto implies through cleanup" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"chain target: cleanup"* ]]
}

@test "unknown --through step is rejected" {
  run "$PLUGIN_ROOT/scripts/next.sh" volk --through nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown step"* ]]
}

@test "next when all steps done reports completion" {
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [x]  2. scope
EOF
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"All steps complete"* ]]
}
```

- [ ] **Step 5.2: Run tests to verify they fail**

Run: `bats tests/next.bats`
Expected: 7 tests FAIL.

- [ ] **Step 5.3: Write `scripts/next.sh`**

Create `scripts/next.sh`:

```bash
#!/usr/bin/env bash
# scripts/next.sh — execute the next actionable step on the active issue.
# Spec §6.5, §7 (chaining), §8 (gates).
# Usage: next.sh <project> [--auto] [--through <step-name>] [-- <note...>]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

# Canonical step ordering (spec §5.2). Indexed 0..20.
STEP_NAMES=(pull draft scope improve prune tighten branch implement
            quality document commit analyze draftmr review redmr
            ship mergetoall updatewbs impact lessonslearned cleanup)

# Steps owned by Plan 2 today (executed in-process here).
# Today: none — Plan 2 implements pull separately (already step 0), and
# all other workflow verbs ship in Plans 3/4. next.sh therefore prints a
# deferral message for those. When Plans 3/4 land they replace this map.
declare -A STEP_OWNER
for n in "${STEP_NAMES[@]}"; do STEP_OWNER["$n"]="deferred"; done

_step_name_to_index() {
  local target="$1" i
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_NAMES[$i]}" == "$target" ]] && { echo "$i"; return 0; }
  done
  return 1
}

main() {
  local project="" auto=0 through="" note=""
  local -a rest=()
  while (( $# > 0 )); do
    case "$1" in
      --auto)     auto=1; shift ;;
      --through)  through="${2:?--through requires a step name}"; shift 2 ;;
      --)         shift; note="$*"; break ;;
      *)          rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]}"

  project="${1:-}"
  [[ -n "$project" ]] || die "next.sh: project required"
  config_is_project "$project" || die "next.sh: unknown project '$project'"

  # Resolve chain target
  local chain_target_idx=""
  if (( auto == 1 )) && [[ -z "$through" ]]; then
    through="cleanup"
  fi
  if [[ -n "$through" ]]; then
    if ! chain_target_idx="$(_step_name_to_index "$through")"; then
      die "next.sh: unknown step '$through'"
    fi
    echo "chain target: $through (step $chain_target_idx)"
  fi

  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ -z "$active" || "$active" == "null" ]]; then
    die "next.sh: No active issue for project '$project'"
  fi
  issue_dir="$(state_get "$project" issue_dir)"
  local checklist="$issue_dir/checklist.md"
  [[ -f "$checklist" ]] || die "next.sh: checklist.md missing at $checklist"

  # Find current step (first non-[x] non-[-]). If it's [!], halt.
  local cur
  cur="$(checklist_current_step "$checklist")"
  if [[ -z "$cur" ]]; then
    echo "All steps complete on $active."
    return 0
  fi
  local cur_state
  cur_state="$(checklist_step_state "$checklist" "$cur")"
  if [[ "$cur_state" == "!" ]]; then
    echo "STUCK: step $cur is marked [!]. Run /devagent:unstuck to clear." >&2
    if [[ -f "$issue_dir/STUCK" ]]; then
      sed 's/^/  /' "$issue_dir/STUCK" >&2
    fi
    return 1
  fi
  if [[ "$cur_state" == "?" ]]; then
    warn "Step $cur is [?] blocked-on-external. Consider /devagent:park."
    return 0
  fi

  # Dispatch loop
  while :; do
    local name owner
    name="${STEP_NAMES[$cur]:-}"
    [[ -n "$name" ]] || die "next.sh: step index $cur out of range"
    owner="${STEP_OWNER[$name]}"

    case "$owner" in
      deferred)
        echo "step $cur ($name): deferred — implemented in a later plan; not yet wired"
        log_append "$issue_dir" "$name" "skipped by next.sh — owner plan not yet shipped${note:+ ($note)}"
        return 0
        ;;
      *)
        die "next.sh: BUG — unknown owner '$owner' for step $name"
        ;;
    esac
    # When future plans land, they replace owner=deferred with a real
    # dispatch and increment $cur; auto/through chains here.
    # shellcheck disable=SC2317
    break
  done
}

main "$@"
```

- [ ] **Step 5.4: Run tests to verify they pass**

Run: `bats tests/next.bats`
Expected: 7 tests PASS.

- [ ] **Step 5.5: Write the slash command wrapper**

Create `commands/devagent:next.md`:

```markdown
---
description: Execute the next actionable step on the active issue
---

# /devagent:next

**Usage:** `/devagent:next [project] [--auto] [--through <step>] [-- <note>]`

Executes the next actionable step (spec §6.5). `--auto` chains to
`cleanup`; `--through <step>` chains up to and including the named
step (spec §7.1).

`--auto` cannot bypass permission gates and cannot continue past `[!]`
or a non-zero step exit (spec §7.2).

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/next.sh" "$@"
```

Where `"$@"` is the verbatim CLI tail forwarded by the harness.
```

- [ ] **Step 5.6: Commit**

```bash
git add scripts/next.sh tests/next.bats commands/devagent:next.md
git commit -s -m "$(cat <<'EOF'
feat(next): add /devagent:next dispatch + chain skeleton

Implements step-name dispatch, --auto / --through flags, STUCK halt,
[?] park-suggestion. All workflow steps currently report 'deferred';
Plans 3 and 4 replace owner=deferred with real handlers.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `scripts/status.sh` — multi-project dashboard

**Files:**
- Create: `scripts/status.sh`
- Create: `tests/status.bats`
- Create: `commands/devagent:status.md`

Spec §6.5: "Multi-project dashboard: active, stuck, parked, idle."

- [ ] **Step 6.1: Write the failing test**

Create `tests/status.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  DEVDOC1="$BATS_TEST_TMPDIR/devDoc/volk"
  DEVDOC2="$BATS_TEST_TMPDIR/devDoc/other"
  mkdir -p "$DEVDOC1/Issue-1" "$DEVDOC2/Issue-9"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC1"

[project.other]
devdoc_dir = "$DEVDOC2"
EOF
  cat > "$DEVAGENT_HOME/state/volk.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$DEVDOC1/Issue-1"
parked = ["Issue-7"]
EOF
  cat > "$DEVDOC1/Issue-1/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  1. draft
- [ ]  2. scope
EOF
  cat > "$DEVAGENT_HOME/state/other.toml" <<EOF
active_issue = "Issue-9"
issue_dir = "$DEVDOC2/Issue-9"
EOF
  cat > "$DEVDOC2/Issue-9/checklist.md" <<'EOF'
- [!]  3. improve
EOF
  echo "Reason: stuck" > "$DEVDOC2/Issue-9/STUCK"
}

@test "status volk shows that project only" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" != *"other"* ]]
}

@test "status --all shows both projects" {
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"other"* ]]
}

@test "status flags STUCK issues" {
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"Issue-9"* ]]
}

@test "status lists parked issues" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [[ "$output" == *"Parked: Issue-7"* ]]
}

@test "status shows current step name for active issue" {
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [[ "$output" == *"Issue-1"* ]]
  [[ "$output" == *"draft"* ]]
}

@test "status with no projects configured prints empty banner" {
  : > "$DEVAGENT_HOME/config.toml"
  run "$PLUGIN_ROOT/scripts/status.sh" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"No projects configured"* ]]
}
```

- [ ] **Step 6.2: Run tests to verify they fail**

Run: `bats tests/status.bats`
Expected: 6 tests FAIL.

- [ ] **Step 6.3: Write `scripts/status.sh`**

Create `scripts/status.sh`:

```bash
#!/usr/bin/env bash
# scripts/status.sh — multi-project dashboard. Spec §6.5.
# Usage: status.sh <project>      → one project
#        status.sh --all          → every configured project
#        status.sh                → active project, else --all

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

_print_one() {
  local project="$1"
  echo "── $project ──"
  local active issue_dir
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"

  if [[ -z "$active" || "$active" == "null" ]]; then
    echo "  Active: (idle)"
  else
    local cur cur_state cur_name
    if [[ -f "$issue_dir/checklist.md" ]]; then
      cur="$(checklist_current_step "$issue_dir/checklist.md")"
      if [[ -n "$cur" ]]; then
        cur_state="$(checklist_step_state "$issue_dir/checklist.md" "$cur")"
        cur_name="$(checklist_step_name "$issue_dir/checklist.md" "$cur")"
        echo "  Active: $active — step $cur ($cur_name) [$cur_state]"
      else
        echo "  Active: $active — all steps complete"
      fi
    else
      echo "  Active: $active — (no checklist.md)"
    fi
    if [[ -n "$issue_dir" && -f "$issue_dir/STUCK" ]]; then
      local reason
      reason="$(awk -F': *' '/^Reason:/{ $1=""; sub(/^ /,""); print; exit }' "$issue_dir/STUCK")"
      echo "  STUCK: $reason"
    fi
  fi

  local parked
  parked="$(state_list_parked "$project" | paste -sd, -)"
  [[ -n "$parked" ]] && echo "  Parked: $parked"
}

main() {
  local mode="auto"
  local project=""
  case "${1:-}" in
    --all) mode="all" ;;
    "")    mode="auto" ;;
    *)     mode="one"; project="$1" ;;
  esac

  local -a projects=()
  mapfile -t projects < <(config_list_projects)
  if (( ${#projects[@]} == 0 )); then
    echo "No projects configured. Add one to ~/.claude/devagent/config.toml."
    return 0
  fi

  case "$mode" in
    one)
      config_is_project "$project" || die "status.sh: unknown project '$project'"
      _print_one "$project"
      ;;
    all|auto)
      local p
      for p in "${projects[@]}"; do _print_one "$p"; done
      ;;
  esac
}

main "$@"
```

- [ ] **Step 6.4: Run tests to verify they pass**

Run: `bats tests/status.bats`
Expected: 6 tests PASS.

- [ ] **Step 6.5: Write the slash command wrapper**

Create `commands/devagent:status.md`:

```markdown
---
description: Multi-project dashboard of active issues, STUCK, and parked
---

# /devagent:status

**Usage:** `/devagent:status [project|--all]`

Per spec §6.5. With no args, prints every configured project. With a
project name, prints that one. With `--all`, same as no args.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" "$@"
```
```

- [ ] **Step 6.6: Commit**

```bash
git add scripts/status.sh tests/status.bats commands/devagent:status.md
git commit -s -m "$(cat <<'EOF'
feat(status): add /devagent:status multi-project dashboard

Per-project view of active issue, current step, STUCK, parked list.
Default and --all iterate every configured project.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `scripts/catchup.sh` — one-screen rehydration

**Files:**
- Create: `scripts/catchup.sh`
- Create: `tests/catchup.bats`
- Create: `commands/devagent:catchup.md`

Spec §6.5: "Synthesizes issue.md + imPlan + actualWork + last comments + last 5 log entries into one-screen rehydration."

Plan 2's `catchup.sh` is a pure formatter — it reads files that may or may not exist (imPlan and actualWork land in Plan 4) and synthesizes them. Missing files print a "not yet present" line, not an error.

- [ ] **Step 7.1: Write the failing test**

Create `tests/catchup.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DEVAGENT_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/issue.md" <<'EOF'
# gnuradio/volk#676 — Demo
- State: open
- Author: @alice

---

Body of the issue here.

---

## Comments (2)

### @bob · 2026-05-12

First comment.

### @carol · 2026-05-15

Second comment with more detail.
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  1. draft
## Log
- 2026-05-10 10:00  pull: fetched
- 2026-05-11 10:00  draft: started
- 2026-05-12 10:00  draft: revised
- 2026-05-13 10:00  scope: 1 recommendation
- 2026-05-14 10:00  improve: queued
- 2026-05-15 10:00  improve: in progress
EOF
}

@test "catchup synthesizes issue title, current step, last 5 log entries" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-676"* ]]
  [[ "$output" == *"Demo"* ]]
  [[ "$output" == *"Current step: 1 (draft)"* ]]
  [[ "$output" == *"draft: revised"* ]]
  [[ "$output" == *"improve: in progress"* ]]
  # First log line should be dropped (5-line cap)
  [[ "$output" != *"pull: fetched"* ]]
}

@test "catchup shows last 2 comments in summary form" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [[ "$output" == *"@bob"* || "$output" == *"@carol"* ]]
}

@test "catchup notes missing imPlan / actualWork without erroring" {
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"imPlan.md: not yet present"* ]]
  [[ "$output" == *"actualWork.md: not yet present"* ]]
}

@test "catchup accepts explicit issue arg" {
  mkdir -p "$DEVDOC/Issue-203"
  cat > "$DEVDOC/Issue-203/checklist.md" <<'EOF'
- [~]  0. pull
## Log
- 2026-05-01 09:00  pull: started
EOF
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk Issue-203
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-203"* ]]
}

@test "catchup errors when no active issue and no arg" {
  rm "$DEVAGENT_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 7.2: Run tests to verify they fail**

Run: `bats tests/catchup.bats`
Expected: 5 tests FAIL.

- [ ] **Step 7.3: Write `scripts/catchup.sh`**

Create `scripts/catchup.sh`:

```bash
#!/usr/bin/env bash
# scripts/catchup.sh — synthesise issue rehydration. Spec §6.5.
# Usage: catchup.sh <project> [issue-id]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

_print_issue_title() {
  local issue_md="$1"
  if [[ -f "$issue_md" ]]; then
    head -n 1 "$issue_md"
  else
    echo "(issue.md missing)"
  fi
}

_print_last_two_comments() {
  local issue_md="$1"
  [[ -f "$issue_md" ]] || { echo "  (no issue.md)"; return; }
  # Extract every "### @user · date" header and the line after; keep last two.
  awk '
    /^### @/ { if (h) print h; h = $0; getline; getline body; sub(/^\s*/, "", body); h = h " — " substr(body,1,120) }
    END { if (h) print h }
  ' "$issue_md" | tail -n 2 | sed 's/^/  /'
}

main() {
  local project="${1:-}"
  local issue_arg="${2:-}"
  [[ -n "$project" ]] || die "catchup.sh: project required"
  config_is_project "$project" || die "catchup.sh: unknown project '$project'"

  local issue issue_dir devdoc
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  if [[ -n "$issue_arg" ]]; then
    issue="$issue_arg"
    issue_dir="${devdoc%/}/$issue"
  else
    issue="$(state_get "$project" active_issue 2>/dev/null || true)"
    issue_dir="$(state_get "$project" issue_dir 2>/dev/null || true)"
    [[ -n "$issue" && "$issue" != "null" ]] \
      || die "catchup.sh: No active issue for $project; pass one explicitly."
  fi
  [[ -d "$issue_dir" ]] || die "catchup.sh: missing $issue_dir"

  echo "═══ Catchup: $project / $issue ═══"
  echo "Title: $(_print_issue_title "$issue_dir/issue.md")"

  if [[ -f "$issue_dir/checklist.md" ]]; then
    local cur cur_name
    cur="$(checklist_current_step "$issue_dir/checklist.md")"
    if [[ -n "$cur" ]]; then
      cur_name="$(checklist_step_name "$issue_dir/checklist.md" "$cur")"
      echo "Current step: $cur ($cur_name)"
    else
      echo "Current step: (all complete)"
    fi
  fi

  if [[ -f "$issue_dir/STUCK" ]]; then
    echo
    echo "STUCK file present:"
    sed 's/^/  /' "$issue_dir/STUCK"
  fi

  echo
  echo "── imPlan ──"
  if [[ -f "$issue_dir/imPlan.md" ]]; then
    head -n 20 "$issue_dir/imPlan.md" | sed 's/^/  /'
  else
    echo "  imPlan.md: not yet present (lands at step 1 draft)"
  fi

  echo
  echo "── actualWork ──"
  if [[ -f "$issue_dir/actualWork.md" ]]; then
    tail -n 20 "$issue_dir/actualWork.md" | sed 's/^/  /'
  else
    echo "  actualWork.md: not yet present (lands at step 9 document)"
  fi

  echo
  echo "── Last 2 comments ──"
  _print_last_two_comments "$issue_dir/issue.md"

  echo
  echo "── Last 5 log entries ──"
  log_tail "$issue_dir" 5 | sed 's/^/  /'
}

main "$@"
```

- [ ] **Step 7.4: Run tests to verify they pass**

Run: `bats tests/catchup.bats`
Expected: 5 tests PASS.

- [ ] **Step 7.5: Write the slash command wrapper**

Create `commands/devagent:catchup.md`:

```markdown
---
description: One-screen rehydration of an issue
---

# /devagent:catchup

**Usage:** `/devagent:catchup [project] [issue]`

Synthesises issue title, current step, STUCK, head of imPlan, tail of
actualWork, last 2 comments, last 5 log entries (spec §6.5).

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/catchup.sh" "$@"
```
```

- [ ] **Step 7.6: Commit**

```bash
git add scripts/catchup.sh tests/catchup.bats commands/devagent:catchup.md
git commit -s -m "$(cat <<'EOF'
feat(catchup): add /devagent:catchup rehydration synth

Concatenates issue title, current step, STUCK, imPlan head, actualWork
tail, last 2 comments, last 5 log entries — bounded to one screen.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `scripts/stuck.sh` + `scripts/unstuck.sh`

**Files:**
- Create: `scripts/stuck.sh`
- Create: `scripts/unstuck.sh`
- Create: `tests/stuck-unstuck.bats`
- Create: `commands/devagent:stuck.md`
- Create: `commands/devagent:unstuck.md`

Spec §5.3 (STUCK file format), §6.5.

- [ ] **Step 8.1: Write the failing test**

Create `tests/stuck-unstuck.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DEVAGENT_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  1. draft
- [ ]  2. scope
## Log
EOF
}

@test "stuck marks current step [!] and writes STUCK file" {
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk "needs upstream API clarification"
  [ "$status" -eq 0 ]
  grep -E '^\- \[!\]  1\. draft' "$DEVDOC/Issue-676/checklist.md"
  [ -f "$DEVDOC/Issue-676/STUCK" ]
  grep -q "needs upstream API clarification" "$DEVDOC/Issue-676/STUCK"
  grep -q "Step: *1 draft" "$DEVDOC/Issue-676/STUCK"
}

@test "stuck appends a log entry" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  grep -E 'draft: stuck — blocked' "$DEVDOC/Issue-676/checklist.md"
}

@test "stuck requires a reason" {
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk
  [ "$status" -ne 0 ]
  [[ "$output" == *"reason"* ]]
}

@test "unstuck removes STUCK file and flips [!] back to [~] by default" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [ ! -f "$DEVDOC/Issue-676/STUCK" ]
  grep -E '^\- \[~\]  1\. draft' "$DEVDOC/Issue-676/checklist.md"
}

@test "unstuck --pending flips to [ ]" {
  "$PLUGIN_ROOT/scripts/stuck.sh" volk "blocked"
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk --pending
  [ "$status" -eq 0 ]
  grep -E '^\- \[ \]  1\. draft' "$DEVDOC/Issue-676/checklist.md"
}

@test "unstuck is a no-op (with warning) when no STUCK file" {
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"no STUCK"* ]]
}
```

- [ ] **Step 8.2: Run tests to verify they fail**

Run: `bats tests/stuck-unstuck.bats`
Expected: 6 tests FAIL.

- [ ] **Step 8.3: Write `scripts/stuck.sh`**

Create `scripts/stuck.sh`:

```bash
#!/usr/bin/env bash
# scripts/stuck.sh — mark current step [!], write STUCK file. Spec §5.3, §6.5.
# Usage: stuck.sh <project> "<reason>"

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

main() {
  local project="${1:-}"
  local reason="${2:-}"
  [[ -n "$project" ]] || die "stuck.sh: project required"
  [[ -n "$reason"  ]] || die "stuck.sh: reason required (quote it)"
  config_is_project "$project" || die "stuck.sh: unknown project '$project'"

  local issue_dir
  issue_dir="$(state_get "$project" issue_dir)"
  [[ -d "$issue_dir" ]] || die "stuck.sh: no issue_dir; nothing to mark stuck"

  local checklist="$issue_dir/checklist.md"
  local cur cur_name last_good last_good_name
  cur="$(checklist_current_step "$checklist")"
  [[ -n "$cur" ]] || die "stuck.sh: no current step to mark stuck"
  cur_name="$(checklist_step_name "$checklist" "$cur")"

  # Walk back for "last good" — last [x] step before cur
  last_good="$(awk -v cur="$cur" '
    match($0, /^\- \[x\] +([0-9]+)\./, m) {
      n = m[1] + 0
      if (n < cur) last = n
    }
    END { if (last != "") print last }
  ' "$checklist")"
  if [[ -n "$last_good" ]]; then
    last_good_name="$(checklist_step_name "$checklist" "$last_good")"
  fi

  checklist_mark "$checklist" "$cur" "!"

  local ts; ts="$(date '+%Y-%m-%d %H:%M')"
  {
    printf 'Step:        %s %s\n' "$cur" "$cur_name"
    printf 'Reason:      %s\n' "$reason"
    if [[ -n "$last_good" ]]; then
      printf 'Last good:   step %s %s\n' "$last_good" "${last_good_name:-}"
    fi
    printf 'Created:     %s\n' "$ts"
  } > "$issue_dir/STUCK"

  log_append "$issue_dir" "$cur_name" "stuck — $reason"
  info "marked step $cur ($cur_name) stuck — wrote $issue_dir/STUCK"
}

main "$@"
```

- [ ] **Step 8.4: Write `scripts/unstuck.sh`**

Create `scripts/unstuck.sh`:

```bash
#!/usr/bin/env bash
# scripts/unstuck.sh — clear STUCK file, flip [!] back. Spec §5.3, §6.5.
# Usage: unstuck.sh <project> [--pending]
#   default: flip to [~]; --pending flips to [ ].

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

main() {
  local project="${1:-}"
  local mode="inprogress"
  case "${2:-}" in
    --pending) mode="pending" ;;
    "")        ;;
    *)         die "unstuck.sh: unknown flag '$2'" ;;
  esac

  [[ -n "$project" ]] || die "unstuck.sh: project required"
  config_is_project "$project" || die "unstuck.sh: unknown project '$project'"

  local issue_dir
  issue_dir="$(state_get "$project" issue_dir)"
  [[ -d "$issue_dir" ]] || die "unstuck.sh: no issue_dir"

  if [[ ! -f "$issue_dir/STUCK" ]]; then
    info "no STUCK file at $issue_dir/STUCK — nothing to clear"
    return 0
  fi

  local checklist="$issue_dir/checklist.md"
  # Find the [!] step
  local stuck_step
  stuck_step="$(awk '
    match($0, /^\- \[!\] +([0-9]+)\./, m) { print m[1]; exit }
  ' "$checklist")"
  [[ -n "$stuck_step" ]] || die "unstuck.sh: STUCK file present but no [!] step in checklist"

  local glyph=" "
  [[ "$mode" == "inprogress" ]] && glyph="~"
  checklist_mark "$checklist" "$stuck_step" "$glyph"

  local name
  name="$(checklist_step_name "$checklist" "$stuck_step")"
  rm -f "$issue_dir/STUCK"
  log_append "$issue_dir" "$name" "unstuck — flipped to [$glyph]"
  info "cleared STUCK at $issue_dir; step $stuck_step ($name) → [$glyph]"
}

main "$@"
```

- [ ] **Step 8.5: Run tests to verify they pass**

Run: `bats tests/stuck-unstuck.bats`
Expected: 6 tests PASS.

- [ ] **Step 8.6: Write slash command wrappers**

Create `commands/devagent:stuck.md`:

```markdown
---
description: Mark the current step stuck and write a STUCK file
---

# /devagent:stuck

**Usage:** `/devagent:stuck "<reason>"`

Marks current step `[!]` and writes `<issue-dir>/STUCK` per spec §5.3.
Halts `next` until cleared via `/devagent:unstuck`.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stuck.sh" "$@"
```
```

Create `commands/devagent:unstuck.md`:

```markdown
---
description: Clear the STUCK file and resume the previously-stuck step
---

# /devagent:unstuck

**Usage:** `/devagent:unstuck [project] [--pending]`

Removes STUCK file and flips `[!]` back to `[~]` (default) or `[ ]`
(with `--pending`). Spec §5.3.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/unstuck.sh" "$@"
```
```

- [ ] **Step 8.7: Commit**

```bash
git add scripts/stuck.sh scripts/unstuck.sh tests/stuck-unstuck.bats \
        commands/devagent:stuck.md commands/devagent:unstuck.md
git commit -s -m "$(cat <<'EOF'
feat(stuck): add /devagent:stuck and /devagent:unstuck

stuck.sh marks current step [!] and writes STUCK file per spec §5.3
(Step, Reason, Last good, Created). unstuck.sh clears STUCK and flips
back to [~] by default or [ ] with --pending.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `scripts/park.sh`, `scripts/resume.sh`, `scripts/switch.sh`

**Files:**
- Create: `scripts/park.sh`
- Create: `scripts/resume.sh`
- Create: `scripts/switch.sh`
- Create: `tests/park-resume-switch.bats`
- Create: `commands/devagent:park.md`
- Create: `commands/devagent:resume.md`
- Create: `commands/devagent:switch.md`

Spec §5.1 (`[P]`), §6.5.

- [ ] **Step 9.1: Write the failing test**

Create `tests/park-resume-switch.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC/Issue-676" "$DEVDOC/Issue-203"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DEVAGENT_HOME/state/volk.toml" <<EOF
active_issue = "Issue-676"
issue_dir = "$DEVDOC/Issue-676"
EOF
  cat > "$DEVDOC/Issue-676/checklist.md" <<'EOF'
- [x]  0. pull
- [~]  1. draft
## Log
EOF
  cat > "$DEVDOC/Issue-203/checklist.md" <<'EOF'
- [~]  3. improve
## Log
EOF
}

@test "park marks active issue [P] and clears active_issue" {
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]
  # active_issue should be unset (no line, or empty)
  ! grep -qE '^active_issue *= *"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
  grep -qE '^parked *=.*"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
  grep -E '^- \[P\] +1\. draft|^Parked at: ' "$DEVDOC/Issue-676/checklist.md" \
    || grep -q 'park: parked' "$DEVDOC/Issue-676/checklist.md"
}

@test "park with explicit issue parks that one even if not active" {
  run "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '"Issue-203"' "$DEVAGENT_HOME/state/volk.toml"
  # Active issue not changed
  grep -qE '^active_issue *= *"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
}

@test "resume reactivates a parked issue" {
  "$PLUGIN_ROOT/scripts/park.sh" volk
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
  ! grep -qE 'parked *=.*"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
}

@test "resume errors when issue isn't parked" {
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-999
  [ "$status" -ne 0 ]
  [[ "$output" == *"not parked"* || "$output" == *"unknown"* ]]
}

@test "switch parks current and resumes target" {
  # Park 203 so it's resumable
  "$PLUGIN_ROOT/scripts/park.sh" volk Issue-203
  run "$PLUGIN_ROOT/scripts/switch.sh" volk Issue-203
  [ "$status" -eq 0 ]
  grep -qE '^active_issue *= *"Issue-203"' "$DEVAGENT_HOME/state/volk.toml"
  grep -qE 'parked *=.*"Issue-676"' "$DEVAGENT_HOME/state/volk.toml"
}

@test "park errors when no active issue and no arg" {
  rm "$DEVAGENT_HOME/state/volk.toml"
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 9.2: Run tests to verify they fail**

Run: `bats tests/park-resume-switch.bats`
Expected: 6 tests FAIL.

- [ ] **Step 9.3: Write `scripts/park.sh`**

Create `scripts/park.sh`:

```bash
#!/usr/bin/env bash
# scripts/park.sh — park an issue; clears active_issue if it was active.
# Spec §5.1 [P], §6.5.
# Usage: park.sh <project> [issue-id]

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

main() {
  local project="${1:-}"
  local issue="${2:-}"
  [[ -n "$project" ]] || die "park.sh: project required"
  config_is_project "$project" || die "park.sh: unknown project '$project'"

  local active devdoc
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  if [[ -z "$issue" ]]; then
    [[ -n "$active" && "$active" != "null" ]] \
      || die "park.sh: no active issue and no issue arg"
    issue="$active"
  fi

  local issue_dir="${devdoc%/}/$issue"
  if [[ -d "$issue_dir" ]]; then
    local checklist="$issue_dir/checklist.md"
    if [[ -f "$checklist" ]]; then
      local cur
      cur="$(checklist_current_step "$checklist")"
      [[ -n "$cur" ]] && checklist_mark "$checklist" "$cur" "P"
      log_append "$issue_dir" "park" "issue parked"
    fi
  fi

  state_add_parked "$project" "$issue"
  if [[ "$active" == "$issue" ]]; then
    state_unset "$project" active_issue
    state_unset "$project" issue_dir
  fi
  info "parked $issue"
}

main "$@"
```

- [ ] **Step 9.4: Write `scripts/resume.sh`**

Create `scripts/resume.sh`:

```bash
#!/usr/bin/env bash
# scripts/resume.sh — reactivate a parked issue.
# Usage: resume.sh <project> <issue-id>

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/config.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/log.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"

main() {
  local project="${1:-}"
  local issue="${2:-}"
  [[ -n "$project" ]] || die "resume.sh: project required"
  [[ -n "$issue"   ]] || die "resume.sh: issue id required"
  config_is_project "$project" || die "resume.sh: unknown project '$project'"

  # Refuse if not parked
  local parked
  parked="$(state_list_parked "$project")"
  if ! grep -qxF "$issue" <<<"$parked"; then
    die "resume.sh: '$issue' not parked for $project"
  fi

  local devdoc issue_dir
  devdoc="$(config_get_project_field "$project" devdoc_dir)"
  issue_dir="${devdoc%/}/$issue"
  [[ -d "$issue_dir" ]] || die "resume.sh: issue dir missing: $issue_dir"

  # Flip [P] back to [~]
  local checklist="$issue_dir/checklist.md"
  if [[ -f "$checklist" ]]; then
    local parked_step
    parked_step="$(awk '
      match($0, /^\- \[P\] +([0-9]+)\./, m) { print m[1]; exit }
    ' "$checklist")"
    [[ -n "$parked_step" ]] && checklist_mark "$checklist" "$parked_step" "~"
    log_append "$issue_dir" "resume" "issue resumed"
  fi

  state_remove_parked "$project" "$issue"
  state_set "$project" active_issue "$issue"
  state_set "$project" issue_dir   "$issue_dir"
  info "resumed $issue"
}

main "$@"
```

- [ ] **Step 9.5: Write `scripts/switch.sh`**

Create `scripts/switch.sh`:

```bash
#!/usr/bin/env bash
# scripts/switch.sh — sugar: park current, resume target.
# Usage: switch.sh <project> <issue-id>

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/io.sh"
# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib/state.sh"

main() {
  local project="${1:-}"
  local target="${2:-}"
  [[ -n "$project" ]] || die "switch.sh: project required"
  [[ -n "$target"  ]] || die "switch.sh: target issue required"

  local active
  active="$(state_get "$project" active_issue 2>/dev/null || true)"
  if [[ -n "$active" && "$active" != "null" && "$active" != "$target" ]]; then
    "$PLUGIN_ROOT/scripts/park.sh" "$project"
  fi
  "$PLUGIN_ROOT/scripts/resume.sh" "$project" "$target"
}

main "$@"
```

- [ ] **Step 9.6: Run tests to verify they pass**

Run: `bats tests/park-resume-switch.bats`
Expected: 6 tests PASS.

- [ ] **Step 9.7: Write slash command wrappers**

Create `commands/devagent:park.md`:

```markdown
---
description: Park an issue, clearing it from active if it was active
---

# /devagent:park

**Usage:** `/devagent:park [project] [issue]`

Marks the issue `[P]`, adds it to `parked` in state, clears
`active_issue` if it matched. Spec §5.1, §6.5.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/park.sh" "$@"
```
```

Create `commands/devagent:resume.md`:

```markdown
---
description: Resume a parked issue, promoting it to active
---

# /devagent:resume

**Usage:** `/devagent:resume [project] <issue>`

Removes the issue from `parked`, flips `[P]` back to `[~]`, sets it as
`active_issue`. Spec §6.5.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh" "$@"
```
```

Create `commands/devagent:switch.md`:

```markdown
---
description: Park current and resume target in one call
---

# /devagent:switch

**Usage:** `/devagent:switch [project] <issue>`

Sugar for `/devagent:park` + `/devagent:resume <issue>` (spec §6.5).

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/switch.sh" "$@"
```
```

- [ ] **Step 9.8: Commit**

```bash
git add scripts/park.sh scripts/resume.sh scripts/switch.sh \
        tests/park-resume-switch.bats \
        commands/devagent:park.md commands/devagent:resume.md commands/devagent:switch.md
git commit -s -m "$(cat <<'EOF'
feat(park): add /devagent:park /devagent:resume /devagent:switch

park marks [P] and clears active_issue when target was active. resume
restores [~] and re-promotes to active. switch is sugar for both.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: End-to-end smoke test

**Files:**
- Create: `tests/e2e-context-core.bats`

Runs a small scripted scenario end-to-end against the stub gh: pull →
where → park → status → resume → catchup → stuck → unstuck → next.

- [ ] **Step 10.1: Write the test**

Create `tests/e2e-context-core.bats`:

```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load "lib/bats-helpers.bash"
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC"
  cat > "$DEVAGENT_HOME/config.toml" <<EOF
[project.volk]
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
}

@test "full context-core happy path" {
  # pull → scaffold
  run "$PLUGIN_ROOT/scripts/pull.sh" volk origin 676
  [ "$status" -eq 0 ]

  # where → reports active
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-676"* ]]

  # status → one project
  run "$PLUGIN_ROOT/scripts/status.sh" volk
  [ "$status" -eq 0 ]

  # catchup → rehydration
  run "$PLUGIN_ROOT/scripts/catchup.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"Catchup"* ]]

  # park → out of active
  run "$PLUGIN_ROOT/scripts/park.sh" volk
  [ "$status" -eq 0 ]

  # where → idle banner
  run "$PLUGIN_ROOT/scripts/where.sh" volk
  [[ "$output" == *"No active issue"* ]]

  # resume → back active
  run "$PLUGIN_ROOT/scripts/resume.sh" volk Issue-676
  [ "$status" -eq 0 ]

  # stuck/unstuck cycle
  run "$PLUGIN_ROOT/scripts/stuck.sh" volk "checking something"
  [ "$status" -eq 0 ]
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -ne 0 ]  # halts on [!]
  run "$PLUGIN_ROOT/scripts/unstuck.sh" volk
  [ "$status" -eq 0 ]

  # next → deferred (Plan 3 owns step 1+)
  run "$PLUGIN_ROOT/scripts/next.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"deferred"* ]]
}
```

- [ ] **Step 10.2: Run the suite to verify it passes**

Run: `bats tests/`
Expected: every test PASSes.

- [ ] **Step 10.3: Commit**

```bash
git add tests/e2e-context-core.bats
git commit -s -m "$(cat <<'EOF'
test(e2e): add context-core happy-path smoke test

Walks pull → where → status → catchup → park → resume → stuck →
unstuck → next end-to-end against the stub gh fixture.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- §3.5 (per-issue dir scaffolding) — Task 3
- §5.1 (state glyphs including `[!]` and `[P]`) — Tasks 8, 9
- §5.3 (STUCK file format: Step, Reason, Last good, Created) — Task 8
- §6.1 (invocation grammar) — Task 1
- §6.3 row 0 (pull) — Task 3
- §6.5 (where, next, status, catchup, stuck, unstuck, park, resume, switch) — Tasks 4–9
- §7.1 (`--auto`, `--through`) — Task 5
- §7.2 (gates not bypassed; STUCK halts) — Task 5 ('STUCK halts' test) plus deferral for actual gate enforcement to Plan 3/4 when the gated scripts ship
- §8 (permission gates) — out of scope for Plan 2 because every gated script (ship, mergetoall, cleanup, sync, plus transition_issue invokers) lands in Plan 3+. Plan 2's only enforcement is the STUCK-halt path in `next.sh`. This is called out in the plan header under "Out of scope".
- §9.1 (issue backend `fetch` contract) — Task 2
- §9.3 (markdown shape) — Task 2
- §9.4 (gh wrapper, stubbed in tests) — Task 2

**Placeholder scan:** No "TBD", no "implement later", no "similar to Task N", no "add appropriate error handling" without code. Every step contains the actual code or actual command.

**Type consistency:** `checklist_mark` takes `(file, step-num, glyph)` consistently across Tasks 3, 8, 9. `state_get`, `state_set`, `state_unset`, `state_add_parked`, `state_remove_parked`, `state_list_parked` signatures used identically everywhere. `log_append (issue-dir, step-name, message)` consistent. Step ordering (`STEP_NAMES`) in Task 5 matches spec §5.2 row order.

**Gap noted, deferred deliberately:** spec §8's "permission gates" enforcement lives entirely in scripts Plan 3 ships. No Plan 2 script makes a remote-visible change, so there's nothing to gate. Plan 3 is the right home.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-19-devagent-02-context-core.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?
