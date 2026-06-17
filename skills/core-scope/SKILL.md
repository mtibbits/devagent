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
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" scope \
  "Scope evaluation appended; N ambiguities, M preconditions, size=X LOC; note: $NOTE"
```

The format above is contract: `statusreport.sh` (via
`scripts/lib/statusreport-detect.py:poorly_scoped`) parses the `scope:` entry for an
integer followed by the `ambiguit` stem (so both `1 ambiguity` and the plural
`N ambiguities` match) and flags the issue as poorly scoped when that count is **> 3** —
the same "More than 3 ambiguities" threshold as the halt-and-ask rule above. Keep the count
adjacent to the word `ambiguit…` so the detector stays in sync.

## Templates referenced

- `${CLAUDE_PLUGIN_ROOT}/templates/imPlan_template.md` (for the canonical section ordering
  if the plan needs restructuring during this step).

## Completion handoff

After marking the step `[x]` (or `[-]` if skipped) and logging:

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first line in the issue's checklist.md
that starts with `- [ ]` -- read that, take the verb after the
step number, and substitute it into the question.

The only exception: if you were invoked under a `/devagent:next
--auto` or `--through` chain (recognizable because the preceding
turn's tool output contained a `CHAIN: /devagent:next ...` line),
then do NOT ask the question -- instead invoke that exact CHAIN:
command verbatim to continue the chain.

If the operator typed a one-off `/devagent:<name>` directly (no
preceding CHAIN: line), DO ask the question and wait for the
operator's answer. Do not advance even if your internal TODO list
still has steps after this one -- the operator's last explicit
instruction is the authoritative scope.
