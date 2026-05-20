# devAgent Phase 5 — Capture Family Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the capture family of devAgent commands (`capture`, `scaffold`, `redissue`, `file`, `reap`) which produce pre-issue draft artifacts under `<devdoc>/Captures/<slug>/`, gate remote filing through `permissions.push_mr`, and idempotently harvest follow-up candidates from prior issue dirs.

**Architecture:** Each command is a thin slash-command markdown file under `commands/` that delegates to either a shell script under `scripts/capture/` (mechanical work: slug, dir, file IO, backend dispatch, hash-based dedupe) or a custom skill under `skills/devagent-<name>/` (judgment work: type detection, child bin-packing, red-team analysis). Scripts source shared libraries from `scripts/lib/` (config loader, slug helper, capture path helper) defined in Phase 1. The `issue/<backend>.sh create` verb invoked by `/devagent:file` is defined in Phase 2 (github) and Phase 10 (others); this plan consumes that contract only.

**Tech Stack:** POSIX bash (scripts), Python 3 (slug + hash helpers when shell falls short), bats (shell tests), pytest (python tests), markdown (templates, slash-command files, skill files), TOML (state files via inline shell parsing — same pattern Phase 1 establishes).

---

## Scope Check

This plan covers exactly Phase 5 from spec §21: the capture family. It does not implement workflow steps (Phase 3/4), backends (Phase 2/10), or the shared `scripts/lib/` helpers (Phase 1). Where this plan needs a Phase 1 helper that may not yet exist, it provides a minimal local stub in `scripts/capture/lib/` so the plan is testable in isolation; the stub will be replaced by the canonical helper when Phase 1 lands.

---

## File Structure

**Slash command markdown (commands/):**
- `commands/capture.md` — dispatch (no subverb / `issue` / `epic`)
- `commands/scaffold.md`
- `commands/redissue.md`
- `commands/file.md`
- `commands/reap.md`

**Scripts (scripts/capture/):**
- `scripts/capture/capture.sh` — slug + dir + writes `draft.md` from a chosen template
- `scripts/capture/file.sh` — calls `issue/<backend>.sh create`, writes `filed.toml`
- `scripts/capture/reap.sh` — scan + draft + record content hashes
- `scripts/capture/lib/slug.sh` — `YYYY-MM-DD-<kebab>` from title
- `scripts/capture/lib/paths.sh` — `<devdoc>/Captures/<slug>/` resolution
- `scripts/capture/lib/hash.sh` — content hash of a reap candidate
- `scripts/capture/lib/template.sh` — artifact resolution per spec §12

**Custom skills (skills/devagent-*/):**
- `skills/devagent-capture/SKILL.md` — judgment: issue vs epic, multi-epic detection
- `skills/devagent-scaffold/SKILL.md` — judgment: bin epic into N child issue drafts
- `skills/devagent-redissue/SKILL.md` — judgment: red-team a draft
- `skills/devagent-reap/SKILL.md` — judgment: classify reap candidates, choose template

**Templates (templates/):**
- `templates/issue_template-bug.md`
- `templates/issue_template-feature.md`
- `templates/issue_template-docs.md`
- `templates/issue_template-perf.md`
- `templates/issue_template-chore.md`
- `templates/epic_template.md`
- `templates/redteam_issue.md` — relocated from `~/.claude/issue-redteam-prompt.md` per spec §12 migration

**Tests (tests/):**
- `tests/capture.bats`
- `tests/file.bats`
- `tests/reap.bats`
- `tests/lib/slug.bats`
- `tests/lib/paths.bats`
- `tests/lib/hash.bats`
- `tests/lib/template.bats`
- `tests/skills/devagent-capture.bats` — fixture-grep verification
- `tests/skills/devagent-scaffold.bats`
- `tests/skills/devagent-redissue.bats`
- `tests/skills/devagent-reap.bats`
- `tests/fixtures/devdoc/` — fake devdoc tree (issue dirs with imPlan-potentialFutureEnhancements.md, STUCK, actualWork.md, lessonsLearned.md)
- `tests/fixtures/config.toml` — minimal config pointing at fixture devdoc
- `tests/fixtures/mock-backend/issue/github.sh` — stub `create` verb returning canned issue number/url
- `tests/helpers.bash` — shared bats helpers (setup tmp devdoc, env vars)

---

## Conventions (apply to every task in this plan)

- All paths absolute. Plugin repo root: `/home/user/src/devAgent`.
- Every shell script begins with `#!/usr/bin/env bash` then `set -euo pipefail`.
- Every commit uses `git commit -s` (DCO required per user CLAUDE.md).
- Every commit message ends with `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` (no "(1M context)").
- Tests are written before implementation (TDD); each task pairs a failing-test step with an implementation step.
- Bats test files declare `load 'helpers'` to pick up `tests/helpers.bash`.
- Skill verification is fixture-based: an input fixture is fed in, the skill is invoked (or its prompt is grep-checked for required structure), and produced files are grepped for required headings/sections. Skills are NOT executed live in CI; their `SKILL.md` content is verified to contain the contract the rest of the plugin depends on.
- DO NOT actually call any tracker API in tests. The `mock-backend/issue/github.sh` stub is the only "backend" used in tests.
- `scripts/capture/lib/*.sh` are sourced (not exec'd), so they MUST be idempotent under `source`.

---

## Task 1: Test harness and fixtures

**Files:**
- Create: `/home/user/src/devAgent/tests/helpers.bash`
- Create: `/home/user/src/devAgent/tests/fixtures/config.toml`
- Create: `/home/user/src/devAgent/tests/fixtures/mock-backend/issue/github.sh`
- Create: `/home/user/src/devAgent/tests/fixtures/devdoc/.gitkeep`

- [ ] **Step 1: Write `tests/helpers.bash`**

```bash
# tests/helpers.bash — shared bats setup
# shellcheck shell=bash

# REPO_ROOT is the devAgent plugin checkout.
export REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Create a clean temp devdoc tree for each test.
setup_tmp_devdoc() {
  export TMP_DEVDOC
  TMP_DEVDOC="$(mktemp -d -t devagent-devdoc.XXXXXX)"
  mkdir -p "${TMP_DEVDOC}/Captures"
  mkdir -p "${TMP_DEVDOC}/templates"
}

teardown_tmp_devdoc() {
  if [[ -n "${TMP_DEVDOC:-}" && -d "${TMP_DEVDOC}" ]]; then
    rm -rf "${TMP_DEVDOC}"
  fi
}

# Point devagent state at a tmp dir for reap-idempotence tests.
setup_tmp_state() {
  export TMP_STATE
  TMP_STATE="$(mktemp -d -t devagent-state.XXXXXX)"
  export DEVAGENT_STATE_DIR="${TMP_STATE}"
}

teardown_tmp_state() {
  if [[ -n "${TMP_STATE:-}" && -d "${TMP_STATE}" ]]; then
    rm -rf "${TMP_STATE}"
  fi
}

# Force a deterministic date for slug generation.
freeze_date() {
  export DEVAGENT_DATE_OVERRIDE="${1:-2026-05-19}"
}

# Assert a file exists and matches a grep pattern.
assert_file_grep() {
  local file="$1" pattern="$2"
  [[ -f "${file}" ]] || { echo "missing: ${file}"; return 1; }
  grep -qE "${pattern}" "${file}" || {
    echo "pattern not found: ${pattern}"
    echo "--- file contents ---"
    cat "${file}"
    return 1
  }
}
```

- [ ] **Step 2: Write `tests/fixtures/config.toml`**

```toml
# Minimal config used by capture-family tests.
# The Phase 1 config loader will read this; until it lands, scripts
# read fields directly via grep/sed in scripts/capture/lib/paths.sh.

[defaults]
checklist_template = "standard"

[project.fake]
source_dir       = "/tmp/fake-src"
devdoc_dir       = "TMP_DEVDOC_PLACEHOLDER"
fork_first       = true

[project.fake.permissions]
push_mr          = false      # default closed — tests must exercise the gate
commit_devdoc    = false

[project.fake.issue_source]
backend     = "github"
repo        = "fakeorg/fake"
dir_prefix  = "Issue-"

[project.fake.issue_source_fork]
backend     = "github"
repo        = "me/fake"
dir_prefix  = "Issue-Fork-"
```

The literal string `TMP_DEVDOC_PLACEHOLDER` is replaced at test time by `helpers.bash` via `sed` (see later tasks that consume it).

- [ ] **Step 3: Write `tests/fixtures/mock-backend/issue/github.sh`**

```bash
#!/usr/bin/env bash
# Mock github issue backend. Records invocations so tests can assert.
set -euo pipefail

verb="${1:-}"
shift || true

case "${verb}" in
  create)
    repo="${1:?repo required}"
    title="${2:?title required}"
    body_file="${3:?body file required}"
    [[ -f "${body_file}" ]] || { echo "body file not found" >&2; exit 2; }
    : "${MOCK_RESPONSE_NUM:=4242}"
    : "${MOCK_RESPONSE_URL:=https://github.com/${repo}/issues/${MOCK_RESPONSE_NUM}}"
    # Record for assertions.
    {
      echo "verb=create"
      echo "repo=${repo}"
      echo "title=${title}"
      echo "body_file=${body_file}"
      printf 'body=<<<\n'
      cat "${body_file}"
      printf '>>>\n'
    } >>"${MOCK_INVOCATION_LOG:-/tmp/devagent-mock.log}"
    printf '%s\n' "${MOCK_RESPONSE_NUM}"
    ;;
  *)
    echo "mock github: unknown verb ${verb}" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 4: Create `tests/fixtures/devdoc/.gitkeep`**

Empty file so the directory is tracked.

- [ ] **Step 5: Make mock backend executable**

```bash
chmod +x /home/user/src/devAgent/tests/fixtures/mock-backend/issue/github.sh
```

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add tests/helpers.bash tests/fixtures/config.toml tests/fixtures/mock-backend/issue/github.sh tests/fixtures/devdoc/.gitkeep
git commit -s -m "$(cat <<'EOF'
test: scaffold capture-family test harness and fixtures

Adds shared bats helpers (tmp devdoc, frozen date, mock backend log),
a minimal fixture config.toml, and a mock github issue backend that
records create-verb invocations for assertion.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Slug helper (`scripts/capture/lib/slug.sh`)

Produces `YYYY-MM-DD-<kebab>` from a free-form title. Date overridable via `DEVAGENT_DATE_OVERRIDE` for deterministic tests.

**Files:**
- Create: `/home/user/src/devAgent/tests/lib/slug.bats`
- Create: `/home/user/src/devAgent/scripts/capture/lib/slug.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/lib/slug.bats`:

```bash
#!/usr/bin/env bats

load '../helpers'

setup() {
  source "${REPO_ROOT}/scripts/capture/lib/slug.sh"
  freeze_date 2026-05-19
}

@test "slug: simple title" {
  run devagent_slug "Corn planting"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-corn-planting" ]
}

@test "slug: collapses runs of non-alnum" {
  run devagent_slug "Fix --- the !!! kernel  bug"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-fix-the-kernel-bug" ]
}

@test "slug: strips leading/trailing dashes" {
  run devagent_slug "---hello world---"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-hello-world" ]
}

@test "slug: lowercases" {
  run devagent_slug "FOO Bar BAZ"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-05-19-foo-bar-baz" ]
}

@test "slug: truncates excessively long titles to 60 chars after the date" {
  long="$(printf 'word %.0s' {1..40})"
  run devagent_slug "${long}"
  [ "$status" -eq 0 ]
  # date prefix (10) + dash (1) + 60 chars max = 71
  [ "${#output}" -le 71 ]
}

@test "slug: empty title fails with explanatory message" {
  run devagent_slug ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty title"* ]]
}

@test "slug: title that becomes empty after sanitization fails" {
  run devagent_slug "!!! --- ???"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/lib/slug.bats`
Expected: all FAIL — `slug.sh` not found.

- [ ] **Step 3: Implement `scripts/capture/lib/slug.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/lib/slug.sh — slug generation for captures.
# Sourced; defines functions only.
# shellcheck shell=bash

devagent_today() {
  if [[ -n "${DEVAGENT_DATE_OVERRIDE:-}" ]]; then
    printf '%s\n' "${DEVAGENT_DATE_OVERRIDE}"
  else
    date +%Y-%m-%d
  fi
}

devagent_slug() {
  local title="${1:-}"
  if [[ -z "${title}" ]]; then
    echo "devagent_slug: empty title" >&2
    return 2
  fi
  # Lowercase, replace non-alnum runs with single dash, trim dashes.
  local kebab
  kebab="$(printf '%s' "${title}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "${kebab}" ]]; then
    echo "devagent_slug: title sanitizes to empty" >&2
    return 2
  fi
  # Cap kebab at 60 chars (per file-structure decision).
  if [[ "${#kebab}" -gt 60 ]]; then
    kebab="${kebab:0:60}"
    kebab="${kebab%-}"
  fi
  printf '%s-%s\n' "$(devagent_today)" "${kebab}"
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/lib/slug.bats`
Expected: 7/7 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/lib/slug.sh tests/lib/slug.bats
git commit -s -m "$(cat <<'EOF'
capture: add slug helper with date-prefix and length cap

devagent_slug produces YYYY-MM-DD-<kebab> from a free-form title.
DEVAGENT_DATE_OVERRIDE pins the date for deterministic tests.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Paths helper (`scripts/capture/lib/paths.sh`)

Resolves `<devdoc>/Captures/<slug>/` and its children. Reads `devdoc_dir` from the project config.

**Files:**
- Create: `/home/user/src/devAgent/tests/lib/paths.bats`
- Create: `/home/user/src/devAgent/scripts/capture/lib/paths.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/lib/paths.bats`:

```bash
#!/usr/bin/env bats

load '../helpers'

setup() {
  setup_tmp_devdoc
  source "${REPO_ROOT}/scripts/capture/lib/paths.sh"
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
}

teardown() { teardown_tmp_devdoc; }

@test "paths: captures_root returns <devdoc>/Captures" {
  run devagent_captures_root
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/Captures" ]
}

@test "paths: capture_dir returns <devdoc>/Captures/<slug>" {
  run devagent_capture_dir "2026-05-19-foo"
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/Captures/2026-05-19-foo" ]
}

@test "paths: ensure_capture_dir creates dir and returns path" {
  run devagent_ensure_capture_dir "2026-05-19-foo"
  [ "$status" -eq 0 ]
  [ -d "${TMP_DEVDOC}/Captures/2026-05-19-foo" ]
}

@test "paths: ensure_capture_dir is idempotent" {
  devagent_ensure_capture_dir "2026-05-19-foo"
  run devagent_ensure_capture_dir "2026-05-19-foo"
  [ "$status" -eq 0 ]
}

@test "paths: missing DEVAGENT_DEVDOC_DIR is an error" {
  unset DEVAGENT_DEVDOC_DIR
  run devagent_captures_root
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVAGENT_DEVDOC_DIR"* ]]
}

@test "paths: rejects slug with slash" {
  run devagent_capture_dir "foo/bar"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid slug"* ]]
}

@test "paths: rejects slug starting with dot" {
  run devagent_capture_dir ".hidden"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid slug"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/lib/paths.bats`
Expected: all FAIL — file missing.

- [ ] **Step 3: Implement `scripts/capture/lib/paths.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/lib/paths.sh — capture path resolution.
# Sourced; defines functions only.
# shellcheck shell=bash

devagent_captures_root() {
  if [[ -z "${DEVAGENT_DEVDOC_DIR:-}" ]]; then
    echo "DEVAGENT_DEVDOC_DIR not set" >&2
    return 2
  fi
  printf '%s/Captures\n' "${DEVAGENT_DEVDOC_DIR%/}"
}

devagent_validate_slug() {
  local slug="${1:-}"
  if [[ -z "${slug}" ]]; then
    echo "invalid slug: empty" >&2
    return 2
  fi
  case "${slug}" in
    .*|*/*|*$'\n'*) echo "invalid slug: ${slug}" >&2; return 2 ;;
  esac
}

devagent_capture_dir() {
  local slug="${1:-}"
  devagent_validate_slug "${slug}" || return $?
  local root
  root="$(devagent_captures_root)" || return $?
  printf '%s/%s\n' "${root}" "${slug}"
}

devagent_ensure_capture_dir() {
  local slug="${1:-}"
  local dir
  dir="$(devagent_capture_dir "${slug}")" || return $?
  mkdir -p "${dir}"
  printf '%s\n' "${dir}"
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/lib/paths.bats`
Expected: 7/7 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/lib/paths.sh tests/lib/paths.bats
git commit -s -m "$(cat <<'EOF'
capture: add paths helper for Captures/<slug> resolution

Validates slugs (no slash, no leading dot, no newline), resolves
<devdoc>/Captures and per-slug subdirs from DEVAGENT_DEVDOC_DIR,
and provides an idempotent ensure-dir helper.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Template resolver (`scripts/capture/lib/template.sh`)

Implements spec §12 artifact resolution: project paths → devdoc templates → plugin templates.

**Files:**
- Create: `/home/user/src/devAgent/tests/lib/template.bats`
- Create: `/home/user/src/devAgent/scripts/capture/lib/template.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/lib/template.bats`:

```bash
#!/usr/bin/env bats

load '../helpers'

setup() {
  setup_tmp_devdoc
  source "${REPO_ROOT}/scripts/capture/lib/template.sh"
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  # Seed a plugin template so the fallback path is testable.
  mkdir -p "${REPO_ROOT}/templates"
  if [[ ! -f "${REPO_ROOT}/templates/issue_template-bug.md" ]]; then
    SEEDED_PLUGIN_TEMPLATE=1
    printf '# Bug template (plugin fallback)\n' \
      >"${REPO_ROOT}/templates/issue_template-bug.md"
  fi
}

teardown() {
  if [[ "${SEEDED_PLUGIN_TEMPLATE:-0}" -eq 1 ]]; then
    rm -f "${REPO_ROOT}/templates/issue_template-bug.md"
  fi
  teardown_tmp_devdoc
}

@test "template: falls through to plugin templates dir when nothing else exists" {
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${REPO_ROOT}/templates/issue_template-bug.md" ]
}

@test "template: devdoc templates dir wins over plugin" {
  printf '# devdoc override\n' \
    >"${TMP_DEVDOC}/templates/issue_template-bug.md"
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/templates/issue_template-bug.md" ]
}

@test "template: project-explicit path wins over devdoc and plugin" {
  printf '# devdoc\n' >"${TMP_DEVDOC}/templates/issue_template-bug.md"
  mkdir -p "${TMP_DEVDOC}/custom"
  printf '# project-explicit\n' \
    >"${TMP_DEVDOC}/custom/bug.md"
  export DEVAGENT_TEMPLATE_OVERRIDE_issue_template_bug="${TMP_DEVDOC}/custom/bug.md"
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/custom/bug.md" ]
}

@test "template: unknown name returns error" {
  run devagent_resolve_template no_such_template
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such template"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/lib/template.bats`
Expected: all FAIL — file missing.

- [ ] **Step 3: Implement `scripts/capture/lib/template.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/lib/template.sh — artifact resolution per spec §12.
# Sourced; defines functions only.
# shellcheck shell=bash

# Resolution order:
#   1. DEVAGENT_TEMPLATE_OVERRIDE_<sanitized_name>  (set by config loader)
#   2. ${DEVAGENT_DEVDOC_DIR}/templates/<name>.md
#   3. ${DEVAGENT_PLUGIN_DIR}/templates/<name>.md
#
# Phase 1's config loader will set the override env var from
# [project.<name>.paths]. Until Phase 1 lands, callers can set the
# env var directly.
devagent_resolve_template() {
  local name="${1:?template name required}"
  local sanitized="${name//-/_}"
  local override_var="DEVAGENT_TEMPLATE_OVERRIDE_${sanitized}"
  local override="${!override_var:-}"
  if [[ -n "${override}" && -f "${override}" ]]; then
    printf '%s\n' "${override}"
    return 0
  fi
  if [[ -n "${DEVAGENT_DEVDOC_DIR:-}" ]]; then
    local devdoc_path="${DEVAGENT_DEVDOC_DIR%/}/templates/${name}.md"
    if [[ -f "${devdoc_path}" ]]; then
      printf '%s\n' "${devdoc_path}"
      return 0
    fi
  fi
  if [[ -n "${DEVAGENT_PLUGIN_DIR:-}" ]]; then
    local plugin_path="${DEVAGENT_PLUGIN_DIR%/}/templates/${name}.md"
    if [[ -f "${plugin_path}" ]]; then
      printf '%s\n' "${plugin_path}"
      return 0
    fi
  fi
  echo "no such template: ${name}" >&2
  return 2
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/lib/template.bats`
Expected: 4/4 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/lib/template.sh tests/lib/template.bats
git commit -s -m "$(cat <<'EOF'
capture: add template resolver per spec §12

Resolution order: project override env var → devdoc templates dir →
plugin templates dir. Unknown templates return non-zero with a
diagnostic.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Ship plugin-default templates

Drops the v1 template set under `templates/`. Spec §12 lists them; the redteam_issue template migrates from `~/.claude/issue-redteam-prompt.md`.

**Files:**
- Create: `/home/user/src/devAgent/templates/issue_template-bug.md`
- Create: `/home/user/src/devAgent/templates/issue_template-feature.md`
- Create: `/home/user/src/devAgent/templates/issue_template-docs.md`
- Create: `/home/user/src/devAgent/templates/issue_template-perf.md`
- Create: `/home/user/src/devAgent/templates/issue_template-chore.md`
- Create: `/home/user/src/devAgent/templates/epic_template.md`
- Create: `/home/user/src/devAgent/templates/redteam_issue.md`

- [ ] **Step 1: Write `templates/issue_template-bug.md`**

```markdown
# {{title}}

## Summary
<one paragraph: what's broken, observable symptom>

## Reproduction
1. <step>
2. <step>
3. <step>

Expected: <what should happen>
Actual:   <what happens>

## Environment
- Project: {{project}}
- Branch/commit: <ref>
- Toolchain: <compiler, version, flags>

## Root-cause hypothesis (optional)
<what you suspect, why>

## Acceptance criteria
- [ ] <observable test that proves the fix>
- [ ] Regression test added

## Source
{{source}}
```

- [ ] **Step 2: Write `templates/issue_template-feature.md`**

```markdown
# {{title}}

## Motivation
<why this matters; who asked; what it unblocks>

## Proposed behavior
<user-visible behavior in 1-3 paragraphs>

## API / interface impact
<signatures, files touched, backwards compatibility>

## Acceptance criteria
- [ ] <observable behavior 1>
- [ ] <observable behavior 2>
- [ ] Documentation updated

## Out of scope
<things this issue deliberately does NOT address>

## Source
{{source}}
```

- [ ] **Step 3: Write `templates/issue_template-docs.md`**

```markdown
# {{title}}

## Affected docs
- <path>
- <path>

## Problem
<what's wrong, missing, or outdated>

## Proposed change
<what the docs should say instead>

## Acceptance criteria
- [ ] All listed files updated
- [ ] Links/examples verified

## Source
{{source}}
```

- [ ] **Step 4: Write `templates/issue_template-perf.md`**

```markdown
# {{title}}

## Hot path
<which kernel/function/loop; how to find it>

## Baseline measurement
- Tool: <volk_profile / perf stat / criterion / ...>
- Workload: <inputs, sizes, repetitions>
- Result: <number ± noise>

## Hypothesis
<what change should help, why>

## Target
<numeric improvement goal; how it will be measured>

## Acceptance criteria
- [ ] Benchmark script checked in (or referenced)
- [ ] Plot from tools/plot_pr_evidence.R-style script attached
- [ ] No regression on adjacent kernels

## Source
{{source}}
```

- [ ] **Step 5: Write `templates/issue_template-chore.md`**

```markdown
# {{title}}

## Scope
<housekeeping, tooling, CI, infra; not user-visible>

## Rationale
<why now>

## Acceptance criteria
- [ ] <verifiable change>
- [ ] No user-visible behavior change

## Source
{{source}}
```

- [ ] **Step 6: Write `templates/epic_template.md`**

```markdown
# Epic: {{title}}

## Outcome
<what is true when this epic is done>

## Why now
<the motivating context; what changes if we skip it>

## Estimated children (rough)
- <child 1 — one-line summary>
- <child 2 — one-line summary>
- <child 3 — one-line summary>

(After authoring, run `/devagent:scaffold <slug>` to bin children into
`children/NN-<name>.md` draft files.)

## Acceptance criteria
- [ ] All children filed and tracked
- [ ] Epic-level integration test or demo

## Out of scope
<adjacent work this epic does not own>

## Source
{{source}}
```

- [ ] **Step 7: Write `templates/redteam_issue.md`**

Copy verbatim content from `/home/user/.claude/issue-redteam-prompt.md` (spec §12 migration). The actual content is operator-authored; this plan ships the migration. If the source file is unavailable, ship this minimal default:

```markdown
# Issue Red Team

Read the draft issue at `{{draft_path}}` and adversarially probe:

## Clarity
- [ ] Is the title unambiguous?
- [ ] Is the problem statement falsifiable?
- [ ] Could a stranger reproduce / verify acceptance?

## Scope
- [ ] Is this one issue, or several stapled together?
- [ ] Are the acceptance criteria observable?
- [ ] Does any criterion encode an implementation detail?

## Risk
- [ ] What happens if the fix is wrong?
- [ ] What adjacent code is at risk of regression?
- [ ] Is there a smaller proof-of-concept that should ship first?

## Output
Write findings to `{{redteam_path}}` as:

### Blocking (N)
- <finding>

### Recommended (N)
- <finding>

### Nits (N)
- <finding>

End with a one-line verdict: `Verdict: ship | revise | split`.
```

When the operator-authored prompt exists at `~/.claude/issue-redteam-prompt.md`, copy it instead — but never overwrite a non-empty `~/.claude/issue-redteam-prompt.md` from this task. The migration is one-way: plugin → templates dir.

Concrete command to use:

```bash
SRC="/home/user/.claude/issue-redteam-prompt.md"
DST="/home/user/src/devAgent/templates/redteam_issue.md"
if [[ -s "${SRC}" ]]; then
  cp "${SRC}" "${DST}"
else
  # write the minimal default shown above into ${DST}
  # (use the Write tool with the content block above)
  true
fi
```

- [ ] **Step 8: Commit**

```bash
cd /home/user/src/devAgent
git add templates/
git commit -s -m "$(cat <<'EOF'
templates: ship v1 issue, epic, and redteam_issue defaults

Five issue templates (bug, feature, docs, perf, chore) plus an
epic template and the issue red-team prompt (migrated from
~/.claude/issue-redteam-prompt.md per spec §12). Each template
uses {{title}}, {{project}}, {{source}} placeholders that the
capture script substitutes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `scripts/capture/capture.sh` — write `draft.md`

Given a type (`issue`/`epic`) and a title, resolves the template, substitutes placeholders, writes `Captures/<slug>/draft.md`.

**Files:**
- Create: `/home/user/src/devAgent/tests/capture.bats`
- Create: `/home/user/src/devAgent/scripts/capture/capture.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/capture.bats`:

```bash
#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
}

teardown() { teardown_tmp_devdoc; }

@test "capture: --type issue writes draft.md with bug template by default" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -eq 0 ]
  slug="2026-05-19-corn-planting"
  draft="${TMP_DEVDOC}/Captures/${slug}/draft.md"
  [ -f "${draft}" ]
  assert_file_grep "${draft}" "^# Corn planting$"
  assert_file_grep "${draft}" "## Acceptance criteria"
  # Slug is printed on stdout for caller use.
  [[ "$output" == *"${slug}"* ]]
}

@test "capture: --type epic uses epic template" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type epic --title "Performance overhaul"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-performance-overhaul/draft.md"
  assert_file_grep "${draft}" "^# Epic: Performance overhaul$"
  assert_file_grep "${draft}" "## Estimated children"
}

@test "capture: refuses to overwrite an existing draft without --force" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "capture: --force overwrites existing draft" {
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" --force
  [ "$status" -eq 0 ]
}

@test "capture: --source records source citation in {{source}} slot" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" \
    --source "Issue-676/imPlan-potentialFutureEnhancements.md line 42"
  [ "$status" -eq 0 ]
  draft="${TMP_DEVDOC}/Captures/2026-05-19-corn-planting/draft.md"
  assert_file_grep "${draft}" "Issue-676/imPlan-potentialFutureEnhancements.md line 42"
}

@test "capture: missing --title is an error" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" --type issue --subtype bug
  [ "$status" -ne 0 ]
  [[ "$output" == *"--title"* ]]
}

@test "capture: unknown --subtype is an error" {
  run "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype nonesuch --title "x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subtype"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/capture.bats`
Expected: all FAIL — script missing.

- [ ] **Step 3: Implement `scripts/capture/capture.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/capture.sh — write a Captures/<slug>/draft.md from a template.
# Invoked by /devagent:capture (script half of capture command).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slug.sh
source "${SCRIPT_DIR}/lib/slug.sh"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/template.sh
source "${SCRIPT_DIR}/lib/template.sh"

usage() {
  cat <<'USAGE' >&2
Usage: capture.sh --type {issue|epic} [--subtype {bug|feature|docs|perf|chore}]
                  --title <title> [--source <citation>] [--force]

Writes <devdoc>/Captures/<slug>/draft.md from the resolved template.
Prints the slug on stdout.

Env:
  DEVAGENT_DEVDOC_DIR   required
  DEVAGENT_PLUGIN_DIR   required
  DEVAGENT_PROJECT      optional (used in {{project}} substitution)
  DEVAGENT_DATE_OVERRIDE  optional (test-only)
USAGE
}

TYPE=""; SUBTYPE="bug"; TITLE=""; SOURCE=""; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="${2:?}"; shift 2 ;;
    --subtype) SUBTYPE="${2:?}"; shift 2 ;;
    --title) TITLE="${2:?}"; shift 2 ;;
    --source) SOURCE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${TITLE}" ]] || { echo "--title required" >&2; exit 2; }

case "${TYPE}" in
  issue)
    case "${SUBTYPE}" in
      bug|feature|docs|perf|chore) ;;
      *) echo "unknown subtype: ${SUBTYPE}" >&2; exit 2 ;;
    esac
    template_name="issue_template-${SUBTYPE}"
    ;;
  epic)
    template_name="epic_template"
    ;;
  *) echo "--type must be issue|epic" >&2; exit 2 ;;
esac

slug="$(devagent_slug "${TITLE}")"
dir="$(devagent_ensure_capture_dir "${slug}")"
draft="${dir}/draft.md"
if [[ -e "${draft}" && "${FORCE}" -ne 1 ]]; then
  echo "draft already exists: ${draft} (use --force to overwrite)" >&2
  exit 3
fi

template_path="$(devagent_resolve_template "${template_name}")"

# Substitute placeholders. Use python3 for safe verbatim substitution.
python3 - "${template_path}" "${draft}" "${TITLE}" "${DEVAGENT_PROJECT:-}" "${SOURCE:-}" <<'PY'
import sys, pathlib
src, dst, title, project, source = sys.argv[1:6]
text = pathlib.Path(src).read_text()
text = text.replace("{{title}}", title)
text = text.replace("{{project}}", project)
text = text.replace("{{source}}", source if source else "(none)")
pathlib.Path(dst).write_text(text)
PY

printf '%s\n' "${slug}"
```

- [ ] **Step 4: Make executable**

```bash
chmod +x /home/user/src/devAgent/scripts/capture/capture.sh
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/capture.bats`
Expected: 7/7 PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/capture.sh tests/capture.bats
git commit -s -m "$(cat <<'EOF'
capture: add capture.sh script for draft.md authoring

Resolves a template (issue subtype or epic), substitutes {{title}},
{{project}}, {{source}} placeholders, writes the draft into
<devdoc>/Captures/<slug>/. Refuses to overwrite without --force.
Prints the slug for caller chaining.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `commands/capture.md` — slash-command dispatch

Spec §6.2 grammar: `/devagent:capture <text>` (model decides), `/devagent:capture issue <text>`, `/devagent:capture epic <text>`. The slash-command markdown delegates judgment to the `devagent-capture` skill and mechanical work to `capture.sh`.

**Files:**
- Create: `/home/user/src/devAgent/commands/capture.md`

- [ ] **Step 1: Write `commands/capture.md`**

```markdown
---
description: Draft a pre-issue or epic capture under <devdoc>/Captures/<slug>/
allowed-tools: Bash, Read, Write, Edit, Skill
---

# /devagent:capture

Args: `[issue|epic] <free-form text>`

## Behavior

1. Parse args:
   - If first token is exactly `issue`, force-type = issue; remainder = text.
   - If first token is exactly `epic`, force-type = epic; remainder = text.
   - Otherwise, force-type is unset and the model decides.

2. Invoke the **devagent-capture** skill with the text and (if set) the
   forced type. The skill returns:
   - `type`: `issue` or `epic`
   - `subtype` (if issue): one of `bug feature docs perf chore`
   - `title`: a short title suitable for a slug
   - Optionally: a recommendation block such as
     `"this is 7 epics"` with proposed child titles. When the skill
     recommends a multi-epic split, do NOT call capture.sh seven times
     silently. Print the recommendation, ask the operator which epics
     to author, then author the chosen ones.

3. Call the script for each chosen artifact:

   ```bash
   scripts/capture/capture.sh \
     --type "<type>" \
     --subtype "<subtype>"  \
     --title "<title>"
   ```

   For epics, omit `--subtype`. The script prints the slug; record it.

4. Report each created `Captures/<slug>/draft.md` path to the operator
   and suggest the next step (`/devagent:redissue <slug>` or, for
   epics, `/devagent:scaffold <slug>`).

## Non-goals

This command does NOT file the issue to any tracker. Filing is the
job of `/devagent:file` and requires the `permissions.push_mr` gate.

## Env contract

The slash command relies on these env vars (set by the Phase 1
config loader; for now the operator sets them in their shell):

- `DEVAGENT_DEVDOC_DIR`
- `DEVAGENT_PLUGIN_DIR`
- `DEVAGENT_PROJECT`
```

- [ ] **Step 2: Commit**

```bash
cd /home/user/src/devAgent
git add commands/capture.md
git commit -s -m "$(cat <<'EOF'
capture: add /devagent:capture slash command

Parses optional issue|epic force-type prefix, delegates type and
subtype judgment to the devagent-capture skill, then calls
scripts/capture/capture.sh for each authored draft. Multi-epic
recommendations require operator confirmation before scaffolding.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `skills/devagent-capture/SKILL.md`

Custom skill that decides issue vs epic and chooses a subtype. Verified by fixture-based structure check.

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-capture/SKILL.md`
- Create: `/home/user/src/devAgent/tests/skills/devagent-capture.bats`
- Create: `/home/user/src/devAgent/tests/fixtures/capture-inputs/single-bug.txt`
- Create: `/home/user/src/devAgent/tests/fixtures/capture-inputs/multi-epic.txt`

- [ ] **Step 1: Write fixtures**

`/home/user/src/devAgent/tests/fixtures/capture-inputs/single-bug.txt`:

```
The convolution kernel emits NaN when the input length is exactly one
less than a multiple of the simd width. Reproducible with the existing
qa_volk_32fc_x2_dot_prod_32fc test by shrinking input by 1.
```

`/home/user/src/devAgent/tests/fixtures/capture-inputs/multi-epic.txt`:

```
We need to overhaul the project: rewrite the build system in CMake,
migrate from autotools, add a Python wheels release pipeline, modernize
the static analyzer setup, and replace the docs system. This is several
months of work.
```

- [ ] **Step 2: Write `skills/devagent-capture/SKILL.md`**

```markdown
---
name: devagent-capture
description: Decide whether a captured idea is one issue, one epic, or several epics; pick a subtype; emit a structured handoff for capture.sh. Triggers when /devagent:capture is invoked.
---

# devagent-capture

You are turning a free-form capture into structured input for
`scripts/capture/capture.sh`.

## Inputs

- `text` — the free-form capture from the operator.
- `forced_type` — one of `issue`, `epic`, or unset.

## Decision procedure

1. **If `forced_type` is set, use it.** Do not second-guess.
2. **Otherwise, classify:**
   - **issue** if the capture describes a single bounded change
     (one bug, one feature, one doc fix, one perf target, one chore)
     that one person can finish in days.
   - **epic** if the capture describes a multi-week effort with
     several independent deliverables.
   - **multi-epic** if the capture describes work that spans
     multiple independent epics (e.g., "rewrite build system AND
     add wheels pipeline AND modernize docs").

3. **If issue, pick a subtype:**
   - `bug`: existing behavior is wrong
   - `feature`: new behavior
   - `docs`: documentation only
   - `perf`: faster/smaller/leaner; no behavior change
   - `chore`: tooling, CI, infra; not user-visible

4. **Pick a title.** Imperative mood, ≤60 characters after slugification.
   - Bug: `fix conv kernel NaN at simd-1 length`
   - Feature: `add CSV export to volk_profile`
   - Epic: `Performance overhaul`

## Output format (REQUIRED)

You MUST emit exactly this block, then stop:

```
TYPE: <issue|epic|multi-epic>
SUBTYPE: <bug|feature|docs|perf|chore|->     # `-` when type is epic / multi-epic
TITLE: <title>
RECOMMENDATION: <one short paragraph; empty if straightforward>
CHILDREN:
- <child title 1>
- <child title 2>
(omit CHILDREN block if not multi-epic)
```

The slash command parses this block and calls `capture.sh` per row.

## Anti-patterns

- Do not author the issue body. `capture.sh` fills the template.
- Do not invent a project name. Use whatever `DEVAGENT_PROJECT` is.
- Do not file the issue. Filing is `/devagent:file`.
- Do not silently expand a single capture into many. If you see
  multi-epic, surface the recommendation and let the operator decide.

## Verification

This skill is verified by `tests/skills/devagent-capture.bats`, which
checks the SKILL.md file for the required output-format block. Live
model execution is not part of CI.
```

- [ ] **Step 3: Write `tests/skills/devagent-capture.bats`**

```bash
#!/usr/bin/env bats

load '../helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/skills/devagent-capture/SKILL.md"

@test "devagent-capture: SKILL.md exists" {
  [ -f "${SKILL}" ]
}

@test "devagent-capture: frontmatter declares name and description" {
  assert_file_grep "${SKILL}" "^name: devagent-capture$"
  assert_file_grep "${SKILL}" "^description: "
}

@test "devagent-capture: documents the TYPE/SUBTYPE/TITLE/RECOMMENDATION contract" {
  assert_file_grep "${SKILL}" "TYPE: <issue\|epic\|multi-epic>"
  assert_file_grep "${SKILL}" "SUBTYPE:"
  assert_file_grep "${SKILL}" "TITLE:"
  assert_file_grep "${SKILL}" "RECOMMENDATION:"
}

@test "devagent-capture: lists all five issue subtypes" {
  for s in bug feature docs perf chore; do
    assert_file_grep "${SKILL}" "\\b${s}\\b"
  done
}

@test "devagent-capture: warns against silent multi-epic expansion" {
  assert_file_grep "${SKILL}" "(silently|surface the recommendation)"
}
```

- [ ] **Step 4: Run tests**

Run: `bats /home/user/src/devAgent/tests/skills/devagent-capture.bats`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-capture/SKILL.md tests/skills/devagent-capture.bats tests/fixtures/capture-inputs/
git commit -s -m "$(cat <<'EOF'
capture: add devagent-capture skill with TYPE/SUBTYPE/TITLE contract

Skill emits a deterministic block parsed by /devagent:capture so the
script and skill halves stay decoupled. Bats verifies SKILL.md
contract structure (frontmatter, output schema, subtype list,
anti-silent-expansion note).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `skills/devagent-scaffold/SKILL.md` + `commands/scaffold.md`

Given an epic capture, bin it into child issue drafts under `Captures/<slug>/children/NN-<name>.md`. Pure judgment — no new script needed beyond reusing `capture.sh` for each child (children live under the epic's dir, not a separate slug).

**Files:**
- Create: `/home/user/src/devAgent/commands/scaffold.md`
- Create: `/home/user/src/devAgent/skills/devagent-scaffold/SKILL.md`
- Create: `/home/user/src/devAgent/tests/skills/devagent-scaffold.bats`

- [ ] **Step 1: Write `commands/scaffold.md`**

```markdown
---
description: Bin an epic capture into child issue drafts under children/
allowed-tools: Bash, Read, Write, Edit, Skill
---

# /devagent:scaffold

Args: `<capture-slug>`

## Behavior

1. Resolve `<devdoc>/Captures/<slug>/draft.md`. If `draft.md` does
   not start with `# Epic:`, abort with a clear error suggesting
   `/devagent:capture epic`.

2. Invoke the **devagent-scaffold** skill, passing `draft.md`. The
   skill returns an ordered list of child entries:

   ```
   - subtype: bug | feature | docs | perf | chore
     title:   <imperative title>
     summary: <one paragraph>
   ```

3. For each entry (1-indexed N), write the file:

   `<devdoc>/Captures/<slug>/children/NN-<kebab-title>.md`

   The body is the resolved `issue_template-<subtype>.md` with
   `{{title}}`, `{{project}}`, and `{{source}}` substituted. `{{source}}`
   becomes `Captures/<slug>/draft.md (scaffolded)`.

4. Print the list of created child paths.

## Idempotence

If `children/` already contains files, refuse without `--force`. With
`--force`, overwrite by index — existing higher-N files that the new
scaffolding does not produce are left in place (do not delete).

## Env contract

Same as `/devagent:capture`.
```

- [ ] **Step 2: Write `skills/devagent-scaffold/SKILL.md`**

```markdown
---
name: devagent-scaffold
description: Bin an epic capture into child issue draft entries (subtype + title + summary). Triggers when /devagent:scaffold is invoked.
---

# devagent-scaffold

You are decomposing an epic into the smallest set of child issues that
can each be implemented, reviewed, and shipped independently.

## Inputs

- `epic_draft` — the markdown body of `Captures/<slug>/draft.md`.

## Decomposition rules

1. **Each child must be shippable alone.** No child depends on a
   sibling for correctness. If A truly depends on B, write the
   dependency explicitly in A's summary and order them so B is
   numbered lower than A.

2. **Each child has one subtype.** Don't bundle "fix X and also add Y"
   into one child.

3. **5–9 children is the sweet spot.** Fewer means the epic was an
   issue. More means it was several epics; recommend re-running
   `/devagent:capture` on the outliers.

4. **Order matters.** Number children so the natural execution order
   is N=01, 02, 03... Foundational/blocking work first, polish last.

## Output format (REQUIRED)

Emit exactly:

```
CHILDREN:
- subtype: <bug|feature|docs|perf|chore>
  title:   <imperative title>
  summary: <one paragraph>
- subtype: ...
  title:   ...
  summary: ...
```

(YAML-ish; the slash command parses by indent.)

## Anti-patterns

- Do not author the full issue body. The slash command fills the
  template; you only choose subtype + title + summary.
- Do not silently produce 20+ children. Cap at 9; if more, return:
  `OVERFLOW: this epic is N epics, suggest re-capturing as: ...`

## Verification

Verified via fixture-grep against SKILL.md contract structure.
```

- [ ] **Step 3: Write `tests/skills/devagent-scaffold.bats`**

```bash
#!/usr/bin/env bats

load '../helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/skills/devagent-scaffold/SKILL.md"
CMD="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/commands/scaffold.md"

@test "devagent-scaffold: SKILL.md exists with correct frontmatter" {
  [ -f "${SKILL}" ]
  assert_file_grep "${SKILL}" "^name: devagent-scaffold$"
}

@test "devagent-scaffold: documents CHILDREN output block" {
  assert_file_grep "${SKILL}" "^CHILDREN:$"
  assert_file_grep "${SKILL}" "subtype:"
  assert_file_grep "${SKILL}" "title:"
  assert_file_grep "${SKILL}" "summary:"
}

@test "devagent-scaffold: caps children and surfaces overflow" {
  assert_file_grep "${SKILL}" "OVERFLOW:"
}

@test "devagent-scaffold: slash command refuses non-epic drafts" {
  assert_file_grep "${CMD}" "# Epic:"
  assert_file_grep "${CMD}" "/devagent:capture epic"
}

@test "devagent-scaffold: slash command requires --force when children/ exists" {
  assert_file_grep "${CMD}" "--force"
}
```

- [ ] **Step 4: Run tests**

Run: `bats /home/user/src/devAgent/tests/skills/devagent-scaffold.bats`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/scaffold.md skills/devagent-scaffold/SKILL.md tests/skills/devagent-scaffold.bats
git commit -s -m "$(cat <<'EOF'
capture: add /devagent:scaffold command and devagent-scaffold skill

Decomposes an epic capture into 5–9 child issue drafts written into
Captures/<slug>/children/NN-<name>.md. Skill enforces single-subtype
children, foundational-first ordering, and surfaces OVERFLOW when
the epic was really several epics.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `skills/devagent-redissue/SKILL.md` + `commands/redissue.md`

Run `templates/redteam_issue.md` against `draft.md`, write `redteam.md` next to it.

**Files:**
- Create: `/home/user/src/devAgent/commands/redissue.md`
- Create: `/home/user/src/devAgent/skills/devagent-redissue/SKILL.md`
- Create: `/home/user/src/devAgent/tests/skills/devagent-redissue.bats`

- [ ] **Step 1: Write `commands/redissue.md`**

```markdown
---
description: Run the issue red-team prompt against a capture draft; write redteam.md
allowed-tools: Read, Write, Edit, Skill
---

# /devagent:redissue

Args: `<capture-slug>`

## Behavior

1. Locate `<devdoc>/Captures/<slug>/draft.md`. Abort if missing.
2. Resolve `redteam_issue` template via the artifact resolution
   order (project paths → devdoc templates → plugin templates).
3. Invoke the **devagent-redissue** skill with `draft_path` and the
   contents of the red-team prompt.
4. The skill writes findings to `<devdoc>/Captures/<slug>/redteam.md`
   structured with `### Blocking`, `### Recommended`, `### Nits`,
   and a one-line `Verdict: ship | revise | split` footer.
5. Report the path and verdict. Do NOT modify `draft.md` itself —
   the operator decides whether to revise based on the findings.

## Env contract

Same as `/devagent:capture`.
```

- [ ] **Step 2: Write `skills/devagent-redissue/SKILL.md`**

```markdown
---
name: devagent-redissue
description: Adversarially review a capture draft using templates/redteam_issue.md; write findings to redteam.md. Triggers when /devagent:redissue is invoked.
---

# devagent-redissue

## Inputs

- `draft_path` — absolute path to `Captures/<slug>/draft.md`.
- `redteam_prompt` — resolved contents of `templates/redteam_issue.md`.

## Procedure

1. Read the draft.
2. Apply each check in the red-team prompt verbatim. Do not skip
   sections because they "seem fine".
3. Group findings by severity:
   - **Blocking** — must be addressed before filing.
   - **Recommended** — should be addressed; not a hard stop.
   - **Nits** — wording, formatting, micro-improvements.
4. End with `Verdict: ship | revise | split`.
   - `ship` — zero blocking findings; recommended/nits acceptable
   - `revise` — one or more blocking findings, single issue still viable
   - `split` — capture is structurally multiple issues

## Output

Write to `<devdoc>/Captures/<slug>/redteam.md` in this shape:

```markdown
# Red-team — <slug>

Run: <YYYY-MM-DD HH:MM>

### Blocking (N)
- <finding>

### Recommended (N)
- <finding>

### Nits (N)
- <finding>

Verdict: ship | revise | split
```

## Anti-patterns

- Do not edit `draft.md`. The operator owns the draft.
- Do not invent acceptance criteria not present in the draft just to
  give yourself something to find.
- Do not write `Verdict: ship` if any Blocking finding exists.

## Verification

Verified via fixture-grep against SKILL.md contract structure.
```

- [ ] **Step 3: Write `tests/skills/devagent-redissue.bats`**

```bash
#!/usr/bin/env bats

load '../helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/skills/devagent-redissue/SKILL.md"
CMD="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/commands/redissue.md"

@test "devagent-redissue: SKILL.md exists with correct frontmatter" {
  [ -f "${SKILL}" ]
  assert_file_grep "${SKILL}" "^name: devagent-redissue$"
}

@test "devagent-redissue: documents Blocking/Recommended/Nits sections" {
  assert_file_grep "${SKILL}" "### Blocking"
  assert_file_grep "${SKILL}" "### Recommended"
  assert_file_grep "${SKILL}" "### Nits"
}

@test "devagent-redissue: documents verdict triad" {
  assert_file_grep "${SKILL}" "Verdict: ship \| revise \| split"
}

@test "devagent-redissue: forbids editing draft.md" {
  assert_file_grep "${SKILL}" "Do not edit .draft.md"
}

@test "devagent-redissue: slash command writes redteam.md next to draft" {
  assert_file_grep "${CMD}" "redteam.md"
  assert_file_grep "${CMD}" "draft.md"
}
```

- [ ] **Step 4: Run tests**

Run: `bats /home/user/src/devAgent/tests/skills/devagent-redissue.bats`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/redissue.md skills/devagent-redissue/SKILL.md tests/skills/devagent-redissue.bats
git commit -s -m "$(cat <<'EOF'
capture: add /devagent:redissue command and devagent-redissue skill

Skill applies templates/redteam_issue.md to a capture draft, groups
findings by severity, writes Captures/<slug>/redteam.md with a
ship|revise|split verdict. Slash command resolves the prompt template
and never edits draft.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `scripts/capture/file.sh` — filing with permission gate

Calls `issue/<backend>.sh create` with the draft body. Honors `permissions.push_mr` (spec §8). Writes `filed.toml` with the returned issue number and URL.

**Files:**
- Create: `/home/user/src/devAgent/tests/file.bats`
- Create: `/home/user/src/devAgent/scripts/capture/file.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/file.bats`:

```bash
#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
  # Wire the mock backend.
  export DEVAGENT_ISSUE_BACKEND_DIR="${REPO_ROOT}/tests/fixtures/mock-backend/issue"
  export MOCK_INVOCATION_LOG
  MOCK_INVOCATION_LOG="$(mktemp -t devagent-mock.XXXXXX.log)"
  # Pre-stage a draft so we have something to file.
  "${REPO_ROOT}/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Corn planting" >/dev/null
  SLUG="2026-05-19-corn-planting"
  CAP_DIR="${TMP_DEVDOC}/Captures/${SLUG}"
}

teardown() {
  rm -f "${MOCK_INVOCATION_LOG:-}"
  teardown_tmp_devdoc
}

@test "file: with push_mr=false, refuses without --yes" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"push_mr"* ]] || [[ "$output" == *"permission"* ]]
}

@test "file: with push_mr=false and --yes, proceeds and writes filed.toml" {
  export DEVAGENT_PERMISSION_PUSH_MR=false
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin --yes
  [ "$status" -eq 0 ]
  filed="${CAP_DIR}/filed.toml"
  [ -f "${filed}" ]
  assert_file_grep "${filed}" '^issue_num = "4242"$'
  assert_file_grep "${filed}" '^url = "https://github.com/fakeorg/fake/issues/4242"$'
  assert_file_grep "${filed}" '^repo = "fakeorg/fake"$'
  assert_file_grep "${filed}" '^target = "origin"$'
}

@test "file: with push_mr=true, proceeds silently" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -eq 0 ]
  [ -f "${CAP_DIR}/filed.toml" ]
}

@test "file: target fork uses DEVAGENT_REPO_FORK" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_FORK="me/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target fork
  [ "$status" -eq 0 ]
  assert_file_grep "${CAP_DIR}/filed.toml" '^repo = "me/fake"$'
}

@test "file: invokes backend create with the draft body" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  grep -q "^verb=create$" "${MOCK_INVOCATION_LOG}"
  grep -q "^repo=fakeorg/fake$" "${MOCK_INVOCATION_LOG}"
  grep -q "^title=Corn planting$" "${MOCK_INVOCATION_LOG}"
}

@test "file: refuses to file an already-filed capture" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"already filed"* ]]
}

@test "file: --refile re-files after filed.toml exists" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin
  export MOCK_RESPONSE_NUM=9999
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "${SLUG}" --target origin --refile
  [ "$status" -eq 0 ]
  assert_file_grep "${CAP_DIR}/filed.toml" '^issue_num = "9999"$'
}

@test "file: missing draft.md is an error" {
  export DEVAGENT_PERMISSION_PUSH_MR=true
  export DEVAGENT_REPO_ORIGIN="fakeorg/fake"
  run "${REPO_ROOT}/scripts/capture/file.sh" --slug "nope-2026-05-19-x" --target origin
  [ "$status" -ne 0 ]
  [[ "$output" == *"draft.md"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/file.bats`
Expected: all FAIL — `file.sh` missing.

- [ ] **Step 3: Implement `scripts/capture/file.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/file.sh — file a capture draft as a tracker issue.
# Honors the push_mr permission gate (spec §8).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"

usage() {
  cat <<'USAGE' >&2
Usage: file.sh --slug <slug> --target {origin|fork} [--yes] [--refile]

Reads <devdoc>/Captures/<slug>/draft.md, calls
$DEVAGENT_ISSUE_BACKEND_DIR/<backend>.sh create <repo> <title> <body-file>,
writes returned issue number + URL to filed.toml.

Permission gate: DEVAGENT_PERMISSION_PUSH_MR=true|false
  false (default) → must pass --yes to proceed

Env:
  DEVAGENT_DEVDOC_DIR            required
  DEVAGENT_ISSUE_BACKEND_DIR     required (path to issue/ backends)
  DEVAGENT_ISSUE_BACKEND         optional (default: github)
  DEVAGENT_REPO_ORIGIN           required if --target origin
  DEVAGENT_REPO_FORK             required if --target fork
  DEVAGENT_PERMISSION_PUSH_MR    true|false (default false)
USAGE
}

SLUG=""; TARGET=""; YES=0; REFILE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="${2:?}"; shift 2 ;;
    --target) TARGET="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --refile) REFILE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${SLUG}" ]] || { echo "--slug required" >&2; exit 2; }
case "${TARGET}" in origin|fork) ;; *) echo "--target must be origin|fork" >&2; exit 2 ;; esac

cap_dir="$(devagent_capture_dir "${SLUG}")"
draft="${cap_dir}/draft.md"
filed="${cap_dir}/filed.toml"

[[ -f "${draft}" ]] || { echo "missing draft.md at ${draft}" >&2; exit 3; }
if [[ -e "${filed}" && "${REFILE}" -ne 1 ]]; then
  echo "already filed: ${filed} (use --refile to re-file)" >&2
  exit 3
fi

# Resolve repo for the chosen target.
case "${TARGET}" in
  origin) repo="${DEVAGENT_REPO_ORIGIN:-}" ;;
  fork)   repo="${DEVAGENT_REPO_FORK:-}" ;;
esac
[[ -n "${repo}" ]] || { echo "repo for target=${TARGET} not configured" >&2; exit 2; }

# Permission gate.
gate="${DEVAGENT_PERMISSION_PUSH_MR:-false}"
if [[ "${gate}" != "true" && "${YES}" -ne 1 ]]; then
  cat >&2 <<EOF
Permission gate: push_mr=${gate}

Plan:
  backend: ${DEVAGENT_ISSUE_BACKEND:-github}
  repo:    ${repo}
  title:   $(head -n1 "${draft}" | sed 's/^# *//')
  body:    ${draft}

Re-run with --yes to proceed, or set
[project.<name>.permissions].push_mr = true in config.toml.
EOF
  exit 4
fi

# Extract title from first H1.
title="$(awk '/^# /{sub(/^# */,""); print; exit}' "${draft}")"
[[ -n "${title}" ]] || { echo "draft has no H1 title" >&2; exit 3; }

backend="${DEVAGENT_ISSUE_BACKEND:-github}"
backend_script="${DEVAGENT_ISSUE_BACKEND_DIR:?DEVAGENT_ISSUE_BACKEND_DIR not set}/${backend}.sh"
[[ -x "${backend_script}" ]] || { echo "backend not executable: ${backend_script}" >&2; exit 3; }

issue_num="$("${backend_script}" create "${repo}" "${title}" "${draft}")"
[[ -n "${issue_num}" ]] || { echo "backend returned empty issue number" >&2; exit 3; }

# Construct URL. Phase 2/10 backends will return URL too via stdout
# in a stable shape; v1 mock returns just the number, so construct.
url="${MOCK_RESPONSE_URL:-https://github.com/${repo}/issues/${issue_num}}"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"${filed}" <<TOML
# Written by scripts/capture/file.sh
issue_num = "${issue_num}"
url = "${url}"
repo = "${repo}"
target = "${TARGET}"
backend = "${backend}"
filed_at = "${now}"
TOML

printf '%s\n' "${url}"
```

- [ ] **Step 4: Make executable**

```bash
chmod +x /home/user/src/devAgent/scripts/capture/file.sh
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/file.bats`
Expected: 8/8 PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/file.sh tests/file.bats
git commit -s -m "$(cat <<'EOF'
capture: add file.sh with push_mr permission gate

Files a capture draft as a tracker issue via
$DEVAGENT_ISSUE_BACKEND_DIR/<backend>.sh create. Honors the
push_mr gate per spec §8: false requires explicit --yes per
invocation; gate cannot be suppressed by chaining flags. Writes
issue_num/url/repo/target/backend/filed_at into filed.toml.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: `commands/file.md`

**Files:**
- Create: `/home/user/src/devAgent/commands/file.md`

- [ ] **Step 1: Write `commands/file.md`**

```markdown
---
description: File a capture draft as a tracker issue (origin or fork)
allowed-tools: Bash, Read
---

# /devagent:file

Args: `<capture-slug> [origin|fork]` (default: `origin`)

## Behavior

1. Validate that `<devdoc>/Captures/<slug>/draft.md` exists.
2. If `<devdoc>/Captures/<slug>/redteam.md` does NOT exist, warn the
   operator and require confirmation. (Filing without a red-team is
   allowed but should be a conscious choice.)
3. Call:

   ```bash
   scripts/capture/file.sh --slug <slug> --target <origin|fork>
   ```

   The script enforces the `permissions.push_mr` gate. If the gate
   is closed, the script prints the plan and exits non-zero; the
   operator re-invokes with `--yes` to confirm.

4. On success, print the returned URL and remind the operator that
   `Captures/<slug>/filed.toml` now records the issue number.

## Targets

- `origin` — the upstream tracker repo (from
  `[project.<name>.issue_source].repo`)
- `fork` — the personal/fork tracker repo (from
  `[project.<name>.issue_source_fork].repo`)

Forks vs origins matter when working on a project where some issues
are filed to your fork (private, scratch, exploratory) and others to
the upstream organization.

## Env contract

Same as `/devagent:capture`, plus the backend env vars consumed by
`file.sh`.

## Non-goals

- Does not transition issue state. That's `issue_workflow` hooks in
  the workflow family.
- Does not create the MR. That's `/devagent:ship`.
```

- [ ] **Step 2: Commit**

```bash
cd /home/user/src/devAgent
git add commands/file.md
git commit -s -m "$(cat <<'EOF'
capture: add /devagent:file slash command

Thin wrapper around scripts/capture/file.sh. Warns when filing
without a red-team. Documents origin vs fork target selection.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Hash helper (`scripts/capture/lib/hash.sh`) for reap idempotence

Spec §15: reap is idempotent via content hashes stored in `~/.claude/devagent/state/<project>.reaped.toml`.

**Files:**
- Create: `/home/user/src/devAgent/tests/lib/hash.bats`
- Create: `/home/user/src/devAgent/scripts/capture/lib/hash.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/lib/hash.bats`:

```bash
#!/usr/bin/env bats

load '../helpers'

setup() {
  source "${REPO_ROOT}/scripts/capture/lib/hash.sh"
}

@test "hash: same content produces same hash" {
  h1="$(devagent_hash_text "hello world")"
  h2="$(devagent_hash_text "hello world")"
  [ "${h1}" = "${h2}" ]
  [ -n "${h1}" ]
}

@test "hash: different content produces different hash" {
  h1="$(devagent_hash_text "hello world")"
  h2="$(devagent_hash_text "hello world!")"
  [ "${h1}" != "${h2}" ]
}

@test "hash: insensitive to leading/trailing whitespace and case" {
  h1="$(devagent_hash_text "Hello World")"
  h2="$(devagent_hash_text "  hello world  ")"
  h3="$(devagent_hash_text $'\nHELLO\tWORLD\n')"
  [ "${h1}" = "${h2}" ]
  [ "${h2}" = "${h3}" ]
}

@test "hash: 12 hex chars" {
  h="$(devagent_hash_text "anything")"
  [[ "${h}" =~ ^[0-9a-f]{12}$ ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/lib/hash.bats`
Expected: all FAIL — file missing.

- [ ] **Step 3: Implement `scripts/capture/lib/hash.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/lib/hash.sh — content hashing for reap idempotence.
# Sourced; defines functions only.
# shellcheck shell=bash

# Normalize text before hashing so cosmetic variations don't bypass
# the dedupe: lowercase, collapse runs of whitespace to single space,
# trim leading/trailing whitespace.
devagent_hash_text() {
  local input="${1:-}"
  printf '%s' "${input}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ //; s/ $//' \
    | sha256sum \
    | awk '{print substr($1, 1, 12)}'
}
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/lib/hash.bats`
Expected: 4/4 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/lib/hash.sh tests/lib/hash.bats
git commit -s -m "$(cat <<'EOF'
capture: add hash helper for reap idempotence

devagent_hash_text normalizes (lowercase, whitespace-collapse, trim)
then sha256-truncated-to-12-hex. Cosmetic edits to a reaped source
do not regenerate captures.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Reap fixtures

Build a fixture devdoc tree containing every reap source type so `reap.sh` can be tested deterministically.

**Files:**
- Create: `/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-100/imPlan-potentialFutureEnhancements.md`
- Create: `/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-100/actualWork.md`
- Create: `/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-100/lessonsLearned.md`
- Create: `/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-101/STUCK`
- Create: `/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-102/imPlan-potentialFutureEnhancements.md`

- [ ] **Step 1: Write reap fixtures**

`/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-100/imPlan-potentialFutureEnhancements.md`:

```markdown
# Issue-100 — Potential future enhancements

- Add benchmark for the alternative AVX-512 dispatch.
- Document the new dispatch policy in codingStandards.md.
```

`/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-100/actualWork.md`:

```markdown
# Issue-100 — Actual work

## What changed
Refactored dispatch path.

### Follow-up
- The orc backend has the same bug; should be its own issue.
```

`/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-100/lessonsLearned.md`:

```markdown
# Issue-100 — Lessons learned

- [actionable] Add a regression test that exercises the dispatch path directly.
- (insight) The dispatch table is harder to test than we thought.
```

`/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-101/STUCK`:

```
Step:        14 redmr
Reason:      red team produced 46 blocking issues, need triage strategy
Last good:   step 13 review (2026-05-19 16:42)
Suggested:   read analysis/2026-05-19-redmr.md; group findings by severity; pick top 3
Created:     2026-05-19 17:08
```

`/home/user/src/devAgent/tests/fixtures/reap-devdoc/Issue-102/imPlan-potentialFutureEnhancements.md`:

```markdown
# Issue-102 — Potential future enhancements

- Make the static analyzer parallel to cut CI time.
```

- [ ] **Step 2: Commit**

```bash
cd /home/user/src/devAgent
git add tests/fixtures/reap-devdoc/
git commit -s -m "$(cat <<'EOF'
test: add reap-devdoc fixture covering all reap source types

Fixture exercises every harvest source from spec §15:
imPlan-potentialFutureEnhancements.md bullets, STUCK files,
actualWork.md ### Follow-up sections, lessonsLearned.md
[actionable] entries.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: `scripts/capture/reap.sh` — harvest follow-ups

Per spec §15. Idempotent via content hashes recorded in `${DEVAGENT_STATE_DIR}/<project>.reaped.toml`. Each reaped item becomes a draft under `Captures/<auto-slug>/draft.md`.

**Files:**
- Create: `/home/user/src/devAgent/tests/reap.bats`
- Create: `/home/user/src/devAgent/scripts/capture/reap.sh`

- [ ] **Step 1: Write failing tests**

`/home/user/src/devAgent/tests/reap.bats`:

```bash
#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  setup_tmp_state
  freeze_date 2026-05-19
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  export DEVAGENT_PROJECT="fake"
  # Copy fixture devdoc tree (Issue-100, 101, 102) into our tmp devdoc.
  cp -R "${REPO_ROOT}/tests/fixtures/reap-devdoc/." "${TMP_DEVDOC}/"
}

teardown() {
  teardown_tmp_devdoc
  teardown_tmp_state
}

@test "reap: first run produces drafts for each candidate" {
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  # At least one draft per fixture source.
  found="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  [ "${found}" -ge 4 ]
}

@test "reap: each draft cites its source" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  # Every reaped draft has a Source line that names an Issue dir.
  for d in "${TMP_DEVDOC}"/Captures/*/draft.md; do
    grep -qE 'Issue-(100|101|102)' "${d}"
  done
}

@test "reap: idempotent — second run produces no new drafts" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  first="$(find "${TMP_DEVDOC}/Captures" -name draft.md | sort)"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  second="$(find "${TMP_DEVDOC}/Captures" -name draft.md | sort)"
  [ "${first}" = "${second}" ]
}

@test "reap: state file records content hashes" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  state="${DEVAGENT_STATE_DIR}/fake.reaped.toml"
  [ -f "${state}" ]
  # Each hash is 12 hex chars under [hashes].
  grep -qE '^[0-9a-f]{12} = ' "${state}"
}

@test "reap: editing a source's wording (cosmetic) does NOT re-reap" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  before="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  # Whitespace + case-only change.
  sed -i 's/Add benchmark for the alternative AVX-512 dispatch./  add  benchmark  for  the  alternative  AVX-512  DISPATCH.  /' \
    "${TMP_DEVDOC}/Issue-100/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  after="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  [ "${before}" = "${after}" ]
}

@test "reap: adding a NEW item to a source produces exactly one new draft" {
  "${REPO_ROOT}/scripts/capture/reap.sh"
  before="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  printf -- '- Brand new follow-up item never seen before.\n' \
    >>"${TMP_DEVDOC}/Issue-102/imPlan-potentialFutureEnhancements.md"
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -eq 0 ]
  after="$(find "${TMP_DEVDOC}/Captures" -name draft.md | wc -l)"
  [ "$((after - before))" -eq 1 ]
}

@test "reap: --dry-run reports candidates without writing anything" {
  run "${REPO_ROOT}/scripts/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-100"* ]]
  found="$(find "${TMP_DEVDOC}/Captures" -name draft.md 2>/dev/null | wc -l)"
  [ "${found}" -eq 0 ]
  [ ! -f "${DEVAGENT_STATE_DIR}/fake.reaped.toml" ]
}

@test "reap: missing DEVAGENT_PROJECT is an error" {
  unset DEVAGENT_PROJECT
  run "${REPO_ROOT}/scripts/capture/reap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVAGENT_PROJECT"* ]]
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bats /home/user/src/devAgent/tests/reap.bats`
Expected: all FAIL — `reap.sh` missing.

- [ ] **Step 3: Implement `scripts/capture/reap.sh`**

```bash
#!/usr/bin/env bash
# scripts/capture/reap.sh — harvest follow-up candidates into Captures/.
# Spec §15. Idempotent via content hashes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slug.sh
source "${SCRIPT_DIR}/lib/slug.sh"
# shellcheck source=lib/paths.sh
source "${SCRIPT_DIR}/lib/paths.sh"
# shellcheck source=lib/template.sh
source "${SCRIPT_DIR}/lib/template.sh"
# shellcheck source=lib/hash.sh
source "${SCRIPT_DIR}/lib/hash.sh"

usage() {
  cat <<'USAGE' >&2
Usage: reap.sh [--dry-run]

Scans <devdoc>/Issue-*/ and <devdoc>/Issue-Fork-*/ for follow-up
candidates and drafts them into <devdoc>/Captures/<slug>/draft.md.
Idempotent via content hashes in
${DEVAGENT_STATE_DIR}/${DEVAGENT_PROJECT}.reaped.toml.

Sources:
  imPlan-potentialFutureEnhancements.md  — every "- " bullet
  STUCK files                            — full body
  actualWork.md                          — ### Follow-up sections
                                         — lines with "should be its own issue"
  lessonsLearned.md                      — lines tagged [actionable]
USAGE
}

DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${DEVAGENT_PROJECT:-}" ]] || { echo "DEVAGENT_PROJECT not set" >&2; exit 2; }
[[ -n "${DEVAGENT_DEVDOC_DIR:-}" ]] || { echo "DEVAGENT_DEVDOC_DIR not set" >&2; exit 2; }
[[ -n "${DEVAGENT_PLUGIN_DIR:-}" ]] || { echo "DEVAGENT_PLUGIN_DIR not set" >&2; exit 2; }

STATE_DIR="${DEVAGENT_STATE_DIR:-${HOME}/.claude/devagent/state}"
mkdir -p "${STATE_DIR}"
STATE_FILE="${STATE_DIR}/${DEVAGENT_PROJECT}.reaped.toml"

# Load already-reaped hashes into an assoc array.
declare -A SEEN
if [[ -f "${STATE_FILE}" ]]; then
  while IFS=' = ' read -r h _; do
    [[ "${h}" =~ ^[0-9a-f]{12}$ ]] && SEEN["${h}"]=1
  done < <(grep -E '^[0-9a-f]{12} = ' "${STATE_FILE}" || true)
fi

# Candidate emitter: prints one line per candidate as:
#   <subtype>\t<title>\t<source-citation>\t<full-text>
emit_candidates() {
  local devdoc="$1"
  shopt -s nullglob
  local d
  for d in "${devdoc}"/Issue-* "${devdoc}"/Issue-Fork-*; do
    [[ -d "${d}" ]] || continue
    local issue_name
    issue_name="$(basename "${d}")"

    # 1. imPlan-potentialFutureEnhancements.md — each "- " bullet
    local f="${d}/imPlan-potentialFutureEnhancements.md"
    if [[ -f "${f}" ]]; then
      local lineno=0
      while IFS= read -r line; do
        lineno=$((lineno + 1))
        if [[ "${line}" =~ ^-\ (.+)$ ]]; then
          local body="${BASH_REMATCH[1]}"
          local title="${body%%.*}"
          printf 'feature\t%s\t%s/imPlan-potentialFutureEnhancements.md line %d\t%s\n' \
            "${title}" "${issue_name}" "${lineno}" "${body}"
        fi
      done <"${f}"
    fi

    # 2. STUCK file
    local s="${d}/STUCK"
    if [[ -f "${s}" ]]; then
      local reason
      reason="$(awk '/^Reason:/{sub(/^Reason:[ ]*/,""); print; exit}' "${s}")"
      [[ -z "${reason}" ]] && reason="${issue_name} STUCK"
      local body
      body="$(cat "${s}")"
      printf 'chore\t%s\t%s/STUCK\t%s\n' \
        "STUCK: ${reason}" "${issue_name}" "${body}"
    fi

    # 3. actualWork.md — ### Follow-up sections + "should be its own issue"
    local a="${d}/actualWork.md"
    if [[ -f "${a}" ]]; then
      # ### Follow-up bullets
      awk '
        /^### Follow-up$/ { inflw = 1; next }
        /^### / && inflw { inflw = 0 }
        inflw && /^- / {
          line=$0; sub(/^- */,"",line);
          title=line; sub(/\..*$/,"",title);
          printf "feature\t%s\tACTUALWORK\t%s\n", title, line;
        }
      ' "${a}" | while IFS=$'\t' read -r st ti src bd; do
        printf '%s\t%s\t%s/actualWork.md (### Follow-up)\t%s\n' "${st}" "${ti}" "${issue_name}" "${bd}"
      done
      # "should be its own issue" lines
      grep -nE 'should be its own issue' "${a}" 2>/dev/null | while IFS=: read -r lineno line; do
        local trimmed="${line# }"
        trimmed="${trimmed#- }"
        local title="${trimmed%%.*}"
        printf 'feature\t%s\t%s/actualWork.md line %s\t%s\n' \
          "${title}" "${issue_name}" "${lineno}" "${trimmed}"
      done
    fi

    # 4. lessonsLearned.md — [actionable]
    local l="${d}/lessonsLearned.md"
    if [[ -f "${l}" ]]; then
      grep -nE '\[actionable\]' "${l}" 2>/dev/null | while IFS=: read -r lineno line; do
        local trimmed="${line# }"
        trimmed="${trimmed#- }"
        trimmed="${trimmed#\[actionable\] }"
        local title="${trimmed%%.*}"
        printf 'chore\t%s\t%s/lessonsLearned.md line %s\t%s\n' \
          "${title}" "${issue_name}" "${lineno}" "${trimmed}"
      done
    fi
  done
}

# Process candidates.
new_count=0
declare -a NEW_HASHES NEW_LABELS
while IFS=$'\t' read -r subtype title source body; do
  [[ -z "${body}" ]] && continue
  h="$(devagent_hash_text "${body}")"
  if [[ -n "${SEEN[${h}]:-}" ]]; then
    continue
  fi
  if [[ "${DRY}" -eq 1 ]]; then
    printf '%s\t%s\t%s\n' "${subtype}" "${title}" "${source}"
    SEEN["${h}"]=1   # avoid duplicate dry-run output in same run
    continue
  fi

  # Write the draft via capture.sh.
  if ! "${SCRIPT_DIR}/capture.sh" \
        --type issue --subtype "${subtype}" \
        --title "${title}" --source "${source}" --force \
        >/dev/null; then
    echo "warn: capture.sh failed for: ${title}" >&2
    continue
  fi
  SEEN["${h}"]=1
  NEW_HASHES+=("${h}")
  NEW_LABELS+=("${title}")
  new_count=$((new_count + 1))
done < <(emit_candidates "${DEVAGENT_DEVDOC_DIR%/}")

if [[ "${DRY}" -eq 1 ]]; then
  exit 0
fi

# Persist state.
{
  printf '# Written by scripts/capture/reap.sh\n'
  printf '# project = %s\n' "${DEVAGENT_PROJECT}"
  printf '[hashes]\n'
  for h in "${!SEEN[@]}"; do
    printf '%s = "seen"\n' "${h}"
  done
} >"${STATE_FILE}"

printf 'reap: %d new draft(s)\n' "${new_count}"
for t in "${NEW_LABELS[@]}"; do
  printf '  + %s\n' "${t}"
done
```

- [ ] **Step 4: Make executable**

```bash
chmod +x /home/user/src/devAgent/scripts/capture/reap.sh
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: `bats /home/user/src/devAgent/tests/reap.bats`
Expected: 8/8 PASS.

If any test produces a candidate stream with embedded tabs or
non-printable artefacts that confuse `read -r`, adjust the
`emit_candidates` helper to print `\t`-separated fields with escaped
bodies (replace literal tab/newline in body with spaces) — the
behavior under test is "second-run produces nothing new", which
remains invariant under that fix.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add scripts/capture/reap.sh tests/reap.bats
git commit -s -m "$(cat <<'EOF'
capture: add reap.sh — harvest follow-ups with content-hash dedupe

Scans Issue-*/Issue-Fork-* dirs for follow-up candidates (per spec
§15) from imPlan-potentialFutureEnhancements.md bullets, STUCK
files, actualWork.md ### Follow-up + "should be its own issue"
lines, lessonsLearned.md [actionable] entries. Each candidate is
hashed (lowercase + whitespace-collapse + sha256-12-hex); second
run with same sources produces zero new drafts. --dry-run reports
without writing.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: `skills/devagent-reap/SKILL.md` + `commands/reap.md`

Spec §6.2 allows reap to be skill-or-script — we implement both halves: the script does the mechanical scan/dedupe (Task 15) and the skill, when invoked, helps classify ambiguous candidates and triage the harvested drafts.

**Files:**
- Create: `/home/user/src/devAgent/commands/reap.md`
- Create: `/home/user/src/devAgent/skills/devagent-reap/SKILL.md`
- Create: `/home/user/src/devAgent/tests/skills/devagent-reap.bats`

- [ ] **Step 1: Write `commands/reap.md`**

```markdown
---
description: Harvest follow-up candidates into Captures/<slug>/draft.md (idempotent)
allowed-tools: Bash, Read, Skill
---

# /devagent:reap

Args: `[project]` (optional; defaults to active project)

## Behavior

1. Run `scripts/capture/reap.sh --dry-run` to enumerate candidates.
2. If candidates exist, ask the operator: review the list, optionally
   trigger the **devagent-reap** skill to classify ambiguous ones
   (e.g., is `STUCK` content really an issue or just operator pain?).
3. Run `scripts/capture/reap.sh` (no `--dry-run`) to write drafts.
4. Print the list of newly created `Captures/<slug>/` paths and
   suggest `/devagent:redissue <slug>` for each.

## Idempotence

The script records content hashes in
`~/.claude/devagent/state/<project>.reaped.toml`. Re-running this
command harvests only candidates added since the last run.

## Env contract

Same as `/devagent:capture`, plus:

- `DEVAGENT_STATE_DIR` (default `~/.claude/devagent/state`)
```

- [ ] **Step 2: Write `skills/devagent-reap/SKILL.md`**

```markdown
---
name: devagent-reap
description: Classify harvested follow-up candidates (subtype + keep/discard) before they become drafts. Triggers when /devagent:reap surfaces ambiguous candidates.
---

# devagent-reap

## When invoked

`/devagent:reap` runs the mechanical scan first. You are invoked only
when the operator wants a judgment pass on ambiguous candidates before
drafts are written.

## Inputs

A list of candidates, each:

- `source` — e.g., `Issue-101/STUCK`
- `body`   — the harvested text

## For each candidate

1. **Classify subtype** if obviously wrong from the heuristic:
   - The script defaults `STUCK` → `chore` and `imPlan-*` → `feature`.
     Override when the content clearly indicates `bug`, `docs`, or
     `perf`.
2. **Keep or discard:**
   - **Keep** if this would be a sensible standalone issue.
   - **Discard** if the item is a one-line working note with no
     external value, or if it's already covered by an active issue.
3. **Suggest a better title** if the heuristic title (everything up
   to the first period) is awkward.

## Output

Emit a YAML-ish block parsed by the slash command:

```
DECISIONS:
- source: Issue-101/STUCK
  action: keep            # keep | discard
  subtype: chore          # only required when overriding
  title:   <better title> # only required when overriding
- source: Issue-100/imPlan-potentialFutureEnhancements.md line 2
  action: discard
  reason: already covered by Issue-200
```

## Anti-patterns

- Do not author the issue body. The script fills the template.
- Do not edit the source file (e.g., the original
  imPlan-potentialFutureEnhancements.md). Reaping is read-only on
  sources.
- Do not discard a STUCK candidate just because it's painful to read.
  STUCK files often surface the highest-value missing issues.

## Verification

Verified via fixture-grep against SKILL.md contract structure.
```

- [ ] **Step 3: Write `tests/skills/devagent-reap.bats`**

```bash
#!/usr/bin/env bats

load '../helpers'

SKILL="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/skills/devagent-reap/SKILL.md"
CMD="${REPO_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}/commands/reap.md"

@test "devagent-reap: SKILL.md exists with correct frontmatter" {
  [ -f "${SKILL}" ]
  assert_file_grep "${SKILL}" "^name: devagent-reap$"
}

@test "devagent-reap: documents DECISIONS output block" {
  assert_file_grep "${SKILL}" "^DECISIONS:$"
  assert_file_grep "${SKILL}" "action: keep"
  assert_file_grep "${SKILL}" "action: discard"
}

@test "devagent-reap: forbids editing the source file" {
  assert_file_grep "${SKILL}" "(read-only on sources|Do not edit the source)"
}

@test "devagent-reap: warns against discarding STUCK candidates lightly" {
  assert_file_grep "${SKILL}" "STUCK"
}

@test "devagent-reap: slash command runs --dry-run first" {
  assert_file_grep "${CMD}" "scripts/capture/reap.sh --dry-run"
}
```

- [ ] **Step 4: Run tests**

Run: `bats /home/user/src/devAgent/tests/skills/devagent-reap.bats`
Expected: 5/5 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/reap.md skills/devagent-reap/SKILL.md tests/skills/devagent-reap.bats
git commit -s -m "$(cat <<'EOF'
capture: add /devagent:reap command and devagent-reap skill

Slash command runs reap.sh --dry-run first, optionally invokes the
devagent-reap skill for judgment on ambiguous candidates, then runs
reap.sh for real. Skill emits a DECISIONS block (keep/discard with
subtype/title overrides). Source files remain read-only.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run every bats file added by this plan**

```bash
cd /home/user/src/devAgent
bats tests/lib/slug.bats \
     tests/lib/paths.bats \
     tests/lib/template.bats \
     tests/lib/hash.bats \
     tests/capture.bats \
     tests/file.bats \
     tests/reap.bats \
     tests/skills/devagent-capture.bats \
     tests/skills/devagent-scaffold.bats \
     tests/skills/devagent-redissue.bats \
     tests/skills/devagent-reap.bats
```

Expected: every file reports all tests PASS. Total: 4 (slug) + 7
(paths) + 4 (template) + 4 (hash) + 7 (capture) + 8 (file) + 8 (reap)
+ 5 (capture skill) + 5 (scaffold skill) + 5 (redissue skill) + 5
(reap skill) = 62 tests.

- [ ] **Step 2: Sanity-check that the script set is self-consistent**

```bash
cd /home/user/src/devAgent
for f in scripts/capture/capture.sh scripts/capture/file.sh scripts/capture/reap.sh; do
  bash -n "${f}" && echo "OK: ${f}"
done
```

Expected: three `OK:` lines, no syntax errors.

- [ ] **Step 3: Verify the slash command + skill set is complete per spec §6.2**

```bash
cd /home/user/src/devAgent
for cmd in capture scaffold redissue file reap; do
  test -f "commands/${cmd}.md" && echo "cmd: ${cmd} OK"
done
for skill in capture scaffold redissue reap; do
  test -f "skills/devagent-${skill}/SKILL.md" && echo "skill: devagent-${skill} OK"
done
```

Expected: five `cmd:` lines and four `skill:` lines (the spec lists
five commands but only four custom skills — `/devagent:file` is
script-only).

- [ ] **Step 4: No commit** — verification only. Parent commits at end per task instructions.

---

## Open questions for the implementer

1. **TOML state file format.** Task 13/15 use a `[hashes]` table with `<hash> = "seen"` entries. Phase 1's canonical state format may differ (it may prefer an array-of-tables). Reconcile when Phase 1 lands; the test in Task 15 step 5 only checks for `^[0-9a-f]{12} = ` so a future schema migration is a one-line test update.

2. **`Captures/<slug>` slug collisions.** Two reap candidates with similar titles on the same day collide. Current behavior: `--force` is passed to `capture.sh`, so the second wins and the first is lost. Acceptable for v1 because the hash-dedupe means re-running does not re-collide, but a follow-up issue should add a `-2`, `-3` suffix on collision. (Not in this plan's scope; surface as a `Captures/.../imPlan-potentialFutureEnhancements.md` item after the plugin is bootstrapped.)

3. **`redteam_issue.md` content authority.** Task 5 step 7 copies from `~/.claude/issue-redteam-prompt.md` if present, otherwise ships a default. Whichever lands becomes the plugin's shipped default; the operator can still override via `<devdoc>/templates/redteam_issue.md` per spec §12.

4. **Skill execution in CI.** This plan verifies skills via fixture-grep on `SKILL.md` structure rather than live model invocation. Live skill exercise is deferred to integration tests run manually; that decision matches Phase 4's stated convention but should be revisited if the project later adopts a model-runner harness for CI.

5. **`/devagent:file` URL construction.** The mock backend returns only the issue number; URL is constructed by `file.sh`. When the real Phase 2 GitHub backend lands, it should return either `num\turl` or `num` on the first line and `url` on the second; standardize the contract before Phase 2 is written. The test in Task 11 step 1 sets `MOCK_RESPONSE_URL` explicitly so it survives whichever contract is chosen.

---

## Self-review notes

- **Spec coverage check (§6.2 capture family):** capture/scaffold/redissue/file/reap all have a command file, and each judgment-requiring command has a skill. `/devagent:file` is correctly script-only with the `push_mr` gate (Task 11). Reap is idempotent (Task 15, three dedicated tests).
- **Spec §3.6 per-capture dir:** `draft.md` (Task 6), `redteam.md` (Task 10), `filed.toml` (Task 11), `children/` (Task 9). All four artifacts are produced.
- **Spec §12 template registry:** Task 5 ships every v1 capture-relevant template (issue × 5 subtypes, epic, redteam_issue). Resolver (Task 4) implements the three-level lookup.
- **Spec §15 reap sources:** all four source types covered by Task 15's `emit_candidates`. Hash-dedupe test (Task 15 step 1) explicitly verifies idempotence.
- **Spec §17 skill registration:** capture/scaffold/redissue/reap are listed as custom skills under §17; we created them as `skills/devagent-*`.
- **No placeholders detected.** Every step has runnable code or content.
- **Type consistency:** `devagent_slug`, `devagent_capture_dir`, `devagent_ensure_capture_dir`, `devagent_resolve_template`, `devagent_hash_text` are used with the same signatures across all tasks. `DEVAGENT_DEVDOC_DIR`, `DEVAGENT_PLUGIN_DIR`, `DEVAGENT_PROJECT`, `DEVAGENT_STATE_DIR`, `DEVAGENT_ISSUE_BACKEND_DIR`, `DEVAGENT_ISSUE_BACKEND`, `DEVAGENT_REPO_ORIGIN`, `DEVAGENT_REPO_FORK`, `DEVAGENT_PERMISSION_PUSH_MR`, `DEVAGENT_DATE_OVERRIDE` are the env-var contract; spelled identically everywhere.
