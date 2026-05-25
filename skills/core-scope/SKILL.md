---
name: core-scope
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
