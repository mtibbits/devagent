---
name: core-draft-mr
description: Use when running step 12 of the devAgent workflow to draft the merge-request body from imPlan, actualWork, and analyzer output before shipping
when-to-use: After /devagent:analyze and before /devagent:review. Run as part of /devagent:draftmr.
---

# devagent-draft-mr

Step 12 of the devAgent 22-step workflow. Fills in
`${CLAUDE_PLUGIN_ROOT}/templates/mr_template.md` from the issue's plan, actualWork, and
analyzer findings, writing the result to `<issue-dir>/mr.md`. The
ship step later uses `mr.md` verbatim as the MR body.

## Overview

The MR body is the only artifact a reviewer reads first. Filling the
template's sections, it must convey: what changed and why now
(**Summary**), which issue it closes (**Related issues** —
`Closes #NNN`), and what evidence exists it works (**Testing**). The
skill fills the template from existing artifacts so nothing is
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
2. **Fill Summary section.** One paragraph: what changed **and why now**
   (the template's Summary is literally "What changed and why?"), from
   the issue's problem statement + the actualWork's outcome + any
   operator $NOTE. Note any deviations from actualWork's
   `## Deviations from plan`. No marketing.
3. **Fill Related issues section.** Add `Closes #<issue-number>` (taken
   from `issue.md`) so the issue **auto-closes on merge** — this is the
   load-bearing line; without it the MR merges but the issue stays open.
   Use `Related: #NNN` for context-only links that should not close.
4. **Fill Testing section.** How the change was verified — bullet list:
   - Tests added (from actualWork).
   - Analyzer results (one line per tool with finding counts from
     `analysis/*.txt`).
   - Benchmarks if performance issue (path to the project's
     evidence-plot output if it has one).
5. **Fill Checklist section** (DCO, surgical-diff confirmation, etc.)
   from the template. Pre-check items that are verifiable from
   artifacts; leave others unchecked.
6. **Write `<issue-dir>/mr.md`.**

## Halt and ask if

- `mr_template.md` cannot be resolved from any registry layer.
- `actualWork.md` is missing — operator must run document first.
- Any `analysis/*.txt` reports unaddressed findings — surface them
  before filing the MR. (The analyze step is N/A when its step is
  absent from the issue's checklist, e.g. docs-only, or when step 11
  is marked `[-]` — the `analyze = "none"` self-skip, #55 — then there
  is no `analysis/` and that is expected, not a halt.)
- `<issue-dir>/mr.md` already exists with substantive content —
  ask whether to overwrite, append a revision section, or abort.

## Skipping policy

Never auto-skip. Filing an MR with no body is bad-faith. If the issue
is docs-only and the template is overkill, surface "trivial change;
fill template stub only?" rather than skipping outright.

## Logging

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" draftmr \
  "mr.md drafted from mr_template.md (template source: $TEMPLATE_PATH); note: $NOTE"
```

## Templates referenced

- `${CLAUDE_PLUGIN_ROOT}/templates/mr_template.md` (the canonical structure being filled).

## Completion handoff

First, **mark this step done** — `next.sh` keys off the checklist mark
(not the log), so without it an `--auto`/`--through` chain re-dispatches
this same step forever:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-mark.sh" "$ISSUE_DIR" <N> x
```

`<N>` is this step's number on the issue's checklist; use `-` instead of
`x` if the step was skipped. Then run the Logging command above (if this
skill/command defines one).

**STOP.** Do not invoke any other `/devagent:*` command on your own.
End your final message with this exact question (substituting the
correct next-step slash command from the checklist):

> Would you like to continue on to /devagent:<next-step-name>?

The next-step name is the first step in the issue's checklist.md not
marked `[x]` or `[-]` -- read that line, take the verb after the
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
