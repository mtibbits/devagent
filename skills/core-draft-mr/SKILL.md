---
name: core-draft-mr
description: Use when running step 12 of the devAgent workflow to draft the merge-request body from imPlan, actualWork, and analyzer output before shipping
when-to-use: After /devagent:analyze and before /devagent:review. Run as part of /devagent:draftmr.
---

# devagent-draft-mr

Step 12 of the devAgent 21-step workflow. Fills in
`${CLAUDE_PLUGIN_ROOT}/templates/mr_template.md` from the issue's plan, actualWork, and
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
    `<devdoc>/templates/` → plugin `${CLAUDE_PLUGIN_ROOT}/templates/mr_template.md`).
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

- `${CLAUDE_PLUGIN_ROOT}/templates/mr_template.md` (the canonical structure being filled).

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
