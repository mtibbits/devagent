---
name: core-improve
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
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" improve \
  "Improvements appended; B bugs, S side-effects, A ambiguities; note: $NOTE"
```

## Templates referenced

- `${CLAUDE_PLUGIN_ROOT}/templates/imPlan_template.md` (canonical section ordering).

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
