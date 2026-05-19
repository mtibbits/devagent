# devAgent Phase 9 — Tooling Utilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `/devagent:depends`, `/devagent:grep`, `/devagent:history`, and `/devagent:template` commands that give operators cross-issue visibility and template introspection, plus a dependency-warning hook that `ship.sh` (Plan 3) calls before opening an MR.

**Architecture:** Each command is a thin Markdown wrapper that shells out to a dedicated bash script under `scripts/`. Shared logic for dependency storage, graph traversal, log parsing, and template resolution lives in `scripts/lib/` so it can be reused by `where`/`next`/`ship` (cross-plan integration). Dependency data lives in a single per-project TOML file (`<state>/<project>.depends.toml`) rather than per-issue meta files — it gives O(1) cycle detection across the whole graph and a single file to back up. Template resolution mirrors the spec's three-layer order (project paths → `<devdoc>/templates/` → plugin `templates/`).

**Tech Stack:** Bash 5+, `bats-core` for shell tests, Python 3 (`tomllib`) only where TOML round-tripping is non-trivial, `grep -RnH` for the grep command (no reinvention), GNU `sort -u` for chronological log merge.

---

## File Structure

**Plan owns (create):**
- `scripts/lib/depends.sh` — dependency CRUD, cycle detection, ship pre-flight warning
- `scripts/lib/template_resolve.sh` — template resolution (3-layer order)
- `scripts/lib/history.sh` — chronological log merge across a project or single issue
- `scripts/depends.sh` — entry point for `/devagent:depends`
- `scripts/grep.sh` — entry point for `/devagent:grep`
- `scripts/history.sh` — entry point for `/devagent:history`
- `scripts/template.sh` — entry point for `/devagent:template`
- `commands/depends.md`, `commands/grep.md`, `commands/history.md`, `commands/template.md`
- `tests/depends.bats`, `tests/grep.bats`, `tests/history.bats`, `tests/template.bats`
- `tests/lib/depends.bats`, `tests/lib/template_resolve.bats`, `tests/lib/history.bats`
- `tests/fixtures/phase9/` — fake project, devdoc, issues, captures

**Plan reads / depends on (from other plans — do NOT modify):**
- `scripts/lib/config.sh` (Plan 1) — `config_get_project_field`, `config_devdoc_dir`, `config_state_dir`
- `scripts/lib/state.sh` (Plan 1) — state file lookup helpers
- `scripts/lib/checklist.sh` (Plan 1) — `checklist_log_entries <file>` returns `ISO-TS|step|message` rows
- `scripts/lib/log.sh` (Plan 1) — `log_info`, `log_warn`, `log_error`
- `scripts/ship.sh` (Plan 3) — must add a single line that calls `depends_ship_preflight`

**Coordination point with Plan 3 (ship.sh):**
Plan 3 must add this one line near the top of its main flow, after argument parsing but before the call to `code/<backend>.sh create-mr`:

```bash
# Phase 9 dependency pre-flight (warn-only by default; --strict makes it block)
. "${DEVAGENT_LIB}/depends.sh"
depends_ship_preflight "${PROJECT}" "${ACTIVE_ISSUE}" "${STRICT_DEPS:-0}" || exit 2
```

If Plan 3 lands before Plan 9, the `.` line will fail until this plan ships. To avoid an ordering hazard, Task 4 in this plan adds a no-op stub `scripts/lib/depends.sh` first (so Plan 3 can source it), then fills in real behavior. If Plan 9 lands first, the file is harmless until Plan 3 sources it.

---

## Task 1: Test scaffolding and fixtures

**Files:**
- Create: `tests/fixtures/phase9/devdoc/Issue-100/checklist.md`
- Create: `tests/fixtures/phase9/devdoc/Issue-100/issue.md`
- Create: `tests/fixtures/phase9/devdoc/Issue-100/imPlan.md`
- Create: `tests/fixtures/phase9/devdoc/Issue-100/actualWork.md`
- Create: `tests/fixtures/phase9/devdoc/Issue-100/mr.md`
- Create: `tests/fixtures/phase9/devdoc/Issue-101/checklist.md`
- Create: `tests/fixtures/phase9/devdoc/Issue-102/checklist.md`
- Create: `tests/fixtures/phase9/devdoc/Captures/2026-05-19-foo/draft.md`
- Create: `tests/fixtures/phase9/devdoc/templates/coding_standards.md`
- Create: `tests/fixtures/phase9/plugin_templates/coding_standards.md`
- Create: `tests/fixtures/phase9/plugin_templates/mr_template.md`
- Create: `tests/fixtures/phase9/state_dir/.gitkeep`
- Create: `tests/lib/_helpers.bash`

- [ ] **Step 1: Create the directory tree**

```bash
mkdir -p tests/fixtures/phase9/devdoc/Issue-100
mkdir -p tests/fixtures/phase9/devdoc/Issue-101
mkdir -p tests/fixtures/phase9/devdoc/Issue-102
mkdir -p tests/fixtures/phase9/devdoc/Captures/2026-05-19-foo
mkdir -p tests/fixtures/phase9/devdoc/templates
mkdir -p tests/fixtures/phase9/plugin_templates
mkdir -p tests/fixtures/phase9/state_dir
mkdir -p tests/lib
touch tests/fixtures/phase9/state_dir/.gitkeep
```

- [ ] **Step 2: Write Issue-100 fixture files**

`tests/fixtures/phase9/devdoc/Issue-100/checklist.md`:
```markdown
# Issue-100 — Workflow checklist

Template: standard
Created: 2026-05-10 09:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [~]  2. scope

## Log
- 2026-05-10 09:00  pull: fetched gnuradio/volk#100
- 2026-05-10 09:12  draft: imPlan.md written (FOOBAR keyword)
- 2026-05-11 10:30  scope: added validation criterion
```

`tests/fixtures/phase9/devdoc/Issue-100/issue.md`:
```markdown
# gnuradio/volk#100 — Sample issue
- State: open
- URL: https://example.invalid/100

Body contains the FOOBAR keyword for grep tests.
```

`tests/fixtures/phase9/devdoc/Issue-100/imPlan.md`:
```markdown
# Issue-100 implementation plan
Step 1: do the thing (FOOBAR appears here too).
```

`tests/fixtures/phase9/devdoc/Issue-100/actualWork.md`:
```markdown
# Actual work
Nothing yet.
```

`tests/fixtures/phase9/devdoc/Issue-100/mr.md`:
```markdown
# MR draft
Pending.
```

- [ ] **Step 3: Write Issue-101 and Issue-102 fixtures**

`tests/fixtures/phase9/devdoc/Issue-101/checklist.md`:
```markdown
# Issue-101 — Workflow checklist

## Log
- 2026-05-09 08:00  pull: fetched #101
- 2026-05-12 14:00  draft: imPlan written
```

`tests/fixtures/phase9/devdoc/Issue-102/checklist.md`:
```markdown
# Issue-102 — Workflow checklist

## Log
- 2026-05-15 11:00  pull: fetched #102
```

- [ ] **Step 4: Write capture and template fixtures**

`tests/fixtures/phase9/devdoc/Captures/2026-05-19-foo/draft.md`:
```markdown
# Capture draft
FOOBAR appears in captures too — grep should skip this by default.
```

`tests/fixtures/phase9/devdoc/templates/coding_standards.md`:
```markdown
# Coding standards (devdoc override)
This is the devdoc-level override.
```

`tests/fixtures/phase9/plugin_templates/coding_standards.md`:
```markdown
# Coding standards (plugin default)
This is the plugin-shipped default.
```

`tests/fixtures/phase9/plugin_templates/mr_template.md`:
```markdown
# MR template (plugin default)
Title:
Summary:
```

- [ ] **Step 5: Write test helper**

`tests/lib/_helpers.bash`:
```bash
# Shared bats helpers for Phase 9 tooling tests.

setup_phase9_env() {
  PHASE9_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/phase9"
  if [ ! -d "${PHASE9_FIXTURE}" ]; then
    PHASE9_FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/phase9"
  fi
  export PHASE9_FIXTURE

  TEST_TMP="$(mktemp -d)"
  cp -a "${PHASE9_FIXTURE}/devdoc"           "${TEST_TMP}/devdoc"
  cp -a "${PHASE9_FIXTURE}/plugin_templates" "${TEST_TMP}/plugin_templates"
  cp -a "${PHASE9_FIXTURE}/state_dir"        "${TEST_TMP}/state"

  export DEVAGENT_STATE_DIR="${TEST_TMP}/state"
  export DEVAGENT_PLUGIN_TEMPLATES="${TEST_TMP}/plugin_templates"
  export DEVAGENT_TEST_DEVDOC="${TEST_TMP}/devdoc"
  export DEVAGENT_TEST_PROJECT="testproj"

  # Minimal config stub so lib/config.sh shims used in phase 9 resolve.
  export DEVAGENT_CONFIG_OVERRIDE="${TEST_TMP}/config.toml"
  cat > "${DEVAGENT_CONFIG_OVERRIDE}" <<EOF
[project.testproj]
devdoc_dir = "${TEST_TMP}/devdoc"
EOF

  # Path to scripts directory under test.
  DEVAGENT_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  if [ ! -d "${DEVAGENT_REPO_ROOT}/scripts" ]; then
    DEVAGENT_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fi
  export DEVAGENT_REPO_ROOT
  export DEVAGENT_LIB="${DEVAGENT_REPO_ROOT}/scripts/lib"
}

teardown_phase9_env() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "${TEST_TMP}" ]; then
    rm -rf "${TEST_TMP}"
  fi
}
```

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/phase9 tests/lib/_helpers.bash
git commit -s -m "$(cat <<'EOF'
test: add Phase 9 tooling fixtures and bats helper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: depends.sh library — storage primitives

**Files:**
- Create: `scripts/lib/depends.sh`
- Create: `tests/lib/depends.bats`

- [ ] **Step 1: Write the failing test for `depends_add` storing a single edge**

`tests/lib/depends.bats`:
```bash
#!/usr/bin/env bats

load _helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "depends_add writes a single edge to state file" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  [ "$status" -eq 0 ]

  state_file="${DEVAGENT_STATE_DIR}/${DEVAGENT_TEST_PROJECT}.depends.toml"
  [ -f "${state_file}" ]
  grep -q '\[Issue-100\]' "${state_file}"
  grep -q 'depends_on = \["Issue-101"\]' "${state_file}"
}
```

- [ ] **Step 2: Run it and confirm failure**

Run: `bats tests/lib/depends.bats`
Expected: FAIL — `depends.sh` does not exist yet.

- [ ] **Step 3: Implement `depends_add` and storage helpers**

`scripts/lib/depends.sh`:
```bash
# scripts/lib/depends.sh — dependency CRUD, cycle detection, ship pre-flight.
# Storage: <state_dir>/<project>.depends.toml with one table per dependent issue:
#   [Issue-100]
#   depends_on = ["Issue-101", "Issue-102"]
#
# Plain-text TOML is used (not Python tomllib write) so the file stays git/diff
# friendly and editable by hand. We parse with awk to avoid a Python dep.

depends_state_file() {
  # $1 project
  printf '%s/%s.depends.toml\n' "${DEVAGENT_STATE_DIR}" "$1"
}

# depends_list <project> <issue> → prints space-separated dependencies (may be empty)
depends_list() {
  local project="$1" issue="$2"
  local file
  file="$(depends_state_file "${project}")"
  [ -f "${file}" ] || { printf '\n'; return 0; }

  awk -v want="${issue}" '
    BEGIN { in_block = 0 }
    /^\[/ {
      # New table header: [Issue-XYZ]
      header = $0
      sub(/^\[/, "", header); sub(/\]$/, "", header)
      in_block = (header == want) ? 1 : 0
      next
    }
    in_block && /^depends_on[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      gsub(/"/, "", line)
      gsub(/,/, " ", line)
      print line
      exit
    }
  ' "${file}"
}

# depends_add <project> <dependent> <dependency>
depends_add() {
  local project="$1" a="$2" b="$3"
  if [ -z "${project}" ] || [ -z "${a}" ] || [ -z "${b}" ]; then
    printf 'depends_add: usage: depends_add <project> <A> <B>\n' >&2
    return 2
  fi
  if [ "${a}" = "${b}" ]; then
    printf 'depends_add: an issue cannot depend on itself: %s\n' "${a}" >&2
    return 3
  fi

  mkdir -p "${DEVAGENT_STATE_DIR}"
  local file
  file="$(depends_state_file "${project}")"
  [ -f "${file}" ] || : > "${file}"

  # Read existing deps for $a.
  local existing
  existing="$(depends_list "${project}" "${a}")"
  local dep
  for dep in ${existing}; do
    if [ "${dep}" = "${b}" ]; then
      return 0  # already recorded; idempotent
    fi
  done

  # Cycle check before we write.
  if depends_would_cycle "${project}" "${a}" "${b}"; then
    printf 'depends_add: refusing to create cycle: %s depends on %s\n' "${a}" "${b}" >&2
    return 4
  fi

  local new_list="${existing} ${b}"
  # Normalize whitespace.
  new_list="$(printf '%s\n' ${new_list} | sort -u | tr '\n' ' ')"
  depends_write_block "${file}" "${a}" "${new_list}"
}

# depends_write_block <file> <issue> <space-separated-deps>
# Rewrites the [issue] table in-place; appends if absent.
depends_write_block() {
  local file="$1" issue="$2" deps="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v want="${issue}" -v deps="${deps}" '
    BEGIN { in_block = 0; replaced = 0 }
    /^\[/ {
      if (in_block && !printed_block) { printed_block = 1 }
      header = $0
      sub(/^\[/, "", header); sub(/\]$/, "", header)
      if (header == want) {
        in_block = 1; replaced = 1
        print "[" want "]"
        printf "depends_on = ["
        n = split(deps, arr, " ")
        first = 1
        for (i = 1; i <= n; i++) {
          if (arr[i] == "") continue
          if (!first) printf ", "
          printf "\"%s\"", arr[i]
          first = 0
        }
        printf "]\n"
        next
      } else {
        in_block = 0
        print
        next
      }
    }
    in_block && /^depends_on[[:space:]]*=/ { next }  # consumed above
    in_block && /^[[:space:]]*$/ { in_block = 0; print; next }
    { print }
    END {
      if (!replaced) {
        print "[" want "]"
        printf "depends_on = ["
        n = split(deps, arr, " ")
        first = 1
        for (i = 1; i <= n; i++) {
          if (arr[i] == "") continue
          if (!first) printf ", "
          printf "\"%s\"", arr[i]
          first = 0
        }
        printf "]\n"
      }
    }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

# Stub — implemented in Task 3.
depends_would_cycle() { return 1; }

# Stub — implemented in Task 5.
depends_ship_preflight() { return 0; }
```

- [ ] **Step 4: Run the test, expect PASS**

Run: `bats tests/lib/depends.bats`
Expected: PASS (one test).

- [ ] **Step 5: Add idempotence and self-dependency tests**

Append to `tests/lib/depends.bats`:
```bash
@test "depends_add is idempotent for repeated edges" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  count="$(depends_list "${DEVAGENT_TEST_PROJECT}" "Issue-100" | wc -w)"
  [ "${count}" -eq 1 ]
}

@test "depends_add refuses self-dependency" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-100"
  [ "$status" -eq 3 ]
}

@test "depends_add appends a second distinct edge" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-102"
  deps="$(depends_list "${DEVAGENT_TEST_PROJECT}" "Issue-100")"
  echo "${deps}" | grep -q "Issue-101"
  echo "${deps}" | grep -q "Issue-102"
}
```

- [ ] **Step 6: Run and confirm PASS**

Run: `bats tests/lib/depends.bats`
Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/depends.sh tests/lib/depends.bats
git commit -s -m "$(cat <<'EOF'
feat(depends): add dependency storage primitives

Stores per-project depends graph in <state>/<project>.depends.toml
with one TOML table per dependent issue. Idempotent, refuses
self-dependency.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: depends.sh — cycle detection

**Files:**
- Modify: `scripts/lib/depends.sh`
- Modify: `tests/lib/depends.bats`

- [ ] **Step 1: Write the failing cycle-detection test**

Append to `tests/lib/depends.bats`:
```bash
@test "depends_add rejects A->B when B->A already exists" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-100"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "cycle"
}

@test "depends_add rejects transitive cycle A->B->C->A" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-102"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-102" "Issue-100"
  [ "$status" -eq 4 ]
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `bats tests/lib/depends.bats`
Expected: the two new tests FAIL (stub returns "no cycle").

- [ ] **Step 3: Replace the cycle stub with real DFS**

In `scripts/lib/depends.sh`, replace:
```bash
# Stub — implemented in Task 3.
depends_would_cycle() { return 1; }
```
with:
```bash
# depends_would_cycle <project> <new-dependent> <new-dependency>
# Returns 0 (true) if adding the edge would create a cycle.
# Performs DFS from <new-dependency> following existing depends_on edges;
# if we ever reach <new-dependent>, the proposed edge would close a cycle.
depends_would_cycle() {
  local project="$1" a="$2" b="$3"
  local visited_file
  visited_file="$(mktemp)"
  _depends_dfs "${project}" "${b}" "${a}" "${visited_file}"
  local rc=$?
  rm -f "${visited_file}"
  return ${rc}
}

_depends_dfs() {
  local project="$1" node="$2" target="$3" visited_file="$4"
  if [ "${node}" = "${target}" ]; then
    return 0  # cycle found
  fi
  if grep -Fxq "${node}" "${visited_file}" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "${node}" >> "${visited_file}"
  local children child
  children="$(depends_list "${project}" "${node}")"
  for child in ${children}; do
    [ -z "${child}" ] && continue
    if _depends_dfs "${project}" "${child}" "${target}" "${visited_file}"; then
      return 0
    fi
  done
  return 1
}
```

- [ ] **Step 4: Run all depends.bats tests**

Run: `bats tests/lib/depends.bats`
Expected: 6/6 pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/depends.sh tests/lib/depends.bats
git commit -s -m "$(cat <<'EOF'
feat(depends): add DFS-based cycle detection

Rejects both direct (A<->B) and transitive (A->B->C->A) cycles
before writing the edge.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: depends.sh — list / graph rendering

**Files:**
- Modify: `scripts/lib/depends.sh`
- Modify: `tests/lib/depends.bats`

- [ ] **Step 1: Write the failing test for graph rendering**

Append to `tests/lib/depends.bats`:
```bash
@test "depends_graph renders ascii tree" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-102"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-102"
  run depends_graph "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "└── Issue-102"
}

@test "depends_graph on empty project prints '(no dependencies)'" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_graph "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no dependencies"
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/lib/depends.bats -f depends_graph`
Expected: both new tests FAIL (function undefined).

- [ ] **Step 3: Implement `depends_graph` and a node-listing helper**

Append to `scripts/lib/depends.sh`:
```bash
# depends_all_dependents <project> — print every issue that has a [block].
depends_all_dependents() {
  local project="$1"
  local file
  file="$(depends_state_file "${project}")"
  [ -f "${file}" ] || return 0
  awk '/^\[/ { gsub(/^\[|\]$/, ""); print }' "${file}"
}

# depends_graph <project> — ASCII tree of the dependency graph.
depends_graph() {
  local project="$1"
  local roots="" all
  all="$(depends_all_dependents "${project}")"
  if [ -z "${all}" ]; then
    printf '(no dependencies recorded for project %s)\n' "${project}"
    return 0
  fi

  # A "root" is any dependent that is not itself a dependency of anyone.
  local node is_child other deps dep
  for node in ${all}; do
    is_child=0
    for other in ${all}; do
      [ "${other}" = "${node}" ] && continue
      deps="$(depends_list "${project}" "${other}")"
      for dep in ${deps}; do
        [ "${dep}" = "${node}" ] && is_child=1 && break
      done
      [ "${is_child}" -eq 1 ] && break
    done
    [ "${is_child}" -eq 0 ] && roots="${roots} ${node}"
  done

  if [ -z "${roots}" ]; then
    # Pure cycle (shouldn't happen due to cycle check, but be safe).
    roots="${all}"
  fi

  for node in ${roots}; do
    printf '%s\n' "${node}"
    _depends_graph_render "${project}" "${node}" "  "
  done
}

_depends_graph_render() {
  local project="$1" parent="$2" prefix="$3"
  local children child count i
  children="$(depends_list "${project}" "${parent}")"
  count=0
  for child in ${children}; do
    [ -n "${child}" ] && count=$((count + 1))
  done
  [ "${count}" -eq 0 ] && return 0

  i=0
  for child in ${children}; do
    [ -z "${child}" ] && continue
    i=$((i + 1))
    if [ "${i}" -eq "${count}" ]; then
      printf '%s└── %s\n' "${prefix}" "${child}"
      _depends_graph_render "${project}" "${child}" "${prefix}    "
    else
      printf '%s├── %s\n' "${prefix}" "${child}"
      _depends_graph_render "${project}" "${child}" "${prefix}│   "
    fi
  done
}
```

- [ ] **Step 4: Run and expect PASS**

Run: `bats tests/lib/depends.bats`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/depends.sh tests/lib/depends.bats
git commit -s -m "$(cat <<'EOF'
feat(depends): add ascii-tree graph rendering

depends_graph identifies roots (issues no one depends on) and walks
children with box-drawing prefixes. Empty project prints a friendly
message rather than nothing.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: depends.sh — ship pre-flight hook

**Files:**
- Modify: `scripts/lib/depends.sh`
- Modify: `tests/lib/depends.bats`

- [ ] **Step 1: Write the failing test for the ship pre-flight**

The hook signature, agreed with Plan 3:
`depends_ship_preflight <project> <issue> <strict_flag>`
- Looks up dependencies of `<issue>`.
- For each, calls `depends_issue_is_merged <project> <issue>` to check status.
- If any are not merged: prints a warning, returns 0 in non-strict mode (proceed), returns 1 in strict mode (block).
- Empty deps → silent success.

Plan 9 owns the mergedness probe but stubs it to read a file `<issue-dir>/.merged` for testing; the real probe will be wired in a later phase by reading `state/<project>.toml`'s `mr_url` and querying `code/<backend>.sh mr-state`. That stub-then-replace pattern is called out in the in-code comment.

Append to `tests/lib/depends.bats`:
```bash
@test "depends_ship_preflight: no deps → exit 0, silent" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "0"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "depends_ship_preflight: open dep, non-strict → warn, exit 0" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  # Issue-101 has no .merged marker → considered open.
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WARNING"
  echo "$output" | grep -q "Issue-101"
}

@test "depends_ship_preflight: open dep, strict → block, exit 1" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "blocking"
}

@test "depends_ship_preflight: merged dep → silent, exit 0" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  touch "${DEVAGENT_TEST_DEVDOC}/Issue-101/.merged"
  mkdir -p "${DEVAGENT_TEST_DEVDOC}/Issue-101"
  touch "${DEVAGENT_TEST_DEVDOC}/Issue-101/.merged"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "1"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/lib/depends.bats -f preflight`
Expected: 4 new tests fail (stub returns 0 silently for all).

- [ ] **Step 3: Replace the preflight stub with real logic**

In `scripts/lib/depends.sh`, replace:
```bash
# Stub — implemented in Task 5.
depends_ship_preflight() { return 0; }
```
with:
```bash
# depends_issue_is_merged <project> <issue> → exit 0 iff merged.
#
# v1 stub: presence of <issue-dir>/.merged marker file means merged.
# A later phase (sync) will replace this with a state/<project>.toml lookup
# of mr_url + code/<backend>.sh mr-state. Keeping it stubbed here means
# Phase 9 doesn't take a hard dep on backend wiring being live.
depends_issue_is_merged() {
  local project="$1" issue="$2"
  local devdoc
  devdoc="$(_depends_devdoc_dir "${project}")"
  [ -f "${devdoc}/${issue}/.merged" ]
}

_depends_devdoc_dir() {
  local project="$1"
  # Test seam: tests set DEVAGENT_TEST_DEVDOC directly.
  if [ -n "${DEVAGENT_TEST_DEVDOC:-}" ]; then
    printf '%s\n' "${DEVAGENT_TEST_DEVDOC}"
    return 0
  fi
  # Production: defer to lib/config.sh.
  if command -v config_get_project_field >/dev/null 2>&1; then
    config_get_project_field "${project}" "devdoc_dir"
    return 0
  fi
  printf '%s/devdoc\n' "${HOME}"
}

# depends_ship_preflight <project> <issue> <strict>
#   strict=0 → warn-only, exit 0
#   strict=1 → block on any unmerged dep, exit 1
depends_ship_preflight() {
  local project="$1" issue="$2" strict="${3:-0}"
  local deps dep open_deps=""
  deps="$(depends_list "${project}" "${issue}")"
  for dep in ${deps}; do
    [ -z "${dep}" ] && continue
    if ! depends_issue_is_merged "${project}" "${dep}"; then
      open_deps="${open_deps} ${dep}"
    fi
  done
  if [ -z "${open_deps}" ]; then
    return 0
  fi
  if [ "${strict}" = "1" ]; then
    printf 'depends: blocking ship of %s — open dependencies:%s\n' \
      "${issue}" "${open_deps}" >&2
    return 1
  fi
  printf 'WARNING: %s has unmerged dependencies:%s (use --strict-deps to block)\n' \
    "${issue}" "${open_deps}"
  return 0
}
```

- [ ] **Step 4: Run all depends.bats tests**

Run: `bats tests/lib/depends.bats`
Expected: all tests pass (10 total).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/depends.sh tests/lib/depends.bats
git commit -s -m "$(cat <<'EOF'
feat(depends): add ship pre-flight hook

depends_ship_preflight is called by ship.sh (Plan 3 integration
point) before opening an MR. Warns by default, blocks under
--strict-deps. Mergedness probe is a stub (.merged marker file);
real backend probe to be wired in a later phase.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: depends.sh CLI entry point

**Files:**
- Create: `scripts/depends.sh`
- Create: `tests/depends.bats`

- [ ] **Step 1: Write failing CLI tests**

`tests/depends.bats`:
```bash
#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "depends.sh: <A> on <B> records edge" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100 on Issue-101
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "recorded"
  state_file="${DEVAGENT_STATE_DIR}/${DEVAGENT_TEST_PROJECT}.depends.toml"
  grep -q '\[Issue-100\]' "${state_file}"
}

@test "depends.sh list prints graph" {
  bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100 on Issue-101
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-101"
}

@test "depends.sh rejects cycle with non-zero exit and message" {
  bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100 on Issue-101
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-101 on Issue-100
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cycle"
}

@test "depends.sh usage on missing args" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "usage"
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/depends.bats`
Expected: all tests fail (script doesn't exist).

- [ ] **Step 3: Implement the CLI**

`scripts/depends.sh`:
```bash
#!/usr/bin/env bash
# scripts/depends.sh — entry point for /devagent:depends
#
# Grammar:
#   depends.sh [--project P] <A> on <B>      record A depends on B
#   depends.sh [--project P] list            print graph
#
# Project resolution: --project flag wins; otherwise tries
# DEVAGENT_ACTIVE_PROJECT env var; otherwise errors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends.sh
. "${SCRIPT_DIR}/lib/depends.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:depends [project] <A> on <B>
  /devagent:depends [project] list

Examples:
  /devagent:depends volk Issue-676 on Issue-Fork-12
  /devagent:depends list
EOF
  exit 2
}

PROJECT=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    -h|--help) usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'depends: no project specified and DEVAGENT_ACTIVE_PROJECT unset\n' >&2
  usage
fi

if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
fi

# Detect subcommand vs edge form.
if [ "${ARGS[0]}" = "list" ]; then
  depends_graph "${PROJECT}"
  exit 0
fi

# Edge form: <A> on <B>
if [ "${#ARGS[@]}" -ne 3 ] || [ "${ARGS[1]}" != "on" ]; then
  printf 'depends: expected "<A> on <B>" got: %s\n' "${ARGS[*]}" >&2
  usage
fi

A="${ARGS[0]}"
B="${ARGS[2]}"
if depends_add "${PROJECT}" "${A}" "${B}"; then
  printf 'recorded: %s depends on %s\n' "${A}" "${B}"
else
  exit $?
fi
```

- [ ] **Step 4: Make executable and run tests**

```bash
chmod +x scripts/depends.sh
bats tests/depends.bats
```
Expected: 4/4 pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/depends.sh tests/depends.bats
git commit -s -m "$(cat <<'EOF'
feat(depends): add CLI entry point scripts/depends.sh

Implements the /devagent:depends grammar: "[project] A on B" and
"[project] list". Resolves project from --project flag, then
DEVAGENT_ACTIVE_PROJECT env var.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: depends slash command markdown

**Files:**
- Create: `commands/depends.md`

- [ ] **Step 1: Write the command file**

`commands/depends.md`:
```markdown
---
description: Record or list issue dependencies (Issue-A depends on Issue-B).
allowed-tools: [Bash]
---

# /devagent:depends

Record or display dependencies between issues.

## Forms

- `/devagent:depends <A> on <B>` — record that Issue A depends on Issue B.
- `/devagent:depends list` — print the dependency graph for the active project.
- `/devagent:depends <project> list` — print the graph for a named project.

## Behavior

- Refuses to create a cycle (direct or transitive).
- Idempotent: re-recording the same edge is a no-op.
- Refuses self-dependency.
- `ship.sh` calls a pre-flight hook (`depends_ship_preflight`) that warns
  when an issue is shipped with unmerged dependencies. Pass `--strict-deps`
  to `/devagent:ship` to escalate the warning to a hard block.

## Invocation

Run the entry script with the parsed arguments:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/depends.sh" $ARGUMENTS
```
```

- [ ] **Step 2: Commit**

```bash
git add commands/depends.md
git commit -s -m "$(cat <<'EOF'
feat(commands): add /devagent:depends slash command

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: grep.sh entry point

**Files:**
- Create: `scripts/grep.sh`
- Create: `tests/grep.bats`

- [ ] **Step 1: Write failing tests**

`tests/grep.bats`:
```bash
#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "grep finds keyword across issue.md and imPlan.md" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100/issue.md"
  echo "$output" | grep -q "Issue-100/imPlan.md"
}

@test "grep does NOT search Captures by default" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Captures/"
}

@test "grep --captures includes Captures" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" --captures FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Captures/"
}

@test "grep -i passes through case-insensitive" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" -i foobar
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100/issue.md"
}

@test "grep -l prints only filenames" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" -l FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "issue.md"
  ! echo "$output" | grep -q "FOOBAR"
}

@test "grep prints output in <issue-dir>:<file>:<line>: form" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" FOOBAR
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^[^:]*Issue-100/issue\.md:[0-9]+:'
}

@test "grep exits 1 when pattern not found, 2 on usage error" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" ZZZ_NO_MATCH_ZZZ
  [ "$status" -eq 1 ]

  run bash "${DEVAGENT_REPO_ROOT}/scripts/grep.sh"
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/grep.bats`
Expected: all fail (script absent).

- [ ] **Step 3: Implement scripts/grep.sh**

`scripts/grep.sh`:
```bash
#!/usr/bin/env bash
# scripts/grep.sh — entry point for /devagent:grep
#
# Greps across per-issue artifact files only (no Captures by default).
# Output: <issue-dir>:<file>:<line-num>: <matching-line>
#
# Supports -i and -l flag pass-through (standard grep semantics).
# Adds --captures to also search <devdoc>/Captures/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends.sh
. "${SCRIPT_DIR}/lib/depends.sh"  # for _depends_devdoc_dir

ARTIFACT_FILES=(
  "issue.md"
  "imPlan.md"
  "imPlan-potentialFutureEnhancements.md"
  "actualWork.md"
  "mr.md"
  "checklist.md"
)

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:grep [project] [-i] [-l] [--captures] <pattern>

Searches: issue.md, imPlan.md, imPlan-potentialFutureEnhancements.md,
          actualWork.md, mr.md, checklist.md across all issue dirs.

Output: <issue-dir>:<file>:<line-num>: <matching-line>
EOF
  exit 2
}

PROJECT=""
GREP_OPTS=()
INCLUDE_CAPTURES=0
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --captures) INCLUDE_CAPTURES=1; shift ;;
    -i|-l|-iL|-li) GREP_OPTS+=("$1"); shift ;;
    -h|--help) usage ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) GREP_OPTS+=("$1"); shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'grep: no project specified and DEVAGENT_ACTIVE_PROJECT unset\n' >&2
  usage
fi
if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
fi

PATTERN="${ARGS[0]}"

DEVDOC="$(_depends_devdoc_dir "${PROJECT}")"
if [ ! -d "${DEVDOC}" ]; then
  printf 'grep: devdoc dir not found: %s\n' "${DEVDOC}" >&2
  exit 2
fi

# Build the include list for grep.
INCLUDES=()
for f in "${ARTIFACT_FILES[@]}"; do
  INCLUDES+=(--include="${f}")
done

# Build the exclude list.
EXCLUDES=()
if [ "${INCLUDE_CAPTURES}" -eq 0 ]; then
  EXCLUDES+=(--exclude-dir=Captures)
fi
EXCLUDES+=(--exclude-dir=templates)
EXCLUDES+=(--exclude-dir=StatusReports)

# Run grep. -H always prints filename; -n line number; -R recursive.
grep -RnH "${GREP_OPTS[@]}" "${INCLUDES[@]}" "${EXCLUDES[@]}" -- \
  "${PATTERN}" "${DEVDOC}"
exit $?
```

- [ ] **Step 4: Make executable and run**

```bash
chmod +x scripts/grep.sh
bats tests/grep.bats
```
Expected: 7/7 pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/grep.sh tests/grep.bats
git commit -s -m "$(cat <<'EOF'
feat(grep): add /devagent:grep entry point

Wraps grep -RnH with --include filters for the six per-issue
artifact files. Excludes Captures by default (--captures opts in).
Pass-through for -i and -l. Exit codes follow grep convention:
0 found, 1 not found, 2 usage.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: grep slash command markdown

**Files:**
- Create: `commands/grep.md`

- [ ] **Step 1: Write the command file**

`commands/grep.md`:
```markdown
---
description: Grep across all per-issue artifact files in a project's devdoc.
allowed-tools: [Bash]
---

# /devagent:grep

Searches across all issue directories for a project, hitting only the
canonical artifact files: `issue.md`, `imPlan.md`,
`imPlan-potentialFutureEnhancements.md`, `actualWork.md`, `mr.md`,
`checklist.md`.

## Usage

```
/devagent:grep [project] [-i] [-l] [--captures] <pattern>
```

- `-i` — case-insensitive (pass-through to grep)
- `-l` — print filenames only (pass-through to grep)
- `--captures` — also search `<devdoc>/Captures/` (off by default)

## Output

```
<issue-dir>:<file>:<line-num>: <matching-line>
```

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grep.sh" $ARGUMENTS
```
```

- [ ] **Step 2: Commit**

```bash
git add commands/grep.md
git commit -s -m "$(cat <<'EOF'
feat(commands): add /devagent:grep slash command

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: history.sh library

**Files:**
- Create: `scripts/lib/history.sh`
- Create: `tests/lib/history.bats`

The history command merges per-issue checklist log lines chronologically. Plan 1's `scripts/lib/checklist.sh` exposes a function `checklist_log_entries <file>` returning `ISO-TS|step|message` rows. If Plan 1 names it differently we adapt by reading the file directly here — this task includes a minimal parser so Phase 9 does not block on Plan 1's exact function names.

- [ ] **Step 1: Write the failing tests**

`tests/lib/history.bats`:
```bash
#!/usr/bin/env bats

load _helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "history_parse_log extracts entries from a checklist file" {
  source "${DEVAGENT_LIB}/history.sh"
  run history_parse_log "${DEVAGENT_TEST_DEVDOC}/Issue-100/checklist.md" "Issue-100"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2026-05-10 09:00|Issue-100|pull|fetched"
  echo "$output" | grep -q "2026-05-10 09:12|Issue-100|draft|imPlan.md written"
}

@test "history_project merges entries across issues, sorted ascending" {
  source "${DEVAGENT_LIB}/history.sh"
  run history_project "${DEVAGENT_TEST_DEVDOC}"
  [ "$status" -eq 0 ]
  # Earliest entry should be Issue-101's pull at 2026-05-09 08:00.
  first_line="$(echo "$output" | head -n1)"
  echo "${first_line}" | grep -q "2026-05-09"
  echo "${first_line}" | grep -q "Issue-101"
  # Must contain Issue-100 and Issue-102 entries too.
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-102"
}

@test "history_issue returns only one issue's entries" {
  source "${DEVAGENT_LIB}/history.sh"
  run history_issue "${DEVAGENT_TEST_DEVDOC}/Issue-100"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  ! echo "$output" | grep -q "Issue-101"
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/lib/history.bats`
Expected: 3 fail.

- [ ] **Step 3: Implement scripts/lib/history.sh**

`scripts/lib/history.sh`:
```bash
# scripts/lib/history.sh — chronological log merge across issues.
#
# Log line format (set by Plan 1's checklist library, see spec §5.2):
#   - YYYY-MM-DD HH:MM  <step>: <message>
#
# Output row format (pipe-delimited, stable for downstream parsing):
#   YYYY-MM-DD HH:MM|<issue>|<step>|<message>

# history_parse_log <checklist-file> <issue-id>
# Reads a single checklist.md, prints one row per log entry.
history_parse_log() {
  local file="$1" issue="$2"
  [ -f "${file}" ] || return 0
  awk -v issue="${issue}" '
    /^## *Log/ { in_log = 1; next }
    in_log && /^## / { in_log = 0; next }
    in_log && /^- *[0-9]{4}-[0-9]{2}-[0-9]{2} +[0-9]{2}:[0-9]{2} +/ {
      line = $0
      sub(/^- */, "", line)
      # Split off timestamp (date + time = first 16 chars after dash).
      ts = substr(line, 1, 16)
      rest = substr(line, 17)
      # Trim leading spaces.
      sub(/^ +/, "", rest)
      # rest looks like: "step: message"
      colon = index(rest, ":")
      if (colon == 0) {
        step = rest; msg = ""
      } else {
        step = substr(rest, 1, colon - 1)
        msg  = substr(rest, colon + 1)
        sub(/^ +/, "", msg)
      }
      printf "%s|%s|%s|%s\n", ts, issue, step, msg
    }
  ' "${file}"
}

# history_issue <issue-dir> — prints sorted log for one issue.
history_issue() {
  local dir="$1"
  local id
  id="$(basename "${dir}")"
  history_parse_log "${dir}/checklist.md" "${id}" | LC_ALL=C sort
}

# history_project <devdoc-dir> — merges all Issue-* dirs, sorted ascending.
history_project() {
  local devdoc="$1"
  [ -d "${devdoc}" ] || return 0
  local issue_dir id
  for issue_dir in "${devdoc}"/Issue-*/; do
    [ -d "${issue_dir}" ] || continue
    id="$(basename "${issue_dir}")"
    history_parse_log "${issue_dir}/checklist.md" "${id}"
  done | LC_ALL=C sort
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `bats tests/lib/history.bats`
Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/history.sh tests/lib/history.bats
git commit -s -m "$(cat <<'EOF'
feat(history): add log-merge library

history_parse_log extracts log entries from one checklist.md;
history_project merges across all Issue-* dirs sorted ascending.
Output is pipe-delimited (ts|issue|step|message) for downstream
formatting.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: history.sh CLI + command

**Files:**
- Create: `scripts/history.sh`
- Create: `tests/history.bats`
- Create: `commands/history.md`

- [ ] **Step 1: Write failing CLI tests**

`tests/history.bats`:
```bash
#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "history.sh whole project prints all entries sorted" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-101"
  echo "$output" | grep -q "Issue-102"
}

@test "history.sh issue scoped prints one issue only" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  ! echo "$output" | grep -q "Issue-101"
}

@test "history.sh output format is human-readable" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^2026-05-10 09:00 +Issue-100 +pull: +fetched'
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/history.bats`
Expected: all fail.

- [ ] **Step 3: Implement scripts/history.sh**

`scripts/history.sh`:
```bash
#!/usr/bin/env bash
# scripts/history.sh — entry point for /devagent:history
#
# Forms:
#   history.sh [--project P]                 → all issues in project
#   history.sh [--project P] Issue-NNN       → one issue
#
# Output: "<ts>  <issue>  <step>: <message>" columns aligned with spaces.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/depends.sh
. "${SCRIPT_DIR}/lib/depends.sh"  # for _depends_devdoc_dir
# shellcheck source=lib/history.sh
. "${SCRIPT_DIR}/lib/history.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:history [project] [Issue-NNN]
EOF
  exit 2
}

PROJECT=""
ISSUE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    -h|--help) usage ;;
    Issue-*|Issue-Fork-*) ISSUE="$1"; shift ;;
    *) ISSUE="$1"; shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'history: no project specified\n' >&2
  usage
fi

DEVDOC="$(_depends_devdoc_dir "${PROJECT}")"
if [ ! -d "${DEVDOC}" ]; then
  printf 'history: devdoc dir not found: %s\n' "${DEVDOC}" >&2
  exit 2
fi

format_rows() {
  awk -F'|' '{ printf "%s  %-14s  %s: %s\n", $1, $2, $3, $4 }'
}

if [ -n "${ISSUE}" ]; then
  history_issue "${DEVDOC}/${ISSUE}" | format_rows
else
  history_project "${DEVDOC}" | format_rows
fi
```

- [ ] **Step 4: Make executable, run**

```bash
chmod +x scripts/history.sh
bats tests/history.bats
```
Expected: 3/3 pass.

- [ ] **Step 5: Write commands/history.md**

```markdown
---
description: Show chronological log across a project or single issue.
allowed-tools: [Bash]
---

# /devagent:history

Concatenated, chronologically-merged log view drawn from the `## Log`
section of each issue's `checklist.md`.

## Usage

```
/devagent:history [project] [Issue-NNN]
```

Without an issue, prints every project log entry ascending. With an
issue, restricts to that issue only.

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/history.sh" $ARGUMENTS
```
```

- [ ] **Step 6: Commit**

```bash
git add scripts/history.sh tests/history.bats commands/history.md
git commit -s -m "$(cat <<'EOF'
feat(history): add /devagent:history command

CLI wraps lib/history.sh, formats pipe-delimited rows into
human-readable aligned columns.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: template_resolve.sh library

**Files:**
- Create: `scripts/lib/template_resolve.sh`
- Create: `tests/lib/template_resolve.bats`

- [ ] **Step 1: Write failing tests for resolution order**

`tests/lib/template_resolve.bats`:
```bash
#!/usr/bin/env bats

load _helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "template_resolve: devdoc override wins over plugin default" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "devdoc/templates/coding_standards.md"
  echo "$output" | grep -q "layer=devdoc"
}

@test "template_resolve: falls back to plugin templates when no devdoc override" {
  rm "${DEVAGENT_TEST_DEVDOC}/templates/coding_standards.md"
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "plugin_templates/coding_standards.md"
  echo "$output" | grep -q "layer=plugin"
}

@test "template_resolve: project paths override wins over devdoc" {
  override="${TEST_TMP}/my_custom_standards.md"
  printf '# project override\n' > "${override}"
  source "${DEVAGENT_LIB}/template_resolve.sh"
  TEMPLATE_PATHS_OVERRIDE_coding_standards="${override}" \
    run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "my_custom_standards.md"
  echo "$output" | grep -q "layer=project"
}

@test "template_resolve: missing template returns 1" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "no_such_template"
  [ "$status" -eq 1 ]
}

@test "template_list enumerates known artifact keys" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_list "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
  echo "$output" | grep -q "mr_template"
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "layer=plugin"
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/lib/template_resolve.bats`
Expected: all 5 fail.

- [ ] **Step 3: Implement scripts/lib/template_resolve.sh**

`scripts/lib/template_resolve.sh`:
```bash
# scripts/lib/template_resolve.sh — three-layer template resolution.
# Order (per spec §12):
#   1. [project.<name>.paths].<key>  → file path
#   2. <devdoc>/templates/<key>.md
#   3. <plugin>/templates/<key>.md   (DEVAGENT_PLUGIN_TEMPLATES env)

# Canonical artifact key list (spec §12 table). Sourced once at load time.
DEVAGENT_TEMPLATE_KEYS=(
  coding_standards
  commit_template
  mr_template
  issue_template-bug
  issue_template-feature
  issue_template-docs
  issue_template-perf
  issue_template-chore
  epic_template
  redteam_issue
  redteam_mr
  imPlan_template
  actualWork_template
  lessonsLearned_template
  wbs_template
  statusreport_template
)

# template_project_paths_override <project> <key>
# Returns absolute path from [project.<P>.paths].<key>, or empty.
# Tests can short-circuit via TEMPLATE_PATHS_OVERRIDE_<key> env var.
template_project_paths_override() {
  local project="$1" key="$2"
  local env_name="TEMPLATE_PATHS_OVERRIDE_${key//-/_}"
  if [ -n "${!env_name:-}" ]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi
  if command -v config_get_project_paths_field >/dev/null 2>&1; then
    config_get_project_paths_field "${project}" "${key}" || true
  fi
}

# template_devdoc_dir <project> — mirror of _depends_devdoc_dir.
template_devdoc_dir() {
  local project="$1"
  if [ -n "${DEVAGENT_TEST_DEVDOC:-}" ]; then
    printf '%s\n' "${DEVAGENT_TEST_DEVDOC}"; return 0
  fi
  if command -v config_get_project_field >/dev/null 2>&1; then
    config_get_project_field "${project}" "devdoc_dir"
    return 0
  fi
  printf '%s/devdoc\n' "${HOME}"
}

# template_resolve <project> <key>
# Prints two lines (or single combined line) describing the winner:
#   path=<absolute path>
#   layer=<project|devdoc|plugin>
# Returns 1 if no layer satisfies.
template_resolve() {
  local project="$1" key="$2"
  local path

  # Layer 1: project paths override.
  path="$(template_project_paths_override "${project}" "${key}")"
  if [ -n "${path}" ] && [ -f "${path}" ]; then
    printf 'path=%s\nlayer=project\n' "${path}"
    return 0
  fi

  # Layer 2: devdoc templates.
  local devdoc
  devdoc="$(template_devdoc_dir "${project}")"
  path="${devdoc}/templates/${key}.md"
  if [ -f "${path}" ]; then
    printf 'path=%s\nlayer=devdoc\n' "${path}"
    return 0
  fi

  # Layer 3: plugin templates.
  path="${DEVAGENT_PLUGIN_TEMPLATES:-${DEVAGENT_REPO_ROOT:-}/templates}/${key}.md"
  if [ -f "${path}" ]; then
    printf 'path=%s\nlayer=plugin\n' "${path}"
    return 0
  fi

  return 1
}

# template_list <project> — table of all known keys + resolved layer.
template_list() {
  local project="$1"
  local key out
  printf '%-32s %-8s %s\n' "KEY" "LAYER" "PATH"
  for key in "${DEVAGENT_TEMPLATE_KEYS[@]}"; do
    if out="$(template_resolve "${project}" "${key}")"; then
      local p l
      p="$(printf '%s\n' "${out}" | sed -n 's/^path=//p')"
      l="$(printf '%s\n' "${out}" | sed -n 's/^layer=//p')"
      printf '%-32s layer=%-7s %s\n' "${key}" "${l}" "${p}"
    else
      printf '%-32s layer=%-7s %s\n' "${key}" "MISSING" "(none)"
    fi
  done
}

# template_show <project> <key> — print resolved layer banner + file contents.
template_show() {
  local project="$1" key="$2"
  local out p l
  if ! out="$(template_resolve "${project}" "${key}")"; then
    printf 'template_show: no template found for key: %s\n' "${key}" >&2
    return 1
  fi
  p="$(printf '%s\n' "${out}" | sed -n 's/^path=//p')"
  l="$(printf '%s\n' "${out}" | sed -n 's/^layer=//p')"
  printf '# === template %s (layer=%s) ===\n' "${key}" "${l}"
  printf '# source: %s\n\n' "${p}"
  cat "${p}"
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `bats tests/lib/template_resolve.bats`
Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/template_resolve.sh tests/lib/template_resolve.bats
git commit -s -m "$(cat <<'EOF'
feat(template): add three-layer template resolution library

Resolves in spec §12 order: project paths → devdoc/templates →
plugin templates. Provides template_resolve, template_list,
template_show. Honors DEVAGENT_TEST_DEVDOC and
TEMPLATE_PATHS_OVERRIDE_<key> for testability.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: template.sh CLI + command

**Files:**
- Create: `scripts/template.sh`
- Create: `tests/template.bats`
- Create: `commands/template.md`

- [ ] **Step 1: Write failing CLI tests**

`tests/template.bats`:
```bash
#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "template.sh list shows all keys with their layer" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "mr_template"
  echo "$output" | grep -q "layer=plugin"
}

@test "template.sh show prints layer banner and content" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show coding_standards
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "devdoc override"
}

@test "template.sh show on missing template exits non-zero" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show no_such_thing
  [ "$status" -ne 0 ]
}

@test "template.sh: project override wins over devdoc, shown in banner" {
  override="${TEST_TMP}/proj_standards.md"
  printf '# project layer override\n' > "${override}"
  TEMPLATE_PATHS_OVERRIDE_coding_standards="${override}" \
    run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
      --project "${DEVAGENT_TEST_PROJECT}" show coding_standards
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=project"
  echo "$output" | grep -q "project layer override"
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/template.bats`
Expected: 4 fail.

- [ ] **Step 3: Implement scripts/template.sh**

`scripts/template.sh`:
```bash
#!/usr/bin/env bash
# scripts/template.sh — entry point for /devagent:template
#
# Subcommands:
#   list                 print resolution table for all known keys
#   show <key>           print resolved content with layer banner

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/template_resolve.sh
. "${SCRIPT_DIR}/lib/template_resolve.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  /devagent:template [project] list
  /devagent:template [project] show <key>
EOF
  exit 2
}

PROJECT=""
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    -h|--help) usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ -z "${PROJECT}" ]; then
  PROJECT="${DEVAGENT_ACTIVE_PROJECT:-}"
fi
if [ -z "${PROJECT}" ]; then
  printf 'template: no project specified\n' >&2
  usage
fi
if [ "${#ARGS[@]}" -eq 0 ]; then
  usage
fi

case "${ARGS[0]}" in
  list)
    template_list "${PROJECT}"
    ;;
  show)
    if [ "${#ARGS[@]}" -lt 2 ]; then
      printf 'template show: <key> required\n' >&2
      usage
    fi
    template_show "${PROJECT}" "${ARGS[1]}"
    ;;
  *)
    printf 'template: unknown subcommand: %s\n' "${ARGS[0]}" >&2
    usage
    ;;
esac
```

- [ ] **Step 4: Make executable, run**

```bash
chmod +x scripts/template.sh
bats tests/template.bats
```
Expected: 4/4 pass.

- [ ] **Step 5: Write commands/template.md**

```markdown
---
description: Inspect resolved artifact templates (list or show).
allowed-tools: [Bash]
---

# /devagent:template

Inspect which template file the plugin will use for a given artifact
key, using the three-layer resolution order from spec §12:

1. `[project.<name>.paths].<key>` in `~/.claude/devagent/config.toml`
2. `<devdoc>/templates/<key>.md`
3. `<plugin>/templates/<key>.md` (shipped default)

## Usage

```
/devagent:template [project] list
/devagent:template [project] show <key>
```

`list` prints a table of every known artifact key, the winning
layer, and the path it resolved to.

`show <key>` prints the resolved content of one template, prefixed
by a banner indicating which layer it came from.

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/template.sh" $ARGUMENTS
```
```

- [ ] **Step 6: Commit**

```bash
git add scripts/template.sh tests/template.bats commands/template.md
git commit -s -m "$(cat <<'EOF'
feat(template): add /devagent:template list|show command

CLI wraps lib/template_resolve.sh. show prints a layer banner
followed by content so operators can see at a glance which
layer (project/devdoc/plugin) won.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Coordination doc + ship.sh integration spec

**Files:**
- Create: `docs/superpowers/plans/2026-05-19-devagent-09-tooling-COORDINATION.md`

This task records the one-line edit Plan 3's executor must make to `ship.sh`. It is a doc-only task; we do not modify Plan 3's files from here.

- [ ] **Step 1: Write the coordination note**

`docs/superpowers/plans/2026-05-19-devagent-09-tooling-COORDINATION.md`:
```markdown
# Phase 9 → Phase 3 Coordination

Phase 9 introduces `depends_ship_preflight`, called by `ship.sh` before
opening an MR. Plan 3's executor should add the following block to
`scripts/ship.sh` immediately after argument parsing, before the call
to `code/<backend>.sh create-mr`:

```bash
# Phase 9: warn (or block under --strict-deps) when shipping an issue
# whose recorded dependencies have not yet been merged.
. "${DEVAGENT_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib}/depends.sh"
STRICT_DEPS="${STRICT_DEPS:-0}"
if ! depends_ship_preflight "${PROJECT}" "${ACTIVE_ISSUE}" "${STRICT_DEPS}"; then
  exit 2
fi
```

Plan 3 must also:
- Accept a `--strict-deps` CLI flag and export `STRICT_DEPS=1` when set.
- Document the flag in `commands/ship.md`.

If Plan 9 lands after Plan 3: Plan 3's `. depends.sh` line will fail
until Plan 9 lands. Workaround during the gap: Plan 3 can wrap the
source in `[ -f ... ] && . ... || true` to keep ship.sh functional.

If Plan 9 lands before Plan 3: nothing to do — `scripts/lib/depends.sh`
is harmless on its own.

`/devagent:where` (Plan 2) should also call `depends_ship_preflight`
in warn-only mode when the active issue's next step is `ship`, so the
operator sees the warning at the planning stage. The exact insertion
point is up to Plan 2's executor; the function signature is stable.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-05-19-devagent-09-tooling-COORDINATION.md
git commit -s -m "$(cat <<'EOF'
docs: add Phase 9 coordination note for ship.sh integration

Records the exact ship.sh edit Plan 3 needs to call
depends_ship_preflight, and the equivalent /devagent:where hook
for Plan 2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: End-to-end smoke + final test sweep

**Files:** (no new files)

- [ ] **Step 1: Run the entire Phase 9 test sweep**

```bash
bats tests/lib/depends.bats tests/lib/history.bats tests/lib/template_resolve.bats \
     tests/depends.bats tests/grep.bats tests/history.bats tests/template.bats
```
Expected: all tests pass, no skips.

- [ ] **Step 2: Smoke the four commands by hand against the fixture**

```bash
export DEVAGENT_STATE_DIR="$(mktemp -d)"
export DEVAGENT_TEST_DEVDOC="$(pwd)/tests/fixtures/phase9/devdoc"
export DEVAGENT_PLUGIN_TEMPLATES="$(pwd)/tests/fixtures/phase9/plugin_templates"
export DEVAGENT_ACTIVE_PROJECT="testproj"

bash scripts/depends.sh Issue-100 on Issue-101
bash scripts/depends.sh list
bash scripts/grep.sh FOOBAR
bash scripts/history.sh
bash scripts/history.sh Issue-100
bash scripts/template.sh list
bash scripts/template.sh show coding_standards

rm -rf "${DEVAGENT_STATE_DIR}"
```

Expected output highlights:
- `depends list` shows `Issue-100 └── Issue-101`
- `grep` returns matches in `Issue-100/issue.md` and `Issue-100/imPlan.md`, no Captures hits
- `history` shows Issue-101's 2026-05-09 entry first
- `template show coding_standards` prints `layer=devdoc` banner

- [ ] **Step 3: Lint scripts with shellcheck**

```bash
shellcheck scripts/depends.sh scripts/grep.sh scripts/history.sh \
           scripts/template.sh scripts/lib/depends.sh \
           scripts/lib/history.sh scripts/lib/template_resolve.sh
```
Expected: clean (warnings about external `config_get_project_field` are acceptable; suppress with `# shellcheck disable=SC2034` only if shellcheck flags an unused-var false positive).

- [ ] **Step 4: Final commit (only if shellcheck or smoke surfaced fixes)**

If you made edits in step 3, commit them:
```bash
git add -p   # review hunks
git commit -s -m "$(cat <<'EOF'
chore(phase9): shellcheck cleanup

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

If nothing changed, skip the commit. Phase 9 is complete.

---

## Self-Review Notes

**Spec coverage check (§6.5 row by row):**
- `/devagent:depends <A> on <B>` → Tasks 2, 6 (lib + CLI), command in Task 7
- `/devagent:where` / `/devagent:next` warning hook → Task 5 implements `depends_ship_preflight`; Task 14 documents how Plan 2 wires it
- `/devagent:depends list` → Task 4 (`depends_graph`), exposed in Task 6 CLI
- `/devagent:grep` with `-i` / `-l` pass-through → Task 8
- `/devagent:history [project] [issue]` → Tasks 10, 11
- `/devagent:template list` → Task 12 (`template_list`), Task 13 CLI
- `/devagent:template show <name>` → Task 12 (`template_show`), Task 13 CLI

**§12 template resolution order:** Task 12 implements project → devdoc → plugin in that exact order; Task 13 test "project override wins over devdoc, shown in banner" asserts the project layer is preferred.

**Cycle detection requirement:** Task 3 tests both direct (A↔B) and transitive (A→B→C→A) cycles.

**Grep does not leak into Captures unless asked:** Task 8 tests assert `Captures/` is excluded by default and included only with `--captures`.

**Ship integration:** Task 5 implements the hook; Task 14 records the exact ship.sh edit and the gap-tolerant workaround.

## Open Questions

1. **Project paths config reader name.** Task 12 calls `config_get_project_paths_field` (Plan 1 helper). If Plan 1 names it differently (e.g., `config_paths_lookup`), the executor must rename one line in `template_project_paths_override`. The test seam (`TEMPLATE_PATHS_OVERRIDE_<key>`) means tests pass either way.
2. **Mergedness probe is stubbed.** `depends_issue_is_merged` reads a `.merged` marker file. A follow-on phase (likely `sync` in Plan 7) should replace it with a real lookup of `state/<project>.toml`'s `mr_url` plus `code/<backend>.sh mr-state`. Documented in the in-code comment and in the coordination doc.
3. **`/devagent:where` hook insertion point.** Plan 2 owns `where.sh`; this plan only documents the contract. If Plan 2's executor would prefer a different return convention (e.g., "warnings as structured TOML" rather than text), the depends_ship_preflight signature would need a v2.
4. **TOML write format.** The depends state file is written as plain text TOML via awk to avoid a Python dep. If Plan 1 standardizes on `tomli_w` or `dasel` for state files, this plan's writer should be migrated to match — straightforward swap, no schema change.
