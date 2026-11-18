---
name: core-prune
description: "Step 6: move deferred/dismissed items from the plan to the future-enhancements file, leaving a minimal load-bearing plan"
when_to_use: After /devagent:improve has tagged items and before /devagent:tighten. Run as part of /devagent:prune.
user-invocable: false
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
---

# devagent-prune

Step 6 of the devAgent 25-step workflow. Walks the Improvements section
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
    leaves a trail comment "moved to imPlan-potentialFutureEnhancements.md")
    (not on the one-task skip path).
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

- After pruning, fewer than 1 task remains.
- Operator's `$NOTE` says "keep X" but X is clearly off-scope —
  surface the conflict rather than silently keeping or pruning.
- Enhancements file already exists with conflicting entries — append,
  don't overwrite.

## Skipping policy

Never auto-skip a plan of two or more tasks. If such a plan is already
minimal (verified by re-reading and confirming every task is
load-bearing), surface "nothing to prune; mark step `[-]` skipped?" for
operator confirmation.

Exception: when the plan has exactly one task, `## Improvements` has no
`[defer]` item, the Scope evaluation's Out of scope has nothing
substantive (the word Checklist step 4 uses), and `$NOTE` is empty, do
not ask. Write nothing to `imPlan-potentialFutureEnhancements.md`;
create it empty if it is absent, because tighten requires the file. The
triaged `[dismiss]` entries in `## Improvements` stand as their own
dismissal record. Log `nothing to prune: one-task plan` (Logging, skip
line) and report that the step is skipped: the command marks it `[-]`.
A one-task plan that does carry a `[defer]` item or a substantive
Out-of-scope item is not skipped: prune it like any other plan, and the
step is marked `[x]`.

## Logging

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" prune "Pruned P items to imPlan-potentialFutureEnhancements.md; K tasks remain; note: $NOTE"
```

On the one-task skip path, run this line instead:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh" "$ISSUE_DIR" prune "nothing to prune: one-task plan"
```

## Templates referenced

- the resolved `imPlan_template.md` (§12 registry: project paths → devdoc → plugin default) (target structure for the pruned
  plan; the Improvements and Scope-evaluation sections pruned here are appended by
  earlier steps, not defined by the template).
