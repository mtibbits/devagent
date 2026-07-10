---
name: core-prune
description: Use when running step 4 of the devAgent workflow to move deferred/dismissed items from the implementation plan into the future-enhancements file, producing a minimal load-bearing plan
when-to-use: After /devagent:improve has tagged items and before /devagent:tighten. Run as part of /devagent:prune.
---

# devagent-prune

Step 4 of the devAgent 22-step workflow. Walks the Improvements section
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
- Refactor adjacent bar_helper for style consistency.

## Source: Improvements [defer] (2026-05-19)
- README update is not load-bearing for this fix.

## Source: Scope > Out of scope (2026-05-19)
- Platform-specific fast path for foo_helper.
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
${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" prune \
  "Pruned P items to imPlan-potentialFutureEnhancements.md; K tasks remain; note: $NOTE"
```

## Templates referenced

- `${CLAUDE_PLUGIN_ROOT}/templates/imPlan_template.md` (target structure for the pruned
  plan; the Improvements and Scope-evaluation sections pruned here are appended by
  earlier steps, not defined by the template).

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
