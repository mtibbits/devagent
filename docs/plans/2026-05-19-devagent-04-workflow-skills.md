# devAgent v1 — Plan 4: Workflow Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 13 skill-type workflow commands (steps 1, 2, 3, 4, 5, 7, 8, 9, 12, 13, 14, 18, 19) of the devAgent 21-step pipeline as slash-command wrappers + 8 new custom skills.

**Architecture:** Each command is a thin `commands/<verb>.md` file that parses `$NOTE` per spec §6.1 and delegates to a skill — either an upstream `superpowers:*` skill (wrapped 5 times) or a new `skills/devagent-*/SKILL.md` (created 8 times). Every command ends by appending a log line via `scripts/checklist-log.sh` (built in Plan 1). Skill quality is verified TDD-style using fixture inputs in `tests/fixtures/` and behavioral checklists that grep expected artifacts after running the skill against the fixture.

**Tech Stack:** Markdown (skills + slash commands), bash (log invocation), bats (fixture-based behavioral tests).

**Dependencies:**
- **Plan 1** must be complete: provides `~/.claude/devagent/config.toml` loader, per-project state TOML, `scripts/lib/checklist.sh`, `scripts/checklist-log.sh`, `scripts/lib/log.sh`, and relocated templates at `templates/{coding_standards,commit_template,mr_template,redteam_mr,redteam_issue,imPlan_template,actualWork_template,lessonsLearned_template}.md`.
- **Plan 3** owns script-type steps 6 (branch), 10 (commit), 11 (analyze), 15 (ship), 16 (mergetoall), 20 (cleanup). Do **not** create these in this plan.
- **Plan 7** owns step 17 (`/devagent:updatewbs`). Do **not** create it here.

**Cross-references:**
- Spec sections: §6.1 (invocation grammar), §6.3 (Family B workflow table), §7 (chaining), §12 (templates registry), §17 (skill integration mapping).
- Plan 1 deliverables consumed: `scripts/lib/checklist.sh`, `scripts/checklist-log.sh`, `templates/*.md`.

**Out of scope for Plan 4:**
- Anything not in the 13 commands listed below.
- Chaining glue (`--auto`, `--through`) — that lives in the chain executor (Plan 2 or 9, per spec §7).
- Permission gates (`push_mr`, etc.) — these are script-level gates, not skill-level.
- Step 0 (pull), Family A (capture), Family C (revision), Family D (context helpers).

---

## File Structure

### New skill directories (8)

```
skills/devagent-scope/SKILL.md
skills/devagent-improve/SKILL.md
skills/devagent-prune/SKILL.md
skills/devagent-tighten/SKILL.md
skills/devagent-document-actual-work/SKILL.md
skills/devagent-draft-mr/SKILL.md
skills/devagent-redmr/SKILL.md
skills/devagent-impact/SKILL.md
skills/devagent-lessons-learned/SKILL.md
```

(9 dirs total — the 8 NEW skills above plus `devagent-document-actual-work` is one of those 8; the duplication in the count is just spec naming. Final count: **9 SKILL.md files**, see spec §6.3 which lists 9 NEW skills under skill-type steps after subtracting the 4 wrappers.)

**Reconciliation with spec table:**
| Step | Wraps existing skill? | New SKILL.md? |
|---|---|---|
| 1 draft | superpowers:writing-plans | no |
| 2 scope | — | devagent-scope |
| 3 improve | — | devagent-improve |
| 4 prune | — | devagent-prune |
| 5 tighten | — | devagent-tighten |
| 7 implement | superpowers:executing-plans | no |
| 8 quality | simplify | no |
| 9 document | — | devagent-document-actual-work |
| 12 draftmr | — | devagent-draft-mr |
| 13 review | superpowers:requesting-code-review | no |
| 14 redmr | — | devagent-redmr |
| 18 impact | — | devagent-impact |
| 19 lessonslearned | — | devagent-lessons-learned |

**8 new skills** (scope, improve, prune, tighten, document-actual-work, draft-mr, redmr, impact, lessons-learned = **9**). Plan creates **9 NEW skills**.

### New slash command files (13)

```
commands/draft.md
commands/scope.md
commands/improve.md
commands/prune.md
commands/tighten.md
commands/implement.md
commands/quality.md
commands/document.md
commands/draftmr.md
commands/review.md
commands/redmr.md
commands/impact.md
commands/lessonslearned.md
```

### New shared helper

```
commands/_lib/note-parser.md  (REJECTED — see Task 1)
```

After deliberation in Task 1: the note-parsing contract is documented once in `commands/draft.md` and referenced by the other 12 command files using a single inline paragraph. No `_lib` is needed.

### New test fixtures (used by behavioral tests)

```
tests/fixtures/issue-scope/issue.md
tests/fixtures/issue-scope/imPlan.md
tests/fixtures/issue-scope/checklist.md
tests/fixtures/issue-improve/imPlan.md
tests/fixtures/issue-improve/checklist.md
tests/fixtures/issue-prune/imPlan.md
tests/fixtures/issue-prune/checklist.md
tests/fixtures/issue-tighten/imPlan.md
tests/fixtures/issue-tighten/imPlan-potentialFutureEnhancements.md
tests/fixtures/issue-tighten/checklist.md
tests/fixtures/issue-document/imPlan.md
tests/fixtures/issue-document/checklist.md
tests/fixtures/issue-document/git-changes.diff
tests/fixtures/issue-draftmr/imPlan.md
tests/fixtures/issue-draftmr/actualWork.md
tests/fixtures/issue-draftmr/checklist.md
tests/fixtures/issue-redmr/mr.md
tests/fixtures/issue-redmr/checklist.md
tests/fixtures/issue-impact/issue.md
tests/fixtures/issue-impact/actualWork.md
tests/fixtures/issue-impact/checklist.md
tests/fixtures/issue-lessons/checklist.md
tests/fixtures/issue-lessons/actualWork.md
```

### New behavioral test files (one per skill)

```
tests/skill_devagent_scope.bats
tests/skill_devagent_improve.bats
tests/skill_devagent_prune.bats
tests/skill_devagent_tighten.bats
tests/skill_devagent_document.bats
tests/skill_devagent_draftmr.bats
tests/skill_devagent_redmr.bats
tests/skill_devagent_impact.bats
tests/skill_devagent_lessons.bats
tests/cmd_wrappers.bats
```

### Skill behavioral-test pattern

Skills are markdown; you cannot unit-test markdown directly. The pattern this plan uses:

1. Stage a fixture issue dir under `tests/fixtures/issue-<skill>/` containing the artifacts the skill expects to read.
2. The bats test invokes a tiny harness `tests/lib/skill-fixture-check.sh` that:
   a. Greps the SKILL.md for **every** item in the skill's "Checklist" section and asserts each item is present and well-formed (non-empty, has a numbered or bulleted prefix).
   b. Greps SKILL.md for the required frontmatter fields (`name`, `description`, optional `when-to-use`).
   c. Greps SKILL.md for the explicit "halt and ask" rule mandated by the spec's no-auto-skip policy.
   d. Greps SKILL.md for the trailing `scripts/checklist-log.sh` invocation.
   e. Greps SKILL.md for the relevant template reference (e.g., `templates/redteam_mr.md` for redmr).
3. The bats test then validates each fixture file exists with required structure (acts as a regression test for the fixtures the SKILL.md tells the engineer to read).

This is a structural/contract test on the SKILL.md document — it does NOT actually run an LLM. Live LLM behavior is verified manually by the operator running each skill once against the fixture and checking the checklist box.

---

## Task 0: Verify Plan 1 prerequisites are in place

**Files:**
- Read: `/home/user/src/devAgent/scripts/checklist-log.sh`
- Read: `/home/user/src/devAgent/scripts/lib/checklist.sh`
- Read: `/home/user/src/devAgent/templates/redteam_mr.md`
- Read: `/home/user/src/devAgent/templates/mr_template.md`
- Read: `/home/user/src/devAgent/templates/coding_standards.md`

- [ ] **Step 1: Confirm checklist-log.sh exists and accepts `<issue-dir> <step-name> <message>`**

Run: `test -x /home/user/src/devAgent/scripts/checklist-log.sh && head -30 /home/user/src/devAgent/scripts/checklist-log.sh`

Expected: file is executable; its usage banner mentions three positional args (issue-dir, step-name, message). If missing or signature differs, **HALT** and reconcile with Plan 1 before proceeding.

- [ ] **Step 2: Confirm template files exist at the canonical paths**

Run: `for f in coding_standards commit_template mr_template redteam_mr redteam_issue imPlan_template actualWork_template lessonsLearned_template; do test -f "/home/user/src/devAgent/templates/$f.md" || echo "MISSING: $f.md"; done`

Expected: no MISSING lines. If any are missing, **HALT** and request Plan 1 completion.

- [ ] **Step 3: Confirm bats is installed**

Run: `which bats && bats --version`

Expected: bats 1.x. If absent, install via `apt-get install bats` or document the gap and proceed with `.bats` files anyway (they will run in CI).

- [ ] **Step 4: Create the test fixture root and lib directory**

Run: `mkdir -p /home/user/src/devAgent/tests/fixtures /home/user/src/devAgent/tests/lib /home/user/src/devAgent/commands /home/user/src/devAgent/skills`

Expected: directories exist; `ls` confirms.

- [ ] **Step 5: Commit the scaffolding**

```bash
cd /home/user/src/devAgent
git add tests/fixtures tests/lib commands skills 2>/dev/null || true
# directories alone don't stage; only commit if a .gitkeep is added
touch tests/fixtures/.gitkeep tests/lib/.gitkeep commands/.gitkeep skills/.gitkeep
git add tests/fixtures/.gitkeep tests/lib/.gitkeep commands/.gitkeep skills/.gitkeep
git commit -s -m "$(cat <<'EOF'
plan4: scaffold workflow-skill directories

Adds placeholder .gitkeep files for commands/, skills/, tests/fixtures/,
and tests/lib/ so subsequent tasks can land files under tracked paths.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 1: Build the skill-fixture-check harness

**Files:**
- Create: `/home/user/src/devAgent/tests/lib/skill-fixture-check.sh`
- Test: `/home/user/src/devAgent/tests/lib_skill_fixture_check.bats`

- [ ] **Step 1: Write the failing test**

Create `/home/user/src/devAgent/tests/lib_skill_fixture_check.bats` with:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  TMP="$(mktemp -d)"
  export TMP
}

teardown() {
  rm -rf "$TMP"
}

@test "harness rejects missing SKILL.md" {
  run bash "$HARNESS" "$TMP/no-such-skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SKILL.md not found"* ]]
}

@test "harness rejects SKILL.md missing frontmatter name field" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
description: stub
---
# Skill
## Checklist
1. step
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"frontmatter missing: name"* ]]
}

@test "harness rejects SKILL.md missing Checklist section" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist section missing"* ]]
}

@test "harness rejects SKILL.md missing checklist-log invocation" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
## Checklist
1. do thing
## Halt
If unsure ask the operator.
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing checklist-log invocation"* ]]
}

@test "harness accepts a valid SKILL.md" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
## Checklist
1. do thing
## Halt
If unsure, halt and ask the operator.
## Logging
Run scripts/checklist-log.sh "$ISSUE_DIR" stepname "msg"
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `cd /home/user/src/devAgent && bats tests/lib_skill_fixture_check.bats`

Expected: all five tests FAIL — `skill-fixture-check.sh` does not exist.

- [ ] **Step 3: Write minimal harness implementation**

Create `/home/user/src/devAgent/tests/lib/skill-fixture-check.sh`:

```bash
#!/usr/bin/env bash
# skill-fixture-check.sh — structural validator for devAgent SKILL.md files.
# Usage: skill-fixture-check.sh <skill-dir> <fixture-dir>
# Exit 0 if SKILL.md passes all structural checks; non-zero otherwise.

set -euo pipefail

skill_dir="${1:-}"
fixture_dir="${2:-}"

if [[ -z "$skill_dir" || -z "$fixture_dir" ]]; then
  echo "usage: $0 <skill-dir> <fixture-dir>" >&2
  exit 64
fi

skill_md="$skill_dir/SKILL.md"

if [[ ! -f "$skill_md" ]]; then
  echo "SKILL.md not found at $skill_md" >&2
  exit 1
fi

# Extract frontmatter (between leading --- markers).
fm="$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$skill_md")"

for field in name description; do
  if ! grep -qE "^${field}:[[:space:]]+\S" <<<"$fm"; then
    echo "frontmatter missing: ${field}" >&2
    exit 1
  fi
done

if ! grep -qE "^##[[:space:]]+Checklist" "$skill_md"; then
  echo "Checklist section missing" >&2
  exit 1
fi

if ! grep -qE "^##[[:space:]]+Halt" "$skill_md"; then
  echo "Halt section missing (no-auto-skip rule required)" >&2
  exit 1
fi

if ! grep -q "checklist-log.sh" "$skill_md"; then
  echo "missing checklist-log invocation" >&2
  exit 1
fi

# Optional fixture-dir existence check — only enforced when caller passes a real dir.
if [[ -d "$fixture_dir" ]]; then
  : # caller-specific fixture checks run in the bats test, not here
fi

exit 0
```

- [ ] **Step 4: Make it executable and re-run tests**

Run:
```bash
chmod +x /home/user/src/devAgent/tests/lib/skill-fixture-check.sh
cd /home/user/src/devAgent && bats tests/lib_skill_fixture_check.bats
```

Expected: all five tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add tests/lib/skill-fixture-check.sh tests/lib_skill_fixture_check.bats
git commit -s -m "$(cat <<'EOF'
plan4: add skill-fixture-check harness

Structural validator for devAgent SKILL.md files: checks frontmatter
name/description, Checklist and Halt sections, and the mandated
checklist-log invocation. Used by per-skill .bats files in subsequent
tasks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Define the slash-command file convention (commands/draft.md)

This task implements `commands/draft.md` first because it is the simplest wrapper (delegates to `superpowers:writing-plans`) and serves as the canonical example referenced by all 12 other command files.

**Files:**
- Create: `/home/user/src/devAgent/commands/draft.md`
- Test: `/home/user/src/devAgent/tests/cmd_wrappers.bats` (created here, expanded in later tasks)

- [ ] **Step 1: Write the failing test**

Create `/home/user/src/devAgent/tests/cmd_wrappers.bats`:

```bash
#!/usr/bin/env bats

CMD_DIR="$BATS_TEST_DIRNAME/../commands"

@test "draft.md exists and is non-empty" {
  [ -f "$CMD_DIR/draft.md" ]
  [ -s "$CMD_DIR/draft.md" ]
}

@test "draft.md documents \$NOTE parsing per spec §6.1" {
  grep -qE '\$NOTE' "$CMD_DIR/draft.md"
  grep -qE 'project|issue' "$CMD_DIR/draft.md"
}

@test "draft.md references the wrapped skill (superpowers:writing-plans)" {
  grep -q 'superpowers:writing-plans' "$CMD_DIR/draft.md"
}

@test "draft.md instructs the model to append a checklist log entry" {
  grep -q 'checklist-log.sh' "$CMD_DIR/draft.md"
}
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats`

Expected: all four tests FAIL — `commands/draft.md` does not exist.

- [ ] **Step 3: Write commands/draft.md**

Create `/home/user/src/devAgent/commands/draft.md`:

```markdown
---
description: Draft an implementation plan for the active issue. Wraps superpowers:writing-plans.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draft

Drafts `<issue-dir>/imPlan.md` for the active issue by invoking the
upstream `superpowers:writing-plans` skill. Step 1 of the 21-step
devAgent workflow (spec §6.3).

## Argument parsing (spec §6.1)

This command receives positional arguments left-to-right:

1. If the first token matches a `project.<name>` from
   `~/.claude/devagent/config.toml`, consume it as the project.
2. If the next token matches `^Issue(-Fork)?-\d+$`, consume it as the
   issue directory.
3. Join remaining tokens with single spaces into `$NOTE` — free-form
   user intent.

`--` halts positional consumption; everything after `--` is `$NOTE`.

Defaults when omitted: project = state's `active_project` (or the only
configured project if exactly one); issue = state's `active_issue` for
that project.

## Workflow

1. Resolve `project`, `issue-dir`, and `$NOTE` per the rules above.
2. Read `<issue-dir>/issue.md`. If absent, halt and tell the operator
   to run `/devagent:pull` first.
3. Invoke the `superpowers:writing-plans` skill. Pass `$NOTE` to the
   skill as additional user-intent context describing what the
   operator wants emphasised in the plan.
4. The skill writes the plan to `<issue-dir>/imPlan.md` (NOT to
   `docs/plans/`, despite the wrapped skill's default).
   Override its save path explicitly when invoking it.
5. On completion, append a log entry:

   ```bash
   scripts/checklist-log.sh "$ISSUE_DIR" draft "imPlan.md written ($N steps); note: $NOTE"
   ```

   Where `$N` is the number of top-level tasks in the plan.

## Halt and ask if

- `<issue-dir>/issue.md` does not exist (operator must run pull first).
- `<issue-dir>/imPlan.md` already exists and is non-empty — ask whether
  to overwrite, start a new revision, or abort.
- Active project cannot be inferred and `config.toml` has multiple
  projects.

## Skipping policy

Never auto-skip. If a precondition is unmet, surface
"step doesn't apply because X, mark skipped?" and require operator
confirmation per spec §6.3 principle.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats`

Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/draft.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:draft command wrapper

Wraps superpowers:writing-plans for the workflow's draft step (step 1
of 21). Establishes the convention referenced by the remaining 12
command files: $NOTE parsing per spec §6.1, halt-and-ask rules, and
the trailing checklist-log invocation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Build devagent-scope skill (workflow step 2)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-scope/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-scope/{issue.md,imPlan.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_scope.bats`

- [ ] **Step 1: Write the failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_scope.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-scope"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-scope"
}

@test "devagent-scope passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-scope SKILL.md lists all 6 scope questions" {
  for q in "scope" "out of scope" "size" "ambiguity" "preconditions" "success"; do
    grep -qi "$q" "$SKILL/SKILL.md" || { echo "missing question: $q"; false; }
  done
}

@test "devagent-scope appends to Scope evaluation section" {
  grep -qE 'Scope evaluation' "$SKILL/SKILL.md"
}

@test "devagent-scope fixture: imPlan.md present" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/issue.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_scope.bats`

Expected: all four tests FAIL — neither skill nor fixtures exist.

- [ ] **Step 3: Create the fixture issue.md**

Create `/home/user/src/devAgent/tests/fixtures/issue-scope/issue.md`:

```markdown
# gnuradio/volk#999 — Add SIMD path for foo_kernel

- State: open
- Author: @example
- Labels: enhancement, performance
- URL: https://github.com/gnuradio/volk/issues/999

---

We need an AVX2 implementation of `foo_kernel` to match the SSE one.
Should follow the existing pattern in `bar_kernel`. Bonus points if
ARM NEON gets added too.

---

## Comments (1)

### @maintainer · 2026-05-10

Please open a separate issue for NEON.
```

- [ ] **Step 4: Create the fixture imPlan.md**

Create `/home/user/src/devAgent/tests/fixtures/issue-scope/imPlan.md`:

```markdown
# Issue-999 — Implementation plan

## Tasks
1. Add AVX2 path to `foo_kernel`.
2. Add NEON path to `foo_kernel`.
3. Add benchmarks.
4. Update docs.
```

- [ ] **Step 5: Create the fixture checklist.md**

Create `/home/user/src/devAgent/tests/fixtures/issue-scope/checklist.md`:

```markdown
# Issue-999 — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: standard
Created: 2026-05-19 09:00
Active revision: 1

## Revision 1

- [x]  0. pull
- [x]  1. draft
- [~]  2. scope            ← active
- [ ]  3. improve

## Log
- 2026-05-19 09:00  pull: fetched gnuradio/volk#999, scaffold created
- 2026-05-19 09:10  draft: imPlan.md written (4 tasks)
```

- [ ] **Step 6: Write the SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-scope/SKILL.md`:

```markdown
---
name: devagent-scope
description: Use when running step 2 of the devAgent workflow to evaluate whether an issue's implementation plan is correctly scoped before investing implementation time
when-to-use: After /devagent:draft has produced an imPlan.md and before /devagent:improve. Run as part of /devagent:scope.
---

# devagent-scope

Step 2 of the devAgent 21-step workflow. Walks the operator through
six scope questions and appends the answers to `<issue-dir>/imPlan.md`
as a new `## Scope evaluation` section.

## Overview

A draft plan often over- or under-reaches. Six structured questions
catch the common failure modes (scope creep, missing preconditions,
no success criterion) before any code is written. The answers become
part of the plan so reviewers see them too.

## Inputs

- `$ISSUE_DIR` — absolute path to the issue directory.
- `$NOTE` — free-form operator intent passed from the slash command.
- Reads: `<issue-dir>/issue.md`, `<issue-dir>/imPlan.md`.
- Writes: appends `## Scope evaluation` to `<issue-dir>/imPlan.md`.

## Checklist

Walk these six questions, one section per question, answer in the
operator's voice. Do not invent answers — when uncertain, halt and
ask.

1. **In scope.** What exactly is this plan changing? List the
   concrete artifacts (files, functions, configs). Anything not on
   this list is out of scope by definition.
2. **Out of scope.** What is intentionally excluded from this plan?
   Cite the related work that *could* be done but isn't. Examples
   are stronger than abstractions.
3. **Size.** Rough estimate: lines of code, files touched, hours of
   work. If size > 1 day or > 300 LOC, halt and ask whether the
   issue should be split.
4. **Ambiguity.** What in the issue or plan is unclear and would
   require a judgment call? List each ambiguity and how this plan
   resolves it (or marks it as "ask the maintainer").
5. **Preconditions.** What must already be true for this plan to
   make sense? (Tests pass on main; baseline benchmark recorded;
   upstream PR #X merged; etc.) Each precondition gets a checkbox.
6. **Success criteria.** How will the operator know this plan
   succeeded? Concrete pass/fail tests. "Works on my machine" is
   not an answer.

## Output format (append to imPlan.md)

```markdown
## Scope evaluation

### In scope
- ...

### Out of scope
- ... (deferred to imPlan-potentialFutureEnhancements.md if non-trivial)

### Size estimate
- ~XXX LOC across N files; ~Y hours.

### Ambiguities
- ...

### Preconditions
- [ ] ...

### Success criteria
- [ ] ...
```

## Halt and ask if

- `<issue-dir>/imPlan.md` does not exist (no plan to evaluate).
- The plan already has a `## Scope evaluation` section (ask whether to
  overwrite, append a new revision sub-section, or abort).
- Size estimate exceeds 1 day / 300 LOC — propose splitting the issue.
- More than 3 ambiguities surface — propose a clarifying comment on
  the upstream issue before continuing.

## Skipping policy

Never auto-skip. If the plan is empty or the issue is purely
docs/chore and the questions don't apply, surface that explicitly:
"This step doesn't apply because the plan is a one-line typo fix
— mark scope step as `[-]` skipped?" Require operator confirmation.

## Logging

After completion:

```bash
scripts/checklist-log.sh "$ISSUE_DIR" scope \
  "Scope evaluation appended; N ambiguities, M preconditions, size=X LOC; note: $NOTE"
```

## Templates referenced

- `templates/imPlan_template.md` (for the canonical section ordering
  if the plan needs restructuring during this step).
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_scope.bats`

Expected: all four tests PASS.

- [ ] **Step 8: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-scope tests/fixtures/issue-scope tests/skill_devagent_scope.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-scope skill (workflow step 2)

Six-question scope evaluation that appends ## Scope evaluation to
<issue-dir>/imPlan.md. Includes fixture issue and bats structural
test via skill-fixture-check.sh harness.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add /devagent:scope command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/scope.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend the wrapper test**

Append to `/home/user/src/devAgent/tests/cmd_wrappers.bats`:

```bash
@test "scope.md exists, invokes devagent-scope, parses \$NOTE, logs" {
  F="$CMD_DIR/scope.md"
  [ -f "$F" ]
  grep -q 'devagent-scope' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f scope`

Expected: the new test FAILS (file not found).

- [ ] **Step 3: Create the command**

Create `/home/user/src/devAgent/commands/scope.md`:

```markdown
---
description: Run six-question scope evaluation on the active issue's plan. Invokes devagent-scope skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:scope

Step 2 of the 21-step devAgent workflow. Invokes the `devagent-scope`
skill to walk through six structured questions and append a
`## Scope evaluation` section to `<issue-dir>/imPlan.md`.

## Argument parsing

Identical to `/devagent:draft`. See `commands/draft.md` for the full
spec §6.1 grammar. In one sentence: optional `project`, optional
`Issue[-Fork]-N`, the rest is `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `<issue-dir>/imPlan.md` exists. If not, halt: operator must
   run `/devagent:draft` first.
3. Invoke the `devagent-scope` skill with `$ISSUE_DIR=<issue-dir>`
   and `$NOTE` as user intent.
4. The skill appends `## Scope evaluation` to `imPlan.md`.
5. The skill itself appends the log entry via
   `scripts/checklist-log.sh`.

## Halt and ask if

- `imPlan.md` is missing (run draft first).
- A `## Scope evaluation` section already exists (overwrite? new
  sub-section? abort?).

## Skipping policy

Never auto-skip. If the issue is a trivial typo and the six questions
don't apply, surface the skip request to the operator rather than
silently advancing.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f scope`

Expected: the new test PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/scope.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:scope command wrapper

Thin wrapper that invokes the devagent-scope skill, parses $NOTE
per spec §6.1, and defers log-append to the skill itself.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Build devagent-improve skill (workflow step 3)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-improve/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-improve/{imPlan.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_improve.bats`

- [ ] **Step 1: Write the failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_improve.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-improve"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-improve"
}

@test "devagent-improve passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-improve covers bugs, side effects, ambiguities" {
  grep -qi 'bug' "$SKILL/SKILL.md"
  grep -qi 'side effect' "$SKILL/SKILL.md"
  grep -qi 'ambiguit' "$SKILL/SKILL.md"
}

@test "devagent-improve fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_improve.bats`

Expected: all three FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-improve/imPlan.md`:

```markdown
# Issue-1001 — Plan

## Tasks
1. Replace `strcpy` with `strncpy` in `foo.c:42`.
2. Add a check for null pointers before the copy.

## Scope evaluation
### In scope
- foo.c lines 40-60
### Success criteria
- [ ] Existing tests still pass
```

`/home/user/src/devAgent/tests/fixtures/issue-improve/checklist.md`:

```markdown
# Issue-1001 — Workflow checklist

## Revision 1
- [x] 2. scope
- [~] 3. improve  ← active

## Log
- 2026-05-19 10:00  scope: 0 ambiguities, 1 precondition
```

- [ ] **Step 4: Write the SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-improve/SKILL.md`:

```markdown
---
name: devagent-improve
description: Use when running step 3 of the devAgent workflow to surface latent bugs, unintended side effects, and ambiguities in an implementation plan before pruning
when-to-use: After /devagent:scope has appended scope evaluation and before /devagent:prune. Run as part of /devagent:improve.
---

# devagent-improve

Step 3 of the devAgent 21-step workflow. Reads `<issue-dir>/imPlan.md`
(including the Scope evaluation section) and appends an `## Improvements`
section that flags concrete plan defects in three categories: bugs,
side effects, ambiguities.

## Overview

Scope tells you what the plan covers. Improve tells you what the plan
gets *wrong* or fails to consider. The deliverable is a flat list of
concrete callouts the operator chooses to act on (merge into tasks),
defer (move to potentialFutureEnhancements), or dismiss (note why).

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads: `<issue-dir>/imPlan.md`, `<issue-dir>/issue.md`.
- Writes: appends `## Improvements` to `<issue-dir>/imPlan.md`.

## Checklist

Walk these three categories in order.

1. **Bugs in the plan.** Where would the proposed change introduce a
   bug, regression, off-by-one, race, or memory issue? For each, cite
   the task number and the specific line of reasoning that fails.
2. **Unintended side effects.** What downstream code, build target,
   API consumer, or test is touched indirectly? Cite call sites if
   known. If unknown but plausible, list as "investigate before
   committing".
3. **Ambiguities not resolved by scope.** What in the plan would
   confuse another engineer reading it cold? Concrete, not abstract:
   "task 2 says 'add a check' — check for what condition? null? empty?
   uninitialized?"

For each callout: tag with `[merge]`, `[defer]`, or `[dismiss]`. The
operator decides; the skill proposes a default tag based on severity.

## Output format (append to imPlan.md)

```markdown
## Improvements

### Bugs
- [merge] Task 2: strncpy with bound = strlen(src) is equivalent to
  strcpy; bound must be sizeof(dst) - 1 with explicit nul-term.

### Unintended side effects
- [defer] foo.c is included by three other TUs; rebuild cost +12s.
  Document, do not change.

### Ambiguities
- [merge] Task 1: which encoding does the source string use? If
  multi-byte, byte-truncation corrupts. Add encoding assertion.
```

## Halt and ask if

- `imPlan.md` lacks a `## Scope evaluation` section — operator must
  run `/devagent:scope` first.
- More than 10 bugs surface — propose returning to draft step rather
  than papering over a fundamentally broken plan.
- A bug callout requires reading source you cannot locate — halt and
  ask the operator to point you at the right file rather than guessing.

## Skipping policy

Never auto-skip. If the plan is trivially mechanical (e.g., a single
typo fix), surface the skip request rather than silently advancing:
"No improvements found; mark step `[-]` skipped?"

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" improve \
  "Improvements appended; B bugs, S side-effects, A ambiguities; note: $NOTE"
```

## Templates referenced

- `templates/imPlan_template.md` (canonical section ordering).
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_improve.bats`

Expected: all three PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-improve tests/fixtures/issue-improve tests/skill_devagent_improve.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-improve skill (workflow step 3)

Surfaces bugs, side effects, and unresolved ambiguities in a drafted
plan. Operator tags each callout [merge|defer|dismiss]. Includes
fixture and structural test.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add /devagent:improve command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/improve.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend the wrapper test**

Append to `/home/user/src/devAgent/tests/cmd_wrappers.bats`:

```bash
@test "improve.md exists, invokes devagent-improve, parses \$NOTE, logs" {
  F="$CMD_DIR/improve.md"
  [ -f "$F" ]
  grep -q 'devagent-improve' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f improve`

Expected: FAILS.

- [ ] **Step 3: Create commands/improve.md**

```markdown
---
description: Surface latent bugs, side effects, ambiguities in the active issue's plan. Invokes devagent-improve skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:improve

Step 3 of the 21-step devAgent workflow. Invokes the `devagent-improve`
skill to read `<issue-dir>/imPlan.md` and append an `## Improvements`
section flagging concrete defects.

## Argument parsing

Per `commands/draft.md`. In short: optional `project`, optional issue
dir, remainder = `$NOTE`; `--` halts positional consumption.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists AND contains a `## Scope evaluation`
   section. If not, halt and tell the operator to run scope first.
3. Invoke `devagent-improve` with `$ISSUE_DIR` and `$NOTE`.
4. The skill appends `## Improvements` and calls
   `scripts/checklist-log.sh`.

## Halt and ask if

- Plan lacks `## Scope evaluation`.
- Plan already has an `## Improvements` section (overwrite? append
  sub-section? abort?).

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
```

- [ ] **Step 4: Verify test passes**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f improve`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/improve.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:improve command wrapper

Thin wrapper delegating to devagent-improve skill.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Build devagent-prune skill (workflow step 4)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-prune/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-prune/{imPlan.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_prune.bats`

- [ ] **Step 1: Write the failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_prune.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-prune"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-prune"
}

@test "devagent-prune passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-prune mentions potentialFutureEnhancements file" {
  grep -q 'imPlan-potentialFutureEnhancements.md' "$SKILL/SKILL.md"
}

@test "devagent-prune fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_prune.bats`

Expected: all three FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-prune/imPlan.md`:

```markdown
# Issue-1002 — Plan

## Tasks
1. Fix the off-by-one in foo_kernel.
2. Add benchmark.
3. Refactor adjacent bar_kernel for style consistency.
4. Update README.

## Improvements
- [defer] Task 3: bar_kernel refactor is unrelated; consistency
  cleanups should be a separate PR per surgical-diffs principle.
- [defer] Task 4: README update is not load-bearing for this fix.
```

`/home/user/src/devAgent/tests/fixtures/issue-prune/checklist.md`:

```markdown
# Issue-1002 — Workflow checklist

## Revision 1
- [x] 3. improve
- [~] 4. prune  ← active

## Log
- 2026-05-19 11:00  improve: 0 bugs, 2 deferred
```

- [ ] **Step 4: Write the SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-prune/SKILL.md`:

```markdown
---
name: devagent-prune
description: Use when running step 4 of the devAgent workflow to move deferred/dismissed items from the implementation plan into the future-enhancements file, producing a minimal load-bearing plan
when-to-use: After /devagent:improve has tagged items and before /devagent:tighten. Run as part of /devagent:prune.
---

# devagent-prune

Step 4 of the devAgent 21-step workflow. Walks the Improvements section
of `<issue-dir>/imPlan.md`, the Out-of-scope section of the Scope
evaluation, and any task whose value is not load-bearing for the
issue, and migrates them to
`<issue-dir>/imPlan-potentialFutureEnhancements.md`.

## Overview

A plan accumulates well-intentioned extras through draft → scope →
improve. Prune is the deliberate "no" pass: anything not directly
serving the issue's stated goal moves to the enhancements file. The
goal is a minimal plan that, when shipped, says only what the issue
asked for.

This is the **surgical-diffs filter**: bundled fixes lose review slots
to other contributors; one issue → one minimal change.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads: `<issue-dir>/imPlan.md` (Tasks + Improvements sections).
- Writes:
  - Modifies `<issue-dir>/imPlan.md` (removes pruned tasks/items;
    leaves a trail comment "moved to imPlan-potentialFutureEnhancements.md").
  - Creates/appends `<issue-dir>/imPlan-potentialFutureEnhancements.md`.

## Checklist

1. **Re-read the issue.** What is the *single* stated goal? Write it
   verbatim at the top of the section you are about to modify.
2. **Walk Tasks top-to-bottom.** For each, ask: "does this serve the
   single goal?" If no, mark for pruning. If "kind of, also serves a
   bigger refactor", prune — that bigger refactor is its own issue.
3. **Walk Improvements.** Every `[defer]` item migrates. Every
   `[dismiss]` item stays in `imPlan.md` as a brief footnote
   explaining the dismissal reasoning.
4. **Walk Scope evaluation > Out of scope.** Anything substantive
   gets a stub in the enhancements file so it's discoverable later.
5. **Re-count tasks.** If the plan now has zero tasks, halt — the
   prune over-pruned.
6. **Write the enhancements file** with the structure below; each
   migrated item gets its own `## Source: <where it came from>` block.

## Enhancements file format

```markdown
# Issue-NNNN — Potential future enhancements

Items moved out of the in-flight plan during /devagent:prune.
Each entry preserves the source citation so it can be promoted to
its own issue later via /devagent:reap.

## Source: Tasks (pruned 2026-05-19)
- Refactor adjacent bar_kernel for style consistency.

## Source: Improvements [defer] (2026-05-19)
- README update is not load-bearing for this fix.

## Source: Scope > Out of scope (2026-05-19)
- ARM NEON path for foo_kernel.
```

## Halt and ask if

- Plan has fewer than 2 tasks (nothing meaningful to prune).
- After pruning, fewer than 1 task remains.
- Operator's `$NOTE` says "keep X" but X is clearly off-scope —
  surface the conflict rather than silently keeping or pruning.
- Enhancements file already exists with conflicting entries — append,
  don't overwrite.

## Skipping policy

Never auto-skip. If the plan is already minimal (verified by
re-reading and confirming every task is load-bearing), surface
"nothing to prune; mark step `[-]` skipped?" for operator
confirmation.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" prune \
  "Pruned P items to imPlan-potentialFutureEnhancements.md; K tasks remain; note: $NOTE"
```

## Templates referenced

- `templates/imPlan_template.md` (target structure for the pruned plan).
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_prune.bats`

Expected: all three PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-prune tests/fixtures/issue-prune tests/skill_devagent_prune.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-prune skill (workflow step 4)

Migrates non-load-bearing tasks and deferred Improvements items into
imPlan-potentialFutureEnhancements.md; preserves source citations
for future /devagent:reap promotion.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Add /devagent:prune command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/prune.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend wrapper test**

Append to `/home/user/src/devAgent/tests/cmd_wrappers.bats`:

```bash
@test "prune.md exists, invokes devagent-prune, parses \$NOTE, logs" {
  F="$CMD_DIR/prune.md"
  [ -f "$F" ]
  grep -q 'devagent-prune' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f prune`

Expected: FAILS.

- [ ] **Step 3: Create commands/prune.md**

```markdown
---
description: Move deferred and off-scope items from the active issue's plan to the future-enhancements file. Invokes devagent-prune skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:prune

Step 4 of the 21-step devAgent workflow. Invokes the `devagent-prune`
skill to migrate non-load-bearing items from `imPlan.md` into
`imPlan-potentialFutureEnhancements.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan.md` exists with `## Improvements` section.
3. Invoke `devagent-prune` with `$ISSUE_DIR` and `$NOTE`.
4. The skill modifies `imPlan.md`, writes/appends
   `imPlan-potentialFutureEnhancements.md`, and logs via
   `scripts/checklist-log.sh`.

## Halt and ask if

- `## Improvements` section missing (run improve first).
- After pruning, no tasks remain.

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
```

- [ ] **Step 4: Verify test passes**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f prune`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/prune.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:prune command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Build devagent-tighten skill (workflow step 5)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-tighten/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-tighten/{imPlan.md,imPlan-potentialFutureEnhancements.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_tighten.bats`

- [ ] **Step 1: Write failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_tighten.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-tighten"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-tighten"
}

@test "devagent-tighten passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-tighten covers ordering, dependencies, file paths, test plan" {
  for k in 'ordering' 'dependenc' 'file path' 'test plan'; do
    grep -qi "$k" "$SKILL/SKILL.md" || { echo "missing: $k"; false; }
  done
}

@test "devagent-tighten fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/imPlan-potentialFutureEnhancements.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_tighten.bats`

Expected: all three FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-tighten/imPlan.md`:

```markdown
# Issue-1003 — Plan

## Tasks
1. Fix the off-by-one in foo_kernel.
2. Add benchmark covering the new bound.
```

`/home/user/src/devAgent/tests/fixtures/issue-tighten/imPlan-potentialFutureEnhancements.md`:

```markdown
# Issue-1003 — Potential future enhancements
```

`/home/user/src/devAgent/tests/fixtures/issue-tighten/checklist.md`:

```markdown
# Issue-1003 — Workflow checklist
## Revision 1
- [x] 4. prune
- [~] 5. tighten  ← active
```

- [ ] **Step 4: Write the SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-tighten/SKILL.md`:

```markdown
---
name: devagent-tighten
description: Use when running step 5 of the devAgent workflow to perform the final pre-implementation review of a pruned plan, locking down task ordering, file paths, and test plan
when-to-use: After /devagent:prune has produced a minimal plan and before /devagent:branch. Run as part of /devagent:tighten.
---

# devagent-tighten

Step 5 of the devAgent 21-step workflow. The last review pass on
`<issue-dir>/imPlan.md` before any code is written. Locks down the
plan so the implementing engineer (often a fresh subagent in a fresh
session) needs zero context-discovery to start.

## Overview

After prune, the plan is minimal. Tighten makes it executable:
- Tasks are in dependency order, smallest first.
- Each task names the file path(s) it touches with absolute paths.
- Each task has a one-line test plan (or explicit "no test, because…").
- The plan has a "Definition of done" matching the Scope evaluation's
  success criteria.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads: full `<issue-dir>/imPlan.md`, scope evaluation, any
  `<issue-dir>/issue.md` clarifications.
- Writes: modifies `<issue-dir>/imPlan.md` in place; may append a
  `## Definition of done` section.

## Checklist

1. **Task ordering.** Are tasks listed in dependency order? Smallest
   first? Reorder if not. Number tasks 1..N after reordering.
2. **Task dependencies.** Mark explicit cross-references with
   `(depends on task N)` notation. If a cycle appears, halt.
3. **File paths.** Every task names the absolute file path(s) it
   modifies or creates. "Update the kernel" → "Update
   `/abs/path/to/foo_kernel.c:142-160`".
4. **Test plan.** Every task has a one-line test plan or an explicit
   "no test, because…" justification. Halt if any task lacks both.
5. **Definition of done.** Append `## Definition of done` mapping
   each Scope > Success criterion to the task(s) that fulfill it.
6. **Re-read silently.** A fresh subagent should be able to start
   task 1 with zero clarifying questions. If you would ask one,
   tighten the plan until you wouldn't.

## Halt and ask if

- A dependency cycle exists between tasks.
- A task cannot have a test plan AND lacks a "no test, because…"
  justification.
- Success criteria from the Scope section are not fulfilled by any
  task.
- The plan needs more than one round of restructuring — surface that
  the plan should arguably go back to `/devagent:draft` rather than
  be patched here.

## Skipping policy

Never auto-skip. If the plan is already tight (ordering, paths, tests
all present), surface "plan is already tight; mark step `[-]`
skipped?" for operator confirmation.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" tighten \
  "Tightened; N tasks, M depend-edges, Definition of done has S criteria; note: $NOTE"
```

## Templates referenced

- `templates/imPlan_template.md` (canonical structure including
  Definition of done section).
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_tighten.bats`

Expected: all three PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-tighten tests/fixtures/issue-tighten tests/skill_devagent_tighten.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-tighten skill (workflow step 5)

Final review pass: task ordering, dependencies, absolute file paths,
per-task test plan, and a Definition of done section traceable to
the scope success criteria.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Add /devagent:tighten command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/tighten.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend wrapper test**

Append to `tests/cmd_wrappers.bats`:

```bash
@test "tighten.md exists, invokes devagent-tighten, parses \$NOTE, logs" {
  F="$CMD_DIR/tighten.md"
  [ -f "$F" ]
  grep -q 'devagent-tighten' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f tighten`

Expected: FAILS.

- [ ] **Step 3: Create commands/tighten.md**

```markdown
---
description: Final review pass on the active issue's pruned plan. Invokes devagent-tighten skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:tighten

Step 5 of the 21-step devAgent workflow. Invokes the `devagent-tighten`
skill for the last pre-implementation review of `imPlan.md`: task
ordering, dependencies, absolute file paths, per-task test plan,
Definition of done.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify `imPlan-potentialFutureEnhancements.md` exists (proves
   prune ran).
3. Invoke `devagent-tighten` with `$ISSUE_DIR` and `$NOTE`.
4. The skill rewrites `imPlan.md` and logs.

## Halt and ask if

- Prune step did not produce `imPlan-potentialFutureEnhancements.md`
  (the empty file is fine; missing file is not).
- Plan has a dependency cycle.

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f tighten`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/tighten.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:tighten command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Add /devagent:implement command wrapper (no new skill)

**Files:**
- Create: `/home/user/src/devAgent/commands/implement.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend wrapper test**

Append:

```bash
@test "implement.md exists, invokes superpowers:executing-plans, parses \$NOTE, logs" {
  F="$CMD_DIR/implement.md"
  [ -f "$F" ]
  grep -q 'superpowers:executing-plans' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f implement`

Expected: FAILS.

- [ ] **Step 3: Create commands/implement.md**

```markdown
---
description: Execute the active issue's plan task-by-task. Wraps superpowers:executing-plans.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:implement

Step 7 of the 21-step devAgent workflow. Invokes the upstream
`superpowers:executing-plans` skill against `<issue-dir>/imPlan.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify branch step has completed (state file's `branch` field is
   set and the working tree is on that branch). If not, halt.
3. Verify `imPlan.md` has a `## Definition of done` section (proves
   tighten ran).
4. Invoke `superpowers:executing-plans` with `$ISSUE_DIR/imPlan.md`
   as the plan path. Pass `$NOTE` as additional context the executor
   should consider (e.g., "skip task 4 — already merged upstream").
5. Implementation happens task-by-task per the wrapped skill's
   conventions. Each task gets its own commit per executing-plans
   defaults.
6. On full completion, append a single summary log entry:

   ```bash
   scripts/checklist-log.sh "$ISSUE_DIR" implement \
     "Plan implemented: N tasks done, F files changed, all tests pass; note: $NOTE"
   ```

## Halt and ask if

- Working tree is not on the issue's branch.
- `imPlan.md` lacks Definition of done.
- A task fails halfway through — surface the failure and let the
  operator decide whether to mark the step `[!]` stuck (via
  `/devagent:stuck`) or retry.

## Skipping policy

Never auto-skip individual tasks; the wrapped skill's task-level
prompting handles that. At the step level, never auto-skip implement
itself — without code change the rest of the pipeline is meaningless.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f implement`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/implement.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:implement command wrapper

Wraps superpowers:executing-plans for step 7. No new skill — thin
delegation with pre-checks for branch state and Definition of done.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Add /devagent:quality command wrapper (no new skill)

**Files:**
- Create: `/home/user/src/devAgent/commands/quality.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend wrapper test**

Append:

```bash
@test "quality.md exists, invokes simplify, references coding_standards.md, logs" {
  F="$CMD_DIR/quality.md"
  [ -f "$F" ]
  grep -q 'simplify' "$F"
  grep -q 'coding_standards' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f quality`

Expected: FAILS.

- [ ] **Step 3: Create commands/quality.md**

```markdown
---
description: Review and tighten code quality on the active issue's branch. Wraps simplify skill + project coding standards.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:quality

Step 8 of the 21-step devAgent workflow. Runs two passes on the
changed code:

1. The `simplify` skill (reuse, quality, efficiency review).
2. A coding-standards conformance pass against the project's
   `coding_standards.md`, resolved per the spec §12 artifact registry
   (project paths → `<devdoc>/templates/` → plugin
   `templates/coding_standards.md`).

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Resolve the coding-standards artifact path:
   - `${config.project.<name>.paths.coding_standards}` if set
   - else `<devdoc_dir>/templates/coding_standards.md` if exists
   - else `/home/user/src/devAgent/templates/coding_standards.md`
3. Verify the working tree is on the issue's branch and there are
   changed files since the baseline SHA (from state file).
4. Invoke the `simplify` skill on the changed diff.
5. Read the resolved `coding_standards.md` and check each rule
   against the changed files.
6. Apply fixes (or surface them for operator decision per simplify's
   own halt-and-ask rules).
7. On completion:

   ```bash
   scripts/checklist-log.sh "$ISSUE_DIR" quality \
     "Quality pass: K simplify findings applied, S standards findings applied; note: $NOTE"
   ```

## Halt and ask if

- Working tree has uncommitted changes that aren't from the implement
  step (operator may have stray edits — confirm before reformatting).
- Coding-standards file cannot be resolved from any of the three
  registry layers.
- Simplify proposes a refactor that would touch files outside the
  current diff (surfaces a scope-creep risk).

## Skipping policy

Never auto-skip. If the diff is tiny (< 5 LOC) and no standards apply,
surface "minimal diff; mark step `[-]` skipped?" for operator
confirmation.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f quality`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/quality.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:quality command wrapper

Wraps simplify skill plus a coding-standards pass driven by the
spec §12 artifact registry resolution order.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Build devagent-document-actual-work skill (workflow step 9)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-document-actual-work/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-document/{imPlan.md,checklist.md,git-changes.diff}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_document.bats`

- [ ] **Step 1: Write failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_document.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-document-actual-work"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-document"
}

@test "devagent-document-actual-work passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-document-actual-work references actualWork_template" {
  grep -q 'actualWork_template' "$SKILL/SKILL.md"
}

@test "devagent-document-actual-work explicitly handles 'no deviation' case" {
  grep -qi 'no deviation' "$SKILL/SKILL.md"
}

@test "devagent-document fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/git-changes.diff" ]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_document.bats`

Expected: all four FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-document/imPlan.md`:

```markdown
# Issue-1004 — Plan

## Tasks
1. Fix off-by-one in foo_kernel.c:142.
2. Add test in test_foo.c covering boundary.

## Definition of done
- [ ] Test test_foo_boundary passes.
```

`/home/user/src/devAgent/tests/fixtures/issue-document/checklist.md`:

```markdown
# Issue-1004 — Workflow checklist
## Revision 1
- [x] 8. quality
- [~] 9. document  ← active
```

`/home/user/src/devAgent/tests/fixtures/issue-document/git-changes.diff`:

```diff
diff --git a/foo_kernel.c b/foo_kernel.c
index 1111..2222 100644
--- a/foo_kernel.c
+++ b/foo_kernel.c
@@ -140,3 +140,3 @@ void foo(int *a, int n) {
-  for (int i = 0; i <= n; ++i) {
+  for (int i = 0; i < n; ++i) {
     a[i] *= 2;
diff --git a/test_foo.c b/test_foo.c
new file mode 100644
+void test_foo_boundary(void) { /* ... */ }
```

- [ ] **Step 4: Write the SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-document-actual-work/SKILL.md`:

```markdown
---
name: devagent-document-actual-work
description: Use when running step 9 of the devAgent workflow to record what was actually built versus what was planned, terse when there is no deviation from the plan
when-to-use: After /devagent:quality and before /devagent:commit. Run as part of /devagent:document.
---

# devagent-document-actual-work

Step 9 of the devAgent 21-step workflow. Writes
`<issue-dir>/actualWork.md` recording what was actually built. The
contract: **be terse when there is no deviation from `imPlan.md`**.
Most of the time, the plan is the work; the actualWork file is short.

## Overview

The plan answers "what should we build?" The actual-work file answers
"what did we build, and where did it differ?" Reviewers and future
operators read actualWork.md first when context-switching back to an
issue, so it must be honest about deviations.

The skill's bias is toward brevity. A plan that was executed
faithfully gets a 3-line actualWork.md — not a synthesised novel.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/imPlan.md` (the contract).
  - `git diff <baseline_sha>..HEAD` for the issue branch.
  - Per-task commit messages since baseline.
- Writes: creates `<issue-dir>/actualWork.md` from
  `templates/actualWork_template.md`.

## Checklist

1. **Compare plan to diff.** For each task in `imPlan.md`, find the
   commit(s) that implemented it. Mark each task as
   `[done as planned]`, `[done with deviation: <one-line reason>]`,
   `[skipped: <reason>]`, or `[discovered: <one-line description>]`
   for work done that wasn't in the plan.
2. **No deviation = terse.** If every task is `[done as planned]`,
   the actualWork.md is exactly this:

   ```markdown
   # Issue-NNNN — Actual work

   Plan executed as written. See `imPlan.md` for tasks; see
   `git log <baseline>..HEAD` for commits.
   ```

   No further sections. No "summary of what was built". No filler.

3. **Deviation = explain.** For each `[deviation]`, `[skipped]`, or
   `[discovered]`, write one paragraph under a `## Deviations` heading:
   what changed, why, what the operator should know later.

4. **Follow-ups.** Any `[discovered]` items that suggest future work
   get a `### Follow-up` sub-heading (the `/devagent:reap` skill
   harvests these by exactly this heading).

## Output template (deviation case)

```markdown
# Issue-NNNN — Actual work

## Plan vs actual
- Task 1: [done as planned]
- Task 2: [done with deviation: boundary test extended to cover
  negative n after discovering related bug]
- Task 3: [discovered: foo_kernel callers in bar.c had matching
  off-by-one; not fixed here per surgical-diffs principle]

## Deviations
### Task 2 deviation
The plan called for a single boundary test at n=N. While writing it,
n=-1 also failed the assertion. Extended to cover that case.

### Follow-up
- bar.c callers should be audited; file as separate issue per
  surgical-diffs.
```

## Halt and ask if

- The diff contains commits not attributable to any task in the plan
  AND not justifiable as "discovered" — surfaces possible scope creep.
- A planned task has no corresponding commit (was it really skipped?
  is the diff comparison broken?).
- The plan's Definition of done has unchecked items.

## Skipping policy

Never auto-skip. This is the **only** place deviations get documented;
skipping defeats the purpose. If the operator insists on skipping,
surface that this means no record of what was actually built.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" document \
  "actualWork.md written: D deviations, F follow-ups; note: $NOTE"
```

## Templates referenced

- `templates/actualWork_template.md` (canonical structure with
  Deviations and Follow-up sub-headings).
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_document.bats`

Expected: all four PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-document-actual-work tests/fixtures/issue-document tests/skill_devagent_document.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-document-actual-work skill (workflow step 9)

Terse when plan executed as written; explicit Deviations and
Follow-up sections when not. Follow-up headings are the harvest
target for /devagent:reap.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Add /devagent:document command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/document.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend test**

Append:

```bash
@test "document.md exists, invokes devagent-document-actual-work, parses \$NOTE, logs" {
  F="$CMD_DIR/document.md"
  [ -f "$F" ]
  grep -q 'devagent-document-actual-work' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f document`

Expected: FAILS.

- [ ] **Step 3: Create commands/document.md**

```markdown
---
description: Record actual work versus the plan for the active issue. Invokes devagent-document-actual-work skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:document

Step 9 of the 21-step devAgent workflow. Invokes the
`devagent-document-actual-work` skill to write
`<issue-dir>/actualWork.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file has a `baseline_sha` (needed to diff actual
   against plan). If absent, halt — operator must run branch first.
3. Invoke `devagent-document-actual-work` with `$ISSUE_DIR` and
   `$NOTE`.
4. The skill writes actualWork.md and logs.

## Halt and ask if

- State file lacks `baseline_sha`.
- imPlan.md lacks `## Definition of done` section.

## Skipping policy

Never auto-skip; documenting deviations is the entire value of this
step.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f document`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/document.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:document command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Build devagent-draft-mr skill (workflow step 12)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-draft-mr/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-draftmr/{imPlan.md,actualWork.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_draftmr.bats`

- [ ] **Step 1: Write failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_draftmr.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-draft-mr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-draftmr"
}

@test "devagent-draft-mr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-draft-mr references mr_template.md" {
  grep -q 'mr_template.md' "$SKILL/SKILL.md"
}

@test "devagent-draft-mr writes mr.md" {
  grep -qE '\bmr\.md\b' "$SKILL/SKILL.md"
}

@test "devagent-draftmr fixture exists" {
  [ -s "$FIXT/imPlan.md" ]
  [ -s "$FIXT/actualWork.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_draftmr.bats`

Expected: all FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-draftmr/imPlan.md`:

```markdown
# Issue-1005 — Plan
## Tasks
1. Fix off-by-one.
2. Add boundary test.
## Definition of done
- [x] test_foo_boundary passes.
```

`/home/user/src/devAgent/tests/fixtures/issue-draftmr/actualWork.md`:

```markdown
# Issue-1005 — Actual work
Plan executed as written.
```

`/home/user/src/devAgent/tests/fixtures/issue-draftmr/checklist.md`:

```markdown
# Issue-1005 — Workflow checklist
## Revision 1
- [x] 11. analyze
- [~] 12. draftmr ← active
```

- [ ] **Step 4: Write SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-draft-mr/SKILL.md`:

```markdown
---
name: devagent-draft-mr
description: Use when running step 12 of the devAgent workflow to draft the merge-request body from imPlan, actualWork, and analyzer output before shipping
when-to-use: After /devagent:analyze and before /devagent:review. Run as part of /devagent:draftmr.
---

# devagent-draft-mr

Step 12 of the devAgent 21-step workflow. Fills in
`templates/mr_template.md` from the issue's plan, actualWork, and
analyzer findings, writing the result to `<issue-dir>/mr.md`. The
ship step later uses `mr.md` verbatim as the MR body.

## Overview

The MR body is the only artifact a reviewer reads first. It must
explain (1) what the change does, (2) why now, (3) what evidence
exists it works, (4) what the reviewer should pay attention to.
The skill fills the template from existing artifacts so nothing is
re-typed.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/issue.md` (for the problem statement and original
    motivation).
  - `<issue-dir>/imPlan.md` (for what was promised).
  - `<issue-dir>/actualWork.md` (for what was delivered + deviations).
  - `<issue-dir>/analysis/*.txt` (for static-analyzer / sanitizer
    summary).
  - Resolved `mr_template.md` (per spec §12 registry: project paths →
    `<devdoc>/templates/` → plugin `templates/mr_template.md`).
- Writes: `<issue-dir>/mr.md`.

## Checklist

1. **Resolve template.** Walk the §12 artifact registry to find
   `mr_template.md`. Halt if unresolvable.
2. **Fill Summary section.** One paragraph from the issue's problem
   statement + the actualWork's outcome. No marketing.
3. **Fill Motivation section.** Why now, drawn from `issue.md`
   labels, related issues, and any operator $NOTE.
4. **Fill Evidence section.** Bullet list:
   - Tests added (from actualWork).
   - Analyzer results (one line per tool with finding counts from
     `analysis/*.txt`).
   - Benchmarks if performance issue (path to evidence plot from
     `tools/plot_pr_evidence.R` if present in repo).
5. **Fill Reviewer notes section.** Anything from actualWork's
   `## Deviations`. If none, write "Plan executed as written; see
   imPlan.md for task list."
6. **Fill Checklist section** (DCO, surgical-diff confirmation, etc.)
   from the template. Pre-check items that are verifiable from
   artifacts; leave others unchecked.
7. **Write `<issue-dir>/mr.md`.**

## Halt and ask if

- `mr_template.md` cannot be resolved from any registry layer.
- `actualWork.md` is missing — operator must run document first.
- Any `analysis/*.txt` reports unaddressed findings — surface them
  before filing the MR.
- `<issue-dir>/mr.md` already exists with substantive content —
  ask whether to overwrite, append a revision section, or abort.

## Skipping policy

Never auto-skip. Filing an MR with no body is bad-faith. If the issue
is docs-only and the template is overkill, surface "trivial change;
fill template stub only?" rather than skipping outright.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" draftmr \
  "mr.md drafted from mr_template.md (template source: $TEMPLATE_PATH); note: $NOTE"
```

## Templates referenced

- `templates/mr_template.md` (the canonical structure being filled).
```

- [ ] **Step 5: Verify**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_draftmr.bats`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-draft-mr tests/fixtures/issue-draftmr tests/skill_devagent_draftmr.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-draft-mr skill (workflow step 12)

Fills the resolved mr_template.md from issue.md, imPlan.md,
actualWork.md, and analysis/*.txt; writes <issue-dir>/mr.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Add /devagent:draftmr command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/draftmr.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend test**

Append:

```bash
@test "draftmr.md exists, invokes devagent-draft-mr, parses \$NOTE, logs" {
  F="$CMD_DIR/draftmr.md"
  [ -f "$F" ]
  grep -q 'devagent-draft-mr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f draftmr`

Expected: FAILS.

- [ ] **Step 3: Create commands/draftmr.md**

```markdown
---
description: Draft the MR body for the active issue. Invokes devagent-draft-mr skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:draftmr

Step 12 of the 21-step devAgent workflow. Invokes the
`devagent-draft-mr` skill to fill `templates/mr_template.md` from the
issue's artifacts and write `<issue-dir>/mr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify analyze step completed (`<issue-dir>/analysis/` exists).
3. Verify actualWork.md exists.
4. Invoke `devagent-draft-mr`.

## Halt and ask if

- analyze step did not run (no analysis/ dir).
- actualWork.md missing.
- mr.md already exists with content (overwrite? revise? abort?).

## Skipping policy

Never auto-skip.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f draftmr`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/draftmr.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:draftmr command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Add /devagent:review command wrapper (no new skill)

**Files:**
- Create: `/home/user/src/devAgent/commands/review.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend test**

Append:

```bash
@test "review.md exists, invokes superpowers:requesting-code-review, logs" {
  F="$CMD_DIR/review.md"
  [ -f "$F" ]
  grep -q 'superpowers:requesting-code-review' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f review`

Expected: FAILS.

- [ ] **Step 3: Create commands/review.md**

```markdown
---
description: Run code review on the active issue's branch. Wraps superpowers:requesting-code-review.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:review

Step 13 of the 21-step devAgent workflow. Invokes the upstream
`superpowers:requesting-code-review` skill against the issue's
branch diff. Produces a review report that the operator addresses
before the red-team step (14).

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists (proves draftmr ran) and branch is set.
3. Resolve coding_standards artifact per spec §12 and pass its path
   to the wrapped skill as context.
4. Invoke `superpowers:requesting-code-review` with the diff scope
   = `baseline_sha..HEAD` on the issue's branch.
5. Save the review output to `<issue-dir>/analysis/YYYY-MM-DD-review.md`.
6. Log:

   ```bash
   scripts/checklist-log.sh "$ISSUE_DIR" review \
     "Review: F findings (B blocking, N nits); see analysis/YYYY-MM-DD-review.md; note: $NOTE"
   ```

## Halt and ask if

- mr.md does not exist (draftmr step skipped).
- The wrapped skill returns blocking findings — do not silently
  advance. Surface the findings and let the operator decide whether
  to address, mark `[!]` stuck, or override.

## Skipping policy

Never auto-skip; review is a quality gate.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f review`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/review.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:review command wrapper

Wraps superpowers:requesting-code-review for step 13. Saves output
to analysis/YYYY-MM-DD-review.md and refuses to silently advance
past blocking findings.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Build devagent-redmr skill (workflow step 14)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-redmr/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-redmr/{mr.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_redmr.bats`

- [ ] **Step 1: Write failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_redmr.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-redmr"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-redmr"
}

@test "devagent-redmr passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-redmr references redteam_mr template" {
  grep -q 'redteam_mr' "$SKILL/SKILL.md"
}

@test "devagent-redmr classifies findings by severity" {
  grep -qi 'blocking' "$SKILL/SKILL.md"
  grep -qi 'severity' "$SKILL/SKILL.md"
}

@test "devagent-redmr fixture exists" {
  [ -s "$FIXT/mr.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_redmr.bats`

Expected: all FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-redmr/mr.md`:

```markdown
# Fix off-by-one in foo_kernel

## Summary
Replaces `i <= n` with `i < n` in foo_kernel inner loop; adds
boundary test.

## Evidence
- test_foo_boundary added; passes.
- cppcheck: 0 findings.
```

`/home/user/src/devAgent/tests/fixtures/issue-redmr/checklist.md`:

```markdown
# Issue-1006 — Workflow checklist
## Revision 1
- [x] 13. review
- [~] 14. redmr  ← active
```

- [ ] **Step 4: Write SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-redmr/SKILL.md`:

```markdown
---
name: devagent-redmr
description: Use when running step 14 of the devAgent workflow to run a red-team adversarial review of the MR body and diff before shipping upstream
when-to-use: After /devagent:review and before /devagent:ship. Run as part of /devagent:redmr.
---

# devagent-redmr

Step 14 of the devAgent 21-step workflow. Runs the project's MR
red-team prompt (`templates/redteam_mr.md`, resolved per §12 registry)
against `<issue-dir>/mr.md` plus the branch diff. Produces a severity-
classified findings report and refuses to silently advance past
blocking findings.

## Overview

Red-team is adversarial: assume the reviewer is hostile and looking
for any reason to reject. The output is a list of findings classified
by severity. The operator must address every BLOCKING finding before
the ship step will fire.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/mr.md` (the MR body under attack).
  - `<issue-dir>/imPlan.md`, `actualWork.md` (for context).
  - `git diff <baseline_sha>..HEAD` (the actual code change).
  - Resolved `templates/redteam_mr.md` (per spec §12 registry).
- Writes: `<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

## Checklist

1. **Resolve template.** Walk §12 registry to locate `redteam_mr.md`.
   Halt if unresolvable.
2. **Load the prompt.** Read the resolved redteam_mr.md verbatim;
   it is the contract for what to attack and how.
3. **Apply prompt to mr.md + diff.** Run every adversarial check the
   template specifies. Produce one finding per identified concern.
4. **Classify every finding** with one of these severity tags:
   - `[BLOCKING]` — reviewer will reject the MR until fixed.
   - `[MAJOR]` — reviewer will request changes; merge stalls.
   - `[MINOR]` — reviewer will nit but merge if rest is clean.
   - `[INFO]` — informational; no action required.
5. **Write findings to** `<issue-dir>/analysis/YYYY-MM-DD-redmr.md`
   in this format:

   ```markdown
   # Red-team review — <date>

   ## Summary
   B blocking, M major, m minor, I info

   ## Findings
   ### [BLOCKING] <one-line title>
   <evidence: file:line, quote, why this blocks>
   <suggested remediation>
   ```
6. **Refuse silent advance.** If B > 0, the skill exits with a
   non-zero status indicator and explicitly tells the operator to
   address findings before re-running, or mark `[!]` stuck via
   `/devagent:stuck`.

## Halt and ask if

- `mr.md` does not exist (draftmr step skipped).
- `redteam_mr.md` cannot be resolved.
- Findings include items the skill cannot classify confidently —
  surface them un-tagged and ask the operator to triage rather than
  inventing a severity.

## Skipping policy

Never auto-skip. Red-team is an unconditional gate on shipping
upstream per operator's principal value prop. If the operator insists
on skipping (private fork-only experimentation, etc.), surface
"this means shipping un-red-teamed; confirm?" and require
acknowledgement.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" redmr \
  "Red-team: B blocking, M major, m minor, I info (template: $TEMPLATE_PATH); note: $NOTE"
```

The format above is contract: `statusreport.sh` parses for the word
`blocking` and an integer to surface failed red-teams in status
reports per spec §14.4.

## Templates referenced

- `templates/redteam_mr.md` (the adversarial prompt itself).
```

- [ ] **Step 5: Verify**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_redmr.bats`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-redmr tests/fixtures/issue-redmr tests/skill_devagent_redmr.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-redmr skill (workflow step 14)

Loads templates/redteam_mr.md per §12 registry, classifies findings
by severity, refuses silent advance on BLOCKING. Log format matches
statusreport.sh parser contract from spec §14.4.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 19: Add /devagent:redmr command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/redmr.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend test**

Append:

```bash
@test "redmr.md exists, invokes devagent-redmr, parses \$NOTE, logs" {
  F="$CMD_DIR/redmr.md"
  [ -f "$F" ]
  grep -q 'devagent-redmr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f redmr`

Expected: FAILS.

- [ ] **Step 3: Create commands/redmr.md**

```markdown
---
description: Run red-team adversarial review of the MR before shipping. Invokes devagent-redmr skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:redmr

Step 14 of the 21-step devAgent workflow. Invokes the `devagent-redmr`
skill to run `templates/redteam_mr.md` against the MR body and diff,
classify findings by severity, and write the report to
`<issue-dir>/analysis/YYYY-MM-DD-redmr.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify mr.md exists.
3. Invoke `devagent-redmr`.
4. Skill writes the report and logs the finding counts in the
   parser-compatible format from spec §14.4.

## Halt and ask if

- mr.md missing.
- Skill reports BLOCKING findings — do NOT advance to ship.

## Skipping policy

Never auto-skip; red-team is an unconditional gate per spec §6.3
principle and the operator's principal value prop.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f redmr`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/redmr.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:redmr command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 20: Build devagent-impact skill (workflow step 18)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-impact/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-impact/{issue.md,actualWork.md,checklist.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_impact.bats`

- [ ] **Step 1: Write failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_impact.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-impact"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-impact"
}

@test "devagent-impact passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-impact distinguishes quantifiable vs qualitative" {
  grep -qi 'quantif' "$SKILL/SKILL.md"
  grep -qi 'qualitat' "$SKILL/SKILL.md"
}

@test "devagent-impact writes to issue dir" {
  grep -q 'impact.md' "$SKILL/SKILL.md"
}

@test "devagent-impact fixture exists" {
  [ -s "$FIXT/issue.md" ]
  [ -s "$FIXT/actualWork.md" ]
  [ -s "$FIXT/checklist.md" ]
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_impact.bats`

Expected: all FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-impact/issue.md`:

```markdown
# gnuradio/volk#1007 — perf: fuse pre-dechirp kernels
- Labels: performance, enhancement
```

`/home/user/src/devAgent/tests/fixtures/issue-impact/actualWork.md`:

```markdown
# Issue-1007 — Actual work
Fused multiply + add kernels into a single pass on RPi4 + x86 testbeds.
Plan executed as written.
```

`/home/user/src/devAgent/tests/fixtures/issue-impact/checklist.md`:

```markdown
# Issue-1007 — Workflow checklist
## Revision 1
- [x] 17. updatewbs
- [~] 18. impact  ← active
```

- [ ] **Step 4: Write SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-impact/SKILL.md`:

```markdown
---
name: devagent-impact
description: Use when running step 18 of the devAgent workflow to measure, quantify, and record the real-world impact of a merged change before extracting lessons learned
when-to-use: After /devagent:updatewbs (step 17) and before /devagent:lessonslearned (step 19). Run as part of /devagent:impact.
---

# devagent-impact

Step 18 of the devAgent 21-step workflow. Captures the *measurable*
outcome of a shipped change so future status reports, velocity
estimates, and lessons-learned have ground truth to refer to.

## Overview

A merged MR is not the same as impact. Impact is the answer to "what
changed in the world because this shipped?" — runtime improvement,
LOC reduction, bug fix verified in production, user complaint
silenced, etc. The skill writes `<issue-dir>/impact.md` with two
sections: **Quantifiable** (numbers) and **Qualitative** (when
numbers are not available or honest).

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/issue.md` (labels indicate the impact dimension to
    measure — `performance` → benchmarks; `bug` → reproducer fixed;
    `docs` → operator-facing clarity).
  - `<issue-dir>/actualWork.md`.
  - Pre/post evidence the operator points to (benchmark CSV, plot
    PNG from `tools/plot_pr_evidence.R`, etc.) — surfaced via `$NOTE`.
- Writes: `<issue-dir>/impact.md`.

## Checklist

1. **Read the issue labels.** Determine the impact dimension:
   - `performance` → speed-up percent, throughput delta.
   - `bug` → reproducer fixed; severity (crash/wrong-answer/cosmetic).
   - `docs` → operator-facing improvement (be honest: usually
     qualitative).
   - `chore`/`refactor` → LOC delta, maintainability score; usually
     qualitative.
2. **Quantifiable section.** For each measurable dimension, record:
   - Baseline number (with units, source, date).
   - Post-change number (same units, source, date).
   - Delta (absolute and percent).
   - Statistical context if available (N runs, std-dev, CI).
   - **Never invent numbers.** If a measurement was not run, say so
     explicitly: "Quantifiable measurement not run because <reason>;
     see Qualitative section."
3. **Qualitative section.** For impact that resists numbers:
   - What changed in user-visible behavior?
   - What complaint or follow-up issue does this close?
   - What downstream pattern does this enable / unblock?
4. **Evidence references.** Link or path-cite every artifact backing
   a quantifiable claim. If `$NOTE` includes a path to a plot PNG,
   embed the reference.
5. **Honesty check.** Re-read every quantifiable claim. If you cannot
   point to evidence, move it to Qualitative or strike it.

## Output format

```markdown
# Issue-NNNN — Impact

## Quantifiable
- Throughput on RPi4: 1.84 GB/s → 2.31 GB/s (+25.5%, N=30, σ=0.04)
  evidence: tools/plot_pr_evidence.R output at
  ~/src/devDoc/volk/Issue-1007/evidence/2026-05-19-rpi4.png
- Build time: unchanged.

## Qualitative
- Unblocks fusion of post-dechirp kernels (separate issue).
- Pattern documented for future kernel-pair fusions.
```

## Halt and ask if

- Issue labels suggest performance impact but no benchmark evidence
  is supplied via `$NOTE` and none is discoverable in
  `<issue-dir>/analysis/` — surface "no evidence; halt or proceed
  qualitative-only?"
- Operator's $NOTE includes numbers that contradict observable
  evidence — surface the discrepancy rather than copying the note.

## Skipping policy

Never auto-skip. If a change has genuinely no measurable impact (pure
chore), surface "no impact to measure; mark step `[-]` skipped?" and
require operator confirmation. Default is not to skip — qualitative
notes still have value for lessons-learned.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" impact \
  "impact.md written: Q quantifiable claims, L qualitative notes; note: $NOTE"
```

## Templates referenced

- None directly. References `tools/plot_pr_evidence.R` outputs when
  performance evidence exists.
```

- [ ] **Step 5: Verify**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_impact.bats`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-impact tests/fixtures/issue-impact tests/skill_devagent_impact.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-impact skill (workflow step 18)

Captures measurable post-merge impact. Quantifiable vs qualitative
sections; refuses to invent numbers; references plot_pr_evidence.R
outputs for performance issues.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 21: Add /devagent:impact command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/impact.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend test**

Append:

```bash
@test "impact.md exists, invokes devagent-impact, parses \$NOTE, logs" {
  F="$CMD_DIR/impact.md"
  [ -f "$F" ]
  grep -q 'devagent-impact' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f impact`

Expected: FAILS.

- [ ] **Step 3: Create commands/impact.md**

```markdown
---
description: Measure and record the real-world impact of a merged change. Invokes devagent-impact skill.
argument-hint: "[project] [issue-dir] [free-form note: paths to evidence files]"
---

# /devagent:impact

Step 18 of the 21-step devAgent workflow. Invokes the `devagent-impact`
skill to write `<issue-dir>/impact.md`.

## Argument parsing

Per `commands/draft.md`. `$NOTE` is the conventional channel for
operator-supplied evidence paths (e.g.,
"benchmark plot at /abs/path/to/plot.png; baseline csv at /abs/path/baseline.csv").

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify state file shows the issue is merged (mr_url present and
   mr-state is `merged`). If not, halt — measuring impact on
   un-merged code is meaningless.
3. Invoke `devagent-impact` with `$ISSUE_DIR` and `$NOTE`.
4. Skill writes impact.md and logs.

## Halt and ask if

- Issue is not merged.
- Performance label present but no evidence path in `$NOTE`.

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f impact`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/impact.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:impact command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 22: Build devagent-lessons-learned skill (workflow step 19)

**Files:**
- Create: `/home/user/src/devAgent/skills/devagent-lessons-learned/SKILL.md`
- Create fixtures: `/home/user/src/devAgent/tests/fixtures/issue-lessons/{checklist.md,actualWork.md}`
- Test: `/home/user/src/devAgent/tests/skill_devagent_lessons.bats`

- [ ] **Step 1: Write failing test**

Create `/home/user/src/devAgent/tests/skill_devagent_lessons.bats`:

```bash
#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  SKILL="$BATS_TEST_DIRNAME/../skills/devagent-lessons-learned"
  FIXT="$BATS_TEST_DIRNAME/fixtures/issue-lessons"
}

@test "devagent-lessons-learned passes structural checks" {
  run bash "$HARNESS" "$SKILL" "$FIXT"
  [ "$status" -eq 0 ]
}

@test "devagent-lessons-learned references lessonsLearned_template" {
  grep -q 'lessonsLearned_template' "$SKILL/SKILL.md"
}

@test "devagent-lessons-learned tags actionable entries (for reap)" {
  grep -qi 'actionable' "$SKILL/SKILL.md"
}

@test "devagent-lessons fixture exists" {
  [ -s "$FIXT/checklist.md" ]
  [ -s "$FIXT/actualWork.md" ]
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_lessons.bats`

Expected: all FAIL.

- [ ] **Step 3: Create fixtures**

`/home/user/src/devAgent/tests/fixtures/issue-lessons/checklist.md`:

```markdown
# Issue-1008 — Workflow checklist
## Revision 1
- [x] 18. impact
- [~] 19. lessonslearned  ← active

## Log
- 2026-05-19 09:00  draft: imPlan.md written (4 tasks)
- 2026-05-19 09:10  scope: 2 ambiguities resolved
- 2026-05-19 10:00  improve: 1 bug surfaced, fixed in task 2
- 2026-05-19 11:00  prune: moved 1 item to enhancements
- 2026-05-19 12:00  implement: 4 tasks done, all tests pass
- 2026-05-19 13:00  redmr: 0 blocking, 2 minor
```

`/home/user/src/devAgent/tests/fixtures/issue-lessons/actualWork.md`:

```markdown
# Issue-1008 — Actual work
## Plan vs actual
- Task 1: [done as planned]
- Task 2: [done with deviation: improve-step bug fix added one extra commit]
- Task 3: [done as planned]
- Task 4: [discovered: docstring referenced removed symbol]

## Deviations
### Task 2 deviation
The improve step caught a sign-error that wasn't in the original plan;
fixed inline.

### Follow-up
- Audit other docstrings in the same module.
```

- [ ] **Step 4: Write SKILL.md**

Create `/home/user/src/devAgent/skills/devagent-lessons-learned/SKILL.md`:

```markdown
---
name: devagent-lessons-learned
description: Use when running step 19 of the devAgent workflow to extract reusable lessons from a completed issue so the same friction is not paid twice
when-to-use: After /devagent:impact and before /devagent:cleanup. Run as part of /devagent:lessonslearned.
---

# devagent-lessons-learned

Step 19 of the devAgent 21-step workflow. Writes
`<issue-dir>/lessonsLearned.md` capturing what to do differently next
time. Entries tagged `actionable` are harvested by `/devagent:reap`
into new captures.

## Overview

A lesson is not a postmortem. The format is one-line claim + one-line
evidence + one-line consequence. The bias is toward short, specific,
re-readable entries — lessonsLearned is read at the start of similar
issues, not at the end of the current one.

## Inputs

- `$ISSUE_DIR`, `$NOTE`.
- Reads:
  - `<issue-dir>/checklist.md` (the Log section — chronology of
    decisions).
  - `<issue-dir>/actualWork.md` (the Deviations section).
  - `<issue-dir>/analysis/*-redmr.md` (what red-team caught).
  - `<issue-dir>/impact.md` (what actually mattered).
  - Resolved `templates/lessonsLearned_template.md`.
- Writes: `<issue-dir>/lessonsLearned.md`.

## Checklist

1. **Resolve template.** Walk §12 registry to find
   `lessonsLearned_template.md`. Halt if unresolvable.
2. **Read the Log chronologically.** Identify decision points where
   the operator second-guessed or reversed course. Each is a candidate
   lesson.
3. **Read Deviations.** Each deviation is a candidate lesson — what
   in the plan was wrong, what was learned mid-implementation?
4. **Read red-team findings.** Each BLOCKING finding the operator
   addressed is a candidate lesson about future plans.
5. **Write entries.** Format per entry:

   ```markdown
   ### <one-line claim>
   - Evidence: <one line citing log entry, deviation, or finding>
   - Consequence: <one line: what to do differently next time>
   - Tags: [actionable | reference | norm | pattern]
   ```

6. **Tag `actionable`** when the lesson implies a follow-up issue
   should exist (`/devagent:reap` harvests these). Tag `reference`
   when it's a fact to remember. Tag `norm` when it changes operator
   working style. Tag `pattern` when it generalises beyond this issue.
7. **Brevity check.** If an entry is more than 4 lines total, split
   it or trim. Long lessons are unread lessons.

## Halt and ask if

- Fewer than 2 candidate lessons surface AND the issue had > 5 log
  entries — likely the skill is missing something; surface the
  thinness for operator review rather than writing a mostly-empty
  file.
- Operator's $NOTE asserts a lesson that contradicts the evidence in
  log/deviations — surface the conflict.

## Skipping policy

Never auto-skip. If the issue was truly mechanical (e.g., a typo fix
with zero deviations and zero red-team findings), surface "nothing
to learn; mark step `[-]` skipped?" for operator confirmation.

## Logging

```bash
scripts/checklist-log.sh "$ISSUE_DIR" lessonslearned \
  "lessonsLearned.md written: L entries (A actionable, R reference, N norm, P pattern); note: $NOTE"
```

## Templates referenced

- `templates/lessonsLearned_template.md` (canonical entry format and
  tag taxonomy).
```

- [ ] **Step 5: Verify**

Run: `cd /home/user/src/devAgent && bats tests/skill_devagent_lessons.bats`

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/user/src/devAgent
git add skills/devagent-lessons-learned tests/fixtures/issue-lessons tests/skill_devagent_lessons.bats
git commit -s -m "$(cat <<'EOF'
plan4: add devagent-lessons-learned skill (workflow step 19)

Extracts reusable lessons from checklist log, deviations, and
red-team findings. Tag taxonomy: actionable | reference | norm |
pattern. Actionable entries are the harvest target for /devagent:reap.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 23: Add /devagent:lessonslearned command wrapper

**Files:**
- Create: `/home/user/src/devAgent/commands/lessonslearned.md`
- Modify: `/home/user/src/devAgent/tests/cmd_wrappers.bats`

- [ ] **Step 1: Extend test**

Append:

```bash
@test "lessonslearned.md exists, invokes devagent-lessons-learned, parses \$NOTE, logs" {
  F="$CMD_DIR/lessonslearned.md"
  [ -f "$F" ]
  grep -q 'devagent-lessons-learned' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f lessonslearned`

Expected: FAILS.

- [ ] **Step 3: Create commands/lessonslearned.md**

```markdown
---
description: Extract reusable lessons from a completed issue. Invokes devagent-lessons-learned skill.
argument-hint: "[project] [issue-dir] [free-form note...]"
---

# /devagent:lessonslearned

Step 19 of the 21-step devAgent workflow. Invokes the
`devagent-lessons-learned` skill to write `<issue-dir>/lessonsLearned.md`.

## Argument parsing

Per `commands/draft.md`.

## Workflow

1. Resolve `project`, `issue-dir`, `$NOTE`.
2. Verify checklist log has > 2 entries (otherwise nothing to learn from).
3. Invoke `devagent-lessons-learned`.

## Halt and ask if

- Fewer than 2 log entries.
- lessonsLearned.md already exists with content (overwrite? append? abort?).

## Skipping policy

Never auto-skip; surface skip requests for operator confirmation.
```

- [ ] **Step 4: Verify**

Run: `cd /home/user/src/devAgent && bats tests/cmd_wrappers.bats -f lessonslearned`

Expected: PASSES.

- [ ] **Step 5: Commit**

```bash
cd /home/user/src/devAgent
git add commands/lessonslearned.md tests/cmd_wrappers.bats
git commit -s -m "$(cat <<'EOF'
plan4: add /devagent:lessonslearned command wrapper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 24: Full-suite regression run

**Files:**
- Read: all created `.bats` files
- No edits — verification only

- [ ] **Step 1: Run every bats file in tests/**

Run: `cd /home/user/src/devAgent && bats tests/`

Expected: ALL tests pass across `tests/lib_skill_fixture_check.bats`,
`tests/cmd_wrappers.bats`, and 9 `tests/skill_devagent_*.bats` files.
Total test count should be roughly: 5 (harness) + 13 (wrappers) + 4 × 9
(skills, ~36) ≈ 54 tests.

- [ ] **Step 2: Run shell linter on any new shell**

Run: `shellcheck /home/user/src/devAgent/tests/lib/skill-fixture-check.sh`

Expected: zero findings. If shellcheck is not installed, document the
gap and skip.

- [ ] **Step 3: Sanity-check the final directory layout**

Run:

```bash
ls /home/user/src/devAgent/commands/ | sort
ls /home/user/src/devAgent/skills/ | sort
```

Expected stdout:

```
# commands
.gitkeep
document.md
draft.md
draftmr.md
impact.md
implement.md
improve.md
lessonslearned.md
prune.md
quality.md
redmr.md
review.md
scope.md
tighten.md

# skills
.gitkeep
devagent-document-actual-work
devagent-draft-mr
devagent-impact
devagent-improve
devagent-lessons-learned
devagent-prune
devagent-redmr
devagent-scope
devagent-tighten
```

If anything is missing, return to the corresponding task. No new
commit at this step.

- [ ] **Step 4: Verify each SKILL.md has the trailing checklist-log invocation literal**

Run:

```bash
for f in /home/user/src/devAgent/skills/devagent-*/SKILL.md; do
  grep -q 'scripts/checklist-log.sh' "$f" || echo "MISSING in $f"
done
```

Expected: no MISSING lines.

- [ ] **Step 5: Verify each command file references its skill**

Run:

```bash
for f in /home/user/src/devAgent/commands/*.md; do
  case "$(basename "$f")" in
    draft.md)         grep -q 'superpowers:writing-plans' "$f"           || echo "BAD: $f";;
    implement.md)     grep -q 'superpowers:executing-plans' "$f"         || echo "BAD: $f";;
    quality.md)       grep -q 'simplify' "$f"                            || echo "BAD: $f";;
    review.md)        grep -q 'superpowers:requesting-code-review' "$f"  || echo "BAD: $f";;
    scope.md)         grep -q 'devagent-scope' "$f"                      || echo "BAD: $f";;
    improve.md)       grep -q 'devagent-improve' "$f"                    || echo "BAD: $f";;
    prune.md)         grep -q 'devagent-prune' "$f"                      || echo "BAD: $f";;
    tighten.md)       grep -q 'devagent-tighten' "$f"                    || echo "BAD: $f";;
    document.md)      grep -q 'devagent-document-actual-work' "$f"       || echo "BAD: $f";;
    draftmr.md)       grep -q 'devagent-draft-mr' "$f"                   || echo "BAD: $f";;
    redmr.md)         grep -q 'devagent-redmr' "$f"                      || echo "BAD: $f";;
    impact.md)        grep -q 'devagent-impact' "$f"                     || echo "BAD: $f";;
    lessonslearned.md) grep -q 'devagent-lessons-learned' "$f"           || echo "BAD: $f";;
  esac
done
```

Expected: no BAD lines.

- [ ] **Step 6: Final commit (if any verification artifacts were modified)**

If steps 1-5 caused any edits, commit them:

```bash
cd /home/user/src/devAgent
git status
# Only commit if there are real changes
git add -- :^.gitkeep
git commit -s -m "$(cat <<'EOF'
plan4: regression verification fixes

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" || echo "no changes to commit"
```

Otherwise: no commit. This task is verification only.

---

## Self-Review

**Spec coverage:**

| Spec §6.3 row | Plan task |
|---|---|
| 1 draft (wrap writing-plans) | Task 2 |
| 2 scope (NEW skill) | Tasks 3-4 |
| 3 improve (NEW skill) | Tasks 5-6 |
| 4 prune (NEW skill) | Tasks 7-8 |
| 5 tighten (NEW skill) | Tasks 9-10 |
| 7 implement (wrap executing-plans) | Task 11 |
| 8 quality (wrap simplify + standards) | Task 12 |
| 9 document (NEW skill) | Tasks 13-14 |
| 12 draftmr (NEW skill) | Tasks 15-16 |
| 13 review (wrap requesting-code-review) | Task 17 |
| 14 redmr (NEW skill) | Tasks 18-19 |
| 18 impact (NEW skill) | Tasks 20-21 |
| 19 lessonslearned (NEW skill) | Tasks 22-23 |

All 13 in scope. Steps 0, 6, 10, 11, 15, 16, 17, 20 explicitly
excluded as belonging to other plans.

Spec §6.1 (invocation grammar / `$NOTE`) — covered by Task 2's draft.md
becoming the canonical reference; all 12 other command files explicitly
delegate to that reference via "Per `commands/draft.md`".

Spec §7 (chaining) — out of scope per Plan 4 boundaries; commands do
not implement `--auto` themselves.

Spec §12 (templates registry) — every skill that consumes a template
explicitly references the §12 three-layer resolution order
(quality.md, draftmr, redmr, lessons-learned).

Spec §17 (skill mapping) — matches the spec table 1:1 with the
correction that the spec lists `redteam_issue` under custom skills but
that belongs to Family A (capture/redissue), not Family B (workflow).
Excluded correctly.

Skipping policy ("never auto-skip; always surface 'doesn't apply
because X, mark skipped?'") — every skill and every command has a
"Skipping policy" section that quotes this rule explicitly.

Checklist log invocation — every skill ends with a literal
`scripts/checklist-log.sh "$ISSUE_DIR" <step> "<msg>"` block; every
command file mentions `checklist-log.sh` (either inline or by delegating
to the skill).

**Placeholder scan:** no "TBD", "TODO", "implement later", or
"fill in details" strings remain. All code blocks are complete.

**Type consistency:**
- Skill dir names are consistent: `devagent-<verb>` everywhere
  (scope, improve, prune, tighten, document-actual-work, draft-mr,
  redmr, impact, lessons-learned). Note that two skills break the
  one-word pattern — `document-actual-work`, `draft-mr`,
  `lessons-learned` — these match the spec's naming exactly.
- Command file names: `<verb>.md` always; matches spec §6.3 exactly
  (draftmr not draft-mr, redmr not red-mr, lessonslearned not
  lessons-learned).
- Log line format consistent: every skill uses
  `"<step>: <freeform>; note: $NOTE"` where `<step>` matches the
  step-name in the checklist (draft, scope, improve, prune, tighten,
  implement, quality, document, draftmr, review, redmr, impact,
  lessonslearned).

**Open questions:**

1. The skill-fixture-check harness validates *structure* of SKILL.md,
   not *behaviour*. Real behavioural verification requires running an
   LLM against the fixture. The plan punts this to operator manual
   verification at first run. Should Plan 4 include a manual-test
   script that drives one skill against its fixture and shows the
   output, or is structural validation enough for v1? Default: punt
   to operator; revisit if structural-only proves insufficient.

2. The `/devagent:quality` step wraps `simplify`, which is shipped
   as a Claude Code built-in skill at the harness level (per the
   available-skills list in the system prompt). Plan 4 assumes
   `simplify` is callable from a command file via the same
   `superpowers:` cross-reference pattern used for upstream
   skills. If the harness's simplify must be invoked differently
   (e.g., `simplify` without a namespace prefix), command file
   `commands/quality.md` needs a one-line adjustment. Verify at
   first execution.

3. The plan creates `.gitkeep` files in Task 0 to make empty dirs
   commit-able, then those files persist forever. Acceptable. If
   not, the engineer can remove them once each directory has real
   content; no impact on plan correctness.

4. Plan 1's `scripts/checklist-log.sh` signature is assumed to be
   `<issue-dir> <step-name> <message>`. If Plan 1 chose a different
   shape (e.g., env vars instead of positionals), every SKILL.md
   needs a single-line edit. Task 0 step 1 catches this mismatch
   before any skill is written.

5. `devagent-impact`'s "honesty check" depends on the operator
   providing evidence paths via `$NOTE`. If `$NOTE` is empty for a
   perf issue, the skill halts. Plan 4 assumes operators using
   `/devagent:impact` for perf work understand they must pass
   evidence paths. This is documented in `commands/impact.md`'s
   argument-hint.
